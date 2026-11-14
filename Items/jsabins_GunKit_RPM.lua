-- @description GunKit RPM (respace folder items by rounds per minute)
-- @author Jay Sabins
-- @version 1.0.0
-- @changelog
--   First release. Select folder items (shots), drag the Rounds per minute slider and the shots
--   move live on the timeline (play while you drag to hear it). Apply makes it stick with one
--   undo point; Revert or closing the window puts everything back.
--   Optional trim so fast rates never overlap, with a short fade on the trimmed ends.
--   Volume shaping across the burst: Start and End level, a Curve, and Random variation, with
--   a bar graph of each shot's level.
--   Preset tabs: each tab keeps its own rate, trim and volume settings; click a tab to preview it.
--   Accent color (gear button) for the Apply button, sliders, checkmarks and volume bars.
-- @about
--   # GunKit RPM
--
--   Respaces the selected folder items so they start 60 / RPM seconds apart, like the shots of
--   an automatic weapon. Each folder item moves together with everything inside it (the items
--   on its child tracks), and the first shot stays where it is.
--
--   The timeline previews every change live; nothing is kept until you click Apply (one undo
--   point). Revert, or closing the window, puts everything back.
--
--   Options: trim so fast rates never overlap (with a fade on the cut), and a volume shape
--   across the burst (Start, End, Curve, Random). Preset tabs keep sets of settings.
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

-- Preset tabs: each tab holds a full set of options. Saved for every project (ExtState).
local FIELDS = { "rpm", "trim", "fade_ms", "vol", "vol_start", "vol_end", "vol_curve", "vol_rand" }
local DEFAULTS = { rpm = 600, trim = false, fade_ms = 5, vol = false, vol_start = 0, vol_end = -6,
                   vol_curve = 0, vol_rand = 0 }

local function copy_set(src)
  local t = {}
  for _, k in ipairs(FIELDS) do
    local v = src and src[k]
    if v == nil then v = DEFAULTS[k] end
    t[k] = v
  end
  return t
end

