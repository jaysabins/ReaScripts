-- @description Gun Builder: single shots, bursts and full-auto sequences from gunshot recordings
-- @author Jay Sabins
-- @version 1.1.0
-- @changelog
--   Stacked sausages: select one sausage per layer track (stacked so they play together)
--   and Burst / Full auto find the shots across all layers at once. Every shot is then
--   built from all the layers, each layer on its own track named after its source, so the
--   layers stay locked together. "Keep stacked layers together" turns it off to use every
--   shot of every item as a separate building block, like before.
-- @about
--   # Gun Builder
--
--   A one-stop window for building gun sounds in REAPER. Pick a mode at the top:
--
--   - **Single shots** (semi-auto): select every item of a rapid-fire session where each
--     shot is one item per layer track, stacked so the layers start together. Gun Builder
--     groups them into shots and spaces the shots out along the timeline with a gap,
--     keeping each shot's layer offsets. Optional region per shot for rendering.
--   - **Burst**: select a sausage item (a row of single shots), or one sausage per layer
--     track stacked so they play together (each shot then keeps all its layers). Gun Builder finds every
--     shot's transient and builds bursts from them at the edit cursor: rounds per burst,
--     rate of fire, how many bursts and the pause between them, gain per round.
--   - **Full auto**: the same from a sausage file, for any number of shots, with an
--     optional ramp (spin-up / spin-down). Or select shots already laid out on the
--     timeline (one item per shot, one track per layer) to re-time them in place.
--
--   Tabs along the top each hold a whole setup (mode and every setting), saved with the
--   project: + adds one, double-click renames, right-click for color, name, order and
--   close. "Presets..." saves and loads named setups for any project.
--
--   With Live update on, the burst you built rebuilds whenever you change a setting, so
--   you can loop playback over it while you dial it in. Each change is one undo step.
--
--   Requires ReaImGui 0.9 or newer (install it from ReaPack).

local r = reaper
local TITLE = "Gun Builder"
local SECTION = "jsabins_GunBuilder"        -- tabs, presets (ExtState / project ExtState)
-- Burst and sequence records in the project use the same keys as Rapid-Fire Builder, so
-- bursts built with that script can be picked up and edited here too.
local DATA = "jsabins_RapidFireBuilder"
local EXT_KEY = "P_EXT:jsabins_rf_burst"
local SEQ_KEY = "P_EXT:jsabins_rf_seq"

if not r.ImGui_GetBuiltinPath then
  r.ShowMessageBox(
    "Gun Builder needs the ReaImGui extension (0.9 or newer).\n\n" ..
    "Install it from Extensions > ReaPack > Browse packages (search \"ReaImGui\"), " ..
    "then restart REAPER and run the script again.", TITLE, 0)
  if r.ReaPack_BrowsePackages then r.ReaPack_BrowsePackages("ReaImGui") end
  return
end
package.path = r.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ok_imgui, ImGui = pcall(function() return require "imgui" "0.9" end)
if not ok_imgui or type(ImGui) ~= "table" then
  r.ShowMessageBox("Gun Builder needs ReaImGui 0.9 or newer.\n\n" ..
    "Update it from Extensions > ReaPack > Synchronize packages, then restart REAPER.", TITLE, 0)
  return
end

----------------------------------------------------------------------
-- USER CONFIG
----------------------------------------------------------------------
local HOP_MS      = 1    -- envelope resolution used for detection
local LOOKBACK_MS = 5    -- how far back the attack jump is measured
local MAX_ITEM_S  = 600  -- skip analysing items longer than this
local GAIN_MIN    = -24  -- gain editor range (dB)
local GAIN_MAX    = 6
local MAX_COUNT   = 200  -- most shots in one build
local MAX_ROUNDS  = 20   -- most rounds in one burst
----------------------------------------------------------------------

local SILENCE_DB = -150

local function clamp(v, lo, hi)
  v = tonumber(v) or lo
  if v ~= v then return lo end -- NaN
  if v < lo then return lo elseif v > hi then return hi end
  return v
end
local function valid_item(it) return it ~= nil and r.ValidatePtr2(0, it, "MediaItem*") end
local function valid_track(tr) return tr ~= nil and r.ValidatePtr2(0, tr, "MediaTrack*") end
local function pos_of(it) return r.GetMediaItemInfo_Value(it, "D_POSITION") end
local function len_of(it) return r.GetMediaItemInfo_Value(it, "D_LENGTH") end

-- Every change to the project goes through here: one undo point, UI refresh held off,
-- and both always closed again even if something inside fails.
local function undo_step(name, fn)
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local ok, a, b = xpcall(fn, debug.traceback)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(ok and name or (TITLE .. ": stopped by an error"), -1)
  if not ok then error(a, 0) end
  return a, b
end

----------------------------------------------------------------------
-- SETTINGS (one table per tab)
----------------------------------------------------------------------
local MODES = { "Single shots", "Burst", "Full auto" }
local MODE_TIPS = {
  "Semi-auto: space stacked layer shots out along the timeline,\none spot (and optional region) per shot.",
  "Build bursts (e.g. 3 rounds) from a sausage file of single shots,\nrepeated with a pause between bursts.",
  "Build a full-auto sequence from a sausage file (with optional spin-up/down),\nor re-time shots already on the timeline in place.",
}
local LANES = { "One track", "Auto (no overlaps)", "One track per shot" }
local ORDERS = {
  "In order (loops)",
  "Ping-pong",
  "Random (no repeats in a row)",
  "Shuffled rounds (each shot once per round)",
}

