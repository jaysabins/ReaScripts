-- Wwise Tool: shared core (loaded by the Wwise Tool scripts; not an action)
-- Author: Jay Sabins

local r = reaper
local M = {}

M.EXT = "jsabins_WwiseTool"
-- Key used before the rename from "Wwise Transfer" (up to 1.8.1). Global settings
-- are copied over once; per-project settings are read from it when a project has
-- none under the new key yet.
M.OLD_EXT = "JS_WwiseTransfer"
M.VERSION = "1.12.3"

for _, key in ipairs({ "last_settings", "presets", "view" }) do
  if r.GetExtState(M.EXT, key) == "" then
    local old = r.GetExtState(M.OLD_EXT, key)
    if old ~= "" then r.SetExtState(M.EXT, key, old, true) end
  end
end
local SEP = package.config:sub(1, 1)
local IS_WIN = SEP == "\\"

----------------------------------------------------------------------
-- JSON
----------------------------------------------------------------------
local json = {}
M.json = json

local function is_array(t)
  if next(t) == nil then return getmetatable(t) == json.array_mt end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end
json.array_mt = {}
function json.array(t) return setmetatable(t or {}, json.array_mt) end

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
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do out[#out + 1] = json.encode(k) .. ":" .. json.encode(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
  end
  error("cannot encode " .. t)
end

function json.decode(s)
  local pos = 1
  local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
  local simple = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
  local function utf8char(cp)
    if cp < 0x80 then return string.char(cp)
    elseif cp < 0x800 then return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
    elseif cp < 0x10000 then
      return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
    end
    return string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
  end
  local function str()
    pos = pos + 1
    local buf = {}
    while true do
      local c = s:sub(pos, pos)
      if c == "" then error("unterminated string") end
      if c == '"' then pos = pos + 1; break end
      if c == "\\" then
        local e = s:sub(pos + 1, pos + 1)
        if e == "u" then
          local cp = tonumber(s:sub(pos + 2, pos + 5), 16) or 63
          pos = pos + 6
          if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
            local lo = tonumber(s:sub(pos + 2, pos + 5), 16) or 0
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
            pos = pos + 6
          end
          buf[#buf + 1] = utf8char(cp)
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
  local val
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
        if d ~= "," then error("bad JSON object at " .. pos) end
      end
    elseif c == "[" then
      pos = pos + 1
      local a = json.array()
      ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1; return a end
      while true do
        a[#a + 1] = val()
        ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "]" then return a end
        if d ~= "," then error("bad JSON array at " .. pos) end
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

-- The file Wwise will keep in Originals for an entry, relative to Originals\SFX (or
-- Originals\Voices\<language>): "<originals subfolder>\<file name>". Wwise keeps the
-- imported file's own name, so a WAV imported straight from disk keeps its name on disk.
function M.originals_name(e)
  local f
  if e.kind == "direct" and e.file then f = e.file:match("([^\\/]+)$")
  elseif e.kind == "project" and e.target then f = e.target:match("([^\\/]+)$")
  elseif (e.name or "") ~= "" then f = e.name .. ".wav" end
  if not f then return nil end
  if e.origsub and e.origsub ~= "" then return e.origsub .. "\\" .. f end
  return f
end

function M.originals_root(s)
  if s.leaf.voice then return "Voices\\" .. ((s.leaf.language or "") ~= "" and s.leaf.language or "<language>") end
  return "SFX"
end

-- Folder of the current project file (or REAPER's project path for an unsaved project).
function M.project_dir()
  local _, fn = r.EnumProjects(-1)
  local d = fn and fn ~= "" and fn:match("^(.*)[\\/]") or nil
  if not d or d == "" then d = r.GetProjectPath() end
  return d
end

-- Split the "Keep rendered files in" setting into a real folder and a wildcard part for
-- RENDER_PATTERN: "Renders\$project\$region" -> "<project folder>\Renders", "$project/$region".
-- A relative path is relative to the project folder. Returns nil when renders are temporary.
function M.render_folder_parts(s)
  local f = (s.render_folder or ""):gsub("^%s+", ""):gsub("[%s\\/]+$", "")
  if f == "" then return nil end
  local absolute = f:match("^%a:") or f:match("^[\\/]")
  local segs = {}
  for seg in (f .. "\\"):gmatch("(.-)[\\/]") do segs[#segs + 1] = seg end
  local fixed, rest = {}, {}
  for _, seg in ipairs(segs) do
    if #rest > 0 or seg:find("$", 1, true) then rest[#rest + 1] = seg else fixed[#fixed + 1] = seg end
  end
  local base = table.concat(fixed, SEP)
  if not absolute then base = M.project_dir() .. (base ~= "" and (SEP .. base) or "") end
  if base == "" then base = SEP end
  return base, table.concat(rest, "/")
end

----------------------------------------------------------------------
-- Settings (per project, with a global fallback) and presets
----------------------------------------------------------------------
M.CONTAINER_TYPES = { "Virtual Folder", "Actor-Mixer", "Random Container", "Sequence Container",
                      "Switch Container", "Blend Container", "Work Unit", "Physical Folder" }
M.CONFLICT_OPS = { { "useExisting", "Use existing (replace audio, keep object)" },
                   { "replaceExisting", "Replace (delete and re-create)" },
                   { "createNew", "Create new (rename new objects)" } }
M.DELAY_TARGETS = { { "container", "Layer containers (level above the Sounds)" }, { "sound", "Each Sound" } }
M.TEMPLATE_OPS = { { "always", "All objects (new and existing)" }, { "new", "New objects only" } }

function M.default_settings()
  return {
    source = "items",                -- "items" (selected items) or "render" (REAPER render settings)
    skip_render_untouched = true,
    items_via_master = false,
    folders_via_master = false,
    mono_to_mono = true,             -- Auto channels: a sound whose left and right match becomes mono
    channels = {},                   -- channel overrides: { [lowercase path below the destination] = "mono"|"stereo" }
    use_wwise_selection = true,      -- destination = Wwise selection at transfer time
    destination = "",
    originals_subfolder = "",
    render_folder = "",              -- keep item renders here ("" = temp folder, deleted after transfer)
    rows = {},                       -- { { type=, name=, template= } }  containers, top to bottom
    leaf = { voice = false, name = "", template = "", language = "" },
    conflict = "useExisting",
    apply_template = "always",
    select_in_wwise = true,
    set_initial_delay = false,       -- write layer timing into Wwise's Initial Delay
    delay_target = "container",      -- "container" (level above the Sounds) or "sound"
    http_port = 8090,
  }
end

local function merge_defaults(s)
  local d = M.default_settings()
  if type(s) ~= "table" then return d end
  for k, v in pairs(d) do if s[k] == nil then s[k] = v end end
  if type(s.leaf) ~= "table" then s.leaf = d.leaf end
  for k, v in pairs(d.leaf) do if s.leaf[k] == nil then s.leaf[k] = v end end
  if type(s.rows) ~= "table" then s.rows = {} end
  if type(s.channels) ~= "table" then s.channels = {} end
  if s.port and s.http_port == 8090 then s.http_port = s.port end -- settings from 1.0.x
  s.port = nil
  return s
end

function M.load_settings()
  local _, s = r.GetProjExtState(0, M.EXT, "settings")
  if s == "" then _, s = r.GetProjExtState(0, M.OLD_EXT, "settings") end
  if s ~= "" then
    local good, t = pcall(json.decode, s)
    if good then return merge_defaults(t) end
  end
  local g = r.GetExtState(M.EXT, "last_settings")
  if g ~= "" then
    local good, t = pcall(json.decode, g)
    if good then return merge_defaults(t) end
  end
  return M.default_settings()
end

-- Saved in the project (so it comes back with the project) and as the default
-- for projects that don't have their own yet. `proj` defaults to the current project.
function M.save_settings(s, proj)
  proj = proj or 0
  local txt = json.encode(s)
  local _, old = r.GetProjExtState(proj, M.EXT, "settings")
  if old ~= txt then r.SetProjExtState(proj, M.EXT, "settings", txt) end
  r.SetExtState(M.EXT, "last_settings", txt, true)
end

-- Presets come in two kinds, saved separately and the same in every project:
--   "structure": the Wwise structure only (levels with their names and templates, and the Sound row).
--   "settings":  everything else that shapes a transfer (source, destination, Originals subfolder,
--                conflict choice, Initial Delay, render and transfer options).
-- The connection port and the preview's Mono/Stereo overrides are never part of a preset.
M.SETTINGS_PRESET_KEYS = { "source", "use_wwise_selection", "destination", "originals_subfolder",
  "conflict", "set_initial_delay", "delay_target", "skip_render_untouched", "items_via_master",
  "folders_via_master", "mono_to_mono", "render_folder", "apply_template", "select_in_wwise" }
local PRESET_KEYS = { structure = "structure_presets", settings = "settings_presets" }

local function read_table(key)
  local p = r.GetExtState(M.EXT, key)
  if p == "" then return {} end
  local ok, t = pcall(json.decode, p)
  return ok and type(t) == "table" and t or {}
end

local function structure_part(p)
  local rows = {}
  for i, row in ipairs(p.rows or {}) do
    rows[i] = { type = row.type, name = row.name or "", template = row.template or "" }
  end
  local leaf = {}
  for k, v in pairs(type(p.leaf) == "table" and p.leaf or {}) do leaf[k] = v end
  return { rows = rows, leaf = leaf }
end

-- Up to 1.10.0 one preset held the structure plus the Originals subfolder, conflict choice
-- and template option. The first time, each old preset becomes a structure preset and a
-- settings preset with the same name. The old list is left as it was.
local function split_old_presets()
  if r.GetExtState(M.EXT, "presets_split") == "1" then return end
  local old = read_table("presets")
  local structure, settings = read_table(PRESET_KEYS.structure), read_table(PRESET_KEYS.settings)
  for name, p in pairs(old) do
    if type(p) == "table" then
      if structure[name] == nil then structure[name] = structure_part(p) end
      local rest = {}
      for _, k in ipairs(M.SETTINGS_PRESET_KEYS) do rest[k] = p[k] end
      if settings[name] == nil and next(rest) then settings[name] = rest end
    end
  end
  if next(structure) then r.SetExtState(M.EXT, PRESET_KEYS.structure, json.encode(structure), true) end
  if next(settings) then r.SetExtState(M.EXT, PRESET_KEYS.settings, json.encode(settings), true) end
  r.SetExtState(M.EXT, "presets_split", "1", true)
end

-- kind: "structure" or "settings"
function M.load_presets(kind)
  split_old_presets()
  return read_table(PRESET_KEYS[kind])
end

function M.save_presets(kind, p) r.SetExtState(M.EXT, PRESET_KEYS[kind], json.encode(p), true) end

function M.preset_from(kind, s)
  if kind == "structure" then return structure_part(s) end
  local p = {}
  for _, k in ipairs(M.SETTINGS_PRESET_KEYS) do p[k] = s[k] end
  return p
end

-- Loading a preset changes only its own kind of settings. A settings preset only sets
-- what it has (one split from an old preset has just a few of them).
function M.apply_preset(kind, s, p)
  if kind == "structure" then
    local st = structure_part(p)
    s.rows = st.rows
    for k, v in pairs(st.leaf) do s.leaf[k] = v end
    return
  end
  for _, k in ipairs(M.SETTINGS_PRESET_KEYS) do
    if p[k] ~= nil then s[k] = p[k] end
  end
end

----------------------------------------------------------------------
-- WAAPI over HTTP (curl, run hidden through ExecProcess)
----------------------------------------------------------------------
local TMP = (os.getenv("TEMP") or os.getenv("TMPDIR") or r.GetResourcePath()) .. SEP .. M.EXT
r.RecursiveCreateDirectory(TMP, 0)
M.TMP = TMP
M.http_port = 8090

local function format_error(uri, kw)
  local detail = (type(kw) == "table" and kw.message) or uri or "unknown error"
  if type(kw) == "table" and kw.details and kw.details.log then
    local lines = {}
    for _, l in ipairs(kw.details.log) do lines[#lines + 1] = type(l) == "table" and (l.message or json.encode(l)) or tostring(l) end
    detail = detail .. "\n" .. table.concat(lines, "\n")
  end
  return detail
end

local CURL = IS_WIN and "curl.exe" or "/usr/bin/curl"

local function parse_reply(exit_code, text, http)
  if exit_code ~= 0 or http == 0 then
    if exit_code == 28 then
      return nil, "Wwise is busy and didn't answer in time.", "busy"
    end
    if exit_code == 7 or http == 0 or (text or ""):find("onnect") then
      return nil, "Couldn't reach Wwise. Is Wwise open with WAAPI enabled? " ..
        "(Project > User Preferences > Enable Wwise Authoring API, HTTP port " .. tostring(M.http_port) .. ")", "offline"
    end
    return nil, "curl failed (" .. tostring(exit_code) .. "): " .. tostring(text)
  end
  if http == 404 or http == 403 or http == 400 or http == 426 then
    return nil, "Wwise refused the connection (HTTP " .. http .. "). In Wwise > Project > User Preferences > " ..
      "Wwise Authoring API, set \"Allow connections from\" to 127.0.0.1,::1 and make sure the WAMP and HTTP " ..
      "ports are different (defaults 8080 and 8090). Then restart Wwise.", "offline"
  end
  if text == nil or text == "" then return {} end
  local ok, res = pcall(json.decode, text)
  if not ok or type(res) ~= "table" then return nil, "Unexpected reply from Wwise: " .. tostring(text) end
  if type(res.uri) == "string" and res.uri:find("^ak%.") and res.message then
    return nil, format_error(res.uri, res), res.uri
  end
  return res
end

local req_counter = 0
local function write_request(uri, args, options)
  req_counter = req_counter + 1
  local base = TMP .. SEP .. "req" .. req_counter % 1000
  local f = io.open(base .. ".json", "wb")
  if not f then return nil end
  f:write(json.encode({ uri = uri, args = args or {}, options = options or {} })); f:close()
  return base
end

local function curl_args(base, timeout)
  return string.format('-s -S --max-time %g -X POST -H "Content-Type: application/json" --data-binary "@%s.json" http://127.0.0.1:%d/waapi',
    timeout, base, math.floor(tonumber(M.http_port) or 8090))
end

-- Blocking, hidden call. `timeout` (seconds, default 120) caps how long REAPER waits;
-- running out returns the error code "busy".
local function waapi_http(uri, args, options, timeout)
  timeout = timeout or 120
  local base = write_request(uri, args, options)
  if not base then return nil, "Could not write a temp file in " .. TMP end
  -- The reply body goes to a file, not stdout: REAPER doesn't drain the stdout pipe
  -- while it waits, so a big reply (like an import's) made curl block until the
  -- ExecProcess timeout. Only the short status line comes back on stdout.
  os.remove(base .. ".out")
  local out = r.ExecProcess(CURL .. ' -o "' .. base .. '.out" -w "HTTP=%{http_code}" ' .. curl_args(base, timeout),
    math.floor((timeout + 5) * 1000))
  os.remove(base .. ".json")
  local body
  local bf = io.open(base .. ".out", "rb")
  if bf then body = bf:read("*a"); bf:close(); os.remove(base .. ".out") end
  if not out then return nil, "curl did not run." end
  local code, text = out:match("^(%-?%d+)\r?\n?(.*)$")
  local http = tonumber((text or ""):match("HTTP=(%d+)%s*$"))
  text = (text or ""):gsub("HTTP=%d+%s*$", "")
  if http and http > 0 then text = body or "" end -- otherwise keep curl's error message
  return parse_reply(tonumber(code), text, http)
end

function M.disconnect() end

function M.waapi(uri, args, options, timeout)
  return waapi_http(uri, args, options, timeout)
end

-- Connection info: version, project name, languages, root path.
-- `timeout` caps each call (default: the usual long WAAPI timeout). Inside a coroutine
-- (the window) it yields between calls, so each frame waits for at most one call.
function M.connect(timeout)
  local function pause() if coroutine.isyieldable() then coroutine.yield() end end
  local info, err, code = M.waapi("ak.wwise.core.getInfo", nil, nil, timeout)
  if not info then return nil, err, code end
  local v = info.version or {}
  local c = {
    year = tonumber(v.year) or 0,
    -- getInfo's displayName is just "Wwise"; the numbers are in version.
    version = v.year and string.format("Wwise %s.%s.%s", v.year, v.major or 0, v.minor or 0)
      or (v.displayName and ("Wwise " .. tostring(v.displayName):gsub("^v", ""))) or info.displayName or "Wwise",
  }
  c.new_types = c.year >= 2025  -- Wwise 2025.1+: "Sound" type, "Containers" root
  c.root = c.new_types and "\\Containers" or "\\Actor-Mixer Hierarchy"
  pause()
  local p = M.waapi("ak.wwise.core.object.get", { from = { ofType = { "Project" } } }, { ["return"] = { "name", "filePath" } }, timeout)
  if p and p["return"] and p["return"][1] then
    c.project = p["return"][1].name
    c.project_path = p["return"][1].filePath
  end
  c.languages = {}
  pause()
  local l = M.waapi("ak.wwise.core.object.get", { from = { ofType = { "Language" } } }, { ["return"] = { "name" } }, timeout)
  if l and l["return"] then
    for _, o in ipairs(l["return"]) do
      if o.name ~= "SFX" and o.name ~= "External" and o.name ~= "Mixed" then c.languages[#c.languages + 1] = o.name end
    end
    table.sort(c.languages)
  end
  return c
end

-- First object selected in Wwise, as a path usable as an import destination.
function M.wwise_selection_path(timeout)
  local sel, err, code = M.waapi("ak.wwise.ui.getSelectedObjects", {}, { ["return"] = { "path", "type", "name" } }, timeout)
  if not sel then return nil, err, code end
  local o = sel.objects and sel.objects[1]
  if not o then return nil, "Nothing is selected in Wwise." end
  local path = o.path
  if o.type == "Sound" or o.type == "AudioFileSource" or o.type == "MusicTrack" then
    path = path:match("^(.*)\\[^\\]+$") -- use its parent
  end
  return path, nil, o
end

-- The Wwise project's Originals folder on disk. Asks Wwise (2021.1+), else assumes
-- <project folder>\Originals.
function M.wwise_originals_dir(conn)
  local info = M.waapi("ak.wwise.core.getProjectInfo", {}, nil, 3)
  local d = info and info.directories and info.directories.originals
  if (not d or d == "") and conn and conn.project_path then
    d = conn.project_path:match("^(.*)[\\/][^\\/]*$")
    if d then d = d .. "\\Originals" end
  end
  if not d or d == "" then return nil end
  return (d:gsub("/", "\\"):gsub("\\+$", ""))
end

-- "D:\Game\Originals\SFX\Weapons\Pistol" relative to "D:\Game\Originals\SFX" -> "Weapons\Pistol".
-- Returns "" for the root itself and nil for a folder outside it.
function M.relative_to(path, root)
  local function norm(p) return ((p or ""):gsub("/", "\\"):gsub("\\+$", "")) end
  path, root = norm(path), norm(root)
  if path:lower() == root:lower() then return "" end
  if path:sub(1, #root + 1):lower() == (root .. "\\"):lower() then return path:sub(#root + 2) end
  return nil
end

-- Folder picker. Uses the js_ReaScriptAPI extension when it's installed, otherwise Windows'
-- own folder dialog through PowerShell (nothing extra to install). `starts` is a list of
-- folders to open at; the first one that exists is used. Returns the folder, or nil.
function M.browse_folder(title, starts)
  if r.JS_Dialog_BrowseForFolder then
    local start = starts[1] or ""
    local ok, f = r.JS_Dialog_BrowseForFolder(title, start)
    if ok == 1 and f and f ~= "" then return f end
    return nil
  end
  if not r.GetOS():match("^Win") then return nil, "The folder picker needs Windows or the js_ReaScriptAPI extension." end
  local base = TMP .. SEP .. "browse_" .. math.random(100000, 999999)
  local function q(s) return "'" .. (s or ""):gsub("'", "''") .. "'" end
  local list = {}
  for i, p in ipairs(starts) do list[i] = q(p) end
  local ps = table.concat({
    "Add-Type -AssemblyName System.Windows.Forms",
    "$d = New-Object System.Windows.Forms.FolderBrowserDialog",
    "$d.Description = " .. q(title),
    "$d.ShowNewFolderButton = $true",
    "foreach ($p in @(" .. table.concat(list, ",") .. ")) { if ($p -and (Test-Path -LiteralPath $p)) { $d.SelectedPath = $p; break } }",
    "$owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false }",
    "$res = $d.ShowDialog($owner)",
    "if ($res -eq [System.Windows.Forms.DialogResult]::OK) { [IO.File]::WriteAllText(" .. q(base .. ".txt") ..
      ", $d.SelectedPath, (New-Object System.Text.UTF8Encoding $false)) }",
  }, "\r\n")
  local f = io.open(base .. ".ps1", "wb")
  if not f then return nil, "Couldn't write the folder picker script to " .. TMP end
  f:write("\239\187\191", ps) -- UTF-8 BOM, so PowerShell reads non-English folder names correctly
  f:close()
  r.ExecProcess('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' ..
    base .. '.ps1"', 600000)
  local out
  local rf = io.open(base .. ".txt", "rb")
  if rf then out = rf:read("*a"); rf:close() end
  os.remove(base .. ".ps1"); os.remove(base .. ".txt")
  if out and out ~= "" then return out end
  return nil
end

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function near(a, b) return math.abs(a - b) < 0.0005 end

function M.sanitize(name)
  name = (name or ""):gsub("[\\/:%*%?\"<>|]", "_"):gsub("^%s+", ""):gsub("%s+$", "")
  return name
end

local function file_exists(p)
  local f = io.open(p, "rb")
  if f then f:close(); return true end
  return false
end

local function split(s, sep)
  local out = {}
  for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = part end
  return out
end

local function basename_noext(p) return (p:match("([^\\/]+)$") or p):gsub("%.[^.]+$", "") end
local function dirname(p) return p:match("^(.*)[\\/][^\\/]*$") or "" end

local function take_name(item)
  local take = r.GetActiveTake(item)
  if take then
    local _, n = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    if n ~= "" then return n:gsub("%.[Ww][Aa][Vv][Ee]?$", "") end
  end
  local _, notes = r.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
  return notes:match("[^\r\n]+")
end

local function source_channels(item)
  local take = r.GetActiveTake(item)
  if not take or r.TakeIsMIDI(take) then return nil end
  return r.GetMediaSourceNumChannels(r.GetMediaItemTake_Source(take))
end

local function is_folder_item(item)
  local tr = r.GetMediaItem_Track(item)
  return r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1 and r.GetActiveTake(item) == nil
end

-- Whole, unedited WAV with nothing applied: safe to import straight from disk.
function M.untouched_source(item)
  local take = r.GetActiveTake(item)
  if not take or r.TakeIsMIDI(take) then return nil end
  local src = r.GetMediaItemTake_Source(take)
  if r.GetMediaSourceParent(src) then return nil end
  if r.GetMediaSourceType(src, ""):upper() ~= "WAVE" then return nil end
  local file = r.GetMediaSourceFileName(src, "")
  if file == "" or not file_exists(file) then return nil end
  local srclen = r.GetMediaSourceLength(src)
  local gi = function(k) return r.GetMediaItemInfo_Value(item, k) end
  local gt = function(k) return r.GetMediaItemTakeInfo_Value(take, k) end
  if not near(gt("D_STARTOFFS"), 0) or not near(gi("D_LENGTH"), srclen) then return nil end
  if gt("D_PLAYRATE") ~= 1 or gt("D_PITCH") ~= 0 or gt("I_CHANMODE") ~= 0 then return nil end
  if not near(gt("D_VOL"), 1) or not near(gi("D_VOL"), 1) or gt("D_PAN") ~= 0 then return nil end
  if gi("D_FADEINLEN") > 0.011 or gi("D_FADEOUTLEN") > 0.011 then return nil end
  if gi("D_FADEINLEN_AUTO") > 0 or gi("D_FADEOUTLEN_AUTO") > 0 then return nil end
  if r.TakeFX_GetCount(take) > 0 or r.GetTakeNumStretchMarkers(take) > 0 then return nil end
  for e = 0, r.CountTakeEnvelopes(take) - 1 do
    if r.CountEnvelopePoints(r.GetTakeEnvelope(take, e)) > 0 then return nil end
  end
  return file
end

----------------------------------------------------------------------
-- Render settings juggling
-- Wildcards are resolved by REAPER itself: we set RENDER_PATTERN to a
-- pattern and read RENDER_TARGETS back (no render happens).
----------------------------------------------------------------------
local NUM_KEYS = { "RENDER_SETTINGS", "RENDER_BOUNDSFLAG", "RENDER_STARTPOS", "RENDER_ENDPOS",
                   "RENDER_ADDTOPROJ", "RENDER_TAILFLAG", "RENDER_CHANNELS", "RENDER_DITHER" }
local STR_KEYS = { "RENDER_FILE", "RENDER_PATTERN", "RENDER_FORMAT" }
local WAV24 = "ZXZhdxgAAQ==" -- WAV, 24-bit PCM

local function get_s(k) return select(2, r.GetSetProjectInfo_String(0, k, "", false)) end
local function set_s(k, v) r.GetSetProjectInfo_String(0, k, v, true) end
local function get_n(k) return r.GetSetProjectInfo(0, k, 0, false) end
local function set_n(k, v) r.GetSetProjectInfo(0, k, v, true) end

local function snapshot()
  local s = { num = {}, str = {}, items = {}, tracks = {}, names = {} }
  for _, k in ipairs(NUM_KEYS) do s.num[k] = get_n(k) end
  for _, k in ipairs(STR_KEYS) do s.str[k] = get_s(k) end
  for i = 0, r.CountSelectedMediaItems(0) - 1 do s.items[#s.items + 1] = r.GetSelectedMediaItem(0, i) end
  for i = 0, r.CountSelectedTracks(0) - 1 do s.tracks[#s.tracks + 1] = r.GetSelectedTrack(0, i) end
  s.cursor = r.GetCursorPosition()
  return s
end

local function select_items(list)
  r.SelectAllMediaItems(0, false)
  for _, it in ipairs(list) do r.SetMediaItemSelected(it, true) end
end

local function rename_take(take, snap, name)
  if not snap.names[take] then snap.names[take] = select(2, r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)) end
  r.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true)
end

local function restore(s)
  for take, nm in pairs(s.names) do
    if r.ValidatePtr(take, "MediaItem_Take*") then r.GetSetMediaItemTakeInfo_String(take, "P_NAME", nm, true) end
  end
  for k, v in pairs(s.num) do if get_n(k) ~= v then set_n(k, v) end end
  for k, v in pairs(s.str) do if get_s(k) ~= v then set_s(k, v) end end
  select_items(s.items)
  r.Main_OnCommand(40297, 0) -- Track: Unselect all tracks
  for _, tr in ipairs(s.tracks) do r.SetTrackSelected(tr, true) end
  r.SetEditCurPos(s.cursor, false, false)
end

local function with_temp_state(fn)
  local s = snapshot()
  r.PreventUIRefresh(1)
  local ok, a, b = pcall(fn, s)
  restore(s)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  if not ok then return nil, tostring(a) end
  return a, b
end

local function targets_for(pattern)
  set_s("RENDER_PATTERN", pattern)
  local t = get_s("RENDER_TARGETS")
  if t == "" then return {} end
  return split(t, ";")
end

-- Resolve `pattern` (which must not be empty) for every render target of the
-- current settings. Returns a list of strings relative to the render folder,
-- extension stripped, using "/" as separator.
local function resolve_pattern(pattern)
  local dummy = targets_for("@")
  local real = targets_for(pattern)
  local out = {}
  for i = 1, #real do
    local d = dummy[i] and dummy[i]:match("^(.*)[\\/]@[^\\/]*$")
    local rel = real[i]
    if d and rel:sub(1, #d) == d then rel = rel:sub(#d + 2) end
    rel = rel:gsub("%.[^.\\/]*$", ""):gsub("\\", "/")
    out[i] = rel
  end
  return out, #dummy == #real
end

-- Wildcard pattern for the container rows + leaf, one "@"-prefixed segment
-- per level so empty wildcards can't collapse a level.
-- REAPER adds "-001", "-002"... to the file name when several targets resolve
-- to the same path. Without a Sound name the last segment is a container, so a
-- throwaway "@" file segment goes last to soak up that suffix instead.
local function mapping_pattern(s)
  local segs = {}
  for _, row in ipairs(s.rows) do segs[#segs + 1] = "@" .. (row.name or ""):gsub("[\\/]", "_") end
  if s.leaf.name ~= "" then segs[#segs + 1] = "@" .. s.leaf.name:gsub("[\\/]", "_") end
  if #segs == 0 then return nil end
  if s.leaf.name == "" then segs[#segs + 1] = "@" end
  return table.concat(segs, "/")
end

local function parse_mapping(resolved, nrows, has_leaf)
  local parts = split(resolved, "/")
  if not has_leaf and nrows > 0 then
    if #parts ~= nrows + 1 or not parts[#parts]:match("^@%-?%d*$") then return nil end
    parts[#parts] = nil
  end
  local want = nrows + (has_leaf and 1 or 0)
  if #parts ~= want then return nil end
  local names = {}
  for i, p in ipairs(parts) do names[i] = M.sanitize(p:gsub("^@", "")) end
  return names
end

local function resolve_originals(s)
  if (s.originals_subfolder or "") == "" then return nil end
  local res = resolve_pattern("@" .. s.originals_subfolder:gsub("/", "\\") .. "/@")
  local out = {}
  for i, p in ipairs(res) do
    -- REAPER adds "-001", "-002"... when several files would get the same name; drop that too.
    out[i] = p:gsub("^@", ""):gsub("/@%-?%d*$", ""):gsub("/", "\\")
  end
  return out
end

----------------------------------------------------------------------
-- Plan: what will be imported where
----------------------------------------------------------------------
local function sound_tag(s, conn)
  if conn and conn.new_types then return "<Sound>" end
  return s.leaf.voice and "<Sound Voice>" or "<Sound SFX>"
end

-- Each entry: { name, names = {container names}, origsub, kind, file?, item?, track?, token? }
-- kind: "direct" | "render" | "folder" | "project"
local function plan_selected_items(s, snap)
  local entries, errors = {}, {}
  local normal, folders = {}, {}
  for _, it in ipairs(snap.items) do
    if is_folder_item(it) then folders[#folders + 1] = it else normal[#normal + 1] = it end
  end
  local pattern = mapping_pattern(s)
  local need_resolve = pattern ~= nil or (s.originals_subfolder or "") ~= ""

  if need_resolve then
    set_s("RENDER_FILE", TMP)
    set_n("RENDER_ADDTOPROJ", 0)
  end

  if #normal > 0 and not need_resolve then
    -- Fast path: nothing to resolve, so no need to touch render settings.
    for i, it in ipairs(normal) do
      local e = { item = it, name = M.sanitize(take_name(it) or ""), token = string.format("JSWT%05d", i), names = {} }
      if e.name == "" then e.name = "Item_" .. i end
      local file = s.skip_render_untouched and M.untouched_source(it)
      e.kind = file and "direct" or "render"
      e.file = file or nil
      e.src_ch = source_channels(it)
      entries[#entries + 1] = e
    end
  elseif #normal > 0 then
    set_n("RENDER_SETTINGS", s.items_via_master and 64 or 32)
    set_n("RENDER_BOUNDSFLAG", 4)
    select_items(normal)
    -- Temporary unique take names reveal REAPER's target order.
    local by_token = {}
    for i, it in ipairs(normal) do
      local e = { item = it, name = M.sanitize(take_name(it) or ("Item_" .. i)), token = string.format("JSWT%05d", i) }
      if e.name == "" then e.name = "Item_" .. i end
      by_token[e.token] = e
      local take = r.GetActiveTake(it)
      if take then rename_take(take, snap, e.token) end
      local file = s.skip_render_untouched and M.untouched_source(it)
      e.kind = file and "direct" or "render"
      e.file = file or nil
      e.src_ch = source_channels(it)
    end
    local order = targets_for("$item")
    for take, nm in pairs(snap.names) do r.GetSetMediaItemTakeInfo_String(take, "P_NAME", nm, true) end
    local ordered = {}
    for i, t in ipairs(order) do ordered[i] = by_token[basename_noext(t)] end
    local mapped = pattern and resolve_pattern(pattern) or {}
    local subs = resolve_originals(s) or {}
    for i, e in ipairs(ordered) do
      if e then
        if pattern then
          local names = parse_mapping(mapped[i] or "", #s.rows, s.leaf.name ~= "")
          if names then
            if s.leaf.name ~= "" then e.name = table.remove(names) end
            e.names = names
          else
            e.unresolved = true
          end
        else
          e.names = {}
        end
        e.origsub = subs[i]
        entries[#entries + 1] = e
      end
    end
    -- Items REAPER wouldn't render (e.g. muted?) still show up as errors.
    local seen = {}
    for _, e in ipairs(entries) do seen[e] = true end
    for _, e in pairs(by_token) do
      if not seen[e] then errors[#errors + 1] = "REAPER won't render item \"" .. e.name .. "\"." end
    end
  end

  for i, it in ipairs(folders) do
    local tr = r.GetMediaItem_Track(it)
    local pos = r.GetMediaItemInfo_Value(it, "D_POSITION")
    local len = r.GetMediaItemInfo_Value(it, "D_LENGTH")
    local e = { item = it, track = tr, kind = "folder", pos = pos, len = len,
                name = M.sanitize(take_name(it) or ""), token = string.format("JSWTF%05d", i) }
    if e.name == "" then
      local _, tn = r.GetTrackName(tr)
      e.name = M.sanitize(tn) .. "_" .. i
    end
    e.names = {}
    if need_resolve then
      r.SetOnlyTrackSelected(tr)
      set_n("RENDER_SETTINGS", s.folders_via_master and 128 or 2)
      set_n("RENDER_BOUNDSFLAG", 0)
      set_n("RENDER_STARTPOS", pos)
      set_n("RENDER_ENDPOS", pos + len)
    end
    if pattern then
      local mapped = resolve_pattern(pattern)
      local names = parse_mapping(mapped[1] or "", #s.rows, s.leaf.name ~= "")
      if names then
        if s.leaf.name ~= "" then e.name = table.remove(names) end
        e.names = names
      else
        e.unresolved = true
      end
    end
    local subs = need_resolve and resolve_originals(s)
    e.origsub = subs and subs[1]
    entries[#entries + 1] = e
  end
  return entries, errors
end

local function plan_render_settings(s)
  local entries, errors = {}, {}
  -- RENDER_PATTERN may be empty (REAPER then uses the project name); read targets as-is.
  local real_pattern = get_s("RENDER_PATTERN")
  local targets = split(get_s("RENDER_TARGETS"), ";")
  if #targets == 1 and targets[1] == "" then targets = {} end
  if #targets == 0 then
    errors[#errors + 1] = "REAPER's render settings produce no files. Open the render settings and pick a source and bounds."
    return entries, errors
  end
  local pattern = mapping_pattern(s)
  local mapped = pattern and resolve_pattern(pattern) or {}
  local subs = resolve_originals(s) or {}
  local relpaths = real_pattern ~= "" and resolve_pattern(real_pattern) or {}
  set_s("RENDER_PATTERN", real_pattern)
  for i, t in ipairs(targets) do
    local e = { kind = "project", target = t, name = M.sanitize(basename_noext(t)), names = {} }
    if pattern then
      local names = parse_mapping(mapped[i] or "", #s.rows, s.leaf.name ~= "")
      if names then
        if s.leaf.name ~= "" then e.name = table.remove(names) end
        e.names = names
      else
        e.unresolved = true
      end
    end
    -- Subfolders in the render pattern carry over into the Originals subfolder.
    local reldir = relpaths[i] and dirname(relpaths[i]) or ""
    local sub = subs[i] or ""
    if reldir ~= "" then sub = (sub ~= "" and (sub .. "\\") or "") .. reldir:gsub("/", "\\") end
    e.origsub = sub ~= "" and sub or nil
    entries[#entries + 1] = e
  end
  return entries, errors
end

-- Build the full plan. Changes render settings temporarily and restores them.
function M.build_plan(s, conn)
  local dest = s.destination
  local res, err = with_temp_state(function(snap)
    if s.source == "render" then return { plan_render_settings(s) } end
    if #snap.items == 0 then return { {}, { "Select one or more items in REAPER." } } end
    return { plan_selected_items(s, snap) }
  end)
  if not res then return { entries = {}, errors = { "Couldn't read the project: " .. tostring(err) } } end
  local plan = { entries = res[1], errors = res[2] or {}, destination = dest }
  M.finish_paths(plan, s, conn)
  return plan
end

-- Fill in Wwise paths (typed for import, plain for display/existence).
function M.finish_paths(plan, s, conn)
  local dest = (plan.destination or ""):gsub("\\+$", "")
  plan.destination = dest
  local tag = sound_tag(s, conn)
  local used = {}
  for _, e in ipairs(plan.entries) do
    if e.unresolved then
      e.path, e.plain = nil, nil
    else
      if e.name == "" then e.name = "Untitled" end
      local typed, plain = dest, dest
      for i, n in ipairs(e.names or {}) do
        local n2 = n ~= "" and n or "Untitled"
        typed = typed .. "\\<" .. s.rows[i].type .. ">" .. n2
        plain = plain .. "\\" .. n2
      end
      e.path = typed .. "\\" .. tag .. e.name
      e.plain = plain .. "\\" .. e.name
      local k = e.plain:lower()
      e.duplicate = used[k] and true or nil
      used[k] = true
    end
  end
end

local function regex_escape(t) return (t:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?%{%}|\\]", function(c) return "\\" .. c end)) end

-- Every Wwise path an entry touches: its containers (below the destination) and the Sound.
local function entry_paths(plan, e)
  local out, p = {}, plan.destination
  for _, n in ipairs(e.names or {}) do
    p = p .. "\\" .. (n ~= "" and n or "Untitled")
    out[#out + 1] = p
  end
  out[#out + 1] = e.plain
  return out
end

local function apply_known(plan, known)
  local existing = {}
  for _, e in ipairs(plan.entries) do
    if e.plain then
      for _, p in ipairs(entry_paths(plan, e)) do
        local id = known[p:lower()]
        if id then existing[p:lower()] = id end
      end
    end
  end
  plan.dest_missing = nil
  plan.existing = existing
  for _, e in ipairs(plan.entries) do e.exists = e.plain and existing[e.plain:lower()] ~= nil end
  return existing
end

-- Ask Wwise which planned objects already exist. Only asks about the names in
-- the plan (not every object under the destination), so it stays fast in big
-- projects. Marks e.exists and returns the set of existing plain paths.
-- `known` (optional) is a cache: lowercase path -> id, or false when known to be
-- missing. When it already answers every path, Wwise isn't asked at all.
-- `timeout` (optional, seconds) caps how long REAPER waits for Wwise.
function M.mark_existing(plan, timeout, known)
  if plan.destination == "" then return {} end
  local names, seen, all_known = {}, {}, known ~= nil
  local function add(n) if n and n ~= "" and not seen[n] then seen[n] = true; names[#names + 1] = regex_escape(n) end end
  for _, e in ipairs(plan.entries) do
    if e.plain then
      for _, n in ipairs(e.names or {}) do add(n ~= "" and n or "Untitled") end
      add(e.name)
      if all_known then
        for _, p in ipairs(entry_paths(plan, e)) do
          if known[p:lower()] == nil then all_known = false; break end
        end
      end
    end
  end
  if #names == 0 then plan.existing = {}; return plan.existing end
  if all_known then return apply_known(plan, known) end
  local res, err, code = M.waapi("ak.wwise.core.object.get",
    { from = { path = { plan.destination } },
      transform = { { select = { "descendants" } }, { where = { "name:matches", "^(" .. table.concat(names, "|") .. ")$" } } } },
    { ["return"] = { "path", "id" } }, timeout)
  if not res then
    if code == "offline" or code == "busy" then return {}, code end
    plan.dest_missing = true
    for _, e in ipairs(plan.entries) do e.exists = false end
    return {}, err
  end
  local found = {}
  for _, o in ipairs(res["return"] or {}) do found[o.path:lower()] = o.id end
  known = known or {}
  for _, e in ipairs(plan.entries) do
    if e.plain then
      for _, p in ipairs(entry_paths(plan, e)) do known[p:lower()] = found[p:lower()] or false end
    end
  end
  return apply_known(plan, known)
end

-- After a transfer, record what now exists in Wwise so the preview doesn't
-- have to ask Wwise again while it is still busy with the import.
function M.remember_transfer(plan, known)
  for _, e in ipairs(plan.entries or {}) do
    if e.plain and e.file then
      for _, p in ipairs(entry_paths(plan, e)) do known[p:lower()] = known[p:lower()] or true end
    end
  end
end

----------------------------------------------------------------------
-- Initial delay from layer timing
----------------------------------------------------------------------
-- Items that overlap in time form one "shot" (e.g. Muzzle_01 + Tail_01). Each item's
-- delay is its start minus the shot's earliest start. With target "container", each
-- layer container (the level above the Sounds) gets the smallest delay among its
-- Sounds; with "sound", every Sound gets its own. Returns { [plain path] = seconds }
-- plus a list of warnings.
local function parent_path(p) return p:match("^(.*)\\[^\\]+$") end

function M.layer_delays(plan, s)
  local list = {}
  for _, e in ipairs(plan.entries or {}) do
    if e.plain and e.item and r.ValidatePtr(e.item, "MediaItem*") then
      local pos = r.GetMediaItemInfo_Value(e.item, "D_POSITION")
      list[#list + 1] = { e = e, pos = pos, fin = pos + r.GetMediaItemInfo_Value(e.item, "D_LENGTH") }
    end
  end
  table.sort(list, function(a, b) return a.pos < b.pos end)
  local g
  for _, x in ipairs(list) do
    if not g or x.pos >= g.fin - 1e-9 then g = { start = x.pos, fin = x.fin } else g.fin = math.max(g.fin, x.fin) end
    x.delay = x.pos - g.start
  end
  local out, warnings = {}, {}
  local by_container = (s.delay_target or "container") == "container" and #(s.rows or {}) > 0
  if by_container then
    local lo, hi = {}, {}
    for _, x in ipairs(list) do
      local c = parent_path(x.e.plain)
      if c then
        lo[c] = math.min(lo[c] or math.huge, x.delay)
        hi[c] = math.max(hi[c] or -math.huge, x.delay)
      end
    end
    for c, v in pairs(lo) do
      out[c] = v
      if hi[c] - v > 0.001 then
        warnings[#warnings + 1] = string.format("%s: its Sounds start %.0f to %.0f ms after their shot; the container gets %.0f ms.",
          c:match("[^\\]+$") or c, v * 1000, hi[c] * 1000, v * 1000)
      end
    end
  else
    for _, x in ipairs(list) do out[x.e.plain] = x.delay end
  end
  return out, warnings
end

-- Write Initial Delay (seconds) on Wwise objects given by path. Returns count, error.
function M.apply_delays(delays, timeout)
  local objs = json.array()
  for path, v in pairs(delays) do
    objs[#objs + 1] = { object = path, ["@InitialDelay"] = math.floor(v * 10000 + 0.5) / 10000 }
  end
  if #objs == 0 then return 0 end
  local res, err = M.waapi("ak.wwise.core.object.set", { objects = objs }, nil, timeout)
  if res then return #objs end
  -- Older Wwise (before 2022.1) has no object.set: one call per object.
  local n, last = 0, err
  for _, o in ipairs(objs) do
    local ok, e2 = M.waapi("ak.wwise.core.object.setProperty", { object = o.object, property = "InitialDelay", value = o["@InitialDelay"] }, nil, timeout)
    if ok then n = n + 1 else last = e2 end
  end
  if n == 0 then return 0, last end
  return n
end

-- Turn the plan into a tree shaped like Wwise's Project Explorer.
-- Node: { name, type, path, children = {...}, entry = e (Sounds only), status = "new"|"exists"|"duplicate"|nil,
--         sounds = number of Sounds below, new_count = new objects below (incl. self) }
function M.build_tree(plan, s, conn)
  local root = { name = plan.destination ~= "" and plan.destination or "(no destination)", type = "Destination",
                 path = plan.destination, children = {}, index = {}, sounds = 0, new_count = 0 }
  local existing = plan.existing
  local function status_of(path)
    if not existing then return nil end
    if plan.dest_missing then return "new" end
    return existing[path:lower()] and "exists" or "new"
  end
  local sound_type = (conn and conn.new_types) and "Sound" or (s.leaf.voice and "Sound Voice" or "Sound SFX")
  local unresolved = 0
  for _, e in ipairs(plan.entries) do
    if not e.plain then
      unresolved = unresolved + 1
    else
      local node, path = root, plan.destination
      local chain = { root }
      for i, n in ipairs(e.names or {}) do
        local nm = n ~= "" and n or "Untitled"
        path = path .. "\\" .. nm
        local key = nm:lower()
        local child = node.index[key]
        if not child then
          child = { name = nm, type = s.rows[i] and s.rows[i].type or "?", path = path, children = {}, index = {},
                    sounds = 0, new_count = 0, status = status_of(path), delay = plan.delays and plan.delays[path] }
          node.index[key] = child
          node.children[#node.children + 1] = child
        end
        node = child
        chain[#chain + 1] = node
      end
      local leaf = { name = e.name, type = sound_type, path = e.plain, entry = e, children = {}, index = {},
                     sounds = 1, new_count = 0, delay = plan.delays and plan.delays[e.plain] }
      leaf.status = e.duplicate and "duplicate" or status_of(e.plain)
      node.children[#node.children + 1] = leaf
      for _, c in ipairs(chain) do c.sounds = c.sounds + 1 end
    end
  end
  -- Count new objects (containers and Sounds) per subtree.
  local function count(n)
    local c = (n.status == "new") and 1 or 0
    for _, ch in ipairs(n.children) do c = c + count(ch) end
    n.new_count = c
    return c
  end
  count(root)
  root.unresolved = unresolved
  return root
end

----------------------------------------------------------------------
-- Validation
----------------------------------------------------------------------
local CHILDREN = {
  container = { ["Switch Container"] = 1, ["Random Container"] = 1, ["Sequence Container"] = 1, ["Blend Container"] = 1, sound = 1 },
  mixer = { ["Work Unit"] = 1, ["Virtual Folder"] = 1, ["Actor-Mixer"] = 1, ["Switch Container"] = 1,
            ["Random Container"] = 1, ["Sequence Container"] = 1, ["Blend Container"] = 1, sound = 1 },
  physical = { ["Physical Folder"] = 1, ["Work Unit"] = 1 },
}
local GROUP = { ["Switch Container"] = "container", ["Random Container"] = "container", ["Sequence Container"] = "container",
                ["Blend Container"] = "container", ["Actor-Mixer"] = "mixer", ["Virtual Folder"] = "mixer",
                ["Work Unit"] = "mixer", ["Physical Folder"] = "physical" }

-- Returns a list of problems with the hierarchy mapping (empty if fine).
function M.validate(s)
  local problems = {}
  local types = {}
  for _, row in ipairs(s.rows) do types[#types + 1] = row.type end
  types[#types + 1] = "sound"
  for i = 2, #types do
    local parent, child = types[i - 1], types[i]
    local g = GROUP[parent]
    if g and not CHILDREN[g][child] then
      problems[#problems + 1] = string.format("A %s can't contain a %s.", parent, child == "sound" and "Sound" or child)
    end
  end
  for i, row in ipairs(s.rows) do
    if (row.name or "") == "" then problems[#problems + 1] = "Level " .. i .. " (" .. row.type .. ") needs a name." end
  end
  if s.leaf.voice and (s.leaf.language or "") == "" then problems[#problems + 1] = "Pick a language for Sound Voice." end
  return problems
end

----------------------------------------------------------------------
-- Mono / stereo
----------------------------------------------------------------------
-- A channel override is set on a Sound or on a container (then it counts for every
-- Sound below it) and stored by its path below the destination, so it still applies
-- when the destination changes. Lowercase keys, "\" between levels.
function M.rel_path(plan, path)
  local d = (plan and plan.destination) or ""
  path = path or ""
  if d ~= "" and path:sub(1, #d + 1):lower() == (d .. "\\"):lower() then return path:sub(#d + 2) end
  return (path:gsub("^\\+", ""))
end

-- "mono", "stereo" or nil (Auto) for a Wwise path, plus the name of the object the
-- override was set on (the Sound itself or a container above it).
function M.channel_override(s, plan, path)
  local ov = s.channels or {}
  local rel = M.rel_path(plan, path)
  while rel and rel ~= "" do
    local m = ov[rel:lower()]
    if m == "mono" or m == "stereo" then return m, rel:match("[^\\]+$") end
    rel = rel:match("^(.*)\\[^\\]+$")
  end
  return nil
end

-- The override set on exactly this path (not inherited), or nil.
function M.own_channel_override(s, plan, path)
  local m = (s.channels or {})[M.rel_path(plan, path):lower()]
  if m == "mono" or m == "stereo" then return m end
end

function M.set_channel_override(s, plan, path, mode)
  if type(s.channels) ~= "table" then s.channels = {} end
  s.channels[M.rel_path(plan, path):lower()] = (mode == "mono" or mode == "stereo") and mode or nil
end

function M.count_channel_overrides(s)
  local n = 0
  for _ in pairs(s.channels or {}) do n = n + 1 end
  return n
end

-- What a Sound will get: "mono", "stereo", "auto" (check after rendering) or nil (keep as is).
local function wanted_channels(s, plan, e)
  local m = e.plain and M.channel_override(s, plan, e.plain)
  if m then return m end
  if s.mono_to_mono and e.kind ~= "direct" then return "auto" end
  return nil
end
M.wanted_channels = wanted_channels

-- WAV files are read and written in plain Lua (nothing extra to install).
-- Handles RIFF WAV with integer PCM (8/16/24/32-bit) or float (32/64-bit) samples.
local CHUNK_FRAMES = 16384
local SAMPLE_FMT = { [1] = { [1] = "B", [2] = "<i2", [3] = "<i3", [4] = "<i4" }, [3] = { [4] = "<f", [8] = "<d" } }

function M.wav_info(path)
  local f = io.open(path, "rb")
  if not f then return nil, "can't open the file" end
  local hdr = f:read(12)
  if not hdr or #hdr < 12 or hdr:sub(1, 4) ~= "RIFF" or hdr:sub(9, 12) ~= "WAVE" then f:close(); return nil, "not a WAV file" end
  local fsize = f:seek("end")
  f:seek("set", 12)
  local info = { chunks = {} }
  while true do
    local ch = f:read(8)
    if not ch or #ch < 8 then break end
    local id, size = ch:sub(1, 4), string.unpack("<I4", ch, 5)
    local start = f:seek()
    if id == "data" then
      if start + size > fsize then size = fsize - start end -- unfinished or oversized header
      info.data_pos, info.data_size = start, size
      info.chunks[#info.chunks + 1] = { id = id }
    else
      local body = f:read(size) or ""
      if id == "fmt " then info.fmt = body end
      info.chunks[#info.chunks + 1] = { id = id, body = body }
    end
    if start + size + (size % 2) >= fsize then break end
    f:seek("set", start + size + (size % 2))
  end
  f:close()
  if not info.fmt or #info.fmt < 16 or not info.data_pos then return nil, "unreadable WAV file" end
  local tag, chans, rate, _, align, bits = string.unpack("<I2I2I4I4I2I2", info.fmt)
  if tag == 0xFFFE and #info.fmt >= 26 then tag = string.unpack("<I2", info.fmt, 25) end
  if chans < 1 or align < chans or align % chans ~= 0 then return nil, "unreadable WAV file" end
  local bytes = align // chans
  if not (SAMPLE_FMT[tag] and SAMPLE_FMT[tag][bytes]) then return nil, "unsupported WAV sample format" end
  info.tag, info.chans, info.rate, info.align, info.bytes, info.bits = tag, chans, rate, align, bytes, bits
  info.frames = info.data_size // align
  return info
end

-- Calls fn(block) with whole sample frames of the data chunk. Stops early when fn returns false.
local function each_block(path, info, fn)
  local f = io.open(path, "rb")
  if not f then return nil end
  f:seek("set", info.data_pos)
  local left = info.frames * info.align
  local step = CHUNK_FRAMES * info.align
  while left > 0 do
    local n = math.min(step, left)
    local b = f:read(n)
    if not b or #b < n then f:close(); return nil end
    left = left - n
    if fn(b) == false then f:close(); return false end
  end
  f:close()
  return true
end

local function frame_pattern(bytes)
  local one = "(" .. string.rep(".", bytes) .. ")"
  return one .. one
end

-- Do left and right of a stereo file match? Identical samples count, and so do
-- differences too small to hear: at most -90 dBFS (or 2 steps at 16-bit and below),
-- e.g. from dither, noise shaping or rounding. Returns true/false and, when they
-- don't match, the level of the first bigger difference in dBFS.
M.LR_MATCH_DB = -90
function M.wav_lr_match(path, info)
  if info.chans ~= 2 then return false end
  local pat = frame_pattern(info.bytes)
  local sf = SAMPLE_FMT[info.tag][info.bytes]
  local two = sf .. sf:gsub("^<", "")
  local full = info.tag == 3 and 1 or (info.bytes == 1 and 128 or 2 ^ (info.bytes * 8 - 1))
  local tol = math.max(full * 10 ^ (M.LR_MATCH_DB / 20), info.tag == 3 and 0 or 2)
  local diff
  local ok = each_block(path, info, function(b)
    local L = b:gsub(pat, "%1")
    local R = b:gsub(pat, "%2")
    if L == R then return true end
    for i = 1, #b, info.align do
      local a, c = string.unpack(two, b, i)
      local d = math.abs(a - c)
      if d > tol then diff = 20 * math.log(d / full, 10); return false end
    end
    return true
  end)
  if ok == nil then return false end
  return ok, diff
end

-- Write `src` as a mono or stereo file at `dest` (may be the same path). Mono keeps the
-- left channel when left and right match (lossless) and averages them otherwise.
-- Other chunks (markers, metadata) are copied as they are.
function M.wav_write_channels(src, info, dest, chans, lr_match)
  local align = info.bytes * chans
  local tmp = dest .. ".jswt.tmp"
  local out = io.open(tmp, "wb")
  if not out then return nil, "can't write " .. tmp end
  local data_len = info.frames * align
  local parts = {}
  out:write("RIFF", string.pack("<I4", 0), "WAVE")
  local total = 4
  local ok_all = true
  for _, c in ipairs(info.chunks) do
    if c.id == "fmt " then
      local tag = info.tag
      local fmt = string.pack("<I2I2I4I4I2I2", tag, chans, info.rate, info.rate * align, align, info.bytes * 8)
      if tag == 3 then fmt = fmt .. string.pack("<I2", 0) end
      out:write("fmt ", string.pack("<I4", #fmt), fmt)
      total = total + 8 + #fmt
    elseif c.id == "data" then
      out:write("data", string.pack("<I4", data_len))
      local pat = frame_pattern(info.bytes)
      local one = "(" .. string.rep(".", info.bytes) .. ")"
      local sf = SAMPLE_FMT[info.tag][info.bytes]
      local two = sf .. sf:gsub("^<", "")
      local float = info.tag == 3
      ok_all = each_block(src, info, function(b)
        if chans == 2 then
          out:write((b:gsub(one, "%1%1")))
        elseif lr_match then
          out:write((b:gsub(pat, "%1")))
        else
          local t, n = {}, 0
          for i = 1, #b, info.align do
            local a, c2 = string.unpack(two, b, i)
            n = n + 1
            t[n] = string.pack(sf, float and (a + c2) / 2 or (a + c2) // 2)
          end
          out:write(table.concat(t))
        end
      end) and ok_all
      if data_len % 2 == 1 then out:write("\0") end
      total = total + 8 + data_len + data_len % 2
    else
      out:write(c.id, string.pack("<I4", #c.body), c.body)
      if #c.body % 2 == 1 then out:write("\0") end
      total = total + 8 + #c.body + #c.body % 2
    end
  end
  out:seek("set", 4)
  out:write(string.pack("<I4", total))
  out:close()
  if not ok_all then os.remove(tmp); return nil, "couldn't read " .. src end
  os.remove(dest)
  if not os.rename(tmp, dest) then os.remove(tmp); return nil, "couldn't replace " .. dest end
  return true
end

-- After rendering: make each Sound's file mono or stereo as wanted. Files REAPER
-- rendered for us are changed in place; WAVs imported from disk and files from your
-- own render settings are copied first, so the originals stay as they are.
local function apply_channels(s, plan, summary)
  local copydir
  local made_mono, changed = 0, 0
  local kept, monos = {}, {}
  for _, e in ipairs(plan.entries) do
    local want = e.file and not e.unresolved and wanted_channels(s, plan, e)
    if want then
      local info, ierr = M.wav_info(e.file)
      local target, lr_match
      if not info then
        if want ~= "auto" then summary.errors[#summary.errors + 1] = "Couldn't make \"" .. e.name .. "\" " .. want .. ": " .. tostring(ierr) .. "."
        else kept[#kept + 1] = e.name .. ": couldn't check it (" .. tostring(ierr) .. ")" end
      elseif info.chans == 2 and (want == "mono" or want == "auto") then
        local diff
        lr_match, diff = M.wav_lr_match(e.file, info)
        if want == "mono" or lr_match then target = 1
        else kept[#kept + 1] = e.name .. (diff and string.format(": left and right differ (by %.0f dB)", diff) or ": left and right differ") end
      elseif want == "auto" and info.chans ~= 1 then
        kept[#kept + 1] = e.name .. ": " .. info.chans .. " channels"
      elseif want == "auto" and info.chans == 1 and e.kind ~= "direct" then
        kept[#kept + 1] = e.name .. ": REAPER rendered it in mono"
      elseif info.chans == 1 and want == "stereo" then
        target = 2
      end
      if target then
        local dest = e.file
        if e.kind == "direct" or e.kind == "project" then
          if not copydir then
            copydir = TMP .. SEP .. "ch_" .. os.time() .. "_" .. math.random(1000, 9999)
            r.RecursiveCreateDirectory(copydir, 0)
            plan.copydir = copydir
          end
          dest = copydir .. SEP .. (e.file:match("([^\\/]+)$") or (e.name .. ".wav"))
        end
        local ok, werr = M.wav_write_channels(e.file, info, dest, target, lr_match)
        if ok then
          if dest ~= e.file then e.file = dest; e.temp = true end
          e.channels_done = target == 1 and "mono" or "stereo"
          changed = changed + 1
          if want == "auto" then
            made_mono = made_mono + 1
            monos[#monos + 1] = e.name
          end
        else
          summary.errors[#summary.errors + 1] = "Couldn't make \"" .. e.name .. "\" " .. (target == 1 and "mono" or "stereo") .. ": " .. tostring(werr) .. "."
        end
      end
    end
  end
  summary.made_mono, summary.channel_changes = made_mono, changed
  summary.kept_stereo, summary.mono_names = kept, monos
end
M.apply_channels = apply_channels

----------------------------------------------------------------------
-- Audio sources of existing Sounds
----------------------------------------------------------------------
-- Re-importing onto an existing Sound can make Wwise add a second audio source with
-- the same name instead of replacing the first. So: name the existing source in the
-- import path (Wwise then replaces its audio), and afterwards delete any older source
-- that a new one with the same name has taken over from.

-- { [lowercase Sound path] = { { id =, name = }, ... } } for the given Sound paths.
function M.sound_sources(paths, timeout)
  local out = {}
  if #paths == 0 then return out end
  local res = M.waapi("ak.wwise.core.object.get",
    { from = { path = paths }, transform = { { select = { "children" } }, { where = { "type:isIn", json.array({ "AudioFileSource" }) } } } },
    { ["return"] = { "id", "name", "path" } }, timeout)
  if not res then return nil end
  for _, o in ipairs(res["return"] or {}) do
    local parent = o.path and o.path:match("^(.*)\\[^\\]+$")
    if parent and o.id then
      local k = parent:lower()
      out[k] = out[k] or {}
      table.insert(out[k], { id = o.id, name = o.name or "" })
    end
  end
  return out
end

-- Source name to put in the import path for an existing Sound.
local function existing_source_name(list, file)
  if not list or #list == 0 then return nil end
  local want = basename_noext(file):lower()
  for _, src in ipairs(list) do if src.name:lower() == want then return src.name end end
  if #list == 1 then return list[1].name end
  return nil
end

-- Delete older sources that a newer one with the same name replaced. Returns count.
local function remove_replaced_sources(before, after)
  local del = json.array()
  for k, now in pairs(after or {}) do
    local old = before[k]
    if old then
      local was = {}
      for _, src in ipairs(old) do was[src.id] = src end
      local new_names = {}
      for _, src in ipairs(now) do if not was[src.id] then new_names[src.name:lower()] = true end end
      for _, src in ipairs(now) do
        if was[src.id] and new_names[src.name:lower()] then del[#del + 1] = src.id end
      end
    end
  end
  local n = 0
  for _, id in ipairs(del) do
    if M.waapi("ak.wwise.core.object.delete", { object = id }) then n = n + 1 end
  end
  return n
end

----------------------------------------------------------------------
-- Transfer
----------------------------------------------------------------------
local function parse_render_stats(stats)
  -- RENDER_STATS looks like "FILE:C:\a.wav;PEAK:...;FILE:C:\b.wav;..."
  local files = {}
  local pos = 1
  while true do
    local a, b = stats:find("FILE:", pos, true)
    if not a then break end
    local nxt = stats:find(";FILE:", b + 1, true) or (#stats + 1)
    local seg = stats:sub(b + 1, nxt - 1)
    local path = seg:match("^(.-);[A-Z]+:") or seg:gsub(";$", "")
    files[#files + 1] = path
    pos = nxt
  end
  return files
end

local function do_render(s, plan)
  local renders = {}
  for _, e in ipairs(plan.entries) do
    if e.kind == "render" or e.kind == "folder" then renders[#renders + 1] = e end
  end
  if s.source ~= "render" and #renders == 0 then return true end

  local outdir = TMP .. SEP .. os.time() .. "_" .. math.random(1000, 9999)
  local keep_base, prefix = M.render_folder_parts(s)
  if keep_base then outdir = keep_base else plan.outdir = outdir end
  prefix = (prefix and prefix ~= "") and (prefix .. "/") or ""
  return with_temp_state(function(snap)
    if s.source == "render" then
      M.render_command()
      local files = parse_render_stats(get_s("RENDER_STATS"))
      for i, e in ipairs(plan.entries) do
        local f = files[i] or e.target
        if f and file_exists(f) then e.file = f end
      end
      return true
    end

    r.RecursiveCreateDirectory(outdir, 0)
    set_s("RENDER_FILE", outdir)
    set_s("RENDER_FORMAT", WAV24)
    set_n("RENDER_ADDTOPROJ", 0)
    set_n("RENDER_TAILFLAG", 0)
    -- Auto channels and Mono/Stereo overrides work on stereo renders: render at least two
    -- channels (more if REAPER's render settings ask for more), then fix each file afterwards.
    if s.mono_to_mono or M.count_channel_overrides(s) > 0 then
      set_n("RENDER_CHANNELS", math.max(2, get_n("RENDER_CHANNELS")))
      -- Dither and noise shaping add different noise to left and right, so a mono
      -- sound would no longer look mono. Our 24-bit renders don't need them.
      set_n("RENDER_DITHER", 0)
    end

    -- Where REAPER will write each token's file (the folder setting can contain wildcards).
    local where, made = {}, {}
    local function note_targets(pattern)
      for _, t in ipairs(targets_for(pattern)) do
        where[basename_noext(t)] = t
        os.remove(t) -- a leftover token file would make REAPER ask about overwriting
      end
    end

    local items = {}
    for _, e in ipairs(renders) do
      if e.kind == "render" then
        items[#items + 1] = e.item
        local take = r.GetActiveTake(e.item)
        if take then rename_take(take, snap, e.token) end
      end
    end
    if #items > 0 then
      select_items(items)
      -- No "mono media to mono" flag (16): REAPER applies it to stereo items too.
      -- Auto channels checks each rendered file instead.
      set_n("RENDER_SETTINGS", s.items_via_master and 64 or 32)
      set_n("RENDER_BOUNDSFLAG", 4)
      note_targets(prefix .. "$item")
      M.render_command()
    end
    for _, e in ipairs(renders) do
      if e.kind == "folder" then
        r.SetOnlyTrackSelected(e.track)
        set_n("RENDER_SETTINGS", s.folders_via_master and 128 or 2)
        set_n("RENDER_BOUNDSFLAG", 0)
        set_n("RENDER_STARTPOS", e.pos)
        set_n("RENDER_ENDPOS", e.pos + e.len)
        note_targets(prefix .. e.token)
        M.render_command()
      end
      local p = where[e.token] or (outdir .. SEP .. e.token .. ".wav")
      if file_exists(p) then
        -- Wwise names the file in Originals after the file, so give it the Sound's name.
        local dir = p:match("^(.*)[\\/][^\\/]*$") or outdir
        local final = dir .. SEP .. e.name .. ".wav"
        -- In the kept-renders folder, a file from an earlier transfer is replaced.
        if keep_base and not made[final:lower()] and file_exists(final) then os.remove(final) end
        local n = 1
        while file_exists(final) do n = n + 1; final = dir .. SEP .. e.name .. "_" .. n .. ".wav" end
        if os.rename(p, final) then e.file = final else e.file = p end
        made[e.file:lower()] = true
        e.temp = not keep_base
      end
    end
    return true
  end)
end

-- File: Render project, using the most recent render settings, auto-close render dialog
function M.render_command() r.Main_OnCommand(42230, 0) end

-- Run a full transfer. Returns a summary table.
function M.transfer(s, conn, on_status)
  local status = on_status or function() end
  local summary = { errors = {}, created = 0, imported = 0, templates = 0, objects = {}, timing = {} }
  local tmark = r.time_precise()
  local function lap(name)
    local now = r.time_precise()
    summary.timing[#summary.timing + 1] = { name, now - tmark }
    tmark = now
  end
  M.http_port = s.http_port

  if not conn then
    local c, err = M.connect()
    if not c then summary.errors[1] = err; return summary end
    conn = c
  end

  local dest = s.destination
  if s.use_wwise_selection then
    local p, err = M.wwise_selection_path()
    if not p then summary.errors[1] = (err or "") .. " Select a parent in Wwise, or turn off \"Use Wwise selection\"."; return summary end
    dest = p
  end
  if (dest or "") == "" then summary.errors[1] = "Set an import destination."; return summary end
  if dest:find("^\\Events") or dest:find("^\\SoundBanks") or dest:find("^\\Switches") or dest:find("^\\Game Parameters") then
    summary.errors[1] = "The destination " .. dest .. " can't hold Sounds."; return summary
  end
  s.destination = dest

  local problems = M.validate(s)
  if #problems > 0 then summary.errors = problems; return summary end

  status("Reading project...")
  local plan = M.build_plan(s, conn)
  summary.plan = plan
  for _, e in ipairs(plan.errors) do summary.errors[#summary.errors + 1] = e end
  if #plan.entries == 0 then return summary end
  lap("Read project")
  status("Checking Wwise...")
  local existing = M.mark_existing(plan)
  lap("Check existing objects")

  status("Rendering...")
  local ok, rerr = do_render(s, plan)
  if not ok then summary.errors[#summary.errors + 1] = "Render failed: " .. tostring(rerr); return summary end
  lap("Render")

  status("Checking mono and stereo...")
  apply_channels(s, plan, summary)
  if (summary.made_mono or 0) > 0 then
    summary.notes = summary.notes or {}
    local m = summary.mono_names or {}
    local shown = {}
    for i = 1, math.min(#m, 8) do shown[i] = m[i] end
    summary.notes[#summary.notes + 1] = string.format("Auto channels made %d Sound%s mono because left and right were the same: %s%s.",
      summary.made_mono, summary.made_mono == 1 and "" or "s", table.concat(shown, ", "),
      #m > 8 and string.format(" and %d more", #m - 8) or "")
  end
  if #(summary.kept_stereo or {}) > 0 then
    summary.notes = summary.notes or {}
    local k = summary.kept_stereo
    local shown = {}
    for i = 1, math.min(#k, 8) do shown[i] = k[i] end
    summary.notes[#summary.notes + 1] = "Auto channels kept these as they were: " .. table.concat(shown, "; ") ..
      (#k > 8 and string.format("; and %d more", #k - 8) or "") .. "."
  end
  if (summary.channel_changes or 0) > 0 then lap("Mono/stereo") end

  -- Audio sources the existing Sounds have now (see "Audio sources of existing Sounds").
  local source_paths, sources_before = json.array(), nil
  -- SFX only: a Voice Sound has one source per language, often with the same name.
  if s.conflict == "useExisting" and not s.leaf.voice then
    for _, e in ipairs(plan.entries) do
      if e.exists and e.plain and e.file and not e.unresolved then source_paths[#source_paths + 1] = e.plain end
    end
    if #source_paths > 0 then sources_before = M.sound_sources(source_paths) end
  end

  local imports = json.array()
  for _, e in ipairs(plan.entries) do
    if e.unresolved then
      summary.errors[#summary.errors + 1] = "Skipped one file: a wildcard in the hierarchy didn't resolve to a single name."
    elseif not e.file then
      summary.errors[#summary.errors + 1] = "Skipped \"" .. e.name .. "\": it didn't render."
    else
      local im = { audioFile = e.file, objectPath = e.path }
      local src = sources_before and e.exists and existing_source_name(sources_before[e.plain:lower()], e.file)
      if src then im.objectPath = e.path .. "\\<AudioFileSource>" .. src end
      if e.origsub and e.origsub ~= "" then im.originalsSubFolder = e.origsub end
      imports[#imports + 1] = im
    end
  end
  if #imports == 0 then return summary end

  status("Importing into Wwise...")
  M.waapi("ak.wwise.core.undo.beginGroup")
  local args = {
    importOperation = s.conflict,
    default = { importLanguage = (s.leaf.voice and s.leaf.language ~= "") and s.leaf.language or "SFX" },
    imports = imports,
    autoAddToSourceControl = true,
  }
  local res, ierr = M.waapi("ak.wwise.core.audio.import", args, { ["return"] = { "id", "path", "type" } })
  if not res and not conn.new_types and ierr and ierr:find("Sound SFX") then
    -- Very new Wwise versions dropped "Sound SFX"; retry with the new type name.
    for _, im in ipairs(imports) do im.objectPath = im.objectPath:gsub("<Sound SFX>", "<Sound>"):gsub("<Sound Voice>", "<Sound>") end
    res, ierr = M.waapi("ak.wwise.core.audio.import", args, { ["return"] = { "id", "path", "type" } })
  end
  if not res then
    M.waapi("ak.wwise.core.undo.endGroup", { displayName = "Wwise Tool (failed)" })
    summary.errors[#summary.errors + 1] = "Wwise import failed: " .. tostring(ierr)
    return summary
  end
  summary.imported = #imports
  if sources_before then
    local n = remove_replaced_sources(sources_before, M.sound_sources(source_paths) or {})
    if n > 0 then
      summary.notes = summary.notes or {}
      summary.notes[#summary.notes + 1] = string.format("Removed %d older duplicate audio source%s.", n, n == 1 and "" or "s")
    end
  end
  lap("Wwise import")

  local ids = json.array()
  for _, o in ipairs(res.objects or {}) do
    if o.path and not existing[o.path:lower()] then summary.created = summary.created + 1 end
    if o.id and (o.type == "Sound" or o.type == nil) then ids[#ids + 1] = o.id end
    summary.objects[#summary.objects + 1] = o
  end
  if #ids == 0 then for _, o in ipairs(res.objects or {}) do if o.id then ids[#ids + 1] = o.id end end end

  -- Property templates: paste each row's template onto the objects at that level.
  local by_template = {}
  local function add_target(template, path)
    if (template or "") == "" or not path then return end
    if s.apply_template == "new" and existing[path:lower()] then return end
    by_template[template] = by_template[template] or {}
    by_template[template][path] = true
  end
  for _, e in ipairs(plan.entries) do
    if e.plain and e.file then
      local p = plan.destination
      for i, n in ipairs(e.names or {}) do
        p = p .. "\\" .. (n ~= "" and n or "Untitled")
        add_target(s.rows[i].template, p)
      end
      add_target(s.leaf.template, e.plain)
    end
  end
  for template, set in pairs(by_template) do
    local targets = json.array()
    for p in pairs(set) do targets[#targets + 1] = p end
    status("Applying template " .. template .. "...")
    local pr, perr = M.waapi("ak.wwise.core.object.pasteProperties", { source = template, targets = targets })
    if pr then summary.templates = summary.templates + #targets
    else summary.errors[#summary.errors + 1] = "Template " .. template .. ": " .. tostring(perr) end
  end

  if next(by_template) then lap("Property templates") end

  -- Initial delay from layer timing (after templates, so a template can't overwrite it).
  if s.set_initial_delay then
    status("Setting initial delays...")
    local delays, warns = M.layer_delays(plan, s)
    local n, derr = M.apply_delays(delays)
    summary.delays = n
    summary.notes = summary.notes or {}
    for _, w in ipairs(warns or {}) do summary.notes[#summary.notes + 1] = w end
    if derr then summary.errors[#summary.errors + 1] = "Initial delay: " .. tostring(derr) end
    lap("Initial delays")
  end
  M.waapi("ak.wwise.core.undo.endGroup", { displayName = "Wwise Tool from REAPER" })

  if s.select_in_wwise and #ids > 0 then
    status("Selecting in Wwise...")
    M.waapi("ak.wwise.ui.commands.execute", { command = "FindInProjectExplorerSyncGroup1", objects = ids })
    lap("Select in Wwise")
  end

  -- Clean up temp renders (Wwise copied them into Originals).
  for _, e in ipairs(plan.entries) do if e.temp and e.file then os.remove(e.file) end end
  if plan.outdir then os.remove(plan.outdir) end
  if plan.copydir then os.remove(plan.copydir) end
  return summary
end

return M
