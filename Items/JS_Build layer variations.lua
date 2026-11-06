-- @description Build aligned layer variations (gunshots, impacts, etc.)
-- @author Jay Sabins
-- @version 1.1.0
-- @changelog
--   New ReaImGui window replaces the old text-box prompt.
--   Window shows the selected layers and how many files each has, and updates live as you change the selection.
--   Transient threshold is now adjustable in the window.
--   Window stays open after Build so you can tweak and build again.
--   Requires ReaImGui (Extensions > ReaPack > Browse packages > ReaImGui).
-- @about
--   Each track = one layer. The items on that track (left to right) = that layer's variations.
--   Select the layer items (or just the layer tracks), run the script, set options and click Build.
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
--
--   Requires ReaImGui (install it from ReaPack).

local r = reaper
local SECTION = "JS_BuildLayerVariations"

local TITLE = "Layer Variations"

----------------------------------------------------------------------
-- USER CONFIG
----------------------------------------------------------------------
local COMBO_WARN = 200 -- ask before building more combinations than this
----------------------------------------------------------------------

if not r.ImGui_CreateContext then
  r.ShowMessageBox(
    "This script needs the ReaImGui extension.\n\n" ..
    "Install it from Extensions > ReaPack > Browse packages (search \"ReaImGui\"), " ..
    "then restart REAPER and run the script again.", TITLE, 0)
  if r.ReaPack_BrowsePackages then r.ReaPack_BrowsePackages("ReaImGui") end
  return
end

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

-- Time (seconds from item start) of the first sample within threshold_db of the item's peak.
local function find_onset(item, threshold_db)
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
    local thr = peak * 10 ^ (threshold_db / 20)
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


----------------------------------------------------------------------
-- SETTINGS (remembered between runs)
----------------------------------------------------------------------
local DEFAULTS = {
  num_var = 0, gap = 0.5, combo = false, by_onset = false, rand_fill = false,
  regions = true, prefix = "Gunshot", keep = false, thresh_db = -24,
}

