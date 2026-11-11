-- @description Wwise Tool (send REAPER audio to Wwise)
-- @author Jay Sabins
-- @version 1.13.4
-- @changelog
--   New Loop column in the preview, like Streaming: click a Sound or container (or
--   pick many rows with drag, Shift+click or Ctrl+click) and choose Loop (infinite),
--   No loop or Auto (leave it as Wwise or the template has it). Written after
--   property templates. Settings tab "Streaming" is now "Stream & loop" and has
--   Clear loop overrides.
-- @provides
--   [main] jsabins_Wwise Tool - Quick send.lua
--   [nomain] jsabins_WwiseTool_core.lua
-- @about
--   # Wwise Tool
--
--   Send audio from REAPER straight into Wwise. Built with Lua and ReaImGui.
--
--   - Source: the selected items, or whatever REAPER's render settings produce
--     (regions, stems, region matrix...).
--   - Import destination: type a Wwise path or grab the Wwise selection.
--   - Hierarchy mapping: build Wwise containers above each Sound
--     (Actor-Mixers, Random/Sequence/Switch/Blend Containers, Virtual Folders,
--     Work Units) named with REAPER wildcards like $region, $track, $item.
--   - Property templates per level, Sound SFX or Sound Voice (with language),
--     Originals subfolder (wildcards allowed).
--   - Conflict handling, structure and settings presets, live preview (new vs existing objects),
--     transfer summary. One Wwise undo step per transfer.
--   - Auto mono/stereo: a Sound whose left and right match is made mono
--     (also for folder items). Click the preview's Channels column to force
--     Mono or Stereo for a Sound or a whole container, or drag/Shift/Ctrl+click
--     to set many rows at once.
--   - Streaming: turn on Stream per Sound or container from the preview's
--     Streaming column, or automatically for Sounds longer than a set length.
--   - Loop: set Sounds to loop (infinite) from the preview's Loop column.
--   - Fast: untouched WAV items import without rendering; edited items render
--     in one pass; everything is imported in one Wwise call.
--
--   "Wwise Tool - Quick send" sends the selected items with the window's
--   last settings, without opening the window. Give it a shortcut.
--
--   Needs ReaImGui (ReaPack > ReaTeam Extensions) and Wwise with WAAPI on:
--   Wwise > Project > User Preferences > Enable Wwise Authoring API (HTTP port 8090).
--
--   Full guide: https://github.com/jaysabins/reascripts/blob/main/Wwise/jsabins_Wwise%20Tool_README.md
--
--   Not affiliated with or endorsed by Audiokinetic. Wwise is a trademark of Audiokinetic Inc.

local r = reaper
local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or ""
local core = dofile(script_dir .. "jsabins_WwiseTool_core.lua")

