-- @description Split rapid-fire gunshots into single shots and spread them out
-- @author Jay Sabins
-- @version 1.0.0
-- @changelog Initial release
-- @about
--   Select one or more items that each hold a rapid-fire burst (machine gun, SMG,
--   auto rifle...) and run the script. It finds every shot's transient, splits the
--   item just before each one, and spreads the shots out along the timeline with a
--   gap between them, so every shot ends up as its own item.
--
--   Each shot runs from just before its transient up to the next shot (the last
--   shot keeps the full tail). You can cap the shot length, set fades, number the
--   shots in their take names and add a region per shot, ready for rendering.
--
--   The window shows a live preview of the selected item's waveform with every
--   detected shot marked, so you can tune the detection before you split.
--   Later items on the same track are moved out of the way (optional).
--   Fully undoable.
--
--   Requires ReaImGui (install it from ReaPack).

local r = reaper
local SECTION = "jsabins_SplitRapidFire"
local TITLE = "Split Rapid-Fire Shots"

----------------------------------------------------------------------
-- USER CONFIG
----------------------------------------------------------------------
local HOP_MS      = 1    -- envelope resolution used for detection
local LOOKBACK_MS = 5    -- how far back the attack jump is measured
local MAX_ITEM_S  = 600  -- skip analysing items longer than this
----------------------------------------------------------------------

if not r.ImGui_CreateContext then
  r.ShowMessageBox(
    "This script needs the ReaImGui extension.\n\n" ..
    "Install it from Extensions > ReaPack > Browse packages (search \"ReaImGui\"), " ..
    "then restart REAPER and run the script again.", TITLE, 0)
  if r.ReaPack_BrowsePackages then r.ReaPack_BrowsePackages("ReaImGui") end
  return
end

local SILENCE_DB = -150

local function pos_of(it) return r.GetMediaItemInfo_Value(it, "D_POSITION") end
local function len_of(it) return r.GetMediaItemInfo_Value(it, "D_LENGTH") end