-- Names may hold anything; | % and line breaks are escaped so one line = one tab.
local function enc(str) return (str:gsub("[%%|\r\n]", function(c) return string.format("%%%02X", c:byte()) end)) end
local function dec(str) return (str:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

local tabs = { list = {}, active = 1, next_id = 1 }

local function load_tabs()
  local raw = ext_get("tabs", "")
  for line in raw:gmatch("[^\n]+") do
    local f = {}
    for v in (line .. "|"):gmatch("([^|]*)|") do f[#f + 1] = v end
    if #f >= 2 + #FIELDS then
      local set = {}
      for i, k in ipairs(FIELDS) do
        local v = f[2 + i]
        if type(DEFAULTS[k]) == "boolean" then set[k] = v == "1" else set[k] = tonumber(v) end
      end
      tabs.list[#tabs.list + 1] = { id = tabs.next_id, name = dec(f[1]), color = tonumber(f[2]), s = copy_set(set) }
      tabs.next_id = tabs.next_id + 1
    end
  end
  if #tabs.list == 0 then
    tabs.list[1] = { id = tabs.next_id, name = "Default", s = copy_set(nil) }
    tabs.next_id = tabs.next_id + 1
  end
  tabs.active = math.max(1, math.min(#tabs.list, tonumber(ext_get("active", "1")) or 1))
end

local function save_tabs()
  local lines = {}
  for _, t in ipairs(tabs.list) do
    local f = { enc(t.name), t.color and tostring(t.color) or "" }
    for _, k in ipairs(FIELDS) do
      local v = t.s[k]
      if type(v) == "boolean" then v = v and "1" or "0" end
      f[#f + 1] = tostring(v)
    end
    lines[#lines + 1] = table.concat(f, "|")
  end
  r.SetExtState(EXT, "tabs", table.concat(lines, "\n"), true)
  r.SetExtState(EXT, "active", tostring(tabs.active), true)
end

load_tabs()
local P = tabs.list[tabs.active].s -- the active tab's options

-- Accent color (0xRRGGBB) for the Apply button, the sliders, checkmarks and the volume bars.
local ACCENT_DEFAULT = 0x1A7F37
local accent = tonumber(ext_get("accent", ""))
local function save_accent()
  if accent then r.SetExtState(EXT, "accent", tostring(accent), true) else r.DeleteExtState(EXT, "accent", true) end
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
-- Same idea for volume: items whose volume this window set on Apply { set_vol, vol = before }, so
-- shaping again starts from the volume they had before, instead of stacking on top of it.
local vol_items = {}
-- Each shot's random volume share, kept for the whole session so the preview doesn't jump around.
local rnd_of = {}

local function snap(item)
  local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local fade = r.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
  local rec = { item = item, pos = pos, len = len, fade = fade, full = len, full_fade = fade,
                vol = r.GetMediaItemInfo_Value(item, "D_VOL") }
  rec.base_vol = rec.vol
  local c = cut_items[item]
  if c and math.abs(c.set_len - len) < 1e-9 then rec.full, rec.full_fade = c.len, c.fade end
  local v = vol_items[item]
  if v and math.abs(v.set_vol - rec.vol) < 1e-9 then rec.base_vol = v.vol end
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
    rnd_of[it] = rnd_of[it] or (math.random() * 2 - 1)
    s.rnd = rnd_of[it] -- this shot's share of the random volume spread
    g.shots[#g.shots + 1] = s
  end
  for _, g in ipairs(S.groups) do
    table.sort(g.shots, function(a, b) return a.pos < b.pos end)
    if S.folder then collect_children(g, is_shot) end
    S.n_shots = S.n_shots + #g.shots
  end
  S.n_tracks = #S.groups
  S.now_rpm = current_rpm() -- shown next to the slider; the slider keeps the tab's rate
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

local function put(rec, pos, len, fade, vol)
  if not valid(rec.item) then return end
  r.SetMediaItemInfo_Value(rec.item, "D_POSITION", pos)
  r.SetMediaItemInfo_Value(rec.item, "D_LENGTH", len)
  r.SetMediaItemInfo_Value(rec.item, "D_FADEOUTLEN", fade)
  r.SetMediaItemInfo_Value(rec.item, "D_VOL", vol or rec.vol)
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
    local f = P.fade_ms > 0 and math.min(P.fade_ms / 1000, l) or 0
    return l, f
  end
  return len, fade
end

-- Volume shape: dB for position t (0 = first shot, 1 = last). Curve bends the line: above 0 it
-- holds near Start longer then drops, below 0 it moves toward End right away.
local function shape_db(t, rnd)
  local e = 4 ^ (P.vol_curve or 0)
  return P.vol_start + (P.vol_end - P.vol_start) * (t ^ e) + (rnd or 0) * P.vol_rand
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
      local cut = (P.trim and i < n) and (start + sp) or math.huge
      local gain = 1
      if P.vol then gain = 10 ^ (shape_db(n > 1 and (i - 1) / (n - 1) or 0, s.rnd) / 20) end
      local len, fade = trimmed(start, s.full, s.full_fade, cut)
      -- Folder items: the gain goes on the child items (the audio); plain items get it themselves.
      put(s, start, len, fade, S.folder and s.base_vol or s.base_vol * gain)
      for _, k in ipairs(s.kids) do
        local klen, kfade = trimmed(k.pos + d, k.full, k.full_fade, cut)
        put(k, k.pos + d, klen, kfade, k.base_vol * gain)
      end
    end
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
end

local function preview()
  if S.n_shots == 0 then return end
  layout(P.rpm)
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
  layout(P.rpm)
  r.Undo_EndBlock2(S.proj, string.format("GunKit RPM: respace %d shots to %g RPM", S.n_shots, P.rpm), -1)
  -- Remember the full length of anything the trim shortened (see cut_items).
  local function note(rec)
    if not valid(rec.item) then return end
    local now = r.GetMediaItemInfo_Value(rec.item, "D_LENGTH")
    if now < rec.full - 1e-9 then
      cut_items[rec.item] = { set_len = now, len = rec.full, fade = rec.full_fade }
    else
      cut_items[rec.item] = nil
    end
    local vol = r.GetMediaItemInfo_Value(rec.item, "D_VOL")
    if math.abs(vol - rec.base_vol) > 1e-9 then
      vol_items[rec.item] = { set_vol = vol, vol = rec.base_vol }
    else
      vol_items[rec.item] = nil
    end
  end
  for _, g in ipairs(S.groups) do
    for _, s in ipairs(g.shots) do
      note(s)
      for _, k in ipairs(s.kids) do note(k) end
    end
  end
  save_tabs()
  local applied = P.rpm
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
-- ACCENT COLOR
------------------------------------------------------------------------------------------------

local function accent_rgb() return accent or ACCENT_DEFAULT end
-- Lighter (f > 0) or darker (f < 0) version of a 0xRRGGBB color.
local function shade(rgb, f)
  local function ch(v)
    v = f >= 0 and (v + (255 - v) * f) or (v * (1 + f))
    return math.max(0, math.min(255, math.floor(v + 0.5)))
  end
  return (ch((rgb >> 16) & 0xFF) << 16) | (ch((rgb >> 8) & 0xFF) << 8) | ch(rgb & 0xFF)
end
local function luminance(rgb)
  return (0.299 * ((rgb >> 16) & 0xFF) + 0.587 * ((rgb >> 8) & 0xFF) + 0.114 * (rgb & 0xFF)) / 255
end
local function rgba(rgb, a) return (rgb << 8) | (a or 0xFF) end

-- Accent on checkmarks and slider grabs; pushed around the whole window. Returns the pop count.
local function push_accent()
  local a = accent_rgb()
  ImGui.PushStyleColor(ctx, ImGui.Col_CheckMark, rgba(shade(a, 0.35)))
  ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrab, rgba(shade(a, 0.1)))
  ImGui.PushStyleColor(ctx, ImGui.Col_SliderGrabActive, rgba(shade(a, 0.3)))
  return 3
end

-- Accent-colored button (Apply). Returns the pop count.
local function push_accent_button()
  local a = accent_rgb()
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, rgba(a))
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, rgba(shade(a, 0.15)))
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, rgba(shade(a, -0.2)))
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, luminance(a) > 0.62 and 0x111111FF or 0xFFFFFFFF)
  return 4
end

-- Slider with the accent: grab in the accent color and the part left of the grab filled with it.
local function accent_slider(id, v, lo, hi, fmt)
  local changed, nv = ImGui.SliderDouble(ctx, id, v, lo, hi, fmt)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local x2, y2 = ImGui.GetItemRectMax(ctx)
  local t = math.max(0, math.min(1, (nv - lo) / (hi - lo)))
  if t > 0 and x2 > x1 then
    local fx = x1 + (x2 - x1) * t
    ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx), x1, y1, fx, y2,
      rgba(accent_rgb(), 0x55), UI.FRAME_ROUNDING)
  end
  return changed, nv
end

------------------------------------------------------------------------------------------------
-- WINDOW PARTS
------------------------------------------------------------------------------------------------

local close_clicked = false
local win_docked = false
local open_look = false

local function draw_gear(dl, x1, y1, size, col)
  local cx, cy = x1 + size / 2, y1 + size / 2
  local ro, ri = size * 0.34, size * 0.255
  local th = math.max(1.2, size * 0.065)
  local step = math.pi / 4
  for i = 0, 7 do
    local a = i * step - math.pi / 2
    local pts = { { ri, a - 0.27 }, { ro, a - 0.17 }, { ro, a + 0.17 }, { ri, a + 0.27 } }
    for _, pt in ipairs(pts) do
      ImGui.DrawList_PathLineTo(dl, cx + math.cos(pt[2]) * pt[1], cy + math.sin(pt[2]) * pt[1])
    end
  end
  ImGui.DrawList_PathStroke(dl, col, ImGui.DrawFlags_Closed, th)
  ImGui.DrawList_AddCircle(dl, cx, cy, size * 0.115, col, 0, th)
end

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

-- Floating window: big bold title on the left; status, gear, ? and X on the right, drawn over the
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
  x = x - gap - size
  ImGui.SetCursorScreenPos(ctx, x, wy + m)
  if title_icon_button("##look_t", size, draw_gear) then open_look = true end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Accent color") end
  title_status(x - gap * 2, wy + m, size)
  local big = UI.title_font and pcall(ImGui.PushFont, ctx, UI.title_font)
  local _, th = ImGui.CalcTextSize(ctx, "GunKit RPM")
  draw_title(ImGui.GetWindowDrawList(ctx), wx + m + 12, wy + m + (size - th) / 2 + 3,
    UI.look.title or ImGui.GetColor(ctx, ImGui.Col_Text), "GunKit RPM")
  if big then ImGui.PopFont(ctx) end
  ImGui.PopClipRect(ctx)
end

-- Docked (no title bar): status, gear and ? on one row at the top, right-aligned.
local function docked_header()
  local size = ImGui.GetFrameHeight(ctx)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local aw = ImGui.GetContentRegionAvail(ctx)
  local gap = 6
  title_status(x0 + aw - 2 * size - gap * 3, y0, size)
  ImGui.SetCursorScreenPos(ctx, x0 + aw - 2 * size - gap, y0)
  if title_icon_button("##look_d", size, draw_gear) then open_look = true end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Accent color") end
  ImGui.SetCursorScreenPos(ctx, x0 + aw - size, y0)
  if title_icon_button("##guide_d", size, draw_question) then open_url(UI.GUIDE_URL) end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Open the GunKit RPM guide on GitHub") end
end

-- Gear popup: the accent color.
local function look_popup()
  if open_look then ImGui.OpenPopup(ctx, "look"); open_look = false end
  if ImGui.BeginPopup(ctx, "look") then
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, "Accent color")
    ImGui.SameLine(ctx)
    local ch, rgb = ImGui.ColorEdit3(ctx, "##accent", accent_rgb(),
      ImGui.ColorEditFlags_NoInputs | ImGui.ColorEditFlags_NoAlpha)
    if ch then accent = rgb; save_accent() end
    tip("Apply button, sliders, checkmarks and volume bars.")
    ImGui.SameLine(ctx)
    local is_default = accent == nil -- decided once for the Begin/EndDisabled pair
    if is_default then ImGui.BeginDisabled(ctx) end
    if ImGui.Button(ctx, "Reset") then accent = nil; save_accent() end
    if is_default then ImGui.EndDisabled(ctx) end
    ImGui.EndPopup(ctx)
  end
