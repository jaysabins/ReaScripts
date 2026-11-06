-- @description Measure timing between selected layers (for Wwise initial delay)
-- @author Jay Sabins (based on a script by bfieser)
-- @version 1.0.0
-- @changelog Initial release
-- @about
--   Select any number of items (e.g. the 4+ layers of a gunshot) and run the script.
--   Items are sorted by position and the console shows, for each layer:
--     - its offset from the first layer (use this as the Initial Delay in Wwise)
--     - its offset from the previous layer
--   in both milliseconds and seconds, labelled with the take and track name.
--
--   Wwise's Initial Delay property is in seconds, so the "Delay (s)" column can be
--   pasted straight in. The breakdown is also copied to the clipboard when SWS is installed.
--
--   Based on "Measure distance in seconds between selected media items" by bfieser,
--   which measured the gap between two items.
--
--   No extensions required.

local r = reaper

----------------------------------------------------------------------
-- USER CONFIG
----------------------------------------------------------------------
local USE_SNAP_OFFSET = false -- true = measure from each item's snap offset instead of its start
local NAME_WIDTH      = 28    -- max characters shown for layer/track names
----------------------------------------------------------------------

local count = r.CountSelectedMediaItems(0)
if count < 2 then
  r.ShowMessageBox("Select at least two items (one per layer).", "Measure layer timing", 0)
  return
end

local function fit(s, w)
  s = s or ""
  if #s > w then s = s:sub(1, w - 1) .. "~" end
  return s .. string.rep(" ", w - #s)
end

local function lpad(s, w)
  return string.rep(" ", w - #s) .. s
end

local function ms(sec) return string.format("%.1f", sec * 1000) end
local function s4(sec) return string.format("%.4f", sec) end

-- Gather selected items
local layers = {}
for i = 0, count - 1 do
  local item  = r.GetSelectedMediaItem(0, i)
  local pos   = r.GetMediaItemInfo_Value(item, "D_POSITION")
  if USE_SNAP_OFFSET then
    pos = pos + r.GetMediaItemInfo_Value(item, "D_SNAPOFFSET")
  end
  local track = r.GetMediaItem_Track(item)
  local _, trackName = r.GetTrackName(track)
  local trackIdx = r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")

  local take = r.GetActiveTake(item)
  local takeName = take and r.GetTakeName(take) or ""
  if takeName == "" then takeName = "(empty item)" end

  layers[#layers + 1] = {
    pos = pos, take = takeName, track = trackName, trackIdx = trackIdx,
  }
end

-- Sort by position, then by track order for items that start together
table.sort(layers, function(a, b)
  if math.abs(a.pos - b.pos) > 1e-9 then return a.pos < b.pos end
  return a.trackIdx < b.trackIdx
end)

local first = layers[1].pos
local lines = {}
local function add(s) lines[#lines + 1] = s end

add(string.format("Layer timing: %d items, sorted by position%s",
  #layers, USE_SNAP_OFFSET and " (snap offsets)" or ""))
add(string.format("First layer starts at %s", r.format_timestr_pos(first, "", 0)))
add("")

local header = lpad("#", 3) .. "  " .. fit("Layer", NAME_WIDTH) .. "  " .. fit("Track", NAME_WIDTH) ..
  "  " .. lpad("Delay (ms)", 10) .. "  " .. lpad("Delay (s)", 9) ..
  "  " .. lpad("From prev (ms)", 14)
add(header)
add(string.rep("-", #header))

for i, L in ipairs(layers) do
  local fromFirst = L.pos - first
  local fromPrev  = i > 1 and (L.pos - layers[i - 1].pos) or nil
  add(lpad(tostring(i), 3) .. "  " .. fit(L.take, NAME_WIDTH) .. "  " .. fit(L.track, NAME_WIDTH) ..
    "  " .. lpad(ms(fromFirst), 10) .. "  " .. lpad(s4(fromFirst), 9) ..
    "  " .. lpad(fromPrev and ms(fromPrev) or "-", 14))
end

add("")
add(string.format("Total spread (first to last): %s ms  (%s s)",
  ms(layers[#layers].pos - first), s4(layers[#layers].pos - first)))

local text = table.concat(lines, "\n")

local copied = false
if r.CF_SetClipboard then
  r.CF_SetClipboard(text)
  copied = true
end

r.ClearConsole()
r.ShowConsoleMsg(text .. "\n")
if copied then r.ShowConsoleMsg("\n(Copied to clipboard)\n") end