----------------------------------------------------------------------
-- SETTINGS (remembered between runs)
----------------------------------------------------------------------
local DEFAULTS = {
  rise_db = 8,       -- how sharply the level must jump to count as a new shot
  floor_db = -30,    -- ignore anything quieter than this (relative to the item's peak)
  min_ms = 40,       -- minimum time between two shots
  preroll_ms = 3,    -- split this far before each transient
  max_ms = 0,        -- cap each shot's length (0 = up to the next shot)
  fadein_ms = 1,
  fadeout_ms = 10,
  spread = true,     -- false = split in place
  gap = 0.5,         -- seconds between spread shots
  ripple = true,     -- move later items on the same track out of the way
  rename = true,     -- number the shots in their take names
  regions = false,   -- add a region per shot
}

local function load_settings()
  local s = {}
  for k, def in pairs(DEFAULTS) do
    s[k] = def
    if r.HasExtState(SECTION, k) then
      local v = r.GetExtState(SECTION, k)
      if type(def) == "boolean" then s[k] = v == "1"
      else s[k] = tonumber(v) or def end
    end
  end
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
-- ANALYSIS
----------------------------------------------------------------------

-- Peak level (dB) of every HOP_MS window of the item, all channels combined.
local function compute_env(item)
  local take = r.GetActiveTake(item)
  if not take or r.TakeIsMIDI(take) then return nil, "not audio" end
  local len = len_of(item)
  if len > MAX_ITEM_S then return nil, "too long" end
  local src = r.GetMediaItemTake_Source(take)
  local sr = r.GetMediaSourceSampleRate(src)
  if not sr or sr <= 0 then sr = 48000 end
  local nch = math.max(1, r.GetMediaSourceNumChannels(src))

  local hop_n = math.max(1, math.floor(sr * HOP_MS / 1000 + 0.5))
  local hop = hop_n / sr
  local nwin = math.floor(len / hop)
  if nwin < 1 then return nil, "too short" end

  local acc = r.CreateTakeAudioAccessor(take)
  local block_w = 256
  local buf = r.new_array(block_w * hop_n * nch)
  local db, peak = {}, SILENCE_DB
  local per_win = hop_n * nch

  for w0 = 0, nwin - 1, block_w do
    local cnt_w = math.min(block_w, nwin - w0)
    local cnt = cnt_w * hop_n
    buf.clear()
    r.GetAudioAccessorSamples(acc, sr, nch, w0 * hop, cnt, buf)
    local t = buf.table(1, cnt * nch)
    for w = 0, cnt_w - 1 do
      local m, base = 0, w * per_win
      for j = base + 1, base + per_win do
        local v = t[j]
        if v < 0 then v = -v end
        if v > m then m = v end
      end
      local d = m > 1e-8 and 20 * math.log(m, 10) or SILENCE_DB
      db[w0 + w + 1] = d
      if d > peak then peak = d end
    end
  end
  r.DestroyAudioAccessor(acc)

  return { db = db, n = nwin, hop = hop, peak = peak, len = len }
end

-- Transient times (seconds from item start).
local function detect(env, o)
  local onsets = {}
  if env.peak <= SILENCE_DB then return onsets end
  local db, hop = env.db, env.hop
  local floor_db = env.peak + o.floor_db
  local k = math.max(1, math.floor(LOOKBACK_MS / 1000 / hop + 0.5))
  local minsp = math.max(1, math.floor(o.min_ms / 1000 / hop + 0.5))
  local last = -math.huge

  for i = 1, env.n do
    local v = db[i]
    if v >= floor_db and i - last >= minsp then
      local lo, lo_i = math.huge, i - 1
      for j = i - k, i - 1 do
        local u = j >= 1 and db[j] or SILENCE_DB
        if u < lo then lo, lo_i = u, j end
      end
      if v - lo >= o.rise_db then
        -- the attack starts right after the quietest window before the jump
        onsets[#onsets + 1] = math.max(0, lo_i) * hop
        last = i
      end
    end
  end
  return onsets
end

-- Shots as { start, len, onset } in seconds from item start.
local function plan_shots(env, onsets, o)
  local shots = {}
  local pre = o.preroll_ms / 1000
  local prev = -math.huge
  local starts = {}
  for _, t in ipairs(onsets) do
    local s = math.max(0, t - pre)
    if s < prev + 0.001 then s = prev + 0.001 end
    if s < env.len - 0.001 then
      starts[#starts + 1] = { s = s, onset = t }
      prev = s
    end
  end
  for k, st in ipairs(starts) do
    local e = starts[k + 1] and starts[k + 1].s or env.len
    local l = e - st.s
    if o.max_ms > 0 then l = math.min(l, o.max_ms / 1000) end
    shots[#shots + 1] = { start = st.s, len = l, onset = st.onset }
  end
  return shots
end

----------------------------------------------------------------------
-- SELECTION + CACHE
----------------------------------------------------------------------
local cache = {} -- item -> { key, env, err }

local function item_key(item)
  local take = r.GetActiveTake(item)
  if not take then return "none" end
  local src = r.GetMediaItemTake_Source(take)
  return table.concat({
    tostring(take), len_of(item),
    r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
    r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
    r.GetMediaSourceFileName(src, ""),
  }, "|")
end

local function get_env(item)
  local key = item_key(item)
  local c = cache[item]
  if not c or c.key ~= key then
    local env, err = compute_env(item)
    c = { key = key, env = env, err = err }
    cache[item] = c
  end
  return c.env, c.err
end

local function take_label(item)
  local take = r.GetActiveTake(item)
  local name = take and r.GetTakeName(take) or ""
  if name == "" then name = "(unnamed)" end
  return name
end

local function collect_items()
  local items = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    local tr = r.GetMediaItem_Track(it)
    items[#items + 1] = {
      item = it, track = tr,
      tidx = r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"),
      pos = pos_of(it), name = take_label(it),
    }
  end
  table.sort(items, function(a, b)
    if a.tidx ~= b.tidx then return a.tidx < b.tidx end
    return a.pos < b.pos
  end)
  -- drop cache entries for items no longer selected
  local keep = {}
  for _, e in ipairs(items) do keep[e.item] = true end
  for it in pairs(cache) do if not keep[it] then cache[it] = nil end end
  return items
end

----------------------------------------------------------------------
-- APPLY
----------------------------------------------------------------------
local function base_name(name)
  return (name:gsub("%.[%w]+$", ""))
end

-- Split one item into its shots. Returns pieces, old end, new end.
local function split_item(item, shots, o)
  local track = r.GetMediaItem_Track(item)
  local pos = pos_of(item)
  local old_end = pos + len_of(item)
  local name = base_name(take_label(item))

  local cur = item
  if shots[1].start > 1e-6 then
    -- drop the lead-in before the first shot
    local right = r.SplitMediaItem(cur, pos + shots[1].start)
    if not right then return nil end
    r.DeleteTrackMediaItem(track, cur)
    cur = right
  end

  local pieces = {}
  for k = 2, #shots do
    local right = r.SplitMediaItem(cur, pos + shots[k].start)
    if not right then break end
    pieces[#pieces + 1] = cur
    cur = right
  end
  pieces[#pieces + 1] = cur

  local digits = math.max(2, #tostring(#pieces))
  local fin, fout = o.fadein_ms / 1000, o.fadeout_ms / 1000
  local next_pos = pos + shots[1].start
  for k, it in ipairs(pieces) do
    local l = shots[k].len
    r.SetMediaItemInfo_Value(it, "D_LENGTH", l)
    r.SetMediaItemInfo_Value(it, "D_FADEINLEN", math.min(fin, l / 2))
    r.SetMediaItemInfo_Value(it, "D_FADEOUTLEN", math.min(fout, l / 2))
    r.SetMediaItemInfo_Value(it, "D_FADEINLEN_AUTO", 0)
    r.SetMediaItemInfo_Value(it, "D_FADEOUTLEN_AUTO", 0)
    if o.spread then
      r.SetMediaItemInfo_Value(it, "D_POSITION", next_pos)
      next_pos = next_pos + l + o.gap
    end
    local shot_name = ("%s_%0" .. digits .. "d"):format(name, k)
    if o.rename then
      local take = r.GetActiveTake(it)
      if take then r.GetSetMediaItemTakeInfo_String(take, "P_NAME", shot_name, true) end
    end
    if o.regions then
      local p = pos_of(it)
      r.AddProjectMarker2(0, true, p, p + l, shot_name, -1, 0)
    end
    r.SetMediaItemSelected(it, true)
  end

  local last = pieces[#pieces]
  local new_end = pos_of(last) + len_of(last)
  return pieces, old_end, new_end
end

local function apply(items, o)
  -- plan everything first, from the untouched items
  local plans, total_shots = {}, 0
  for _, e in ipairs(items) do
    local env = get_env(e.item)
    if env then
      local shots = plan_shots(env, detect(env, o), o)
      if #shots > 0 then
        plans[e.item] = shots
        total_shots = total_shots + #shots
      end
    end
  end
  if total_shots == 0 then return 0, 0 end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  r.Main_OnCommand(40289, 0) -- Item: Unselect all items

  -- group by track and work left to right, so each item's growth pushes the next ones
  local tracks, seen = {}, {}
  for _, e in ipairs(items) do
    if plans[e.item] and not seen[e.track] then
      seen[e.track] = true
      tracks[#tracks + 1] = e.track
    end
  end

  local done_items, done_shots = 0, 0
  for _, tr in ipairs(tracks) do
    local list = {}
    for i = 0, r.CountTrackMediaItems(tr) - 1 do
      local it = r.GetTrackMediaItem(tr, i)
      list[#list + 1] = { item = it, pos = pos_of(it) }
    end
    table.sort(list, function(a, b) return a.pos < b.pos end)

    local offset, started = 0, false
    for _, e in ipairs(list) do
      local shots = plans[e.item]
      if shots then
        started = true
        if offset ~= 0 then r.SetMediaItemInfo_Value(e.item, "D_POSITION", e.pos + offset) end
        local pieces, old_end, new_end = split_item(e.item, shots, o)
        if pieces then
          done_items = done_items + 1
          done_shots = done_shots + #pieces
          if o.spread then offset = offset + (new_end - old_end) end
        end
      elseif started and o.ripple and offset ~= 0 then
        r.SetMediaItemInfo_Value(e.item, "D_POSITION", e.pos + offset)
      end
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(("Split %d items into %d single shots"):format(done_items, done_shots), -1)
  return done_items, done_shots
end

----------------------------------------------------------------------
-- GUI
----------------------------------------------------------------------
local ctx = r.ImGui_CreateContext(TITLE)
local opt = load_settings()
local items, last_state = {}, nil
local preview_idx = 1
local status = ""

local PREVIEW_W, PREVIEW_H = 460, 120
local COL_BG      = 0x1E1E1EFF
local COL_BAND    = 0xFFFFFF10
local COL_WAVE    = 0x5FB4C8FF
local COL_FLOOR   = 0xD8B44A90
local COL_ONSET   = 0xE05050FF
local COL_CUT     = 0x00000090

local function refresh_items()
  local state = r.GetProjectStateChangeCount(0)
  if state == last_state then return end
  last_state = state
  items = collect_items()
  if preview_idx > #items then preview_idx = math.max(1, #items) end
end

local function label(text)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Text(ctx, text)
  r.ImGui_SameLine(ctx, 170)
end

local function tooltip(text)
  if r.ImGui_IsItemHovered(ctx) then r.ImGui_SetTooltip(ctx, text) end
end

local function draw_preview(env, shots)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local x0, y0 = r.ImGui_GetCursorScreenPos(ctx)
  local W, H = PREVIEW_W, PREVIEW_H
  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + W, y0 + H, COL_BG)

  local function tx(t) return x0 + (t / env.len) * W end
  local range = 60
  local function ty(d)
    local f = (d - (env.peak - range)) / range
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    return y0 + H - f * H
  end

  -- alternate bands per shot, and darken anything cut off by max length
  for k, s in ipairs(shots) do
    if k % 2 == 0 then
      r.ImGui_DrawList_AddRectFilled(dl, tx(s.start), y0, tx(s.start + s.len), y0 + H, COL_BAND)
    end
    local e = shots[k + 1] and shots[k + 1].start or env.len
    if s.start + s.len < e - 1e-6 then
      r.ImGui_DrawList_AddRectFilled(dl, tx(s.start + s.len), y0, tx(e), y0 + H, COL_CUT)
    end
  end
  if shots[1] and shots[1].start > 0 then
    r.ImGui_DrawList_AddRectFilled(dl, x0, y0, tx(shots[1].start), y0 + H, COL_CUT)
  end

  -- waveform envelope
  local n = env.n
  for x = 0, W - 1 do
    local a = math.floor(x * n / W) + 1
    local b = math.max(a, math.floor((x + 1) * n / W))
    local m = SILENCE_DB
    for i = a, math.min(b, n) do
      local d = env.db[i]
      if d > m then m = d end
    end
    local y = ty(m)
    if y < y0 + H then
      r.ImGui_DrawList_AddLine(dl, x0 + x + 0.5, y0 + H, x0 + x + 0.5, y, COL_WAVE, 1)
    end
  end

  -- detection floor
  local fy = ty(env.peak + opt.floor_db)
  r.ImGui_DrawList_AddLine(dl, x0, fy, x0 + W, fy, COL_FLOOR, 1)

  -- shot starts
  for _, s in ipairs(shots) do
    local x = tx(s.onset)
    r.ImGui_DrawList_AddLine(dl, x, y0, x, y0 + H, COL_ONSET, 1)
  end

  r.ImGui_Dummy(ctx, W, H)
  if r.ImGui_IsItemHovered(ctx) then
    local mx = r.ImGui_GetMousePos(ctx)
    local t = math.max(0, math.min(env.len, (mx - x0) / W * env.len))
    r.ImGui_SetTooltip(ctx, ("%.3f s\nRed = shot starts\nYellow = detection floor"):format(t))
  end
end

local memo_sig, memo_counts, memo_total = nil, {}, 0

local function analyse()
  local counts, total = {}, 0
  for i, e in ipairs(items) do
    local env, err = get_env(e.item)
    if env then
      local shots = plan_shots(env, detect(env, opt), opt)
      counts[i] = { n = #shots, env = env, shots = shots }
      total = total + #shots
    else
      counts[i] = { n = 0, err = err }
    end
  end
  return counts, total
end

local function draw()
  refresh_items()
  local rv

  -- Items + preview ---------------------------------------------------------
  local sig = table.concat({ last_state, opt.rise_db, opt.floor_db, opt.min_ms, opt.preroll_ms, opt.max_ms }, "|")
  if sig ~= memo_sig then
    memo_sig = sig
    memo_counts, memo_total = analyse()
  end
  local counts, total = memo_counts, memo_total

  if #items == 0 then
    r.ImGui_TextWrapped(ctx,
      "Select one or more items that hold a rapid-fire burst.\n" ..
      "Each shot gets split out and spread along the timeline.")
    r.ImGui_Dummy(ctx, PREVIEW_W, 0)
  else
    r.ImGui_Text(ctx, ("%d shots found in %d item%s"):format(total, #items, #items == 1 and "" or "s"))

    local function item_text(i)
      local c = counts[i]
      local extra = c.err and ("(" .. c.err .. ")") or ("%d shots"):format(c.n)
      return ("%d. %s  [%s]"):format(i, items[i].name, extra)
    end

    label("Preview")
    r.ImGui_SetNextItemWidth(ctx, PREVIEW_W - 170)
    if r.ImGui_BeginCombo(ctx, "##preview", item_text(preview_idx)) then
      for i = 1, #items do
        if r.ImGui_Selectable(ctx, item_text(i) .. "##" .. i, i == preview_idx) then preview_idx = i end
      end
      r.ImGui_EndCombo(ctx)
    end

    local c = counts[preview_idx]
    if c and c.env then
      draw_preview(c.env, c.shots)
    else
      r.ImGui_Dummy(ctx, PREVIEW_W, PREVIEW_H)
    end
  end

  r.ImGui_Separator(ctx)

  -- Detection -----------------------------------------------------------------
  r.ImGui_Text(ctx, "Detection")
  label("  Attack jump")
  r.ImGui_SetNextItemWidth(ctx, 220)
  rv, opt.rise_db = r.ImGui_SliderDouble(ctx, "##rise", opt.rise_db, 2, 30, "%.1f dB")
  tooltip("How sharply the level has to jump to count as a new shot.\nLower = more sensitive (finds more shots).")

  label("  Ignore below")
  r.ImGui_SetNextItemWidth(ctx, 220)
  rv, opt.floor_db = r.ImGui_SliderDouble(ctx, "##floor", opt.floor_db, -60, -3, "%.0f dB from peak")
  tooltip("Transients quieter than this (relative to the item's loudest point) are ignored.")

  label("  Min time between")
  r.ImGui_SetNextItemWidth(ctx, 220)
  rv, opt.min_ms = r.ImGui_SliderDouble(ctx, "##min", opt.min_ms, 5, 500, "%.0f ms")
  tooltip("Two shots can't be closer than this.\n600 RPM = 100 ms, 900 RPM = 67 ms, 1200 RPM = 50 ms.")

  r.ImGui_Separator(ctx)

  -- Shots -----------------------------------------------------------------------
  r.ImGui_Text(ctx, "Shots")
  label("  Pre-roll")
  r.ImGui_SetNextItemWidth(ctx, 220)
  rv, opt.preroll_ms = r.ImGui_SliderDouble(ctx, "##pre", opt.preroll_ms, 0, 20, "%.1f ms")
  tooltip("Split this far before each transient so the attack stays intact.")

  label("  Max length")
  r.ImGui_SetNextItemWidth(ctx, 220)
  rv, opt.max_ms = r.ImGui_SliderDouble(ctx, "##max", opt.max_ms, 0, 3000,
    opt.max_ms <= 0 and "Up to next shot" or "%.0f ms")
  tooltip("Cap each shot's length. All the way left = each shot runs up to the next one\n(the last shot keeps its full tail).")

  label("  Fade in / out")
  r.ImGui_SetNextItemWidth(ctx, 105)
  rv, opt.fadein_ms = r.ImGui_InputDouble(ctx, "##fin", opt.fadein_ms, 0, 0, "%.1f ms")
  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, 105)
  rv, opt.fadeout_ms = r.ImGui_InputDouble(ctx, "##fout", opt.fadeout_ms, 0, 0, "%.1f ms")
  if opt.fadein_ms < 0 then opt.fadein_ms = 0 end
  if opt.fadeout_ms < 0 then opt.fadeout_ms = 0 end

  r.ImGui_Separator(ctx)

  -- Placement -------------------------------------------------------------------
  label("Placement")
  if r.ImGui_RadioButton(ctx, "Spread out", opt.spread) then opt.spread = true end
  r.ImGui_SameLine(ctx)
  if r.ImGui_RadioButton(ctx, "Split in place", not opt.spread) then opt.spread = false end

  r.ImGui_BeginDisabled(ctx, not opt.spread)
  label("  Gap (seconds)")
  r.ImGui_SetNextItemWidth(ctx, 120)
  rv, opt.gap = r.ImGui_InputDouble(ctx, "##gap", opt.gap, 0.1, 1.0, "%.2f")
  if opt.gap < 0 then opt.gap = 0 end
  rv, opt.ripple = r.ImGui_Checkbox(ctx, "Move later items on the track out of the way", opt.ripple)
  r.ImGui_EndDisabled(ctx)

  rv, opt.rename = r.ImGui_Checkbox(ctx, "Number the shots in take names (Name_01, Name_02...)", opt.rename)
  rv, opt.regions = r.ImGui_Checkbox(ctx, "Create a region per shot", opt.regions)

  r.ImGui_Separator(ctx)

  -- Split -----------------------------------------------------------------------
  r.ImGui_BeginDisabled(ctx, total == 0)
  if r.ImGui_Button(ctx, ("Split into %d shots"):format(total), 200, 0) then
    save_settings(opt)
    local n_items, n_shots = apply(items, opt)
    status = ("Split %d item%s into %d shots. Ctrl+Z to undo."):format(
      n_items, n_items == 1 and "" or "s", n_shots)
    last_state = nil
  end
  r.ImGui_EndDisabled(ctx)
  r.ImGui_SameLine(ctx)
  r.ImGui_Text(ctx, status)
end

local function loop()
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