end

------------------------------------------------------------------------------------------------
-- PRESET TABS
------------------------------------------------------------------------------------------------

local tab_select_pending = true
local tab_edit, tab_edit_text, open_tab_edit = nil, "", false

local TAB_COLS = {
  { imgui_const("Col_Tab"), 0xA0 },
  { imgui_const("Col_TabHovered"), 0xE0 },
  { imgui_const("Col_TabSelected", "Col_TabActive"), 0xFF },
  { imgui_const("Col_TabDimmed", "Col_TabUnfocused"), 0x80 },
  { imgui_const("Col_TabDimmedSelected", "Col_TabUnfocusedActive"), 0xD0 },
}
local function push_tab_color(rgb)
  if not rgb then return 0 end
  local n = 0
  for _, c in ipairs(TAB_COLS) do
    if c[1] then ImGui.PushStyleColor(ctx, c[1], (rgb << 8) | c[2]); n = n + 1 end
  end
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, luminance(rgb) > 0.62 and 0x111111FF or 0xFFFFFFFF)
  return n + 1
end

-- Show tab i: its options become the live ones and (if shots are selected) the timeline previews them.
local function show_tab(i)
  tabs.active = i
  P = tabs.list[i].s
  tab_select_pending = true
  save_tabs()
  if S.n_shots > 0 then preview() end
