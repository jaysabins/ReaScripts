-- @description JS Folder Batch Processor
-- @author Jay Sabins, Daniel Petras
-- @version 2.0.0
-- @changelog Initial public release
-- @about Batch-renders multi-language VO from a structured project folder (_Raw to _Processed) with per-language overrides and CSV logging. Requires SWS and ReaImGui.

-------------------------------------------------------------------------------
-- JS FOLDER BATCH PROCESSOR v2.0
-------------------------------------------------------------------------------
-- Original by: Daniel Petras and Jay Sabins
-- Ported to ReaImGui with per-language overrides and progress tracking

--DEPENDENCIES--
-- SWS/S&M Extension: https://www.sws-extension.org/
-- ReaImGui: https://forum.cockos.com/showthread.php?t=250419

------------------------------------------------------------------------------------------------

--[[
INSTRUCTIONS:
  - Set up '_Raw', '_Processed', 'Data', 'Chains', and 'Docs' folders inside of Reaper project folder
  - Include language-named folders inside '_Raw' that match track names exactly
  - Use 'Script: mpl_Add FXChain to selected track (modified by JS 2).lua' to add FX Chains
  - Once Raw folder is populated and FX Chains added, run this script and click Batch!
]]

------------------------------------------------------------------------------------------------
-- HELPERS
------------------------------------------------------------------------------------------------

local function msg(var)
  reaper.ShowConsoleMsg(tostring(var) .. "\n")
end

------------------------------------------------------------------------------------------------
-- GLOBAL STATE
------------------------------------------------------------------------------------------------

local ctx = reaper.ImGui_CreateContext("JS Folder Batch v2.0")
local sans_serif = reaper.ImGui_CreateFont("sans-serif", 13)
reaper.ImGui_Attach(ctx, sans_serif)

-- Default render settings (globals, may be overridden per-lang)
local settings = {
  sr_idx       = 2,   -- 0=22050, 1=44100, 2=48000, 3=96000
  ch_idx       = 1,   -- 0=Mono, 1=Stereo
  fmt_idx      = 0,   -- 0=WAV, 1=MP3, 2=FLAC, 3=AIFF
  fadein_ms    = "0",
  fadeout_ms   = "0",
  fadein_shape = 0,
  fadeout_shape= 0,
  end_offset_ms= "0",
  tail_ms      = "0",
  delete_after = false,
}

local SR_VALUES   = {22050, 44100, 48000, 96000}
local SR_LABELS   = {"22050", "44100", "48000", "96000"}
local CH_VALUES   = {1, 2}
local CH_LABELS   = {"Mono", "Stereo"}
local FMT_VALUES  = {"evaw", "l3pm", "calf", "ffia"}
local FMT_LABELS  = {"WAV", "MP3", "FLAC", "AIFF"}
local SHAPE_LABELS= "Linear\0Equal Power -\0Equal Power +\0Equal Power - Steep\0Equal Power + Steep\0S-Curve Shallow\0S-Curve Steep\0"

-- Detected language folders
local lang_folders       = {}
-- Per-language override table: lang_overrides[lang] = { enabled=bool, settings={...} }
local lang_overrides     = {}

-- Progress state
local progress_active    = false
local progress_current   = 0
local progress_total     = 0
local progress_label     = ""
local batch_done         = false
local batch_done_msg     = ""

-- Window/tab state
local open               = true
local active_tab         = 0  -- 0=Global, 1=Languages, 2=Progress

-- Project vars
local PROJ_FILE          = ""
local PROJ_FOLDER        = ""
local _FILE_INFO         = {}
local _DATA_FILE_EXISTS  = false
local x_clock            = 0

------------------------------------------------------------------------------------------------
-- PROJECT / PATH HELPERS
------------------------------------------------------------------------------------------------

local function get_global_vars()
  _, PROJ_FILE = reaper.EnumProjects(-1)
  _FILE_INFO = {}
  _DATA_FILE_EXISTS = false
  PROJ_FOLDER = PROJ_FILE:match("(.*" .. "\\" .. ")")
end

