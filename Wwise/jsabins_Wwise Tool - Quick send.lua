-- Wwise Tool - Quick send
-- Part of the "Wwise Tool" package by Jay Sabins.
-- Sends the selected items (or your render settings, if the window is set to
-- that) to Wwise using the Wwise Tool window's last settings, without
-- opening the window. Assign it a shortcut for one-key transfers.

local r = reaper
local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[\\/])") or ""
local core = dofile(script_dir .. "jsabins_WwiseTool_core.lua")

local s = core.load_settings()
core.http_port = s.http_port

local summary = core.transfer(s)

if #summary.errors > 0 then
  local head = summary.imported > 0
    and string.format("Sent %d file(s) to Wwise, with problems:\n\n", summary.imported)
    or "Nothing was sent to Wwise.\n\n"
  r.ShowMessageBox(head .. table.concat(summary.errors, "\n"), "Wwise Tool", 0)
end
r.defer(function() end) -- no undo point