if not r.ImGui_GetBuiltinPath then
  r.ShowMessageBox("This script needs ReaImGui.\nInstall it from Extensions > ReaPack > Browse packages (search \"ReaImGui\"), then restart REAPER.",
    "Wwise Tool", 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. "/?.lua"
local ImGui = require "imgui" "0.9"

local ctx = ImGui.CreateContext("Wwise Tool")

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local S = core.load_settings()
core.http_port = S.http_port
-- Look of the window (same in every project): background opacity, hidden preview columns,
-- type colors and the unit the preview's Initial delay column shows ("s" or "ms").
local view = { opacity = 1.0, hidden = {}, colors = {}, delay_unit = "s" }
do
  local v = r.GetExtState(core.EXT, "view")
  local ok, t = pcall(core.json.decode, v ~= "" and v or "{}")
  if ok and type(t) == "table" then
    if type(t.opacity) == "number" then view.opacity = math.max(0.2, math.min(1, t.opacity)) end
    if type(t.hidden) == "table" then for k, b in pairs(t.hidden) do if b == true then view.hidden[k] = true end end end
    if type(t.colors) == "table" then
      for k, c in pairs(t.colors) do if type(c) == "number" then view.colors[k] = math.floor(c) end end
    end
    if t.delay_unit == "ms" then view.delay_unit = "ms" end
    if type(t.size_v) == "number" then view.size_v = t.size_v end
  end
end
local function save_view() r.SetExtState(core.EXT, "view", core.json.encode(view), true) end
local view_dirty = false -- type colors changed; saved once the color picker is let go

-- Initial delay as text, in the unit chosen in Settings (or by right-clicking the column).
local DELAY_UNITS = { { "s", "Seconds (0.042 s)" }, { "ms", "Milliseconds (42 ms)" } }
local function delay_text(sec)
  if view.delay_unit == "ms" then return string.format("%.0f ms", sec * 1000) end
  return string.format("%.3f s", sec)
end
local open_delay_menu = false
local conn, conn_err = nil, nil
local plan = { entries = {}, errors = {} }
-- Two kinds of presets: the Wwise structure only, and the rest of the settings.
local presets = { structure = core.load_presets("structure"), settings = core.load_presets("settings") }
local preset_name = { structure = "", settings = "" }
local selected_row = 0           -- the Wwise structure level that Remove / Move act on (0 = none)
local summary = nil
local status_line = ""
local last_sig, last_check, sel_poll_at = nil, 0, 0
local was_focused = true
-- The preview never waits on Wwise longer than this (seconds); if Wwise is busy it retries later.
local PREVIEW_TIMEOUT, RETRY_DELAY = 1.5, 5
local retry_at = nil
local quiet_until = 0
-- What the preview knows exists in Wwise under known_dest (lowercase path -> id, or false).
local known_existing, known_dest = {}, nil
local function forget_existing() known_existing = {} end
local wwise_sel_path = nil
local dirty_settings = false
local open_summary = false
local open_settings = false

local COLOR_OK = 0x6BCB77FF
local COLOR_BAD = 0xFF6B6BFF
local COLOR_DIM = 0x9A9A9AFF
local COLOR_NEW = 0x6BCB77FF     -- green: will be created
local COLOR_EXISTS = 0xF5A524FF  -- orange: already in Wwise

local WILDCARDS = {
  { "$region", "Region name" }, { "$regionnumber", "Region number" }, { "$marker", "Marker before the item/region" },
  { "$track", "Track name" }, { "$parenttrack", "Parent (folder) track name" }, { "$folders", "All parent folder names" },
  { "$item", "Item (take) name" }, { "$itemnumber", "Item number on track" }, { "$project", "Project name" },
  { "$tempo", "Tempo" }, { "$timesig", "Time signature" }, { "$date", "Date" }, { "$author", "Project author" },
}

-- Connecting runs in the background (see start_connect) with a short timeout per call,
-- so opening the window never waits on Wwise and a busy Wwise can't freeze REAPER.
local CONNECT_TIMEOUT = 3
local connecting, reconnect_at = false, nil
local function connect()
  core.http_port = S.http_port
  local code
  conn, conn_err, code = core.connect(CONNECT_TIMEOUT)
  -- Busy (e.g. still loading a project): try again in a few seconds.
  reconnect_at = (not conn and code == "busy") and (r.time_precise() + 5) or nil
  if conn and S.destination == "" then S.destination = conn.root .. "\\Default Work Unit" end
  if conn and S.leaf.voice and S.leaf.language == "" and conn.languages[1] then S.leaf.language = conn.languages[1] end
  forget_existing()
  last_sig = nil
end

local function settings_changed() dirty_settings = true; last_sig = nil end

local function current_destination()
  if S.use_wwise_selection then return wwise_sel_path or "" end
  return S.destination
end

----------------------------------------------------------------------
-- Preview refresh (only when something relevant changes)
----------------------------------------------------------------------
local function signature()
  local n = r.CountSelectedMediaItems(0)
  local first = n > 0 and tostring(r.GetSelectedMediaItem(0, 0)) or ""
  local last = n > 0 and tostring(r.GetSelectedMediaItem(0, n - 1)) or ""
  return table.concat({ r.GetProjectStateChangeCount(0), n, first, last, core.json.encode(S), current_destination(),
                        tostring(r.EnumProjects(-1)) }, "|")
end

----------------------------------------------------------------------
-- Diagnostics: a log of slow moments (frames where this script worked for a
-- long time, or where REAPER didn't run the script for a while).
----------------------------------------------------------------------
local slow_log, frame_notes = {}, {}
local last_frame_end, last_transfer_end = nil, nil
local function note(text) frame_notes[#frame_notes + 1] = text end
do
  local waapi = core.waapi
  core.waapi = function(uri, args, options, timeout)
    local t = r.time_precise()
    local a, b, c = waapi(uri, args, options, timeout)
    note(string.format("%s %.0fms%s", uri:gsub("^ak%.wwise%.", ""), (r.time_precise() - t) * 1000,
      a and "" or (" (" .. tostring(type(c) == "string" and c or "error") .. ")")))
    return a, b, c
  end
end

-- Objects our own transfer just selected in Wwise ("Select imported Sounds in Wwise").
-- That selection must not become the next import destination.
local imported_paths = {}
local function own_selection(o)
  return type(o) == "table" and o.path and imported_paths[o.path:lower()] or false
end

-- Work runs in coroutines so it can be spread across frames. WAAPI calls use the hidden,
-- blocking curl path: the non-blocking path flashes a console window on Windows.
local bg_task, transfer_task = nil, nil

local function run_task(task)
  if not task then return nil end
  local ok, err = coroutine.resume(task)
  if not ok then status_line = "Error: " .. tostring(err); connecting = false; return nil end
  if coroutine.status(task) == "dead" then return nil end
  return task
end

-- Connect without blocking the window: the first frame is drawn before any WAAPI call.
local function start_connect()
  connecting = true
  bg_task = coroutine.create(function()
    coroutine.yield()
    connect()
    connecting = false
  end)
end

local function refresh_job(poll_selection, sig)
  return coroutine.create(function()
    if poll_selection then
      local p, _, x = core.wwise_selection_path(PREVIEW_TIMEOUT)
      if x ~= "busy" and not own_selection(x) and p ~= wwise_sel_path then wwise_sel_path = p end
    end
    local s2 = core.json.decode(core.json.encode(S))
    s2.destination = current_destination()
    local tb = r.time_precise()
    local newplan = core.build_plan(s2, conn)
    note(string.format("read project %.0fms (%d Sounds)", (r.time_precise() - tb) * 1000, #newplan.entries))
    local after = signature()
    if conn and newplan.destination ~= "" then
      if known_dest ~= newplan.destination then known_existing, known_dest = {}, newplan.destination end
      local _, err = core.mark_existing(newplan, PREVIEW_TIMEOUT, known_existing)
      if err == "offline" then conn = nil; conn_err = "Lost connection to Wwise."
      elseif err == "busy" then
        status_line = "Wwise is busy, the preview will update in a moment."
        retry_at = r.time_precise() + RETRY_DELAY
      elseif status_line:find("^Wwise is busy") then status_line = "" end
    end
    if s2.set_initial_delay then newplan.delays, newplan.delay_warnings = core.layer_delays(newplan, s2) end
    newplan.tree = core.build_tree(newplan, s2, conn)
    plan = newplan
    if sig then last_sig = after end -- building the plan can bump REAPER's change counter
  end)
end

local function refresh_preview(force)
  if transfer_task then return end
  if bg_task then bg_task = run_task(bg_task); return end
  local now = r.time_precise()
  if not conn and reconnect_at and now >= reconnect_at then reconnect_at = nil; start_connect(); return end
  if retry_at and now >= retry_at then retry_at = nil; force = true end
  local poll = S.use_wwise_selection and conn and sel_poll_at and now >= sel_poll_at
  if poll then sel_poll_at = nil end
  if not force and not poll and now - last_check < 0.3 then return end
  last_check = now
  local sig = signature()
  if dirty_settings then core.save_settings(S); dirty_settings = false end
  if sig == last_sig and not force and not poll then return end
  if poll and sig == last_sig and not force then
    -- Only the Wwise selection might have changed: check it, rebuild only if it did.
    bg_task = coroutine.create(function()
      local p, _, x = core.wwise_selection_path(PREVIEW_TIMEOUT)
      if x == "busy" then sel_poll_at = r.time_precise() + RETRY_DELAY
      elseif not own_selection(x) and p ~= wwise_sel_path then wwise_sel_path = p; last_sig = nil end
    end)
  else
    last_sig = sig
    bg_task = refresh_job(poll, true) -- also read the Wwise selection if it was due
  end
  bg_task = run_task(bg_task)
end

----------------------------------------------------------------------
-- Widgets
----------------------------------------------------------------------
local function help(text)
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, "(?)")
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, text) end
end

local function combo(label, list, value, width)
  -- list entries: { value, label } or plain strings
  local idx, labels, values = 0, {}, {}
  for i, it in ipairs(list) do
    if type(it) == "table" then values[i], labels[i] = it[1], it[2] else values[i], labels[i] = it, it end
    if values[i] == value then idx = i - 1 end
  end
  if width then ImGui.SetNextItemWidth(ctx, width) end
  local changed, new = ImGui.Combo(ctx, label, idx, table.concat(labels, "\0") .. "\0")
  if changed then return true, values[new + 1] end
  return false, value
end

local function input(label, value, hint, width)
  if width then ImGui.SetNextItemWidth(ctx, width) end
  local changed, v
  if hint then changed, v = ImGui.InputTextWithHint(ctx, label, hint, value or "")
  else changed, v = ImGui.InputText(ctx, label, value or "") end
  if changed then settings_changed() end
  return v
end

local function wildcard_menu(id, apply)
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "$##wc" .. id) then ImGui.OpenPopup(ctx, "wcpop" .. id) end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Insert a REAPER wildcard") end
  if ImGui.BeginPopup(ctx, "wcpop" .. id) then
    for _, w in ipairs(WILDCARDS) do
      if ImGui.Selectable(ctx, w[1] .. "    " .. w[2]) then apply(w[1]); settings_changed() end
    end
    ImGui.EndPopup(ctx)
  end
end

local function from_wwise_button(id, apply)
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "From Wwise##" .. id) then
    local p, err = core.wwise_selection_path()
    if p then apply(p); settings_changed() else status_line = err or "" end
  end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Use the object selected in Wwise") end
end

----------------------------------------------------------------------
-- Sections
----------------------------------------------------------------------
local GUIDE_URL = "https://github.com/jaysabins/reascripts/blob/main/Wwise/jsabins_Wwise%20Tool_README.md"

-- Open a web page in the default browser. Uses SWS's CF_ShellExecute when it's there,
-- otherwise the OS's own opener (explorer.exe is a window app, so no console flashes).
local function open_url(url)
  if reaper.CF_ShellExecute then reaper.CF_ShellExecute(url); return end
  local os_name = reaper.GetOS()
  if os_name:match("^Win") then
    reaper.ExecProcess('explorer.exe "' .. url .. '"', -2)
  elseif os_name:match("^OSX") or os_name:match("^macOS") then
    reaper.ExecProcess('/usr/bin/open "' .. url .. '"', -2)
  else
    reaper.ExecProcess('xdg-open "' .. url .. '"', -2)
  end
end

-- Square button with a gear drawn on it (no icon font needed).
local function gear_button(id, size)
  local pressed = ImGui.Button(ctx, id, size, size)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local col = ImGui.GetColor(ctx, ImGui.Col_Text)
  local cx, cy = x1 + size / 2, y1 + size / 2
  local ring, thick = size * 0.20, size * 0.12
  local r_in, r_out, half_w = ring, size * 0.34, size * 0.075
  ImGui.DrawList_AddCircle(dl, cx, cy, ring, col, 0, thick)
  for i = 0, 7 do
    local a = i * math.pi / 4
    local dx, dy = math.cos(a), math.sin(a)
    local px, py = -dy * half_w, dx * half_w
    ImGui.DrawList_AddQuadFilled(dl,
      cx + dx * r_in + px, cy + dy * r_in + py,
      cx + dx * r_out + px, cy + dy * r_out + py,
      cx + dx * r_out - px, cy + dy * r_out - py,
      cx + dx * r_in - px, cy + dy * r_in - py, col)
  end
  return pressed
end

local function section_connection()
  -- Left: status dot, Wwise project and Wwise version. Right: "?" (opens the guide) and Settings (which also has Reconnect).
  -- A connection problem shows as a banner underneath.
  local lh = ImGui.GetFrameHeight(ctx)
  local dot = 8
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.DrawList_AddCircleFilled(dl, x + dot / 2, y + lh / 2, dot / 2, conn and COLOR_OK or COLOR_BAD)
  ImGui.Dummy(ctx, dot, lh)
  ImGui.SameLine(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  if conn then
    ImGui.Text(ctx, conn.project or "Wwise")
    if conn.project_path and ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, conn.project_path) end
    if (conn.version or "") ~= "" then ImGui.SameLine(ctx); ImGui.TextDisabled(ctx, conn.version) end
  elseif connecting then
    ImGui.TextDisabled(ctx, "Connecting to Wwise...")
  else
    ImGui.TextColored(ctx, COLOR_BAD, "Not connected")
  end

  local pad_x = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  local spacing = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
  local qw = ImGui.CalcTextSize(ctx, "?") + pad_x * 2
  local fh = ImGui.GetFrameHeight(ctx)
  local bw = qw + spacing + fh
  ImGui.SameLine(ctx)
  local avail = ImGui.GetContentRegionAvail(ctx)
  if avail > bw then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + avail - bw) end
  if ImGui.Button(ctx, "?") then open_url(GUIDE_URL) end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Open the Wwise Tool guide on GitHub") end
  ImGui.SameLine(ctx)
  if gear_button("##settings", fh) then open_settings = true end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Settings: connection (Reconnect), rendering, transfer and window") end

  if not conn and conn_err then
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, 0x2A2213FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Border, 0x4A3C1FFF)
    if ImGui.BeginChild(ctx, "connerr", 0, 0, ImGui.ChildFlags_Border | ImGui.ChildFlags_AutoResizeY) then
      ImGui.PushTextWrapPos(ctx, 0)
      ImGui.TextColored(ctx, 0xF3D6A0FF, conn_err)
      ImGui.TextColored(ctx, 0xF3D6A0FF, "When Wwise is ready, open Settings and click Reconnect.")
      ImGui.PopTextWrapPos(ctx)
      ImGui.EndChild(ctx)
    end
    ImGui.PopStyleColor(ctx, 2)
  end
end

-- Write the preview's initial delays to objects that already exist in Wwise (one undo step).
local function apply_delays_now()
  local todo, skipped = {}, 0
  local existing = plan.existing or {}
  for path, v in pairs(plan.delays or {}) do
    if existing[path:lower()] then todo[path] = v else skipped = skipped + 1 end
  end
  core.waapi("ak.wwise.core.undo.beginGroup")
  local n, err = core.apply_delays(todo)
  core.waapi("ak.wwise.core.undo.endGroup", { displayName = "Wwise Tool: set initial delays" })
  if err then status_line = "Couldn't set initial delays: " .. tostring(err)
  else
    status_line = string.format("Set Initial Delay on %d object%s.", n, n == 1 and "" or "s") ..
      (skipped > 0 and string.format(" %d not in Wwise yet (they get it when you transfer).", skipped) or "")
  end
end

local function dim_label(text) ImGui.TextColored(ctx, COLOR_DIM, text) end

