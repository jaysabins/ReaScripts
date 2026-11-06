-- @description Screenshot track FX chain to Docs folder
-- @author Jay Sabins
-- @version 1.1.0
-- @changelog Screenshots now go into a subfolder of Docs named after the track (Docs\<Track name>\)
-- @about
--   Select a track and run. Each plugin in that track's FX chain is opened in its
--   own window, one at a time in chain order, screenshotted, and closed again.
--   The images are saved as PNGs in Docs\<Track name>\ inside the project folder
--   (created if needed), numbered in chain order: 01_ReaEQ.png, 02_ReaComp.png...
--
--   Requires js_ReaScriptAPI (install it from ReaPack, then restart REAPER).
--   The project must be saved first so the script knows where the project folder is.
--
--   Tips: don't move the mouse over or click on the plugin windows while it runs.
--   If a plugin with a slow GUI comes out blank, raise WAIT_SECONDS at the top
--   of the script.

local r = reaper
local TITLE = "Screenshot FX Chain"

----------------------------------------------------------------------
-- USER CONFIG
----------------------------------------------------------------------
local DOCS_FOLDER_NAME   = "Docs"  -- folder created inside the project folder
local WAIT_SECONDS       = 1.0     -- time each plugin gets to draw its GUI before the shot
local TRACK_SUBFOLDER    = true    -- true = save into Docs\<Track name>\, false = straight into Docs\
local KEEP_VENDOR_IN_NAME = false  -- true = 01_ReaEQ (Cockos).png, false = 01_ReaEQ.png
local OPEN_FOLDER_WHEN_DONE = true -- open the Docs folder in Explorer when finished
local INCLUDE_OFFLINE    = false   -- offline plugins have no GUI, so they're skipped by default
----------------------------------------------------------------------

local SEP = package.config:sub(1, 1)

local function msg(s) r.ShowMessageBox(s, TITLE, 0) end

----------------------------------------------------------------------
-- Checks
----------------------------------------------------------------------
if not (r.JS_LICE_WritePNG and r.JS_GDI_Blit and r.JS_GDI_GetScreenDC) then
  msg("This script needs the js_ReaScriptAPI extension.\n\n" ..
      "1. Go to Extensions > ReaPack > Browse packages\n" ..
      "2. Search for \"js_ReaScriptAPI\"\n" ..
      "3. Right-click it > Install, then click Apply\n" ..
      "4. Restart REAPER and run this script again.")
  return
end

local track = r.GetSelectedTrack(0, 0)
if not track then
  msg("Select a track first.")
  return
end

local fxCount = r.TrackFX_GetCount(track)
if fxCount == 0 then
  msg("The selected track has no FX.")
  return
end

local _, projPath = r.EnumProjects(-1)
local projDir = projPath and projPath:match("^(.*)[\\/]")
if not projDir or projDir == "" then
  msg("Save the project first, so the script knows where the project folder is.")
  return
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function sanitize(s)
  s = s:gsub('[<>:"/\\|%?%*%c]', "_")
  s = s:gsub("^%s+", ""):gsub("[%s%.]+$", "")
  if s == "" then s = "FX" end
  return s
end

local function cleanFXName(name)
  name = name:gsub("^[%w]+:%s*", "")          -- drop "VST3: ", "CLAP: ", "JS: "...
  if not KEEP_VENDOR_IN_NAME then
    name = name:gsub("%s*%b()%s*$", "")       -- drop trailing "(Vendor)"
  end
  return sanitize(name)
end

local function trackName(tr)
  local _, name = r.GetTrackName(tr)
  return name
end

-- Keep a window fully on its monitor's work area so nothing gets cut off.
local function keepOnScreen(hwnd)
  local ok, L, T, R, B = r.JS_Window_GetRect(hwnd)
  if not ok then return end
  local sl, st, sr, sb = r.my_getViewport(0, 0, 0, 0, L, T, R, B, true)
  local w, h = R - L, B - T
  local x = math.max(sl, math.min(L, sr - w))
  local y = math.max(st, math.min(T, sb - h))
  if x ~= L or y ~= T then r.JS_Window_Move(hwnd, x, y) end
end

-- Copy what's on screen inside the window's client area into a PNG.
-- Grabbing from the screen (instead of the window itself) also works for
-- plugins that draw with the GPU, which would otherwise come out black.
local function captureWindow(hwnd, path)
  local ok, L, T, R, B = r.JS_Window_GetClientRect(hwnd)
  if not ok then return false end
  local w, h = math.abs(R - L), math.abs(B - T)
  if w < 2 or h < 2 then return false end
  local top = math.min(T, B)

  local bmp = r.JS_LICE_CreateBitmap(true, w, h)
  if not bmp then return false end
  local bmpDC = r.JS_LICE_GetDC(bmp)
  local screenDC = r.JS_GDI_GetScreenDC()
  r.JS_GDI_Blit(bmpDC, 0, 0, screenDC, L, top, w, h)
  r.JS_GDI_ReleaseDC(screenDC)
  local written = r.JS_LICE_WritePNG(path, bmp, false)
  r.JS_LICE_DestroyBitmap(bmp)
  return written
