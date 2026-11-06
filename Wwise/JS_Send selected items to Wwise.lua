-- @description Send selected items to Wwise (instant import via WAAPI)
-- @author Jay Sabins
-- @version 1.0.0
-- @changelog Initial release
-- @about
--   Select items in REAPER, select a parent in Wwise (Work Unit, Actor-Mixer,
--   virtual folder or container), run this script. Each item becomes a Sound
--   in Wwise named after the item's take name.
--
--   How it stays fast:
--   - Items that are a whole, untouched WAV file are imported straight from
--     the source file (no render at all).
--   - Everything else is rendered in ONE offline render pass (selected items),
--     with take FX, fades, trims, pitch and rate applied.
--   - Items on a folder track (empty "naming" items over a folder) render the
--     folder's mix (the folder track plus its children) for that item's time range.
--   - All files go to Wwise in ONE import call.
--
--   Needs: Wwise open with WAAPI enabled.
--   Wwise > Project > User Preferences > Wwise Authoring API:
--   tick "Enable Wwise Authoring API" and keep the HTTP port at 8090.
--   Uses curl.exe, which ships with Windows 10 and 11.
--   Your render settings are restored afterwards.

local r = reaper
local TITLE = "Send to Wwise"

----------------------------------------------------------------------
-- USER CONFIG
----------------------------------------------------------------------
local WAAPI_URL         = "http://127.0.0.1:8090/waapi"
local SKIP_RENDER_UNTOUCHED = true  -- import untouched WAV files directly (fastest)
local ITEMS_VIA_MASTER  = false     -- false: item + take FX only. true: through track FX and master.
local FOLDERS_VIA_MASTER = false    -- folder items: false = folder stem, true = through master
local MONO_TO_MONO      = true      -- mono-only items render as mono files
local IMPORT_OPERATION  = "useExisting" -- "useExisting" replaces the audio of existing Sounds with the same name
local SELECT_IN_WWISE   = true      -- select the imported Sounds in Wwise afterwards
local CURL              = "curl.exe"
----------------------------------------------------------------------

local function msg(s) r.ShowMessageBox(s, TITLE, 0) end
local SEP = package.config:sub(1, 1)

----------------------------------------------------------------------
-- Minimal JSON
----------------------------------------------------------------------
local json = {}

local function is_array(t)
  if next(t) == nil then return t.__array == true end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end

local esc_map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
                  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

