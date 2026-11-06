-- JS Wwise Transfer: shared core (loaded by the Wwise Transfer scripts; not an action)
-- Author: Jay Sabins

local r = reaper
local M = {}

M.EXT = "JS_WwiseTransfer"
M.VERSION = "1.1.0"
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

----------------------------------------------------------------------
-- Settings (per project, with a global fallback) and presets
----------------------------------------------------------------------
M.CONTAINER_TYPES = { "Virtual Folder", "Actor-Mixer", "Random Container", "Sequence Container",
                      "Switch Container", "Blend Container", "Work Unit", "Physical Folder" }
M.CONFLICT_OPS = { { "useExisting", "Use existing (replace audio, keep object)" },
                   { "replaceExisting", "Replace (delete and re-create)" },
                   { "createNew", "Create new (rename new objects)" } }
M.TEMPLATE_OPS = { { "always", "Always" }, { "new", "New objects only" } }

function M.default_settings()
  return {
    source = "items",                -- "items" (selected items) or "render" (REAPER render settings)
    skip_render_untouched = true,
    items_via_master = false,
    folders_via_master = false,
    mono_to_mono = true,
    use_wwise_selection = true,      -- destination = Wwise selection at transfer time
    destination = "",
    originals_subfolder = "",
    rows = {},                       -- { { type=, name=, template= } }  containers, top to bottom
    leaf = { voice = false, name = "", template = "", language = "" },
    conflict = "useExisting",
    apply_template = "always",
    select_in_wwise = true,
    wamp_port = 8080,
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
  if s.port and s.http_port == 8090 then s.http_port = s.port end -- settings from 1.0.x
  s.port = nil
  return s
end

function M.load_settings()
  local ok, s = r.GetProjExtState(0, M.EXT, "settings")
  if ok == 1 and s ~= "" then
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

function M.save_settings(s)
  local txt = json.encode(s)
  local _, old = r.GetProjExtState(0, M.EXT, "settings")
  if old ~= txt then r.SetProjExtState(0, M.EXT, "settings", txt) end
  r.SetExtState(M.EXT, "last_settings", txt, true)
end

function M.load_presets()
  local p = r.GetExtState(M.EXT, "presets")
  if p == "" then return {} end
  local ok, t = pcall(json.decode, p)
  return ok and type(t) == "table" and t or {}
end

function M.save_presets(p) r.SetExtState(M.EXT, "presets", json.encode(p), true) end

-- The parts of the settings a preset stores (the hierarchy mapping and conflict rules).
function M.preset_from(s)
  local rows = {}
  for i, row in ipairs(s.rows) do rows[i] = { type = row.type, name = row.name, template = row.template } end
  return { rows = rows, leaf = { voice = s.leaf.voice, name = s.leaf.name, template = s.leaf.template,
           language = s.leaf.language }, originals_subfolder = s.originals_subfolder,
           conflict = s.conflict, apply_template = s.apply_template }
end

function M.apply_preset(s, p)
  s.rows = {}
  for i, row in ipairs(p.rows or {}) do s.rows[i] = { type = row.type, name = row.name or "", template = row.template or "" } end
  if p.leaf then for k, v in pairs(p.leaf) do s.leaf[k] = v end end
  if p.originals_subfolder then s.originals_subfolder = p.originals_subfolder end
  if p.conflict then s.conflict = p.conflict end
  if p.apply_template then s.apply_template = p.apply_template end
end

----------------------------------------------------------------------
-- WAAPI transport
-- 1. WAMP over WebSocket (what Wwise's own tools use), via LuaSocket from
--    the free "Mavriq Lua Sockets" ReaPack package. One persistent connection.
-- 2. Fallback: WAAPI over HTTP with curl (older Wwise versions).
----------------------------------------------------------------------
local TMP = (os.getenv("TEMP") or os.getenv("TMPDIR") or r.GetResourcePath()) .. SEP .. M.EXT
r.RecursiveCreateDirectory(TMP, 0)
M.TMP = TMP
M.wamp_port = 8080
M.http_port = 8090

M.MAVRIQ_REPO = "https://github.com/mavriq-dev/public-reascripts/raw/master/index.xml"

local socket_lib = nil
local function load_socket()
  if socket_lib ~= nil then return socket_lib or nil end
  local ok, s = pcall(require, "socket.core")
  if not ok then
    local res = r.GetResourcePath()
    local ext = IS_WIN and "dll" or "so"
    local dirs = {
      res .. "/Scripts/Mavriq ReaScript Repository/Various/Mavriq-Lua-Sockets/",
      res .. "/Scripts/Mavriq ReaScript Repository/Various/Mavriq-Lua-Batteries/bin/",
    }
    for _, d in ipairs(dirs) do
      package.cpath = package.cpath .. ";" .. d .. "?." .. ext
      package.path = package.path .. ";" .. d .. "?.lua"
    end
    ok, s = pcall(require, "socket.core")
  end
  socket_lib = ok and type(s) == "table" and s.tcp and s or false
  return socket_lib or nil
end

function M.has_websocket() return load_socket() ~= nil end

-- Base64 (for the WebSocket handshake key)
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64(data)
  return ((data:gsub(".", function(x)
    local bits, b = "", x:byte()
    for i = 8, 1, -1 do bits = bits .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0") end
    return bits
  end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
    if #x < 6 then return "" end
    local c = 0
    for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
    return B64:sub(c + 1, c + 1)
  end) .. ({ "", "==", "=" })[#data % 3 + 1])
end
M._b64 = b64

local ws = nil       -- { sock = , next_id = }

local function ws_close()
  if ws and ws.sock then pcall(function() ws.sock:close() end) end
  ws = nil
end
M.disconnect = ws_close

local function recv_exact(sock, n)
  local data, err, partial = sock:receive(n)
  if data then return data end
  return nil, err, partial
end

local function ws_send(sock, payload, opcode)
  opcode = opcode or 0x1
  local len = #payload
  local hdr
  if len < 126 then hdr = string.char(0x80 | opcode, 0x80 | len)
  elseif len < 65536 then hdr = string.char(0x80 | opcode, 0x80 | 126, len >> 8, len & 0xFF)
  else
    hdr = string.char(0x80 | opcode, 0x80 | 127, 0, 0, 0, 0,
      (len >> 24) & 0xFF, (len >> 16) & 0xFF, (len >> 8) & 0xFF, len & 0xFF)
  end
  local m = { math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255) }
  local out, chunk = {}, {}
  for i = 1, len do
    chunk[#chunk + 1] = string.char(payload:byte(i) ~ m[(i - 1) % 4 + 1])
    if #chunk == 4096 then out[#out + 1] = table.concat(chunk); chunk = {} end
  end
  out[#out + 1] = table.concat(chunk)
  local frame = hdr .. string.char(m[1], m[2], m[3], m[4]) .. table.concat(out)
  local i = 1
  while i <= #frame do
    local sent, err, partial = sock:send(frame, i)
    if not sent then
      if err == "timeout" and partial and partial >= i then i = partial + 1
      else return nil, err end
    else
      i = sent + 1
    end
  end
  return true
end

-- Read one complete text message (handles fragmentation, ping/pong, close).
local function ws_recv(sock)
  local parts = {}
  while true do
    local h, err = recv_exact(sock, 2)
    if not h then return nil, err end
    local b1, b2 = h:byte(1, 2)
    local fin, opcode = (b1 & 0x80) ~= 0, b1 & 0x0F
    local masked, len = (b2 & 0x80) ~= 0, b2 & 0x7F
    if len == 126 then
      local e = recv_exact(sock, 2); if not e then return nil, "closed" end
      len = (e:byte(1) << 8) | e:byte(2)
    elseif len == 127 then
      local e = recv_exact(sock, 8); if not e then return nil, "closed" end
      len = 0
      for k = 1, 8 do len = (len << 8) | e:byte(k) end
    end
    local mask = masked and recv_exact(sock, 4) or nil
    local payload = len > 0 and recv_exact(sock, len) or ""
    if not payload then return nil, "closed" end
    if mask then
      local t = {}
      for k = 1, #payload do t[k] = string.char(payload:byte(k) ~ mask:byte((k - 1) % 4 + 1)) end
      payload = table.concat(t)
    end
    if opcode == 0x8 then return nil, "closed"
    elseif opcode == 0x9 then ws_send(sock, payload, 0xA)
    elseif opcode == 0xA then -- pong, ignore
    else
      parts[#parts + 1] = payload
      if fin then return table.concat(parts) end
    end
  end
end

local function ws_open()
  local socket = load_socket()
  if not socket then return nil, "nosocket" end
  local sock = socket.tcp()
  sock:settimeout(3)
  local ok, err = sock:connect("127.0.0.1", math.floor(tonumber(M.wamp_port) or 8080))
  if not ok then
    pcall(function() sock:close() end)
    return nil, "Couldn't reach Wwise on port " .. tostring(M.wamp_port) .. ". Is Wwise open with WAAPI enabled? " ..
      "(Project > User Preferences > Enable Wwise Authoring API; WAMP port " .. tostring(M.wamp_port) .. ")", "offline"
  end
  local key = {}
  for k = 1, 16 do key[k] = string.char(math.random(0, 255)) end
  local req = "GET /waapi HTTP/1.1\r\nHost: 127.0.0.1:" .. tostring(M.wamp_port) ..
    "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " .. b64(table.concat(key)) ..
    "\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: wamp.2.json\r\n\r\n"
  sock:send(req)
  local status = sock:receive("*l")
  if not status or not status:find(" 101") then
    pcall(function() sock:close() end)
    return nil, "Wwise refused the WebSocket connection (" .. tostring(status) .. ")."
  end
  repeat local line = sock:receive("*l") until not line or line == ""
  sock:settimeout(120)
  local ok2, serr = ws_send(sock, json.encode({ 1, "realm1", { roles = { caller = {}, subscriber = {} } } }))
  if not ok2 then pcall(function() sock:close() end); return nil, "WebSocket send failed: " .. tostring(serr) end
  local msg = ws_recv(sock)
  local okd, welcome = pcall(json.decode, msg or "")
  if not okd or type(welcome) ~= "table" or welcome[1] ~= 2 then
    pcall(function() sock:close() end)
    return nil, "Wwise didn't accept the WAMP session: " .. tostring(msg)
  end
  ws = { sock = sock, next_id = 1 }
  return ws
end

local function format_error(uri, kw)
  local detail = (type(kw) == "table" and kw.message) or uri or "unknown error"
  if type(kw) == "table" and kw.details and kw.details.log then
    local lines = {}
    for _, l in ipairs(kw.details.log) do lines[#lines + 1] = type(l) == "table" and (l.message or json.encode(l)) or tostring(l) end
    detail = detail .. "\n" .. table.concat(lines, "\n")
  end
  return detail
end

local function waapi_wamp(uri, args, options, retried)
  if not ws then
    local c, err, code = ws_open()
    if not c then return nil, err, code end
  end
  local id = ws.next_id
  ws.next_id = id + 1
  local ok, err = ws_send(ws.sock, json.encode({ 48, id, options or {}, uri, json.array(), args or {} }))
  if not ok then
    ws_close()
    if not retried then return waapi_wamp(uri, args, options, true) end
    return nil, "Lost connection to Wwise (" .. tostring(err) .. ")", "offline"
  end
  while true do
    local msg, rerr = ws_recv(ws.sock)
    if not msg then
      ws_close()
      if not retried and rerr == "closed" then return waapi_wamp(uri, args, options, true) end
      return nil, "Lost connection to Wwise (" .. tostring(rerr) .. ")", "offline"
    end
    local okd, m = pcall(json.decode, msg)
    if okd and type(m) == "table" then
      if m[1] == 50 and m[2] == id then
        return m[5] or {}
      elseif m[1] == 8 and m[3] == id then
        return nil, format_error(m[5], m[7]), m[5]
      elseif m[1] == 3 or m[1] == 6 then -- ABORT / GOODBYE
        ws_close()
        return nil, "Wwise closed the session.", "offline"
      end
    end
  end
end

local CURL = IS_WIN and "curl.exe" or "/usr/bin/curl"

local function waapi_http(uri, args, options)
  local body = json.encode({ uri = uri, args = args or {}, options = options or {} })
  local req = TMP .. SEP .. "request.json"
  local f = io.open(req, "wb")
  if not f then return nil, "Could not write " .. req end
  f:write(body); f:close()

  local cmd = string.format('%s -s -S --max-time 120 -w "\n@@HTTP %%{http_code}" -X POST -H "Content-Type: application/json" --data-binary "@%s" http://127.0.0.1:%d/waapi',
    CURL, req, math.floor(tonumber(M.http_port) or 8090))
  local out = r.ExecProcess(cmd, 125000)
  if not out then return nil, "curl did not run." end
  local code, text = out:match("^(%-?%d+)\r?\n?(.*)$")
  code = tonumber(code)
  if code ~= 0 then
    if code == 7 or code == 28 or (text or ""):find("onnect") then
      return nil, "Couldn't reach Wwise. Is Wwise open with WAAPI enabled? " ..
        "(Project > User Preferences > Enable Wwise Authoring API, HTTP port " .. tostring(M.http_port) .. ")", "offline"
    end
    return nil, "curl failed (" .. tostring(code) .. "): " .. tostring(text)
  end
  local http = tonumber((text or ""):match("@@HTTP (%d+)%s*$"))
  text = (text or ""):gsub("\r?\n?@@HTTP %d+%s*$", "")
  if http == 404 or http == 400 or http == 426 then
    return nil, "Wwise didn't accept the HTTP connection (HTTP " .. http .. "). " ..
      "Install \"Mavriq Lua Sockets\" from ReaPack so the script can use Wwise's WebSocket connection instead " ..
      "(see the Wwise Transfer README).", "offline"
  end
  if text == "" then return {} end
  local ok, res = pcall(json.decode, text)
  if not ok or type(res) ~= "table" then return nil, "Unexpected reply from Wwise: " .. tostring(text) end
  if type(res.uri) == "string" and res.uri:find("^ak%.") and res.message then
    return nil, format_error(res.uri, res), res.uri
  end
  return res
end

function M.transport_name() return load_socket() and "WebSocket" or "HTTP" end

function M.waapi(uri, args, options)
  if load_socket() then return waapi_wamp(uri, args, options) end
  return waapi_http(uri, args, options)
end

-- Connection info: version, project name, languages, root path.
function M.connect()
  local info, err = M.waapi("ak.wwise.core.getInfo")
  if not info then return nil, err end
  local v = info.version or {}
  local c = {
    year = tonumber(v.year) or 0,
    version = info.displayName or ((v.year or "?") .. "." .. (v.major or "?") .. "." .. (v.minor or "?")),
  }
  c.new_types = c.year >= 2025  -- Wwise 2025.1+: "Sound" type, "Containers" root
  c.root = c.new_types and "\\Containers" or "\\Actor-Mixer Hierarchy"
  local p = M.waapi("ak.wwise.core.object.get", { from = { ofType = { "Project" } } }, { ["return"] = { "name", "filePath" } })
  if p and p["return"] and p["return"][1] then
    c.project = p["return"][1].name
    c.project_path = p["return"][1].filePath
  end
  c.languages = {}
  local l = M.waapi("ak.wwise.core.object.get", { from = { ofType = { "Language" } } }, { ["return"] = { "name" } })
  if l and l["return"] then
    for _, o in ipairs(l["return"]) do
      if o.name ~= "SFX" and o.name ~= "External" and o.name ~= "Mixed" then c.languages[#c.languages + 1] = o.name end
    end
    table.sort(c.languages)
  end
  return c
end

-- First object selected in Wwise, as a path usable as an import destination.
function M.wwise_selection_path()
  local sel, err = M.waapi("ak.wwise.ui.getSelectedObjects", {}, { ["return"] = { "path", "type", "name" } })
  if not sel then return nil, err end
  local o = sel.objects and sel.objects[1]
  if not o then return nil, "Nothing is selected in Wwise." end
  local path = o.path
  if o.type == "Sound" or o.type == "AudioFileSource" or o.type == "MusicTrack" then
    path = path:match("^(.*)\\[^\\]+$") -- use its parent
  end
  return path, nil, o
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
                   "RENDER_ADDTOPROJ", "RENDER_TAILFLAG" }
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
local function mapping_pattern(s)
  local segs = {}
  for _, row in ipairs(s.rows) do segs[#segs + 1] = "@" .. (row.name or ""):gsub("[\\/]", "_") end
  if s.leaf.name ~= "" then segs[#segs + 1] = "@" .. s.leaf.name:gsub("[\\/]", "_") end
  if #segs == 0 then return nil end
  return table.concat(segs, "/")
end

local function parse_mapping(resolved, nrows, has_leaf)
  local parts = split(resolved, "/")
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
    out[i] = p:gsub("^@", ""):gsub("/@$", ""):gsub("/", "\\")
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
      entries[#entries + 1] = e
    end
  elseif #normal > 0 then
    set_n("RENDER_SETTINGS", (s.items_via_master and 64 or 32) | (s.mono_to_mono and 16 or 0))
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

-- Ask Wwise which planned objects already exist. Marks e.exists and returns the set of existing plain paths.
function M.mark_existing(plan)
  if plan.destination == "" then return {} end
  local res, err, code = M.waapi("ak.wwise.core.object.get",
    { from = { path = { plan.destination } }, transform = { { select = { "descendants" } } } },
    { ["return"] = { "path", "id" } })
  local existing = {}
  if not res then
    if code == "offline" then return existing, "offline" end
    plan.dest_missing = true
    for _, e in ipairs(plan.entries) do e.exists = false end
    return existing, err
  end
  plan.dest_missing = nil
  for _, o in ipairs(res["return"] or {}) do existing[o.path:lower()] = o.id end
  for _, e in ipairs(plan.entries) do e.exists = e.plain and existing[e.plain:lower()] ~= nil end
  return existing
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
  plan.outdir = outdir
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
      set_n("RENDER_SETTINGS", (s.items_via_master and 64 or 32) | (s.mono_to_mono and 16 or 0))
      set_n("RENDER_BOUNDSFLAG", 4)
      set_s("RENDER_PATTERN", "$item")
      M.render_command()
    end
    for _, e in ipairs(renders) do
      if e.kind == "folder" then
        r.SetOnlyTrackSelected(e.track)
        set_n("RENDER_SETTINGS", s.folders_via_master and 128 or 2)
        set_n("RENDER_BOUNDSFLAG", 0)
        set_n("RENDER_STARTPOS", e.pos)
        set_n("RENDER_ENDPOS", e.pos + e.len)
        set_s("RENDER_PATTERN", e.token)
        M.render_command()
      end
      local p = outdir .. SEP .. e.token .. ".wav"
      if file_exists(p) then
        -- Wwise names the file in Originals after the file, so give it the Sound's name.
        local final = outdir .. SEP .. e.name .. ".wav"
        local n = 1
        while file_exists(final) do n = n + 1; final = outdir .. SEP .. e.name .. "_" .. n .. ".wav" end
        if os.rename(p, final) then e.file = final else e.file = p end
        e.temp = true
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
  local summary = { errors = {}, created = 0, imported = 0, templates = 0, objects = {} }
  M.wamp_port, M.http_port = s.wamp_port, s.http_port

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
  local existing = M.mark_existing(plan)

  status("Rendering...")
  local ok, rerr = do_render(s, plan)
  if not ok then summary.errors[#summary.errors + 1] = "Render failed: " .. tostring(rerr); return summary end

  local imports = json.array()
  for _, e in ipairs(plan.entries) do
    if e.unresolved then
      summary.errors[#summary.errors + 1] = "Skipped one file: a wildcard in the hierarchy didn't resolve to a single name."
    elseif not e.file then
      summary.errors[#summary.errors + 1] = "Skipped \"" .. e.name .. "\": it didn't render."
    else
      local im = { audioFile = e.file, objectPath = e.path }
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
    M.waapi("ak.wwise.core.undo.endGroup", { displayName = "Wwise Transfer (failed)" })
    summary.errors[#summary.errors + 1] = "Wwise import failed: " .. tostring(ierr)
    return summary
  end
  summary.imported = #imports

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

  M.waapi("ak.wwise.core.undo.endGroup", { displayName = "Wwise Transfer from REAPER" })

  if s.select_in_wwise and #ids > 0 then
    M.waapi("ak.wwise.ui.commands.execute", { command = "FindInProjectExplorerSyncGroup1", objects = ids })
  end

  -- Clean up temp renders (Wwise copied them into Originals).
  for _, e in ipairs(plan.entries) do if e.temp and e.file then os.remove(e.file) end end
  if plan.outdir then os.remove(plan.outdir) end
  return summary
end

return M