end

----------------------------------------------------------------------
-- Output folder
----------------------------------------------------------------------
local outDir = projDir .. SEP .. DOCS_FOLDER_NAME
if TRACK_SUBFOLDER then
  local tn = trackName(track)
  outDir = outDir .. SEP .. sanitize(tn)
end
r.RecursiveCreateDirectory(outDir, 0)

-- Offer to clear out numbered screenshots from an earlier run, so a chain
-- that got shorter doesn't leave old images behind.
local oldFiles = {}
local i = 0
while true do
  local f = r.EnumerateFiles(outDir, i)
  if not f then break end
  if f:match("^%d%d+_.+%.[Pp][Nn][Gg]$") then oldFiles[#oldFiles + 1] = f end
  i = i + 1
end
if #oldFiles > 0 then
  local answer = r.ShowMessageBox(
    ("The folder already has %d numbered screenshot(s) from an earlier run:\n%s\n\n" ..
     "Yes = delete them and start fresh\nNo = keep them (same names get overwritten)\nCancel = stop"):format(#oldFiles, outDir),
    TITLE, 3)
  if answer == 2 then return end
  if answer == 6 then
    for _, f in ipairs(oldFiles) do os.remove(outDir .. SEP .. f) end
  end
end

----------------------------------------------------------------------
-- Build the job list
----------------------------------------------------------------------
local jobs, skipped = {}, {}
local digits = math.max(2, #tostring(fxCount))
for fx = 0, fxCount - 1 do
  local _, name = r.TrackFX_GetFXName(track, fx, "")
  local offline = r.TrackFX_GetOffline(track, fx)
  if offline and not INCLUDE_OFFLINE then
    skipped[#skipped + 1] = ("%d. %s (offline)"):format(fx + 1, name)
  else
    jobs[#jobs + 1] = {
      fx = fx,
      name = name,
      file = ("%0" .. digits .. "d_%s.png"):format(fx + 1, cleanFXName(name)),
      wasOpen = r.TrackFX_GetFloatingWindow(track, fx) ~= nil,
    }
  end
end

----------------------------------------------------------------------
-- Run: open, wait, capture, close, one plugin at a time
----------------------------------------------------------------------
local saved, failed = {}, {}
local idx, phase, t0, hwnd = 1, "open", 0, nil

local function finish()
  local lines = { ("Saved %d screenshot(s) to:\n%s"):format(#saved, outDir) }
  if #failed > 0 then
    lines[#lines + 1] = "\nCouldn't capture:\n" .. table.concat(failed, "\n")
  end
  if #skipped > 0 then
    lines[#lines + 1] = "\nSkipped:\n" .. table.concat(skipped, "\n")
  end
  if OPEN_FOLDER_WHEN_DONE and #saved > 0 then
    if r.CF_ShellExecute then
      r.CF_ShellExecute(outDir)
    elseif SEP == "\\" then
      os.execute('start "" "' .. outDir .. '"')
    else
      os.execute('open "' .. outDir .. '"')
    end
  end
  msg(table.concat(lines, "\n"))
end

local function step()
  local job = jobs[idx]
  if not job then
    finish()
    return
  end

  local now = r.time_precise()

  if phase == "open" then
    r.TrackFX_Show(track, job.fx, 3)            -- 3 = open as floating window
    t0, hwnd, phase = now, nil, "place"

  elseif phase == "place" then
    if now - t0 >= 0.2 then
      hwnd = r.TrackFX_GetFloatingWindow(track, job.fx)
      if hwnd then
        keepOnScreen(hwnd)
        r.JS_Window_SetForeground(hwnd)
      end
      phase = "shoot"
    end

  elseif phase == "shoot" then
    if now - t0 >= WAIT_SECONDS then
      hwnd = hwnd or r.TrackFX_GetFloatingWindow(track, job.fx)
      local path = outDir .. SEP .. job.file
      if hwnd and captureWindow(hwnd, path) then
        saved[#saved + 1] = job.file
      else
        failed[#failed + 1] = ("%d. %s"):format(job.fx + 1, job.name)
      end
      if not job.wasOpen then r.TrackFX_Show(track, job.fx, 2) end  -- 2 = close floating window
      idx, phase = idx + 1, "open"
    end
  end

  r.defer(step)
end

if #jobs == 0 then
  msg("Nothing to capture. All FX on this track are offline.")
  return
end

step()
