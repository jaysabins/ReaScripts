-- @description Name folder items and nested folder items by track and number them per region
-- @author Jay Sabins
-- @version 1.0.0
-- @changelog Initial release: like "Name folder items by track and number them per region", but nested folder items are renamed too
-- @about
--   Same as "Name folder items by track and number them per region", but nested folder
--   items under a selected folder item are renamed too, each with its own folder
--   track's name. Regular child items (media items on non-folder tracks) are still left
--   alone, so NVK Folder Items' auto-select (which selects the children too) can stay on.
--
--   Each folder item gets its folder track's name plus a counter: Footsteps_01,
--   Footsteps_02... The counter starts again at 01 inside each region and counts left
--   to right. Each folder track keeps its own count.
--
--   Which items: the selected items. If no items are selected, every item on the
--   selected tracks is used. From those, every folder item (any item on a folder track,
--   at any nesting level) is renamed. Items that aren't folder items are skipped.
--
--   Folder items with a take have the take renamed; empty ones get the item notes set,
--   which is the text REAPER shows on an empty item.
--
--   Items that don't start inside a region are left alone (change SKIP_OUTSIDE_REGIONS
--   below to number them too). If regions overlap, the one that starts latest wins.
--   Fully undoable.

local r = reaper
local TITLE = "Name folder and nested folder items by track"

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

local function is_folder_track(tr)
  return r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1
end

-- Keep every folder item (any item on a folder track, so NVK folder items with takes
-- count), nested ones included. Everything else is a child or loose item and is skipped.
local function folder_items_only(items)
  local kept = {}
  for _, it in ipairs(items) do
    if is_folder_track(r.GetMediaItem_Track(it)) then kept[#kept + 1] = it end
  end
  return kept, #items - #kept
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
  local all = collect_items()
  if #all == 0 then
    r.ShowMessageBox("Select some folder items, or select folder tracks to use all their items.", TITLE, 0)
    return false
  end
  local items, ignored = folder_items_only(all)
  if #items == 0 then
    r.ShowMessageBox("None of the selected items are folder items (items on a folder track), so there is nothing to rename.", TITLE, 0)
    return false
  end

  local regions = get_regions()
  if #regions == 0 and SKIP_OUTSIDE_REGIONS then
    r.ShowMessageBox("There are no regions in this project, so there is nothing to number.", TITLE, 0)
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
      " folder item(s) don't start inside a region and were left as they were." ..
      (ignored > 0 and ("\n" .. ignored .. " child or non-folder item(s) were ignored.") or ""), TITLE, 0)
  end
  return renamed > 0
end

r.PreventUIRefresh(1)
r.Undo_BeginBlock()
local changed = main()
r.Undo_EndBlock("Name folder and nested folder items by track and number per region", changed and -1 or 0)
r.PreventUIRefresh(-1)
r.UpdateArrange()
