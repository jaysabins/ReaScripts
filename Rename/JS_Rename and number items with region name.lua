-- @description Rename and number items with region name
-- @author Jay Sabins
-- @version 1.0.0
-- @changelog Initial public release
-- @about Renames selected items to their region's name plus a two-digit counter (Region_01, Region_02...).

function main()
  local sep = "_"
  local occur_map = {}
  
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    item = reaper.GetSelectedMediaItem(0, i)
    pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    markeridx, regionidx = reaper.GetLastMarkerAndCurRegion( 0, pos )
    if regionidx > - 1 then
      local retval, isrgn, pos, rgnend, name, markrgnindexnumber, color = reaper.EnumProjectMarkers3( 0, regionidx )
      if not occur_map[name] then occur_map[name] = 0 end
      occur_map[name] = occur_map[name] + 1
      reaper.GetSetMediaItemTakeInfo_String(reaper.GetActiveTake(item),"P_NAME", name .. sep .. getNumSuffix(occur_map[name]), true)
    end
  end
end

function getNumSuffix(index)
  local idx_str = tostring(index)
  if idx_str:len() == 1 then 
    return "0" .. idx_str
  else
    return idx_str
  end
end

reaper.PreventUIRefresh(1)
reaper.Undo_BeginBlock()
main()
reaper.Undo_EndBlock("Name and enumerate items from regions",-1)
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