local function scan_lang_folders()
  lang_folders = {}
  local raw_folder = PROJ_FOLDER .. "_Raw"
  local i = 0
  while true do
    local name = reaper.EnumerateSubdirectories(raw_folder, i)
    if name == nil then break end
    table.insert(lang_folders, name)
    -- init override entry if not present
    if not lang_overrides[name] then
      lang_overrides[name] = {
        enabled = false,
        settings = {
          sr_idx        = settings.sr_idx,
          ch_idx        = settings.ch_idx,
          fmt_idx       = settings.fmt_idx,
          fadein_ms     = settings.fadein_ms,
          fadeout_ms    = settings.fadeout_ms,
          fadein_shape  = settings.fadein_shape,
          fadeout_shape = settings.fadeout_shape,
          end_offset_ms = settings.end_offset_ms,
          tail_ms       = settings.tail_ms,
        }
      }
    end
    i = i + 1
  end
end

------------------------------------------------------------------------------------------------
-- RENDER SETTING CONVERSION
------------------------------------------------------------------------------------------------

local function resolve_settings(s)
  -- Returns computed values from a settings table
  local out = {}
  out.CHANNELS       = CH_VALUES[s.ch_idx + 1]
  out.SR             = SR_VALUES[s.sr_idx + 1]
  out.FORMAT         = FMT_VALUES[s.fmt_idx + 1]
  out.FADEIN_LENGTH  = (tonumber(s.fadein_ms)     or 0) / 1000
  out.FADEOUT_LENGTH = (tonumber(s.fadeout_ms)    or 0) / 1000
  out.FADEIN_SHAPE   = s.fadein_shape
  out.FADEOUT_SHAPE  = s.fadeout_shape
  out.END_MARKER_OFFSET = (tonumber(s.end_offset_ms) or 0) / 1000
  out.TAIL_LENGTH    = tonumber(s.tail_ms) or 0
  return out
end

local function set_render_info(r)
  reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "$item", true)
  reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", r.FORMAT, true)
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 64|512|1024, true)
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG ", 4, true)
  reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", r.CHANNELS, true)
  reaper.GetSetProjectInfo(0, "RENDER_SRATE", r.SR, true)
  reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 16, true)
  reaper.GetSetProjectInfo(0, "RENDER_TAILMS", r.TAIL_LENGTH, true)
  reaper.GetSetProjectInfo(0, "RENDER_FADEIN", r.FADEIN_LENGTH, true)
  reaper.GetSetProjectInfo(0, "RENDER_FADEOUT", r.FADEOUT_LENGTH, true)
  reaper.GetSetProjectInfo(0, "RENDER_FADEINSHAPE", r.FADEIN_SHAPE, true)
  reaper.GetSetProjectInfo(0, "RENDER_FADEOUTSHAPE", r.FADEOUT_SHAPE, true)
end

------------------------------------------------------------------------------------------------
-- DATA / CSV
------------------------------------------------------------------------------------------------

local function read_data_to_table()
  local _, filename = reaper.EnumProjects(-1)
  filename = filename:match("^.+\\(.+)%.rpp$")
  local date = os.date("%Y-%m-%d_%I%M %S %p ")
  local data_file = PROJ_FOLDER .. "Data\\" .. date .. filename .. " Proc Data.csv"
  local file = io.open(data_file, "r")
  if file ~= nil then
    _DATA_FILE_EXISTS = true
    for line in io.lines(data_file) do
      table.insert(_FILE_INFO, line)
    end
    file:close()
  end
end

local function save_data_to_table(lang, file_path, tr, r)
  local tr_notes = reaper.NF_GetSWSTrackNotes(tr)
  if tr_notes == "" then tr_notes = "None" end
  local row = table.concat({
    PROJ_FILE, lang, file_path, tr_notes,
    os.date("%x"), os.date("%H:%M:%S"),
    r.CHANNELS,
    r.FADEIN_LENGTH  * 1000, r.FADEIN_SHAPE,
    r.FADEOUT_LENGTH * 1000, r.FADEOUT_SHAPE,
    r.TAIL_LENGTH,
    r.END_MARKER_OFFSET * 1000
  }, ",")
  table.insert(_FILE_INFO, row)
end