-- "Presets..." button and popup for one kind of preset ("structure" or "settings").
local function presets_button(kind, label, tip)
  local list = presets[kind]
  local pop = "presets_" .. kind
  if ImGui.Button(ctx, label) then ImGui.OpenPopup(ctx, pop) end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, tip) end
  if ImGui.BeginPopup(ctx, pop) then
    ImGui.Text(ctx, "Load")
    local names = {}
    for n in pairs(list) do names[#names + 1] = n end
    table.sort(names)
    if #names == 0 then ImGui.TextDisabled(ctx, "  (no presets yet)") end
    for _, n in ipairs(names) do
      if ImGui.Selectable(ctx, "  " .. n, false, ImGui.SelectableFlags_DontClosePopups) then
        core.apply_preset(kind, S, list[n]); preset_name[kind] = n; settings_changed()
        if kind == "settings" then sel_poll_at = 0; forget_existing() end
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    ImGui.Separator(ctx)
    ImGui.SetNextItemWidth(ctx, 180)
    local _, v = ImGui.InputTextWithHint(ctx, "##pname", "preset name", preset_name[kind])
    preset_name[kind] = v
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Save") and v ~= "" then
      list[v] = core.preset_from(kind, S); core.save_presets(kind, list)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Delete") and list[v] then
      list[v] = nil; core.save_presets(kind, list)
    end
    ImGui.EndPopup(ctx)
  end
end

local function section_source()
  ImGui.SeparatorText(ctx, "Source")
  local changed
  changed, S.source = combo("##source", { { "items", "Selected items" }, { "render", "REAPER render settings (regions, stems, matrix...)" } }, S.source, -1)
  if changed then settings_changed() end
  if S.source == "render" then
    if ImGui.Button(ctx, "Render settings...") then r.Main_OnCommand(40015, 0) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Region matrix...") then r.Main_OnCommand(41888, 0) end
    ImGui.PushTextWrapPos(ctx, 0)
    dim_label("Files render where your render settings say, then import from there.")
    ImGui.PopTextWrapPos(ctx)
  end
  ImGui.Dummy(ctx, 0, 4)
end

-- Pick the Originals subfolder in a folder dialog that opens in the Wwise project's
-- Originals\SFX (or Voices\<language>) folder.
local function browse_originals()
  if not conn then status_line = "Connect to Wwise first, so its Originals folder can be found."; return end
  if S.leaf.voice and (S.leaf.language or "") == "" then status_line = "Pick a voice language first."; return end
  local orig = core.wwise_originals_dir(conn)
  if not orig then status_line = "Couldn't find the Wwise project's Originals folder."; return end
  local root = orig .. "\\" .. core.originals_root(S)
  local starts = { root, orig }
  local cur = S.originals_subfolder or ""
  if cur ~= "" and not cur:find("$", 1, true) then table.insert(starts, 1, root .. "\\" .. cur:gsub("/", "\\")) end
  local f, err = core.browse_folder("Choose the Originals subfolder. It must be inside " .. root, starts)
  if not f then if err then status_line = err end return end
  local rel = core.relative_to(f, root)
  if not rel then status_line = "Pick a folder inside " .. root .. ". Wwise keeps imported audio there."; return end
  S.originals_subfolder = rel
  status_line = ""
  settings_changed()
end

local function section_destination()
  ImGui.SeparatorText(ctx, "Wwise destination")
  local c
  c, S.use_wwise_selection = ImGui.Checkbox(ctx, "Always use the object selected in Wwise", S.use_wwise_selection)
  if c then settings_changed(); sel_poll_at = 0 end
  if S.use_wwise_selection then
    if ImGui.SmallButton(ctx, "Refresh##selpoll") then sel_poll_at = 0; forget_existing(); last_sig = nil end
    ImGui.SameLine(ctx)
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.Text(ctx, wwise_sel_path or "(nothing selected in Wwise)")
    ImGui.PopTextWrapPos(ctx)
  else
    S.destination = input("##dest", S.destination, "\\Containers\\Default Work Unit", -86)
    from_wwise_button("dest", function(p) S.destination = p end)
  end
  ImGui.Dummy(ctx, 0, 2)
  dim_label("Originals subfolder")
  S.originals_subfolder = input("##orig", S.originals_subfolder, "optional, e.g. Weapons\\$region", -96)
  wildcard_menu("orig", function(w) S.originals_subfolder = S.originals_subfolder .. w end)
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Browse##orig") then browse_originals() end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Pick a folder inside the Wwise project's Originals folder") end
  dim_label("If a Sound or container already exists")
  c, S.conflict = combo("##conflict", core.CONFLICT_OPS, S.conflict, -1)
  if c then settings_changed() end
  ImGui.Dummy(ctx, 0, 2)
  c, S.set_initial_delay = ImGui.Checkbox(ctx, "Set Initial Delay from layer timing", S.set_initial_delay)
  if c then settings_changed() end
  help("Select all your layers (e.g. every Muzzle and Tail item). Items that overlap in time\n" ..
    "count as one shot; each layer's Initial Delay is how far it starts after the\n" ..
    "shot's first item. Leave a gap between shots. The delays show in the preview.")
  if S.set_initial_delay then
    c, S.delay_target = combo("##delaytarget", core.DELAY_TARGETS, S.delay_target, -1)
    if c then settings_changed() end
    local n = 0
    for _ in pairs(plan.delays or {}) do n = n + 1 end
    local can = conn and n > 0
    if not can then ImGui.BeginDisabled(ctx) end
    if ImGui.Button(ctx, "Set delays on existing objects now") then apply_delays_now() end
    if not can then ImGui.EndDisabled(ctx) end
    if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
      ImGui.SetTooltip(ctx, "Write the delays to the objects that already exist in Wwise, without transferring audio.")
    end
  end
  ImGui.Dummy(ctx, 0, 4)
end

-- Default type colors. Users can pick their own in Settings > Type colors (stored in view.colors,
-- same in every project). Sound SFX, Sound Voice and Sound share the "Sound" color.
local DEFAULT_TYPE_COLORS = {
  ["Actor-Mixer"] = 0x7BD88FFF, ["Random Container"] = 0xF2A65AFF, ["Sequence Container"] = 0xE07FD0FF,
  ["Switch Container"] = 0x5FD3C8FF, ["Blend Container"] = 0xA070FFFF, ["Virtual Folder"] = 0xB0B0B0FF,
  ["Work Unit"] = 0xE0C060FF, ["Physical Folder"] = 0xB0B0B0FF, ["Sound"] = 0x6FA8FFFF,
  ["Destination"] = 0xC8C8C8FF,
}
local COLOR_TYPE_ORDER = { "Actor-Mixer", "Random Container", "Sequence Container", "Switch Container",
  "Blend Container", "Virtual Folder", "Work Unit", "Physical Folder", "Sound", "Destination" }
local COLOR_KEY = { ["Sound SFX"] = "Sound", ["Sound Voice"] = "Sound" }
local function type_color(t)
  local k = COLOR_KEY[t] or t
  return view.colors[k] or DEFAULT_TYPE_COLORS[k]
end
local TYPE_TAGS = {
  ["Destination"] = "[DEST]", ["Work Unit"] = "[WU]", ["Virtual Folder"] = "[VF]", ["Physical Folder"] = "[PF]",
  ["Actor-Mixer"] = "[AM]", ["Random Container"] = "[RND]", ["Sequence Container"] = "[SEQ]",
  ["Switch Container"] = "[SW]", ["Blend Container"] = "[BLD]", ["Sound SFX"] = "[SFX]", ["Sound Voice"] = "[VO]",
  ["Sound"] = "[SND]",
}
-- Color a Wwise structure row's fields (type dropdown, name, $ and ... buttons) with its type's
-- tag color instead of the default blue, the same colors as the preview's [RND], [SND]... tags.
local function with_alpha(c, a) return (c & 0xFFFFFF00) | a end
local function push_type_colors(t)
  local c = type_color(t)
  if not c then return 0 end
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, with_alpha(c, 0x50))
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, with_alpha(c, 0x70))
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, with_alpha(c, 0x90))
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, with_alpha(c, 0x60))
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, with_alpha(c, 0x80))
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, with_alpha(c, 0xA0))
  return 6
end
local row_tint = { type = nil, n = 0 }
local function push_row_colors(t) row_tint.type = t; row_tint.n = push_type_colors(t) end
local function pop_row_colors()
  if row_tint.n > 0 then ImGui.PopStyleColor(ctx, row_tint.n) end
  row_tint.type, row_tint.n = nil, 0
end

