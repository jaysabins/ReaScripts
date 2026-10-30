-- @description JS Loudness Analyzer (selected items)
-- @author Jay Sabins
-- @version 1.0.0
-- @changelog Initial public release
-- @about Measures LUFS, true peak and RMS of selected items without modifying the project. Prints to the console and optionally writes a CSV. Requires SWS.

-------------------------------------------------------------------------------
-- JS Loudness Analyzer (Selected Items) v1.0
-------------------------------------------------------------------------------
-- By: Jay Sabins

--INSTRUCTIONS--
-- Select one or more audio items in REAPER and run the script.
-- Results are printed to the ReaScript console and (optionally) written to a CSV.
-- The project is not modified: nothing is imported, moved or deleted.
--
-- CSV location:
--   Saved project   -> <project folder>\Data\
--   Unsaved project -> <REAPER resource folder>\Data\Loudness\
-- The folder is created automatically if it doesn't exist.

--DEPENDENCIES--
-- SWS/S&M Extension: https://www.sws-extension.org/

------------------------------------------------------------------------------------------------
--USER SETTINGS--

ANALYZE_LOUDNESS   = true   -- LUFS-I, LUFS-S max, LUFS-M max, LRA
ANALYZE_TRUE_PEAK  = true   -- True peak (dBTP). Slightly slower.
ANALYZE_RMS        = true   -- Average RMS (dB)

PRINT_TO_CONSOLE   = true   -- Show a results table in the ReaScript console
WRITE_CSV          = true   -- Save results to a CSV file
COPY_TO_CLIPBOARD  = false  -- Copy results (tab-separated) to the clipboard, ready to paste into a spreadsheet

------------------------------------------------------------------------------------------------

local SEP = package.config:sub(1, 1)