local function write_data()
  local _, filename = reaper.EnumProjects(-1)
  filename = filename:match("^.+\\(.+)%.rpp$")
  local date = os.date("%Y-%m-%d_%I%M %S %p ")
  local data_file = PROJ_FOLDER .. "Data\\" .. date .. filename .. " Proc Data.csv"
  local write_file = io.open(data_file, "w")
  if write_file ~= nil then
    for k, v in pairs(_FILE_INFO) do
      if k == 1 and _DATA_FILE_EXISTS == false then
        write_file:write("Project,Language,Filename,FX Chain,Date,Time,CH,FI Length,FI Shape,FO Length,FO Shape,Tail Length,End Marker Offset\n")
      end
      write_file:write(v .. "\n")
    end
    write_file:close()
  end
  local date2 = os.date("%Y-%m-%d_%I%M %S %p")
  reaper.ShowConsoleMsg("Batch Process Completed: " .. date2 .. "\n")
  reaper.ShowConsoleMsg(string.format("Elapsed Time: %.2f sec\n", os.clock() - x_clock))
end

------------------------------------------------------------------------------------------------
-- MARKERS
------------------------------------------------------------------------------------------------

local function add_end_markers(end_marker_offset)
  local mkr_name = "end"
  if end_marker_offset > 0 then
    local num_sel_items = reaper.CountSelectedMediaItems(0)
    for i = 0, num_sel_items - 1 do
      local item = reaper.GetSelectedMediaItem(0, i)
      local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_len   = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local item_end   = item_start + item_len
      reaper.SetTakeMarker(reaper.GetActiveTake(item), -1, mkr_name, (item_end - end_marker_offset) - item_start)
    end
  end
end

------------------------------------------------------------------------------------------------
-- CORE BATCH LOGIC
------------------------------------------------------------------------------------------------

local function insert_and_render_lang(lang, raw_folder, tr, r)
  local file_counter = 0
  while true do
    local file_path = reaper.EnumerateFiles(raw_folder .. "\\" .. lang, file_counter)
    if file_path == nil then break end
    reaper.InsertMedia(raw_folder .. "\\" .. lang .. "\\" .. file_path, 0)
    save_data_to_table(lang, file_path, tr, r)
    file_counter = file_counter + 1
  end

  add_end_markers(r.END_MARKER_OFFSET)
  reaper.GetSetProjectInfo_String(0, "RENDER_FILE", PROJ_FOLDER .. "_Processed\\" .. lang, true)
  reaper.Main_OnCommand(42230, 1) -- Render using most recent settings, auto-close

  if settings.delete_after then
    reaper.Main_OnCommand(40006, 1)
  end

  reaper.Main_OnCommand(reaper.NamedCommandLookup("_SWS_UNSELONTRACKS"), 0)
end

-- Full synchronous batch (called when user clicks Batch!)
local function run_batch()

  x_clock = os.clock()

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  get_global_vars()
  scan_lang_folders()
  read_data_to_table()

  local raw_folder = PROJ_FOLDER .. "_Raw"
  progress_total   = #lang_folders
  progress_current = 0
  batch_done       = false

  -- Global resolved settings (used unless overridden)
  local global_r = resolve_settings(settings)
  set_render_info(global_r)

  for _, lang in ipairs(lang_folders) do

    progress_label   = "Processing: " .. lang
    progress_current = progress_current + 1

    -- Determine which settings to use for this lang
    local r = global_r
    if lang_overrides[lang] and lang_overrides[lang].enabled then
      r = resolve_settings(lang_overrides[lang].settings)
    end

    set_render_info(r)

    -- Find matching track
    for i = 0, reaper.CountTracks(0) - 1 do
      local tr = reaper.GetTrack(0, i)
      reaper.SetOnlyTrackSelected(tr)
      local _, tr_name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
      if tr_name == lang then
        insert_and_render_lang(lang, raw_folder, tr, r)
        break
      end
    end
  end

  write_data()

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock(({reaper.get_action_context()})[2]:match(".+[/\\](.+)"), -1)
  reaper.UpdateArrange()

  local elapsed = string.format("%.2f", os.clock() - x_clock)
  batch_done     = true
  batch_done_msg = string.format("Done! Processed %d language(s) in %s sec.", progress_total, elapsed)
  progress_label = batch_done_msg
  active_tab     = 2
