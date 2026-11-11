-- @description Remove missing scripts from action list
-- @author Jay Sabins
-- @version 1.0.0
-- @changelog Initial release
-- @about
--   Combs through every script registered in the Action List (all sections:
--   Main, MIDI Editor, Media Explorer...) and finds the ones whose script file
--   no longer exists on disk. Shows them in a list so you can pick which to
--   remove, backs up reaper-kb.ini first, then unregisters them.
--
--   Without ReaImGui it falls back to a simple Yes/No prompt that removes all
--   missing scripts at once.

local r = reaper
local TITLE = "Remove missing scripts from action list"

----------------------------------------------------------------------
-- Paths
----------------------------------------------------------------------
local SEP = package.config:sub(1, 1)
local RESOURCE = r.GetResourcePath()
local KB_INI = RESOURCE .. SEP .. "reaper-kb.ini"
local SCRIPTS_DIR = RESOURCE .. SEP .. "Scripts"

local SECTION_NAMES = {
  [0]     = "Main",
  [100]   = "Main (alt recording)",
  [32060] = "MIDI Editor",
  [32061] = "MIDI Event List",
  [32062] = "MIDI Inline Editor",
  [32063] = "Media Explorer",
}

local function section_name(id)
  return SECTION_NAMES[id] or ("Section " .. tostring(id))
end

local function is_absolute(p)
  return p:match("^%a:[\\/]") or p:match("^[\\/]")
end

local function full_path(p)
  if is_absolute(p) then return p end
  return SCRIPTS_DIR .. SEP .. p
end

local function file_exists(p)
  if r.file_exists(p) then return true end
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

