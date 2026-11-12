-- @description Spread rapid-fire shots out along the timeline (groups stacked layers into shots)
-- @author Jay Sabins
-- @version 2.0.0
-- @changelog
--   Reworked to match how rapid-fire sessions are actually built: no more splitting.
--   Each shot is already its own set of files stacked across the layer tracks, so the
--   script now groups the selected items into shots by start time (items that start
--   together are one shot) and spaces those shots out along the timeline with a gap,
--   keeping the timing between layers inside each shot exactly as it was.
--   Before/after preview in the window, optional region per shot, later items on the
--   tracks move out of the way.
-- @about
--   Select every item of a rapid-fire sequence (all layers, all shots) and run the script.
--
--   Items that start at (nearly) the same time are treated as one shot: those are the
--   layers stacked vertically on the different tracks. The script finds each shot, then
--   moves the shots apart so each one has its own spot on the timeline, with a gap you
--   choose between the end of one shot and the start of the next. The layers inside a
--   shot keep their exact offsets, and nothing is split, trimmed or faded.
--
--   "Same shot" tolerance: how far apart two items can start and still count as the
--   same shot. The window shows the shots it found, colored, before and after, so you
--   can see the grouping is right before you apply it.
--
--   Options: create a region per shot (ready for rendering), move later items on the
--   involved tracks out of the way. Fully undoable.
--
--   Requires ReaImGui (install it from ReaPack).

local r = reaper
local SECTION = "jsabins_SpreadShots"
local TITLE = "Spread Rapid-Fire Shots"

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

----------------------------------------------------------------------
-- SETTINGS (remembered between runs)
----------------------------------------------------------------------
local DEFAULTS = {
  tol_ms = 20,       -- items starting within this of a shot's first item belong to that shot
  gap = 0.5,         -- seconds between the end of one shot and the start of the next
  ripple = true,     -- move later items on the involved tracks out of the way
  regions = false,   -- add a region per shot
  prefix = "Shot",   -- region name prefix
}

local function load_settings()
  local s = {}
  for k, def in pairs(DEFAULTS) do
    s[k] = def
    if r.HasExtState(SECTION, k) then
      local v = r.GetExtState(SECTION, k)
      if type(def) == "boolean" then s[k] = v == "1"
      elseif type(def) == "number" then s[k] = tonumber(v) or def
      else s[k] = v end
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
-- GROUPING
----------------------------------------------------------------------
local function collect_items()
  local items = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    local tr = r.GetMediaItem_Track(it)
    local p = pos_of(it)
    items[#items + 1] = {
      item = it, track = tr, pos = p, len = len_of(it), stop = p + len_of(it),
      tidx = r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"),
    }
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
local function layout(shots, gap)
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