end

------------------------------------------------------------------------------------------------
-- GUI HELPERS
------------------------------------------------------------------------------------------------

local function draw_settings_block(s, uid)
  -- uid: unique string suffix for ImGui IDs to avoid conflicts between global/per-lang panels
  local changed

  -- Sample Rate
  reaper.ImGui_Text(ctx, "Sample Rate")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 90)
  changed, s.sr_idx = reaper.ImGui_Combo(ctx, "##sr" .. uid, s.sr_idx, table.concat(SR_LABELS, "\0") .. "\0")

  -- Channels
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_Text(ctx, "  Channels")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 80)
  changed, s.ch_idx = reaper.ImGui_Combo(ctx, "##ch" .. uid, s.ch_idx, table.concat(CH_LABELS, "\0") .. "\0")

  -- Format
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_Text(ctx, "  Format")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 70)
  changed, s.fmt_idx = reaper.ImGui_Combo(ctx, "##fmt" .. uid, s.fmt_idx, table.concat(FMT_LABELS, "\0") .. "\0")

  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Text(ctx, "All fade/offset values in milliseconds")
  reaper.ImGui_Spacing(ctx)

  -- Fade In
  reaper.ImGui_Text(ctx, "Fade-In Length (ms)")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 60)
  changed, s.fadein_ms = reaper.ImGui_InputText(ctx, "##fi" .. uid, s.fadein_ms)
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_Text(ctx, "  Shape")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 150)
  changed, s.fadein_shape = reaper.ImGui_Combo(ctx, "##fis" .. uid, s.fadein_shape, SHAPE_LABELS)

  -- Fade Out
  reaper.ImGui_Text(ctx, "Fade-Out Length (ms)")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 60)
  changed, s.fadeout_ms = reaper.ImGui_InputText(ctx, "##fo" .. uid, s.fadeout_ms)
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_Text(ctx, "  Shape")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 150)
  changed, s.fadeout_shape = reaper.ImGui_Combo(ctx, "##fos" .. uid, s.fadeout_shape, SHAPE_LABELS)

  -- End Marker Offset
  reaper.ImGui_Text(ctx, "End Marker Offset (ms)")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 60)
  changed, s.end_offset_ms = reaper.ImGui_InputText(ctx, "##emo" .. uid, s.end_offset_ms)

  -- Tail Length
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_Text(ctx, "  Tail Length (ms)")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 60)
  changed, s.tail_ms = reaper.ImGui_InputText(ctx, "##tl" .. uid, s.tail_ms)
end

------------------------------------------------------------------------------------------------
-- MAIN GUI LOOP
------------------------------------------------------------------------------------------------

