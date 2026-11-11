-- @description Build a rapid-fire burst from single shots (sausage file)
-- @author Jay Sabins
-- @version 1.0.0
-- @changelog
--   First version.
-- @about
--   Select a "sausage" item holding a row of single shots (or several items, or
--   shots you already split) and run the script. It finds every shot's transient
--   and builds a rapid-fire burst out of them on a new track below, starting at
--   the edit cursor.
--
--   - Rate of fire in RPM or in ms between shots, with an optional ramp
--     (spin-up / spin-down) to a second rate.
--   - Number of shots and the order they're used in: in order, ping-pong,
--     random (no shot twice in a row) or shuffled rounds.
--   - Gain per shot: draw the gain of every shot with the mouse, or start from a
--     preset shape (fade out, fade in, accent first, random) and tweak it.
--   - Humanize timing, gain and pitch.
--   - Shots can ring out over each other or be cut off by the next one.
--   - Click a shot in the waveform to leave it out of the burst.
--
--   With "Live update" on, the last burst you built is rebuilt every time you
--   change a setting, so you can loop playback over it while you dial in the
--   rate and gain. Each change is one undo step.
--
--   Requires ReaImGui (install it from ReaPack).

local r = reaper
local SECTION = "jsabins_RapidFireBuilder"
local TITLE = "Rapid-Fire Builder"
local EXT_KEY = "P_EXT:jsabins_rf_burst"

----------------------------------------------------------------------
-- USER CONFIG
----------------------------------------------------------------------
local HOP_MS      = 1    -- envelope resolution used for detection
local LOOKBACK_MS = 5    -- how far back the attack jump is measured
local MAX_ITEM_S  = 600  -- skip analysing items longer than this
local GAIN_MIN    = -24  -- gain editor range (dB)
local GAIN_MAX    = 6
local MAX_COUNT   = 200
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
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

----------------------------------------------------------------------
-- SETTINGS (remembered between runs)
----------------------------------------------------------------------
local ORDERS = {
  "In order (loops)",
  "Ping-pong",
  "Random (no repeats in a row)",
  "Shuffled rounds (each shot once per round)",
}