-- Clipboard icon (Wwise's "paste properties" look) drawn over a button, no icon font needed.
-- Dim outline when the level has no property template, amber and filled in when it has one.
local COLOR_TEMPLATE = 0xF5C542FF
local function template_button(id, has)
  local h = ImGui.GetFrameHeight(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local pressed = ImGui.Button(ctx, id, w > 0 and w or h, h)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local x2, y2 = ImGui.GetItemRectMax(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local col = has and COLOR_TEMPLATE or ImGui.GetColor(ctx, ImGui.Col_TextDisabled)
  local s = math.min(x2 - x1, y2 - y1)
  local cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
  local bw, bh = s * 0.46, s * 0.58
  local bx1, by1 = cx - bw / 2, cy - bh / 2 + s * 0.04
  local bx2, by2 = bx1 + bw, by1 + bh
  local th = math.max(1, s * 0.07)
  if has then
    ImGui.DrawList_AddRectFilled(dl, bx1, by1, bx2, by2, with_alpha(col, 0x40), s * 0.06)
  end
  ImGui.DrawList_AddRect(dl, bx1, by1, bx2, by2, col, s * 0.06, 0, th)
  -- the clip at the top
  local cw = bw * 0.5
  ImGui.DrawList_AddRectFilled(dl, cx - cw / 2, by1 - s * 0.07, cx + cw / 2, by1 + s * 0.07, col, s * 0.03)
  -- property lines
  for k = 1, 3 do
    local ly = by1 + bh * (0.22 + k * 0.19)
    local lx2 = bx2 - bw * (k == 3 and 0.42 or 0.22)
    ImGui.DrawList_AddLine(dl, bx1 + bw * 0.22, ly, lx2, ly, col, th)
  end
  return pressed
end

-- Per-level property template: the clipboard button opens a popup to set it.
local function level_options(id, get_t, set_t)
  local has = (get_t() or "") ~= ""
  if template_button("##opt" .. id, has) then ImGui.OpenPopup(ctx, "lvlopt" .. id) end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, has and ("Property template: " .. get_t() .. "\nClick to change it.")
      or "Property template (none). Click to set one.")
  end
  local tinted = row_tint.type
  pop_row_colors() -- the popup keeps the normal colors
  if ImGui.BeginPopup(ctx, "lvlopt" .. id) then
    dim_label("Property template (optional)")
    ImGui.SetNextItemWidth(ctx, 320)
    local ch, v = ImGui.InputTextWithHint(ctx, "##tmpl", "\\Templates\\...", get_t() or "")
    if ch then set_t(v); settings_changed() end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "From Wwise##t") then
      local _, err, o = core.wwise_selection_path()
      if o then set_t(o.path); settings_changed() else status_line = err or "" end
    end
    if has then
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Clear##t") then set_t(""); settings_changed() end
    end
    ImGui.EndPopup(ctx)
  end
  if tinted then push_row_colors(tinted) end
end

local function section_hierarchy()
  ImGui.SeparatorText(ctx, "Wwise structure")
  ImGui.PushTextWrapPos(ctx, 0)
  dim_label("Levels created under the destination, top to bottom. Names can use wildcards.")
  ImGui.PopTextWrapPos(ctx)

  local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerV
  if ImGui.BeginTable(ctx, "map", 3, flags) then
    ImGui.TableSetupColumn(ctx, "Type", ImGui.TableColumnFlags_WidthFixed, 150)
    ImGui.TableSetupColumn(ctx, "Name", ImGui.TableColumnFlags_WidthStretch)
    ImGui.TableSetupColumn(ctx, "", ImGui.TableColumnFlags_WidthFixed, 30)
    ImGui.TableHeadersRow(ctx)

    if selected_row > #S.rows then selected_row = #S.rows end
    for i, row in ipairs(S.rows) do
      ImGui.PushID(ctx, tostring(i))
      ImGui.TableNextRow(ctx)
      if i == selected_row then
        ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_RowBg1, 0x4A90E255)
      end
      ImGui.TableNextColumn(ctx)
      local c
      push_row_colors(row.type)
      c, row.type = combo("##type", core.CONTAINER_TYPES, row.type, -1)
      if ImGui.IsItemActivated(ctx) then selected_row = i end
      if c then settings_changed(); selected_row = i; pop_row_colors(); push_row_colors(row.type) end
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -28)
      local ch, v = ImGui.InputTextWithHint(ctx, "##name", "e.g. $region", row.name or "")
      if ch then row.name = v; settings_changed() end
      if ImGui.IsItemActive(ctx) then selected_row = i end
      wildcard_menu("r" .. i, function(w) row.name = (row.name or "") .. w end)
      ImGui.TableNextColumn(ctx)
      level_options("r" .. i, function() return row.template end, function(t) row.template = t end)
      pop_row_colors()
      ImGui.PopID(ctx)
    end

    -- Leaf (the Sound itself)
    ImGui.PushID(ctx, "leaf")
    ImGui.TableNextRow(ctx)
    ImGui.TableNextColumn(ctx)
    local c
    push_row_colors("Sound")
    c, S.leaf.voice = combo("##leaftype", { { false, "Sound SFX" }, { true, "Sound Voice" } }, S.leaf.voice, -1)
    if c then
      settings_changed()
      if S.leaf.voice and S.leaf.language == "" and conn and conn.languages[1] then S.leaf.language = conn.languages[1] end
    end
    ImGui.TableNextColumn(ctx)
    ImGui.SetNextItemWidth(ctx, -28)
    local ch, v = ImGui.InputTextWithHint(ctx, "##leafname", S.source == "items" and "(item name)" or "(rendered file name)", S.leaf.name)
    if ch then S.leaf.name = v; settings_changed() end
    wildcard_menu("leaf", function(w) S.leaf.name = S.leaf.name .. w end)
    ImGui.TableNextColumn(ctx)
    level_options("leaf", function() return S.leaf.template end, function(t) S.leaf.template = t end)
    pop_row_colors()
    ImGui.PopID(ctx)
    ImGui.EndTable(ctx)
  end

  -- Level buttons. Remove / Move act on the selected level (click its type or name to select it),
  -- or the bottom level when none is selected.
  if ImGui.Button(ctx, "+ Add level") then
    S.rows[#S.rows + 1] = { type = #S.rows == 0 and "Actor-Mixer" or "Random Container", name = "", template = "" }
    selected_row = #S.rows
    settings_changed()
  end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Add a level at the bottom, just above the Sound") end
  local n = #S.rows
  local target = (selected_row >= 1 and selected_row <= n) and selected_row or n
  local tname = n > 0 and ((S.rows[target].name or "") ~= "" and S.rows[target].name or S.rows[target].type) or nil
  ImGui.SameLine(ctx)
  if n == 0 then ImGui.BeginDisabled(ctx) end
  if ImGui.Button(ctx, "- Remove level") and n > 0 then
    table.remove(S.rows, target)
    selected_row = math.min(target, #S.rows)
    settings_changed()
  end
  if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
    ImGui.SetTooltip(ctx, n > 0 and ("Remove level " .. target .. ": " .. tname ..
      "\nClick a level's type or name to pick which one.") or "No levels to remove")
  end
  ImGui.SameLine(ctx)
  if n < 2 or target <= 1 then ImGui.BeginDisabled(ctx) end
  if ImGui.ArrowButton(ctx, "##lvlup", ImGui.Dir_Up) and target > 1 then
    S.rows[target], S.rows[target - 1] = S.rows[target - 1], S.rows[target]
    selected_row = target - 1
    settings_changed()
  end
  if n < 2 or target <= 1 then ImGui.EndDisabled(ctx) end
  if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) and n > 0 then
    ImGui.SetTooltip(ctx, "Move level " .. target .. " (" .. tname .. ") up")
  end
  ImGui.SameLine(ctx)
  if n < 2 or target >= n then ImGui.BeginDisabled(ctx) end
  if ImGui.ArrowButton(ctx, "##lvldown", ImGui.Dir_Down) and target < n then
    S.rows[target], S.rows[target + 1] = S.rows[target + 1], S.rows[target]
    selected_row = target + 1
    settings_changed()
  end
  if n < 2 or target >= n then ImGui.EndDisabled(ctx) end
  if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) and n > 0 then
    ImGui.SetTooltip(ctx, "Move level " .. target .. " (" .. tname .. ") down")
  end
  if n == 0 then ImGui.EndDisabled(ctx) end
  if S.leaf.voice then
    ImGui.SameLine(ctx)
    local langs = (conn and #conn.languages > 0) and conn.languages or { S.leaf.language ~= "" and S.leaf.language or "English(US)" }
    local c
    c, S.leaf.language = combo("Voice language", langs, S.leaf.language, 160)
    if c then settings_changed() end
  end

  -- Same line when it fits, otherwise on the next one.
  local pad_x = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  local need = ImGui.CalcTextSize(ctx, "Structure presets...") + pad_x * 2 + 20
  ImGui.SameLine(ctx)
  if ImGui.GetContentRegionAvail(ctx) >= need then
    ImGui.Dummy(ctx, 12, 0)
    ImGui.SameLine(ctx)
  else
    ImGui.NewLine(ctx)
  end
  presets_button("structure", "Structure presets...",
    "Save or load just the Wwise structure (levels, names, templates and the Sound row).\n" ..
    "Loading one leaves your other settings as they are.")
end


local CH_LABEL = { mono = "Mono", stereo = "Stereo" }
local ST_LABEL = { on = "Stream", off = "No stream" }
local LP_LABEL = { on = "Loop", off = "No loop" }

-- Preview columns you can click to set something on a Sound or a whole container
-- (a container's choice counts for every Sound inside it). Each one keeps its choices
-- in its own settings table through core's get/set functions.
local PICK_COLS = {
  ch = {
    what = "Channels",
    options = { { nil, "Auto" }, { "mono", "Mono" }, { "stereo", "Stereo" } },
    labels = CH_LABEL,
    own = function(path) return core.own_channel_override(S, plan, path) end,
    get = function(path) return core.channel_override(S, plan, path) end,
    set = function(path, v) core.set_channel_override(S, plan, path, v) end,
  },
  st = {
    what = "Streaming",
    options = { { nil, "Auto" }, { "on", "Stream" }, { "off", "No stream" } },
    labels = ST_LABEL,
    own = function(path) return core.own_stream_override(S, plan, path) end,
    get = function(path) return core.stream_override(S, plan, path) end,
    set = function(path, v) core.set_stream_override(S, plan, path, v) end,
  },
  lp = {
    what = "Loop",
    options = { { nil, "Auto" }, { "on", "Loop" }, { "off", "No loop" } },
    labels = LP_LABEL,
    own = function(path) return core.own_loop_override(S, plan, path) end,
    get = function(path) return core.loop_override(S, plan, path) end,
    set = function(path, v) core.set_loop_override(S, plan, path, v) end,
  },
}

-- Multi-select for those columns. Rows are picked by click, click-drag, Shift+click (range)
-- or Ctrl+click (add/remove); the menu then sets every picked row at once. Picking in one
-- column clears what was picked in the other. Rows are keyed by Wwise path. Ranges use the
-- row order of the previous frame.
local pk_col = nil       -- "ch" or "st": the column the picked rows belong to
local pk_sel = {}        -- path -> true
local pk_anchor = nil    -- path a Shift range or drag starts from
local pk_dragging = false   -- left button went down on a row; the menu opens when it's let go
local pk_drag_range = false -- plain click: dragging over rows picks the range
local pk_rows, pk_rows_prev, pk_index = {}, {}, {} -- this frame's / last frame's rows in order
local pk_names = {}      -- path -> { name, is_sound } for the menu header
local open_pk_menu = false
-- Main window position, kept up to date each frame. While picking rows with the mouse the
-- window is held in place there, so a drag that starts while the menu is open (ImGui
-- would treat it as dragging the window) only picks rows.
local main_win_pos = { 0, 0 }
local main_win_docked = false
local pk_pin = nil

local function pk_count()
  local n = 0
  for p in pairs(pk_sel) do if pk_names[p] then n = n + 1 end end
  return n
end

local function pk_select_range(a, b)
  local ia, ib = pk_index[a], pk_index[b]
  pk_sel = {}
  if not ia or not ib then pk_sel[b] = true; return end
  if ia > ib then ia, ib = ib, ia end
  for i = ia, ib do pk_sel[pk_rows_prev[i]] = true end
end

-- Called once per preview row (below the destination), whatever columns are shown.
local function pick_row(node)
  pk_rows[#pk_rows + 1] = node.path
  pk_names[node.path] = { node.name, node.entry ~= nil }
end

-- One clickable cell in a pick column.
local function pick_cell(col, path, text, color, tip)
  local selected = pk_col == col and pk_sel[path] == true
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, color)
  ImGui.Selectable(ctx, text .. "##" .. col, selected)
  ImGui.PopStyleColor(ctx)
  -- AllowWhenBlockedByPopup: with the menu open, the next click on a row still counts
  -- (it closes the menu and picks the row) instead of needing a second click.
  local hov_flags = ImGui.HoveredFlags_AllowWhenBlockedByPopup
  if ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Left) and ImGui.IsItemHovered(ctx, hov_flags) then
    if pk_col ~= col then pk_col, pk_sel, pk_anchor = col, {}, nil end
    local mods = ImGui.GetKeyMods(ctx)
    if mods & ImGui.Mod_Shift ~= 0 and pk_anchor then
      pk_select_range(pk_anchor, path)
    elseif mods & ImGui.Mod_Ctrl ~= 0 then
      pk_sel[path] = (not pk_sel[path]) or nil
      pk_anchor = path
    else
      pk_sel = { [path] = true }
      pk_anchor = path
      pk_drag_range = true
    end
    pk_dragging = true
    if not main_win_docked then pk_pin = { main_win_pos[1], main_win_pos[2] } end
  elseif ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Right) and ImGui.IsItemHovered(ctx, hov_flags) then
    if pk_col ~= col or not pk_sel[path] then pk_col, pk_sel, pk_anchor = col, { [path] = true }, path end
    open_pk_menu = true
  elseif pk_drag_range and pk_col == col and ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenBlockedByActiveItem) then
    pk_select_range(pk_anchor, path)
  end
  if not pk_dragging and ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, tip .. "\nClick to change. Drag, Shift+click or Ctrl+click to pick\nseveral rows, then right-click to change them all.")
  end
