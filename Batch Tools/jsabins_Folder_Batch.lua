-- @description Folder Batch Processor
-- @author Jay Sabins, Daniel Petras
-- @version 2.1.0
-- @changelog
--   New look to match Wwise Tool: dark #191919 window with big rounded corners and a thin
--   outline, Verdana, a bold "Folder Batch" title in a custom title bar with flat ? and X
--   buttons (a box only shows on hover), grey buttons and fields with rounded corners.
--   One screen instead of three tabs: project and render settings on the left, the languages
--   list on the right, and a big Batch button at the bottom left.
--   The languages list shows how many files each language folder has, whether a track with
--   the same name was found, and whether it uses its own render settings. Click a language to
--   give it its own settings.
--   Batch is greyed out until the project is saved and the _Raw folder has been scanned; hover
--   it to see why.
--   If you've changed Wwise Tool's Settings > Appearance (font, colors, corners), Folder Batch
--   uses the same look.
--   Renamed from jsabins_Folder_Batch_ImGui.lua.
-- @about
--   # Folder Batch Processor
--
--   Batch-renders multi-language VO from a structured project folder (_Raw to _Processed)
--   with per-language overrides and CSV logging.
--
--   Requires SWS and ReaImGui (ReaPack > ReaTeam Extensions).
--
--   Full guide: https://github.com/jaysabins/reascripts/blob/main/Batch%20Tools/jsabins_Folder_Batch_README.md

-------------------------------------------------------------------------------
-- FOLDER BATCH PROCESSOR v2.1
-------------------------------------------------------------------------------
-- Original by: Daniel Petras and Jay Sabins
-- Ported to ReaImGui with per-language overrides; restyled to match Wwise Tool in 2.1.

--DEPENDENCIES--
-- SWS/S&M Extension: https://www.sws-extension.org/
-- ReaImGui: https://forum.cockos.com/showthread.php?t=250419

------------------------------------------------------------------------------------------------

--[[
INSTRUCTIONS:
  - Set up '_Raw', '_Processed', 'Data', 'Chains', and 'Docs' folders inside of Reaper project folder
  - Include language-named folders inside '_Raw' that match track names exactly
  - Use 'Script: mpl_Add FXChain to selected track (modified by JS 2).lua' to add FX Chains
  - Once Raw folder is populated and FX Chains added, run this script and click Batch
]]