local function load_settings()
  local s = {}
  for k, v in pairs(DEFAULTS) do s[k] = v end

  -- Carry over the answers from the old text-box version (v1.0.0) the first time.
  local old = r.GetExtState(SECTION, "last")
  if old ~= "" and not r.HasExtState(SECTION, "gap") then
    local f = {}
    for x in (old .. "|"):gmatch("(.-)|") do f[#f + 1] = x end
    s.num_var   = math.max(0, math.floor(tonumber(f[1]) or 0))
    s.gap       = math.max(0, tonumber(f[2]) or 0.5)
    s.combo     = f[3] == "1"
    s.by_onset  = f[4] == "1"
    s.rand_fill = f[5] == "1"
    s.regions   = f[6] == "1"
    s.prefix    = (f[7] and f[7] ~= "") and f[7] or s.prefix
    s.keep      = f[8] == "1"
  end

  for k, def in pairs(DEFAULTS) do
    if r.HasExtState(SECTION, k) then
      local v = r.GetExtState(SECTION, k)
      if type(def) == "boolean" then s[k] = v == "1"
      elseif type(def) == "number" then s[k] = tonumber(v) or def
      else s[k] = v end
    end
  end
  s.num_var = math.max(0, math.floor(s.num_var))
  return s
end

local function save_settings(s)
  for k, def in pairs(DEFAULTS) do
    local v = s[k]
    if type(def) == "boolean" then v = v and "1" or "0" end
    r.SetExtState(SECTION, k, tostring(v), true)
  end
end

----------------------------------------------------------------------
-- BUILD
----------------------------------------------------------------------
local function count_layers(layers)
  local max_count, combos_total = 1, 1
  for _, L in ipairs(layers) do
    max_count = math.max(max_count, #L.items)
    combos_total = combos_total * #L.items
  end
  return max_count, combos_total
end

-- Returns the number of variations built, or nil if cancelled.
local function build(layers, o)
  local max_count, combos_total = count_layers(layers)
  local num_var = o.num_var > 0 and o.num_var or max_count
  local gap = math.max(0, o.gap)
  local prefix = o.prefix ~= "" and o.prefix or "Var"

  if o.combo and combos_total > COMBO_WARN then
    local go = r.ShowMessageBox(
      ("That's %d combinations. Build them all?"):format(combos_total), TITLE, 1)
    if go ~= 1 then return nil end
  end

  -- Snapshot sources ---------------------------------------------------
  local earliest, latest_end, max_onset = math.huge, 0, 0
  for _, L in ipairs(layers) do
    L.src = {}
    for _, it in ipairs(L.items) do
      local p, l = pos_of(it), len_of(it)
      local _, chunk = r.GetItemStateChunk(it, "", false)
      local onset = o.by_onset and find_onset(it, o.thresh_db) or 0
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
  if o.combo then
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
        if v <= c or not o.rand_fill or c == 1 then
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

  local start = o.keep and (latest_end + math.max(gap, 1)) or earliest

  if not o.keep then
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
    if o.regions then
      local name = ("%s_%0" .. digits .. "d"):format(prefix, v)
      if o.combo then name = name .. "_" .. table.concat(p, "-") end
      r.AddProjectMarker2(0, true, slot_start, slot_start + content, name, -1, 0)
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(("Build %d layer variations"):format(#picks), -1)
  return #picks
end

----------------------------------------------------------------------
-- GUI
----------------------------------------------------------------------
local ctx = r.ImGui_CreateContext(TITLE)
local opt = load_settings()
local layers, last_state = {}, nil
local status = ""

-- Re-read the selection only when the project changes.
local function refresh_layers()
  local state = r.GetProjectStateChangeCount(0)
  if state == last_state then return end
  last_state = state
  layers = collect_layers()
  for _, L in ipairs(layers) do
    local _, name = r.GetTrackName(L.track)
    L.name = name
  end
end

local function label(text)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Text(ctx, text)
  r.ImGui_SameLine(ctx, 130)
end

local function draw()
  refresh_layers()
  local max_count, combos_total = count_layers(layers)
  local rv

  -- Layers --------------------------------------------------------------
  if #layers == 0 then
    r.ImGui_TextWrapped(ctx,
      "Select the layer items (or the layer tracks).\n" ..
      "Each track = one layer, its items = that layer's variations.")
  else
    r.ImGui_Text(ctx, ("%d layers selected"):format(#layers))
    local row_h = r.ImGui_GetTextLineHeightWithSpacing(ctx) + 2
    local h = (math.min(#layers, 8) + 1) * row_h + 4
    local flags = r.ImGui_TableFlags_Borders() | r.ImGui_TableFlags_RowBg() | r.ImGui_TableFlags_ScrollY()
    if r.ImGui_BeginTable(ctx, "layers", 2, flags, 340, h) then
      r.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
      r.ImGui_TableSetupColumn(ctx, "Layer (track)", r.ImGui_TableColumnFlags_WidthStretch())
      r.ImGui_TableSetupColumn(ctx, "Files", r.ImGui_TableColumnFlags_WidthFixed(), 50)
      r.ImGui_TableHeadersRow(ctx)
      for _, L in ipairs(layers) do
        r.ImGui_TableNextRow(ctx)
        r.ImGui_TableNextColumn(ctx)
        r.ImGui_Text(ctx, ("%d. %s"):format(math.floor(L.idx), L.name))
        r.ImGui_TableNextColumn(ctx)
        r.ImGui_Text(ctx, tostring(#L.items))
      end
      r.ImGui_EndTable(ctx)
    end
  end

  r.ImGui_Separator(ctx)

  -- Mode ------------------------------------------------------------------
  label("Mode")
  if r.ImGui_RadioButton(ctx, "Aligned", not opt.combo) then opt.combo = false end
  r.ImGui_SameLine(ctx)
  if r.ImGui_RadioButton(ctx, ("Every combination (%d)"):format(combos_total), opt.combo) then opt.combo = true end

  r.ImGui_BeginDisabled(ctx, opt.combo)
  label("Variations")
  local auto = opt.num_var == 0
  rv, auto = r.ImGui_Checkbox(ctx, ("Most files (%d)"):format(max_count), auto)
  if rv then opt.num_var = auto and 0 or max_count end
  if not auto then
    r.ImGui_SameLine(ctx)
    r.ImGui_SetNextItemWidth(ctx, 90)
    rv, opt.num_var = r.ImGui_InputInt(ctx, "##numvar", opt.num_var, 1, 10)
    if opt.num_var < 1 then opt.num_var = 1 end
  end

  label("Short layers")
  if r.ImGui_RadioButton(ctx, "Cycle", not opt.rand_fill) then opt.rand_fill = false end
  r.ImGui_SameLine(ctx)
  if r.ImGui_RadioButton(ctx, "Random", opt.rand_fill) then opt.rand_fill = true end
  r.ImGui_EndDisabled(ctx)

  label("Gap (seconds)")
  r.ImGui_SetNextItemWidth(ctx, 120)
  rv, opt.gap = r.ImGui_InputDouble(ctx, "##gap", opt.gap, 0.1, 1.0, "%.2f")
  if opt.gap < 0 then opt.gap = 0 end

  label("Align by")
  if r.ImGui_RadioButton(ctx, "Item start", not opt.by_onset) then opt.by_onset = false end
  r.ImGui_SameLine(ctx)
  if r.ImGui_RadioButton(ctx, "First transient", opt.by_onset) then opt.by_onset = true end
  if opt.by_onset then
    label("  Threshold")
    r.ImGui_SetNextItemWidth(ctx, 180)
    rv, opt.thresh_db = r.ImGui_SliderDouble(ctx, "##thresh", opt.thresh_db, -60, -1, "%.0f dB below peak")
  end

  r.ImGui_Separator(ctx)

  rv, opt.regions = r.ImGui_Checkbox(ctx, "Create a region per variation", opt.regions)
  r.ImGui_BeginDisabled(ctx, not opt.regions)
  label("  Region name")
  r.ImGui_SetNextItemWidth(ctx, 180)
  rv, opt.prefix = r.ImGui_InputText(ctx, "##prefix", opt.prefix)
  r.ImGui_EndDisabled(ctx)

  rv, opt.keep = r.ImGui_Checkbox(ctx, "Keep original items", opt.keep)

  r.ImGui_Separator(ctx)

  -- Build -----------------------------------------------------------------
  local n = opt.combo and combos_total or (opt.num_var > 0 and opt.num_var or max_count)
  r.ImGui_BeginDisabled(ctx, #layers == 0)
  if r.ImGui_Button(ctx, ("Build %d variations"):format(#layers == 0 and 0 or n), 200, 0) then
    save_settings(opt)
    local built = build(layers, opt)
    status = built and ("Built %d variations. Ctrl+Z to undo."):format(built) or "Cancelled."
    last_state = nil -- items changed, re-read selection
  end
  r.ImGui_EndDisabled(ctx)
  r.ImGui_SameLine(ctx)
  r.ImGui_Text(ctx, status)
end

local function loop()
  r.ImGui_SetNextWindowSize(ctx, 380, 0, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, TITLE, true, r.ImGui_WindowFlags_AlwaysAutoResize())
  if visible then
    draw()
    if r.ImGui_IsWindowFocused(ctx) and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
      open = false
    end
    r.ImGui_End(ctx)
  end
  if open then
    r.defer(loop)
  else
    save_settings(opt)
  end
end

r.defer(loop)
