-- @description GunKit RPM (respace folder items by rounds per minute)
-- @author Jay Sabins
-- @version 1.0.0
-- @changelog
--   First release. Select folder items (shots), drag the Rounds per minute slider and the shots
--   move live on the timeline (play while you drag to hear it). Apply makes it stick with one
--   undo point; Revert or closing the window puts everything back. Optional trim so fast rates
--   never overlap, with a short fade on the trimmed ends.
-- @about
--   # GunKit RPM
--
--   Respaces the selected folder items so they start 60 / RPM seconds apart, like the shots of
--   an automatic weapon. Each folder item moves together with everything inside it (the items
--   on its child tracks), and the first shot stays where it is.
--
--   The timeline previews the new spacing live while you change the rate; nothing is kept until
--   you click Apply (one undo point). Revert, or closing the window, puts everything back.
--
--   "Trim so shots don't overlap" shortens each shot (and its child items) where the next shot
--   starts, with a short fade-out on the cut, so fast rates never overlap.
--
--   Only folder items count as shots, so NVK Folder Items' auto-select (which selects the child
--   items too) can stay on. With no folder items selected, the selected items themselves are
--   used as the shots.
--
--   Requires ReaImGui (ReaPack > ReaTeam Extensions). Same look as Wwise Tool.
--
--   Guide: https://github.com/jaysabins/reascripts/blob/main/Items/jsabins_GunKit_RPM_README.md