local function draw_gui()

  reaper.ImGui_SetNextWindowSize(ctx, 600, 520, reaper.ImGui_Cond_FirstUseEver())
  local visible, win_open = reaper.ImGui_Begin(ctx, "JS Folder Batch Processor v2.0", true)
  open = win_open

  if not visible then
    reaper.ImGui_End(ctx)
    return
  end

  -- TAB BAR
  if reaper.ImGui_BeginTabBar(ctx, "MainTabs") then

    -------------------------------------------------------
    -- TAB 1: GLOBAL SETTINGS
    -------------------------------------------------------
    if reaper.ImGui_BeginTabItem(ctx, "Global Settings") then
      active_tab = 0
      reaper.ImGui_Spacing(ctx)

      draw_settings_block(settings, "_global")

      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Spacing(ctx)

      local changed
      changed, settings.delete_after = reaper.ImGui_Checkbox(ctx, "Delete items after render", settings.delete_after)

      reaper.ImGui_Spacing(ctx)

      -- SCAN button
      if reaper.ImGui_Button(ctx, "Scan _Raw Folder for Languages", 260, 0) then
        get_global_vars()
        scan_lang_folders()
      end

      reaper.ImGui_SameLine(ctx)

      if #lang_folders > 0 then
        reaper.ImGui_Text(ctx, string.format("  Found %d language(s)", #lang_folders))
      else
        reaper.ImGui_TextDisabled(ctx, "  No languages scanned yet")
      end

      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Spacing(ctx)

      -- BATCH BUTTON
      local can_batch = #lang_folders > 0
      if not can_batch then
        reaper.ImGui_BeginDisabled(ctx)
      end

      if reaper.ImGui_Button(ctx, "  BATCH!  ", 540, 36) then
        run_batch()
      end

      if not can_batch then
        reaper.ImGui_EndDisabled(ctx)
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_TextDisabled(ctx, " Scan a folder first")
      end

      reaper.ImGui_EndTabItem(ctx)
    end

    -------------------------------------------------------
    -- TAB 2: PER-LANGUAGE OVERRIDES
    -------------------------------------------------------
    if reaper.ImGui_BeginTabItem(ctx, "Language Overrides") then
      active_tab = 1
      reaper.ImGui_Spacing(ctx)

      if #lang_folders == 0 then
        reaper.ImGui_TextDisabled(ctx, "No languages found. Use 'Scan _Raw Folder' on the Global Settings tab first.")
      else
        reaper.ImGui_TextWrapped(ctx, "Enable per-language overrides to use different render settings for specific languages. Disabled languages use Global Settings.")
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)

        for _, lang in ipairs(lang_folders) do
          local ov = lang_overrides[lang]
          reaper.ImGui_Spacing(ctx)

          local hdr_label = lang
          if ov.enabled then
            hdr_label = lang .. "  [OVERRIDE ACTIVE]"
          end

          -- Collapsing header per language
          if reaper.ImGui_CollapsingHeader(ctx, hdr_label .. "##hdr_" .. lang) then
            reaper.ImGui_Indent(ctx, 12)
            reaper.ImGui_Spacing(ctx)

            local changed
            changed, ov.enabled = reaper.ImGui_Checkbox(ctx, "Enable override for " .. lang, ov.enabled)

            if ov.enabled then
              reaper.ImGui_Spacing(ctx)
              draw_settings_block(ov.settings, "_" .. lang)
            else
              reaper.ImGui_TextDisabled(ctx, "Override disabled — using Global Settings for this language.")
            end

            reaper.ImGui_Unindent(ctx, 12)
            reaper.ImGui_Spacing(ctx)
          end
        end
      end

      reaper.ImGui_EndTabItem(ctx)
    end

    -------------------------------------------------------
    -- TAB 3: PROGRESS / LOG
    -------------------------------------------------------
    if reaper.ImGui_BeginTabItem(ctx, "Progress") then
      active_tab = 2
      reaper.ImGui_Spacing(ctx)

      if progress_total == 0 and not batch_done then
        reaper.ImGui_TextDisabled(ctx, "No batch running. Click BATCH! on the Global Settings tab to begin.")
      else
        -- Progress bar
        local frac = progress_total > 0 and (progress_current / progress_total) or 0
        reaper.ImGui_Text(ctx, string.format("Language %d / %d", progress_current, progress_total))
        reaper.ImGui_ProgressBar(ctx, frac, -1, 0, "")
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextWrapped(ctx, progress_label)

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)

        if batch_done then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x88FF88FF)
          reaper.ImGui_Text(ctx, "Batch complete!")
          reaper.ImGui_PopStyleColor(ctx)
          reaper.ImGui_TextWrapped(ctx, batch_done_msg)
        else
          reaper.ImGui_TextDisabled(ctx, "Batch in progress...")
        end
      end

      reaper.ImGui_EndTabItem(ctx)
    end

    reaper.ImGui_EndTabBar(ctx)
  end

  reaper.ImGui_End(ctx)
end

------------------------------------------------------------------------------------------------
-- DEFER LOOP
------------------------------------------------------------------------------------------------

local function loop()
  reaper.ImGui_PushFont(ctx, sans_serif, 0)
  local ok, err = pcall(draw_gui)
  reaper.ImGui_PopFont(ctx)

  if not ok then
    reaper.ShowConsoleMsg("JS ImGui Error: " .. tostring(err) .. "\n")
    return
  end

  if open then
    reaper.defer(loop)
  end
end

-- INIT
get_global_vars()
reaper.defer(loop)
