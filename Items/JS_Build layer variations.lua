-- @description Build aligned layer variations (gunshots, impacts, etc.)
-- @author Jay Sabins
-- @version 1.0.0
-- @changelog Initial public release
-- @about
--   Each track = one layer. The items on that track (left to right) = that layer's variations.
--   Select the layer items (or just the layer tracks) and run.
--
--   Default mode: builds N variations side by side, every layer aligned in each slot.
--     Variation 1 = file 1 of every layer, variation 2 = file 2, etc.
--     Layers with fewer files cycle (or pick randomly, if chosen). A layer with
--     one file is reused in every variation.
--   Combo mode: builds every possible combination of layer files.
--
--   Alignment: item start (default) or first transient per item.
--   Optional: one region per variation, ready for Render > Project regions.
--   Fully undoable.

local r = reaper
local SECTION = "JS_BuildLayerVariations"

----------------------------------------------------------------------
-- USER CONFIG
----------------------------------------------------------------------
local TRANSIENT_THRESHOLD_DB = -24 -- onset = first sample within this many dB of the item's own peak
local COMBO_WARN = 200             -- ask before building more combinations than this
----------------------------------------------------------------------

local function msg(s) r.ShowMessageBox(s, "Layer Variations", 0) end

local function pos_of(it) return r.GetMediaItemInfo_Value(it, "D_POSITION") end
local function len_of(it) return r.GetMediaItemInfo_Value(it, "D_LENGTH") end