local DEFAULTS = {
  mode = 3,           -- 1 single shots, 2 burst, 3 full auto
  -- single shots
  tol_ms = 20,        -- items starting within this of a shot's first item belong to that shot
  gap = 0.5,          -- seconds between the end of one shot and the start of the next
  ripple = true,      -- move later items on the involved tracks out of the way
  regions = false,    -- add a region per shot
  prefix = "Shot",    -- region name prefix
  -- detection
  rise_db = 8, floor_db = -30, min_ms = 40, preroll_ms = 3,
  -- rate
  use_ms = false, rpm = 750, ramp = false, rpm_end = 1100,
  count = 12,         -- full auto: number of shots
  rounds = 3,         -- burst: rounds per burst
  bursts = 1,         -- burst: number of bursts
  burst_gap_ms = 250, -- burst: from the last round of one burst to the first of the next
  order = 1, seed = 1,
  choke = false, lanes = 2, fadein_ms = 1, fadeout_ms = 15,
  jit_ms = 0, jit_db = 0, jit_cents = 0,
  region = false,
  live = true,
  stack = true,       -- stacked sausages (one per layer track): each shot uses every layer
}
-- Settings that are how you like the window, not part of a setup.
local UI_KEYS = { live = true, use_ms = true }
-- Settings that only matter in Single shots mode (they don't touch a built burst).
local SPREAD_KEYS = { tol_ms = true, gap = true, ripple = true, regions = true, prefix = true }

local function sanitize(s)
  for k, def in pairs(DEFAULTS) do
    if type(s[k]) ~= type(def) then s[k] = def end
  end
  s.mode = math.floor(clamp(s.mode, 1, 3))
  s.order = math.floor(clamp(s.order, 1, #ORDERS))
  s.lanes = math.floor(clamp(s.lanes, 1, 3))
  s.count = math.floor(clamp(s.count, 1, MAX_COUNT))
  s.rounds = math.floor(clamp(s.rounds, 1, MAX_ROUNDS))
  s.bursts = math.floor(clamp(s.bursts, 1, math.max(1, MAX_COUNT // s.rounds)))
  s.seed = math.floor(clamp(s.seed, 1, 99999))
  s.rpm = clamp(s.rpm, 30, 3000)
  s.rpm_end = clamp(s.rpm_end, 30, 3000)
  s.burst_gap_ms = clamp(s.burst_gap_ms, 20, 10000)
  s.tol_ms = clamp(s.tol_ms, 1, 500)
  s.gap = clamp(s.gap, 0, 600)
  s.rise_db = clamp(s.rise_db, 1, 60)
  s.floor_db = clamp(s.floor_db, -90, -1)
  s.min_ms = clamp(s.min_ms, 1, 5000)
  s.preroll_ms = clamp(s.preroll_ms, 0, 100)
  s.fadein_ms = clamp(s.fadein_ms, 0, 5000)
  s.fadeout_ms = clamp(s.fadeout_ms, 0, 5000)
  s.jit_ms = clamp(s.jit_ms, 0, 100)
  s.jit_db = clamp(s.jit_db, 0, 24)
  s.jit_cents = clamp(s.jit_cents, 0, 1200)
  s.prefix = tostring(s.prefix):gsub("[\r\n]", " ")
  return s
end

local function default_settings()
  local s = {}
  for k, v in pairs(DEFAULTS) do s[k] = v end
  return s
end

local function copy_settings(s)
  local t = {}
  for k in pairs(DEFAULTS) do t[k] = s[k] end
  return sanitize(t)
end

local function parse_value(def, v)
  if v == nil then return nil end
  if type(def) == "boolean" then return v == "1" or v == "true" end
  if type(def) == "number" then return tonumber(v) end
  return v
end

local function value_text(v)
  if type(v) == "boolean" then return v and "1" or "0" end
  return tostring(v)
end

-- Text storage. Setups are kept on one line (safe for ExtState): fields are "key=value",
-- separated by ";", setups separated by "|". Those characters are %-escaped in values.
local function enc(v)
  return (tostring(v):gsub("[%%;=|\r\n]", function(c) return ("%%%02X"):format(c:byte()) end))
end
local function dec(v)
  return (v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function list_csv(s)
  local t = {}
  for v in (s or ""):gmatch("[^,]+") do t[#t + 1] = v end
  return t
end

local function gains_text(g)
  local p = {}
  for i, v in ipairs(g or {}) do p[i] = ("%.2f"):format(v) end
  return table.concat(p, ",")
end

local function gains_from(text)
  local g = {}
  for i, v in ipairs(list_csv(text)) do g[i] = clamp(tonumber(v) or 0, GAIN_MIN, GAIN_MAX) end
  return g
end

local function copy_gains(g)
  local t = { auto = {}, burst = {} }
  for k in pairs(t) do
    for i, v in ipairs(g and g[k] or {}) do t[k][i] = v end
  end
  return t
end

-- A setup (tab or preset) to text and back.
local function encode_setup(t)
  local f = { "name=" .. enc(t.name or "") }
  if t.color then f[#f + 1] = "color=" .. tostring(math.floor(t.color)) end
  f[#f + 1] = "ga=" .. gains_text(t.gains and t.gains.auto)
  f[#f + 1] = "gb=" .. gains_text(t.gains and t.gains.burst)
  local keys = {}
  for k in pairs(DEFAULTS) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do f[#f + 1] = "s_" .. k .. "=" .. enc(value_text(t.s[k])) end
  return table.concat(f, ";")
end

local function parse_fields(seg)
  local f = {}
  for part in seg:gmatch("[^;]+") do
    local k, v = part:match("^([^=]+)=(.*)$")
    if k then f[k] = dec(v) end
  end
  return f
end

local function decode_setup(seg)
  local f = parse_fields(seg)
  local s = default_settings()
  for k, def in pairs(DEFAULTS) do
    local v = parse_value(def, f["s_" .. k])
    if v ~= nil then s[k] = v end
  end
  local color = tonumber(f.color)
  return {
    name = f.name or "",
    color = color and math.floor(clamp(color, 0, 0xFFFFFF)) or nil,
    s = sanitize(s),
    gains = { auto = gains_from(f.ga), burst = gains_from(f.gb) },
  }
end

-- First run: start from the settings of Rapid-Fire Builder and Spread Rapid-Fire Shots.
local function migrated_tab()
  local s = default_settings()
  for _, old in ipairs({ "jsabins_RapidFireBuilder", "jsabins_SpreadShots" }) do
    for k, def in pairs(DEFAULTS) do
      if k ~= "mode" and r.HasExtState(old, k) then
        local v = parse_value(def, r.GetExtState(old, k))
        if v ~= nil then s[k] = v end
      end
    end
  end
  return { name = "Default", s = sanitize(s),
    gains = { auto = gains_from(r.GetExtState("jsabins_RapidFireBuilder", "gains")), burst = {} } }
end

local function decode_tabs(txt)
  if not txt or txt == "" then return nil end
  local segs = {}
  for seg in txt:gmatch("[^|]+") do segs[#segs + 1] = seg end
  if #segs < 2 then return nil end
  local head = parse_fields(segs[1])
  local list = {}
  for i = 2, #segs do
    local ok, t = pcall(decode_setup, segs[i])
    if ok and t then list[#list + 1] = t end
  end
  if #list == 0 then return nil end
  return { active = math.floor(clamp(tonumber(head.active) or 1, 1, #list)), list = list }
end

local function load_tabs()
  local _, txt = r.GetProjExtState(0, SECTION, "tabs")
  local t = decode_tabs(txt) or decode_tabs(r.GetExtState(SECTION, "last_tabs"))
  if not t then t = { active = 1, list = { migrated_tab() } } end
  for i, tab in ipairs(t.list) do
    tab.id = i
    if tab.name == "" then tab.name = "Tab " .. i end
  end
  t.next_id = #t.list + 1
  return t
end

local function encode_tabs(t)
  local segs = { "v=1;active=" .. tostring(t.active) }
  for _, tab in ipairs(t.list) do segs[#segs + 1] = encode_setup(tab) end
  return table.concat(segs, "|")
end

local function save_tabs(t, proj)
  proj = proj or 0
  local txt = encode_tabs(t)
  local _, old = r.GetProjExtState(proj, SECTION, "tabs")
  if old ~= txt then r.SetProjExtState(proj, SECTION, "tabs", txt) end -- only when changed (marks the project dirty)
  r.SetExtState(SECTION, "last_tabs", txt, true)
end

local function load_presets()
  local p = {}
  for seg in r.GetExtState(SECTION, "presets"):gmatch("[^|]+") do
    local ok, t = pcall(decode_setup, seg)
    if ok and t and t.name ~= "" then p[t.name] = t end
  end
  return p
end

local function save_presets(p)
  local names = {}
  for n in pairs(p) do names[#names + 1] = n end
  table.sort(names)
  local segs = {}
  for _, n in ipairs(names) do segs[#segs + 1] = encode_setup(p[n]) end
  r.SetExtState(SECTION, "presets", table.concat(segs, "|"), true)
end

----------------------------------------------------------------------
-- ANALYSIS (transient detection inside a sausage file)
----------------------------------------------------------------------

-- Peak level (dB) of every HOP_MS window of the item, all channels combined.
local function compute_env(item)
  if not valid_item(item) then return nil, "item is gone" end
  local take = r.GetActiveTake(item)
  if not take or r.TakeIsMIDI(take) then return nil, "not audio" end
  local src = r.GetMediaItemTake_Source(take)
  if not src then return nil, "no source" end
  local len = len_of(item)
  if len > MAX_ITEM_S then return nil, "too long" end
  local sr = r.GetMediaSourceSampleRate(src)
  if not sr or sr <= 0 then sr = 48000 end
  local nch = math.floor(clamp(r.GetMediaSourceNumChannels(src), 1, 64))

  local hop_n = math.max(1, math.floor(sr * HOP_MS / 1000 + 0.5))
  local hop = hop_n / sr
  local nwin = math.floor(len / hop)
  if nwin < 1 then return nil, "too short" end

  local acc = r.CreateTakeAudioAccessor(take)
  if not acc then return nil, "can't read audio" end
  -- keep the buffer at about 256k samples whatever the sample rate and channel count
  local per_win = hop_n * nch
  local block_w = math.max(1, math.min(256, 262144 // per_win))
  local buf = r.new_array(block_w * per_win)
  local db, peak = {}, SILENCE_DB

  local ok, err = pcall(function()
    for w0 = 0, nwin - 1, block_w do
      local cnt_w = math.min(block_w, nwin - w0)
      local cnt = cnt_w * hop_n
      buf.clear()
      r.GetAudioAccessorSamples(acc, sr, nch, w0 * hop, cnt, buf)
      local t = buf.table(1, cnt * nch)
      for w = 0, cnt_w - 1 do
        local m, base = 0, w * per_win
        for j = base + 1, base + per_win do
          local v = t[j] or 0
          if v < 0 then v = -v end
          if v > m then m = v end
        end
        local d = m > 1e-8 and 20 * math.log(m, 10) or SILENCE_DB
        db[w0 + w + 1] = d
        if d > peak then peak = d end
      end
    end
  end)
  r.DestroyAudioAccessor(acc)
  if not ok then return nil, "can't read audio (" .. tostring(err) .. ")" end

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
-- ITEMS, SELECTION, CACHE
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
    src and r.GetMediaSourceFileName(src, "") or "",
  }, "|")
end

local function get_env(item)
  if not valid_item(item) then return nil, "item is gone" end
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

local function item_guid(it)
  return select(2, r.GetSetMediaItemInfo_String(it, "GUID", "", false))
end

local function burst_id_of(it)
  local ok, v = r.GetSetMediaItemInfo_String(it, EXT_KEY, "", false)
  if ok and v ~= "" then return v end
end

local function seq_tag(it)
  local ok, v = r.GetSetMediaItemInfo_String(it, SEQ_KEY, "", false)
  if ok and v ~= "" then return v end
end

local function item_entry(it)
  local tr = r.GetMediaItem_Track(it)
  local p, l = pos_of(it), len_of(it)
  return {
    item = it, track = tr,
    tidx = tr and r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") or 0,
    pos = p, len = l, stop = p + l, name = take_label(it), guid = item_guid(it),
  }
end

local function sort_items(items)
  table.sort(items, function(a, b)
    if a.tidx ~= b.tidx then return a.tidx < b.tidx end
    return a.pos < b.pos
  end)
  return items
end

-- Selected source items (bursts left out), the id of the selected burst if the selection
-- holds items of exactly one burst, and the id of the selected re-timed sequence.
local function collect_selection()
  local items, ids, n_ids, last = {}, {}, 0, nil
  local sids, n_sids, slast = {}, 0, nil
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    if it and r.GetMediaItem_Track(it) then
      local id = burst_id_of(it)
      if id then
        if not ids[id] then ids[id], n_ids, last = true, n_ids + 1, id end
      else
        items[#items + 1] = item_entry(it)
        local tag = seq_tag(it)
        local sid = tag and tag:match("^([^|]+)")
        if sid and not sids[sid] then sids[sid], n_sids, slast = true, n_sids + 1, sid end
      end
    end
  end
  return sort_items(items), n_ids == 1 and last or nil, n_sids == 1 and slast or nil
end

-- Items by GUID, skipping any that are gone. `known` = entries from last time, reused
-- when their item is still there (saves a scan of the whole project).
local function items_by_guid(guids, known)
  local found, missing = {}, false
  local prev = {}
  for _, e in ipairs(known or {}) do prev[e.guid] = e.item end
  for _, g in ipairs(guids) do
    local it = prev[g]
    if it and valid_item(it) and item_guid(it) == g then found[g] = it else missing = true end
  end
  if missing then
    local want = {}
    for _, g in ipairs(guids) do if not found[g] then want[g] = true end end
    for i = 0, r.CountMediaItems(0) - 1 do
      local it = r.GetMediaItem(0, i)
      local g = item_guid(it)
      if want[g] then found[g] = it end
    end
  end
  local items = {}
  for _, g in ipairs(guids) do
    if found[g] then items[#items + 1] = item_entry(found[g]) end
  end
  return sort_items(items)
end

local function prune_cache(items)
  local keep = {}
  for _, e in ipairs(items) do keep[e.item] = true end
  for it in pairs(cache) do if not keep[it] then cache[it] = nil end end
end

----------------------------------------------------------------------
-- SINGLE SHOTS (group stacked layers into shots, spread the shots out)
----------------------------------------------------------------------
local function collect_spread_items()
  local items = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    if it and r.GetMediaItem_Track(it) then items[#items + 1] = item_entry(it) end
  end
  table.sort(items, function(a, b)
    if a.pos ~= b.pos then return a.pos < b.pos end
    return a.tidx < b.tidx
  end)
  return items
end

-- Shots: items whose start is within tol of the shot's first item.
local function group_shots(items, tol)
  local shots, cur = {}, nil
  for _, e in ipairs(items) do
    if cur and e.pos - cur.start <= tol + 1e-9 then
      cur.items[#cur.items + 1] = e
      if e.stop > cur.stop then cur.stop = e.stop end
    else
      cur = { items = { e }, start = e.pos, stop = e.stop }
      shots[#shots + 1] = cur
    end
  end
  return shots
end

-- New start time of every shot.
local function spread_layout(shots, gap)
  local starts = {}
  for k, s in ipairs(shots) do
    if k == 1 then
      starts[k] = s.start
    else
      local prev = shots[k - 1]
      starts[k] = starts[k - 1] + (prev.stop - prev.start) + gap
    end
  end
  return starts
end

local function apply_spread(items, o)
  local shots = group_shots(items, o.tol_ms / 1000)
  if #shots == 0 then return 0 end
  local starts = spread_layout(shots, o.gap)

  local sel_end = 0
  for _, s in ipairs(shots) do sel_end = math.max(sel_end, s.stop) end
  local last = shots[#shots]
  local growth = starts[#shots] + (last.stop - last.start) - sel_end

  return undo_step(("Gun Builder: spread %d single shots"):format(#shots), function()
    -- later items on the same tracks move by how much longer the sequence got
    if o.ripple and growth > 0 then
      local in_sel, seen = {}, {}
      for _, e in ipairs(items) do in_sel[e.item] = true end
      for _, e in ipairs(items) do
        if valid_track(e.track) and not seen[e.track] then
          seen[e.track] = true
          for i = 0, r.CountTrackMediaItems(e.track) - 1 do
            local it = r.GetTrackMediaItem(e.track, i)
            if it and not in_sel[it] then
              local p = pos_of(it)
              if p >= sel_end - 1e-6 then r.SetMediaItemInfo_Value(it, "D_POSITION", p + growth) end
            end
          end
        end
      end
    end

    local digits = math.max(2, #tostring(#shots))
    local prefix = o.prefix ~= "" and o.prefix or "Shot"
    for k, s in ipairs(shots) do
      local delta = starts[k] - s.start
      if delta ~= 0 then
        for _, e in ipairs(s.items) do
          if valid_item(e.item) then r.SetMediaItemInfo_Value(e.item, "D_POSITION", e.pos + delta) end
        end
      end
      if o.regions then
        r.AddProjectMarker2(0, true, starts[k], starts[k] + (s.stop - s.start),
          ("%s_%0" .. digits .. "d"):format(prefix, k), -1, 0)
      end
    end
    return #shots
  end)
end

----------------------------------------------------------------------
-- BURST / FULL AUTO PLANNING
----------------------------------------------------------------------

-- Small seeded random generator, so the same seed always gives the same result.
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

-- Gain list resampled to n values (keeps the drawn shape when the count changes).
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

-- Time from shot k to shot k+1 with a rate (and optional ramp) over N shots.
local function interval_at(o, k, N)
  local rpm = o.rpm
  if o.ramp and N > 2 then
    rpm = o.rpm + (o.rpm_end - o.rpm) * (k - 1) / (N - 2)
  end
  return 60 / math.max(1, rpm)
end

-- Total shots and gain-editor bars for the settings' mode.
local function shot_layout(o)
  if o.mode == 2 then return o.rounds * o.bursts, o.rounds end
  return o.count, o.count
end

-- The build as a list of { src, idx, t, len, gain, cents, lane } (t from the start).
-- Returns the list, the total length and the number of tracks it needs.
local function plan_burst(pool, o, gains)
  local P = #pool
  local N, per = shot_layout(o)
  local out = {}
  if P == 0 then return out, 0, 1 end
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
      gain = (gains[(k - 1) % per + 1] or 0) + jit(jg, o.jit_db),
      cents = jit(jp, o.jit_cents),
    }
    prev_t = t
    if o.mode == 2 then
      if k % o.rounds == 0 then
        grid = grid + o.burst_gap_ms / 1000
      else
        grid = grid + 60 / math.max(1, o.rpm)
      end
    else
      grid = grid + interval_at(o, k, N)
    end
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

  -- tracks: a shot may share a track with the one before it if it only overlaps that
  -- shot's fade-out
  local lanes = 1
  if pool[1].stacked then
    -- stacked: one track per layer, like the source
    local nl = 1
    for _, s in ipairs(out) do
      s.lane = 1
      for _, sl in ipairs(s.src.slices) do nl = math.max(nl, sl.layer) end
    end
    return out, total, nl
  elseif o.lanes == 3 then
    for k, s in ipairs(out) do s.lane = k end
    lanes = #out
  elseif o.lanes == 2 then
    local ends = {}
    for _, s in ipairs(out) do
      local lane
      for li = 1, #ends do
        if ends[li] <= s.t + 1e-6 then lane = li; break end
      end
      lane = lane or #ends + 1
      s.lane = lane
      ends[lane] = s.t + s.len - math.min(fout, s.len / 2)
    end
    lanes = math.max(1, #ends)
  else
    for _, s in ipairs(out) do s.lane = 1 end
  end
  return out, total, lanes
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

-- Direct child tracks of a folder track.
local function folder_kids(parent)
  local kids = {}
  if r.GetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH") ~= 1 then return kids end
  local i = math.floor(r.GetMediaTrackInfo_Value(parent, "IP_TRACKNUMBER"))
  local depth = 1
  while depth > 0 and i < r.CountTracks(0) do
    local t = r.GetTrack(0, i)
    if depth == 1 then kids[#kids + 1] = t end
    depth = depth + r.GetMediaTrackInfo_Value(t, "I_FOLDERDEPTH")
    i = i + 1
  end
  return kids
end

local function burst_tracks(parent)
  local list = { parent }
  for _, t in ipairs(folder_kids(parent)) do list[#list + 1] = t end
  return list
end

-- Make sure the burst track has the child tracks a burst needs (empty extra ones are
-- removed). Returns the tracks to put shots on, by lane. If the folder holds nested
-- folders of its own, it is left alone and everything goes on the burst track.
local function ensure_lanes(parent, n, name)
  local kids = folder_kids(parent)
  for _, k in ipairs(kids) do
    if r.GetMediaTrackInfo_Value(k, "I_FOLDERDEPTH") > 0 then return { parent } end
  end
  local pd = r.GetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH")
  local closing = #kids > 0 and r.GetMediaTrackInfo_Value(kids[#kids], "I_FOLDERDEPTH") or (pd - 1)
  local want = n > 1 and n or 0

  for i = #kids, want + 1, -1 do
    if r.CountTrackMediaItems(kids[i]) == 0 then
      r.DeleteTrack(kids[i])
      table.remove(kids, i)
    else
      break
    end
  end
  local base = math.floor(r.GetMediaTrackInfo_Value(parent, "IP_TRACKNUMBER"))
  while #kids < want do
    local idx = base + #kids
    r.InsertTrackAtIndex(idx, true)
    local t = r.GetTrack(0, idx)
    if not t then break end
    r.GetSetMediaTrackInfo_String(t, "P_NAME", ("%s %d"):format(name, #kids + 1), true)
    kids[#kids + 1] = t
  end

  if #kids == 0 then
    r.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", closing + 1)
  else
    r.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", 1)
    for i, t in ipairs(kids) do
      r.SetMediaTrackInfo_Value(t, "I_FOLDERDEPTH", i == #kids and closing or 0)
    end
  end
  if n <= 1 or #kids == 0 then return { parent } end
  return kids
end

local function delete_burst(parent, id)
  for _, tr in ipairs(burst_tracks(parent)) do
    for i = r.CountTrackMediaItems(tr) - 1, 0, -1 do
      local it = r.GetTrackMediaItem(tr, i)
      if it and burst_id_of(it) == id then r.DeleteTrackMediaItem(tr, it) end
    end
  end
end

local function burst_exists(b)
  local parent = find_track(b and b.track_guid)
  if not parent then return false end
  for _, tr in ipairs(burst_tracks(parent)) do
    for i = 0, r.CountTrackMediaItems(tr) - 1 do
      local it = r.GetTrackMediaItem(tr, i)
      if it and burst_id_of(it) == b.id then return true end
    end
  end
  return false
end

-- Burst memory (saved in the project, so a burst can be edited again later).
local function store_burst(b, o, gains, excluded)
  local lines = {
    "track=" .. b.track_guid,
    ("pos=%.10f"):format(b.pos),
    "name=" .. (b.name or ""):gsub("[\r\n]", " "),
    "region=" .. (b.region_name or ""):gsub("[\r\n]", " "),
    "sources=" .. table.concat(b.sources or {}, ","),
  }
  local keys = {}
  for k in pairs(DEFAULTS) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    lines[#lines + 1] = "o_" .. k .. "=" .. value_text(o[k]):gsub("[\r\n]", " ")
  end
  lines[#lines + 1] = "gains=" .. gains_text(gains)
  local ex = {}
  for key in pairs(excluded) do ex[#ex + 1] = key end
  table.sort(ex)
  lines[#lines + 1] = "excluded=" .. table.concat(ex, ",")
  r.SetProjExtState(0, DATA, "burst_" .. b.id, table.concat(lines, "\n"))
  r.SetProjExtState(0, DATA, "last", b.id)
end

-- Returns burst, settings, gains, excluded, or nil if the project has no record of it.
local function load_burst(id)
  local rv, s = r.GetProjExtState(0, DATA, "burst_" .. id)
  if rv == 0 or s == "" then return nil end
  local f = {}
  for line in s:gmatch("[^\n]+") do
    local k, v = line:match("^([%w_]+)=(.*)$")
    if k then f[k] = v end
  end
  if not f.track then return nil end
  local b = {
    id = id, track_guid = f.track, pos = tonumber(f.pos) or 0, name = f.name or "",
    region_name = (f.region and f.region ~= "") and f.region or nil,
    sources = list_csv(f.sources),
  }
  local o = default_settings()
  for k, def in pairs(DEFAULTS) do
    local v = parse_value(def, f["o_" .. k])
    if v ~= nil then o[k] = v end
  end
  if not f.o_mode or o.mode == 1 then o.mode = 3 end -- built by Rapid-Fire Builder: full auto
  sanitize(o)
  local ex = {}
  for _, key in ipairs(list_csv(f.excluded)) do ex[key] = true end
  return b, o, gains_from(f.gains), ex
end

-- Copy of a source item, with fresh GUIDs and unselected. nil if it can't be read.
local function clone_chunk(item)
  local ok, chunk = r.GetItemStateChunk(item, "", false)
  if not ok or not chunk or chunk == "" then return nil end
  chunk = chunk:gsub("\n%s*IGUID [^\n]*", ""):gsub("\n%s*GUID [^\n]*", "")
  chunk = chunk:gsub("\n(%s*)SEL 1", "\n%1SEL 0")
  return chunk
end

local function place_shot(tr, chunk_cache, s, base, o, id)
  local src_item = s.src.item
  if not valid_item(src_item) then return nil end
  local chunk = chunk_cache[src_item]
  if chunk == nil then
    chunk = clone_chunk(src_item) or false
    chunk_cache[src_item] = chunk
  end
  if not chunk then return nil end
  local it = r.AddMediaItemToTrack(tr)
  if not it then return nil end
  if not r.SetItemStateChunk(it, chunk, false) then
    r.DeleteTrackMediaItem(tr, it)
    return nil
  end
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

local id_counter = 0
local function new_id()
  id_counter = id_counter + 1
  return ("%d%04d%02d"):format(os.time(), math.random(0, 9999), id_counter % 100)
end

local burst_track_guid = nil -- track the last new burst went on (new bursts go there too)

-- Builds a burst. b = the burst to rebuild in place, or nil to start a new one at the edit
-- cursor (on the last burst track if it still exists, otherwise on a new track below the
-- source).
local function build(pool, o, gains, b, src_track, name)
  local plan, total, n_lanes = plan_burst(pool, o, gains)
  if #plan == 0 then return b, 0 end
  local fresh = not b or b.missing or not find_track(b.track_guid)
  if fresh and not find_track(burst_track_guid) and not valid_track(src_track) then return b, 0 end
  local what = o.mode == 2 and "burst" or "full-auto sequence"

  return undo_step(("Gun Builder: %s %s (%d shots)"):format(fresh and "build" or "update", what, #plan), function()
    local parent
    local sources = b and b.sources
    if fresh then
      parent = find_track(burst_track_guid)
      if not parent then
        local idx = math.floor(r.GetMediaTrackInfo_Value(src_track, "IP_TRACKNUMBER"))
        r.InsertTrackAtIndex(idx, true)
        parent = r.GetTrack(0, idx)
        r.GetSetMediaTrackInfo_String(parent, "P_NAME", name .. (o.mode == 2 and " burst" or " auto"), true)
      end
      b = { track_guid = r.GetTrackGUID(parent), id = new_id(), pos = r.GetCursorPosition(), name = name,
        sources = sources }
    else
      parent = find_track(b.track_guid)
      delete_burst(parent, b.id)
    end
    burst_track_guid = b.track_guid

    local _, pname = r.GetSetMediaTrackInfo_String(parent, "P_NAME", "", false)
    local lanes = ensure_lanes(parent, n_lanes, pname ~= "" and pname or (b.name .. " burst"))
    local chunk_cache = {}
    local stacked = plan[1].src.stacked
    if stacked and #lanes > 1 then
      -- name each layer track after the source track it comes from
      for _, sl in ipairs(plan[1].src.slices) do
        local tr = lanes[sl.layer]
        local src_tr = valid_item(sl.item) and r.GetMediaItem_Track(sl.item)
        if tr and src_tr then
          local _, ln = r.GetSetMediaTrackInfo_String(src_tr, "P_NAME", "", false)
          if ln ~= "" then r.GetSetMediaTrackInfo_String(tr, "P_NAME", ln .. " (built)", true) end
        end
      end
    end
    for _, s in ipairs(plan) do
      if stacked then
        for _, sl in ipairs(s.src.slices) do
          local len = math.min(sl.len, s.len - sl.off)
          if len > 0.002 then
            place_shot(lanes[sl.layer] or lanes[#lanes], chunk_cache,
              { src = { item = sl.item, start = sl.start }, t = s.t + sl.off, len = len,
                gain = s.gain, cents = s.cents }, b.pos, o, b.id)
          end
        end
      else
        place_shot(lanes[s.lane] or lanes[#lanes], chunk_cache, s, b.pos, o, b.id)
      end
    end

    local num = find_region(b)
    if num then r.DeleteProjectMarker(0, num, true) end
    b.region_name = nil
    if o.region then
      b.region_name = b.name .. (o.mode == 2 and " burst" or " auto")
      r.AddProjectMarker2(0, true, b.pos, b.pos + total, b.region_name, -1, 0)
    end
    return b, #plan
  end)
end

----------------------------------------------------------------------
-- RE-TIME IN PLACE (shots already on the timeline: one item per shot, one track per layer)
----------------------------------------------------------------------
local SEQ_ORDERS = { "In order", "Shuffle, last stays last", "Shuffle all" }
local SEQ_DEFAULTS = { rpm = 600, ramp = false, rpm_end = 900, seed = 1, choke = false, fadeout_ms = 15 }
local SEQ_OPT_KEYS = { "rpm", "ramp", "rpm_end", "seed", "choke", "fadeout_ms" }
local LAYER_DEFAULTS = { order = 1, jit_ms = 0, jit_db = 0, jit_cents = 0, delay_ms = 0 }
local LAYER_KEYS = { "order", "jit_ms", "jit_db", "jit_cents", "delay_ms" }

local function new_layer_opt()
  local t = {}
  for k, v in pairs(LAYER_DEFAULTS) do t[k] = v end
  return t
end

local function take_pitch(it)
  local tk = r.GetActiveTake(it)
  return tk and r.GetMediaItemTakeInfo_Value(tk, "D_PITCH") or 0
end

-- Layers (one per track, in track order) from a list of item entries.
local function group_layers(list)
  local by, layers = {}, {}
  for _, e in ipairs(list) do
    local L = by[e.track]
    if not L then
      local _, nm = r.GetSetMediaTrackInfo_String(e.track, "P_NAME", "", false)
      L = { track = e.track, guid = r.GetTrackGUID(e.track), tidx = e.tidx,
            name = nm ~= "" and nm or ("Track " .. math.floor(e.tidx)), entries = {}, shots = {} }
      by[e.track] = L
      layers[#layers + 1] = L
    end
    L.entries[#L.entries + 1] = e
  end
  table.sort(layers, function(a, b) return a.tidx < b.tidx end)
  return layers
end

local function finish_sequence(sq)
  sq.N = 0
  for _, L in ipairs(sq.layers) do
    sq.N = math.max(sq.N, #L.shots)
    if not sq.lopt[L.guid] then sq.lopt[L.guid] = new_layer_opt() end
  end
  if #sq.gains ~= sq.N then sq.gains = resample(sq.gains, sq.N) end
  return sq
end

-- New sequence from items: the n-th item (left to right) on every track is shot n.
local function capture_sequence(list)
  local layers = group_layers(list)
  local anchor = {}
  for _, L in ipairs(layers) do
    table.sort(L.entries, function(a, b) return a.pos < b.pos end)
    for k, e in ipairs(L.entries) do
      if not anchor[k] or e.pos < anchor[k] then anchor[k] = e.pos end
    end
  end
  for _, L in ipairs(layers) do
    for k, e in ipairs(L.entries) do
      local it = e.item
      L.shots[k] = {
        item = it, slot = k, off = e.pos - anchor[k], len = len_of(it),
        vol = r.GetMediaItemInfo_Value(it, "D_VOL"),
        fout = r.GetMediaItemInfo_Value(it, "D_FADEOUTLEN"),
        pitch = take_pitch(it),
      }
    end
  end
  -- start from the sequence's own rate (the middle gap between shots)
  local gaps = {}
  for k = 2, #anchor do gaps[#gaps + 1] = anchor[k] - anchor[k - 1] end
  table.sort(gaps)
  local gap = gaps[math.floor((#gaps + 1) / 2)]
  local so = {}
  for k, v in pairs(SEQ_DEFAULTS) do so[k] = v end
  if gap and gap > 0.005 then
    so.rpm = clamp(60 / gap, 30, 3000)
    so.rpm_end = so.rpm
  end
  return finish_sequence({ id = new_id(), start = anchor[1] or 0, layers = layers,
    opt = so, lopt = {}, gains = {} })
end

local function store_sequence(sq)
  local lines = { ("start=%.10f"):format(sq.start) }
  for _, k in ipairs(SEQ_OPT_KEYS) do
    lines[#lines + 1] = "o_" .. k .. "=" .. value_text(sq.opt[k])
  end
  lines[#lines + 1] = "gains=" .. gains_text(sq.gains)
  for guid, lo in pairs(sq.lopt) do
    local p = {}
    for i, k in ipairs(LAYER_KEYS) do p[i] = tostring(lo[k]) end
    lines[#lines + 1] = "layer_" .. guid .. "=" .. table.concat(p, ",")
  end
  r.SetProjExtState(0, DATA, "seq_" .. sq.id, table.concat(lines, "\n"))
end

-- A sequence from its tagged items. keep = the same sequence already in memory, whose
-- settings win over the saved ones (they may not be applied yet).
local function load_sequence(id, keep)
  local list = {}
  for i = 0, r.CountMediaItems(0) - 1 do
    local it = r.GetMediaItem(0, i)
    local tag = it and seq_tag(it)
    if tag then
      local f = {}
      for v in (tag .. "|"):gmatch("([^|]*)|") do f[#f + 1] = v end
      if f[1] == id and #f >= 7 then
        local e = item_entry(it)
        e.shot = { item = it, slot = tonumber(f[2]) or 1, off = tonumber(f[3]) or 0,
          len = tonumber(f[4]) or len_of(it), vol = tonumber(f[5]) or 1,
          pitch = tonumber(f[6]) or 0, fout = tonumber(f[7]) or 0 }
        list[#list + 1] = e
      end
    end
  end
  if #list == 0 then return nil end
  local layers = group_layers(list)
  for _, L in ipairs(layers) do
    table.sort(L.entries, function(a, b) return a.shot.slot < b.shot.slot end)
    for k, e in ipairs(L.entries) do L.shots[k] = e.shot end
  end
  if keep then
    keep.layers = layers
    return finish_sequence(keep)
  end

  local sq = { id = id, layers = layers, opt = {}, lopt = {}, gains = {} }
  for k, v in pairs(SEQ_DEFAULTS) do sq.opt[k] = v end
  local rv, rec = r.GetProjExtState(0, DATA, "seq_" .. id)
  local f = {}
  if rv ~= 0 then
    for line in rec:gmatch("[^\n]+") do
      local k, v = line:match("^([^=]+)=(.*)$")
      if k then f[k] = v end
    end
  end
  sq.start = tonumber(f.start)
  if not sq.start then
    sq.start = math.huge
    for _, e in ipairs(list) do sq.start = math.min(sq.start, e.pos) end
  end
  for _, k in ipairs(SEQ_OPT_KEYS) do
    local v = parse_value(SEQ_DEFAULTS[k], f["o_" .. k])
    if v ~= nil then sq.opt[k] = v end
  end
  sq.opt.rpm = clamp(sq.opt.rpm, 30, 3000)
  sq.opt.rpm_end = clamp(sq.opt.rpm_end, 30, 3000)
  sq.opt.seed = math.floor(clamp(sq.opt.seed, 1, 99999))
  sq.opt.fadeout_ms = clamp(sq.opt.fadeout_ms, 0, 5000)
  sq.gains = gains_from(f.gains)
  for _, L in ipairs(layers) do
    local vals = list_csv(f["layer_" .. L.guid])
    if #vals > 0 then
      local lo = new_layer_opt()
      for i, k in ipairs(LAYER_KEYS) do lo[k] = tonumber(vals[i]) or LAYER_DEFAULTS[k] end
      lo.order = math.floor(clamp(lo.order, 1, #SEQ_ORDERS))
      sq.lopt[L.guid] = lo
    end
  end
  return finish_sequence(sq)
end

-- Where every shot of every layer goes: list of { shot, t, len, gain, cents, lane, idx, choked }
-- (t from the sequence start). Also returns the length, layer count and earliest t.
local function plan_sequence(sq)
  local o, N = sq.opt, sq.N
  local T = { 0 }
  for p = 2, N do T[p] = T[p - 1] + interval_at(o, p - 1, N) end
  local fout = o.fadeout_ms / 1000
  local out = {}
  for li, L in ipairs(sq.layers) do
    local lo = sq.lopt[L.guid] or LAYER_DEFAULTS
    local n = #L.shots
    local perm = {}
    for i = 1, n do perm[i] = i end
    if lo.order ~= 1 then
      local rnd = make_rng(o.seed + li * 977)
      local last = lo.order == 2 and n - 1 or n
      for i = last, 2, -1 do
        local j = math.floor(rnd() * i) + 1
        perm[i], perm[j] = perm[j], perm[i]
      end
    end
    local base = o.seed + li * 977
    local jt, jg, jp = make_rng(base + 101), make_rng(base + 202), make_rng(base + 303)
    local function jit(rng, amount) return (rng() * 2 - 1) * amount end

    local row, prev = {}, -math.huge
    for pi = 1, n do
      local sh = L.shots[perm[pi]]
      local t = (T[pi] or 0) + sh.off + lo.delay_ms / 1000
      if pi > 1 then t = t + jit(jt, lo.jit_ms / 1000) end
      if t < prev + 0.001 then t = prev + 0.001 end
      prev = t
      row[pi] = { shot = sh, t = t, lane = li, idx = sh.slot,
        gain = (sq.gains[pi] or 0) + jit(jg, lo.jit_db), cents = jit(jp, lo.jit_cents),
        src = { label = tostring(sh.slot) } }
    end
    for pi, sp in ipairs(row) do
      local l = sp.shot.len
      sp.choked = false
      if o.choke and row[pi + 1] then
        local c = row[pi + 1].t - sp.t + fout
        if c < l then l, sp.choked = c, true end
      end
      sp.len = math.max(0.005, l)
      out[#out + 1] = sp
    end
  end
  local t0, total = math.huge, 0
  for _, sp in ipairs(out) do t0 = math.min(t0, sp.t) end
  if t0 == math.huge then t0 = 0 end
  for _, sp in ipairs(out) do total = math.max(total, sp.t + sp.len - t0) end
  return out, total, #sq.layers, t0
end

local function tag_shot(sq, sh)
  r.GetSetMediaItemInfo_String(sh.item, SEQ_KEY, ("%s|%d|%.10f|%.10f|%.10f|%.6f|%.10f"):format(
    sq.id, sh.slot, sh.off, sh.len, sh.vol, sh.pitch, sh.fout), true)
end

local function apply_sequence(sq)
  local plan = plan_sequence(sq)
  local fout = sq.opt.fadeout_ms / 1000
  undo_step("Gun Builder: re-time shots", function()
    for _, sp in ipairs(plan) do
      local sh, it = sp.shot, sp.shot.item
      if valid_item(it) then
        r.SetMediaItemInfo_Value(it, "D_POSITION", sq.start + sp.t)
        r.SetMediaItemInfo_Value(it, "D_LENGTH", sp.len)
        r.SetMediaItemInfo_Value(it, "D_VOL", sh.vol * 10 ^ (sp.gain / 20))
        r.SetMediaItemInfo_Value(it, "D_FADEOUTLEN",
          sp.choked and math.min(fout, sp.len / 2) or math.min(sh.fout, sp.len))
        local tk = r.GetActiveTake(it)
        if tk then r.SetMediaItemTakeInfo_Value(tk, "D_PITCH", sh.pitch + sp.cents / 100) end
        tag_shot(sq, sh)
      end
    end
    store_sequence(sq)
  end)
end

-- Take the items as they are now as the sequence's new starting point.
local function recapture_sequence(sq)
  local list = {}
  for _, L in ipairs(sq.layers) do
    for _, sh in ipairs(L.shots) do
      if valid_item(sh.item) then list[#list + 1] = item_entry(sh.item) end
    end
  end
  local nsq = capture_sequence(list)
  undo_step("Gun Builder: take current positions as the original", function()
    for _, L in ipairs(nsq.layers) do
      for _, sh in ipairs(L.shots) do tag_shot(nsq, sh) end
    end
    store_sequence(nsq)
  end)
  return nsq
end

local function seq_sig(sq)
  local p = {}
  for _, k in ipairs(SEQ_OPT_KEYS) do p[#p + 1] = tostring(sq.opt[k]) end
  for _, g in ipairs(sq.gains) do p[#p + 1] = ("%.2f"):format(g) end
  for _, L in ipairs(sq.layers) do
    local lo = sq.lopt[L.guid] or LAYER_DEFAULTS
    for _, k in ipairs(LAYER_KEYS) do p[#p + 1] = tostring(lo[k]) end
  end
  return table.concat(p, "|")
end

----------------------------------------------------------------------
-- STATE
----------------------------------------------------------------------
local ctx = ImGui.CreateContext(TITLE)

local tabs = load_tabs()
local opt = tabs.list[tabs.active].s          -- the showing tab's settings
local presets = load_presets()
local preset_name = ""

local items = {}          -- source items (burst / full auto) or items to spread (single shots)
local sources = {}        -- GUIDs of the current source items (burst / full auto)
local last_state, last_mode = nil, nil
local preview_idx = 1
local excluded = {}       -- "guid:k" -> true for source shots left out
local burst = nil         -- the burst being live-updated
local built_sig = nil
local status = ""
local view = "burst"      -- in Burst / Full auto: "burst" (build from a sausage) or "seq" (re-time)
local seq = nil           -- the sequence being re-timed
local force_view = nil    -- the user's choice for an untagged selection
local last_sel_key = nil
local show_switch = false
local memo_sig = nil
local analysis = { per = {}, pool = {} }
local dirty_tabs, dirty_at = false, 0

local W = 520             -- width of the graphs (follows the window)
local LABEL_X = 170
local C = {} -- colors
C.COLOR_DIM = 0x9A9A9AFF
C.COL_BG = 0x1E1E1EFF
C.COL_BAND = 0xFFFFFF10
C.COL_LANE = 0xFFFFFF08
C.COL_WAVE = 0x5FB4C8FF
C.COL_FLOOR = 0xD8B44A90
C.COL_ONSET = 0xE05050FF
C.COL_OFF = 0x000000A0
C.COL_TEXT = 0xFFFFFFC0
C.COL_BAR = 0xE0A040FF
C.COL_BAR_HOT = 0xFFD070FF
C.COL_ZERO = 0xFFFFFF50
C.COL_ACCENT = 0x3A78B8FF
C.SHOT_COLS = { 0x5FB4C8FF, 0xE0A040FF, 0x8BC34AFF, 0xD07AD0FF, 0xE06060FF, 0x7090E0FF }
C.PALETTE = { 0xE0605AFF, 0xE8A24AFF, 0xD9D35BFF, 0x7FCB6AFF, 0x4FBFB0FF, 0x5A9BE0FF, 0x8A7AE0FF, 0xD27AD0FF }

local function tab_now() return tabs.list[tabs.active] end

-- Project changes asked for while drawing run after the window is finished (outside
-- ImGui's Begin/End), so a problem in one can never leave the window half-drawn.
local pending = nil
local function later(fn) pending = fn end

local function mark_dirty() dirty_tabs = true; dirty_at = r.time_precise() end

local function save_all(proj)
  local ok = pcall(save_tabs, tabs, proj)
  if ok then dirty_tabs = false end
end

-- Gain list for the mode showing, sized to the shots it covers.
local function cur_gains()
  local tab = tab_now()
  tab.gains = tab.gains or { auto = {}, burst = {} }
  local key = opt.mode == 2 and "burst" or "auto"
  local _, per = shot_layout(opt)
  local g = tab.gains[key] or {}
  if #g ~= per then g = resample(g, per) end
  tab.gains[key] = g
  return g
end

-- Signature of everything that shapes a build (a live burst rebuilds when it changes).
local function burst_sig_of(o, gains, ex)
  local p = {}
  for k in pairs(DEFAULTS) do
    if not UI_KEYS[k] and not SPREAD_KEYS[k] then p[#p + 1] = k .. "=" .. tostring(o[k]) end
  end
  table.sort(p)
  for _, g in ipairs(gains) do p[#p + 1] = ("%.2f"):format(g) end
  if ex then
    local e = {}
    for key in pairs(ex) do e[#e + 1] = key end
    table.sort(e)
    p[#p + 1] = table.concat(e, ",")
  end
  return table.concat(p, "|")
end
local function burst_sig() return burst_sig_of(opt, cur_gains(), excluded) end

-- Stop live-updating the current burst (it stays as it is).
local function let_go(why)
  if burst then
    burst = nil
    if why then status = why end
  end
end

-- Make an existing burst the one being edited: its settings go into the showing tab.
local function attach(id)
  local b, o, g, ex = load_burst(id)
  if not b or not burst_exists(b) then return false end
  for k in pairs(DEFAULTS) do
    if not UI_KEYS[k] and not SPREAD_KEYS[k] then opt[k] = o[k] end
  end
  sanitize(opt)
  local tab = tab_now()
  local _, per = shot_layout(opt)
  tab.gains[opt.mode == 2 and "burst" or "auto"] = resample(g, per)
  burst, excluded = b, ex
  sources = b.sources
  burst_track_guid = b.track_guid
  built_sig = burst_sig()
  memo_sig = nil
  last_mode = opt.mode
  mark_dirty()
  status = "Editing the selected " .. (opt.mode == 2 and "burst" or "sequence") ..
    " (its settings are loaded into this tab). Changes update it live."
  return true
end

-- On opening: carry on live-updating the project's last burst, but only if it was built
-- with exactly the showing tab's settings (so opening never changes a tab).
local function resume_last()
  local rv, id = r.GetProjExtState(0, DATA, "last")
  if rv == 0 or id == "" then return end
  local b, o, g = load_burst(id)
  if not b or o.mode ~= opt.mode or not burst_exists(b) then return end
  if burst_sig_of(o, g) == burst_sig_of(opt, cur_gains()) then attach(id) end
end

local function same_sources(sel, guids)
  if #sel ~= #(guids or {}) then return false end
  local set = {}
  for _, g in ipairs(guids) do set[g] = true end
  for _, e in ipairs(sel) do if not set[e.guid] then return false end end
  return true
end

-- Burst / Full auto: works out what the selection is.
--   shots of a re-timed sequence    -> that sequence
--   several items on one track      -> shots to re-time (can be switched)
--   source items                    -> the sausage(s) to build from
--   one burst (only when newly selected) -> that burst becomes the one being edited
--   nothing                         -> the source from before stays
local function refresh_build()
  local sel, sel_burst, sel_seq = collect_selection()
  local keys = {}
  for i, e in ipairs(sel) do keys[i] = e.guid end
  local key = table.concat(keys, ",") .. "|" .. tostring(sel_burst)
  local sel_changed = key ~= last_sel_key
  if sel_changed then last_sel_key, force_view = key, nil end
  show_switch = #sel > 0 and not sel_seq

  if sel_seq then
    local sq = load_sequence(sel_seq, seq and seq.id == sel_seq and seq or nil)
    if sq then
      if not (seq and seq.id == sq.id) then sq.applied_sig = seq_sig(sq) end
      seq, view = sq, "seq"
      return
    end
  end
  local auto = "burst"
  local per_track = {}
  for _, e in ipairs(sel) do
    per_track[e.track] = (per_track[e.track] or 0) + 1
    if per_track[e.track] > 1 then auto = "seq" end
  end
  if #sel > 0 and (force_view or auto) == "seq" then
    local sq = capture_sequence(sel)
    if seq and seq.fresh and seq.key == key then
      -- same selection, nothing applied yet: keep what has been dialled in
      sq.id, sq.opt, sq.applied_sig = seq.id, seq.opt, seq.applied_sig
      for g, lo in pairs(seq.lopt) do sq.lopt[g] = lo end
      sq.gains = resample(seq.gains, sq.N)
    else
      sq.applied_sig = seq_sig(sq)
    end
    sq.fresh, sq.key = true, key
    seq, view = sq, "seq"
    return
  end
  view = "burst"

  if #sel == 0 and sel_burst and sel_changed and not (burst and burst.id == sel_burst) then
    attach(sel_burst)
  end
  if #sel > 0 then
    if burst and not same_sources(sel, burst.sources) then
      let_go("New source selected: Build makes a new one.")
    end
    sources = keys
  elseif burst then
    sources = burst.sources or {}
  end
  items = items_by_guid(sources, items)
  prune_cache(items)
  if preview_idx > #items then preview_idx = math.max(1, #items) end
end

local function refresh()
  local state = r.GetProjectStateChangeCount(0)
  if state == last_state and opt.mode == last_mode then return end
  local prev_mode = last_mode
  last_state, last_mode = state, opt.mode
  if burst and not burst_exists(burst) then burst = nil end
  if opt.mode == 1 then
    items = collect_spread_items()
  else
    if prev_mode ~= opt.mode then items = {} end -- the list was the single-shot selection
    refresh_build()
  end
end

local function set_mode(m)
  if m == opt.mode then return end
  opt.mode = m
  let_go("Switched to " .. MODES[m] .. ". Click a burst on the timeline to edit it again.")
  memo_sig, last_state = nil, nil
  mark_dirty()
end

----------------------------------------------------------------------
-- GUI HELPERS
----------------------------------------------------------------------
local function label(text)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, text)
  ImGui.SameLine(ctx, LABEL_X)
end

local function tooltip(text)
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, text) end
end

local function shot_key(e, k) return (e.guid or tostring(e.item)) .. ":" .. k end

-- Stacked sausages: two or more source items on different tracks that play at the same
-- time (one sausage per layer). Their shots are found together and each shot keeps all layers.
local function is_stacked(list)
  if #list < 2 then return false end
  local tracks, a, b = {}, -math.huge, math.huge
  for _, e in ipairs(list) do
    if tracks[e.track] then return false end
    tracks[e.track] = true
    a, b = math.max(a, e.pos), math.min(b, e.pos + e.len)
  end
  return a < b
end

local STACK_STEP = 0.001 -- grid of the combined envelope (s)

local function analyse_stacked()
  local per, pool, layers = {}, {}, {}
  local t0, t1 = math.huge, -math.huge
  for i, e in ipairs(items) do
    local env, err = get_env(e.item)
    per[i] = { env = env, err = err, shots = {} }
    if env then
      layers[#layers + 1] = { e = e, env = env, i = i }
      t0, t1 = math.min(t0, e.pos), math.max(t1, e.pos + e.len)
    end
  end
  if #layers == 0 or t1 <= t0 then return { per = per, pool = pool, stacked = true, n_layers = #items } end

  -- Combined envelope in project time: the loudest layer at each moment, every layer
  -- measured against its own peak so a quiet layer counts as much as a loud one.
  local n = math.max(1, math.ceil((t1 - t0) / STACK_STEP))
  local db = {}
  for j = 1, n do db[j] = SILENCE_DB end
  for _, L in ipairs(layers) do
    local env, pos = L.env, L.e.pos
    if env.peak > SILENCE_DB then
      for w = 1, env.n do
        local j = math.floor((pos + (w - 1) * env.hop - t0) / STACK_STEP) + 1
        if j >= 1 and j <= n then
          local v = env.db[w] - env.peak
          if v > db[j] then db[j] = v end
        end
      end
    end
  end
  local cenv = { db = db, n = n, hop = STACK_STEP, peak = 0, len = t1 - t0 }
  local shots = plan_shots(cenv, detect(cenv, opt), opt)

  for k, sh in ipairs(shots) do
    local gs, ge = t0 + sh.start, t0 + sh.start + sh.len
    -- the same shot, as each layer sees it (times from that item's start)
    for _, L in ipairs(layers) do
      local e = L.e
      local list = per[L.i].shots
      list[#list + 1] = { start = gs - e.pos, len = sh.len, onset = t0 + sh.onset - e.pos }
    end
    if not excluded["stack:" .. k] then
      local slices = {}
      for li, e in ipairs(items) do
        local a, b = math.max(gs, e.pos), math.min(ge, e.pos + e.len)
        if b - a > 0.002 and per[li].env then
          slices[#slices + 1] = { item = e.item, start = a - e.pos, len = b - a, off = a - gs, layer = li }
        end
      end
      if #slices > 0 then
        pool[#pool + 1] = { stacked = true, slices = slices, len = sh.len, label = tostring(k) }
      end
    end
  end
  return { per = per, pool = pool, stacked = true, n_layers = #items, n_found = #shots }
end

-- Detection on every source item; builds the shot pool.
local function analyse()
  if opt.stack and is_stacked(items) then return analyse_stacked() end
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

-- Waveform of a source item with the shots found in it.
local function draw_source(e, a, stacked)
  local env, shots = a.env, a.shots
  local function key_of(k) return stacked and ("stack:" .. k) or shot_key(e, k) end
  local dl = ImGui.GetWindowDrawList(ctx)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local H = 100
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + W, y0 + H, C.COL_BG, 4)

  local function tx(t) return x0 + clamp(t / env.len, 0, 1) * W end
  local function ty(d) return y0 + H - clamp((d - (env.peak - 60)) / 60, 0, 1) * H end

  for k, s in ipairs(shots) do
    if k % 2 == 0 then
      ImGui.DrawList_AddRectFilled(dl, tx(s.start), y0, tx(s.start + s.len), y0 + H, C.COL_BAND)
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
    if y < y0 + H then ImGui.DrawList_AddLine(dl, x0 + x + 0.5, y0 + H, x0 + x + 0.5, y, C.COL_WAVE, 1) end
  end

  local fy = ty(env.peak + opt.floor_db)
  ImGui.DrawList_AddLine(dl, x0, fy, x0 + W, fy, C.COL_FLOOR, 1)

  for k, s in ipairs(shots) do
    local x = tx(s.onset)
    ImGui.DrawList_AddLine(dl, x, y0, x, y0 + H, C.COL_ONSET, 1)
    ImGui.DrawList_AddText(dl, x + 2, y0 + 2, C.COL_TEXT, tostring(k))
    if excluded[key_of(k)] then
      ImGui.DrawList_AddRectFilled(dl, tx(s.start), y0, tx(s.start + s.len), y0 + H, C.COL_OFF)
    end
  end

  ImGui.InvisibleButton(ctx, "##source", W, H)
  if ImGui.IsItemHovered(ctx) then
    local mx = ImGui.GetMousePos(ctx)
    local t = clamp((mx - x0) / W * env.len, 0, env.len)
    local hit
    for k, s in ipairs(shots) do
      if t >= s.start and t < s.start + s.len then hit = k end
    end
    if hit and ImGui.IsItemClicked(ctx, ImGui.MouseButton_Left) then
      local key = key_of(hit)
      excluded[key] = not excluded[key] or nil
      memo_sig = nil
    end
    ImGui.SetTooltip(ctx, hit
      and ("Shot %d%s\nClick to %s it"):format(hit,
        excluded[key_of(hit)] and " (left out)" or "",
        excluded[key_of(hit)] and "use" or "leave out")
      or "Red = shots found\nYellow = detection floor")
  end
end

-- Gain editor: one bar per shot, drawn with the mouse.
local drag_last = nil

local function draw_gains(gains, labels, what)
  local N = #gains
  local dl = ImGui.GetWindowDrawList(ctx)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local H = 110
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + W, y0 + H, C.COL_BG, 4)
  ImGui.InvisibleButton(ctx, "##gains", W, H)
  if N == 0 then drag_last = nil; return end
  local function ty(v) return y0 + (GAIN_MAX - v) / (GAIN_MAX - GAIN_MIN) * H end
  local zy = ty(0)
  ImGui.DrawList_AddLine(dl, x0, zy, x0 + W, zy, C.COL_ZERO, 1)

  local hovered = ImGui.IsItemHovered(ctx)
  local active = ImGui.IsItemActive(ctx)
  local mx, my = ImGui.GetMousePos(ctx)
  local bw = W / N
  local hot = (hovered or active) and math.floor(clamp(math.floor((mx - x0) / bw) + 1, 1, N)) or nil

  if active and hot then
    local v = GAIN_MAX - clamp((my - y0) / H, 0, 1) * (GAIN_MAX - GAIN_MIN)
    v = math.floor(v * 2 + 0.5) / 2
    if drag_last and drag_last[1] <= N then
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
  if hovered and hot and ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Right) then gains[hot] = 0 end

  for k = 1, N do
    local xa, xb = x0 + (k - 1) * bw + 1, x0 + k * bw - 1
    if xb < xa + 1 then xb = xa + 1 end
    local y = ty(gains[k] or 0)
    ImGui.DrawList_AddRectFilled(dl, xa, math.min(y, zy), xb, math.max(y, zy) + 1,
      k == hot and C.COL_BAR_HOT or C.COL_BAR)
    if bw >= 16 and labels[k] then
      ImGui.DrawList_AddText(dl, xa + 2, y0 + H - 15, C.COL_TEXT, labels[k])
    end
  end

  if hovered and hot then
    ImGui.SetTooltip(ctx, ("%s %d%s: %+.1f dB\nDrag to draw the gain, right-click to reset"):format(
      what or "Shot", hot, labels[hot] and (" (source shot " .. labels[hot] .. ")") or "", gains[hot] or 0))
  end
end

-- Preset gain shapes, written into the given gain list.
local function gain_shapes(gains, title)
  ImGui.Text(ctx, title or "Gain per shot")
  ImGui.SameLine(ctx, LABEL_X)
  local function shape(name, f)
    if ImGui.SmallButton(ctx, name) then
      local N = #gains
      for k = 1, N do
        gains[k] = clamp(f(N > 1 and (k - 1) / (N - 1) or 0, k), GAIN_MIN, GAIN_MAX)
      end
    end
    ImGui.SameLine(ctx)
  end
  shape("Flat", function() return 0 end)
  shape("Fade out", function(x) return -12 * x end)
  shape("Fade in", function(x) return -12 * (1 - x) end)
  shape("Accent 1st", function(_, k) return k == 1 and 3 or -2 end)
  shape("Random", function() return -math.random() * 4 end)
  ImGui.NewLine(ctx)
end

-- Timeline view of a build: each block one shot, height = gain.
local function draw_plan(plan, total, n_lanes, t0)
  t0 = t0 or 0
  n_lanes = math.max(1, n_lanes)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local H = clamp(n_lanes * 14, 60, 180)
  local LH = H / n_lanes
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + W, y0 + H, C.COL_BG, 4)
  if total > 0 then
    local function tx(t) return x0 + (t - t0) / total * W end
    for k, s in ipairs(plan) do
      local lane = math.min(s.lane or 1, n_lanes)
      local yb = y0 + lane * LH
      local h = clamp((s.gain - GAIN_MIN) / (GAIN_MAX - GAIN_MIN), 0.05, 1) * (LH - 2)
      local col = C.SHOT_COLS[((s.idx or 1) - 1) % #C.SHOT_COLS + 1]
      local xa = tx(s.t)
      ImGui.DrawList_AddRectFilled(dl, xa, yb - h, math.max(xa + 1, tx(s.t + s.len)), yb,
        (col & 0xFFFFFF00) | 0x50)
      ImGui.DrawList_AddLine(dl, xa, yb - h, xa, yb, col, 1)
      if n_lanes == 1 and (k == 1 or tx(s.t) - tx(plan[k - 1].t) > 14) then
        ImGui.DrawList_AddText(dl, xa + 2, y0 + 2, C.COL_TEXT, s.src.label)
      end
    end
  end
  ImGui.Dummy(ctx, W, H)
  tooltip("Each block is one shot, its height shows the gain,\nthe number is the source shot it uses.")
end

local function rate_slider(id, key, t)
  t = t or opt
  ImGui.SetNextItemWidth(ctx, 240)
  local rv, v
  if opt.use_ms then
    rv, v = ImGui.SliderDouble(ctx, id, 60000 / t[key], 20, 500, "%.1f ms between shots")
    if rv then t[key] = 60000 / clamp(v, 20, 2000) end
  else
    rv, v = ImGui.SliderDouble(ctx, id, t[key], 120, 3000, "%.0f RPM")
    if rv then t[key] = clamp(v, 30, 3000) end
  end
  if rv then mark_dirty() end
  tooltip(("%.0f RPM = %.1f ms between shots = %.1f shots per second"):format(
    t[key], 60000 / t[key], t[key] / 60))
end

-- Small wrappers that also note the tab changed.
local function slider(id, key, lo, hi, fmt, w)
  ImGui.SetNextItemWidth(ctx, w or 240)
  local rv, v = ImGui.SliderDouble(ctx, id, opt[key], lo, hi, fmt)
  if rv then opt[key] = v; mark_dirty() end
  return rv
end

local function checkbox(text, key)
  local rv, v = ImGui.Checkbox(ctx, text, opt[key])
  if rv then opt[key] = v; mark_dirty() end
  return rv
end

local function combo(id, key, list, w)
  ImGui.SetNextItemWidth(ctx, w or 240)
  if ImGui.BeginCombo(ctx, id, list[opt[key]] or list[1]) then
    for i, name in ipairs(list) do
      if ImGui.Selectable(ctx, name, i == opt[key]) then opt[key] = i; mark_dirty() end
    end
    ImGui.EndCombo(ctx)
  end
end

----------------------------------------------------------------------
-- SINGLE SHOTS VIEW
----------------------------------------------------------------------
local function draw_spread_preview(id, shots, starts, t0, t1, lanes, nlanes)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local H = 110
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + W, y0 + H, C.COL_BG, 4)
  local span = math.max(t1 - t0, 1e-6)
  local lane_h = H / math.max(1, nlanes)
  for i = 1, nlanes, 2 do
    ImGui.DrawList_AddRectFilled(dl, x0, y0 + (i - 1) * lane_h, x0 + W, y0 + i * lane_h, C.COL_LANE)
  end
  local function tx(t) return x0 + (t - t0) / span * W end
  local hovered_shot
  local mx, my = ImGui.GetMousePos(ctx)
  for k, s in ipairs(shots) do
    local delta = starts and (starts[k] - s.start) or 0
    local col = C.PALETTE[(k - 1) % #C.PALETTE + 1]
    for _, e in ipairs(s.items) do
      local lane = lanes[e.track] or 1
      local ax = tx(e.pos + delta)
      local bx = math.max(ax + 2, tx(e.stop + delta))
      local ay = y0 + (lane - 1) * lane_h + 1
      local by = ay + math.max(2, lane_h - 2)
      ImGui.DrawList_AddRectFilled(dl, ax, ay, bx, by, (col & 0xFFFFFF00) | 0x90)
      ImGui.DrawList_AddLine(dl, ax, ay, ax, by, col, 2)
      if mx >= ax and mx <= bx and my >= ay and my <= by then hovered_shot = k end
    end
  end
  ImGui.InvisibleButton(ctx, id, W, H)
  if ImGui.IsItemHovered(ctx) and hovered_shot then
    local s = shots[hovered_shot]
    ImGui.SetTooltip(ctx, ("Shot %d: %d layer%s, %.0f ms long"):format(
      hovered_shot, #s.items, #s.items == 1 and "" or "s", (s.stop - s.start) * 1000))
  end
end

local function draw_single()
  local shots = group_shots(items, opt.tol_ms / 1000)

  if #items == 0 then
    ImGui.TextWrapped(ctx,
      "Select every item of the rapid-fire session (all layers, all shots).\n" ..
      "Items that start together are one shot (its layers, stacked across tracks); " ..
      "the shots get spaced out along the timeline, one after another.")
  else
    local min_l, max_l = math.huge, 0
    for _, s in ipairs(shots) do
      min_l, max_l = math.min(min_l, #s.items), math.max(max_l, #s.items)
    end
    local layers = min_l == max_l and tostring(min_l) or ("%d-%d"):format(min_l, max_l)
    ImGui.Text(ctx, ("%d shots found, %s layer%s each (%d items)"):format(
      #shots, layers, max_l == 1 and "" or "s", #items))

    local lanes, order = {}, {}
    for _, e in ipairs(items) do
      if not lanes[e.track] then lanes[e.track] = true; order[#order + 1] = e end
    end
    table.sort(order, function(a, b) return a.tidx < b.tidx end)
    for i, e in ipairs(order) do lanes[e.track] = i end

    local starts = spread_layout(shots, opt.gap)
    local t0, now_end = math.huge, 0
    for _, s in ipairs(shots) do t0 = math.min(t0, s.start); now_end = math.max(now_end, s.stop) end
    local last = shots[#shots]
    local after_end = starts[#shots] + (last.stop - last.start)

    ImGui.Text(ctx, "Now")
    draw_spread_preview("##now", shots, nil, t0, now_end, lanes, #order)
    ImGui.Text(ctx, ("After (%.2f s long)"):format(after_end - t0))
    draw_spread_preview("##after", shots, starts, t0, after_end, lanes, #order)
  end

  ImGui.SeparatorText(ctx, "Settings")
  label("Same shot within")
  slider("##tol", "tol_ms", 1, 200, "%.0f ms", 240)
  tooltip("Items that start within this much of a shot's first item belong to that shot.\n" ..
    "Keep it below the time between shots (600 RPM = 100 ms, 900 RPM = 67 ms).\n" ..
    "If two shots got merged, lower it; if one shot got split in two, raise it.")

  label("Gap (seconds)")
  ImGui.SetNextItemWidth(ctx, 120)
  local rv, v = ImGui.InputDouble(ctx, "##gap", opt.gap, 0.1, 1.0, "%.2f")
  if rv then opt.gap = clamp(v, 0, 600); mark_dirty() end
  tooltip("Space between the end of one shot (its longest layer) and the start of the next.")

  checkbox("Move later items on these tracks out of the way", "ripple")
  checkbox("Create a region per shot", "regions")
  ImGui.BeginDisabled(ctx, not opt.regions)
  label("  Region name")
  ImGui.SetNextItemWidth(ctx, 180)
  rv, v = ImGui.InputText(ctx, "##prefix", opt.prefix)
  if rv then opt.prefix = v:gsub("[\r\n|;]", " "); mark_dirty() end
  tooltip("Regions are named <name>_01, <name>_02...")
  ImGui.EndDisabled(ctx)

  ImGui.Separator(ctx)
  ImGui.BeginDisabled(ctx, #shots < 1)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 8)
  if ImGui.Button(ctx, ("Spread %d shot%s"):format(#shots, #shots == 1 and "" or "s"), 200, ImGui.GetFrameHeight(ctx) * 1.3) then
    local list, o = items, opt
    later(function()
      local n = apply_spread(list, o) or 0
      status = ("Spread %d shot%s. Ctrl+Z to undo."):format(n, n == 1 and "" or "s")
      last_state = nil
    end)
  end
  ImGui.PopStyleVar(ctx)
  ImGui.EndDisabled(ctx)
  ImGui.TextWrapped(ctx, status)
end

----------------------------------------------------------------------
-- RE-TIME VIEW
----------------------------------------------------------------------
local function draw_view_switch()
  label("Selection is")
  if ImGui.RadioButton(ctx, "A sausage to build from", view == "burst") and view ~= "burst" then
    force_view, last_state = "burst", nil
  end
  tooltip("Find the shots inside the selected item(s) and build from them.")
  ImGui.SameLine(ctx)
  if ImGui.RadioButton(ctx, "Shots to re-time", view == "seq") and view ~= "seq" then
    force_view, last_state = "seq", nil
  end
  tooltip("Each selected item is one shot and each track one layer:\n" ..
    "move them in place to a new rate, with gain and humanize per layer.")
end

local function draw_seq()
  local sq = seq
  local so = sq.opt
  local rv, v
  local plan, total, n_layers, t0 = plan_sequence(sq)

  ImGui.Text(ctx, ("Shots on the timeline: %d layer%s, %d shots"):format(n_layers, n_layers == 1 and "" or "s", sq.N))
  if show_switch then draw_view_switch() end
  ImGui.Separator(ctx)

  label("Rate of fire")
  rate_slider("##srpm", "rpm", so)
  ImGui.SameLine(ctx)
  checkbox("ms", "use_ms")
  label("")
  rv, v = ImGui.Checkbox(ctx, "Ramp to##sramp", so.ramp)
  if rv then so.ramp = v end
  tooltip("Change the rate across the sequence, e.g. a minigun spinning up.")
  ImGui.SameLine(ctx)
  ImGui.BeginDisabled(ctx, not so.ramp)
  rate_slider("##srpm_end", "rpm_end", so)
  ImGui.EndDisabled(ctx)

  label("Shot tails")
  if ImGui.RadioButton(ctx, "Keep full length##s", not so.choke) then so.choke = false end
  ImGui.SameLine(ctx)
  if ImGui.RadioButton(ctx, "Cut at next shot##s", so.choke) then so.choke = true end
  tooltip("Shorten each item so it ends (with a fade) where the next shot on its layer starts.\n" ..
    "The original lengths come back when you switch back.")
  if so.choke then
    label("  Fade out")
    ImGui.SetNextItemWidth(ctx, 115)
    rv, v = ImGui.InputDouble(ctx, "##sfout", so.fadeout_ms, 0, 0, "%.1f ms")
    if rv then so.fadeout_ms = clamp(v, 0, 5000) end
  end

  ImGui.Separator(ctx)
  gain_shapes(sq.gains)
  local labels = {}
  for k = 1, sq.N do labels[k] = tostring(k) end
  draw_gains(sq.gains, labels)

  ImGui.Text(ctx, ("Result: %.2f s"):format(total))
  draw_plan(plan, total, n_layers, t0)

  ImGui.Separator(ctx)
  local COLS = { 150, 270, 335, 400, 465 }
  ImGui.Text(ctx, "Layer")
  ImGui.SameLine(ctx, COLS[1]); ImGui.Text(ctx, "Order")
  ImGui.SameLine(ctx, COLS[2]); ImGui.Text(ctx, "Time +/-")
  ImGui.SameLine(ctx, COLS[3]); ImGui.Text(ctx, "Gain +/-")
  ImGui.SameLine(ctx, COLS[4]); ImGui.Text(ctx, "Pitch +/-")
  ImGui.SameLine(ctx, COLS[5]); ImGui.Text(ctx, "Delay")
  for li, L in ipairs(sq.layers) do
    local lo = sq.lopt[L.guid]
    if not lo then lo = new_layer_opt(); sq.lopt[L.guid] = lo end
    ImGui.PushID(ctx, "layer" .. li)
    ImGui.AlignTextToFramePadding(ctx)
    local nm = L.name
    if #nm > 20 then nm = nm:sub(1, 19) .. "~" end
    ImGui.Text(ctx, ("%s (%d)"):format(nm, #L.shots))
    tooltip(L.name)
    ImGui.SameLine(ctx, COLS[1])
    ImGui.SetNextItemWidth(ctx, 115)
    if ImGui.BeginCombo(ctx, "##order", SEQ_ORDERS[lo.order] or SEQ_ORDERS[1]) then
      for i, name in ipairs(SEQ_ORDERS) do
        if ImGui.Selectable(ctx, name, i == lo.order) then lo.order = i end
      end
      ImGui.EndCombo(ctx)
    end
    tooltip("Which shot sound plays where on this layer.\n" ..
      "Shuffle mixes the shots up; \"last stays last\" keeps the tail shot at the end.")
    ImGui.SameLine(ctx, COLS[2])
    ImGui.SetNextItemWidth(ctx, 60)
    rv, v = ImGui.SliderDouble(ctx, "##jms", lo.jit_ms, 0, 20, "%.1fms")
    if rv then lo.jit_ms = v end
    ImGui.SameLine(ctx, COLS[3])
    ImGui.SetNextItemWidth(ctx, 60)
    rv, v = ImGui.SliderDouble(ctx, "##jdb", lo.jit_db, 0, 6, "%.1fdB")
    if rv then lo.jit_db = v end
    ImGui.SameLine(ctx, COLS[4])
    ImGui.SetNextItemWidth(ctx, 60)
    rv, v = ImGui.SliderDouble(ctx, "##jct", lo.jit_cents, 0, 200, "%.0fc")
    if rv then lo.jit_cents = v end
    ImGui.SameLine(ctx, COLS[5])
    ImGui.SetNextItemWidth(ctx, 60)
    rv, v = ImGui.SliderDouble(ctx, "##dly", lo.delay_ms, -20, 20, "%.1fms")
    if rv then lo.delay_ms = v end
    tooltip("Shift this whole layer earlier or later.")
    ImGui.PopID(ctx)
  end
  if #sq.layers > 0 and ImGui.SmallButton(ctx, "Copy first layer to all") then
    local first = sq.lopt[sq.layers[1].guid]
    if first then
      for _, L in ipairs(sq.layers) do
        local lo = sq.lopt[L.guid]
        if lo then for _, k in ipairs(LAYER_KEYS) do lo[k] = first[k] end end
      end
    end
  end
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, "Reroll##seq") then so.seed = (so.seed % 99999) + 1 end
  tooltip("New shuffle order and humanize values for every layer.")

  ImGui.Separator(ctx)
  local busy = ImGui.IsAnyItemActive(ctx) or ImGui.IsMouseDown(ctx, ImGui.MouseButton_Left)
  local cur = seq_sig(sq)
  local function apply_now()
    later(function()
      apply_sequence(sq)
      sq.applied_sig, sq.fresh = cur, false
      status = "Shots re-timed. Ctrl+Z to undo."
      last_state = nil
    end)
  end
  if sq.N > 0 and opt.live and not busy and cur ~= sq.applied_sig then apply_now() end
  ImGui.BeginDisabled(ctx, sq.N == 0 or (opt.live and cur == sq.applied_sig))
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 8)
  if ImGui.Button(ctx, "Apply", 150, 0) then apply_now() end
  ImGui.PopStyleVar(ctx)
  ImGui.EndDisabled(ctx)
  ImGui.SameLine(ctx)
  checkbox("Live update", "live")
  tooltip("Move the items every time you change a setting.")
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, "Use current positions") then
    later(function()
      seq = recapture_sequence(sq)
      seq.applied_sig = seq_sig(seq)
      status = "The items as they are now are the new starting point."
      last_state = nil
    end)
  end
  tooltip("If you moved, trimmed or changed items by hand, take them as they are now\n" ..
    "as the starting point (otherwise the next change puts them back).")
  ImGui.TextWrapped(ctx, status)
end

----------------------------------------------------------------------
-- BURST / FULL AUTO VIEW
----------------------------------------------------------------------
local function draw_build()
  local is_burst = opt.mode == 2
  local sig = table.concat({ tostring(last_state), #items, tostring(opt.stack), opt.rise_db, opt.floor_db,
    opt.min_ms, opt.preroll_ms }, "|")
  if sig ~= memo_sig then
    memo_sig = sig
    analysis = analyse()
  end
  local pool = analysis.pool
  local gains = cur_gains()
  local plan, total, n_lanes = plan_burst(pool, opt, gains)

  -- Source -----------------------------------------------------------------------
  if #items == 0 then
    ImGui.TextWrapped(ctx,
      "Select an item holding a row of single shots (a sausage file), or several items.\n" ..
      "Their shots become the building blocks.\n\n" ..
      (is_burst and "" or "Or select shots already on the timeline (one item per shot, one track per layer) " ..
        "to re-time them in place."))
  else
    local total_found = 0
    if analysis.stacked then
      total_found = analysis.n_found or 0
      ImGui.Text(ctx, ("%d shots found across %d stacked layers, %d used%s"):format(total_found,
        analysis.n_layers or #items, #pool, #pool < total_found and " (click a shot to use it again)" or ""))
      tooltip("The selected items play at the same time on different tracks, so they're treated as\n" ..
        "layers of one sausage: shots are found across all of them together, and every shot\n" ..
        "is built from all the layers, each on its own track.")
    else
      for _, a in ipairs(analysis.per) do total_found = total_found + #a.shots end
      ImGui.Text(ctx, ("%d shots found, %d used%s"):format(total_found, #pool,
        #pool < total_found and " (click a shot to use it again)" or ""))
    end
    if is_stacked(items) then
      if checkbox("Keep stacked layers together", "stack") then memo_sig = nil end
      tooltip("On: each shot uses every layer (the selected items stacked across tracks).\n" ..
        "Off: every shot in every item is a separate building block.")
    end
    if show_switch then draw_view_switch() end
    if #items > 1 then
      local function item_text(i)
        local a = analysis.per[i]
        local e = items[i]
        if not a or not e then return "" end
        return ("%d. %s  [%s]"):format(i, e.name, a.err or (#a.shots .. " shots"))
      end
      label("Preview")
      ImGui.SetNextItemWidth(ctx, math.max(100, W - LABEL_X))
      if ImGui.BeginCombo(ctx, "##preview", item_text(preview_idx)) then
        for i = 1, #items do
          if ImGui.Selectable(ctx, item_text(i) .. "##" .. i, i == preview_idx) then preview_idx = i end
        end
        ImGui.EndCombo(ctx)
      end
    end
    local a = analysis.per[preview_idx]
    if a and a.env and items[preview_idx] then
      draw_source(items[preview_idx], a, analysis.stacked)
    else
      ImGui.Text(ctx, a and a.err and ("Can't analyse this item (" .. a.err .. ")") or "")
      ImGui.Dummy(ctx, W, 100)
    end
  end

  -- Detection --------------------------------------------------------------------
  if ImGui.CollapsingHeader(ctx, "Shot detection", ImGui.TreeNodeFlags_DefaultOpen) then
    label("Attack jump")
    slider("##rise", "rise_db", 2, 30, "%.1f dB")
    tooltip("How sharply the level has to jump to count as a new shot.\nLower = more sensitive (finds more shots).")
    label("Ignore below")
    slider("##floor", "floor_db", -60, -3, "%.0f dB from peak")
    tooltip("Transients quieter than this (relative to the item's loudest point) are ignored.")
    label("Min time between")
    slider("##min", "min_ms", 5, 1000, "%.0f ms")
    tooltip("Two shots in the source can't be closer than this.")
    label("Pre-roll")
    slider("##pre", "preroll_ms", 0, 20, "%.1f ms")
    tooltip("Each shot starts this far before its transient so the attack stays intact.")
  end

  ImGui.SeparatorText(ctx, is_burst and "Burst" or "Full auto")
  local rv, v

  label("Rate of fire")
  rate_slider("##rpm", "rpm")
  ImGui.SameLine(ctx)
  checkbox("ms", "use_ms")
  tooltip("Show the rate as milliseconds between shots instead of rounds per minute.")

  if is_burst then
    label("Rounds per burst")
    ImGui.SetNextItemWidth(ctx, 240)
    rv, v = ImGui.SliderInt(ctx, "##rounds", opt.rounds, 1, MAX_ROUNDS)
    if rv then opt.rounds = math.floor(clamp(v, 1, MAX_ROUNDS)); sanitize(opt); mark_dirty() end
    tooltip("How many shots each burst fires (a 3-round burst = 3).")
    label("Bursts")
    ImGui.SetNextItemWidth(ctx, 240)
    local max_b = math.max(1, MAX_COUNT // opt.rounds)
    rv, v = ImGui.SliderInt(ctx, "##bursts", opt.bursts, 1, math.min(20, max_b))
    if rv then opt.bursts = math.floor(clamp(v, 1, max_b)); mark_dirty() end
    tooltip("How many bursts in a row (each one uses the next shots from the source).")
    ImGui.BeginDisabled(ctx, opt.bursts < 2)
    label("Pause between bursts")
    slider("##bgap", "burst_gap_ms", 50, 2000, "%.0f ms")
    tooltip("From the last round of one burst to the first round of the next.")
    ImGui.EndDisabled(ctx)
  else
    label("")
    checkbox("Ramp to##ramp", "ramp")
    tooltip("Change the rate across the sequence, e.g. a minigun spinning up\n(the rate moves from the first value to this one).")
    ImGui.SameLine(ctx)
    ImGui.BeginDisabled(ctx, not opt.ramp)
    rate_slider("##rpm_end", "rpm_end")
    ImGui.EndDisabled(ctx)

    label("Shots")
    ImGui.SetNextItemWidth(ctx, 240)
    rv, v = ImGui.SliderInt(ctx, "##count", opt.count, 1, 64)
    if rv then opt.count = math.floor(clamp(v, 1, MAX_COUNT)); mark_dirty() end
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 80)
    rv, v = ImGui.InputInt(ctx, "##count_in", opt.count, 1, 10)
    if rv then opt.count = math.floor(clamp(v, 1, MAX_COUNT)); mark_dirty() end
    tooltip(("Up to %d shots."):format(MAX_COUNT))
  end

  label("Order")
  combo("##order", "order", ORDERS)
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Reroll") then opt.seed = (opt.seed % 99999) + 1; mark_dirty() end
  tooltip("New random order and humanize values.")

  -- Gain -------------------------------------------------------------------------
  ImGui.Separator(ctx)
  gain_shapes(gains, is_burst and "Gain per round" or "Gain per shot")
  local labels = {}
  if is_burst then
    for k = 1, #gains do labels[k] = tostring(k) end
  else
    for k, sp in ipairs(plan) do labels[k] = sp.src.label end
  end
  local before = gains_text(gains)
  draw_gains(gains, labels, is_burst and "Round" or "Shot")
  if gains_text(gains) ~= before then mark_dirty() end

  -- Preview ----------------------------------------------------------------------
  ImGui.Text(ctx, #plan > 0 and ("Result: %d shots, %.2f s%s"):format(#plan, total,
    n_lanes > 1 and (", on %d tracks"):format(n_lanes) or "") or "Result")
  if analysis.stacked then
    -- one row per layer
    local rows = {}
    for _, sp in ipairs(plan) do
      for _, sl in ipairs(sp.src.slices) do
        rows[#rows + 1] = { t = sp.t + sl.off, len = math.max(0.001, math.min(sl.len, sp.len - sl.off)),
          gain = sp.gain, idx = sp.idx, lane = sl.layer, src = sp.src }
      end
    end
    draw_plan(rows, total, n_lanes)
  else
    draw_plan(plan, total, n_lanes)
  end

  -- Tails, tracks, humanize ---------------------------------------------------------
  if ImGui.CollapsingHeader(ctx, "Tails, tracks and humanize", ImGui.TreeNodeFlags_DefaultOpen) then
    label("Shot tails")
    if ImGui.RadioButton(ctx, "Ring out", not opt.choke) then opt.choke = false; mark_dirty() end
    tooltip("Every shot keeps its full length and overlaps the next ones.")
    ImGui.SameLine(ctx)
    if ImGui.RadioButton(ctx, "Cut at next shot", opt.choke) then opt.choke = true; mark_dirty() end
    tooltip("Each shot fades out as the next one starts (the last shot rings out).")

    label("Tracks")
    ImGui.BeginDisabled(ctx, analysis.stacked == true)
    combo("##lanes", "lanes", LANES)
    ImGui.EndDisabled(ctx)
    if analysis.stacked then tooltip("Stacked layers: each layer goes on its own track, like the source.") end
    tooltip("Where the shots go. Spread over several tracks (in a folder under the\n" ..
      "build track) so overlapping tails don't hide each other.\n" ..
      "Auto uses just enough tracks that no two shots overlap.")

    label("Fade in / out")
    ImGui.SetNextItemWidth(ctx, 115)
    rv, v = ImGui.InputDouble(ctx, "##fin", opt.fadein_ms, 0, 0, "%.1f ms")
    if rv then opt.fadein_ms = clamp(v, 0, 5000); mark_dirty() end
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 115)
    rv, v = ImGui.InputDouble(ctx, "##fout", opt.fadeout_ms, 0, 0, "%.1f ms")
    if rv then opt.fadeout_ms = clamp(v, 0, 5000); mark_dirty() end

    label("Humanize timing")
    slider("##jms", "jit_ms", 0, 20, "+/- %.1f ms")
    label("Humanize gain")
    slider("##jdb", "jit_db", 0, 6, "+/- %.1f dB")
    label("Humanize pitch")
    slider("##jct", "jit_cents", 0, 200, "+/- %.0f cents")

    checkbox(is_burst and "Add a region around the bursts" or "Add a region around the sequence", "region")
  end

  -- Build ------------------------------------------------------------------------
  ImGui.Separator(ctx)
  local busy = ImGui.IsAnyItemActive(ctx) or ImGui.IsMouseDown(ctx, ImGui.MouseButton_Left)
  local cur_sig = burst_sig()
  local src_track = items[1] and items[1].track
  local src_name = items[1] and items[1].name:gsub("%.[%w]+$", "") or "Gun"

  if opt.live and burst and #plan > 0 and not busy and cur_sig ~= built_sig then
    local o, target = opt, burst
    later(function()
      if burst ~= target then return end -- let go of in the meantime
      local b = build(pool, o, gains, target, src_track, src_name)
      if b then
        burst = b
        built_sig = cur_sig
        store_burst(burst, o, gains, excluded)
        status = "Updated. Ctrl+Z to undo."
        last_state = nil
      end
    end)
  end

  local what = is_burst and "burst" or "sequence"
  ImGui.BeginDisabled(ctx, #plan == 0)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 8)
  if ImGui.Button(ctx, (burst and "Build new " or "Build ") .. what, 170, ImGui.GetFrameHeight(ctx) * 1.3) then
    local o, list = opt, items
    later(function()
      local guids = {}
      for i, e in ipairs(list) do guids[i] = e.guid end
      local b, n = build(pool, o, gains, { sources = guids, missing = true }, src_track, src_name)
      if b and n and n > 0 then
        burst = b
        built_sig = cur_sig
        store_burst(burst, o, gains, excluded)
        mark_dirty()
        status = ("Built %d shots at the edit cursor."):format(n)
        last_state = nil
      else
        status = "Couldn't build: the source track is gone. Select the source again."
      end
    end)
  end
  ImGui.PopStyleVar(ctx)
  tooltip("Builds at the edit cursor on a track below the source.")
  ImGui.EndDisabled(ctx)
  ImGui.SameLine(ctx)
  checkbox("Live update", "live")
  tooltip("Rebuild the last build every time you change a setting\n" ..
    "(loop playback over it to hear changes as you make them).\n" ..
    "Click any build in the arrange view to edit it again.")
  if burst and opt.live then
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Let go") then let_go("Kept as it is: changes no longer touch it.") end
    tooltip("Stop updating the last build, so changes no longer touch it.")
  end
  ImGui.TextWrapped(ctx, status)
end

----------------------------------------------------------------------
-- PRESETS (named setups, the same in every project)
----------------------------------------------------------------------
local function apply_setup(src)
  local tab = tab_now()
  for k in pairs(DEFAULTS) do
    if not UI_KEYS[k] then opt[k] = src.s[k] end
  end
  sanitize(opt)
  tab.gains = copy_gains(src.gains)
  let_go("Preset loaded. Build makes a new one.")
  memo_sig, last_state = nil, nil
  mark_dirty()
end

local function presets_popup()
  if ImGui.BeginPopup(ctx, "presets") then
    ImGui.Text(ctx, "Load into this tab")
    local names = {}
    for n in pairs(presets) do names[#names + 1] = n end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    if #names == 0 then ImGui.TextDisabled(ctx, "  (no presets yet)") end
    for _, n in ipairs(names) do
      if ImGui.Selectable(ctx, "  " .. n .. "##p_" .. n, false) then
        apply_setup(presets[n]); preset_name = n
      end
    end
    ImGui.Separator(ctx)
    ImGui.SetNextItemWidth(ctx, 180)
    local _, v = ImGui.InputTextWithHint(ctx, "##pname", "preset name", preset_name)
    preset_name = v:gsub("[\r\n|;]", " ")
    local name = preset_name:match("^%s*(.-)%s*$")
    ImGui.SameLine(ctx)
    ImGui.BeginDisabled(ctx, name == "")
    if ImGui.Button(ctx, presets[name] and "Overwrite" or "Save") then
      local tab = tab_now()
      presets[name] = { name = name, s = copy_settings(opt), gains = copy_gains(tab.gains) }
      save_presets(presets)
    end
    ImGui.EndDisabled(ctx)
    ImGui.SameLine(ctx)
    ImGui.BeginDisabled(ctx, not presets[name])
    if ImGui.Button(ctx, "Delete") then
      presets[name] = nil
      save_presets(presets)
    end
    ImGui.EndDisabled(ctx)
    ImGui.EndPopup(ctx)
  end
end

----------------------------------------------------------------------
-- TABS (each one a whole setup). Click to switch, + adds a copy, double-click renames,
-- right-click for color, name, close and order.
----------------------------------------------------------------------
-- Tab bar state: TS.select_pending = ImGui still has to show tabs.active (first frame, after a
-- switch); rename/close/edit = the tab a popup is open for.
local TS = { select_pending = true, rename = nil, close = nil, open_rename = false, open_close = false,
  edit = nil, edit_text = "", open_edit = false }

local function imgui_const(...)
  for _, name in ipairs({ ... }) do
    local ok, v = pcall(function() return ImGui[name] end)
    if ok and type(v) == "number" then return v end
  end
end
local TAB_COLS = {
  { imgui_const("Col_Tab"), 0xA0 },
  { imgui_const("Col_TabHovered"), 0xE0 },
  { imgui_const("Col_TabSelected", "Col_TabActive"), 0xFF },
  { imgui_const("Col_TabDimmed", "Col_TabUnfocused"), 0x80 },
  { imgui_const("Col_TabDimmedSelected", "Col_TabUnfocusedActive"), 0xD0 },
}
local function push_tab_color(rgb)
  if not rgb then return 0 end
  local n = 0
  for _, c in ipairs(TAB_COLS) do
    if c[1] then ImGui.PushStyleColor(ctx, c[1], (rgb << 8) | c[2]); n = n + 1 end
  end
  local lum = (0.299 * ((rgb >> 16) & 0xFF) + 0.587 * ((rgb >> 8) & 0xFF) + 0.114 * (rgb & 0xFF)) / 255
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, lum > 0.62 and 0x111111FF or 0xFFFFFFFF)
  return n + 1
end
local function default_tab_rgb()
  local c = TAB_COLS[3][1] and ImGui.GetStyleColor(ctx, TAB_COLS[3][1])
  return c and (c >> 8) & 0xFFFFFF or 0x3A6EA5
end

local function show_tab(i)
  if not tabs.list[i] then return end
  tabs.active = i
  local keep_live, keep_ms = opt.live, opt.use_ms -- window preferences stay as they are
  opt = tabs.list[i].s
  opt.live, opt.use_ms = keep_live, keep_ms
  TS.select_pending = true
  let_go("Switched to \"" .. tabs.list[i].name .. "\". Build makes a new one.")
  memo_sig, last_state = nil, nil
  mark_dirty()
end

local function new_tab_name(base)
  local used = {}
  for _, t in ipairs(tabs.list) do used[t.name:lower()] = true end
  if base and not used[base:lower()] then return base end
  local n = base and 2 or #tabs.list + 1
  local function name(k) return base and (base .. " " .. k) or ("Tab " .. k) end
  while used[name(n):lower()] do n = n + 1 end
  return name(n)
end

local function add_tab(from, at, name)
  local src = tabs.list[from]
  local tab = { id = tabs.next_id, name = name, color = src.color, s = copy_settings(src.s), gains = copy_gains(src.gains) }
  tabs.next_id = tabs.next_id + 1
  table.insert(tabs.list, at, tab)
  if at <= tabs.active then tabs.active = tabs.active + 1 end
  show_tab(at)
end

local function close_tab(i)
  if #tabs.list < 2 or not tabs.list[i] then return end
  table.remove(tabs.list, i)
  if i == tabs.active then
    show_tab(math.min(i, #tabs.list))
  else
    if i < tabs.active then tabs.active = tabs.active - 1 end
    TS.select_pending = true
    mark_dirty()
  end
end

local function move_tab(i, d)
  local j = i + d
  if not tabs.list[i] or not tabs.list[j] then return end
  tabs.list[i], tabs.list[j] = tabs.list[j], tabs.list[i]
  if tabs.active == i then tabs.active = j elseif tabs.active == j then tabs.active = i end
  -- ImGui keeps a tab bar's order once tabs exist; new ids make it lay them out in our order.
  for _, k in ipairs({ i, j }) do tabs.list[k].id = tabs.next_id; tabs.next_id = tabs.next_id + 1 end
  TS.select_pending = true
  mark_dirty()
end

local function section_tabs()
  local action
  if ImGui.BeginTabBar(ctx, "setups", ImGui.TabBarFlags_FittingPolicyScroll) then
    local can_close = #tabs.list > 1
    for i, tab in ipairs(tabs.list) do
      local flags = (TS.select_pending and i == tabs.active) and ImGui.TabItemFlags_SetSelected or ImGui.TabItemFlags_None
      local lbl = tab.name .. "###tab" .. tab.id
      local sel, keep
      local pushed = push_tab_color(tab.color)
      if can_close then sel, keep = ImGui.BeginTabItem(ctx, lbl, true, flags)
      else sel = ImGui.BeginTabItem(ctx, lbl, nil, flags) end
      if pushed > 0 then ImGui.PopStyleColor(ctx, pushed) end
      if can_close and keep == false then action = { "close", i } end
      if ImGui.IsItemHovered(ctx) then
        if ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then action = { "rename", i }
        elseif can_close and ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Middle) then action = { "close", i } end
      end
      if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) then action = { "edit", i } end
      if sel then
        -- While a switch is pending ImGui may still report the old tab for a frame: ignore it.
        if i == tabs.active then TS.select_pending = false
        elseif not TS.select_pending then action = action or { "show", i } end
        ImGui.EndTabItem(ctx)
      end
    end
    if ImGui.TabItemButton(ctx, "+", ImGui.TabItemFlags_Trailing | ImGui.TabItemFlags_NoTooltip) then action = { "add" } end
    tooltip("New tab, starting as a copy of this one.\nEach tab keeps its own mode and settings.\n" ..
      "Double-click a tab to rename it, right-click for its color, name and order.")
    ImGui.EndTabBar(ctx)
  end

  if action then
    local a, i = action[1], action[2]
    if a == "show" then show_tab(i)
    elseif a == "add" then add_tab(tabs.active, #tabs.list + 1, new_tab_name())
    elseif a == "rename" then TS.rename = { i = i, text = tabs.list[i].name }; TS.open_rename = true
    elseif a == "close" then TS.close = i; TS.open_close = true
    elseif a == "edit" then TS.edit, TS.edit_text = tabs.list[i], tabs.list[i].name; TS.open_edit = true end
  end

  if TS.open_edit then ImGui.OpenPopup(ctx, "tabedit"); TS.open_edit = false end
  if ImGui.BeginPopup(ctx, "tabedit") then
    local i
    for k, t in ipairs(tabs.list) do if t == TS.edit then i = k end end
    if not i then ImGui.CloseCurrentPopup(ctx)
    else
      local tab = TS.edit
      local ch, rgb = ImGui.ColorEdit3(ctx, "##tabcolor", tab.color or default_tab_rgb(),
        ImGui.ColorEditFlags_NoInputs | ImGui.ColorEditFlags_NoAlpha)
      if ch then tab.color = rgb; mark_dirty() end
      tooltip("Tab color")
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, 200)
      if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
      ch, TS.edit_text = ImGui.InputText(ctx, "##tabeditname", TS.edit_text)
      local enter = ImGui.IsItemDeactivatedAfterEdit(ctx) and ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)
      if ch then
        local name = TS.edit_text:gsub("[\r\n|;]", " "):match("^%s*(.-)%s*$")
        if name ~= "" then tab.name = name; mark_dirty() end
      end
      ImGui.SameLine(ctx)
      local can_close = #tabs.list > 1
      ImGui.BeginDisabled(ctx, not can_close)
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x9A2A30FF)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0xC0383FFF)
      if ImGui.Button(ctx, "Close tab") then
        TS.close = i; TS.open_close = true; ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.PopStyleColor(ctx, 2)
      ImGui.EndDisabled(ctx)
      ImGui.BeginDisabled(ctx, not tab.color)
      if ImGui.Button(ctx, "Reset color") then tab.color = nil; mark_dirty() end
      ImGui.EndDisabled(ctx)
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Duplicate") then
        add_tab(i, i + 1, new_tab_name(tab.name .. " copy")); ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      ImGui.TextColored(ctx, C.COLOR_DIM, "Tab order:")
      ImGui.SameLine(ctx)
      ImGui.BeginDisabled(ctx, i == 1)
      if ImGui.ArrowButton(ctx, "##tableft", ImGui.Dir_Left) then move_tab(i, -1) end
      ImGui.EndDisabled(ctx)
      ImGui.SameLine(ctx)
      ImGui.BeginDisabled(ctx, i == #tabs.list)
      if ImGui.ArrowButton(ctx, "##tabright", ImGui.Dir_Right) then move_tab(i, 1) end
      ImGui.EndDisabled(ctx)
      if enter then ImGui.CloseCurrentPopup(ctx) end
    end
    ImGui.EndPopup(ctx)
  end

  if TS.open_rename then ImGui.OpenPopup(ctx, "Rename tab"); TS.open_rename = false end
  if ImGui.BeginPopup(ctx, "Rename tab") then
    if not TS.rename or not tabs.list[TS.rename.i] then ImGui.CloseCurrentPopup(ctx)
    else
      if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
      ImGui.SetNextItemWidth(ctx, 220)
      local enter
      enter, TS.rename.text = ImGui.InputText(ctx, "##tabname", TS.rename.text, ImGui.InputTextFlags_EnterReturnsTrue)
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "OK") or enter then
        local name = TS.rename.text:gsub("[\r\n|;]", " "):match("^%s*(.-)%s*$")
        if name ~= "" then tabs.list[TS.rename.i].name = name; mark_dirty() end
        TS.rename = nil
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    ImGui.EndPopup(ctx)
  end

  if TS.open_close then ImGui.OpenPopup(ctx, "Close tab?"); TS.open_close = false end
  if ImGui.BeginPopupModal(ctx, "Close tab?", nil, ImGui.WindowFlags_AlwaysAutoResize) then
    local tab = TS.close and tabs.list[TS.close]
    if not tab then ImGui.CloseCurrentPopup(ctx)
    else
      ImGui.Text(ctx, "Close \"" .. tab.name .. "\"?")
      ImGui.TextColored(ctx, C.COLOR_DIM, "Its settings go with it. Save them as a preset first to keep them.")
      if ImGui.Button(ctx, "Close tab", 120) or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) then
        close_tab(TS.close); TS.close = nil; ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Cancel", 120) or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
        TS.close = nil; ImGui.CloseCurrentPopup(ctx)
      end
    end
    ImGui.EndPopup(ctx)
  end
end

----------------------------------------------------------------------
-- MODE BUTTONS
----------------------------------------------------------------------
local function section_modes()
  local avail = ImGui.GetContentRegionAvail(ctx)
  local sp = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
  local pad = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  local pw = ImGui.CalcTextSize(ctx, "Presets...") + pad * 2 + 8
  local bw = math.max(60, math.floor((avail - pw - sp * 3) / 3))
  local bh = math.floor(ImGui.GetFrameHeight(ctx) * 1.6 + 0.5)
  local pick
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 8)
  for i, name in ipairs(MODES) do
    if i > 1 then ImGui.SameLine(ctx) end
    local on = opt.mode == i
    if on then
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, C.COL_ACCENT)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, C.COL_ACCENT)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, C.COL_ACCENT)
    end
    if ImGui.Button(ctx, name .. "##mode" .. i, bw, bh) then pick = i end
    if on then ImGui.PopStyleColor(ctx, 3) end
    tooltip(MODE_TIPS[i])
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Presets...", pw, bh) then ImGui.OpenPopup(ctx, "presets") end
  tooltip("Save this tab's setup as a named preset, or load one into it.\nPresets are the same in every project.")
  ImGui.PopStyleVar(ctx)
  presets_popup()
  if pick then set_mode(pick) end
end

----------------------------------------------------------------------
-- WINDOW (rounded corners, big close button in the top-right corner)
----------------------------------------------------------------------
local WINDOW_ROUNDING = 10
local ANY_POPUP = imgui_const("PopupFlags_AnyPopup") or
  ((imgui_const("PopupFlags_AnyPopupId") or 0) | (imgui_const("PopupFlags_AnyPopupLevel") or 0))
local close_clicked = false
local main_win_docked = false

local function close_size() return math.floor(ImGui.GetFontSize(ctx) * 2 + 0.5) end
local function close_margin() return math.floor(ImGui.GetFontSize(ctx) * 0.5 + 0.5) end
local function title_bar_size() return close_size() + close_margin() * 2 end

-- Rounded square with an X: dark gray normally, red on hover, darker red while pressed.
local function close_button(id, size)
  local pressed = ImGui.InvisibleButton(ctx, id, size, size)
  local hovered, held = ImGui.IsItemHovered(ctx), ImGui.IsItemActive(ctx)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local bg = held and 0xB8323AFF or (hovered and 0xE04048FF or 0x2A2A2AFF)
  local fg = hovered and 0xFFFFFFFF or ImGui.GetColor(ctx, ImGui.Col_Text)
  ImGui.DrawList_AddRectFilled(dl, x1, y1, x1 + size, y1 + size, bg, size * 0.22)
  local m, th = size * 0.30, math.max(2, size * 0.08)
  ImGui.DrawList_AddLine(dl, x1 + m, y1 + m, x1 + size - m, y1 + size - m, fg, th)
  ImGui.DrawList_AddLine(dl, x1 + size - m, y1 + m, x1 + m, y1 + size - m, fg, th)
  return pressed
end

-- Drawn last, over the (taller) title bar. The cursor is not moved back afterwards: ImGui
-- errors in End() when the cursor is moved past the content without an item after it.
local function title_close_button()
  local size, m = close_size(), close_margin()
  local wx, wy = ImGui.GetWindowPos(ctx)
  local ww = ImGui.GetWindowSize(ctx)
  ImGui.PushClipRect(ctx, wx, wy, wx + ww, wy + title_bar_size(), false)
  ImGui.SetCursorScreenPos(ctx, wx + ww - size - m, wy + m)
  if close_button("##closewin", size) then close_clicked = true end
  tooltip("Close Gun Builder")
  ImGui.PopClipRect(ctx)
end

-- Follow REAPER's project tabs: each project keeps its own Gun Builder tabs.
local cur_proj = r.EnumProjects(-1)
local function follow_project_tab()
  local proj = r.EnumProjects(-1)
  if proj == cur_proj then return end
  if cur_proj and r.ValidatePtr(cur_proj, "ReaProject*") then save_all(cur_proj) end
  cur_proj = proj
  local keep_live, keep_ms = opt.live, opt.use_ms
  tabs = load_tabs()
  opt = tabs.list[tabs.active].s
  opt.live, opt.use_ms = keep_live, keep_ms
  burst, seq, built_sig = nil, nil, nil
  items, sources, excluded, cache = {}, {}, {}, {}
  burst_track_guid, last_sel_key, force_view = nil, nil, nil
  last_state, last_mode, memo_sig = nil, nil, nil
  TS.select_pending = true
  dirty_tabs = false
  status = ""
end

local function frame()
  follow_project_tab()
  refresh()

  ImGui.SetNextWindowSize(ctx, 640, 860, ImGui.Cond_FirstUseEver)
  ImGui.SetNextWindowSizeConstraints(ctx, 520, 320, 4000, 4000)
  ImGui.SetNextWindowCollapsed(ctx, false, ImGui.Cond_Always)
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, 0x141414FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg, 0x0F0F0FFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive, 0x0F0F0FFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgCollapsed, 0x0F0F0FFF)
  local pad_x, pad_y = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  local title_pad = (title_bar_size() - ImGui.GetFontSize(ctx)) / 2
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, pad_x, math.max(pad_y, title_pad))
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding, WINDOW_ROUNDING)
  -- No p_open when floating: ImGui's small X is replaced by the big one. Docked windows have
  -- no title bar, so they get ImGui's normal X on the dock tab.
  local visible, open = ImGui.Begin(ctx, TITLE, main_win_docked and true or nil, ImGui.WindowFlags_NoCollapse)
  ImGui.PopStyleVar(ctx, 2)
  if open == nil then open = true end
  if visible then
    main_win_docked = ImGui.IsWindowDocked(ctx)
    section_tabs()
    section_modes()
    ImGui.Spacing(ctx)
    if ImGui.BeginChild(ctx, "body", 0, 0) then
      W = math.max(360, math.floor(ImGui.GetContentRegionAvail(ctx) - 4))
      if opt.mode == 1 then
        draw_single()
      elseif view == "seq" and seq then
        draw_seq()
      else
        draw_build()
      end
      ImGui.EndChild(ctx)
    end
    if not main_win_docked then title_close_button() end
    -- Escape closes the window (not while typing or with a popup open).
    if ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows)
      and not ImGui.IsAnyItemActive(ctx)
      and not ImGui.IsPopupOpen(ctx, "", ANY_POPUP)
      and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape, false) then
      open = false
    end
    ImGui.End(ctx)
  end
  ImGui.PopStyleColor(ctx, 4)
  if pending then
    local fn = pending
    pending = nil
    fn()
  end
  if close_clicked then open = false end

  -- save the tabs a moment after the last change (not every frame while dragging)
  if dirty_tabs and r.time_precise() - dirty_at > 1 and not ImGui.IsMouseDown(ctx, ImGui.MouseButton_Left) then
    save_all()
  end
  return open
end

local stopped = false
local function loop()
  if stopped then return end
  local ok, res = xpcall(frame, debug.traceback)
  if not ok then
    stopped = true
    save_all()
    r.ShowConsoleMsg("\n" .. TITLE .. " stopped because of an error:\n" .. tostring(res) .. "\n")
    r.ShowMessageBox(TITLE .. " ran into an error and closed. Any change it was making was closed " ..
      "off as one undo step, so Ctrl+Z puts it back.\n\nThe details are in the ReaScript console " ..
      "window: copy them when reporting the problem.", TITLE, 0)
    return
  end
  if res then
    r.defer(loop)
  else
    stopped = true
    save_all()
  end
end

r.atexit(function()
  if not stopped then save_all() end
end)

resume_last()
r.defer(loop)
