-- @description JS Loudness Analyzer (language folders)
-- @author Jay Sabins
-- @version 1.1.0
-- @changelog Initial public release
-- @about Measures LUFS and RMS for every file in the project's _Raw language folders and writes a CSV to Data. Requires SWS.

-------------------------------------------------------------------------------
-- JS Loudness Analyzer v1.1
-------------------------------------------------------------------------------
-- Written by: Jay Sabins (based on a script by Daniel Petras)

--INSTRUCTIONS--
-- Save your REAPER project. Next to the .rpp, create a '_Raw' folder.
-- Inside '_Raw', make one folder per language. Each folder name must match a
-- track name in the session exactly (case-sensitive).
-- Run the script. Results are written to 'Data\<timestamp> <project> Loudness Data.csv'
-- (the 'Data' folder is created automatically if missing).
-- Progress and any problems are printed to the ReaScript console.

--DEPENDENCIES--
-- SWS/S&M Extension: https://www.sws-extension.org/

------------------------------------------------------------------------------------------------
--USER SETTINGS--

DISABLE_SCRIPT              = false
DELETE_ITEMS_AFTER_ANALYSIS = true   -- remove the imported items once measured
CLOSE_AFTER_PROCESS         = false  -- quit REAPER when finished
ANALYZE_RMS                 = true
ANALYZE_LOUDNESS            = true
VERBOSE                     = true   -- print what the script finds to the console

------------------------------------------------------------------------------------------------

local SEP = package.config:sub(1, 1)  -- "\" on Windows, "/" on macOS/Linux

local AUDIO_EXT = {
  wav = true, bwf = true, aif = true, aiff = true, flac = true,
  mp3 = true, ogg = true, opus = true, m4a = true, wv = true,
}

local function log(s)  reaper.ShowConsoleMsg(tostring(s) .. "\n") end
local function vlog(s) if VERBOSE then log(s) end end

local function round(num, places)
  if type(num) ~= "number" then return "NO CALC" end
  local mult = 10 ^ (places or 0)
  return math.floor(num * mult + 0.5) / mult
end

-- Quote CSV fields that contain commas, quotes or newlines
local function csv_field(v)
  v = tostring(v)
  if v:find('[,"\n]') then
    v = '"' .. (v:gsub('"', '""')) .. '"'
  end
  return v
end

------------------------------------------------------------------------------------------------
-- PROJECT / FILESYSTEM
------------------------------------------------------------------------------------------------

local function get_project_info()
  local _, proj_path = reaper.EnumProjects(-1)
  if not proj_path or proj_path == "" then
    return nil, "Project must be saved before running this script."
  end
  local folder, file = proj_path:match("^(.*[\\/])([^\\/]+)$")
  if not folder then
    return nil, "Couldn't parse project path: " .. proj_path
  end
  local name = file:gsub("%.[Rr][Pp][Pp]$", "")
  return { path = proj_path, folder = folder, name = name }
end