end

-- Channels column: shows Auto / Mono / Stereo.
local function channels_cell(node)
  local path = node.path
  local own = core.own_channel_override(S, plan, path)
  local eff, from = core.channel_override(S, plan, path)
  local text, col, tip
  if own then
    text, col = CH_LABEL[own], 0xFFFFFFFF
    tip = node.entry and ("Set to " .. text .. " for this Sound.") or ("Set to " .. text .. " for every Sound in " .. node.name .. ".")
  elseif eff then
    text, col = CH_LABEL[eff], 0xCFCFCFFF
    tip = text .. ", set on " .. from .. "."
  elseif node.entry and node.entry.kind == "direct" then
    local n = node.entry.src_ch
    text = n == 1 and "Mono" or n == 2 and "Stereo" or (n and (n .. " ch")) or "As file"
    col, tip = COLOR_DIM, "Imported as the file is on disk."
  elseif node.entry then
    text, col = S.mono_to_mono and "Auto" or "As rendered", COLOR_DIM
    tip = S.mono_to_mono and "Auto: renders in stereo, then made mono if left and right are the same."
      or "Keeps the channels it renders with (Auto channels is off in Settings)."
  else
    text, col, tip = "Auto", COLOR_DIM, "No override: each Sound inside decides for itself."
  end
  pick_cell("ch", path, text, col, tip)
end

local function len_text(sec)
  if sec >= 60 then return string.format("%d:%04.1f", math.floor(sec / 60), sec % 60) end
  return string.format("%.1f s", sec)
end

-- Streaming column: shows Stream / No stream, or what Auto streaming will do.
local function streaming_cell(node)
  local path = node.path
  local own = core.own_stream_override(S, plan, path)
  local eff, from = core.stream_override(S, plan, path)
  local e = node.entry
  local text, col, tip
  if own then
    text, col = ST_LABEL[own], 0xFFFFFFFF
    tip = (own == "on" and "Streaming turned on" or "Streaming turned off") ..
      (e and " for this Sound." or (" for every Sound in " .. node.name .. "."))
  elseif eff then
    text, col = ST_LABEL[eff], 0xCFCFCFFF
    tip = (eff == "on" and "Streaming turned on" or "Streaming turned off") .. ", set on " .. from .. "."
  elseif e then
    local want, why = core.wanted_streaming(S, plan, e)
    local min = len_text(S.stream_min_sec or 10)
    if want then
      text, col = "Auto: stream", 0xCFCFCFFF
      tip = "Auto streaming: " .. len_text(e.len) .. " long, at least " .. min .. "."
    elseif why == "short" then
      text, col = "-", COLOR_DIM
      tip = "Auto streaming: " .. len_text(e.len) .. " long, shorter than " .. min .. ".\nLeft as Wwise or the template has it."
    elseif why == "unknown" then
      text, col = "Auto", COLOR_DIM
      tip = "Auto streaming: streams if the rendered file is at least " .. min .. " long."
    else
      text, col = "-", COLOR_DIM
      tip = "Left as Wwise or the template has it." .. (e.len and ("\nLength: " .. len_text(e.len)) or "")
    end
  else
    text, col, tip = "-", COLOR_DIM, "No override: each Sound inside decides for itself."
  end
  pick_cell("st", path, text, col, tip)
end

-- Loop column: shows Loop / No loop, or "-" when it's left as Wwise or the template has it.
local function loop_cell(node)
  local path = node.path
  local own = core.own_loop_override(S, plan, path)
  local eff, from = core.loop_override(S, plan, path)
  local text, col, tip
  if own then
    text, col = LP_LABEL[own], 0xFFFFFFFF
    tip = (own == "on" and "Loops forever" or "Looping turned off") ..
      (node.entry and " for this Sound." or (" for every Sound in " .. node.name .. "."))
  elseif eff then
    text, col = LP_LABEL[eff], 0xCFCFCFFF
    tip = (eff == "on" and "Loops forever" or "Looping turned off") .. ", set on " .. from .. "."
  else
    text, col = "-", COLOR_DIM
    tip = node.entry and "Left as Wwise or the template has it." or "No override: each Sound inside decides for itself."
  end
  pick_cell("lp", path, text, col, tip)
end

-- Called after the preview table: finishes a drag and draws the shared menu.
local function pick_menu()
  if pk_dragging and not ImGui.IsMouseDown(ctx, ImGui.MouseButton_Left) then
    pk_dragging, pk_drag_range, pk_pin = false, false, nil
    open_pk_menu = true -- letting go of a click or a drag opens the menu for what's picked
  end
  pk_rows_prev, pk_rows = pk_rows, {}
  pk_index = {}
  for i, p in ipairs(pk_rows_prev) do pk_index[p] = i end
  if open_pk_menu then
    open_pk_menu = false
    if pk_count() > 0 and PICK_COLS[pk_col] then ImGui.OpenPopup(ctx, "pickpop") end
  end
  if ImGui.BeginPopup(ctx, "pickpop") then
    local pc = PICK_COLS[pk_col] or PICK_COLS.ch
    local paths = {}
    for p in pairs(pk_sel) do if pk_index[p] then paths[#paths + 1] = p end end
    table.sort(paths, function(a, b) return pk_index[a] < pk_index[b] end)
    if #paths == 1 then
      local nm = pk_names[paths[1]]
      dim_label(nm[2] and (pc.what .. " for " .. nm[1]) or (pc.what .. " for every Sound in " .. nm[1]))
    else
      dim_label(string.format("%s for %d selected rows", pc.what, #paths))
    end
    -- Tick the option only when every picked row already has it.
    local common, mixed = nil, false
    for i, p in ipairs(paths) do
      local o = pc.own(p) or "auto"
      if i == 1 then common = o elseif o ~= common then mixed = true end
    end
    for _, o in ipairs(pc.options) do
      if ImGui.Selectable(ctx, o[2], not mixed and common == (o[1] or "auto")) then
        for _, p in ipairs(paths) do pc.set(p, o[1]) end
        settings_changed()
        pk_sel = {}
      end
    end
    if #paths == 1 then
      local own = pc.own(paths[1])
      local eff, from = pc.get(paths[1])
      if not own and eff then dim_label("Now " .. pc.labels[eff] .. ", from " .. from .. ".") end
    end
    ImGui.EndPopup(ctx)
  elseif not pk_dragging and next(pk_sel) and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    pk_sel = {}
  end
end

local KIND_LABEL = { direct = "Direct (no render)", render = "Render item", folder = "Render folder", project = "Render" }
local tree_open_all = nil -- true/false for one frame to expand/collapse everything

local function status_cell(st)
  if st == "duplicate" then ImGui.TextColored(ctx, COLOR_BAD, "Duplicate")
  elseif st == "exists" then ImGui.TextColored(ctx, COLOR_EXISTS, "Exists")
  elseif st == "new" then ImGui.TextColored(ctx, COLOR_NEW, "New")
  else ImGui.TextDisabled(ctx, "-") end
end

local function draw_node(node, depth)
  ImGui.TableNextRow(ctx)
  ImGui.TableNextColumn(ctx)
  local is_leaf = #node.children == 0
  local flags = ImGui.TreeNodeFlags_SpanFullWidth
  if is_leaf then
    flags = flags | ImGui.TreeNodeFlags_Leaf | ImGui.TreeNodeFlags_NoTreePushOnOpen
  else
    flags = flags | ImGui.TreeNodeFlags_DefaultOpen
    if tree_open_all ~= nil then
      -- "Collapse all" folds only the containers that hold Sounds, so the container layout stays visible.
      local holds_sounds = false
      for _, ch in ipairs(node.children) do if #ch.children == 0 then holds_sounds = true; break end end
      ImGui.SetNextItemOpen(ctx, tree_open_all or not holds_sounds, ImGui.Cond_Always)
    end
  end
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, type_color(node.type) or 0xFFFFFFFF)
  local tag = TYPE_TAGS[node.type] or "[?]"
  local open = ImGui.TreeNodeEx(ctx, node.path or node.name, tag, flags)
  ImGui.PopStyleColor(ctx)
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, node.type) end
  ImGui.SameLine(ctx)
  local label = node.name
  if not is_leaf then label = label .. string.format("  (%d)", node.sounds) end
  ImGui.Text(ctx, label)
  if ImGui.IsItemHovered(ctx) then
    local tip = node.type .. "\n" .. (node.path or "")
    if node.entry then
      tip = tip .. "\n" .. (KIND_LABEL[node.entry.kind] or "")
      if node.entry.file then tip = tip .. "\nAudio: " .. node.entry.file end
      if node.entry.origsub then tip = tip .. "\nOriginals\\" .. node.entry.origsub end
    end
    ImGui.SetTooltip(ctx, tip)
  end
  ImGui.TableNextColumn(ctx)
  if depth > 0 then status_cell(node.status) end
  ImGui.TableNextColumn(ctx)
  if node.entry then ImGui.TextDisabled(ctx, KIND_LABEL[node.entry.kind] or "") end
  if depth > 0 and node.path then pick_row(node) end
  ImGui.TableNextColumn(ctx)
  if depth > 0 and node.path then channels_cell(node) end
  ImGui.TableNextColumn(ctx)
  if depth > 0 and node.path then streaming_cell(node) end
  ImGui.TableNextColumn(ctx)
  if depth > 0 and node.path then loop_cell(node) end
  ImGui.TableNextColumn(ctx)
  if node.entry then
    local o = core.originals_name(node.entry)
    if o then
      ImGui.TextColored(ctx, COLOR_DIM, o)
      if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Originals\\" .. core.originals_root(S) .. "\\" .. o) end
    end
  end
  ImGui.TableNextColumn(ctx)
  if node.delay then
    ImGui.Text(ctx, delay_text(node.delay))
    if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) then open_delay_menu = true end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Right-click to show seconds or milliseconds") end
  end
  if open and not is_leaf then
    for i, ch in ipairs(node.children) do
      ImGui.PushID(ctx, tostring(i))
      draw_node(ch, depth + 1)
      ImGui.PopID(ctx)
    end
    ImGui.TreePop(ctx)
  end