end

local function new_tab_name(base)
  local used = {}
  for _, t in ipairs(tabs.list) do used[t.name:lower()] = true end
  if base and not used[base:lower()] then return base end
  local n = base and 2 or #tabs.list + 1
  local function name(k) return base and (base .. " " .. k) or ("Preset " .. k) end
  while used[name(n):lower()] do n = n + 1 end
  return name(n)
end

local function add_tab(from, at, name)
  local src = tabs.list[from]
  local tab = { id = tabs.next_id, name = name, color = src.color, s = copy_set(src.s) }
  tabs.next_id = tabs.next_id + 1
  table.insert(tabs.list, at, tab)
  if at <= tabs.active then tabs.active = tabs.active + 1 end
  show_tab(at)
end

local function close_tab(i)
  if #tabs.list < 2 or not tabs.list[i] then return end
  table.remove(tabs.list, i)
  if i == tabs.active then
    show_tab(math.min(i, #tabs.list))
  else
    if i < tabs.active then tabs.active = tabs.active - 1 end
    tab_select_pending = true
    save_tabs()
  end
end

local function move_tab(i, d)
  local j = i + d
  if not tabs.list[i] or not tabs.list[j] then return end
  tabs.list[i], tabs.list[j] = tabs.list[j], tabs.list[i]
  if tabs.active == i then tabs.active = j elseif tabs.active == j then tabs.active = i end
  -- ImGui keeps a tab bar's order once tabs exist; new ids make it lay them out in our order.
  for _, k in ipairs({ i, j }) do tabs.list[k].id = tabs.next_id; tabs.next_id = tabs.next_id + 1 end
  tab_select_pending = true
  save_tabs()
end

local function section_tabs()
  local action
  if ImGui.BeginTabBar(ctx, "presets", ImGui.TabBarFlags_FittingPolicyScroll) then
    for i, tab in ipairs(tabs.list) do
      local flags = (tab_select_pending and i == tabs.active) and ImGui.TabItemFlags_SetSelected or ImGui.TabItemFlags_None
      local pushed = push_tab_color(tab.color)
      local sel = ImGui.BeginTabItem(ctx, tab.name .. "###tab" .. tab.id, nil, flags)
      if pushed > 0 then ImGui.PopStyleColor(ctx, pushed) end
      if ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then action = { "edit", i } end
      if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) then action = { "edit", i } end
      if sel then
        -- While a switch is pending ImGui may still report the old tab for a frame: ignore it.
        if i == tabs.active then tab_select_pending = false
        elseif not tab_select_pending then action = action or { "show", i } end
        ImGui.EndTabItem(ctx)
      end
    end
    if ImGui.TabItemButton(ctx, "+", ImGui.TabItemFlags_Trailing | ImGui.TabItemFlags_NoTooltip) then action = { "add" } end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "New preset, starting as a copy of this one.\n" ..
        "Each tab keeps its own rate, trim and volume settings.\nRight-click or double-click a tab to rename, color, duplicate, reorder or close it.")
    end
    ImGui.EndTabBar(ctx)
  end

  if action then
    local a, i = action[1], action[2]
    if a == "show" then show_tab(i)
    elseif a == "add" then add_tab(tabs.active, #tabs.list + 1, new_tab_name())
    elseif a == "edit" then tab_edit, tab_edit_text = tabs.list[i], tabs.list[i].name; open_tab_edit = true end
  end

  -- Tab popup: color, name, close; reset color, duplicate, order.
  if open_tab_edit then ImGui.OpenPopup(ctx, "tabedit"); open_tab_edit = false end
  if ImGui.BeginPopup(ctx, "tabedit") then
    local i
    for k, t in ipairs(tabs.list) do if t == tab_edit then i = k end end
    if not i then ImGui.CloseCurrentPopup(ctx)
    else
      local tab = tab_edit
      local default_rgb = 0x3C3C3C
      local ch, rgb = ImGui.ColorEdit3(ctx, "##tabcolor", tab.color or default_rgb,
        ImGui.ColorEditFlags_NoInputs | ImGui.ColorEditFlags_NoAlpha)
      if ch then tab.color = rgb; save_tabs() end
      tip("Tab color")
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, 180)
      if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
      ch, tab_edit_text = ImGui.InputText(ctx, "##tabeditname", tab_edit_text)
      if ch then
        local name = tab_edit_text:match("^%s*(.-)%s*$")
        if name ~= "" then tab.name = name; save_tabs() end
      end
      local enter = ImGui.IsItemDeactivatedAfterEdit(ctx) and ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
      ImGui.SameLine(ctx)
      local can_close = #tabs.list > 1 -- decided once for the Begin/EndDisabled pair
      if not can_close then ImGui.BeginDisabled(ctx) end
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x8E2A2AFF)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0xB23636FF)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x6E1F1FFF)
      local close_clicked_tab = ImGui.Button(ctx, "Close tab")
      ImGui.PopStyleColor(ctx, 3)
      if not can_close then ImGui.EndDisabled(ctx) end
      if close_clicked_tab and can_close then close_tab(i); ImGui.CloseCurrentPopup(ctx) end

      local no_color = not tab.color -- decided once: Reset clears it
      if no_color then ImGui.BeginDisabled(ctx) end
      if ImGui.Button(ctx, "Reset color") then tab.color = nil; save_tabs() end
      if no_color then ImGui.EndDisabled(ctx) end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Duplicate") then
        add_tab(i, i + 1, new_tab_name(tab.name .. " copy")); ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      ImGui.AlignTextToFramePadding(ctx)
      dim("Order:")
      ImGui.SameLine(ctx)
      local first, last = i == 1, i == #tabs.list -- decided once
      if first then ImGui.BeginDisabled(ctx) end
      local left = ImGui.ArrowButton(ctx, "##tableft", ImGui.Dir_Left)
      if first then ImGui.EndDisabled(ctx) end
      ImGui.SameLine(ctx)
      if last then ImGui.BeginDisabled(ctx) end
      local right = ImGui.ArrowButton(ctx, "##tabright", ImGui.Dir_Right)
      if last then ImGui.EndDisabled(ctx) end
      if left and not first then move_tab(i, -1) elseif right and not last then move_tab(i, 1) end
      if enter then ImGui.CloseCurrentPopup(ctx) end
    end
    ImGui.EndPopup(ctx)
  end
