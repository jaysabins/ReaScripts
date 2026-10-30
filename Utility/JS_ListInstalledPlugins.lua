-- @description List installed plugins
-- @author Jay Sabins
-- @version 1.0.0
-- @changelog Initial public release
-- @about Writes a text list of every plugin REAPER knows about, grouped by format, to the resource folder and opens it. Requires REAPER 6.37+.

-- List Installed Plugins.lua
-- Writes a text list of every plugin REAPER knows about, grouped by format,
-- saves it to your REAPER resource folder, and opens it.
-- Requires REAPER 6.37+ (for reaper.EnumInstalledFX).

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
local INCLUDE_IDENT   = false  -- true = also list the plugin file / identifier
local OPEN_WHEN_DONE  = true   -- open the text file after writing it
local OUTPUT_FILENAME = os.date("%y%m%d") .. "_InstalledPlugins.txt"

---------------------------------------------------------------------------
if not reaper.EnumInstalledFX then
  reaper.MB("This script needs REAPER 6.37 or newer.", "List Installed Plugins", 0)
  return
end

-- Collect plugins, grouped by the format prefix REAPER uses ("VST3", "CLAP", "JS"...)
local groups, groupOrder, total = {}, {}, 0
local i = 0
while true do
  local ok, name, ident = reaper.EnumInstalledFX(i)
  if not ok then break end

  local fmt, plugName = name:match("^([^:]+):%s*(.+)$")
  if not fmt then fmt, plugName = "Other", name end

  if not groups[fmt] then
    groups[fmt] = {}
    groupOrder[#groupOrder + 1] = fmt
  end
  table.insert(groups[fmt], { name = plugName, ident = ident or "" })
  total = total + 1
  i = i + 1
end

if total == 0 then
  reaper.MB("No plugins found. Try rescanning in Preferences > Plug-ins.", "List Installed Plugins", 0)
  return
end

-- Sort formats and plugins alphabetically (case-insensitive)
local function lower_lt(a, b) return a:lower() < b:lower() end
table.sort(groupOrder, lower_lt)

-- Build the text
local lines = {}
local function add(s) lines[#lines + 1] = s end

add("REAPER Installed Plugins")
add("Generated: " .. os.date("%Y-%m-%d %H:%M"))
add("REAPER " .. reaper.GetAppVersion())
add("Total: " .. total)
add(string.rep("=", 60))

for _, fmt in ipairs(groupOrder) do
  local list = groups[fmt]
  table.sort(list, function(a, b) return lower_lt(a.name, b.name) end)
  add("")
  add(string.format("[%s]  (%d)", fmt, #list))
  add(string.rep("-", 60))
  for _, p in ipairs(list) do
    if INCLUDE_IDENT and p.ident ~= "" then
      add(p.name .. "    |    " .. p.ident)
    else
      add(p.name)
    end
  end
end

local text = table.concat(lines, "\n")

-- Write the file
local sep = package.config:sub(1, 1)
local path = reaper.GetResourcePath() .. sep .. OUTPUT_FILENAME
local f, err = io.open(path, "w")
if not f then
  reaper.MB("Couldn't write file:\n" .. tostring(err), "List Installed Plugins", 0)
  return
end
f:write(text)
f:close()

-- Copy to clipboard if SWS is installed
if reaper.CF_SetClipboard then reaper.CF_SetClipboard(text) end

-- Open the file
if OPEN_WHEN_DONE then
  if reaper.CF_ShellExecute then
    reaper.CF_ShellExecute(path)
  elseif reaper.GetOS():match("Win") then
    os.execute('start "" "' .. path .. '"')
  else
    os.execute('open "' .. path .. '"')
  end
end

reaper.ShowConsoleMsg(string.format("Listed %d plugins -> %s\n", total, path))