local r = reaper
if not r.ImGui_GetBuiltinPath then
  r.ShowMessageBox("This script needs ReaImGui.\nInstall it from Extensions > ReaPack > Browse packages (search \"ReaImGui\"), then restart REAPER.",
    "GunKit RPM", 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. "/?.lua"
local ImGui = require "imgui" "0.9"

local ctx = ImGui.CreateContext("GunKit RPM")
local EXT = "jsabins_GunKit_RPM"
local EPS = 0.0005      -- seconds: tolerance for "starts inside" tests
local RPM_MIN, RPM_MAX = 1, 6000          -- any typed value is kept inside this
local SLIDER_MIN, SLIDER_MAX = 60, 1500   -- the slider's own range (Ctrl+click it to type more)

------------------------------------------------------------------------------------------------
-- SAVED OPTIONS
------------------------------------------------------------------------------------------------

local function ext_get(key, default)
  local v = r.GetExtState(EXT, key)
  if v == nil or v == "" then return default end
  return v
end

local opt = {
  trim = ext_get("trim", "0") == "1",
  fade_ms = tonumber(ext_get("fade_ms", "5")) or 5,
  rpm = tonumber(ext_get("rpm", "600")) or 600, -- used when the selection has a single shot
}

local function save_opts()
  r.SetExtState(EXT, "trim", opt.trim and "1" or "0", true)
  r.SetExtState(EXT, "fade_ms", tostring(opt.fade_ms), true)
  r.SetExtState(EXT, "rpm", tostring(opt.rpm), true)
end

------------------------------------------------------------------------------------------------
-- SHOTS (folder items and their children)
------------------------------------------------------------------------------------------------
-- S.groups: one group per track; each holds that track's shots sorted by position. Every shot
-- (and child) keeps its original position, length and fade-out, so the preview is always worked
-- out from the originals and can be put back exactly.

local S = {
  proj = nil,
  groups = {},
  n_shots = 0,
  n_tracks = 0,
  folder = true,   -- false: no folder items selected, the plain selected items are the shots
  dirty = false,   -- the timeline shows a preview that hasn't been applied
  sig = nil,       -- what the selection/project looked like when captured
  rpm = 600,
  typed = 600,     -- the typed field's value while it's being edited
  last_msg = nil,
}

local function is_folder_track(tr)
  return r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1
end

local function track_is_under(tr, parent)
  local p = r.GetParentTrack(tr)
  while p do
    if p == parent then return true end
    p = r.GetParentTrack(p)
  end
  return false
end

-- Items this window trimmed on Apply: { set_len = length we gave it, len, fade = before the cut }.
-- If such an item still has the length we gave it, the layout works from its full length, so a
-- slower rate after an Apply lets the shots ring out again.
local cut_items = {}

local function snap(item)
  local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local fade = r.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
  local rec = { item = item, pos = pos, len = len, fade = fade, full = len, full_fade = fade }
  local c = cut_items[item]
  if c and math.abs(c.set_len - len) < 1e-9 then rec.full, rec.full_fade = c.len, c.fade end
  return rec
end

-- Keep only folder items (any item on a folder track, so NVK folder items count). A folder item
-- on a track under another selected folder item's track that overlaps it is part of that folder
-- item, so it's dropped too. Same rule as Wwise Tool's "Folder items" source.
local function folder_items_only(items)
  local folders = {}
  for _, it in ipairs(items) do
    local tr = r.GetMediaItem_Track(it)
    if is_folder_track(tr) then
      local pos = r.GetMediaItemInfo_Value(it, "D_POSITION")
      folders[#folders + 1] = { item = it, track = tr, s = pos,
                                e = pos + r.GetMediaItemInfo_Value(it, "D_LENGTH") }
    end
  end
  local kept = {}
  for _, f in ipairs(folders) do
    local covered = false
    for _, p in ipairs(folders) do
      if p.item ~= f.item and f.s < p.e - 1e-9 and f.e > p.s + 1e-9
         and track_is_under(f.track, p.track) then
        covered = true; break
      end
    end
    if not covered then kept[#kept + 1] = f.item end
  end
  return kept
end

-- Children of each shot in a group: every item on a track under the group's folder track that
-- starts inside the shot (if shots overlap, the latest-starting one gets it).
local function collect_children(g, is_shot)
  local num = math.floor(r.GetMediaTrackInfo_Value(g.track, "IP_TRACKNUMBER")) -- 1-based
  local idx = num -- 0-based index of the first track after the folder track
  while idx < r.CountTracks(0) do
    local tr = r.GetTrack(0, idx)
    if not track_is_under(tr, g.track) then break end
    for i = 0, r.CountTrackMediaItems(tr) - 1 do
      local it = r.GetTrackMediaItem(tr, i)
      if not is_shot[it] then
        local p = r.GetMediaItemInfo_Value(it, "D_POSITION")
        local owner
        for _, s in ipairs(g.shots) do
          if p >= s.pos - EPS and p < s.pos + s.len - EPS then owner = s end -- sorted: latest wins
        end
        if owner then owner.kids[#owner.kids + 1] = snap(it) end
      end
    end
    idx = idx + 1
  end
end

-- Start-to-start rate of the shots as they are now, or nil with fewer than two shots.
local function current_rpm()
  local total, gaps = 0, 0
  for _, g in ipairs(S.groups) do
    local n = #g.shots
    if n >= 2 then
      total = total + (g.shots[n].pos - g.shots[1].pos)
      gaps = gaps + (n - 1)
    end
  end
  if gaps == 0 or total <= 1e-6 then return nil end
  return 60 / (total / gaps)
end

local function selection_sig()
  local proj = r.EnumProjects(-1)
  local t = { tostring(proj), r.GetProjectStateChangeCount(proj) }
  for i = 0, r.CountSelectedMediaItems(0) - 1 do t[#t + 1] = tostring(r.GetSelectedMediaItem(0, i)) end
  return table.concat(t, ",")
end

local function capture()
  S.proj = r.EnumProjects(-1)
  S.groups, S.n_shots, S.n_tracks = {}, 0, 0
  S.dirty = false
  local sel = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do sel[#sel + 1] = r.GetSelectedMediaItem(0, i) end
  local shots = folder_items_only(sel)
  S.folder = #shots > 0
  if not S.folder then shots = sel end
  local by_track, is_shot = {}, {}
  for _, it in ipairs(shots) do
    is_shot[it] = true
    local tr = r.GetMediaItem_Track(it)
    local g = by_track[tr]
    if not g then
      g = { track = tr, shots = {} }
      by_track[tr] = g
      S.groups[#S.groups + 1] = g
    end
    local s = snap(it)
    s.kids = {}
    g.shots[#g.shots + 1] = s
  end
  for _, g in ipairs(S.groups) do
    table.sort(g.shots, function(a, b) return a.pos < b.pos end)
    if S.folder then collect_children(g, is_shot) end
    S.n_shots = S.n_shots + #g.shots
  end
  S.n_tracks = #S.groups
  local rate = current_rpm()
  S.rpm = rate and math.floor(rate * 10 + 0.5) / 10 or opt.rpm
  S.typed = S.rpm
  S.sig = selection_sig()
end

local function valid(item)
  return r.ValidatePtr2(S.proj, item, "MediaItem*")
end

-- Every captured item still exists (an undo or a delete can remove them under us).
local function all_valid()
  for _, g in ipairs(S.groups) do
    for _, s in ipairs(g.shots) do
      if not valid(s.item) then return false end
      for _, k in ipairs(s.kids) do if not valid(k.item) then return false end end
    end
  end
  return true
end

local function put(rec, pos, len, fade)
  if not valid(rec.item) then return end
  r.SetMediaItemInfo_Value(rec.item, "D_POSITION", pos)
  r.SetMediaItemInfo_Value(rec.item, "D_LENGTH", len)
  r.SetMediaItemInfo_Value(rec.item, "D_FADEOUTLEN", fade)
end

-- Put every item back where it was captured.
local function restore()
  r.PreventUIRefresh(1)
  for _, g in ipairs(S.groups) do
    for _, s in ipairs(g.shots) do
      put(s, s.pos, s.len, s.fade)
      for _, k in ipairs(s.kids) do put(k, k.pos, k.len, k.fade) end
    end
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
end

-- Shorten an item that would run past `cut` (the next shot's start). Items starting at or after
-- the cut are left as they are.
local function trimmed(start, len, fade, cut)
  if start < cut - EPS and start + len > cut + EPS then
    local l = cut - start
    local f = opt.fade_ms > 0 and math.min(opt.fade_ms / 1000, l) or 0
    return l, f
  end
  return len, fade
end

-- Lay the shots out at `rpm` (worked out from the originals every time).
local function layout(rpm)
  rpm = math.max(RPM_MIN, math.min(RPM_MAX, rpm))
  local sp = 60 / rpm
  r.PreventUIRefresh(1)
  for _, g in ipairs(S.groups) do
    local base, n = g.shots[1].pos, #g.shots
    for i, s in ipairs(g.shots) do
      local start = base + (i - 1) * sp
      local d = start - s.pos
      local cut = (opt.trim and i < n) and (start + sp) or math.huge
      local len, fade = trimmed(start, s.full, s.full_fade, cut)
      put(s, start, len, fade)
      for _, k in ipairs(s.kids) do
        local klen, kfade = trimmed(k.pos + d, k.full, k.full_fade, cut)
        put(k, k.pos + d, klen, kfade)
      end
    end
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
end

local function preview()
  if S.n_shots == 0 then return end
  layout(S.rpm)
  S.dirty = true
  S.last_msg = nil
end

local function revert()
  if S.dirty then restore() end
  capture()
end

-- Apply: put the originals back, then lay out again inside one undo block, so Undo goes straight
-- back to how things were before the window touched them.
local function apply()
  if not (S.dirty and S.n_shots > 0) then return end
  restore()
  r.Undo_BeginBlock2(S.proj)
  layout(S.rpm)
  r.Undo_EndBlock2(S.proj, string.format("GunKit RPM: respace %d shots to %g RPM", S.n_shots, S.rpm), -1)
  -- Remember the full length of anything the trim shortened (see cut_items).
  local function note(rec)
    if not valid(rec.item) then return end
    local now = r.GetMediaItemInfo_Value(rec.item, "D_LENGTH")
    if now < rec.full - 1e-9 then
      cut_items[rec.item] = { set_len = now, len = rec.full, fade = rec.full_fade }
    else
      cut_items[rec.item] = nil
    end
  end
  for _, g in ipairs(S.groups) do
    for _, s in ipairs(g.shots) do
      note(s)
      for _, k in ipairs(s.kids) do note(k) end
    end
  end
  opt.rpm = S.rpm
  save_opts()
  local applied = S.rpm
  capture() -- the applied layout is the new starting point
  S.last_msg = string.format("Applied %g RPM to %d shot%s.", applied, S.n_shots, S.n_shots == 1 and "" or "s")
end

-- Called every frame: follow the selection while nothing is being previewed; if items vanished
-- mid-preview (undo, delete), drop the preview.
local function watch_selection()
  if S.dirty then
    if not all_valid() then restore(); capture() end
    return
  end
  if selection_sig() ~= S.sig then capture() end
end

------------------------------------------------------------------------------------------------
-- LOOK (same as Wwise Tool and Folder Batch)
------------------------------------------------------------------------------------------------
-- Same defaults as Wwise Tool: Verdana 12, 14px bold headings, #191919 background, 14px window
-- corners, 8px corners on buttons/fields/panels, a thin #505050 outline. If Wwise Tool's
-- Settings > Appearance has been changed, its saved look is used here too, so the two match.

local UI = {}
UI.FONT_CHOICES = { "Verdana", "Tahoma", "Segoe UI", "Arial", "Calibri", "Consolas" }
UI.LOOK_DEFAULTS = { font = "Verdana", size = 12, head = 14, win_round = 14, frame_round = 8 }
UI.DEFAULT_TEXT, UI.DEFAULT_DIM, UI.DEFAULT_BG = 0xFFFFFFFF, 0x9A9A9AFF, 0x191919FF
UI.DEFAULT_OUTLINE = 0x505050FF
UI.COLOR_OK, UI.COLOR_BAD, UI.COLOR_PREVIEW = 0x6BCB77FF, 0xFF6B6BFF, 0xF5A524FF
UI.APPLY_H = 34 -- Apply button height (same as Wwise Tool's Transfer button)
UI.GUIDE_URL = "https://github.com/jaysabins/reascripts/blob/main/Items/jsabins_GunKit_RPM_README.md"

-- Wwise Tool keeps its look as JSON in ExtState jsabins_WwiseTool/view, under "look".
-- Read just those few flat fields (no JSON library needed); anything missing keeps its default.
UI.read_look = function()
  local d = UI.LOOK_DEFAULTS
  local L = { font = d.font, size = d.size, head = d.head, win_round = d.win_round, frame_round = d.frame_round }
  local ok, v = pcall(r.GetExtState, "jsabins_WwiseTool", "view")
  local body = ok and type(v) == "string" and v:match('"look"%s*:%s*(%b{})')
  if not body then return L end
  local function num(k)
    local n = tonumber(body:match('"' .. k .. '"%s*:%s*(%-?[%d%.eE%+]+)'))
    return n and math.floor(n) or nil
  end
  local function clamp(n, lo, hi) return n and math.max(lo, math.min(hi, n)) or nil end
  local font = body:match('"font"%s*:%s*"([^"]*)"')
  for _, f in ipairs(UI.FONT_CHOICES) do if f == font then L.font = f end end
  L.size = clamp(num("size"), 9, 18) or L.size
  L.head = clamp(num("head"), 10, 24) or L.head
  L.win_round = clamp(num("win_round"), 0, 20) or L.win_round
  local fr = clamp(num("frame_round"), 0, 10)
  -- Wwise Tool 1.22.0 saved its old default (3); 1.22.1 moved everyone on it to 8.
  if fr and not ((num("look_v") or 0) < 1 and fr == 3) then L.frame_round = fr end
  for _, k in ipairs({ "title", "text", "dim", "bg", "outline" }) do
    local n = num(k)
    if n then L[k] = n | 0xFF end
  end
  return L
end
UI.look = UI.read_look()
UI.bg_rgb = function() return (UI.look.bg or UI.DEFAULT_BG) >> 8 end
UI.dim_col = function() return UI.look.dim or UI.DEFAULT_DIM end
UI.WINDOW_ROUNDING = UI.look.win_round
UI.FRAME_ROUNDING = UI.look.frame_round

-- Fonts are made once at startup. Any that can't be made fall back to ImGui's own font.
UI.make_font = function(size, bold)
  local flags = 0
  if bold then
    local okb, b = pcall(function() return ImGui.FontFlags_Bold end)
    if okb and type(b) == "number" then flags = b end
  end
  local ok, f = pcall(ImGui.CreateFont, UI.look.font, size, flags)
  if not (ok and f) then ok, f = pcall(ImGui.CreateFont, UI.look.font, size) end
  if ok and f and pcall(ImGui.Attach, ctx, f) then return f end
end
UI.main_font = UI.make_font(UI.look.size)
UI.section_font = UI.make_font(UI.look.head, true)   -- section headings
UI.title_font = UI.make_font(UI.look.head + 1, true) -- big window title, 1px bigger

-- Constant names changed between ReaImGui versions, so use whichever exists.
local function imgui_const(...)
  for _, name in ipairs({ ... }) do
    local ok, v = pcall(function() return ImGui[name] end)
    if ok and type(v) == "number" then return v end
  end
end

-- Dark grey theme in place of ImGui's default blue (same colors as Wwise Tool).
local GREY_THEME = {
  { { "Col_WindowBg" }, 0x191919FF },
  { { "Col_Border" }, 0x2E2E2EFF },
  { { "Col_Button" }, 0x3A3A3AFF },
  { { "Col_ButtonHovered" }, 0x4C4C4CFF },
  { { "Col_ButtonActive" }, 0x5E5E5EFF },
  { { "Col_FrameBg" }, 0x2A2A2AFF },
  { { "Col_FrameBgHovered" }, 0x383838FF },
  { { "Col_FrameBgActive" }, 0x464646FF },
  { { "Col_Header" }, 0x3A3A3AFF },
  { { "Col_HeaderHovered" }, 0x4A4A4AFF },
  { { "Col_HeaderActive" }, 0x585858FF },
  { { "Col_CheckMark" }, 0xD8D8D8FF },
  { { "Col_SliderGrab" }, 0x8A8A8AFF },
  { { "Col_SliderGrabActive" }, 0xB4B4B4FF },
  { { "Col_SeparatorHovered" }, 0x707070C8 },
  { { "Col_SeparatorActive" }, 0x909090FF },
  { { "Col_ResizeGrip" }, 0x5A5A5A40 },
  { { "Col_ResizeGripHovered" }, 0x7A7A7AAA },
  { { "Col_ResizeGripActive" }, 0x9A9A9AF2 },
  { { "Col_Tab" }, 0x2C2C2CFF },
  { { "Col_TabHovered" }, 0x4C4C4CFF },
  { { "Col_TabSelected", "Col_TabActive" }, 0x3C3C3CFF },
  { { "Col_TabDimmed", "Col_TabUnfocused" }, 0x242424FF },
  { { "Col_TabDimmedSelected", "Col_TabUnfocusedActive" }, 0x333333FF },
  { { "Col_TextSelectedBg" }, 0x6A6A6A80 },
  { { "Col_NavCursor", "Col_NavHighlight" }, 0x9A9A9AFF },
  { { "Col_DockingPreview" }, 0x8A8A8AB3 },
}
for _, t in ipairs(GREY_THEME) do t[1] = imgui_const(table.unpack(t[1])) end
-- Push the grey theme; returns how many colors to pop.
local function push_grey_theme()
  local n = 0
  for _, t in ipairs(GREY_THEME) do
    if t[1] then
      ImGui.PushStyleColor(ctx, t[1], t[1] == ImGui.Col_WindowBg and ((UI.bg_rgb() << 8) | 0xFF) or t[2]); n = n + 1
    end
  end
  if UI.look.text then ImGui.PushStyleColor(ctx, ImGui.Col_Text, UI.look.text); n = n + 1 end
  if UI.look.dim then ImGui.PushStyleColor(ctx, ImGui.Col_TextDisabled, UI.look.dim); n = n + 1 end
  return n
end

-- Rounded corners for everything ImGui draws square by default. Pushed right after the window's
-- Begin and popped right before its End.
UI.ROUNDING_VARS = { "StyleVar_FrameRounding", "StyleVar_GrabRounding", "StyleVar_PopupRounding",
  "StyleVar_ChildRounding", "StyleVar_TabRounding", "StyleVar_ScrollbarRounding" }
UI.push_rounding = function()
  local n = 0
  for _, k in ipairs(UI.ROUNDING_VARS) do
    local ok, v = pcall(function() return ImGui[k] end)
    if ok and type(v) == "number" then ImGui.PushStyleVar(ctx, v, UI.FRAME_ROUNDING); n = n + 1 end
  end
  return n
end

------------------------------------------------------------------------------------------------
-- GUI HELPERS
------------------------------------------------------------------------------------------------

local function tip(text)
  if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then ImGui.SetTooltip(ctx, text) end
end
local function dim(text) ImGui.TextColored(ctx, UI.dim_col(), text) end

-- Section heading: bold text with a line after it (like Wwise Tool's sections).
local function section_title(text)
  local big = UI.section_font and pcall(ImGui.PushFont, ctx, UI.section_font)
  ImGui.SeparatorText(ctx, text)
  if big then ImGui.PopFont(ctx) end
  ImGui.Dummy(ctx, 0, 0) -- a little room under the heading
end

-- The big window title, drawn twice a pixel apart so it's extra bold.
local function draw_title(dl, x, y, col, text)
  ImGui.DrawList_AddText(dl, x, y, col, text)
  ImGui.DrawList_AddText(dl, x + 1, y, col, text)
end

-- Open a web page in the default browser (SWS's CF_ShellExecute, else the OS's own opener).
local function open_url(url)
  if r.CF_ShellExecute then r.CF_ShellExecute(url); return end
  local os_name = r.GetOS()
  if os_name:match("^Win") then
    r.ExecProcess('explorer.exe "' .. url .. '"', -2)
  elseif os_name:match("^OSX") or os_name:match("^macOS") then
    r.ExecProcess('/usr/bin/open "' .. url .. '"', -2)
  else
    r.ExecProcess('xdg-open "' .. url .. '"', -2)
  end
end

-- Title-bar buttons: twice the font size, flat until hovered (grey box; the X goes red).
local function close_size() return math.floor(ImGui.GetFontSize(ctx) * 2 + 0.5) end
local function close_margin() return math.floor(ImGui.GetFontSize(ctx) * 0.5 + 0.5) end
local function title_bar_size() return close_size() + close_margin() + math.max(2, math.floor(close_margin() * 0.4)) end

local function close_button(id, size)
  local pressed = ImGui.InvisibleButton(ctx, id, size, size)
  local hovered, held = ImGui.IsItemHovered(ctx), ImGui.IsItemActive(ctx)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local fg = hovered and 0xFFFFFFFF or ImGui.GetColor(ctx, ImGui.Col_Text)
  if hovered or held then
    ImGui.DrawList_AddRectFilled(dl, x1, y1, x1 + size, y1 + size, held and 0xB8323AFF or 0xE04048FF, size * 0.22)
  end
  local m, th = size * 0.30, math.max(2, size * 0.08)
  local a, b = m - 0.5, size - m - 0.5
  ImGui.DrawList_AddLine(dl, x1 + a, y1 + a, x1 + b, y1 + b, fg, th)
  ImGui.DrawList_AddLine(dl, x1 + b, y1 + a, x1 + a, y1 + b, fg, th)
  return pressed
end

local function title_icon_button(id, size, draw)
  local pressed = ImGui.InvisibleButton(ctx, id, size, size)
  local hovered, held = ImGui.IsItemHovered(ctx), ImGui.IsItemActive(ctx)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local fg = hovered and 0xFFFFFFFF or ImGui.GetColor(ctx, ImGui.Col_Text)
  if hovered or held then
    ImGui.DrawList_AddRectFilled(dl, x1, y1, x1 + size, y1 + size, held and 0x5E5E5EFF or 0x4C4C4CFF, size * 0.22)
  end
  draw(dl, x1, y1, size, fg)
  return pressed
end

local function draw_question(dl, x1, y1, size, fg)
  local big = UI.section_font and pcall(ImGui.PushFont, ctx, UI.section_font)
  local tw, th = ImGui.CalcTextSize(ctx, "?")
  ImGui.DrawList_AddText(dl, x1 + (size - tw) / 2, y1 + (size - th) / 2, fg, "?")
  if big then ImGui.PopFont(ctx) end
end


------------------------------------------------------------------------------------------------
-- WINDOW PARTS
------------------------------------------------------------------------------------------------

local close_clicked = false
local win_docked = false

-- Status in the title bar: { text, color (nil = normal), tooltip }, and the dot's color.
local function status_items()
  if S.n_shots == 0 then
    return { { "Nothing selected", UI.dim_col(), "Select the folder items (shots) to respace." } }, UI.dim_col()
  end
  local what = S.folder and "folder item" or "item"
  local t = { { string.format("%d %s%s", S.n_shots, what, S.n_shots == 1 and "" or "s"), nil,
    S.folder and "Selected folder items. Their child items move with them." or
      "No folder items selected, so the selected items themselves are the shots." } }
  if S.n_tracks > 1 then t[2] = { string.format("on %d tracks", S.n_tracks), UI.dim_col(),
    "Each track's shots are spaced on their own, starting from that track's first shot." } end
  if S.dirty then
    t[#t + 1] = { "preview", UI.COLOR_PREVIEW, "The timeline shows a preview. Apply keeps it; Revert or closing puts things back." }
    return t, UI.COLOR_PREVIEW
  end
  return t, UI.COLOR_OK
end

-- Status dot and text, right-aligned to right_x and centered on a row of height h at top.
local function title_status(right_x, top, h)
  local items, dot_col = status_items()
  local sp = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
  local dot = 8
  local w = dot + sp
  for i, it in ipairs(items) do w = w + ImGui.CalcTextSize(ctx, it[1]) + (i > 1 and sp or 0) end
  local th = ImGui.GetTextLineHeight(ctx)
  local x, y = right_x - w, top + (h - th) / 2
  ImGui.DrawList_AddCircleFilled(ImGui.GetWindowDrawList(ctx), x + dot / 2, top + h / 2, dot / 2, dot_col)
  x = x + dot + sp
  for _, it in ipairs(items) do
    ImGui.SetCursorScreenPos(ctx, x, y)
    if it[2] then ImGui.TextColored(ctx, it[2], it[1]) else ImGui.Text(ctx, it[1]) end
    if it[3] and ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, it[3]) end
    x = x + ImGui.CalcTextSize(ctx, it[1]) + sp
  end
end

-- Floating window: big bold title on the left; status, ? and X on the right, drawn over the
-- (taller) title bar. Called last in the window so it draws on top.
local function title_bar()
  local size, m = close_size(), close_margin()
  local wx, wy = ImGui.GetWindowPos(ctx)
  local ww = ImGui.GetWindowSize(ctx)
  ImGui.PushClipRect(ctx, wx, wy, wx + ww, wy + title_bar_size(), false)
  local gap = math.floor(m * 0.6 + 0.5)
  local x = wx + ww - size - m - gap
  ImGui.SetCursorScreenPos(ctx, x, wy + m)
  if close_button("##closewin", size) then close_clicked = true end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, S.dirty and "Close GunKit RPM (puts the shots back; Apply first to keep the preview)" or "Close GunKit RPM")
  end
  x = x - gap - size
  ImGui.SetCursorScreenPos(ctx, x, wy + m)
  if title_icon_button("##guide_t", size, draw_question) then open_url(UI.GUIDE_URL) end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Open the GunKit RPM guide on GitHub") end
  title_status(x - gap * 2, wy + m, size)
  local big = UI.title_font and pcall(ImGui.PushFont, ctx, UI.title_font)
  local _, th = ImGui.CalcTextSize(ctx, "GunKit RPM")
  draw_title(ImGui.GetWindowDrawList(ctx), wx + m + 12, wy + m + (size - th) / 2 + 3,
    UI.look.title or ImGui.GetColor(ctx, ImGui.Col_Text), "GunKit RPM")
  if big then ImGui.PopFont(ctx) end
  ImGui.PopClipRect(ctx)
end

-- Docked (no title bar): status and ? on one row at the top, right-aligned.
local function docked_header()
  local size = ImGui.GetFrameHeight(ctx)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local aw = ImGui.GetContentRegionAvail(ctx)
  local gap = 6
  title_status(x0 + aw - size - gap * 2, y0, size)
  ImGui.SetCursorScreenPos(ctx, x0 + aw - size, y0)
  if title_icon_button("##guide_d", size, draw_question) then open_url(UI.GUIDE_URL) end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Open the GunKit RPM guide on GitHub") end
end

local function form_label(text)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, text)
  ImGui.SameLine(ctx, math.floor(ImGui.GetFontSize(ctx) * 7))
end

local function section_shots()
  section_title("Shots")
  if S.n_shots == 0 then
    dim("Select the folder items to respace.")
    dim("Their child items move with them.")
    return
  end
  local what = S.folder and "folder item" or "item"
  ImGui.Text(ctx, string.format("%d %s%s%s", S.n_shots, what, S.n_shots == 1 and "" or "s",
    S.n_tracks > 1 and string.format(" on %d tracks", S.n_tracks) or ""))
  if S.folder then
    tip("Each folder item moves with everything on its child tracks that starts inside it.")
  else
    tip("No folder items are selected, so the selected items themselves are the shots.")
  end
  if S.dirty then
    dim("Selection is locked while previewing.")
    tip("Apply or Revert to pick other items.")
  else
    dim("The first shot of each track stays where it is.")
  end
end

local function set_rpm(v)
  v = math.max(RPM_MIN, math.min(RPM_MAX, v))
  if v ~= S.rpm or not S.dirty then
    S.rpm = v
    preview()
  end
end

local function section_rate()
  section_title("Rate")
  local can = S.n_shots > 0 -- worked out once: Begin/EndDisabled below must match
  if not can then ImGui.BeginDisabled(ctx) end

  form_label("Rounds/min")
  local field_w = math.floor(ImGui.GetFontSize(ctx) * 5)
  local sp_x = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
  ImGui.SetNextItemWidth(ctx, -(field_w + sp_x))
  local changed, v = ImGui.SliderDouble(ctx, "##rpm", S.rpm, SLIDER_MIN, SLIDER_MAX, "%.0f RPM")
  if changed then set_rpm(v) end
  tip("Drag to change the rate; the timeline follows live. Ctrl+click to type any value.")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, field_w)
  if not S.typing then S.typed = S.rpm end
  local _, tv = ImGui.InputDouble(ctx, "##rpmtyped", S.typed, 0, 0, "%.1f")
  S.typed = tv
  S.typing = ImGui.IsItemActive(ctx)
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then set_rpm(S.typed) end
  tip(string.format("Type a rate (%d to %d) and press Enter.", RPM_MIN, RPM_MAX))

  form_label("Spacing")
  ImGui.Text(ctx, string.format("%.1f ms", 60000 / S.rpm))
  local was = current_rpm()
  if was and not S.dirty then
    ImGui.SameLine(ctx)
    dim("(as they are now)")
  end
  tip("Start-to-start time between shots.")

  ImGui.Dummy(ctx, 0, 2)
  local c1, t = ImGui.Checkbox(ctx, "Trim so shots don't overlap", opt.trim)
  if c1 then
    opt.trim = t
    save_opts()
    if S.n_shots > 0 then preview() end
  end
  tip("When the spacing is shorter than a shot, cut each shot (and its child items) where the next one starts.")
  if opt.trim then
    ImGui.Indent(ctx)
    form_label("Fade on cut")
    ImGui.SetNextItemWidth(ctx, field_w)
    local _, fv = ImGui.InputDouble(ctx, "##fade", opt.fade_ms, 0, 0, "%.0f")
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then
      opt.fade_ms = math.max(0, math.min(500, fv))
      save_opts()
      if S.dirty then preview() end
    end
    tip("Fade-out on each trimmed end so the cut doesn't click. 0 = no fade.")
    ImGui.SameLine(ctx)
    ImGui.AlignTextToFramePadding(ctx)
    dim("ms")
    ImGui.Unindent(ctx)
  end

  if not can then ImGui.EndDisabled(ctx) end

  if S.last_msg then
    ImGui.Dummy(ctx, 0, 2)
    ImGui.TextColored(ctx, UI.COLOR_OK, S.last_msg)
  end
end

-- First shot's position (to start playback from), or nil.
local function first_shot_pos()
  local p
  for _, g in ipairs(S.groups) do
    local s = g.shots[1].pos
    if not p or s < p then p = s end
  end
  return p
end

-- Bottom row: green Apply on the left, then Revert and Play.
local function footer()
  local can_apply = S.dirty and S.n_shots > 0 -- worked out once for the pairs below
  local sp_x = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
  local small_w = math.floor(ImGui.GetFontSize(ctx) * 6)
  local avail = ImGui.GetContentRegionAvail(ctx)
  local apply_w = math.max(80, avail - 2 * (small_w + sp_x))

  if can_apply then
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x1A7F37FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x2C974BFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x166A2EFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFFFFFFF)
  else
    ImGui.BeginDisabled(ctx)
  end
  local apply_clicked = ImGui.Button(ctx, "Apply##apply", apply_w, UI.APPLY_H)
  if can_apply then ImGui.PopStyleColor(ctx, 4) else ImGui.EndDisabled(ctx) end
  if apply_clicked and can_apply then S.apply_queued = true end
  if S.n_shots == 0 then tip("Select some folder items first.")
  elseif not S.dirty then tip("Change the rate first; the timeline previews it, then Apply keeps it.")
  else tip("Keep the new spacing (one undo point).") end

  ImGui.SameLine(ctx)
  local can_revert = S.dirty
  if not can_revert then ImGui.BeginDisabled(ctx) end
  local revert_clicked = ImGui.Button(ctx, "Revert##revert", small_w, UI.APPLY_H)
  if not can_revert then ImGui.EndDisabled(ctx) end
  if revert_clicked and can_revert then S.revert_queued = true end
  tip("Put the shots back where they were.")

  ImGui.SameLine(ctx)
  local playing = (r.GetPlayState() & 1) == 1
  local can_play = S.n_shots > 0 or playing
  if not can_play then ImGui.BeginDisabled(ctx) end
  local play_clicked = ImGui.Button(ctx, (playing and "Stop" or "Play") .. "##play", small_w, UI.APPLY_H)
  if not can_play then ImGui.EndDisabled(ctx) end
  if play_clicked and can_play then
    if playing then
      r.OnStopButton()
    else
      local p = first_shot_pos()
      if p then r.SetEditCurPos(p, true, false) end
      r.OnPlayButton()
    end
  end
  tip(playing and "Stop playback." or "Play from the first shot. Keep changing the rate while it plays.")
end

------------------------------------------------------------------------------------------------
-- MAIN WINDOW
------------------------------------------------------------------------------------------------

local function loop_body()
  ImGui.SetNextWindowSize(ctx, 520, 330, ImGui.Cond_FirstUseEver)
  ImGui.SetNextWindowSizeConstraints(ctx, 440, 300, 4000, 4000)
  local main_font = UI.main_font and pcall(ImGui.PushFont, ctx, UI.main_font)
  ImGui.SetNextWindowCollapsed(ctx, false, ImGui.Cond_Always)
  local own_bg = not win_docked
  local bg_col = (UI.bg_rgb() << 8) | 0xFF
  ImGui.SetNextWindowBgAlpha(ctx, own_bg and 0 or 1)
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, 0x202020FF) -- solid popups and tooltips
  local title_bg = own_bg and (UI.bg_rgb() << 8) or bg_col
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg, title_bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive, title_bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgCollapsed, title_bg)
  local theme_n = push_grey_theme()
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, UI.FRAME_ROUNDING)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_GrabRounding, UI.FRAME_ROUNDING)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_PopupRounding, UI.FRAME_ROUNDING)
  local pad_x, pad_y = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  local title_pad = (title_bar_size() - ImGui.GetFontSize(ctx)) / 2
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, pad_x, math.max(pad_y, title_pad))
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding, UI.WINDOW_ROUNDING)
  local hide_title = not win_docked
  if hide_title then ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x00000000) end
  local visible, open = ImGui.Begin(ctx, "GunKit RPM", win_docked and true or nil,
    ImGui.WindowFlags_NoCollapse | ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoScrollWithMouse)
  if hide_title then ImGui.PopStyleColor(ctx) end
  ImGui.PopStyleVar(ctx, 2)
  if open == nil then open = true end
  if visible then
    local round_n = UI.push_rounding()
    if own_bg then
      local wx, wy = ImGui.GetWindowPos(ctx)
      local ww, wh = ImGui.GetWindowSize(ctx)
      local dl = ImGui.GetWindowDrawList(ctx)
      ImGui.PushClipRect(ctx, wx, wy, wx + ww, wy + wh, false)
      ImGui.DrawList_AddRectFilled(dl, wx, wy, wx + ww, wy + wh, bg_col, UI.WINDOW_ROUNDING)
      ImGui.DrawList_AddRect(dl, wx + 0.5, wy + 0.5, wx + ww - 0.5, wy + wh - 0.5,
        UI.look.outline or UI.DEFAULT_OUTLINE, UI.WINDOW_ROUNDING, 0, 1)
      ImGui.PopClipRect(ctx)
    end
    win_docked = ImGui.IsWindowDocked(ctx)
    if win_docked then docked_header() end

    local _, sp_y = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
    local footer_h = UI.APPLY_H + sp_y
    if ImGui.BeginChild(ctx, "body", 0, -footer_h, ImGui.ChildFlags_Border) then
      section_shots()
      ImGui.Dummy(ctx, 0, 4)
      section_rate()
      ImGui.EndChild(ctx)
    end
    footer()

    if not win_docked then title_bar() end
    if round_n > 0 then ImGui.PopStyleVar(ctx, round_n) end
    ImGui.End(ctx)
  end
  ImGui.PopStyleVar(ctx, 3)
  ImGui.PopStyleColor(ctx, 4 + theme_n)
  if main_font then ImGui.PopFont(ctx) end
  if close_clicked then open = false end
  return open
end

------------------------------------------------------------------------------------------------
-- DEFER LOOP
------------------------------------------------------------------------------------------------

local finished = false
-- Closing (X, or REAPER stopping the script) puts back anything that wasn't applied.
local function finish()
  if finished then return end
  finished = true
  if S.dirty then restore(); S.dirty = false end
  save_opts()
end

local function loop()
  watch_selection()
  local open = loop_body()
  -- Timeline changes from the buttons run between frames, never inside the ImGui window.
  if S.apply_queued then S.apply_queued = false; apply() end
  if S.revert_queued then S.revert_queued = false; revert() end
  if open then r.defer(loop) else finish() end
end

r.atexit(finish)
capture()
r.defer(loop)