end

------------------------------------------------------------------------------------------------
-- RATE AND VOLUME
------------------------------------------------------------------------------------------------

-- Label in a fixed first column (wide enough for the longest label).
local function form_label(text, col_w)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, text)
  ImGui.SameLine(ctx, col_w)
end
local function label_col() return math.floor(ImGui.CalcTextSize(ctx, "Rounds/min") + ImGui.GetFontSize(ctx) * 1.2) end

-- Something changed an option: save it and update the preview.
local function option_changed()
  save_tabs()
  if S.n_shots > 0 then preview() end
end

local function section_rate()
  section_title("Rate")
  if S.n_shots == 0 then
    dim("Select the folder items to respace.")
  else
    local what = S.folder and "folder item" or "item"
    ImGui.Text(ctx, string.format("%d %s%s%s", S.n_shots, what, S.n_shots == 1 and "" or "s",
      S.n_tracks > 1 and string.format(" on %d tracks", S.n_tracks) or ""))
    if S.dirty then
      tip("Selection is locked while previewing. Apply or Revert to pick other items.")
    elseif S.now_rpm then
      ImGui.SameLine(ctx)
      dim(string.format("(now %.0f RPM)", S.now_rpm))
      tip("The rate the selected shots are at right now. Nothing moves until you change something.")
    end
  end
  ImGui.Dummy(ctx, 0, 2)

  local col = label_col()
  local field_w = math.floor(ImGui.GetFontSize(ctx) * 4.5)
  local sp_x = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)

  form_label("Rounds/min", col)
  ImGui.SetNextItemWidth(ctx, -(field_w + sp_x))
  local changed, v = accent_slider("##rpm", P.rpm, SLIDER_MIN, SLIDER_MAX, "%.0f RPM")
  if changed then P.rpm = math.max(RPM_MIN, math.min(RPM_MAX, v)); option_changed() end
  tip("Drag to change the rate; the timeline follows live. Ctrl+click to type any value.")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, field_w)
  if not S.typing then S.typed = P.rpm end
  local _, tv = ImGui.InputDouble(ctx, "##rpmtyped", S.typed, 0, 0, "%.1f")
  S.typed = tv
  S.typing = ImGui.IsItemActive(ctx)
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then
    P.rpm = math.max(RPM_MIN, math.min(RPM_MAX, S.typed)); option_changed()
  end
  tip(string.format("Type a rate (%d to %d) and press Enter.", RPM_MIN, RPM_MAX))

  form_label("Spacing", col)
  ImGui.Text(ctx, string.format("%.1f ms", 60000 / P.rpm))
  tip("Start-to-start time between shots.")

  ImGui.Dummy(ctx, 0, 4)
  local c1, t = ImGui.Checkbox(ctx, "Trim so shots don't overlap", P.trim)
  if c1 then P.trim = t; option_changed() end
  tip("When the spacing is shorter than a shot, cut each shot (and its child items) where the next one starts.")
  local trim_on = P.trim -- decided once for the Begin/EndDisabled pair
  if not trim_on then ImGui.BeginDisabled(ctx) end
  ImGui.Indent(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, "Fade on cut")
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, field_w)
  local _, fv = ImGui.InputDouble(ctx, "##fade", P.fade_ms, 0, 0, "%.0f")
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then
    P.fade_ms = math.max(0, math.min(500, fv)); option_changed()
  end
  tip("Fade-out on each trimmed end so the cut doesn't click. 0 = no fade.")
  ImGui.SameLine(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  dim("ms")
  ImGui.Unindent(ctx)
  if not trim_on then ImGui.EndDisabled(ctx) end

  if S.last_msg then
    ImGui.Dummy(ctx, 0, 2)
    ImGui.TextColored(ctx, UI.COLOR_OK, S.last_msg)
  end
end

-- Bars showing each shot's volume (for the largest group, or 12 sample shots with none selected).
local function volume_graph(h)
  local n = 12
  local g_rnd
  for _, g in ipairs(S.groups) do
    if not g_rnd or #g.shots > #g_rnd then g_rnd = g.shots end
  end
  if g_rnd and #g_rnd >= 2 then n = math.min(#g_rnd, 64) end
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  ImGui.Dummy(ctx, w, h)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, 0x222222FF, UI.FRAME_ROUNDING)
  local lo, hi = -36, 12
  local function y_of(db) return y0 + h - 3 - (h - 6) * (math.max(lo, math.min(hi, db)) - lo) / (hi - lo) end
  ImGui.DrawList_AddLine(dl, x0 + 4, y_of(0), x0 + w - 4, y_of(0), 0x3A3A3AFF, 1) -- 0 dB line
  local a = accent_rgb()
  local on = P.vol
  local pad = 6
  local bw = (w - pad * 2) / n
  for i = 1, n do
    local t = n > 1 and (i - 1) / (n - 1) or 0
    local rnd = g_rnd and g_rnd[i] and g_rnd[i].rnd or 0
    local db = on and shape_db(t, rnd) or 0
    local bx = x0 + pad + (i - 1) * bw
    ImGui.DrawList_AddRectFilled(dl, bx + 1, y_of(db), bx + math.max(2, bw - 2), y0 + h - 3,
      rgba(on and shade(a, 0.1) or 0x555555, on and 0xFF or 0x90), 2)
  end
  if ImGui.IsItemHovered(ctx) then
    local mx = ImGui.GetMousePos(ctx)
    local i = math.max(1, math.min(n, math.floor((mx - x0 - pad) / bw) + 1))
    local t = n > 1 and (i - 1) / (n - 1) or 0
    local rnd = g_rnd and g_rnd[i] and g_rnd[i].rnd or 0
    ImGui.SetTooltip(ctx, string.format("Shot %d: %+.1f dB", i, on and shape_db(t, rnd) or 0))
  end
