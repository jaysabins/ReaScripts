-- @description Wwise Transfer (send REAPER audio to Wwise)
-- @author Jay Sabins
-- @version 1.6.4
-- @changelog
--   Header: shows the Wwise version number again (it only said "Wwise"), and the script version is only in Settings now.
-- @provides
--   [main] jsabins_Wwise Transfer - Quick send.lua
--   [nomain] jsabins_WwiseTransfer_core.lua
-- @about
--   # Wwise Transfer
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
--   - Conflict handling, presets, live preview (new vs existing objects),
--     transfer summary. One Wwise undo step per transfer.
--   - Fast: untouched WAV items import without rendering; edited items render
--     in one pass; everything is imported in one Wwise call.
--
--   "Wwise Transfer - Quick send" sends the selected items with the window's
--   last settings, without opening the window. Give it a shortcut.
--
--   Needs ReaImGui (ReaPack > ReaTeam Extensions) and Wwise with WAAPI on:
--   Wwise > Project > User Preferences > Enable Wwise Authoring API (HTTP port 8090).

local r = reaper
local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or ""
local core = dofile(script_dir .. "jsabins_WwiseTransfer_core.lua")

if not r.ImGui_GetBuiltinPath then
  r.ShowMessageBox("This script needs ReaImGui.\nInstall it from Extensions > ReaPack > Browse packages (search \"ReaImGui\"), then restart REAPER.",
    "Wwise Transfer", 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. "/?.lua"
local ImGui = require "imgui" "0.9"

local ctx = ImGui.CreateContext("Wwise Transfer")

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local S = core.load_settings()
core.http_port = S.http_port
-- Look of the window (same in every project): background opacity and hidden preview columns.
local view = { opacity = 1.0, hidden = {} }
do
  local v = r.GetExtState(core.EXT, "view")
  local ok, t = pcall(core.json.decode, v ~= "" and v or "{}")
  if ok and type(t) == "table" then
    if type(t.opacity) == "number" then view.opacity = math.max(0.2, math.min(1, t.opacity)) end
    if type(t.hidden) == "table" then for k, b in pairs(t.hidden) do if b == true then view.hidden[k] = true end end end
  end
end
local function save_view() r.SetExtState(core.EXT, "view", core.json.encode(view), true) end
local conn, conn_err = nil, nil
local plan = { entries = {}, errors = {} }
local presets = core.load_presets()
local preset_name = ""
local selected_row = 0           -- 0 = leaf
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

local function connect()
  core.http_port = S.http_port
  conn, conn_err = core.connect()
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
  if not ok then status_line = "Error: " .. tostring(err); return nil end
  if coroutine.status(task) == "dead" then return nil end
  return task
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
local function section_connection()
  -- One-line toolbar, right-aligned: status dot, project, Wwise version, Refresh/Connect and
  -- Settings. A connection problem shows as a banner underneath.
  local spacing = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
  local pad_x = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  local function bw(t) return ImGui.CalcTextSize(ctx, t) + pad_x * 2 end
  local lh = ImGui.GetFrameHeight(ctx)
  local dot = 8

  local name = conn and (conn.project or "Wwise") or "Not connected"
  local ver = conn and (conn.version or "") or ""
  local btn = conn and "Refresh" or "Connect"
  local widths = { dot, ImGui.CalcTextSize(ctx, name) }
  if ver ~= "" then widths[#widths + 1] = ImGui.CalcTextSize(ctx, ver) end
  widths[#widths + 1] = spacing          -- divider
  widths[#widths + 1] = bw(btn)
  widths[#widths + 1] = bw("Settings")
  local w = spacing * (#widths - 1)
  for _, x in ipairs(widths) do w = w + x end
  local avail = ImGui.GetContentRegionAvail(ctx)
  if avail > w then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + avail - w) end

  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.DrawList_AddCircleFilled(dl, x + dot / 2, y + lh / 2, dot / 2, conn and COLOR_OK or COLOR_BAD)
  ImGui.Dummy(ctx, dot, lh)
  ImGui.SameLine(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  if conn then ImGui.Text(ctx, name) else ImGui.TextColored(ctx, COLOR_BAD, name) end
  if conn and conn.project_path and ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, conn.project_path) end
  if ver ~= "" then ImGui.SameLine(ctx); ImGui.TextDisabled(ctx, ver) end
  ImGui.SameLine(ctx)
  x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.DrawList_AddLine(dl, x + spacing / 2, y + 4, x + spacing / 2, y + lh - 4, 0x3A4456FF)
  ImGui.Dummy(ctx, spacing, lh)
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, btn) then connect() end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, conn and "Reconnect and re-read the Wwise project" or "Connect to Wwise") end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Settings") then open_settings = true end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Connection, render and after-transfer preferences") end

  if not conn and conn_err then
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, 0x2A2213FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Border, 0x4A3C1FFF)
    if ImGui.BeginChild(ctx, "connerr", 0, 0, ImGui.ChildFlags_Border | ImGui.ChildFlags_AutoResizeY) then
      ImGui.PushTextWrapPos(ctx, 0)
      ImGui.TextColored(ctx, 0xF3D6A0FF, conn_err)
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
  core.waapi("ak.wwise.core.undo.endGroup", { displayName = "Wwise Transfer: set initial delays" })
  if err then status_line = "Couldn't set initial delays: " .. tostring(err)
  else
    status_line = string.format("Set Initial Delay on %d object%s.", n, n == 1 and "" or "s") ..
      (skipped > 0 and string.format(" %d not in Wwise yet (they get it when you transfer).", skipped) or "")
  end
end

local function dim_label(text) ImGui.TextColored(ctx, COLOR_DIM, text) end

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

-- Per-level options popup: property template, move, remove.
local function level_options(id, get_t, set_t, row_index)
  local has = (get_t() or "") ~= ""
  if ImGui.Button(ctx, (has and "T" or "...") .. "##opt" .. id, -1) then ImGui.OpenPopup(ctx, "lvlopt" .. id) end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, has and ("Property template: " .. get_t()) or "Property template, move, remove")
  end
  local action
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
    if row_index then
      ImGui.Separator(ctx)
      if ImGui.Button(ctx, "Move up") then action = "up"; ImGui.CloseCurrentPopup(ctx) end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Move down") then action = "down"; ImGui.CloseCurrentPopup(ctx) end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Remove level") then action = "remove"; ImGui.CloseCurrentPopup(ctx) end
    end
    ImGui.EndPopup(ctx)
  end
  return action
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

    local remove, move = nil, nil
    for i, row in ipairs(S.rows) do
      ImGui.PushID(ctx, tostring(i))
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      local c
      c, row.type = combo("##type", core.CONTAINER_TYPES, row.type, -1)
      if c then settings_changed() end
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -28)
      local ch, v = ImGui.InputTextWithHint(ctx, "##name", "e.g. $region", row.name or "")
      if ch then row.name = v; settings_changed() end
      if ImGui.IsItemActive(ctx) then selected_row = i end
      wildcard_menu("r" .. i, function(w) row.name = (row.name or "") .. w end)
      ImGui.TableNextColumn(ctx)
      local act = level_options("r" .. i, function() return row.template end, function(t) row.template = t end, i)
      if act == "up" and i > 1 then move = { i, i - 1 }
      elseif act == "down" and i < #S.rows then move = { i, i + 1 }
      elseif act == "remove" then remove = i end
      ImGui.PopID(ctx)
    end

    -- Leaf (the Sound itself)
    ImGui.PushID(ctx, "leaf")
    ImGui.TableNextRow(ctx)
    ImGui.TableNextColumn(ctx)
    local c
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
    level_options("leaf", function() return S.leaf.template end, function(t) S.leaf.template = t end, nil)
    ImGui.PopID(ctx)
    ImGui.EndTable(ctx)

    if remove then table.remove(S.rows, remove); settings_changed() end
    if move then S.rows[move[1]], S.rows[move[2]] = S.rows[move[2]], S.rows[move[1]]; settings_changed() end
  end

  if ImGui.Button(ctx, "+ Add level") then
    S.rows[#S.rows + 1] = { type = #S.rows == 0 and "Actor-Mixer" or "Random Container", name = "", template = "" }
    settings_changed()
  end
  if S.leaf.voice then
    ImGui.SameLine(ctx)
    local langs = (conn and #conn.languages > 0) and conn.languages or { S.leaf.language ~= "" and S.leaf.language or "English(US)" }
    local c
    c, S.leaf.language = combo("Voice language", langs, S.leaf.language, 160)
    if c then settings_changed() end
  end

  -- Presets
  ImGui.SameLine(ctx)
  ImGui.Dummy(ctx, 12, 0)
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Presets...") then ImGui.OpenPopup(ctx, "presets") end
  if ImGui.BeginPopup(ctx, "presets") then
    ImGui.Text(ctx, "Load")
    local names = {}
    for n in pairs(presets) do names[#names + 1] = n end
    table.sort(names)
    if #names == 0 then ImGui.TextDisabled(ctx, "  (no presets yet)") end
    for _, n in ipairs(names) do
      if ImGui.Selectable(ctx, "  " .. n, false, ImGui.SelectableFlags_DontClosePopups) then
        core.apply_preset(S, presets[n]); preset_name = n; settings_changed()
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    ImGui.Separator(ctx)
    ImGui.SetNextItemWidth(ctx, 180)
    local _, v = ImGui.InputTextWithHint(ctx, "##pname", "preset name", preset_name)
    preset_name = v
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Save") and preset_name ~= "" then
      presets[preset_name] = core.preset_from(S); core.save_presets(presets)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Delete") and presets[preset_name] then
      presets[preset_name] = nil; core.save_presets(presets)
    end
    ImGui.EndPopup(ctx)
  end
end


local TYPE_COLORS = {
  ["Destination"] = 0xC8C8C8FF, ["Work Unit"] = 0xE0C060FF, ["Virtual Folder"] = 0xB0B0B0FF,
  ["Physical Folder"] = 0xB0B0B0FF, ["Actor-Mixer"] = 0x6FA8FFFF, ["Random Container"] = 0xF2A65AFF,
  ["Sequence Container"] = 0xE07FD0FF, ["Switch Container"] = 0x9B8CFFFF, ["Blend Container"] = 0x5FD3C8FF,
  ["Sound SFX"] = 0x7BD88FFF, ["Sound Voice"] = 0x7BD88FFF, ["Sound"] = 0x7BD88FFF,
}
local TYPE_TAGS = {
  ["Destination"] = "[DEST]", ["Work Unit"] = "[WU]", ["Virtual Folder"] = "[VF]", ["Physical Folder"] = "[PF]",
  ["Actor-Mixer"] = "[AM]", ["Random Container"] = "[RND]", ["Sequence Container"] = "[SEQ]",
  ["Switch Container"] = "[SW]", ["Blend Container"] = "[BLD]", ["Sound SFX"] = "[SFX]", ["Sound Voice"] = "[VO]",
  ["Sound"] = "[SND]",
}
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
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, TYPE_COLORS[node.type] or 0xFFFFFFFF)
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
  ImGui.TableNextColumn(ctx)
  if node.entry then
    local o = core.originals_name(node.entry)
    if o then
      ImGui.TextColored(ctx, COLOR_DIM, o)
      if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Originals\\" .. core.originals_root(S) .. "\\" .. o) end
    end
  end
  ImGui.TableNextColumn(ctx)
  if node.delay then ImGui.Text(ctx, string.format("%.0f ms", node.delay * 1000)) end
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
-- the choice is kept in `view` so it comes back next time.
local PREVIEW_COLS = {
  { id = "Name", stretch = true, w = 4, nohide = true },
  { id = "Status", w = 70 },
  { id = "Audio", w = 120 },
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
    ImGui.TextDisabled(ctx, "  Right-click a column header to choose columns.")
  end

  local flags = ImGui.TableFlags_BordersV | ImGui.TableFlags_BordersOuterH | ImGui.TableFlags_RowBg |
                ImGui.TableFlags_ScrollY | ImGui.TableFlags_Resizable | ImGui.TableFlags_Hideable
  local h = math.max(160, select(2, ImGui.GetContentRegionAvail(ctx)) - 52)
  if ImGui.BeginTable(ctx, "previewtree", #PREVIEW_COLS, flags, 0, h) then
    ImGui.TableSetupScrollFreeze(ctx, 0, 1)
    for _, c in ipairs(PREVIEW_COLS) do
      local cf = c.stretch and ImGui.TableColumnFlags_WidthStretch or ImGui.TableColumnFlags_WidthFixed
      if c.nohide then cf = cf | ImGui.TableColumnFlags_NoHide end
      if view.hidden[c.id] then cf = cf | ImGui.TableColumnFlags_DefaultHide end
      ImGui.TableSetupColumn(ctx, c.id, cf, c.w)
    end
    ImGui.TableHeadersRow(ctx)
    sync_columns()
    if tree and #tree.children > 0 then draw_node(tree, 0) end
    ImGui.EndTable(ctx)
  end
  tree_open_all = nil
end

local function do_transfer()
  core.save_settings(S)
  status_line = "Transferring..."
  local s2 = core.json.decode(core.json.encode(S))
  local t0 = r.time_precise()
  bg_task = nil
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
  if not conn then why = "Not connected to Wwise. Click Connect at the top."
  elseif current_destination() == "" then
    why = S.use_wwise_selection and "Select a parent object in Wwise (or untick \"Always use the object selected in Wwise\")."
      or "Set an import destination."
  elseif #problems > 0 then why = problems[1]
  elseif #plan.entries == 0 then why = (plan.errors and plan.errors[1]) or "Select one or more items in REAPER."
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
  if not can or transfer_task then ImGui.BeginDisabled(ctx) end
  if ImGui.Button(ctx, transfer_task and "Transferring..." or "Transfer to Wwise", bw, 34) and not transfer_task then do_transfer() end
  if not can or transfer_task then ImGui.EndDisabled(ctx) end
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

local function settings_popup()
  if open_settings then ImGui.OpenPopup(ctx, "Settings"); open_settings = false end
  ImGui.SetNextWindowSize(ctx, 500, 0, ImGui.Cond_Appearing)
  if not ImGui.BeginPopupModal(ctx, "Settings", nil, ImGui.WindowFlags_AlwaysAutoResize) then return end
  local c, v

  ImGui.SeparatorText(ctx, "Connection")
  ImGui.SetNextItemWidth(ctx, 100)
  c, v = ImGui.InputInt(ctx, "WAAPI HTTP port", S.http_port)
  if c then S.http_port = v; settings_changed() end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Reconnect") then core.disconnect(); connect() end
  ImGui.PushTextWrapPos(ctx, 480)
  ImGui.TextColored(ctx, COLOR_DIM, "Must match Wwise > Project > User Preferences > Wwise Authoring API (default 8090). " ..
    "\"Allow connections from\" there should be 127.0.0.1,::1.")
  ImGui.PopTextWrapPos(ctx)
  ImGui.Dummy(ctx, 0, 4)

  ImGui.SeparatorText(ctx, "Rendering selected items")
  c, S.skip_render_untouched = ImGui.Checkbox(ctx, "Import untouched WAV files directly (no render)", S.skip_render_untouched)
  if c then settings_changed() end
  help("An item that plays a whole WAV file with no trims, FX, fades, pitch or volume changes\nis imported straight from disk. This is the fastest path.")
  c, S.items_via_master = ImGui.Checkbox(ctx, "Render items through track FX and master", S.items_via_master)
  if c then settings_changed() end
  c, S.folders_via_master = ImGui.Checkbox(ctx, "Render folder items through master", S.folders_via_master)
  if c then settings_changed() end
  help("An empty item on a folder track renders the folder's mix (folder + children)\nover that item's time range, named after the item.")
  c, S.mono_to_mono = ImGui.Checkbox(ctx, "Mono items render as mono files", S.mono_to_mono)
  if c then settings_changed() end
  ImGui.Dummy(ctx, 0, 2)
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
  ImGui.Dummy(ctx, 0, 4)

  ImGui.SeparatorText(ctx, "Transfer")
  dim_label("Paste each level's property template onto:")
  c, S.apply_template = combo("##apply_template", core.TEMPLATE_OPS, S.apply_template, 320)
  if c then settings_changed() end
  help("Templates are set per Structure level with its \"...\" button.\n" ..
    "\"New objects only\" leaves objects that already existed in Wwise as they are.")
  c, S.select_in_wwise = ImGui.Checkbox(ctx, "Select imported Sounds in Wwise afterwards", S.select_in_wwise)
  if c then settings_changed() end
  ImGui.Dummy(ctx, 0, 6)

  ImGui.SeparatorText(ctx, "Window")
  dim_label("Background opacity")
  ImGui.SetNextItemWidth(ctx, 260)
  local pct
  c, pct = ImGui.SliderInt(ctx, "##opacity", math.floor(view.opacity * 100 + 0.5), 20, 100, "%d%%")
  if c then view.opacity = pct / 100 end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then save_view() end
  help("How see-through the Wwise Transfer window's background is. Text and buttons stay solid.\n" ..
    "Only works while the window is floating, not when it's docked.")
  ImGui.Dummy(ctx, 0, 6)

  ImGui.SeparatorText(ctx, "Diagnostics")
  ImGui.PushTextWrapPos(ctx, 480)
  ImGui.TextColored(ctx, COLOR_DIM, string.format("Slow moments recorded: %d. If REAPER stutters or freezes, " ..
    "copy this log and send it over.", #slow_log))
  ImGui.PopTextWrapPos(ctx)
  if ImGui.Button(ctx, "Copy slow-moment log") then
    ImGui.SetClipboardText(ctx, "Wwise Transfer " .. core.VERSION .. "\n" .. table.concat(slow_log, "\n"))
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Clear log") then slow_log = {} end
  ImGui.Dummy(ctx, 0, 6)

  ImGui.Separator(ctx)
  ImGui.TextDisabled(ctx, "Wwise Transfer " .. core.VERSION)
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

loop_body = function()
  if not transfer_task then follow_project_tab() end
  if transfer_task then transfer_task = run_task(transfer_task) end
  refresh_preview(false)
  ImGui.SetNextWindowSize(ctx, 1180, 760, ImGui.Cond_FirstUseEver)
  -- Always set it: ImGui's default window background is only ~94% opaque, so 100% must be explicit.
  ImGui.SetNextWindowBgAlpha(ctx, view.opacity)
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, 0x141414FF) -- solid popups and Settings/summary windows
  local visible, open = ImGui.Begin(ctx, "Wwise Transfer", true)
  if visible then
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
  ImGui.PopStyleColor(ctx)
  return open
end

connect()
refresh_preview(true)
r.defer(loop)