-- Gather layers: selected items grouped by track, or all items on selected tracks.
local function collect_layers()
  local items = {}
  local nsel = r.CountSelectedMediaItems(0)
  if nsel > 0 then
    for i = 0, nsel - 1 do items[#items + 1] = r.GetSelectedMediaItem(0, i) end
  else
    for t = 0, r.CountSelectedTracks(0) - 1 do
      local tr = r.GetSelectedTrack(0, t)
      for i = 0, r.CountTrackMediaItems(tr) - 1 do
        items[#items + 1] = r.GetTrackMediaItem(tr, i)
      end
    end
  end

  local layers, by_track = {}, {}
  for _, it in ipairs(items) do
    local tr = r.GetMediaItem_Track(it)
    if not by_track[tr] then
      by_track[tr] = { track = tr, idx = r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"), items = {} }
      layers[#layers + 1] = by_track[tr]
    end
    table.insert(by_track[tr].items, it)
  end

  table.sort(layers, function(a, b) return a.idx < b.idx end)
  for _, L in ipairs(layers) do
    table.sort(L.items, function(a, b) return pos_of(a) < pos_of(b) end)
  end
  return layers
end

-- Time (seconds from item start) of the first sample within TRANSIENT_THRESHOLD_DB of the item's peak.
local function find_onset(item)
  local take = r.GetActiveTake(item)
  if not take or r.TakeIsMIDI(take) then return 0 end
  local src = r.GetMediaItemTake_Source(take)
  local nch = math.max(1, r.GetMediaSourceNumChannels(src))
  local sr = 48000
  local total = math.floor(len_of(item) * sr)
  if total <= 0 then return 0 end

  local acc = r.CreateTakeAudioAccessor(take)
  local block = 4096
  local buf = r.new_array(block * nch)

  local function scan(cb)
    local done = 0
    while done < total do
      local cnt = math.min(block, total - done)
      buf.clear()
      r.GetAudioAccessorSamples(acc, sr, nch, done / sr, cnt, buf)
      local t = buf.table(1, cnt * nch)
      for i = 1, cnt * nch do
        if cb(math.abs(t[i]), done + (i - 1) // nch) then return end
      end
      done = done + cnt
    end
  end

  local peak = 0
  scan(function(v) if v > peak then peak = v end return false end)

  local onset = 0
  if peak > 0 then
    local thr = peak * 10 ^ (TRANSIENT_THRESHOLD_DB / 20)
    scan(function(v, s) if v >= thr then onset = s / sr return true end return false end)
  end

  r.DestroyAudioAccessor(acc)
  return onset
end

-- Duplicate an item onto a track at a position, with fresh GUIDs.
local function place_item(track, chunk, pos)
  local fresh = chunk:gsub("{%x+%-%x+%-%x+%-%x+%-%x+}", function() return r.genGuid("") end)
  local it = r.AddMediaItemToTrack(track)
  r.SetItemStateChunk(it, fresh, false)
  r.SetMediaItemInfo_Value(it, "D_POSITION", pos)
  r.SetMediaItemSelected(it, true)
  return it
end

local function main()
  local layers = collect_layers()
  if #layers == 0 then
    msg("Select the layer items (or the layer tracks) first.\n\nEach track = one layer, its items = that layer's variations.")
    return
  end

  local max_count, combos_total = 1, 1
  for _, L in ipairs(layers) do
    max_count = math.max(max_count, #L.items)
    combos_total = combos_total * #L.items
  end

  -- Dialog ------------------------------------------------------------
  local defaults = r.GetExtState(SECTION, "last")
  if defaults == "" then defaults = "0|0.5|0|0|0|1|Gunshot|0" end

  local captions = table.concat({
    "Variations (0 = most files: " .. max_count .. ")",
    "Gap between variations (s)",
    "Mode: 0=aligned 1=all combos (" .. combos_total .. ")",
    "Align by: 0=item start 1=transient",
    "Short layers: 0=cycle 1=random",
    "Create regions (1/0)",
    "Region name prefix",
    "Keep originals (1/0)",
    "separator=|",
    "extrawidth=80",
  }, ",")

  local ok, ret = r.GetUserInputs(
    ("Layer Variations — %d layers"):format(#layers), 8, captions, defaults)
  if not ok then return end
  r.SetExtState(SECTION, "last", ret, true)

  local f = {}
  for s in (ret .. "|"):gmatch("(.-)|") do f[#f + 1] = s end

  local num_var    = math.floor(tonumber(f[1]) or 0)
  if num_var <= 0 then num_var = max_count end
  local gap        = math.max(0, tonumber(f[2]) or 0.5)
  local combo_mode = f[3] == "1"
  local by_onset   = f[4] == "1"
  local rand_fill  = f[5] == "1"
  local regions    = f[6] == "1"
  local prefix     = (f[7] and f[7] ~= "") and f[7] or "Var"
  local keep       = f[8] == "1"

  if combo_mode and combos_total > COMBO_WARN then
    local go = r.ShowMessageBox(
      ("That's %d combinations. Build them all?"):format(combos_total), "Layer Variations", 1)
    if go ~= 1 then return end
  end

  -- Snapshot sources ---------------------------------------------------
  local earliest, latest_end, max_onset = math.huge, 0, 0
  for _, L in ipairs(layers) do
    L.src = {}
    for _, it in ipairs(L.items) do
      local p, l = pos_of(it), len_of(it)
      local _, chunk = r.GetItemStateChunk(it, "", false)
      local onset = by_onset and find_onset(it) or 0
      L.src[#L.src + 1] = { chunk = chunk, len = l, onset = onset }
      earliest = math.min(earliest, p)
      latest_end = math.max(latest_end, p + l)
      max_onset = math.max(max_onset, onset)
    end
  end

  -- Slot length = longest aligned item + gap
  local content = 0
  for _, L in ipairs(layers) do
    for _, s in ipairs(L.src) do
      content = math.max(content, (max_onset - s.onset) + s.len)
    end
  end
  local slot = content + gap

  -- Decide which file each layer uses in each variation -----------------
  local picks = {}
  if combo_mode then
    for k = 0, combos_total - 1 do
      local p, rem = {}, k
      for li = #layers, 1, -1 do -- last layer changes fastest
        local c = #layers[li].src
        p[li] = rem % c + 1
        rem = rem // c
      end
      picks[#picks + 1] = p
    end
  else
    math.randomseed(os.time())
    for v = 1, num_var do
      local p = {}
      for li, L in ipairs(layers) do
        local c = #L.src
        if v <= c or not rand_fill or c == 1 then
          p[li] = (v - 1) % c + 1
        else
          local prev = picks[v - 1][li]
          local pick
          repeat pick = math.random(c) until pick ~= prev
          p[li] = pick
        end
      end
      picks[#picks + 1] = p
    end
  end

  -- Build ----------------------------------------------------------------
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  local start = keep and (latest_end + math.max(gap, 1)) or earliest

  if not keep then
    for _, L in ipairs(layers) do
      for _, it in ipairs(L.items) do
        r.DeleteTrackMediaItem(L.track, it)
      end
    end
  end

  r.Main_OnCommand(40289, 0) -- Item: Unselect all items

  local digits = math.max(2, #tostring(#picks))
  for v, p in ipairs(picks) do
    local slot_start = start + (v - 1) * slot
    for li, L in ipairs(layers) do
      local s = L.src[p[li]]
      place_item(L.track, s.chunk, slot_start + (max_onset - s.onset))
    end
    if regions then
      local name = ("%s_%0" .. digits .. "d"):format(prefix, v)
      if combo_mode then name = name .. "_" .. table.concat(p, "-") end
      r.AddProjectMarker2(0, true, slot_start, slot_start + content, name, -1, 0)
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(("Build %d layer variations"):format(#picks), -1)
end

main()