local DEFAULTS = {
  -- detection
  rise_db = 8,        -- how sharply the level must jump to count as a new shot
  floor_db = -30,     -- ignore anything quieter than this (relative to the item's peak)
  min_ms = 40,        -- minimum time between two shots
  preroll_ms = 3,     -- each shot starts this far before its transient
  -- burst
  use_ms = false,     -- show the rate as ms between shots instead of RPM
  rpm = 750,
  ramp = false,       -- ramp the rate across the burst
  rpm_end = 1100,
  count = 12,
  order = 1,          -- index into ORDERS
  seed = 1,
  choke = false,      -- cut each shot off when the next one starts
  fadein_ms = 1,
  fadeout_ms = 15,
  jit_ms = 0,         -- humanize: timing
  jit_db = 0,         -- humanize: gain
  jit_cents = 0,      -- humanize: pitch
  region = false,     -- add a region around the burst
  live = true,        -- rebuild the last burst when settings change
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
  s.order = clamp(math.floor(s.order), 1, #ORDERS)
  s.count = clamp(math.floor(s.count), 1, MAX_COUNT)
  return s
end

local function save_settings(s, gains)
  for k, def in pairs(DEFAULTS) do
    local v = s[k]
    if type(def) == "boolean" then v = v and "1" or "0" end
    r.SetExtState(SECTION, k, tostring(v), true)
  end
  local parts = {}
  for i, g in ipairs(gains) do parts[i] = ("%.2f"):format(g) end
  r.SetExtState(SECTION, "gains", table.concat(parts, ","), true)
end

local function load_gains()
  local g = {}
  local s = r.GetExtState(SECTION, "gains")
  for v in s:gmatch("[^,]+") do g[#g + 1] = clamp(tonumber(v) or 0, GAIN_MIN, GAIN_MAX) end
  return g
end

----------------------------------------------------------------------
-- ANALYSIS (same detection as Split rapid-fire shots 1.1.0)
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
        onsets[#onsets + 1] = math.max(0, lo_i) * hop
        last = i
      end
    end
  end
  return onsets
end

-- Shots as { start, len, onset } in seconds from item start. Each runs up to the next.
local function plan_shots(env, onsets, o)
  local shots, starts = {}, {}
  local pre = o.preroll_ms / 1000
  local prev = -math.huge
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
    shots[#shots + 1] = { start = st.s, len = e - st.s, onset = st.onset }
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

local function is_burst_item(it)
  local ok, v = r.GetSetMediaItemInfo_String(it, EXT_KEY, "", false)
  return ok and v ~= ""
end

-- Selected items (bursts this script built are left out), by track then position.
local function collect_items()
  local items = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    if not is_burst_item(it) then
      local tr = r.GetMediaItem_Track(it)
      items[#items + 1] = {
        item = it, track = tr,
        tidx = r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"),
        pos = pos_of(it), name = take_label(it),
        guid = select(2, r.GetSetMediaItemInfo_String(it, "GUID", "", false)),
      }
    end
  end
  table.sort(items, function(a, b)
    if a.tidx ~= b.tidx then return a.tidx < b.tidx end
    return a.pos < b.pos
  end)
  local keep = {}
  for _, e in ipairs(items) do keep[e.item] = true end
  for it in pairs(cache) do if not keep[it] then cache[it] = nil end end
  return items
end

----------------------------------------------------------------------
-- BURST PLANNING
----------------------------------------------------------------------

-- Small seeded random generator, so the same seed always gives the same burst.
local function make_rng(seed)
  local s = (math.floor(seed) * 2654435761 + 12345) % 4294967296
  if s == 0 then s = 1 end
  return function()
    s = (1103515245 * s + 12345) % 2147483648
    return s / 2147483648
  end
end

local function sequence(P, N, order, rnd)
  local seq = {}
  if P == 1 then
    for k = 1, N do seq[k] = 1 end
  elseif order == 1 then
    for k = 1, N do seq[k] = (k - 1) % P + 1 end
  elseif order == 2 then
    local period = 2 * P - 2
    for k = 1, N do
      local i = (k - 1) % period
      seq[k] = i < P and i + 1 or period - i + 1
    end
  elseif order == 3 then
    local prev
    for k = 1, N do
      local v
      repeat v = math.floor(rnd() * P) + 1 until v ~= prev
      seq[k], prev = v, v
    end
  else
    local prev
    while #seq < N do
      local round = {}
      for i = 1, P do round[i] = i end
      for i = P, 2, -1 do
        local j = math.floor(rnd() * i) + 1
        round[i], round[j] = round[j], round[i]
      end
      if round[1] == prev then round[1], round[P] = round[P], round[1] end
      for i = 1, P do
        if #seq < N then seq[#seq + 1] = round[i] end
      end
      prev = seq[#seq]
    end
  end
  return seq
end

-- Gain of every shot in the editor, resampled when the shot count changes.
local function resample(g, n)
  local m = #g
  local out = {}
  if m == 0 then
    for i = 1, n do out[i] = 0 end
  elseif m == 1 or n == 1 then
    for i = 1, n do out[i] = g[1] end
  else
    for i = 1, n do
      local x = (i - 1) / (n - 1) * (m - 1) + 1
      local a = math.floor(x)
      local b = math.min(m, a + 1)
      local f = x - a
      out[i] = g[a] * (1 - f) + g[b] * f
    end
  end
  return out
end

local function interval_at(o, k, N)
  local rpm = o.rpm
  if o.ramp and N > 2 then
    rpm = o.rpm + (o.rpm_end - o.rpm) * (k - 1) / (N - 2)
  elseif o.ramp and N == 2 then
    rpm = o.rpm
  end
  return 60 / math.max(1, rpm)
end

-- The burst as a list of { src, t, len, gain, cents } (t from the burst start).
local function plan_burst(pool, o, gains)
  local P, N = #pool, o.count
  local out = {}
  if P == 0 then return out, 0 end
  local rnd = make_rng(o.seed)
  local seq = sequence(P, N, o.order, rnd)
  local jt, jg, jp = make_rng(o.seed + 101), make_rng(o.seed + 202), make_rng(o.seed + 303)
  local function jit(rng, amount) return (rng() * 2 - 1) * amount end

  local grid = 0
  local prev_t = -math.huge
  for k = 1, N do
    local t = grid
    if k > 1 then t = t + jit(jt, o.jit_ms / 1000) end
    if t < prev_t + 0.001 then t = prev_t + 0.001 end
    if t < 0 then t = 0 end
    out[k] = {
      src = pool[seq[k]], idx = seq[k], t = t,
      gain = (gains[k] or 0) + jit(jg, o.jit_db),
      cents = jit(jp, o.jit_cents),
    }
    prev_t = t
    grid = grid + interval_at(o, k, N)
  end

  local total = 0
  local fout = o.fadeout_ms / 1000
  for k, s in ipairs(out) do
    local l = s.src.len
    if o.choke and out[k + 1] then
      l = math.min(l, out[k + 1].t - s.t + fout)
    end
    s.len = math.max(0.005, l)
    total = math.max(total, s.t + s.len)
  end
  return out, total
end

----------------------------------------------------------------------
-- BUILD
----------------------------------------------------------------------
local function find_track(guid)
  if not guid then return nil end
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if r.GetTrackGUID(tr) == guid then return tr end
  end
end

local function delete_burst(tr, id)
  for i = r.CountTrackMediaItems(tr) - 1, 0, -1 do
    local it = r.GetTrackMediaItem(tr, i)
    local ok, v = r.GetSetMediaItemInfo_String(it, EXT_KEY, "", false)
    if ok and v == id then r.DeleteTrackMediaItem(tr, it) end
  end
end

local function burst_exists(b)
  local tr = find_track(b and b.track_guid)
  if not tr then return false end
  for i = 0, r.CountTrackMediaItems(tr) - 1 do
    local ok, v = r.GetSetMediaItemInfo_String(r.GetTrackMediaItem(tr, i), EXT_KEY, "", false)
    if ok and v == b.id then return true end
  end
  return false
end

-- Copy of a source item, with fresh GUIDs and unselected.
local function clone_chunk(item)
  local _, chunk = r.GetItemStateChunk(item, "", false)
  chunk = chunk:gsub("\n%s*IGUID [^\n]*", ""):gsub("\n%s*GUID [^\n]*", "")
  chunk = chunk:gsub("\n(%s*)SEL 1", "\n%1SEL 0")
  return chunk
end

local function place_shot(tr, chunk_cache, s, base, o, id)
  local src_item = s.src.item
  local chunk = chunk_cache[src_item]
  if not chunk then
    chunk = clone_chunk(src_item)
    chunk_cache[src_item] = chunk
  end
  local it = r.AddMediaItemToTrack(tr)
  r.SetItemStateChunk(it, chunk, false)
  r.SetMediaItemSelected(it, false)

  local vol = r.GetMediaItemInfo_Value(src_item, "D_VOL")
  r.SetMediaItemInfo_Value(it, "D_POSITION", base + s.t)
  r.SetMediaItemInfo_Value(it, "D_LENGTH", s.len)
  r.SetMediaItemInfo_Value(it, "D_VOL", vol * 10 ^ (s.gain / 20))
  r.SetMediaItemInfo_Value(it, "D_FADEINLEN", math.min(o.fadein_ms / 1000, s.len / 2))
  r.SetMediaItemInfo_Value(it, "D_FADEOUTLEN", math.min(o.fadeout_ms / 1000, s.len / 2))
  r.SetMediaItemInfo_Value(it, "D_FADEINLEN_AUTO", 0)
  r.SetMediaItemInfo_Value(it, "D_FADEOUTLEN_AUTO", 0)
  r.SetMediaItemInfo_Value(it, "B_LOOPSRC", 0)

  local src_takes = r.CountTakes(src_item)
  for ti = 0, r.CountTakes(it) - 1 do
    local take = r.GetTake(it, ti)
    local src_take = ti < src_takes and r.GetTake(src_item, ti)
    if take and src_take then
      local rate = r.GetMediaItemTakeInfo_Value(src_take, "D_PLAYRATE")
      local offs = r.GetMediaItemTakeInfo_Value(src_take, "D_STARTOFFS")
      r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", offs + s.src.start * rate)
      if s.cents ~= 0 then
        local p = r.GetMediaItemTakeInfo_Value(src_take, "D_PITCH")
        r.SetMediaItemTakeInfo_Value(take, "D_PITCH", p + s.cents / 100)
      end
    end
  end
  r.GetSetMediaItemInfo_String(it, EXT_KEY, id, true)
  return it
end

local function find_region(b)
  if not b.region_name then return nil end
  local i = 0
  while true do
    local rv, isrgn, pos, _, name, num = r.EnumProjectMarkers3(0, i)
    if rv == 0 then return nil end
    if isrgn and name == b.region_name and math.abs(pos - b.pos) < 1e-6 then return num end
    i = i + 1
  end
end

local function new_id()
  return ("%d%04d"):format(os.time(), math.random(0, 9999))
end

-- Builds a burst. b = the burst to rebuild in place, or nil to start a new one at the
-- edit cursor (on the last burst track if it still exists, otherwise on a new track
-- below the source).
local burst_track_guid = nil

local function build(pool, o, gains, b, src_track, name)
  local plan, total = plan_burst(pool, o, gains)
  if #plan == 0 then return b, 0 end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  local fresh = not b
  local tr = b and find_track(b.track_guid)
  if b and not tr then fresh = true end
  if fresh then
    tr = find_track(burst_track_guid)
    if not tr then
      local idx = math.floor(r.GetMediaTrackInfo_Value(src_track, "IP_TRACKNUMBER"))
      r.InsertTrackAtIndex(idx, true)
      tr = r.GetTrack(0, idx)
      r.GetSetMediaTrackInfo_String(tr, "P_NAME", name .. " burst", true)
    end
    b = { track_guid = r.GetTrackGUID(tr), id = new_id(), pos = r.GetCursorPosition() }
  else
    delete_burst(tr, b.id)
  end
  burst_track_guid = b.track_guid

  local chunk_cache = {}
  for _, s in ipairs(plan) do place_shot(tr, chunk_cache, s, b.pos, o, b.id) end

  local num = find_region(b)
  if num then r.DeleteProjectMarker(0, num, true) end
  b.region_name = nil
  if o.region then
    b.region_name = name .. " burst"
    r.AddProjectMarker2(0, true, b.pos, b.pos + total, b.region_name, -1, 0)
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock((fresh and "Build rapid-fire burst (%d shots)" or "Update rapid-fire burst (%d shots)"):format(#plan), -1)
  return b, #plan
end

----------------------------------------------------------------------
-- GUI
----------------------------------------------------------------------
local ctx = r.ImGui_CreateContext(TITLE)
local opt = load_settings()
local gains = resample(load_gains(), opt.count)
local items, last_state = {}, nil
local preview_idx = 1
local excluded = {}   -- "guid:k" -> true for shots left out of the burst
local burst = nil     -- the last burst built (for live update)
local built_sig = nil
local status = ""

local W = 520
local LABEL_X = 170
local COL_BG      = 0x1E1E1EFF
local COL_BAND    = 0xFFFFFF10
local COL_WAVE    = 0x5FB4C8FF
local COL_FLOOR   = 0xD8B44A90
local COL_ONSET   = 0xE05050FF
local COL_OFF     = 0x000000A0
local COL_TEXT    = 0xFFFFFFC0
local COL_BAR     = 0xE0A040FF
local COL_BAR_HOT = 0xFFD070FF
local COL_ZERO    = 0xFFFFFF50
local SHOT_COLS = { 0x5FB4C8FF, 0xE0A040FF, 0x8BC34AFF, 0xD07AD0FF, 0xE06060FF, 0x7090E0FF }

local function refresh_items()
  local state = r.GetProjectStateChangeCount(0)
  if state == last_state then return end
  last_state = state
  items = collect_items()
  if preview_idx > #items then preview_idx = math.max(1, #items) end
  if burst and not burst_exists(burst) then burst = nil end
end

local function label(text)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Text(ctx, text)
  r.ImGui_SameLine(ctx, LABEL_X)
end

local function tooltip(text)
  if r.ImGui_IsItemHovered(ctx) then r.ImGui_SetTooltip(ctx, text) end
end

local function shot_key(e, k) return (e.guid or tostring(e.item)) .. ":" .. k end

-- Detection on every selected item; builds the shot pool.
local memo_sig, analysis = nil, { per = {}, pool = {} }

local function analyse()
  local per, pool = {}, {}
  for i, e in ipairs(items) do
    local env, err = get_env(e.item)
    if env then
      local shots = plan_shots(env, detect(env, opt), opt)
      per[i] = { env = env, shots = shots }
      for k, s in ipairs(shots) do
        if not excluded[shot_key(e, k)] then
          pool[#pool + 1] = {
            item = e.item, start = s.start, len = s.len,
            label = #items > 1 and ("%d.%d"):format(i, k) or tostring(k),
          }
        end
      end
    else
      per[i] = { err = err, shots = {} }
    end
  end
  return { per = per, pool = pool }
end

local function draw_source(e, a)
  local env, shots = a.env, a.shots
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local x0, y0 = r.ImGui_GetCursorScreenPos(ctx)
  local H = 100
  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + W, y0 + H, COL_BG)

  local function tx(t) return x0 + clamp(t / env.len, 0, 1) * W end
  local function ty(d) return y0 + H - clamp((d - (env.peak - 60)) / 60, 0, 1) * H end

  for k, s in ipairs(shots) do
    if k % 2 == 0 then
      r.ImGui_DrawList_AddRectFilled(dl, tx(s.start), y0, tx(s.start + s.len), y0 + H, COL_BAND)
    end
  end

  local n = env.n
  for x = 0, W - 1 do
    local a0 = math.floor(x * n / W) + 1
    local b0 = math.max(a0, math.floor((x + 1) * n / W))
    local m = SILENCE_DB
    for i = a0, math.min(b0, n) do
      local d = env.db[i]
      if d > m then m = d end
    end
    local y = ty(m)
    if y < y0 + H then r.ImGui_DrawList_AddLine(dl, x0 + x + 0.5, y0 + H, x0 + x + 0.5, y, COL_WAVE, 1) end
  end

  local fy = ty(env.peak + opt.floor_db)
  r.ImGui_DrawList_AddLine(dl, x0, fy, x0 + W, fy, COL_FLOOR, 1)

  for k, s in ipairs(shots) do
    local x = tx(s.onset)
    r.ImGui_DrawList_AddLine(dl, x, y0, x, y0 + H, COL_ONSET, 1)
    r.ImGui_DrawList_AddText(dl, x + 2, y0 + 2, COL_TEXT, tostring(k))
    if excluded[shot_key(e, k)] then
      r.ImGui_DrawList_AddRectFilled(dl, tx(s.start), y0, tx(s.start + s.len), y0 + H, COL_OFF)
    end
  end

  r.ImGui_InvisibleButton(ctx, "##source", W, H)
  if r.ImGui_IsItemHovered(ctx) then
    local mx = r.ImGui_GetMousePos(ctx)
    local t = clamp((mx - x0) / W * env.len, 0, env.len)
    local hit
    for k, s in ipairs(shots) do
      if t >= s.start and t < s.start + s.len then hit = k end
    end
    if hit and r.ImGui_IsItemClicked(ctx, 0) then
      local key = shot_key(e, hit)
      excluded[key] = not excluded[key] or nil
      memo_sig = nil
    end
    r.ImGui_SetTooltip(ctx, hit
      and ("Shot %d%s\nClick to %s it"):format(hit,
        excluded[shot_key(e, hit)] and " (left out)" or "",
        excluded[shot_key(e, hit)] and "use" or "leave out")
      or "Red = shots found\nYellow = detection floor")
  end
end

-- Gain editor: one bar per shot of the burst, drawn with the mouse.
local drag_last = nil

local function draw_gains(plan)
  local N = #gains
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local x0, y0 = r.ImGui_GetCursorScreenPos(ctx)
  local H = 110
  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + W, y0 + H, COL_BG)
  local function ty(v) return y0 + (GAIN_MAX - v) / (GAIN_MAX - GAIN_MIN) * H end
  local zy = ty(0)
  r.ImGui_DrawList_AddLine(dl, x0, zy, x0 + W, zy, COL_ZERO, 1)

  r.ImGui_InvisibleButton(ctx, "##gains", W, H)
  local hovered = r.ImGui_IsItemHovered(ctx)
  local active = r.ImGui_IsItemActive(ctx)
  local mx, my = r.ImGui_GetMousePos(ctx)
  local bw = W / N
  local hot = (hovered or active) and clamp(math.floor((mx - x0) / bw) + 1, 1, N) or nil

  if active then
    local v = GAIN_MAX - clamp((my - y0) / H, 0, 1) * (GAIN_MAX - GAIN_MIN)
    v = math.floor(v * 2 + 0.5) / 2
    if drag_last then
      local k0, v0 = drag_last[1], drag_last[2]
      local step = hot > k0 and 1 or -1
      for k = k0, hot, step do
        local f = hot == k0 and 1 or (k - k0) / (hot - k0)
        gains[k] = v0 + (v - v0) * f
      end
    else
      gains[hot] = v
    end
    drag_last = { hot, v }
  else
    drag_last = nil
  end
  if hovered and r.ImGui_IsMouseClicked(ctx, 1) then gains[hot] = 0 end

  for k = 1, N do
    local xa, xb = x0 + (k - 1) * bw + 1, x0 + k * bw - 1
    if xb < xa + 1 then xb = xa + 1 end
    local y = ty(gains[k])
    r.ImGui_DrawList_AddRectFilled(dl, xa, math.min(y, zy), xb, math.max(y, zy) + 1,
      k == hot and COL_BAR_HOT or COL_BAR)
    if bw >= 16 and plan[k] then
      r.ImGui_DrawList_AddText(dl, xa + 2, y0 + H - 15, COL_TEXT, plan[k].src.label)
    end
  end

  if hovered and hot then
    r.ImGui_SetTooltip(ctx, ("Shot %d%s: %+.1f dB\nDrag to draw the gain, right-click to reset a shot"):format(
      hot, plan[hot] and (" (source shot " .. plan[hot].src.label .. ")") or "", gains[hot]))
  end
end

-- Timeline view of the burst that will be built.
local function draw_burst(plan, total)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local x0, y0 = r.ImGui_GetCursorScreenPos(ctx)
  local H = 60
  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + W, y0 + H, COL_BG)
  if total > 0 then
    local function tx(t) return x0 + t / total * W end
    for k, s in ipairs(plan) do
      local h = clamp((s.gain - GAIN_MIN) / (GAIN_MAX - GAIN_MIN), 0.05, 1) * (H - 4)
      local col = SHOT_COLS[(s.idx - 1) % #SHOT_COLS + 1]
      local xa = tx(s.t)
      r.ImGui_DrawList_AddRectFilled(dl, xa, y0 + H - h, math.max(xa + 1, tx(s.t + s.len)), y0 + H,
        (col & 0xFFFFFF00) | 0x50)
      r.ImGui_DrawList_AddLine(dl, xa, y0 + H - h, xa, y0 + H, col, 1)
      if k == 1 or tx(s.t) - tx(plan[k - 1].t) > 14 then
        r.ImGui_DrawList_AddText(dl, xa + 2, y0 + 2, COL_TEXT, s.src.label)
      end
    end
  end
  r.ImGui_Dummy(ctx, W, H)
  if r.ImGui_IsItemHovered(ctx) then
    r.ImGui_SetTooltip(ctx, "The burst: each block is one shot, its height shows the gain,\n" ..
      "the number is the source shot it uses.")
  end
end

-- Changing any setting rebuilds a live burst; changing the selection alone doesn't.
local function burst_sig()
  local p = {}
  for k, v in pairs(opt) do
    if k ~= "live" and k ~= "use_ms" then p[#p + 1] = k .. "=" .. tostring(v) end
  end
  table.sort(p)
  for _, g in ipairs(gains) do p[#p + 1] = ("%.2f"):format(g) end
  local ex = {}
  for key in pairs(excluded) do ex[#ex + 1] = key end
  table.sort(ex)
  p[#p + 1] = table.concat(ex, ",")
  return table.concat(p, "|")
end

local function rate_slider(id, key)
  r.ImGui_SetNextItemWidth(ctx, 240)
  local rv, v
  if opt.use_ms then
    local ms = 60000 / opt[key]
    rv, v = r.ImGui_SliderDouble(ctx, id, ms, 20, 500, "%.1f ms between shots")
    if rv then opt[key] = 60000 / clamp(v, 20, 2000) end
  else
    rv, v = r.ImGui_SliderDouble(ctx, id, opt[key], 120, 3000, "%.0f RPM")
    if rv then opt[key] = clamp(v, 30, 3000) end
  end
  tooltip(("%.0f RPM = %.1f ms between shots = %.1f shots per second"):format(
    opt[key], 60000 / opt[key], opt[key] / 60))
end

local function draw()
  refresh_items()
  local rv

  local sig = table.concat({ last_state, opt.rise_db, opt.floor_db, opt.min_ms, opt.preroll_ms }, "|")
  if sig ~= memo_sig then
    memo_sig = sig
    analysis = analyse()
  end
  local pool = analysis.pool
  if #gains ~= opt.count then gains = resample(gains, opt.count) end
  local plan, total = plan_burst(pool, opt, gains)

  -- Source --------------------------------------------------------------------
  if #items == 0 then
    r.ImGui_TextWrapped(ctx,
      "Select an item holding a row of single shots (a sausage file), or several items.\n" ..
      "Their shots become the building blocks of the burst.")
    r.ImGui_Dummy(ctx, W, 0)
  else
    local total_found = 0
    for _, a in ipairs(analysis.per) do total_found = total_found + #a.shots end
    r.ImGui_Text(ctx, ("%d shots found, %d used%s"):format(total_found, #pool,
      #pool < total_found and " (click a shot to use it again)" or ""))
    if #items > 1 then
      local function item_text(i)
        local a = analysis.per[i]
        return ("%d. %s  [%s]"):format(i, items[i].name, a.err or (#a.shots .. " shots"))
      end
      label("Preview")
      r.ImGui_SetNextItemWidth(ctx, W - LABEL_X)
      if r.ImGui_BeginCombo(ctx, "##preview", item_text(preview_idx)) then
        for i = 1, #items do
          if r.ImGui_Selectable(ctx, item_text(i) .. "##" .. i, i == preview_idx) then preview_idx = i end
        end
        r.ImGui_EndCombo(ctx)
      end
    end
    local a = analysis.per[preview_idx]
    if a and a.env then
      draw_source(items[preview_idx], a)
    else
      r.ImGui_Text(ctx, a and a.err and ("Can't analyse this item (" .. a.err .. ")") or "")
      r.ImGui_Dummy(ctx, W, 100)
    end
  end

  -- Detection -----------------------------------------------------------------
  label("Attack jump")
  r.ImGui_SetNextItemWidth(ctx, 240)
  rv, opt.rise_db = r.ImGui_SliderDouble(ctx, "##rise", opt.rise_db, 2, 30, "%.1f dB")
  tooltip("How sharply the level has to jump to count as a new shot.\nLower = more sensitive (finds more shots).")
  label("Ignore below")
  r.ImGui_SetNextItemWidth(ctx, 240)
  rv, opt.floor_db = r.ImGui_SliderDouble(ctx, "##floor", opt.floor_db, -60, -3, "%.0f dB from peak")
  tooltip("Transients quieter than this (relative to the item's loudest point) are ignored.")
  label("Min time between")
  r.ImGui_SetNextItemWidth(ctx, 240)
  rv, opt.min_ms = r.ImGui_SliderDouble(ctx, "##min", opt.min_ms, 5, 1000, "%.0f ms")
  tooltip("Two shots in the source can't be closer than this.")
  label("Pre-roll")
  r.ImGui_SetNextItemWidth(ctx, 240)
  rv, opt.preroll_ms = r.ImGui_SliderDouble(ctx, "##pre", opt.preroll_ms, 0, 20, "%.1f ms")
  tooltip("Each shot starts this far before its transient so the attack stays intact.")

  r.ImGui_Separator(ctx)

  -- Rate + order ----------------------------------------------------------------
  label("Rate of fire")
  rate_slider("##rpm", "rpm")
  r.ImGui_SameLine(ctx)
  rv, opt.use_ms = r.ImGui_Checkbox(ctx, "ms", opt.use_ms)
  tooltip("Show the rate as milliseconds between shots instead of rounds per minute.")

  label("")
  rv, opt.ramp = r.ImGui_Checkbox(ctx, "Ramp to##ramp", opt.ramp)
  tooltip("Change the rate across the burst, e.g. a minigun spinning up\n(the rate moves from the first value to this one).")
  r.ImGui_SameLine(ctx)
  r.ImGui_BeginDisabled(ctx, not opt.ramp)
  rate_slider("##rpm_end", "rpm_end")
  r.ImGui_EndDisabled(ctx)

  label("Shots")
  r.ImGui_SetNextItemWidth(ctx, 240)
  rv, opt.count = r.ImGui_SliderInt(ctx, "##count", opt.count, 1, 64)
  opt.count = clamp(opt.count, 1, MAX_COUNT)
  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, 80)
  rv, opt.count = r.ImGui_InputInt(ctx, "##count_in", opt.count, 1, 10)
  opt.count = clamp(opt.count, 1, MAX_COUNT)
  tooltip(("Up to %d shots."):format(MAX_COUNT))

  label("Order")
  r.ImGui_SetNextItemWidth(ctx, 240)
  if r.ImGui_BeginCombo(ctx, "##order", ORDERS[opt.order]) then
    for i, name in ipairs(ORDERS) do
      if r.ImGui_Selectable(ctx, name, i == opt.order) then opt.order = i end
    end
    r.ImGui_EndCombo(ctx)
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Reroll") then opt.seed = (opt.seed % 99999) + 1 end
  tooltip("New random order and humanize values.")

  r.ImGui_Separator(ctx)

  -- Gain ------------------------------------------------------------------------
  r.ImGui_Text(ctx, "Gain per shot")
  r.ImGui_SameLine(ctx, LABEL_X)
  local function shape(name, f)
    if r.ImGui_SmallButton(ctx, name) then
      local N = #gains
      for k = 1, N do
        gains[k] = clamp(f(N > 1 and (k - 1) / (N - 1) or 0, k), GAIN_MIN, GAIN_MAX)
      end
    end
    r.ImGui_SameLine(ctx)
  end
  shape("Flat", function() return 0 end)
  shape("Fade out", function(x) return -12 * x end)
  shape("Fade in", function(x) return -12 * (1 - x) end)
  shape("Accent 1st", function(_, k) return k == 1 and 3 or -2 end)
  shape("Random", function() return -math.random() * 4 end)
  r.ImGui_NewLine(ctx)
  draw_gains(plan)

  -- Burst preview ----------------------------------------------------------------
  r.ImGui_Text(ctx, #plan > 0 and ("Burst: %d shots, %.2f s"):format(#plan, total) or "Burst")
  draw_burst(plan, total)

  r.ImGui_Separator(ctx)

  -- Shot length + humanize --------------------------------------------------------
  label("Shot tails")
  if r.ImGui_RadioButton(ctx, "Ring out", not opt.choke) then opt.choke = false end
  tooltip("Every shot keeps its full length and overlaps the next ones.")
  r.ImGui_SameLine(ctx)
  if r.ImGui_RadioButton(ctx, "Cut at next shot", opt.choke) then opt.choke = true end
  tooltip("Each shot fades out as the next one starts (the last shot rings out).")

  label("Fade in / out")
  r.ImGui_SetNextItemWidth(ctx, 115)
  rv, opt.fadein_ms = r.ImGui_InputDouble(ctx, "##fin", opt.fadein_ms, 0, 0, "%.1f ms")
  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, 115)
  rv, opt.fadeout_ms = r.ImGui_InputDouble(ctx, "##fout", opt.fadeout_ms, 0, 0, "%.1f ms")
  opt.fadein_ms = math.max(0, opt.fadein_ms)
  opt.fadeout_ms = math.max(0, opt.fadeout_ms)

  label("Humanize timing")
  r.ImGui_SetNextItemWidth(ctx, 240)
  rv, opt.jit_ms = r.ImGui_SliderDouble(ctx, "##jms", opt.jit_ms, 0, 20, "+/- %.1f ms")
  label("Humanize gain")
  r.ImGui_SetNextItemWidth(ctx, 240)
  rv, opt.jit_db = r.ImGui_SliderDouble(ctx, "##jdb", opt.jit_db, 0, 6, "+/- %.1f dB")
  label("Humanize pitch")
  r.ImGui_SetNextItemWidth(ctx, 240)
  rv, opt.jit_cents = r.ImGui_SliderDouble(ctx, "##jct", opt.jit_cents, 0, 200, "+/- %.0f cents")

  rv, opt.region = r.ImGui_Checkbox(ctx, "Add a region around the burst", opt.region)

  r.ImGui_Separator(ctx)

  -- Build -------------------------------------------------------------------------
  local busy = r.ImGui_IsAnyItemActive(ctx) or r.ImGui_IsMouseDown(ctx, 0)
  local cur_sig = burst_sig()
  local src_track = items[1] and items[1].track
  local src_name = items[1] and items[1].name:gsub("%.[%w]+$", "")

  if opt.live and burst and #plan > 0 and not busy and cur_sig ~= built_sig then
    burst = build(pool, opt, gains, burst, src_track, src_name)
    built_sig = cur_sig
    save_settings(opt, gains)
    status = "Burst updated. Ctrl+Z to undo."
    last_state = nil
  end

  r.ImGui_BeginDisabled(ctx, #plan == 0)
  if r.ImGui_Button(ctx, burst and "Build new burst" or "Build burst", 150, 0) then
    local n
    burst, n = build(pool, opt, gains, nil, src_track, src_name)
    built_sig = cur_sig
    save_settings(opt, gains)
    status = ("Built %d shots at the edit cursor."):format(n)
    last_state = nil
  end
  tooltip("Builds the burst at the edit cursor on a track below the source.")
  r.ImGui_EndDisabled(ctx)
  r.ImGui_SameLine(ctx)
  rv, opt.live = r.ImGui_Checkbox(ctx, "Live update", opt.live)
  tooltip("Rebuild the last burst every time you change a setting\n" ..
    "(loop playback over it to hear changes as you make them).")
  if burst and opt.live then
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, "Let go") then burst = nil; status = "Burst kept as it is." end
    tooltip("Stop updating the last burst, so changes no longer touch it.")
  end
  r.ImGui_TextWrapped(ctx, status)
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
    save_settings(opt, gains)
  end
end

r.defer(loop)