local function list_subdirs(path)
  local t, i = {}, 0
  while true do
    local n = reaper.EnumerateSubdirectories(path, i)
    if not n then break end
    t[#t + 1] = n
    i = i + 1
  end
  table.sort(t)
  return t
end

local function list_audio_files(path)
  local files, skipped, i = {}, {}, 0
  while true do
    local n = reaper.EnumerateFiles(path, i)
    if not n then break end
    local ext = (n:match("%.([^%.]+)$") or ""):lower()
    if AUDIO_EXT[ext] then
      files[#files + 1] = n
    else
      skipped[#skipped + 1] = n
    end
    i = i + 1
  end
  table.sort(files)
  return files, skipped
end

local function trim_lower(s)
  return (s:match("^%s*(.-)%s*$") or s):lower()
end

-- Returns the track whose name matches exactly, or nil plus a near-miss name to help debugging
local function find_track_by_name(name)
  local near
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, tn = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if tn == name then return tr end
    if trim_lower(tn) == trim_lower(name) then near = tn end
  end
  return nil, near
end

------------------------------------------------------------------------------------------------
-- ANALYSIS
------------------------------------------------------------------------------------------------

local function analyze_item(item)
  local rms, lufs_i, lufs_s, lufs_m = "NOT CALC", "NOT CALC", "NOT CALC", "NOT CALC"
  local take = reaper.GetActiveTake(item)

  if ANALYZE_LOUDNESS and take then
    local ok, i_, _, _, _, s_, m_ = reaper.NF_AnalyzeTakeLoudness(take, false)
    if ok then
      lufs_i = (i_ and i_ > -150) and round(i_, 2) or "NO CALC"
      lufs_s = (s_ and s_ > -150) and round(s_, 2) or "NO CALC"
      lufs_m = (m_ and m_ > -150) and round(m_, 3) or "NO CALC"
    else
      lufs_i, lufs_s, lufs_m = "NO CALC", "NO CALC", "NO CALC"
    end
  end

  if ANALYZE_RMS then
    local r = reaper.NF_GetMediaItemAverageRMS(item)
    rms = (r and r > -150) and round(r, 2) or "NO CALC"
  end

  return rms, lufs_i, lufs_s, lufs_m
end

-- Imports one file onto the given track and returns the new item (or nil)
local function import_file(full_path, tr)
  reaper.SelectAllMediaItems(0, false)
  reaper.SetOnlyTrackSelected(tr)
  reaper.Main_OnCommand(40914, 0) -- Track: Set first selected track as last touched track
  reaper.SetEditCurPos(0, false, false)

  reaper.InsertMedia(full_path, 0) -- 0 = add to current track

  local item = reaper.GetSelectedMediaItem(0, 0)
  if item and reaper.GetMediaItem_Track(item) ~= tr then
    reaper.MoveMediaItemToTrack(item, tr)
  end
  return item
end

------------------------------------------------------------------------------------------------
-- MAIN
------------------------------------------------------------------------------------------------

local function main()

  if not reaper.NF_AnalyzeTakeLoudness then
    log("Error: SWS extension not found. Install it from https://www.sws-extension.org/")
    return false
  end

  local proj, err = get_project_info()
  if not proj then log("Error: " .. err) return false end

  local raw_dir  = proj.folder .. "_Raw"
  local data_dir = proj.folder .. "Data"

  vlog("Project:    " .. proj.path)
  vlog("Raw folder: " .. raw_dir)

  local langs = list_subdirs(raw_dir)
  if #langs == 0 then
    log("Error: No language folders found in " .. raw_dir)
    log("Make sure '_Raw' sits next to your .rpp and contains one folder per language.")
    return false
  end
  vlog("Language folders found: " .. table.concat(langs, ", ") .. "\n")

  reaper.RecursiveCreateDirectory(data_dir, 0)

  local saved_cursor = reaper.GetCursorPosition()
  local rows, inserted = {}, {}

  for _, lang in ipairs(langs) do
    local tr, near = find_track_by_name(lang)

    if not tr then
      log(string.format("SKIPPED '%s': no track with that exact name%s",
        lang, near and (" (did you mean '" .. near .. "'?)") or ""))
    else
      local lang_dir = raw_dir .. SEP .. lang
      local files, skipped = list_audio_files(lang_dir)
      vlog(string.format("%s: %d audio file(s)%s", lang, #files,
        #skipped > 0 and (", ignored " .. #skipped .. " non-audio file(s)") or ""))

      for _, f in ipairs(files) do
        local item = import_file(lang_dir .. SEP .. f, tr)
        if not item then
          log("  FAILED to import: " .. f)
        else
          inserted[#inserted + 1] = item
          local rms, li, ls, lm = analyze_item(item)
          rows[#rows + 1] = table.concat({
            csv_field(lang), csv_field(f), rms, li, ls, lm,
            os.date("%x"), os.date("%H:%M:%S"),
          }, ",")
        end
      end
    end
  end

  if DELETE_ITEMS_AFTER_ANALYSIS then
    for _, item in ipairs(inserted) do
      if reaper.ValidatePtr(item, "MediaItem*") then
        reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(item), item)
      end
    end
  end

  reaper.SetEditCurPos(saved_cursor, false, false)

  -- Write CSV
  local stamp    = os.date("%Y-%m-%d_%I%M %S %p")
  local csv_path = data_dir .. SEP .. stamp .. " " .. proj.name .. " Loudness Data.csv"
  local f, ferr  = io.open(csv_path, "w")
  if not f then
    log("Error: Could not write CSV: " .. tostring(ferr))
    return false
  end

  f:write("Language,Filename,RMS,LUFS-I,LUFS-S,LUFS-M,Date,Time\n")
  for _, r in ipairs(rows) do f:write(r .. "\n") end
  f:close()

  log(string.format("\nDone. %d file(s) analyzed.\nCSV: %s", #rows, csv_path))
  if #rows == 0 then
    log("Warning: No rows were written. Check the SKIPPED / FAILED messages above.")
  end

  return true
end

------------------------------------------------------------------------------------------------

if not DISABLE_SCRIPT then
  reaper.ClearConsole()
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local ok = main()

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("JS Loudness Analyzer", -1)
  reaper.UpdateArrange()

  if ok and CLOSE_AFTER_PROCESS then
    reaper.Main_OnCommand(40004, 0) -- File: Quit REAPER
  end
end