end

local function db_slider(label, key, lo, hi, col, help)
  form_label(label, col)
  ImGui.SetNextItemWidth(ctx, -1)
  local ch, v = accent_slider("##" .. key, P[key], lo, hi, key == "vol_curve" and "%.2f" or "%+.1f dB")
  if ch then P[key] = v; option_changed() end
  tip(help .. "\nCtrl+click to type a value.")
end

local function section_volume()
  section_title("Volume")
  local c, v = ImGui.Checkbox(ctx, "Shape the volume across the burst", P.vol)
  if c then P.vol = v; option_changed() end
  tip("Sets each shot's volume from Start (first shot) to End (last shot).\nFolder items: the gain goes on their child items.")
  local on = P.vol -- decided once for the Begin/EndDisabled pair
  if not on then ImGui.BeginDisabled(ctx) end
  local col = label_col()
  db_slider("Start", "vol_start", -24, 6, col, "Volume of the first shot.")
  db_slider("End", "vol_end", -24, 6, col, "Volume of the last shot.")
  db_slider("Curve", "vol_curve", -1, 1, col,
    "Bends the line from Start to End.\nAbove 0: holds near Start, then drops late.\nBelow 0: moves toward End right away.")
  db_slider("Random", "vol_rand", 0, 6, col, "Each shot gets up to this much extra up or down, so the burst sounds less mechanical.")
  if not on then ImGui.EndDisabled(ctx) end
  ImGui.Dummy(ctx, 0, 2)
  local _, avail_h = ImGui.GetContentRegionAvail(ctx)
  volume_graph(math.max(40, math.min(110, avail_h - 4)))
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