function json.encode(v)
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number" then
    if v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%d", v) end
    return string.format("%.14g", v)
  elseif t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c)
      return esc_map[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif t == "table" then
    local out = {}
    if is_array(v) then
      for i = 1, #v do out[i] = json.encode(v[i]) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    for k, val in pairs(v) do
      if k ~= "__array" then out[#out + 1] = json.encode(tostring(k)) .. ":" .. json.encode(val) end
    end
    return "{" .. table.concat(out, ",") .. "}"
  end
  error("cannot encode " .. t)
end

function json.decode(s)
  local pos = 1
  local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
  local val
  local function str()
    pos = pos + 1
    local buf = {}
    while true do
      local c = s:sub(pos, pos)
      if c == "" then error("unterminated string") end
      if c == '"' then pos = pos + 1; break end
      if c == "\\" then
        local e = s:sub(pos + 1, pos + 1)
        local simple = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
        if e == "u" then
          local cp = tonumber(s:sub(pos + 2, pos + 5), 16) or 63
          if cp < 0x80 then buf[#buf + 1] = string.char(cp)
          elseif cp < 0x800 then
            buf[#buf + 1] = string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
          else
            buf[#buf + 1] = string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
          end
          pos = pos + 6
        else
          buf[#buf + 1] = simple[e] or e
          pos = pos + 2
        end
      else
        local nxt = s:find('["\\]', pos) or #s + 1
        buf[#buf + 1] = s:sub(pos, nxt - 1)
        pos = nxt
      end
    end
    return table.concat(buf)
  end
  val = function()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local o = {}
      ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1; return o end
      while true do
        ws()
        local k = str()
        ws(); pos = pos + 1 -- ':'
        o[k] = val()
        ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "}" then return o end
      end
    elseif c == "[" then
      pos = pos + 1
      local a = {}
      ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1; return a end
      while true do
        a[#a + 1] = val()
        ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "]" then return a end
      end
    elseif c == '"' then return str()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" then error("bad JSON at " .. pos) end
      pos = pos + #num
      return tonumber(num)
    end
  end
  return val()
end

----------------------------------------------------------------------
-- WAAPI over HTTP (one curl call, no console window)
----------------------------------------------------------------------
local TMP = (os.getenv("TEMP") or os.getenv("TMPDIR") or r.GetResourcePath()) .. SEP .. "JS_SendToWwise"
r.RecursiveCreateDirectory(TMP, 0)

local function waapi(uri, args, options)
  local body = json.encode({ uri = uri, args = args or {}, options = options or {} })
  local req = TMP .. SEP .. "request.json"
  local f = io.open(req, "wb")
  if not f then return nil, "Could not write " .. req end
  f:write(body); f:close()

  local cmd = string.format('%s -s -S -X POST -H "Content-Type: application/json" --data-binary "@%s" %s',
    CURL, req, WAAPI_URL)
  local out = r.ExecProcess(cmd, 60000)
  if not out then return nil, "curl did not run." end
  local code, text = out:match("^(%-?%d+)\n?(.*)$")
  code = tonumber(code)
  if code ~= 0 then
    if code == 7 or code == 28 or (text or ""):find("onnect") then
      return nil, "Couldn't reach Wwise.\n\nIs Wwise open, with WAAPI enabled?\n" ..
        "Project > User Preferences > Wwise Authoring API:\n" ..
        "tick \"Enable Wwise Authoring API\", HTTP port 8090."
    end
    return nil, "curl failed (" .. tostring(code) .. "):\n" .. tostring(text)
  end
  local ok, res = pcall(json.decode, text)
  if not ok or type(res) ~= "table" then return nil, "Unexpected reply from Wwise:\n" .. tostring(text) end
  -- WAAPI errors come back as { uri = "ak.wwise....", message = "..." }
  if type(res.uri) == "string" and res.uri:find("^ak%.") and res.message then
    local detail = res.message
    if res.details and res.details.log then detail = detail .. "\n" .. json.encode(res.details.log) end
    return nil, "Wwise error (" .. res.uri .. "):\n" .. tostring(detail), res
  end
  return res
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function near(a, b) return math.abs(a - b) < 0.0005 end

local function sanitize(name)
  name = (name or ""):gsub("%.[Ww][Aa][Vv]$", ""):gsub("[\\/:%*%?\"<>|]", "_"):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then name = "Untitled" end
  return name
end

local function take_name(item)
  local take = r.GetActiveTake(item)
  if not take then return nil end
  local _, n = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  return n
end

local function is_folder_track(tr) return r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1 end

-- Whole, unedited WAV file with nothing applied: safe to import directly.
local function untouched_source(item)
  local take = r.GetActiveTake(item)
  if not take or r.TakeIsMIDI(take) then return nil end
  local src = r.GetMediaItemTake_Source(take)
  local parent = r.GetMediaSourceParent(src)
  if parent then return nil end -- section/reversed source
  if r.GetMediaSourceType(src, ""):upper() ~= "WAVE" then return nil end
  local file = r.GetMediaSourceFileName(src, "")
  if file == "" then return nil end
  local srclen = r.GetMediaSourceLength(src)
  local gi = function(k) return r.GetMediaItemInfo_Value(item, k) end
  local gt = function(k) return r.GetMediaItemTakeInfo_Value(take, k) end
  if not near(gt("D_STARTOFFS"), 0) then return nil end
  if not near(gi("D_LENGTH"), srclen) then return nil end
  if gt("D_PLAYRATE") ~= 1 or gt("D_PITCH") ~= 0 or gt("I_CHANMODE") ~= 0 then return nil end
  if not near(gt("D_VOL"), 1) or not near(gi("D_VOL"), 1) then return nil end
  if gt("D_PAN") ~= 0 then return nil end
  if gi("D_FADEINLEN") > 0.011 or gi("D_FADEOUTLEN") > 0.011 then return nil end -- allow default tiny fades
  if gi("D_FADEINLEN_AUTO") > 0 or gi("D_FADEOUTLEN_AUTO") > 0 then return nil end
  if r.TakeFX_GetCount(take) > 0 then return nil end
  if r.CountTakeEnvelopes(take) > 0 then
    for e = 0, r.CountTakeEnvelopes(take) - 1 do
      local env = r.GetTakeEnvelope(take, e)
      if r.CountEnvelopePoints(env) > 0 then return nil end
    end
  end
  if r.GetTakeNumStretchMarkers(take) > 0 then return nil end
  return file
end

----------------------------------------------------------------------
-- Render (saves and restores the project's render settings)
----------------------------------------------------------------------
local NUM_KEYS = { "RENDER_SETTINGS", "RENDER_BOUNDSFLAG", "RENDER_STARTPOS", "RENDER_ENDPOS",
                   "RENDER_ADDTOPROJ", "RENDER_TAILFLAG" }
local STR_KEYS = { "RENDER_FILE", "RENDER_PATTERN", "RENDER_FORMAT" }
local WAV24 = "ZXZhdxgAAQ==" -- WAV, 24-bit PCM

local function save_render_settings()
  local s = { num = {}, str = {} }
  for _, k in ipairs(NUM_KEYS) do s.num[k] = r.GetSetProjectInfo(0, k, 0, false) end
  for _, k in ipairs(STR_KEYS) do s.str[k] = select(2, r.GetSetProjectInfo_String(0, k, "", false)) end
  return s
end

local function restore_render_settings(s)
  for k, v in pairs(s.num) do r.GetSetProjectInfo(0, k, v, true) end
  for k, v in pairs(s.str) do r.GetSetProjectInfo_String(0, k, v, true) end
end

local function render_now()
  -- File: Render project, using the most recent render settings, auto-close render dialog
  r.Main_OnCommand(42230, 0)
end

local function set_selected_items(list)
  r.SelectAllMediaItems(0, false)
  for _, it in ipairs(list) do r.SetMediaItemSelected(it, true) end
end

local function file_exists(p)
  local f = io.open(p, "rb")
  if f then f:close(); return true end
  return false
end

----------------------------------------------------------------------
-- Main
----------------------------------------------------------------------
local function main()
  local n = r.CountSelectedMediaItems(0)
  if n == 0 then msg("Select one or more items first."); return end

  -- 1. Where in Wwise?
  local sel, err = waapi("ak.wwise.ui.getSelectedObjects", {}, { ["return"] = { "path", "type", "name" } })
  if not sel then msg(err); return end
  local objs = sel.objects or {}
  if #objs == 0 then
    msg("Select a parent in Wwise first (a Work Unit, Actor-Mixer, virtual folder or container).")
    return
  end
  local target = objs[1]
  local parent_path = target.path
  if target.type == "Sound" or target.type == "AudioFileSource" then
    parent_path = parent_path:match("^(.*)\\[^\\]+$") -- import next to the selected Sound
  end
  if not parent_path or parent_path:find("^\\Events") or parent_path:find("^\\Switches")
     or parent_path:find("^\\Game Parameters") or parent_path:find("^\\SoundBanks") then
    msg("The object selected in Wwise (" .. tostring(target.name) .. ") can't hold Sounds.\n" ..
        "Select a Work Unit, Actor-Mixer, virtual folder or container.")
    return
  end

  -- 2. Sort items into: direct import, item render, folder render.
  local direct, to_render, folder_items, all = {}, {}, {}, {}
  local orig_sel = {}
  for i = 0, n - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    orig_sel[#orig_sel + 1] = it
    local tr = r.GetMediaItem_Track(it)
    local name = take_name(it)
    if not name or name == "" then
      local _, notes = r.GetSetMediaItemInfo_String(it, "P_NOTES", "", false)
      name = notes:match("[^\r\n]+") or ("Item_" .. (i + 1))
    end
    local entry = { item = it, name = sanitize(name) }
    all[#all + 1] = entry
    if is_folder_track(tr) and (not r.GetActiveTake(it)) then
      entry.track = tr
      folder_items[#folder_items + 1] = entry
    else
      local file = SKIP_RENDER_UNTOUCHED and untouched_source(it)
      if file then entry.file = file; direct[#direct + 1] = entry
      else to_render[#to_render + 1] = entry end
    end
  end

  -- unique Wwise names inside this batch
  local seen = {}
  for _, e in ipairs(all) do
    local base, k = e.name, 1
    while seen[e.name:lower()] do k = k + 1; e.name = string.format("%s_%02d", base, k) end
    seen[e.name:lower()] = true
  end

  -- 3. Render what needs rendering into a fresh temp folder.
  local outdir = TMP .. SEP .. os.time() .. "_" .. math.random(1000, 9999)
  local rendered_files = {}
  if #to_render + #folder_items > 0 then
    r.RecursiveCreateDirectory(outdir, 0)
    local saved = save_render_settings()
    local cursor = r.GetCursorPosition()
    local saved_tracks = {}
    for t = 0, r.CountSelectedTracks(0) - 1 do saved_tracks[#saved_tracks + 1] = r.GetSelectedTrack(0, t) end
    local saved_names = {}

    r.PreventUIRefresh(1)
    local ok, perr = pcall(function()
      r.GetSetProjectInfo_String(0, "RENDER_FILE", outdir, true)
      r.GetSetProjectInfo_String(0, "RENDER_FORMAT", WAV24, true)
      r.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, true)
      r.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, true)

      -- 3a. Regular items: one render pass. Each take gets a temporary unique
      -- name so every output file maps back to its item exactly.
      if #to_render > 0 then
        for i, e in ipairs(to_render) do
          local take = r.GetActiveTake(e.item)
          if take then
            saved_names[take] = select(2, r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false))
            e.token = string.format("JSWW_%04d", i)
            r.GetSetMediaItemTakeInfo_String(take, "P_NAME", e.token, true)
          end
        end
        set_selected_items((function() local l = {} for _, e in ipairs(to_render) do l[#l + 1] = e.item end return l end)())
        local flags = ITEMS_VIA_MASTER and 64 or 32
        if MONO_TO_MONO then flags = flags | 16 end
        r.GetSetProjectInfo(0, "RENDER_SETTINGS", flags, true)
        r.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 4, true) -- selected media items
        r.GetSetProjectInfo_String(0, "RENDER_PATTERN", "$item", true)
        render_now()
        for take, nm in pairs(saved_names) do r.GetSetMediaItemTakeInfo_String(take, "P_NAME", nm, true) end
        saved_names = {}
        for _, e in ipairs(to_render) do
          local p = e.token and (outdir .. SEP .. e.token .. ".wav")
          if p and file_exists(p) then e.file = p end
        end
      end

      -- 3b. Folder items: render the folder track's mix over each item's time range.
      for i, e in ipairs(folder_items) do
        local pos = r.GetMediaItemInfo_Value(e.item, "D_POSITION")
        local len = r.GetMediaItemInfo_Value(e.item, "D_LENGTH")
        r.SetOnlyTrackSelected(e.track)
        r.GetSetProjectInfo(0, "RENDER_SETTINGS", FOLDERS_VIA_MASTER and 128 or 2, true)
        r.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, true) -- custom time bounds
        r.GetSetProjectInfo(0, "RENDER_STARTPOS", pos, true)
        r.GetSetProjectInfo(0, "RENDER_ENDPOS", pos + len, true)
        e.token = string.format("JSWWF_%04d", i)
        r.GetSetProjectInfo_String(0, "RENDER_PATTERN", e.token, true)
        render_now()
        local p = outdir .. SEP .. e.token .. ".wav"
        if file_exists(p) then e.file = p end
      end
    end)
    for take, nm in pairs(saved_names) do r.GetSetMediaItemTakeInfo_String(take, "P_NAME", nm, true) end
    restore_render_settings(saved)
    set_selected_items(orig_sel)
    r.Main_OnCommand(40297, 0) -- unselect all tracks
    for _, tr in ipairs(saved_tracks) do r.SetTrackSelected(tr, true) end
    r.SetEditCurPos(cursor, false, false)
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
    if not ok then msg("Render failed:\n" .. tostring(perr)); return end

    -- Rename rendered files to the item names (Wwise names its Originals after the file).
    for _, list in ipairs({ to_render, folder_items }) do
      for _, e in ipairs(list) do
        if e.file then
          local final = outdir .. SEP .. e.name .. ".wav"
          if os.rename(e.file, final) then e.file = final end
          rendered_files[#rendered_files + 1] = e.file
        end
      end
    end
  end

  -- 4. One import call for everything.
  local imports, missing = {}, {}
  for _, e in ipairs(all) do
    if e.file then
      imports[#imports + 1] = { audioFile = e.file, objectPath = "" , _name = e.name }
    else
      missing[#missing + 1] = e.name
    end
  end
  if #imports == 0 then msg("Nothing was rendered, so nothing was sent to Wwise."); return end

  local function build(sound_tag)
    local list = {}
    for i, im in ipairs(imports) do
      list[i] = { audioFile = im.audioFile, objectPath = parent_path .. "\\" .. sound_tag .. im._name }
    end
    return {
      importOperation = IMPORT_OPERATION,
      default = { importLanguage = "SFX" },
      imports = list,
      autoAddToSourceControl = true,
    }
  end

  local res, ierr = waapi("ak.wwise.core.audio.import", build("<Sound SFX>"), { ["return"] = { "id", "path" } })
  if not res then
    -- Newer Wwise versions call the type "Sound" instead of "Sound SFX".
    local res2 = waapi("ak.wwise.core.audio.import", build("<Sound>"), { ["return"] = { "id", "path" } })
    if res2 then res, ierr = res2, nil end
  end
  if not res then msg(ierr); return end

  -- Clean up rendered temp files (Wwise has copied them into its Originals folder).
  for _, p in ipairs(rendered_files) do os.remove(p) end
  os.remove(outdir)

  if SELECT_IN_WWISE and res.objects and #res.objects > 0 then
    local ids = {}
    for _, o in ipairs(res.objects) do if o.id then ids[#ids + 1] = o.id end end
    if #ids > 0 then
      waapi("ak.wwise.ui.commands.execute", { command = "FindInProjectExplorerSyncGroup1", objects = ids })
    end
  end

  if #missing > 0 then
    msg(string.format("Sent %d item(s) to Wwise.\n\nThese didn't render and were skipped:\n%s",
      #imports, table.concat(missing, "\n")))
  end
end

math.randomseed(os.time())
r.Undo_BeginBlock()
main()
r.Undo_EndBlock("Send selected items to Wwise", -1)
