-- vendored from nvim-kit@0.17.0 (lua/nvim_kit/vrix.lua) — do not edit; re-vendor
-- The VRIX container: the one file (`index.bin`) of a note index. A port of code-kit
-- `index-container.ts` (tag 0.31.1) and its `crc32`, proven by the conformance vectors and byte
-- for byte what vault-rag writes.
--
-- Layout: "VRIX" · u32 headerLen LE · header JSON (manifest + paths [+ stamps]) · int8 matrix ·
-- u32 CRC32 LE (over everything before it).
--
-- The format is frozen: the magic, `schema_version` 2 and the ORDER of the header keys are what
-- every index on disk carries (`encode(decode(x))` gives the same bytes back). Lua's
-- `vim.json.decode` loses key order, so `HEADER_KEYS` is the order; `vim.json.encode` is not used
-- for the header either (it masks DEL as `\u007f`, `JSON.stringify` writes the byte).
--
-- One edge differs from the source: the header is read with `vim.json.decode`, which is more
-- lenient than `JSON.parse` (`NaN`, `0x10`, ...). The CRC has to match first, so only a file
-- somebody wrote on purpose could carry such a header.
local bit = require('bit')

local M = {}

M.SCHEMA_VERSION = 2

--- The keys of the header, in the order they are written.
M.HEADER_KEYS = {
  'schema_version',
  'vault',
  'embedding_model',
  'source_dim',
  'index_dim',
  'granularity',
  'aggregation',
  'quant',
  'scale',
  'count',
  'source_commit',
  'built_at',
  'paths',
  'stamps',
}

local MAGIC = 'VRIX'
local byte, char, floor, concat = string.byte, string.char, math.floor, table.concat

local TABLE = {}
for n = 0, 255 do
  local c = n
  for _ = 1, 8 do
    if bit.band(c, 1) == 1 then
      c = bit.bxor(bit.rshift(c, 1), 0xEDB88320)
    else
      c = bit.rshift(c, 1)
    end
  end
  TABLE[n] = c
end

--- CRC-32 (ISO-HDLC, the one of zip and PNG) of the byte string `bytes`, as a number from 0 to 2^32 - 1.
function M.crc32(bytes)
  if type(bytes) ~= 'string' then
    error('nvim-kit vrix: crc32 needs a byte string', 2)
  end
  local crc = 0xFFFFFFFF
  for i = 1, #bytes do
    crc = bit.bxor(TABLE[bit.bxor(bit.band(crc, 0xFF), byte(bytes, i))], bit.rshift(crc, 8))
  end
  return bit.bxor(crc, 0xFFFFFFFF) % 4294967296
end

local function u32_le(n)
  return char(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256)
end