local function log(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

local function round(num, places)
  if type(num) ~= "number" then return "NO CALC" end
  local mult = 10 ^ (places or 0)
  return math.floor(num * mult + 0.5) / mult
end

-- SWS returns -150 (or lower) when a value can't be measured, e.g. silence
local function valid(v, places)
  if type(v) == "number" and v > -150 then return round(v, places) end
  return "NO CALC"
end

local function csv_field(v)
  v = tostring(v)
  if v:find('[,"\n]') then
    v = '"' .. (v:gsub('"', '""')) .. '"'
  end
  return v
end

local function basename(path)
  return path:match("([^\\/]+)$") or path
end

------------------------------------------------------------------------------------------------
-- ITEM INFO
------------------------------------------------------------------------------------------------

local function get_source_name(take)
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return "" end
  -- Section/reversed sources wrap the real file; walk up to the parent
  local parent = reaper.GetMediaSourceParent(src)
  while parent do
    src = parent
    parent = reaper.GetMediaSourceParent(src)
  end
  local fn = reaper.GetMediaSourceFileName(src, "")
  return fn ~= "" and basename(fn) or ""
end

local function analyze_item(item)
  local take = reaper.GetActiveTake(item)
  if not take then return nil, "empty item" end
  if reaper.TakeIsMIDI(take) then return nil, "MIDI item" end

  local tr = reaper.GetMediaItem_Track(item)
  local _, track_name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  if track_name == "" then
    track_name = "Track " .. math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
  end

  local r = {
    track    = track_name,
    take     = reaper.GetTakeName(take),
    source   = get_source_name(take),
    position = round(reaper.GetMediaItemInfo_Value(item, "D_POSITION"), 3),
    length   = round(reaper.GetMediaItemInfo_Value(item, "D_LENGTH"), 3),
    rms      = "NOT CALC",
    lufs_i   = "NOT CALC",
    lufs_s   = "NOT CALC",
    lufs_m   = "NOT CALC",
    lra      = "NOT CALC",
    tp       = "NOT CALC",
  }

  if ANALYZE_LOUDNESS or ANALYZE_TRUE_PEAK then
    local ok, i_, range, tp, _, s_, m_ = reaper.NF_AnalyzeTakeLoudness(take, ANALYZE_TRUE_PEAK)
    if ok then
      if ANALYZE_LOUDNESS then
        r.lufs_i = valid(i_, 2)
        r.lufs_s = valid(s_, 2)
        r.lufs_m = valid(m_, 2)
        r.lra    = (type(range) == "number" and i_ and i_ > -150) and round(range, 2) or "NO CALC"
      end
      if ANALYZE_TRUE_PEAK then r.tp = valid(tp, 2) end
    else
      if ANALYZE_LOUDNESS then r.lufs_i, r.lufs_s, r.lufs_m, r.lra = "NO CALC", "NO CALC", "NO CALC", "NO CALC" end
      if ANALYZE_TRUE_PEAK then r.tp = "NO CALC" end
    end
  end

  if ANALYZE_RMS then
    r.rms = valid(reaper.NF_GetMediaItemAverageRMS(item), 2)
  end

  return r
end

------------------------------------------------------------------------------------------------
-- OUTPUT
------------------------------------------------------------------------------------------------

local COLUMNS = {
  { key = "track",    title = "Track"       },
  { key = "take",     title = "Take"        },
  { key = "source",   title = "Source File" },
  { key = "position", title = "Position (s)"},
  { key = "length",   title = "Length (s)"  },
  { key = "lufs_i",   title = "LUFS-I"      },
  { key = "lufs_s",   title = "LUFS-S Max"  },
  { key = "lufs_m",   title = "LUFS-M Max"  },
  { key = "lra",      title = "LRA"         },
  { key = "tp",       title = "True Peak"   },
  { key = "rms",      title = "RMS"         },
}

local function print_table(results)
  -- Work out column widths (cap long names so the table stays readable)
  local MAX_W = 32
  local widths = {}
  for c, col in ipairs(COLUMNS) do
    local w = #col.title
    for _, r in ipairs(results) do w = math.max(w, #tostring(r[col.key])) end
    widths[c] = math.min(w, MAX_W)
  end

  local function fmt_row(get)
    local parts = {}
    for c, col in ipairs(COLUMNS) do
      local v = tostring(get(col))
      if #v > widths[c] then v = v:sub(1, widths[c] - 1) .. "~" end
      parts[c] = v .. string.rep(" ", widths[c] - #v)
    end
    return table.concat(parts, "  ")
  end

  log(fmt_row(function(col) return col.title end))
  local rule = {}
  for c = 1, #COLUMNS do rule[c] = string.rep("-", widths[c]) end
  log(table.concat(rule, "  "))
  for _, r in ipairs(results) do
    log(fmt_row(function(col) return r[col.key] end))
  end
end

local function get_output_dir()
  local _, proj_path = reaper.EnumProjects(-1)
  local folder = proj_path and proj_path:match("^(.*)[\\/][^\\/]+$")
  if folder and folder ~= "" then
    return folder .. SEP .. "Data", true
  end
  return reaper.GetResourcePath() .. SEP .. "Data" .. SEP .. "Loudness", false
end

local function get_project_name()
  local _, proj_path = reaper.EnumProjects(-1)
  local name = proj_path and proj_path:match("([^\\/]+)%.[Rr][Pp][Pp]$")
  return name or "Unsaved Project"
end

local function write_csv(results)
  local dir, is_project = get_output_dir()
  reaper.RecursiveCreateDirectory(dir, 0)

  local stamp = os.date("%Y-%m-%d_%I%M %S %p")
  local path  = dir .. SEP .. stamp .. " " .. get_project_name() .. " Selected Loudness.csv"

  local f, err = io.open(path, "w")
  if not f then
    log("Error: Could not write CSV: " .. tostring(err))
    return nil
  end

  local header = {}
  for c, col in ipairs(COLUMNS) do header[c] = csv_field(col.title) end
  header[#header + 1] = "Date"
  header[#header + 1] = "Time"
  f:write(table.concat(header, ",") .. "\n")

  local date, time = os.date("%x"), os.date("%H:%M:%S")
  for _, r in ipairs(results) do
    local row = {}
    for c, col in ipairs(COLUMNS) do row[c] = csv_field(r[col.key]) end
    row[#row + 1] = date
    row[#row + 1] = time
    f:write(table.concat(row, ",") .. "\n")
  end
  f:close()

  if not is_project then
    log("(Project isn't saved, so the CSV went to REAPER's resource folder.)")
  end
  return path
end

local function copy_to_clipboard(results)
  if not reaper.CF_SetClipboard then
    log("Clipboard copy needs a newer SWS version. Skipped.")
    return
  end
  local lines, header = {}, {}
  for c, col in ipairs(COLUMNS) do header[c] = col.title end
  lines[1] = table.concat(header, "\t")
  for _, r in ipairs(results) do
    local row = {}
    for c, col in ipairs(COLUMNS) do row[c] = tostring(r[col.key]) end
    lines[#lines + 1] = table.concat(row, "\t")
  end
  reaper.CF_SetClipboard(table.concat(lines, "\n"))
  log("Results copied to clipboard.")
end

------------------------------------------------------------------------------------------------
-- MAIN
------------------------------------------------------------------------------------------------

local function main()
  if not reaper.NF_AnalyzeTakeLoudness then
    reaper.MB("This script needs the SWS extension.\nhttps://www.sws-extension.org/", "JS Loudness Analyzer", 0)
    return
  end

  local count = reaper.CountSelectedMediaItems(0)
  if count == 0 then
    reaper.MB("Select one or more audio items first.", "JS Loudness Analyzer", 0)
    return
  end

  reaper.ClearConsole()
  local start = os.clock()

  local results, skipped = {}, 0
  for i = 0, count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local r, why = analyze_item(item)
    if r then
      results[#results + 1] = r
    else
      skipped = skipped + 1
      log(string.format("Skipped item %d (%s)", i + 1, why))
    end
  end

  if #results == 0 then
    log("No audio items to analyze.")
    return
  end

  if PRINT_TO_CONSOLE then
    print_table(results)
    log("")
  end

  if WRITE_CSV then
    local path = write_csv(results)
    if path then log("CSV: " .. path) end
  end

  if COPY_TO_CLIPBOARD then copy_to_clipboard(results) end

  log(string.format("Analyzed %d item(s)%s in %.2f sec.",
    #results, skipped > 0 and (", skipped " .. skipped) or "", os.clock() - start))
end

main()