-- Play / stop button: a real transport icon drawn on a normal button.
local function transport_button(playing, w, h)
  local clicked = ImGui.Button(ctx, "##play", w, h)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local x2, y2 = ImGui.GetItemRectMax(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
  local s = math.floor((y2 - y1) * 0.36)
  local col = ImGui.GetColor(ctx, ImGui.Col_Text)
  if playing then
    ImGui.DrawList_AddRectFilled(dl, cx - s * 0.75, cy - s * 0.75, cx + s * 0.75, cy + s * 0.75, col, 2)
  else
    ImGui.DrawList_AddTriangleFilled(dl, cx - s * 0.7, cy - s, cx - s * 0.7, cy + s, cx + s, cy, col)
  end
  return clicked
end

-- Bottom row: accent Apply on the left, then Revert and Play.
local function footer()
  local can_apply = S.dirty and S.n_shots > 0 -- worked out once for the pairs below
  local sp_x = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
  local small_w = math.floor(ImGui.GetFontSize(ctx) * 6)
  local play_w = UI.APPLY_H + 16
  local avail = ImGui.GetContentRegionAvail(ctx)
  local apply_w = math.max(80, avail - small_w - play_w - 2 * sp_x)

  local pushed = 0
  if can_apply then pushed = push_accent_button() else ImGui.BeginDisabled(ctx) end
  local apply_clicked = ImGui.Button(ctx, "Apply##apply", apply_w, UI.APPLY_H)
  if can_apply then ImGui.PopStyleColor(ctx, pushed) else ImGui.EndDisabled(ctx) end
  if apply_clicked and can_apply then S.apply_queued = true end
  if S.n_shots == 0 then tip("Select some folder items first.")
  elseif not S.dirty then tip("Change something first; the timeline previews it, then Apply keeps it.")
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
  local play_clicked = transport_button(playing, play_w, UI.APPLY_H)
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
  tip(playing and "Stop" or "Play from the first shot. Keep changing settings while it plays.")
end

------------------------------------------------------------------------------------------------
-- MAIN WINDOW
------------------------------------------------------------------------------------------------

local function loop_body()
  ImGui.SetNextWindowSize(ctx, 720, 400, ImGui.Cond_FirstUseEver)
  ImGui.SetNextWindowSizeConstraints(ctx, 600, 360, 4000, 4000)
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
  local accent_n = push_accent()
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
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_GrabMinSize, 14) -- a wider slider grab
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

    section_tabs()

    local _, sp_y = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
    local footer_h = UI.APPLY_H + sp_y
    local avail_w = ImGui.GetContentRegionAvail(ctx)
    local left_w = math.floor(avail_w * 0.52)
    if ImGui.BeginChild(ctx, "rate", left_w, -footer_h, ImGui.ChildFlags_Border) then
      section_rate()
      ImGui.EndChild(ctx)
    end
    ImGui.SameLine(ctx)
    if ImGui.BeginChild(ctx, "volume", 0, -footer_h, ImGui.ChildFlags_Border) then
      section_volume()
      ImGui.EndChild(ctx)
    end
    footer()
    look_popup()

    if not win_docked then title_bar() end
    ImGui.PopStyleVar(ctx, 1)
    if round_n > 0 then ImGui.PopStyleVar(ctx, round_n) end
    ImGui.End(ctx)
  end
  ImGui.PopStyleVar(ctx, 3)
  ImGui.PopStyleColor(ctx, 4 + theme_n + accent_n)
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
  save_tabs()
end

local function loop()
  watch_selection()
  local open = loop_body()
  -- Apply / Revert run between frames, never inside the ImGui window.
  if S.apply_queued then S.apply_queued = false; apply() end
  if S.revert_queued then S.revert_queued = false; revert() end
  if open then r.defer(loop) else finish() end
end

r.atexit(finish)
capture()
r.defer(loop)
