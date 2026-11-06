-- @description Name items by track and number them per region
-- @author Jay Sabins
-- @version 1.0.0
-- @changelog Initial public release
-- @about
--   Renames items to their track's name plus a counter: Footsteps_01, Footsteps_02...
--   The counter starts again at 01 inside each region and counts left to right.
--   Each track keeps its own count, so two tracks in the same region both start at 01.
--
--   Which items: the selected items. If no items are selected, every item on the
--   selected tracks is used.
--
--   Works on normal items (the take is renamed) and on empty items such as folder
--   items (the item notes are set, which is the text REAPER shows on an empty item).
--
--   Items that don't start inside a region are left alone (change SKIP_OUTSIDE_REGIONS
--   below to number them too). If regions overlap, the one that starts latest wins.
--   Fully undoable.

local r = reaper

----------------------------------------------------------------------
-- USER CONFIG
----------------------------------------------------------------------
local SEPARATOR = "_"            -- between track name and number
local PAD_DIGITS = 2             -- 2 = 01, 02... ; 1 = 1, 2... ; 3 = 001...
local SKIP_OUTSIDE_REGIONS = true -- false = number items outside regions as their own group
----------------------------------------------------------------------

local function get_regions()
  local regions = {}
  local _, num_markers, num_regions = r.CountProjectMarkers(0)
  for i = 0, num_markers + num_regions - 1 do
    local _, isrgn, pos, rgnend, _, idx = r.EnumProjectMarkers3(0, i)
    if isrgn then regions[#regions + 1] = { start = pos, stop = rgnend, id = idx } end
  end
  return regions
end

-- Region the position falls in (latest-starting one if they overlap), or nil.
local function region_at(regions, pos)
  local best
  for _, rg in ipairs(regions) do
    if pos >= rg.start - 1e-9 and pos < rg.stop - 1e-9 then
      if not best or rg.start > best.start then best = rg end
    end
  end
  return best
end

local function collect_items()
  local items = {}
  local n_sel = r.CountSelectedMediaItems(0)
  if n_sel > 0 then
    for i = 0, n_sel - 1 do items[#items + 1] = r.GetSelectedMediaItem(0, i) end
  else
    for t = 0, r.CountSelectedTracks(0) - 1 do
      local tr = r.GetSelectedTrack(0, t)
      for i = 0, r.CountTrackMediaItems(tr) - 1 do
        items[#items + 1] = r.GetTrackMediaItem(tr, i)
      end
    end
  end
  return items
end

local function track_name(tr)
  local _, name = r.GetTrackName(tr) -- falls back to "Track N" when unnamed
  return name
end

local function set_item_name(item, name)
  local take = r.GetActiveTake(item)
  if take then
    r.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true)
  else
    r.GetSetMediaItemInfo_String(item, "P_NOTES", name, true)
  end
end

local function main()
  local items = collect_items()
  if #items == 0 then
    r.ShowMessageBox("Select some items, or select tracks to use all their items.", "Name items by track", 0)
    return false
  end

  local regions = get_regions()
  if #regions == 0 and SKIP_OUTSIDE_REGIONS then
    r.ShowMessageBox("There are no regions in this project, so there is nothing to number.", "Name items by track", 0)
    return false
  end

  -- Sort left to right (then by track order) so numbering follows time.
  local list = {}
  for _, item in ipairs(items) do
    local tr = r.GetMediaItem_Track(item)
    list[#list + 1] = {
      item = item,
      track = tr,
      tr_idx = r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"),
      pos = r.GetMediaItemInfo_Value(item, "D_POSITION"),
    }
  end
  table.sort(list, function(a, b)
    if math.abs(a.pos - b.pos) > 1e-9 then return a.pos < b.pos end
    return a.tr_idx < b.tr_idx
  end)

  local counts, renamed, skipped = {}, 0, 0
  local fmt = "%0" .. math.max(PAD_DIGITS, 1) .. "d"
  for _, e in ipairs(list) do
    local rg = region_at(regions, e.pos)
    if rg or not SKIP_OUTSIDE_REGIONS then
      local key = tostring(e.track) .. "|" .. (rg and tostring(rg.id) or "none")
      counts[key] = (counts[key] or 0) + 1
      set_item_name(e.item, track_name(e.track) .. SEPARATOR .. string.format(fmt, counts[key]))
      renamed = renamed + 1
    else
      skipped = skipped + 1
    end
  end

  if skipped > 0 then
    r.ShowMessageBox(renamed .. " item(s) renamed.\n" .. skipped ..
      " item(s) don't start inside a region and were left as they were.", "Name items by track", 0)
  end
  return renamed > 0
end

r.PreventUIRefresh(1)
r.Undo_BeginBlock()
local changed = main()
r.Undo_EndBlock("Name items by track and number per region", changed and -1 or 0)
r.PreventUIRefresh(-1)
r.UpdateArrange()
