-- @description Wwise Transfer (send REAPER audio to Wwise)
-- @author Jay Sabins
-- @version 1.2.0
-- @changelog
--   Back to HTTP only. Nothing extra to install (the Mavriq Lua Sockets option is removed).
--   A refused connection now explains the fix: set "Allow connections from" to 127.0.0.1,::1 in Wwise's User Preferences.
-- @provides
--   [main] JS_Wwise Transfer - Quick send.lua
--   [nomain] JS_WwiseTransfer_core.lua
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
local core = dofile(script_dir .. "JS_WwiseTransfer_core.lua")

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
local conn, conn_err = nil, nil
local plan = { entries = {}, errors = {} }
local presets = core.load_presets()
local preset_name = ""
local selected_row = 0           -- 0 = leaf
local summary = nil
local status_line = ""
local last_sig, last_check, last_sel_poll = nil, 0, 0
local wwise_sel_path = nil
local dirty_settings = false
local open_summary = false

local COLOR_OK = 0x6BCB77FF
local COLOR_BAD = 0xFF6B6BFF
local COLOR_DIM = 0x9A9A9AFF
local COLOR_NEW = 0x7FC8F8FF

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

local function refresh_preview(force)
  local now = r.time_precise()
  if S.use_wwise_selection and conn and now - last_sel_poll > 2 then
    last_sel_poll = now
    local p = core.wwise_selection_path()
    if p ~= wwise_sel_path then wwise_sel_path = p; last_sig = nil end
  end
  if not force and now - last_check < 0.3 then return end
  last_check = now
  local sig = signature()
  if sig == last_sig and not force then return end
  local s2 = core.json.decode(core.json.encode(S))
  s2.destination = current_destination()
  plan = core.build_plan(s2, conn)
  if conn and plan.destination ~= "" then
    local _, err = core.mark_existing(plan)
    if err == "offline" then conn = nil; conn_err = "Lost connection to Wwise." end
  end
  last_sig = signature() -- building the plan can bump REAPER's change counter
  if dirty_settings then core.save_settings(S); dirty_settings = false end
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
  if conn then
    ImGui.TextColored(ctx, COLOR_OK, "Connected")
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, "to " .. (conn.version or "Wwise") .. (conn.project and ("  -  project " .. conn.project) or ""))
  else
    ImGui.TextColored(ctx, COLOR_BAD, "Not connected to Wwise")
  end
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, conn and "Refresh" or "Connect") then connect() end
  if not conn and conn_err then
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextColored(ctx, COLOR_DIM, conn_err)
    ImGui.PopTextWrapPos(ctx)
  end
end

local function section_source()
  ImGui.SeparatorText(ctx, "Source")
  local changed
  changed, S.source = combo("##source", { { "items", "Selected items" }, { "render", "REAPER render settings (regions, stems, matrix...)" } }, S.source, 340)
  if changed then settings_changed() end
  if S.source == "items" then
    local c
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
  else
    if ImGui.Button(ctx, "Open render settings...") then r.Main_OnCommand(40015, 0) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Region render matrix...") then r.Main_OnCommand(41888, 0) end
    ImGui.TextColored(ctx, COLOR_DIM, "Files render where your render settings say, then import from there.")
  end
end

local function section_destination()
  ImGui.SeparatorText(ctx, "Wwise destination")
  local c
  c, S.use_wwise_selection = ImGui.Checkbox(ctx, "Always use the object selected in Wwise", S.use_wwise_selection)
  if c then settings_changed(); last_sel_poll = 0 end
  if S.use_wwise_selection then
    ImGui.TextColored(ctx, COLOR_DIM, "Import destination: " .. (wwise_sel_path or "(nothing selected in Wwise)"))
  else
    S.destination = input("Import destination##dest", S.destination, "\\Actor-Mixer Hierarchy\\Default Work Unit", -170)
    from_wwise_button("dest", function(p) S.destination = p end)
  end
  S.originals_subfolder = input("Originals subfolder##orig", S.originals_subfolder, "optional, e.g. Weapons\\$region", -170)
  wildcard_menu("orig", function(w) S.originals_subfolder = S.originals_subfolder .. w end)
end

local function section_hierarchy()
  ImGui.SeparatorText(ctx, "Wwise structure (hierarchy mapping)")
  ImGui.TextColored(ctx, COLOR_DIM, "Levels created under the destination, top to bottom. Names can use wildcards.")

  local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg | ImGui.TableFlags_SizingStretchProp
  if ImGui.BeginTable(ctx, "map", 4, flags) then
    ImGui.TableSetupColumn(ctx, "Type", ImGui.TableColumnFlags_WidthFixed, 160)
    ImGui.TableSetupColumn(ctx, "Name", ImGui.TableColumnFlags_WidthStretch, 2)
    ImGui.TableSetupColumn(ctx, "Property template", ImGui.TableColumnFlags_WidthStretch, 2)
    ImGui.TableSetupColumn(ctx, "", ImGui.TableColumnFlags_WidthFixed, 96)
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
      ImGui.SetNextItemWidth(ctx, -28)
      ch, v = ImGui.InputTextWithHint(ctx, "##tmpl", "optional", row.template or "")
      if ch then row.template = v; settings_changed() end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "W##t") then
        local _, err, o = core.wwise_selection_path()
        if o then row.template = o.path; settings_changed() else status_line = err or "" end
      end
      if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Use the object selected in Wwise as this level's property template") end
      ImGui.TableNextColumn(ctx)
      if ImGui.SmallButton(ctx, "Up") and i > 1 then move = { i, i - 1 } end
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Dn") and i < #S.rows then move = { i, i + 1 } end
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "X") then remove = i end
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
    ImGui.SetNextItemWidth(ctx, -28)
    ch, v = ImGui.InputTextWithHint(ctx, "##leaftmpl", "optional", S.leaf.template)
    if ch then S.leaf.template = v; settings_changed() end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "W##lt") then
      local _, err, o = core.wwise_selection_path()
      if o then S.leaf.template = o.path; settings_changed() else status_line = err or "" end
    end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Use the object selected in Wwise as the Sounds' property template") end
    ImGui.TableNextColumn(ctx)
    ImGui.TextDisabled(ctx, "Sound")
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