----------------------------------------------------------------------
-- reaper-kb.ini parsing
-- Script lines look like:
--   SCR 4 0 RS1234abcd "Custom: My script.lua" "Folder/My script.lua"
-- Strings with spaces are quoted with ", ' or ` (REAPER picks a quote
-- character that isn't inside the string).
----------------------------------------------------------------------
local function tokenize(line)
  local tokens, i, n = {}, 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c == " " or c == "\t" then
      i = i + 1
    elseif c == '"' or c == "'" or c == "`" then
      local close = line:find(c, i + 1, true)
      if not close then close = n + 1 end
      tokens[#tokens + 1] = line:sub(i + 1, close - 1)
      i = close + 1
    else
      local stop = line:find("[ \t]", i) or (n + 1)
      tokens[#tokens + 1] = line:sub(i, stop - 1)
      i = stop
    end
  end
  return tokens
end

local function read_scripts()
  local list = {}
  local f = io.open(KB_INI, "r")
  if not f then return nil end
  for raw in f:lines() do
    local line = raw:gsub("\r$", "")
    if line:sub(1, 4) == "SCR " then
      local t = tokenize(line)
      -- t[1]=SCR t[2]=flags t[3]=section t[4]=command id t[5]=name t[6]=path
      local section = tonumber(t[3])
      local path = t[6]
      if section and path and path ~= "" then
        list[#list + 1] = {
          section = section,
          cmd = t[4] or "",
          name = (t[5] or ""):gsub("^Custom:%s*", ""),
          path = path,
          full = full_path(path),
        }
      end
    end
  end
  f:close()
  return list
end

local function find_missing()
  local all = read_scripts()
  if not all then return nil end
  local missing = {}
  for _, s in ipairs(all) do
    if not file_exists(s.full) then
      s.checked = true
      missing[#missing + 1] = s
    end
  end
  table.sort(missing, function(a, b)
    if a.section ~= b.section then return a.section < b.section end
    return a.name:lower() < b.name:lower()
  end)
  return missing, #all
end

----------------------------------------------------------------------
-- Backup and removal
----------------------------------------------------------------------
local function backup_kb()
  local src = io.open(KB_INI, "rb")
  if not src then return nil end
  local data = src:read("*a")
  src:close()
  local dest = KB_INI .. ".backup-" .. os.date("%Y%m%d-%H%M%S")
  local out = io.open(dest, "wb")
  if not out then return nil end
  out:write(data)
  out:close()
  return dest
end

local function key_of(s)
  return s.section .. "|" .. s.cmd
end

-- Returns removed count, list of entries that are still registered, backup path
local function remove_scripts(entries)
  if #entries == 0 then return 0, {}, nil end
  local backup = backup_kb()
  if not backup then
    return nil, nil, nil
  end

  -- Try the path exactly as stored, then the full path, so it works for
  -- both relative (inside Scripts) and absolute registrations.
  for i, s in ipairs(entries) do
    local last = (i == #entries)
    r.AddRemoveReaScript(false, s.section, s.path, false)
    if s.full ~= s.path then
      r.AddRemoveReaScript(false, s.section, s.full, last)
    elseif last then
      r.AddRemoveReaScript(false, s.section, s.path, true)
    end
  end

  -- Re-read reaper-kb.ini to see what actually went away.
  local still = {}
  local after = read_scripts() or {}
  local present = {}
  for _, s in ipairs(after) do present[key_of(s)] = true end
  local removed = 0
  for _, s in ipairs(entries) do
    local gone = not present[key_of(s)]
    -- Main-section commands can also be checked live, in case the ini
    -- hasn't been rewritten yet.
    if not gone and (s.section == 0 or s.section == 100) and s.cmd ~= "" then
      gone = r.NamedCommandLookup("_" .. s.cmd) == 0
    end
    if gone then removed = removed + 1 else still[#still + 1] = s end
  end
  return removed, still, backup
end

local function report(removed, still, backup)
  if not removed then
    r.ShowMessageBox("Couldn't back up reaper-kb.ini, so nothing was changed.\n\n" .. KB_INI, TITLE, 0)
    return
  end
  local msg = ("Removed %d missing script%s from the Action List."):format(removed, removed == 1 and "" or "s")
  if backup then msg = msg .. "\n\nBackup of the old action list:\n" .. backup end
  if #still > 0 then
    msg = msg .. ("\n\n%d couldn't be removed (they're still registered):"):format(#still)
    for i, s in ipairs(still) do
      if i > 10 then msg = msg .. "\n..." break end
      msg = msg .. "\n- " .. s.name
    end
  end
  r.ShowMessageBox(msg, TITLE, 0)
end

----------------------------------------------------------------------
-- Start
----------------------------------------------------------------------
local missing, total = find_missing()
if not missing then
  r.ShowMessageBox("Couldn't read reaper-kb.ini:\n" .. KB_INI, TITLE, 0)
  return
end

if #missing == 0 then
  r.ShowMessageBox(("Checked %d scripts in the Action List. None are missing."):format(total), TITLE, 0)
  return
end

----------------------------------------------------------------------
-- Fallback without ReaImGui: list in the console, ask Yes/No
----------------------------------------------------------------------
if not r.ImGui_CreateContext then
  r.ClearConsole()
  r.ShowConsoleMsg(("Missing scripts in the Action List (%d):\n\n"):format(#missing))
  for _, s in ipairs(missing) do
    r.ShowConsoleMsg(("[%s] %s\n    %s\n"):format(section_name(s.section), s.name, s.full))
  end
  local ans = r.ShowMessageBox(
    ("Found %d missing script%s (listed in the console).\n\n" ..
     "Remove all of them from the Action List?\nreaper-kb.ini is backed up first.\n\n" ..
     "(Install ReaImGui to pick them one by one.)"):format(#missing, #missing == 1 and "" or "s"),
    TITLE, 4)
  if ans == 6 then report(remove_scripts(missing)) end
  return
end

----------------------------------------------------------------------
-- ReaImGui window
----------------------------------------------------------------------
local ctx = r.ImGui_CreateContext(TITLE)
local filter = ""
local status = ("Checked %d scripts, %d missing."):format(total, #missing)

local function matches(s)
  if filter == "" then return true end
  local f = filter:lower()
  return s.name:lower():find(f, 1, true) or s.full:lower():find(f, 1, true)
end

local function count_checked()
  local n = 0
  for _, s in ipairs(missing) do if s.checked then n = n + 1 end end
  return n
end

local function rescan()
  local m, t = find_missing()
  missing = m or {}
  total = t or 0
  status = ("Checked %d scripts, %d missing."):format(total, #missing)
end

local function do_remove()
  local picked = {}
  for _, s in ipairs(missing) do if s.checked then picked[#picked + 1] = s end end
  if #picked == 0 then return end
  local ans = r.ShowMessageBox(
    ("Remove %d script%s from the Action List?\n\nreaper-kb.ini is backed up first. " ..
     "Any shortcuts or toolbar buttons pointing at them will stop working " ..
     "(they already don't, since the files are gone)."):format(#picked, #picked == 1 and "" or "s"),
    TITLE, 4)
  if ans ~= 6 then return end
  local removed, still, backup = remove_scripts(picked)
  report(removed, still, backup)
  rescan()
end

local function draw()
  r.ImGui_Text(ctx, status)
  r.ImGui_SameLine(ctx)
  if r.ImGui_SmallButton(ctx, "Rescan") then rescan() end

  r.ImGui_SetNextItemWidth(ctx, -1)
  local changed, txt = r.ImGui_InputTextWithHint(ctx, "##filter", "Filter by name or path", filter)
  if changed then filter = txt end

  if r.ImGui_Button(ctx, "Check all") then
    for _, s in ipairs(missing) do if matches(s) then s.checked = true end end
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Uncheck all") then
    for _, s in ipairs(missing) do if matches(s) then s.checked = false end end
  end

  local flags = r.ImGui_TableFlags_Borders() | r.ImGui_TableFlags_RowBg() |
                r.ImGui_TableFlags_Resizable() | r.ImGui_TableFlags_ScrollY()
  local footer = r.ImGui_GetFrameHeightWithSpacing(ctx) + 4
  if r.ImGui_BeginTable(ctx, "missing", 4, flags, 0, -footer) then
    r.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
    r.ImGui_TableSetupColumn(ctx, "", r.ImGui_TableColumnFlags_WidthFixed(), 24)
    r.ImGui_TableSetupColumn(ctx, "Action", r.ImGui_TableColumnFlags_WidthStretch(), 2)
    r.ImGui_TableSetupColumn(ctx, "Section", r.ImGui_TableColumnFlags_WidthFixed(), 110)
    r.ImGui_TableSetupColumn(ctx, "Missing file", r.ImGui_TableColumnFlags_WidthStretch(), 3)
    r.ImGui_TableHeadersRow(ctx)
    for i, s in ipairs(missing) do
      if matches(s) then
        r.ImGui_TableNextRow(ctx)
        r.ImGui_TableSetColumnIndex(ctx, 0)
        local _, v = r.ImGui_Checkbox(ctx, "##c" .. i, s.checked)
        s.checked = v
        r.ImGui_TableSetColumnIndex(ctx, 1)
        r.ImGui_Text(ctx, s.name)
        r.ImGui_TableSetColumnIndex(ctx, 2)
        r.ImGui_Text(ctx, section_name(s.section))
        r.ImGui_TableSetColumnIndex(ctx, 3)
        r.ImGui_Text(ctx, s.full)
        if r.ImGui_IsItemHovered(ctx) then r.ImGui_SetTooltip(ctx, s.full) end
      end
    end
    r.ImGui_EndTable(ctx)
  end

  local n = count_checked()
  if n == 0 then r.ImGui_BeginDisabled(ctx) end
  if r.ImGui_Button(ctx, ("Remove %d checked"):format(n)) then do_remove() end
  if n == 0 then r.ImGui_EndDisabled(ctx) end
end

local function loop()
  r.ImGui_SetNextWindowSize(ctx, 820, 460, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, TITLE, true)
  if visible then
    draw()
    r.ImGui_End(ctx)
  end
  if open then r.defer(loop) end
end

r.defer(loop)