local function read_u32_le(s, pos)
  local a, b, c, d = byte(s, pos, pos + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end

local EMPTY_DICT_MT = getmetatable(vim.empty_dict())

-- A decoded JSON object: a table with a key that is not an array index, or an empty one that
-- `vim.json.decode` marked as `{}` (a plain empty table is `[]`).
local function is_object(v)
  if type(v) ~= 'table' then
    return false
  end
  local k = next(v)
  if k == nil then
    return getmetatable(v) == EMPTY_DICT_MT
  end
  for key in pairs(v) do
    if type(key) ~= 'number' then
      return true
    end
  end
  return false
end

local function is_array(v)
  return type(v) == 'table' and not is_object(v)
end

local function finite_number(v)
  return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

-- Stamps are only good if they match `paths` row for row; otherwise there is none (a wrong guard
-- is worse than no guard).
local function stamps_valid(stamps, path_count)
  if not is_array(stamps) or #stamps ~= path_count then
    return false
  end
  for _, e in ipairs(stamps) do
    if not (is_array(e) and #e == 2 and finite_number(e[1]) and finite_number(e[2])) then
      return false
    end
  end
  return true
end

--- Reads a container. Returns `{ manifest, paths, matrix, stamps? }` (`matrix` a byte string of
--- int8 rows, `manifest` the header without `paths` and `stamps`, `stamps` a list of
--- `{ mtime, size }` only when it is usable), or `nil, reason` with `reason` one of `truncated`,
--- `magic`, `crc`, `header`, `schema` (checked in this order).
function M.decode(bytes)
  if type(bytes) ~= 'string' then
    error('nvim-kit vrix: decode needs a byte string', 2)
  end
  local n = #bytes
  if n < 12 then
    return nil, 'truncated'
  end
  if bytes:sub(1, 4) ~= MAGIC then
    return nil, 'magic'
  end
  local header_len = read_u32_le(bytes, 5)
  if 8 + header_len + 4 > n then
    return nil, 'truncated'
  end
  if read_u32_le(bytes, n - 3) ~= M.crc32(bytes:sub(1, n - 4)) then
    return nil, 'crc'
  end
  local ok, header = pcall(vim.json.decode, bytes:sub(9, 8 + header_len), { luanil = { object = true } })
  if not ok then
    return nil, 'header'
  end
  if not is_object(header) then
    return nil, 'header'
  end
  if header.schema_version ~= M.SCHEMA_VERSION then
    return nil, 'schema'
  end
  local paths, stamps = header.paths, header.stamps
  if not is_array(paths) then
    return nil, 'header'
  end
  for i = 1, #paths do
    if type(paths[i]) ~= 'string' then
      return nil, 'header'
    end
  end
  local manifest = {}
  for k, v in pairs(header) do
    if k ~= 'paths' and k ~= 'stamps' then
      manifest[k] = v
    end
  end
  local out = { manifest = manifest, paths = paths, matrix = bytes:sub(9 + header_len, n - 4) }
  if stamps_valid(stamps, #paths) then
    out.stamps = stamps
  end
  return out
end

local ESCAPES = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}

-- JSON.stringify for a string: `"` and `\` escaped, \b \f \n \r \t short, the other bytes below
-- 0x20 as \u00xx in lower case; everything else raw, DEL (0x7f) and `/` included. (`%c` would
-- match DEL, so the class is spelled out.)
local function json_string(s)
  return '"'
    .. s:gsub('[%z\1-\31"\\]', function(c)
      return ESCAPES[c] or ('\\u%04x'):format(byte(c))
    end)
    .. '"'
end

local MAX_SAFE = 2 ^ 53

local function json_integer(v, what)
  if type(v) ~= 'number' or v ~= floor(v) or v ~= v or math.abs(v) > MAX_SAFE then
    error(('nvim-kit vrix: encode writes only integers (%s)'):format(what), 3)
  end
  if v == 0 then
    return '0'
  end
  return ('%.0f'):format(v)
end

local function json_value(v, what)
  if type(v) == 'string' then
    return json_string(v)
  end
  return json_integer(v, what)
end

local MANIFEST_KEYS = {}
for _, k in ipairs(M.HEADER_KEYS) do
  if k ~= 'paths' and k ~= 'stamps' then
    MANIFEST_KEYS[k] = true
  end
end

--- Writes a container: the manifest's keys in `HEADER_KEYS` order with `schema_version` 2, then
--- `paths` and, only when it is as long as `paths`, `stamps` (a list of `{ mtime, size }`). The
--- header is compact JSON as `JSON.stringify` writes it. `matrix` is the byte string of the int8
--- rows. Values in the manifest are strings or integers; a key that is not in `HEADER_KEYS` (or
--- is `paths`/`stamps`), a fractional number or another type raises.
function M.encode(manifest, paths, matrix, stamps)
  if type(manifest) ~= 'table' or type(paths) ~= 'table' or type(matrix) ~= 'string' then
    error('nvim-kit vrix: encode needs a manifest table, a list of paths and a byte string', 2)
  end
  for k in pairs(manifest) do
    if not MANIFEST_KEYS[k] then
      error(('nvim-kit vrix: encode: unknown manifest key %s'):format(tostring(k)), 2)
    end
  end
  local parts = {}
  for _, k in ipairs(M.HEADER_KEYS) do
    if k == 'schema_version' then
      parts[#parts + 1] = '"schema_version":' .. M.SCHEMA_VERSION
    elseif MANIFEST_KEYS[k] then
      if manifest[k] ~= nil then
        parts[#parts + 1] = json_string(k) .. ':' .. json_value(manifest[k], k)
      end
    elseif k == 'paths' then
      local items = {}
      for i = 1, #paths do
        if type(paths[i]) ~= 'string' then
          error('nvim-kit vrix: encode: paths must be strings', 2)
        end
        items[i] = json_string(paths[i])
      end
      parts[#parts + 1] = '"paths":[' .. concat(items, ',') .. ']'
    elseif stamps and #stamps == #paths then
      local items = {}
      for i, e in ipairs(stamps) do
        if type(e) ~= 'table' or #e ~= 2 then
          error('nvim-kit vrix: encode: a stamp is { mtime, size }', 2)
        end
        items[i] = '[' .. json_integer(e[1], 'stamp') .. ',' .. json_integer(e[2], 'stamp') .. ']'
      end
      parts[#parts + 1] = '"stamps":[' .. concat(items, ',') .. ']'
    end
  end
  local header = '{' .. concat(parts, ',') .. '}'
  local body = MAGIC .. u32_le(#header) .. header .. matrix
  return body .. u32_le(M.crc32(body))
end

return M