local function section_conflicts()
  ImGui.SeparatorText(ctx, "If objects already exist")
  local c
  c, S.conflict = combo("If a Sound or container exists", core.CONFLICT_OPS, S.conflict, 300)
  if c then settings_changed() end
  c, S.apply_template = combo("Apply property templates", core.TEMPLATE_OPS, S.apply_template, 300)
  if c then settings_changed() end
  c, S.select_in_wwise = ImGui.Checkbox(ctx, "Select imported Sounds in Wwise afterwards", S.select_in_wwise)
  if c then settings_changed() end
end

local function section_preview()
  local n = #plan.entries
  ImGui.SeparatorText(ctx, string.format("Preview (%d file%s)", n, n == 1 and "" or "s"))
  local problems = core.validate(S)
  for _, p in ipairs(problems) do ImGui.TextColored(ctx, COLOR_BAD, "- " .. p) end
  for _, p in ipairs(plan.errors or {}) do ImGui.TextColored(ctx, COLOR_BAD, "- " .. p) end
  if plan.dest_missing then ImGui.TextColored(ctx, COLOR_BAD, "- The import destination doesn't exist in Wwise.") end

  local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg | ImGui.TableFlags_ScrollY | ImGui.TableFlags_Resizable
  local h = math.max(120, select(2, ImGui.GetContentRegionAvail(ctx)) - 60)
  if ImGui.BeginTable(ctx, "preview", 3, flags, 0, h) then
    ImGui.TableSetupScrollFreeze(ctx, 0, 1)
    ImGui.TableSetupColumn(ctx, "Wwise object", ImGui.TableColumnFlags_WidthStretch, 4)
    ImGui.TableSetupColumn(ctx, "Status", ImGui.TableColumnFlags_WidthFixed, 80)
    ImGui.TableSetupColumn(ctx, "Audio", ImGui.TableColumnFlags_WidthFixed, 110)
    ImGui.TableHeadersRow(ctx)
    local dest = plan.destination or ""
    for i, e in ipairs(plan.entries) do
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      if e.plain then
        local shown = e.plain
        if dest ~= "" and shown:sub(1, #dest) == dest then shown = "..." .. shown:sub(#dest + 1) end
        ImGui.Text(ctx, shown)
        if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, e.path) end
      else
        ImGui.TextColored(ctx, COLOR_BAD, "(a wildcard didn't resolve for " .. (e.name or "?") .. ")")
      end
      ImGui.TableNextColumn(ctx)
      if e.duplicate then ImGui.TextColored(ctx, COLOR_BAD, "Duplicate")
      elseif e.exists == nil then ImGui.TextDisabled(ctx, "-")
      elseif e.exists then ImGui.TextColored(ctx, COLOR_DIM, "Exists")
      else ImGui.TextColored(ctx, COLOR_NEW, "New") end
      ImGui.TableNextColumn(ctx)
      local kind = ({ direct = "Direct (no render)", render = "Render item", folder = "Render folder", project = "Render" })[e.kind] or ""
      ImGui.TextDisabled(ctx, kind)
      if e.origsub and ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Originals\\" .. e.origsub) end
    end
    ImGui.EndTable(ctx)
  end
end

local function do_transfer()
  core.save_settings(S)
  status_line = "Transferring..."
  local s2 = core.json.decode(core.json.encode(S))
  local t0 = r.time_precise()
  summary = core.transfer(s2, conn, function(msg) status_line = msg end)
  summary.seconds = r.time_precise() - t0
  summary.destination = s2.destination
  status_line = ""
  open_summary = true
  last_sig = nil
end

local function section_transfer()
  local problems = core.validate(S)
  local can = conn and #plan.entries > 0 and #problems == 0 and current_destination() ~= ""
  if not can then ImGui.BeginDisabled(ctx) end
  if ImGui.Button(ctx, "Transfer to Wwise", -1, 34) then do_transfer() end
  if not can then ImGui.EndDisabled(ctx) end
  if status_line ~= "" then ImGui.TextColored(ctx, COLOR_DIM, status_line) end
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
    if s.seconds then ImGui.TextDisabled(ctx, string.format("Took %.2f s", s.seconds)) end
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

local function section_settings()
  if ImGui.CollapsingHeader(ctx, "Connection settings") then
    ImGui.SetNextItemWidth(ctx, 100)
    local c, v = ImGui.InputInt(ctx, "WAAPI HTTP port", S.http_port)
    if c then S.http_port = v; settings_changed() end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Reconnect") then core.disconnect(); connect() end
    ImGui.TextColored(ctx, COLOR_DIM, "Must match Wwise > Project > User Preferences > Wwise Authoring API.")
  end
end

----------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------
local function loop()
  refresh_preview(false)
  ImGui.SetNextWindowSize(ctx, 760, 820, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "Wwise Transfer", true)
  if visible then
    section_connection()
    section_source()
    section_destination()
    section_hierarchy()
    section_conflicts()
    section_settings()
    section_preview()
    section_transfer()
    summary_popup()
    ImGui.End(ctx)
  end
  if open then
    r.defer(loop)
  else
    core.save_settings(S)
  end
end

connect()
refresh_preview(true)
r.defer(loop)