local r = reaper
if not r.ImGui_GetBuiltinPath then
  r.ShowMessageBox("This script needs ReaImGui.\nInstall it from Extensions > ReaPack > Browse packages (search \"ReaImGui\"), then restart REAPER.",
    "Folder Batch", 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. "/?.lua"
local ImGui = require "imgui" "0.9"

------------------------------------------------------------------------------------------------
-- GLOBAL STATE
------------------------------------------------------------------------------------------------

local ctx = ImGui.CreateContext("Folder Batch")

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
local SR_ITEMS    = table.concat(SR_LABELS, "\0") .. "\0"
local CH_ITEMS    = table.concat(CH_LABELS, "\0") .. "\0"
local FMT_ITEMS   = table.concat(FMT_LABELS, "\0") .. "\0"

-- Detected language folders
local lang_folders       = {}
-- Per-language override table: lang_overrides[lang] = { enabled=bool, settings={...} }
local lang_overrides     = {}
-- Number of files in each language folder (counted when scanning)
local lang_files         = {}

-- Result of the last batch
local progress_total     = 0
local batch_done         = false
local batch_done_msg     = ""

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
  lang_files = {}
  if not PROJ_FOLDER then return end -- project not saved yet: no folder to scan
  local raw_folder = PROJ_FOLDER .. "_Raw"
  local i = 0
  while true do
    local name = reaper.EnumerateSubdirectories(raw_folder, i)
    if name == nil then break end
    table.insert(lang_folders, name)
    -- count its files (shown in the languages list)
    local n = 0
    while reaper.EnumerateFiles(raw_folder .. "\\" .. name, n) do n = n + 1 end
    lang_files[name] = n
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

-- Full synchronous batch (run between frames after the Batch button is clicked)
local function run_batch()

  x_clock = os.clock()

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  get_global_vars()
  scan_lang_folders()
  read_data_to_table()

  local raw_folder = PROJ_FOLDER .. "_Raw"
  progress_total   = #lang_folders
  batch_done       = false

  -- Global resolved settings (used unless overridden)
  local global_r = resolve_settings(settings)
  set_render_info(global_r)

  for _, lang in ipairs(lang_folders) do

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
  batch_done_msg = string.format("Processed %d language(s) in %s sec.", progress_total, elapsed)
end

------------------------------------------------------------------------------------------------
-- LOOK (same as Wwise Tool)
------------------------------------------------------------------------------------------------
-- Same defaults as Wwise Tool: Verdana 12, 14px bold headings, #191919 background, 14px window
-- corners, 8px corners on buttons/fields/panels, a thin #505050 outline. If Wwise Tool's
-- Settings > Appearance has been changed, its saved look is used here too, so the two match.

local UI = {}
UI.FONT_CHOICES = { "Verdana", "Tahoma", "Segoe UI", "Arial", "Calibri", "Consolas" }
UI.LOOK_DEFAULTS = { font = "Verdana", size = 12, head = 14, win_round = 14, frame_round = 8 }
UI.DEFAULT_TEXT, UI.DEFAULT_DIM, UI.DEFAULT_BG = 0xFFFFFFFF, 0x9A9A9AFF, 0x191919FF
UI.DEFAULT_OUTLINE = 0x505050FF
UI.COLOR_OK, UI.COLOR_BAD, UI.COLOR_OWN = 0x6BCB77FF, 0xFF6B6BFF, 0xF5A524FF
UI.BATCH_H = 34 -- Batch button height (same as Wwise Tool's Transfer button)
UI.GUIDE_URL = "https://github.com/jaysabins/reascripts/blob/main/Batch%20Tools/jsabins_Folder_Batch_README.md"

-- Wwise Tool keeps its look as JSON in ExtState jsabins_WwiseTool/view, under "look".
-- Read just those few flat fields (no JSON library needed); anything missing keeps its default.
UI.read_look = function()
  local d = UI.LOOK_DEFAULTS
  local L = { font = d.font, size = d.size, head = d.head, win_round = d.win_round, frame_round = d.frame_round }
  local ok, v = pcall(r.GetExtState, "jsabins_WwiseTool", "view")
  local body = ok and type(v) == "string" and v:match('"look"%s*:%s*(%b{})')
  if not body then return L end
  local function num(k)
    local n = tonumber(body:match('"' .. k .. '"%s*:%s*(%-?[%d%.eE%+]+)'))
    return n and math.floor(n) or nil
  end
  local function clamp(n, lo, hi) return n and math.max(lo, math.min(hi, n)) or nil end
  local font = body:match('"font"%s*:%s*"([^"]*)"')
  for _, f in ipairs(UI.FONT_CHOICES) do if f == font then L.font = f end end
  L.size = clamp(num("size"), 9, 18) or L.size
  L.head = clamp(num("head"), 10, 24) or L.head
  L.win_round = clamp(num("win_round"), 0, 20) or L.win_round
  local fr = clamp(num("frame_round"), 0, 10)
  -- Wwise Tool 1.22.0 saved its old default (3); 1.22.1 moved everyone on it to 8.
  if fr and not ((num("look_v") or 0) < 1 and fr == 3) then L.frame_round = fr end
  for _, k in ipairs({ "title", "text", "dim", "bg", "outline" }) do
    local n = num(k)
    if n then L[k] = n | 0xFF end
  end
  return L
end
UI.look = UI.read_look()
UI.bg_rgb = function() return (UI.look.bg or UI.DEFAULT_BG) >> 8 end
UI.dim_col = function() return UI.look.dim or UI.DEFAULT_DIM end
UI.WINDOW_ROUNDING = UI.look.win_round
UI.FRAME_ROUNDING = UI.look.frame_round

-- Fonts are made once at startup. Any that can't be made fall back to ImGui's own font.
UI.make_font = function(size, bold)
  local flags = 0
  if bold then
    local okb, b = pcall(function() return ImGui.FontFlags_Bold end)
    if okb and type(b) == "number" then flags = b end
  end
  local ok, f = pcall(ImGui.CreateFont, UI.look.font, size, flags)
  if not (ok and f) then ok, f = pcall(ImGui.CreateFont, UI.look.font, size) end
  if ok and f and pcall(ImGui.Attach, ctx, f) then return f end
end
UI.main_font = UI.make_font(UI.look.size)
UI.section_font = UI.make_font(UI.look.head, true)   -- section headings
UI.title_font = UI.make_font(UI.look.head + 1, true) -- big window title, 1px bigger

-- Constant names changed between ReaImGui versions, so use whichever exists.
local function imgui_const(...)
  for _, name in ipairs({ ... }) do
    local ok, v = pcall(function() return ImGui[name] end)
    if ok and type(v) == "number" then return v end
  end
end

-- Dark grey theme in place of ImGui's default blue (same colors as Wwise Tool).
local GREY_THEME = {
  { { "Col_WindowBg" }, 0x191919FF },
  { { "Col_Border" }, 0x2E2E2EFF },
  { { "Col_Button" }, 0x3A3A3AFF },
  { { "Col_ButtonHovered" }, 0x4C4C4CFF },
  { { "Col_ButtonActive" }, 0x5E5E5EFF },
  { { "Col_FrameBg" }, 0x2A2A2AFF },
  { { "Col_FrameBgHovered" }, 0x383838FF },
  { { "Col_FrameBgActive" }, 0x464646FF },
  { { "Col_Header" }, 0x3A3A3AFF },
  { { "Col_HeaderHovered" }, 0x4A4A4AFF },
  { { "Col_HeaderActive" }, 0x585858FF },
  { { "Col_CheckMark" }, 0xD8D8D8FF },
  { { "Col_SliderGrab" }, 0x8A8A8AFF },
  { { "Col_SliderGrabActive" }, 0xB4B4B4FF },
  { { "Col_SeparatorHovered" }, 0x707070C8 },
  { { "Col_SeparatorActive" }, 0x909090FF },
  { { "Col_ResizeGrip" }, 0x5A5A5A40 },
  { { "Col_ResizeGripHovered" }, 0x7A7A7AAA },
  { { "Col_ResizeGripActive" }, 0x9A9A9AF2 },
  { { "Col_Tab" }, 0x2C2C2CFF },
  { { "Col_TabHovered" }, 0x4C4C4CFF },
  { { "Col_TabSelected", "Col_TabActive" }, 0x3C3C3CFF },
  { { "Col_TabDimmed", "Col_TabUnfocused" }, 0x242424FF },
  { { "Col_TabDimmedSelected", "Col_TabUnfocusedActive" }, 0x333333FF },
  { { "Col_TextSelectedBg" }, 0x6A6A6A80 },
  { { "Col_NavCursor", "Col_NavHighlight" }, 0x9A9A9AFF },
  { { "Col_DockingPreview" }, 0x8A8A8AB3 },
}
for _, t in ipairs(GREY_THEME) do t[1] = imgui_const(table.unpack(t[1])) end
-- Push the grey theme; returns how many colors to pop.
local function push_grey_theme()
  local n = 0
  for _, t in ipairs(GREY_THEME) do
    if t[1] then
      ImGui.PushStyleColor(ctx, t[1], t[1] == ImGui.Col_WindowBg and ((UI.bg_rgb() << 8) | 0xFF) or t[2]); n = n + 1
    end
  end
  if UI.look.text then ImGui.PushStyleColor(ctx, ImGui.Col_Text, UI.look.text); n = n + 1 end
  if UI.look.dim then ImGui.PushStyleColor(ctx, ImGui.Col_TextDisabled, UI.look.dim); n = n + 1 end
  return n
end

-- Rounded corners for everything ImGui draws square by default. Pushed right after the window's
-- Begin and popped right before its End.
UI.ROUNDING_VARS = { "StyleVar_FrameRounding", "StyleVar_GrabRounding", "StyleVar_PopupRounding",
  "StyleVar_ChildRounding", "StyleVar_TabRounding", "StyleVar_ScrollbarRounding" }
UI.push_rounding = function()
  local n = 0
  for _, k in ipairs(UI.ROUNDING_VARS) do
    local ok, v = pcall(function() return ImGui[k] end)
    if ok and type(v) == "number" then ImGui.PushStyleVar(ctx, v, UI.FRAME_ROUNDING); n = n + 1 end
  end
  return n
end

------------------------------------------------------------------------------------------------
-- GUI HELPERS
------------------------------------------------------------------------------------------------

local function tip(text)
  if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then ImGui.SetTooltip(ctx, text) end
end
local function dim(text) ImGui.TextColored(ctx, UI.dim_col(), text) end

-- Section heading: bold text with a line after it (like Wwise Tool's sections).
local function section_title(text)
  local big = UI.section_font and pcall(ImGui.PushFont, ctx, UI.section_font)
  ImGui.SeparatorText(ctx, text)
  if big then ImGui.PopFont(ctx) end
  ImGui.Dummy(ctx, 0, 0) -- a little room under the heading
end

-- The big window title, drawn twice a pixel apart so it's extra bold.
local function draw_title(dl, x, y, col, text)
  ImGui.DrawList_AddText(dl, x, y, col, text)
  ImGui.DrawList_AddText(dl, x + 1, y, col, text)
end

-- Open a web page in the default browser (SWS's CF_ShellExecute, else the OS's own opener).
local function open_url(url)
  if r.CF_ShellExecute then r.CF_ShellExecute(url); return end
  local os_name = r.GetOS()
  if os_name:match("^Win") then
    r.ExecProcess('explorer.exe "' .. url .. '"', -2)
  elseif os_name:match("^OSX") or os_name:match("^macOS") then
    r.ExecProcess('/usr/bin/open "' .. url .. '"', -2)
  else
    r.ExecProcess('xdg-open "' .. url .. '"', -2)
  end
end

-- Title-bar buttons: twice the font size, flat until hovered (grey box; the X goes red).
local function close_size() return math.floor(ImGui.GetFontSize(ctx) * 2 + 0.5) end
local function close_margin() return math.floor(ImGui.GetFontSize(ctx) * 0.5 + 0.5) end
local function title_bar_size() return close_size() + close_margin() + math.max(2, math.floor(close_margin() * 0.4)) end

local function close_button(id, size)
  local pressed = ImGui.InvisibleButton(ctx, id, size, size)
  local hovered, held = ImGui.IsItemHovered(ctx), ImGui.IsItemActive(ctx)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local fg = hovered and 0xFFFFFFFF or ImGui.GetColor(ctx, ImGui.Col_Text)
  if hovered or held then
    ImGui.DrawList_AddRectFilled(dl, x1, y1, x1 + size, y1 + size, held and 0xB8323AFF or 0xE04048FF, size * 0.22)
  end
  local m, th = size * 0.30, math.max(2, size * 0.08)
  local a, b = m - 0.5, size - m - 0.5
  ImGui.DrawList_AddLine(dl, x1 + a, y1 + a, x1 + b, y1 + b, fg, th)
  ImGui.DrawList_AddLine(dl, x1 + b, y1 + a, x1 + a, y1 + b, fg, th)
  return pressed
end

local function title_icon_button(id, size, draw)
  local pressed = ImGui.InvisibleButton(ctx, id, size, size)
  local hovered, held = ImGui.IsItemHovered(ctx), ImGui.IsItemActive(ctx)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local fg = hovered and 0xFFFFFFFF or ImGui.GetColor(ctx, ImGui.Col_Text)
  if hovered or held then
    ImGui.DrawList_AddRectFilled(dl, x1, y1, x1 + size, y1 + size, held and 0x5E5E5EFF or 0x4C4C4CFF, size * 0.22)
  end
  draw(dl, x1, y1, size, fg)
  return pressed
end

local function draw_question(dl, x1, y1, size, fg)
  local big = UI.section_font and pcall(ImGui.PushFont, ctx, UI.section_font)
  local tw, th = ImGui.CalcTextSize(ctx, "?")
  ImGui.DrawList_AddText(dl, x1 + (size - tw) / 2, y1 + (size - th) / 2, fg, "?")
  if big then ImGui.PopFont(ctx) end
end

------------------------------------------------------------------------------------------------
-- WINDOW PARTS
------------------------------------------------------------------------------------------------

local close_clicked = false
local win_docked = false
local batch_queued = 0  -- 1: clicked (show "Rendering..."), 2: run after this frame
local selected_lang = nil

-- Current project's folder (nil while the project has never been saved) and name.
local function project_info()
  local _, file = r.EnumProjects(-1)
  file = file or ""
  return file:match("(.*\\)"), file:match("([^\\/]+)%.[Rr][Pp][Pp]$")
end

-- Status in the title bar: { text, color (nil = normal), tooltip }, and the dot's color.
local function status_items()
  local folder, name = project_info()
  if not folder then
    return { { "Project not saved", UI.COLOR_BAD, "Save the REAPER project first: Folder Batch works from the project's folder." } }, UI.COLOR_BAD
  end
  local t = { { name or "Project", nil, folder } }
  if #lang_folders > 0 then
    t[2] = { string.format("%d language%s", #lang_folders, #lang_folders == 1 and "" or "s"), UI.dim_col() }
    return t, UI.COLOR_OK
  end
  t[2] = { "not scanned", UI.dim_col() }
  return t, UI.dim_col()
end

-- Status dot and text, right-aligned to right_x and centered on a row of height h at top.
local function title_status(right_x, top, h)
  local items, dot_col = status_items()
  local sp = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
  local dot = 8
  local w = dot + sp
  for i, it in ipairs(items) do w = w + ImGui.CalcTextSize(ctx, it[1]) + (i > 1 and sp or 0) end
  local th = ImGui.GetTextLineHeight(ctx)
  local x, y = right_x - w, top + (h - th) / 2
  ImGui.DrawList_AddCircleFilled(ImGui.GetWindowDrawList(ctx), x + dot / 2, top + h / 2, dot / 2, dot_col)
  x = x + dot + sp
  for _, it in ipairs(items) do
    ImGui.SetCursorScreenPos(ctx, x, y)
    if it[2] then ImGui.TextColored(ctx, it[2], it[1]) else ImGui.Text(ctx, it[1]) end
    if it[3] and ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, it[3]) end
    x = x + ImGui.CalcTextSize(ctx, it[1]) + sp
  end
end

-- Floating window: big bold title on the left; status, ? and X on the right, drawn over the
-- (taller) title bar. Called last in the window so it draws on top. The cursor isn't moved back
-- afterwards (ImGui errors in End() if the cursor is moved without an item after it).
local function title_bar()
  local size, m = close_size(), close_margin()
  local wx, wy = ImGui.GetWindowPos(ctx)
  local ww = ImGui.GetWindowSize(ctx)
  ImGui.PushClipRect(ctx, wx, wy, wx + ww, wy + title_bar_size(), false)
  local gap = math.floor(m * 0.6 + 0.5)
  local x = wx + ww - size - m - gap
  ImGui.SetCursorScreenPos(ctx, x, wy + m)
  if close_button("##closewin", size) then close_clicked = true end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Close Folder Batch") end
  x = x - gap - size
  ImGui.SetCursorScreenPos(ctx, x, wy + m)
  if title_icon_button("##guide_t", size, draw_question) then open_url(UI.GUIDE_URL) end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Open the Folder Batch guide on GitHub") end
  title_status(x - gap * 2, wy + m, size)
  local big = UI.title_font and pcall(ImGui.PushFont, ctx, UI.title_font)
  local _, th = ImGui.CalcTextSize(ctx, "Folder Batch")
  draw_title(ImGui.GetWindowDrawList(ctx), wx + m + 12, wy + m + (size - th) / 2 + 3,
    UI.look.title or ImGui.GetColor(ctx, ImGui.Col_Text), "Folder Batch")
  if big then ImGui.PopFont(ctx) end
  ImGui.PopClipRect(ctx)
end

-- Docked (no title bar): status and ? on one row at the top, right-aligned.
local function docked_header()
  local size = ImGui.GetFrameHeight(ctx)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local aw = ImGui.GetContentRegionAvail(ctx)
  local gap = 6
  title_status(x0 + aw - size - gap * 2, y0, size)
  ImGui.SetCursorScreenPos(ctx, x0 + aw - size, y0)
  if title_icon_button("##guide_d", size, draw_question) then open_url(UI.GUIDE_URL) end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Open the Folder Batch guide on GitHub") end
end

-- One row of a settings form: label on the left, the control lined up in a second column.
local function form_label(text)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, text)
  ImGui.SameLine(ctx, math.floor(ImGui.GetFontSize(ctx) * 9))
end

local function ms_input(id, value)
  ImGui.SetNextItemWidth(ctx, math.floor(ImGui.GetFontSize(ctx) * 5))
  local _, v = ImGui.InputText(ctx, id, value, ImGui.InputTextFlags_CharsDecimal)
  ImGui.SameLine(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  dim("ms")
  return v
end

local function shape_combo(id, value)
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, -1)
  local _, v = ImGui.Combo(ctx, id, value, SHAPE_LABELS)
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Fade shape") end
  return v
end

-- Render settings form (used for the global settings and for each language's own settings).
local function settings_form(s, uid)
  local fw = math.floor(ImGui.GetFontSize(ctx) * 8)
  local _
  form_label("Sample rate")
  ImGui.SetNextItemWidth(ctx, fw)
  _, s.sr_idx = ImGui.Combo(ctx, "##sr" .. uid, s.sr_idx, SR_ITEMS)
  form_label("Channels")
  ImGui.SetNextItemWidth(ctx, fw)
  _, s.ch_idx = ImGui.Combo(ctx, "##ch" .. uid, s.ch_idx, CH_ITEMS)
  form_label("Format")
  ImGui.SetNextItemWidth(ctx, fw)
  _, s.fmt_idx = ImGui.Combo(ctx, "##fmt" .. uid, s.fmt_idx, FMT_ITEMS)
  ImGui.Dummy(ctx, 0, 2)
  form_label("Fade-in")
  s.fadein_ms = ms_input("##fi" .. uid, s.fadein_ms)
  s.fadein_shape = shape_combo("##fis" .. uid, s.fadein_shape)
  form_label("Fade-out")
  s.fadeout_ms = ms_input("##fo" .. uid, s.fadeout_ms)
  s.fadeout_shape = shape_combo("##fos" .. uid, s.fadeout_shape)
  form_label("End marker")
  s.end_offset_ms = ms_input("##emo" .. uid, s.end_offset_ms)
  ImGui.SameLine(ctx, 0, 0)
  dim(" before the end")
  tip("Adds a take marker named \"end\" this far before each item's end. 0 = no marker.")
  form_label("Tail")
  s.tail_ms = ms_input("##tl" .. uid, s.tail_ms)
  tip("Extra time rendered after each item.")
end

local function section_project()
  section_title("Project")
  local folder = project_info()
  if not folder then
    ImGui.TextColored(ctx, UI.COLOR_BAD, "Save the REAPER project first.")
    dim("Folder Batch works from the project's folder.")
    return
  end
  ImGui.TextWrapped(ctx, folder .. "_Raw")
  tip("Each folder in _Raw is a language. Its name must match a track's name exactly.")
  if ImGui.Button(ctx, "Scan _Raw folder") then
    get_global_vars()
    scan_lang_folders()
    local still_there = false
    for _, l in ipairs(lang_folders) do if l == selected_lang then still_there = true end end
    if not still_there then selected_lang = nil end
  end
  tip("Find the language folders in _Raw.")
  ImGui.SameLine(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  if #lang_folders > 0 then
    ImGui.Text(ctx, string.format("Found %d language%s", #lang_folders, #lang_folders == 1 and "" or "s"))
  else
    dim("Not scanned yet")
  end
end

local function section_render()
  section_title("Render settings")
  settings_form(settings, "_global")
  ImGui.Dummy(ctx, 0, 2)
  local _
  _, settings.delete_after = ImGui.Checkbox(ctx, "Delete items after render", settings.delete_after)
  tip("Removes the imported items from the timeline once each language has rendered.")
end

-- Big Batch button at the bottom left, green when ready. Why it's greyed out is in its tooltip.
local function section_batch(bw)
  local why
  if not project_info() then why = "Save the REAPER project first."
  elseif #lang_folders == 0 then why = "Click Scan _Raw folder first."
  elseif batch_queued > 0 then why = "Rendering..."
  end
  local can = why == nil -- worked out once: the Begin/EndDisabled pair below must match
  if can then
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x1A7F37FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x2C974BFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x166A2EFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFFFFFFF)
  else
    ImGui.BeginDisabled(ctx)
  end
  local label = batch_queued > 0 and "Rendering..." or "Batch"
  if ImGui.Button(ctx, label .. "##batch", bw, UI.BATCH_H) and can then batch_queued = 1 end
  if can then ImGui.PopStyleColor(ctx, 4) else ImGui.EndDisabled(ctx) end
  local info = "Imports each language's files from _Raw onto its track, renders them to _Processed\\<language> and logs them in Data."
  if batch_done then info = info .. "\n\nLast batch: " .. batch_done_msg end
  tip(why and (why .. "\n\n" .. info) or info)
end

-- Names of all tracks in the project (to show which languages have a matching track).
local function track_names()
  local t = {}
  for i = 0, r.CountTracks(0) - 1 do
    local _, name = r.GetSetMediaTrackInfo_String(r.GetTrack(0, i), "P_NAME", "", false)
    if name then t[name] = true end
  end
  return t
end

-- Languages: a quiet list (no lines, dim header). Click one to give it its own settings.
local function section_languages()
  section_title("Languages")
  if #lang_folders == 0 then
    dim("Click Scan _Raw folder to list the language folders.")
  else
    local tracks = track_names()
    local flags = ImGui.TableFlags_SizingFixedFit | ImGui.TableFlags_PadOuterX
    if ImGui.BeginTable(ctx, "langs", 4, flags) then
      ImGui.TableSetupColumn(ctx, "Language", ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableSetupColumn(ctx, "Files")
      ImGui.TableSetupColumn(ctx, "Track")
      ImGui.TableSetupColumn(ctx, "Settings")
      ImGui.TableNextRow(ctx)
      for i, h in ipairs({ "Language", "Files", "Track", "Settings" }) do
        ImGui.TableSetColumnIndex(ctx, i - 1)
        dim(h)
      end
      for i, lang in ipairs(lang_folders) do
        local ov = lang_overrides[lang]
        ImGui.TableNextRow(ctx)
        ImGui.TableSetColumnIndex(ctx, 0)
        if ImGui.Selectable(ctx, lang .. "##lang" .. i, selected_lang == lang, ImGui.SelectableFlags_SpanAllColumns) then
          selected_lang = (selected_lang == lang) and nil or lang
        end
        tip("Click to give " .. lang .. " its own render settings.")
        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.Text(ctx, tostring(lang_files[lang] or 0))
        ImGui.TableSetColumnIndex(ctx, 2)
        if tracks[lang] then
          ImGui.TextColored(ctx, UI.COLOR_OK, "Found")
        else
          ImGui.TextColored(ctx, UI.COLOR_BAD, "Missing")
          tip("No track named \"" .. lang .. "\". This language is skipped.")
        end
        ImGui.TableSetColumnIndex(ctx, 3)
        if ov and ov.enabled then ImGui.TextColored(ctx, UI.COLOR_OWN, "Own") else dim("Global") end
      end
      ImGui.EndTable(ctx)
    end
  end

  local ov = selected_lang and lang_overrides[selected_lang]
  if ov then
    ImGui.Dummy(ctx, 0, 6)
    section_title(selected_lang)
    local _
    _, ov.enabled = ImGui.Checkbox(ctx, "Use its own render settings", ov.enabled)
    if ov.enabled then
      ImGui.Dummy(ctx, 0, 2)
      settings_form(ov.settings, "_" .. selected_lang)
    else
      dim("Uses the render settings on the left.")
    end
  end

  if batch_done then
    ImGui.Dummy(ctx, 0, 6)
    section_title("Last batch")
    ImGui.TextColored(ctx, UI.COLOR_OK, batch_done_msg)
  end
end

------------------------------------------------------------------------------------------------
-- MAIN WINDOW
------------------------------------------------------------------------------------------------

local function loop_body()
  ImGui.SetNextWindowSize(ctx, 900, 560, ImGui.Cond_FirstUseEver)
  ImGui.SetNextWindowSizeConstraints(ctx, 640, 400, 4000, 4000)
  -- Main font for the whole window. Pushed before Begin, popped after End.
  local main_font = UI.main_font and pcall(ImGui.PushFont, ctx, UI.main_font)
  ImGui.SetNextWindowCollapsed(ctx, false, ImGui.Cond_Always)
  -- Floating: the whole background (title bar included) is painted by us as one rounded shape
  -- right after Begin, so ImGui's own title bar and body backgrounds are made transparent.
  -- Docked: ImGui's own background and dock tab.
  local own_bg = not win_docked
  local bg_col = (UI.bg_rgb() << 8) | 0xFF
  ImGui.SetNextWindowBgAlpha(ctx, own_bg and 0 or 1)
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg, 0x202020FF) -- solid popups and tooltips
  local title_bg = own_bg and (UI.bg_rgb() << 8) or bg_col
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg, title_bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive, title_bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgCollapsed, title_bg)
  local theme_n = push_grey_theme()
  -- Rounded corners on tooltips/popups too (they're their own windows): pushed before Begin and
  -- popped after End.
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, UI.FRAME_ROUNDING)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_GrabRounding, UI.FRAME_ROUNDING)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_PopupRounding, UI.FRAME_ROUNDING)
  -- Taller title bar to fit the big title and buttons; rounded window corners.
  local pad_x, pad_y = ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
  local title_pad = (title_bar_size() - ImGui.GetFontSize(ctx)) / 2
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, pad_x, math.max(pad_y, title_pad))
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding, UI.WINDOW_ROUNDING)
  -- ImGui's title text is hidden (we draw the big title); the dock tab still reads "Folder Batch".
  local hide_title = not win_docked
  if hide_title then ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x00000000) end
  local visible, open = ImGui.Begin(ctx, "Folder Batch", win_docked and true or nil,
    ImGui.WindowFlags_NoCollapse | ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoScrollWithMouse)
  if hide_title then ImGui.PopStyleColor(ctx) end
  ImGui.PopStyleVar(ctx, 2)
  if open == nil then open = true end
  if visible then
    local round_n = UI.push_rounding()
    if own_bg then
      -- One rounded rectangle for the whole window, then the thin outline on top.
      local wx, wy = ImGui.GetWindowPos(ctx)
      local ww, wh = ImGui.GetWindowSize(ctx)
      local dl = ImGui.GetWindowDrawList(ctx)
      ImGui.PushClipRect(ctx, wx, wy, wx + ww, wy + wh, false)
      ImGui.DrawList_AddRectFilled(dl, wx, wy, wx + ww, wy + wh, bg_col, UI.WINDOW_ROUNDING)
      ImGui.DrawList_AddRect(dl, wx + 0.5, wy + 0.5, wx + ww - 0.5, wy + wh - 0.5,
        UI.look.outline or UI.DEFAULT_OUTLINE, UI.WINDOW_ROUNDING, 0, 1)
      ImGui.PopClipRect(ctx)
    end
    win_docked = ImGui.IsWindowDocked(ctx)
    if win_docked then docked_header() end

    -- Layout: project + render settings on the left with Batch under them; languages on the right.
    local avail_w = ImGui.GetContentRegionAvail(ctx)
    local left_w = math.floor(math.max(360, math.min(480, avail_w * 0.5)))
    local _, sp_y = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
    local footer_h = UI.BATCH_H + sp_y
    ImGui.BeginGroup(ctx)
    if ImGui.BeginChild(ctx, "setup", left_w, -footer_h, ImGui.ChildFlags_Border) then
      section_project()
      section_render()
      ImGui.EndChild(ctx)
    end
    section_batch(left_w)
    ImGui.EndGroup(ctx)
    ImGui.SameLine(ctx)
    if ImGui.BeginChild(ctx, "languages", 0, 0) then
      section_languages()
      ImGui.EndChild(ctx)
    end

    if not win_docked then title_bar() end
    if round_n > 0 then ImGui.PopStyleVar(ctx, round_n) end
    ImGui.End(ctx)
  end
  ImGui.PopStyleVar(ctx, 3)
  ImGui.PopStyleColor(ctx, 4 + theme_n)
  if main_font then ImGui.PopFont(ctx) end
  if close_clicked then open = false end
  return open
end

------------------------------------------------------------------------------------------------
-- DEFER LOOP
------------------------------------------------------------------------------------------------

local function loop()
  local open = loop_body()
  -- The batch runs between frames (never inside an ImGui window), one frame after the click so
  -- the button can show "Rendering..." first.
  if batch_queued == 2 then
    batch_queued = 0
    run_batch()
  elseif batch_queued == 1 then
    batch_queued = 2
  end
  if open then r.defer(loop) end
end

-- INIT
get_global_vars()
r.defer(loop)