----------------------------------------------------------------------
-- APPLY
----------------------------------------------------------------------
local function apply(items, o)
  local shots = group_shots(items, o.tol_ms / 1000)
  if #shots == 0 then return 0 end
  local starts = layout(shots, o.gap)

  local sel_end = 0
  for _, s in ipairs(shots) do sel_end = math.max(sel_end, s.stop) end
  local last = shots[#shots]
  local new_end = starts[#shots] + (last.stop - last.start)
  local growth = new_end - sel_end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  -- later items on the same tracks, moved by how much longer the sequence got
  if o.ripple and growth > 0 then
    local in_sel, seen = {}, {}
    for _, e in ipairs(items) do in_sel[e.item] = true end
    for _, e in ipairs(items) do
      if not seen[e.track] then
        seen[e.track] = true
        for i = 0, r.CountTrackMediaItems(e.track) - 1 do
          local it = r.GetTrackMediaItem(e.track, i)
          if not in_sel[it] then
            local p = pos_of(it)
            if p >= sel_end - 1e-6 then r.SetMediaItemInfo_Value(it, "D_POSITION", p + growth) end
          end
        end
      end
    end
  end

  local digits = math.max(2, #tostring(#shots))
  for k, s in ipairs(shots) do
    local delta = starts[k] - s.start
    if delta ~= 0 then
      for _, e in ipairs(s.items) do
        r.SetMediaItemInfo_Value(e.item, "D_POSITION", e.pos + delta)
      end
    end
    if o.regions then
      local name = ("%s_%0" .. digits .. "d"):format(o.prefix ~= "" and o.prefix or "Shot", k)
      r.AddProjectMarker2(0, true, starts[k], starts[k] + (s.stop - s.start), name, -1, 0)
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(("Spread %d shots along the timeline"):format(#shots), -1)
  return #shots
end

----------------------------------------------------------------------
-- GUI
----------------------------------------------------------------------
local ctx = r.ImGui_CreateContext(TITLE)
local opt = load_settings()
local items, last_state = {}, nil
local status = ""

local PREVIEW_W, PREVIEW_H = 480, 110
local COL_BG = 0x1E1E1EFF
local COL_LANE = 0xFFFFFF08
local PALETTE = {
  0xE0605AFF, 0xE8A24AFF, 0xD9D35BFF, 0x7FCB6AFF, 0x4FBFB0FF,
  0x5A9BE0FF, 0x8A7AE0FF, 0xD27AD0FF,
}

local function refresh_items()
  local state = r.GetProjectStateChangeCount(0)
  if state == last_state then return end
  last_state = state
  items = collect_items()
end

local function label(text)
  r.ImGui_AlignTextToFramePadding(ctx)
  r.ImGui_Text(ctx, text)
  r.ImGui_SameLine(ctx, 170)
end

local function tooltip(text)
  if r.ImGui_IsItemHovered(ctx) then r.ImGui_SetTooltip(ctx, text) end
end

-- Draw the items as colored blocks, one lane per track. starts = new shot starts, or nil for "now".
local function draw_preview(id, shots, starts, t0, t1, lanes, nlanes)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local x0, y0 = r.ImGui_GetCursorScreenPos(ctx)
  local W, H = PREVIEW_W, PREVIEW_H
  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + W, y0 + H, COL_BG)
  local span = math.max(t1 - t0, 1e-6)
  local lane_h = H / math.max(1, nlanes)
  for i = 1, nlanes, 2 do
    r.ImGui_DrawList_AddRectFilled(dl, x0, y0 + (i - 1) * lane_h, x0 + W, y0 + i * lane_h, COL_LANE)
  end
  local function tx(t) return x0 + (t - t0) / span * W end
  local hovered_shot
  local mx, my = r.ImGui_GetMousePos(ctx)
  for k, s in ipairs(shots) do
    local delta = starts and (starts[k] - s.start) or 0
    local col = PALETTE[(k - 1) % #PALETTE + 1]
    for _, e in ipairs(s.items) do
      local lane = lanes[e.track]
      local ax, bx = tx(e.pos + delta), math.max(tx(e.pos + delta) + 2, tx(e.stop + delta))
      local ay = y0 + (lane - 1) * lane_h + 1
      local by = ay + math.max(2, lane_h - 2)
      r.ImGui_DrawList_AddRectFilled(dl, ax, ay, bx, by, (col & 0xFFFFFF00) | 0x90)
      r.ImGui_DrawList_AddLine(dl, ax, ay, ax, by, col, 2)
      if mx >= ax and mx <= bx and my >= ay and my <= by then hovered_shot = k end
    end
  end
  r.ImGui_InvisibleButton(ctx, id, W, H)
  if r.ImGui_IsItemHovered(ctx) and hovered_shot then
    local s = shots[hovered_shot]
    r.ImGui_SetTooltip(ctx, ("Shot %d: %d layer%s, %.0f ms long"):format(
      hovered_shot, #s.items, #s.items == 1 and "" or "s", (s.stop - s.start) * 1000))
  end
end

local function draw()
  refresh_items()
  local rv
  local shots = group_shots(items, opt.tol_ms / 1000)

  if #items == 0 then
    r.ImGui_TextWrapped(ctx,
      "Select every item of the rapid-fire sequence (all layers, all shots).\n" ..
      "Items that start together are one shot; the shots get spaced out along the timeline.")
    r.ImGui_Dummy(ctx, PREVIEW_W, 0)
  else
    local min_l, max_l = math.huge, 0
    for _, s in ipairs(shots) do
      min_l, max_l = math.min(min_l, #s.items), math.max(max_l, #s.items)
    end
    local layers = min_l == max_l and tostring(min_l) or ("%d-%d"):format(min_l, max_l)
    r.ImGui_Text(ctx, ("%d shots found, %s layer%s each (%d items)"):format(
      #shots, layers, max_l == 1 and "" or "s", #items))

    -- lanes = one per track, top to bottom
    local lanes, order = {}, {}
    for _, e in ipairs(items) do
      if not lanes[e.track] then lanes[e.track] = true; order[#order + 1] = e end
    end
    table.sort(order, function(a, b) return a.tidx < b.tidx end)
    for i, e in ipairs(order) do lanes[e.track] = i end

    local starts = layout(shots, opt.gap)
    local t0, now_end = math.huge, 0
    for _, s in ipairs(shots) do t0 = math.min(t0, s.start); now_end = math.max(now_end, s.stop) end
    local last = shots[#shots]
    local after_end = starts[#shots] + (last.stop - last.start)

    r.ImGui_Text(ctx, "Now")
    draw_preview("##now", shots, nil, t0, now_end, lanes, #order)
    r.ImGui_Text(ctx, ("After (%.2f s long)"):format(after_end - t0))
    draw_preview("##after", shots, starts, t0, after_end, lanes, #order)
  end

  r.ImGui_Separator(ctx)

  label("Same shot within")
  r.ImGui_SetNextItemWidth(ctx, 220)
  rv, opt.tol_ms = r.ImGui_SliderDouble(ctx, "##tol", opt.tol_ms, 1, 200, "%.0f ms")
  tooltip("Items that start within this much of a shot's first item belong to that shot.\n" ..
    "Keep it below the time between shots (600 RPM = 100 ms, 900 RPM = 67 ms).\n" ..
    "If two shots got merged, lower it; if one shot got split in two, raise it.")

  label("Gap (seconds)")
  r.ImGui_SetNextItemWidth(ctx, 120)
  rv, opt.gap = r.ImGui_InputDouble(ctx, "##gap", opt.gap, 0.1, 1.0, "%.2f")
  if opt.gap < 0 then opt.gap = 0 end
  tooltip("Space between the end of one shot (its longest layer) and the start of the next.")

  rv, opt.ripple = r.ImGui_Checkbox(ctx, "Move later items on these tracks out of the way", opt.ripple)
  rv, opt.regions = r.ImGui_Checkbox(ctx, "Create a region per shot", opt.regions)
  r.ImGui_BeginDisabled(ctx, not opt.regions)
  label("  Region name")
  r.ImGui_SetNextItemWidth(ctx, 180)
  rv, opt.prefix = r.ImGui_InputText(ctx, "##prefix", opt.prefix)
  r.ImGui_EndDisabled(ctx)

  r.ImGui_Separator(ctx)

  r.ImGui_BeginDisabled(ctx, #shots < 1)
  if r.ImGui_Button(ctx, ("Spread %d shots"):format(#shots), 200, 0) then
    save_settings(opt)
    local n = apply(items, opt)
    status = ("Spread %d shots. Ctrl+Z to undo."):format(n)
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