end

-- Preview columns. Right-clicking a header (TableFlags_Hideable) shows a tick box per column;
-- the choice is kept in `view` so it comes back next time. Columns can be dragged by their
-- header into another order (TableFlags_Reorderable, Name stays first); ImGui remembers the
-- order, and the header's right-click menu has "Reset order".
-- Cells are always drawn in this list's order; only where they show changes.
local PREVIEW_COLS = {
  { id = "Name", stretch = true, w = 4, nohide = true },
  { id = "Status", w = 70 },
  { id = "Audio", w = 120 },
  { id = "Channels", w = 80 },
  { id = "Streaming", w = 90 },
  { id = "Loop", w = 70 },
  { id = "Originals file", stretch = true, w = 3 },
  { id = "Initial delay", w = 80 },
}
local cols_frames = 0
local function sync_columns()
  cols_frames = cols_frames + 1
  if cols_frames == 1 then
    -- Apply the saved choice (ImGui's own saved table state may differ). Takes effect next frame.
    for i, c in ipairs(PREVIEW_COLS) do
      if not c.nohide then ImGui.TableSetColumnEnabled(ctx, i - 1, not view.hidden[c.id]) end
    end
    return
  end
  if cols_frames < 3 then return end
  local changed = false
  for i, c in ipairs(PREVIEW_COLS) do
    if not c.nohide then
      local hidden = (ImGui.TableGetColumnFlags(ctx, i - 1) & ImGui.TableColumnFlags_IsEnabled) == 0
      if hidden ~= (view.hidden[c.id] == true) then view.hidden[c.id] = hidden or nil; changed = true end
    end
  end
  if changed then save_view() end
end

local function section_preview()
  local n = #plan.entries
  ImGui.SeparatorText(ctx, string.format("Preview in Wwise (%d Sound%s)", n, n == 1 and "" or "s"))
  local problems = core.validate(S)
  for _, p in ipairs(problems) do ImGui.TextColored(ctx, COLOR_BAD, "- " .. p) end
  for _, p in ipairs(plan.errors or {}) do ImGui.TextColored(ctx, COLOR_BAD, "- " .. p) end
  if plan.delay_warnings and #plan.delay_warnings > 0 then
    ImGui.PushTextWrapPos(ctx, 0)
    for _, w in ipairs(plan.delay_warnings) do ImGui.TextColored(ctx, 0xF4D35EFF, "- Initial delay: " .. w) end
    ImGui.PopTextWrapPos(ctx)
  end
  if plan.dest_missing then ImGui.TextColored(ctx, COLOR_BAD, "- The import destination doesn't exist in Wwise.") end

  local tree = plan.tree
  if tree then
    if tree.unresolved and tree.unresolved > 0 then
      ImGui.TextColored(ctx, COLOR_BAD, string.format("- %d file(s) skipped: a wildcard in the structure didn't resolve.", tree.unresolved))
    end
    if plan.existing then
      ImGui.TextColored(ctx, COLOR_NEW, string.format("%d new object%s", tree.new_count, tree.new_count == 1 and "" or "s"))
      ImGui.SameLine(ctx)
      ImGui.TextDisabled(ctx, "will be created. Everything else already exists and will be updated.")
    end
    if ImGui.SmallButton(ctx, "Expand all") then tree_open_all = true end
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Collapse all") then tree_open_all = false end
    ImGui.SameLine(ctx)
    ImGui.TextDisabled(ctx, "  Right-click a column header to choose columns; drag a header to move it.")
  end

  local flags = ImGui.TableFlags_BordersV | ImGui.TableFlags_BordersOuterH | ImGui.TableFlags_RowBg |
                ImGui.TableFlags_ScrollY | ImGui.TableFlags_Resizable | ImGui.TableFlags_Hideable |
                ImGui.TableFlags_Reorderable
  local h = math.max(160, select(2, ImGui.GetContentRegionAvail(ctx)) - 52)
  if ImGui.BeginTable(ctx, "previewtree", #PREVIEW_COLS, flags, 0, h) then
    ImGui.TableSetupScrollFreeze(ctx, 0, 1)
    for _, c in ipairs(PREVIEW_COLS) do
      local cf = c.stretch and ImGui.TableColumnFlags_WidthStretch or ImGui.TableColumnFlags_WidthFixed
      if c.nohide then cf = cf | ImGui.TableColumnFlags_NoHide | ImGui.TableColumnFlags_NoReorder end
      if view.hidden[c.id] then cf = cf | ImGui.TableColumnFlags_DefaultHide end
      ImGui.TableSetupColumn(ctx, c.id, cf, c.w)
    end
    ImGui.TableHeadersRow(ctx)
    sync_columns()
    if tree and #tree.children > 0 then draw_node(tree, 0) end
    ImGui.EndTable(ctx)
  end
  pick_menu()
  if open_delay_menu then ImGui.OpenPopup(ctx, "delayunit"); open_delay_menu = false end
  if ImGui.BeginPopup(ctx, "delayunit") then
    ImGui.TextDisabled(ctx, "Show Initial delay in")
    for _, u in ipairs(DELAY_UNITS) do
      if ImGui.MenuItem(ctx, u[2], nil, view.delay_unit == u[1]) then view.delay_unit = u[1]; save_view() end
    end
    ImGui.EndPopup(ctx)
  end
  tree_open_all = nil
end

local function do_transfer()
  core.save_settings(S)
  status_line = "Transferring..."
  local s2 = core.json.decode(core.json.encode(S))
  local t0 = r.time_precise()
  bg_task = nil; connecting = false
  transfer_task = coroutine.create(function()
    summary = core.transfer(s2, conn, function(msg) status_line = msg end)
    summary.seconds = r.time_precise() - t0
    summary.destination = s2.destination
    status_line = ""
    open_summary = true
    -- Remember what was just created, so the preview doesn't query Wwise while it's still busy importing.
    imported_paths = {}
    for _, o in ipairs(summary.objects or {}) do if o.path then imported_paths[o.path:lower()] = true end end
    last_transfer_end = r.time_precise()
    note("transfer " .. string.format("%.0fms", (summary.seconds or 0) * 1000))
    if summary.plan and summary.imported > 0 then
      if known_dest ~= summary.plan.destination then known_existing, known_dest = {}, summary.plan.destination end
      core.remember_transfer(summary.plan, known_existing)
    end
    last_sig = nil
    quiet_until = r.time_precise() + 10
  end)
  transfer_task = run_task(transfer_task)
end

local function section_transfer()
  local problems = core.validate(S)
  -- Why the button is greyed out (first reason wins).
  local why
  if not conn then why = "Not connected to Wwise. Open Settings and click Reconnect."
  elseif current_destination() == "" then
    why = S.use_wwise_selection and "Select a parent object in Wwise (or untick \"Always use the object selected in Wwise\")."
      or "Set an import destination."
  elseif #problems > 0 then why = problems[1]
  elseif #plan.entries == 0 then why = (plan.errors and plan.errors[1]) or "Select one or more items in REAPER."
  elseif core.plan_needs_render(S, plan) and not core.project_saved() then why = core.UNSAVED_MSG
  end
  local can = why == nil
  ImGui.Separator(ctx)
  ImGui.Dummy(ctx, 0, 2)
  local bw = 260
  local text = status_line
  if text == "" and why then text = why end
  if text == "" then
    local n = #plan.entries
    text = string.format("%d Sound%s  ->  %s", n, n == 1 and "" or "s", current_destination() ~= "" and current_destination() or "(no destination)")
  end
  local avail = ImGui.GetContentRegionAvail(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.PushTextWrapPos(ctx, math.max(80, avail - bw - 12))
  ImGui.TextColored(ctx, (why and status_line == "") and 0xF4D35EFF or COLOR_DIM, text)
  ImGui.PopTextWrapPos(ctx)
  ImGui.SameLine(ctx)
  avail = ImGui.GetContentRegionAvail(ctx)
  if avail > bw then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + avail - bw) end
  local busy = not can or transfer_task
  if busy then ImGui.BeginDisabled(ctx)
  else
    -- Green when ready; the greyed-out look stays as it was while disabled.
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x1A7F37FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x2C974BFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x166A2EFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFFFFFFF)
  end
  if ImGui.Button(ctx, transfer_task and "Transferring..." or "Transfer to Wwise", bw, 34) and not transfer_task then do_transfer() end
  if busy then ImGui.EndDisabled(ctx) else ImGui.PopStyleColor(ctx, 4) end
  if why and ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then ImGui.SetTooltip(ctx, why) end
end

local function summary_popup()
  if open_summary then ImGui.OpenPopup(ctx, "Transfer summary"); open_summary = false end
  ImGui.SetNextWindowSize(ctx, 520, 0, ImGui.Cond_Appearing)
  if ImGui.BeginPopupModal(ctx, "Transfer summary", nil, ImGui.WindowFlags_AlwaysAutoResize) then
    local s = summary or { errors = {} }
    local okc = (#s.errors == 0) and COLOR_OK or (s.imported > 0 and 0xF4D35EFF or COLOR_BAD)
    ImGui.TextColored(ctx, okc, (#s.errors == 0) and "Transfer complete" or (s.imported > 0 and "Transfer finished with warnings" or "Transfer failed"))
    if s.destination then ImGui.Text(ctx, "Destination: " .. s.destination) end
    ImGui.Text(ctx, string.format("Audio files imported: %d", s.imported or 0))
    ImGui.Text(ctx, string.format("Objects created: %d", s.created or 0))
    if (s.templates or 0) > 0 then ImGui.Text(ctx, string.format("Templates applied: %d", s.templates)) end
    if (s.streaming_on or 0) > 0 then ImGui.Text(ctx, string.format("Sounds set to stream: %d", s.streaming_on)) end
    if (s.streaming_off or 0) > 0 then ImGui.Text(ctx, string.format("Streaming turned off: %d", s.streaming_off)) end
    if (s.loop_on or 0) > 0 then ImGui.Text(ctx, string.format("Sounds set to loop: %d", s.loop_on)) end
    if (s.loop_off or 0) > 0 then ImGui.Text(ctx, string.format("Looping turned off: %d", s.loop_off)) end
    if (s.delays or 0) > 0 then ImGui.Text(ctx, string.format("Initial delays set: %d", s.delays)) end
    if s.notes and #s.notes > 0 then
      ImGui.PushTextWrapPos(ctx, 500)
      for _, n in ipairs(s.notes) do ImGui.TextColored(ctx, COLOR_DIM, "- " .. n) end
      ImGui.PopTextWrapPos(ctx)
    end
    if s.seconds then ImGui.TextDisabled(ctx, string.format("Took %.2f s", s.seconds)) end
    if s.timing and #s.timing > 0 then
      local parts = {}
      for _, t in ipairs(s.timing) do parts[#parts + 1] = string.format("%s %.2fs", t[1], t[2]) end
      ImGui.PushTextWrapPos(ctx, 500)
      ImGui.TextDisabled(ctx, table.concat(parts, "  |  "))
      ImGui.PopTextWrapPos(ctx)
      if ImGui.SmallButton(ctx, "Copy timing") then ImGui.SetClipboardText(ctx, table.concat(parts, "\n")) end
    end
    if #s.errors > 0 then
      ImGui.Separator(ctx)
      ImGui.PushTextWrapPos(ctx, 500)
      for _, e in ipairs(s.errors) do ImGui.TextColored(ctx, COLOR_BAD, "- " .. e) end
      ImGui.PopTextWrapPos(ctx)
      if ImGui.Button(ctx, "Copy details") then ImGui.SetClipboardText(ctx, table.concat(s.errors, "\n")) end
      ImGui.SameLine(ctx)
    end
    if ImGui.Button(ctx, "Close") or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) then
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.EndPopup(ctx)
  end
end

-- Settings window: one tab per group. Each tab's contents are drawn by its own function.
local function settings_connection()
  local c, v
  ImGui.SetNextItemWidth(ctx, 100)
  c, v = ImGui.InputInt(ctx, "WAAPI HTTP port", S.http_port)
  if c then S.http_port = v; settings_changed() end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Reconnect") and not connecting then core.disconnect(); bg_task = nil; start_connect() end
  ImGui.PushTextWrapPos(ctx, 480)
  ImGui.TextColored(ctx, COLOR_DIM, "Must match Wwise > Project > User Preferences > Wwise Authoring API (default 8090). " ..
    "\"Allow connections from\" there should be 127.0.0.1,::1.")
  ImGui.PopTextWrapPos(ctx)
end

local function settings_rendering()
  local c
  dim_label("For Source: Selected items.")
  c, S.skip_render_untouched = ImGui.Checkbox(ctx, "Import untouched WAV files directly (no render)", S.skip_render_untouched)
  if c then settings_changed() end
  help("An item that plays a whole WAV file with no trims, FX, fades, pitch or volume changes\nis imported straight from disk. This is the fastest path.")
  c, S.items_via_master = ImGui.Checkbox(ctx, "Render items through track FX and master", S.items_via_master)
  if c then settings_changed() end
  c, S.folders_via_master = ImGui.Checkbox(ctx, "Render folder items through master", S.folders_via_master)
  if c then settings_changed() end
  help("An empty item on a folder track renders the folder's mix (folder + children)\nover that item's time range, named after the item.")
  ImGui.Dummy(ctx, 0, 4)
  dim_label("Keep rendered files in")
  S.render_folder = input("##renderfolder", S.render_folder, "(empty: temporary, deleted after the transfer)", 380)
  wildcard_menu("rf", function(w) S.render_folder = S.render_folder .. w end)
  help("A folder for the files rendered from selected items, e.g. Renders or Renders\\$project.\n" ..
    "Relative paths start in the project folder. REAPER wildcards are allowed.\n" ..
    "A file there with the same name as a new render is replaced.\n" ..
    "Untouched WAV items aren't rendered (they import straight from disk) unless that option is off.")
  do
    local base, rest = core.render_folder_parts(S)
    if base then ImGui.TextDisabled(ctx, base .. ((rest ~= "") and ("\\" .. rest:gsub("/", "\\")) or "")) end
  end
end

local function settings_channels()
  local c
  c, S.mono_to_mono = ImGui.Checkbox(ctx, "Auto channels: make a Sound mono when left and right are the same", S.mono_to_mono)
  if c then settings_changed() end
  help("Edited items and folder items render in stereo. Afterwards each file is checked:\n" ..
    "when left and right are the same, the Sound is imported as mono; otherwise it stays stereo.\n" ..
    "Untouched WAV files import as they are on disk.\n" ..
    "Click a Sound or container in the preview's Channels column to force Mono or Stereo.")
  do
    local n = core.count_channel_overrides(S)
    if n > 0 then
      if ImGui.SmallButton(ctx, string.format("Clear channel overrides (%d)", n)) then S.channels = {}; settings_changed() end
      help("Removes every Mono/Stereo choice made in the preview's Channels column (this project).")
    end
  end
end

local function settings_transfer()
  local c
  dim_label("Paste each level's property template onto:")
  c, S.apply_template = combo("##apply_template", core.TEMPLATE_OPS, S.apply_template, 320)
  if c then settings_changed() end
  help("Templates are set per Structure level with its \"...\" button.\n" ..
    "\"New objects only\" leaves objects that already existed in Wwise as they are.")
  c, S.select_in_wwise = ImGui.Checkbox(ctx, "Select imported Sounds in Wwise afterwards", S.select_in_wwise)
  if c then settings_changed() end
end

local function settings_streaming()
  local c, v
  c, S.stream_auto = ImGui.Checkbox(ctx, "Auto streaming: stream Sounds at least", S.stream_auto)
  if c then settings_changed() end
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 90)
  c, v = ImGui.InputDouble(ctx, "seconds long", S.stream_min_sec, 1, 5, "%.1f")
  if c then S.stream_min_sec = math.max(0, v); settings_changed() end
  help("Turns on Stream in Wwise for every Sound that long or longer. Shorter Sounds are left\n" ..
    "as Wwise or their template has them. Selected items use the item length; files from\n" ..
    "REAPER's render settings are measured after rendering.\n" ..
    "Click a Sound or container in the preview's Streaming column to force Stream or No stream.")
  dim_label("When a Sound is set to stream, also turn on:")
  c, S.stream_zero_latency = ImGui.Checkbox(ctx, "Zero latency", S.stream_zero_latency)
  if c then settings_changed() end
  ImGui.SameLine(ctx)
  c, S.stream_non_cachable = ImGui.Checkbox(ctx, "Non-cachable", S.stream_non_cachable)
  if c then settings_changed() end
  help("Zero latency loads the start of the file (Prefetch length, set in Wwise) into memory so\n" ..
    "it plays without delay. Non-cachable keeps it out of the stream cache.\n" ..
    "Streaming and these flags are written after the property templates, so they win.")
  do
    local n = core.count_stream_overrides(S)
    if n > 0 then
      if ImGui.SmallButton(ctx, string.format("Clear streaming overrides (%d)", n)) then S.streaming = {}; settings_changed() end
      help("Removes every Stream/No stream choice made in the preview's Streaming column (this project).")
    end
  end
  ImGui.Dummy(ctx, 0, 6)
  ImGui.SeparatorText(ctx, "Loop")
  ImGui.PushTextWrapPos(ctx, 0)
  dim_label("Click a Sound or container in the preview's Loop column to set Loop (infinite) or No loop. " ..
    "Auto leaves it as Wwise or the template has it. Written after the property templates, so it wins.")
  ImGui.PopTextWrapPos(ctx)
  do
    local n = core.count_loop_overrides(S)
    if n > 0 then
      if ImGui.SmallButton(ctx, string.format("Clear loop overrides (%d)", n)) then S.loops = {}; settings_changed() end
      help("Removes every Loop/No loop choice made in the preview's Loop column (this project).")
    end
  end
end

local function settings_interface()
  local c
  ImGui.SeparatorText(ctx, "Window")
  dim_label("Background opacity")
  ImGui.SetNextItemWidth(ctx, 260)
  local pct
  c, pct = ImGui.SliderInt(ctx, "##opacity", math.floor(view.opacity * 100 + 0.5), 20, 100, "%d%%")
  if c then view.opacity = pct / 100 end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then save_view() end
  help("How see-through the Wwise Tool window's background is. Text and buttons stay solid.\n" ..
    "Only works while the window is floating, not when it's docked.")
  dim_label("Show the preview's Initial delay in")
  do
    local ch, u = combo("##delayunit", DELAY_UNITS, view.delay_unit, 260)
    if ch then view.delay_unit = u; save_view() end
  end
  help("Seconds match what Wwise's Initial Delay field shows. You can also right-click\n" ..
    "a value in the preview's Initial delay column to switch.")
  ImGui.Dummy(ctx, 0, 6)

  ImGui.SeparatorText(ctx, "Type colors")
  dim_label("Colors for the Wwise structure rows and the preview's type tags.")
  local color_flags = ImGui.ColorEditFlags_NoInputs | ImGui.ColorEditFlags_NoAlpha
  if ImGui.BeginTable(ctx, "typecolors", 2) then
    for i, k in ipairs(COLOR_TYPE_ORDER) do
      if i % 2 == 1 then ImGui.TableNextRow(ctx) end
      ImGui.TableNextColumn(ctx)
      local cur = type_color(k)
      local ch, rgb = ImGui.ColorEdit3(ctx, k .. "##tc" .. k, cur >> 8, color_flags)
      if ch then
        local rgba = ((rgb & 0xFFFFFF) << 8) | 0xFF
        view.colors[k] = (rgba ~= DEFAULT_TYPE_COLORS[k]) and rgba or nil
        view_dirty = true
      end
    end
    ImGui.EndTable(ctx)
  end
  if next(view.colors) and ImGui.SmallButton(ctx, "Reset colors to defaults") then
    view.colors = {}; view_dirty = true
  end
  if view_dirty and not ImGui.IsAnyItemActive(ctx) then save_view(); view_dirty = false end
end

local function settings_diagnostics()
  ImGui.PushTextWrapPos(ctx, 480)
  ImGui.TextColored(ctx, COLOR_DIM, string.format("Slow moments recorded: %d. If REAPER stutters or freezes, " ..
    "copy this log and send it over.", #slow_log))
  ImGui.PopTextWrapPos(ctx)
  if ImGui.Button(ctx, "Copy slow-moment log") then
    ImGui.SetClipboardText(ctx, "Wwise Tool " .. core.VERSION .. "\n" .. table.concat(slow_log, "\n"))
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Clear log") then slow_log = {} end
end

local SETTINGS_TABS = {
  { "Connection", settings_connection },
  { "Rendering", settings_rendering },
  { "Channels", settings_channels },
  { "Transfer", settings_transfer },
  { "Stream & loop", settings_streaming },
  { "Interface", settings_interface },
  { "Diagnostics", settings_diagnostics },
}

-- New ID (title still reads "Settings") so the old auto-sized window's saved size
-- doesn't carry over to the tabbed one.
local SETTINGS_ID = "Settings##tabbed"

local function settings_popup()
  if open_settings then ImGui.OpenPopup(ctx, SETTINGS_ID); open_settings = false end
  ImGui.SetNextWindowSize(ctx, 560, 440, ImGui.Cond_FirstUseEver)
  ImGui.SetNextWindowSizeConstraints(ctx, 420, 300, 2000, 2000)
  if not ImGui.BeginPopupModal(ctx, SETTINGS_ID) then return end

  -- Fixed-size window: switching tabs doesn't make it jump around. The tab's
  -- contents scroll when they don't fit; the footer stays put.
  local footer_h = ImGui.GetFrameHeightWithSpacing(ctx) + 8
  if ImGui.BeginTabBar(ctx, "settingstabs") then
    for _, t in ipairs(SETTINGS_TABS) do
      if ImGui.BeginTabItem(ctx, t[1]) then
        if ImGui.BeginChild(ctx, "##settings_" .. t[1], 0, -footer_h) then
          ImGui.Dummy(ctx, 0, 2)
          t[2]()
          ImGui.EndChild(ctx)
        end
        ImGui.EndTabItem(ctx)
      end
    end
    ImGui.EndTabBar(ctx)
  end

  ImGui.Separator(ctx)
  ImGui.TextDisabled(ctx, "Wwise Tool " .. core.VERSION)
  ImGui.SameLine(ctx)
  local w = 80
  local avail = ImGui.GetContentRegionAvail(ctx)
  if avail > w then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + avail - w) end
  if ImGui.Button(ctx, "Close", w) or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then ImGui.CloseCurrentPopup(ctx) end
  ImGui.EndPopup(ctx)
end

----------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------
local function log_frame(t0, gap)
  local work = r.time_precise() - t0
  if work > 0.1 or gap > 0.25 then
    local since = last_transfer_end and string.format("  [%.1fs after transfer]", t0 - last_transfer_end) or ""
    local line = string.format("%s  script %.0fms  REAPER busy before %.0fms%s  %s", os.date("%H:%M:%S"),
      work * 1000, gap * 1000, since, table.concat(frame_notes, ", "))
    slow_log[#slow_log + 1] = line
    if #slow_log > 60 then table.remove(slow_log, 1) end
  end
  frame_notes = {}
  last_frame_end = r.time_precise()
end

local loop_body
local function loop()
  local t0 = r.time_precise()
  -- Time between the end of our last frame and now: normally ~33 ms. Much more means
  -- REAPER itself (or another script) was busy and didn't give us a turn.
  local gap = last_frame_end and math.max(0, t0 - last_frame_end - 0.034) or 0
  local open = loop_body()
  log_frame(t0, gap)
  if open then
    r.defer(loop)
  else
    core.save_settings(S)
  end
end

-- Settings live in each project. When you switch project tabs, save any pending
-- change into the project it belongs to and load the new project's settings.
local cur_proj = r.EnumProjects(-1)
local function follow_project_tab()
  local proj = r.EnumProjects(-1)
  if proj == cur_proj then return end
  if dirty_settings and cur_proj and r.ValidatePtr(cur_proj, "ReaProject*") then core.save_settings(S, cur_proj) end
  dirty_settings = false
  cur_proj = proj
  S = core.load_settings()
  core.http_port = S.http_port
  plan = { entries = {}, errors = {} }
  forget_existing()
  sel_poll_at = 0
  last_sig = nil
end

-- 1.12.0/1.12.1 could leave the window screen-sized: put it back to the standard size once.
local size_reset = view.size_v ~= 2

loop_body = function()
  if not transfer_task then follow_project_tab() end
  if transfer_task then transfer_task = run_task(transfer_task) end
  refresh_preview(false)
  ImGui.SetNextWindowSize(ctx, 1180, 760, ImGui.Cond_FirstUseEver)
  if size_reset then
    ImGui.SetNextWindowSize(ctx, 1180, 760, ImGui.Cond_Always)
    size_reset = false
    view.size_v = 2; save_view()
  elseif pk_pin then
    ImGui.SetNextWindowPos(ctx, pk_pin[1], pk_pin[2], ImGui.Cond_Always)
  end
  -- No collapsing (WindowFlags_NoCollapse), so double-clicking the title bar does nothing.
  -- Older versions could leave the window collapsed (saved by ImGui); always open it.
  ImGui.SetNextWindowCollapsed(ctx, false, ImGui.Cond_Always)
  -- Always set it: ImGui's default window background is only ~94% opaque, so 100% must be explicit.
  ImGui.SetNextWindowBgAlpha(ctx, view.opacity)
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, 0x141414FF) -- solid popups and Settings/summary windows
  -- Title bar in the window's own dark background instead of ImGui's default blue.
  local title_bg = 0x0F0F0F00 | math.floor(view.opacity * 255 + 0.5)
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg, title_bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive, title_bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgCollapsed, title_bg)
  local visible, open = ImGui.Begin(ctx, "Wwise Tool", true, ImGui.WindowFlags_NoCollapse)
  if visible then
    main_win_pos[1], main_win_pos[2] = ImGui.GetWindowPos(ctx)
    main_win_docked = ImGui.IsWindowDocked(ctx)
    -- Re-read the Wwise selection when coming back to this window (e.g. after clicking in Wwise).
    -- AnyWindow: our own popups (like the summary) don't count as leaving. Right after a
    -- transfer (render dialog, Wwise busy importing) focus changes are ignored for a bit.
    local focused = ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_AnyWindow)
    if focused and not was_focused and r.time_precise() > quiet_until then
      sel_poll_at = 0; forget_existing(); last_sig = nil
    end
    was_focused = focused
    section_connection()
    ImGui.Spacing(ctx)
    -- Layout: setup on the left, preview + transfer on the right.
    local avail_w = ImGui.GetContentRegionAvail(ctx)
    local left_w = math.floor(math.max(340, math.min(440, avail_w * 0.42)))
    if ImGui.BeginChild(ctx, "setup", left_w, 0, ImGui.ChildFlags_Border) then
      presets_button("settings", "Settings presets...",
        "Save or load everything except the Wwise structure: source, destination, Originals\n" ..
        "subfolder, conflict choice, Initial Delay, and the render and transfer options in Settings.\n" ..
        "Loading one leaves the Wwise structure as it is.")
      section_source()
      section_destination()
      section_hierarchy()
      ImGui.EndChild(ctx)
    end
    ImGui.SameLine(ctx)
    if ImGui.BeginChild(ctx, "previewpane", 0, 0) then
      section_preview()
      section_transfer()
      ImGui.EndChild(ctx)
    end
    summary_popup()
    settings_popup()
    ImGui.End(ctx)
  end
  ImGui.PopStyleColor(ctx, 4)
  return open
end

start_connect()
r.defer(loop)
