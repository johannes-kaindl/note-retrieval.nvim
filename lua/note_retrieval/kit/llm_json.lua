-- vendored from nvim-kit@0.17.1 (lua/nvim_kit/llm_json.lua) — do not edit; re-vendor
-- Reading a model's answer: <think> blocks out, then the first JSON object. A port of code-kit
-- src/ts/pure/think-splitter.ts (stripThinkBlocks) and src/ts/pure/llm-json.ts
-- (extractJsonCandidates, firstJsonObject), checked against code-kit's conformance vectors.
-- Positions are bytes, not UTF-16 units; every character the scan looks at is ASCII, so the
-- spans are the same.
local M = {}

local OPEN, CLOSE = '<think>', '</think>'

local function find(s, needle, from)
  return s:find(needle, from, true)
end

local function last_find(s, needle)
  local at, from = nil, 1
  while true do
    local i = find(s, needle, from)
    if not i then
      return at
    end
    at, from = i, i + 1
  end
end

--- <think>…</think> out of a complete text. Pairs always go (an open pairs with the nearest close
--- after it); opts.drop_stray_close drops everything up to the LAST close without an open,
--- opts.drop_unclosed drops an unclosed open and everything after it. Linear in the text.
function M.strip_think(text, opts)
  opts = opts or {}
  local out = text
  local open = find(out, OPEN, 1)
  if open then
    local parts, from = {}, 1
    while open do
      local close = find(out, CLOSE, open + #OPEN)
      if not close then
        break -- no close after this open: none after a later one either
      end
      parts[#parts + 1] = out:sub(from, open - 1)
      from = close + #CLOSE
      open = find(out, OPEN, from)
    end
    parts[#parts + 1] = out:sub(from)
    out = table.concat(parts)
  end
  if opts.drop_stray_close then
    local stray = last_find(out, CLOSE)
    if stray then
      out = out:sub(stray + #CLOSE)
    end
  end
  if opts.drop_unclosed then
    local unclosed = find(out, OPEN, 1)
    if unclosed then
      out = out:sub(1, unclosed - 1)
    end
  end
  return out
end

-- Strict JSON (ECMA-404, what JS JSON.parse accepts). vim.json.decode also takes NaN, Infinity,
-- hex numbers, leading zeros, +1, 1. and raw control characters in strings (measured on
-- Neovim 0.12); a span counts only when this check passes. Iterative, so deep nesting costs no
-- Lua stack.
local WS = { [0x20] = true, [0x09] = true, [0x0A] = true, [0x0D] = true }
local ESC = {}
for c in ('"\\/bfnrt'):gmatch('.') do
  ESC[c:byte()] = true
end

local function skip_ws(s, i)
  while WS[s:byte(i)] do
    i = i + 1
  end
  return i
end

local function digits(s, i)
  local j = i
  while true do
    local b = s:byte(j)
    if not b or b < 0x30 or b > 0x39 then
      return j
    end
    j = j + 1
  end
end

-- End (exclusive) of the string starting at the quote at i, or nil.
local function scan_string(s, i)
  i = i + 1
  while true do
    local b = s:byte(i)
    if not b or b < 0x20 then
      return nil
    elseif b == 0x22 then
      return i + 1
    elseif b == 0x5C then
      local e = s:byte(i + 1)
      if e == 0x75 then
        if not s:sub(i + 2, i + 5):match('^%x%x%x%x$') then
          return nil
        end
        i = i + 6
      elseif e and ESC[e] then
        i = i + 2
      else
        return nil
      end
    else
      i = i + 1
    end
  end
end

-- End (exclusive) of the number at i, or nil.
local function scan_number(s, i)
  local j = i
  if s:byte(j) == 0x2D then
    j = j + 1
  end
  local b = s:byte(j)
  if b == 0x30 then
    j = j + 1
  elseif b and b >= 0x31 and b <= 0x39 then
    j = digits(s, j + 1)
  else
    return nil
  end
  if s:byte(j) == 0x2E then
    local k = digits(s, j + 1)
    if k == j + 1 then
      return nil
    end
    j = k
  end
  b = s:byte(j)
  if b == 0x65 or b == 0x45 then
    j = j + 1
    b = s:byte(j)
    if b == 0x2B or b == 0x2D then
      j = j + 1
    end
    local k = digits(s, j)
    if k == j then
      return nil
    end
    j = k
  end
  return j
end

local LITERALS = { t = 'true', f = 'false', n = 'null' }

--- True when s is exactly one JSON value (surrounding whitespace allowed), as JSON.parse demands.
function M.is_strict_json(s)
  local stack = {} -- '{' or '['
  local i = skip_ws(s, 1)
  local expect = 'value' -- value | key | colon | comma_or_close | value_or_close | key_or_close
  while true do
    local c = s:sub(i, i)
    if expect == 'value' or expect == 'value_or_close' then
      if expect == 'value_or_close' and c == ']' then
        table.remove(stack)
        i = i + 1
        expect = 'comma_or_close'
      elseif c == '{' then
        stack[#stack + 1] = '{'
        i = i + 1
        expect = 'key_or_close'
      elseif c == '[' then
        stack[#stack + 1] = '['
        i = i + 1
        expect = 'value_or_close'
      elseif c == '"' then
        i = scan_string(s, i)
        expect = 'comma_or_close'
      elseif LITERALS[c] then
        local lit = LITERALS[c]
        if s:sub(i, i + #lit - 1) ~= lit then
          return false
        end
        i = i + #lit
        expect = 'comma_or_close'
      else
        i = scan_number(s, i)
        expect = 'comma_or_close'
      end
    elseif expect == 'key' or expect == 'key_or_close' then
      if expect == 'key_or_close' and c == '}' then
        table.remove(stack)
        i = i + 1
        expect = 'comma_or_close'
      elseif c == '"' then
        i = scan_string(s, i)
        expect = 'colon'
      else
        return false
      end
    elseif expect == 'colon' then
      if c ~= ':' then
        return false
      end
      i = i + 1
      expect = 'value'
    else -- comma_or_close
      local top = stack[#stack]
      if not top then
        return i > #s
      elseif c == ',' then
        i = i + 1
        expect = top == '{' and 'key' or 'value'
      elseif (c == '}' and top == '{') or (c == ']' and top == '[') then
        table.remove(stack)
        i = i + 1
      else
        return false
      end
    end
    if not i then
      return false
    end
    i = skip_ws(s, i)
  end
end

local function strict_decode(span)
  if not M.is_strict_json(span) then
    return false, 'not strict JSON'
  end
  -- vim.json still refuses what JSON.parse takes: a lone surrogate escape (\ud800) and nesting
  -- deeper than 1000. Both count as not parsed (measured on Neovim 0.12).
  return pcall(vim.json.decode, span, { luanil = { object = true } })
end

local FENCE = '```'

-- Bodies of the closed fenced blocks, in order: three backticks, a tag line without a backtick,
-- a line break, the body up to the next three backticks.
local function fenced_bodies(text, json_only)
  local bodies, from = {}, 1
  while true do
    local open = find(text, FENCE, from)
    if not open then
      return bodies
    end
    local p = open + #FENCE
    local tag_start = p
    while p <= #text and text:byte(p) ~= 10 and text:byte(p) ~= 96 do
      p = p + 1
    end
    if text:byte(p) ~= 10 then
      from = open + 1 -- a backtick or the end before a line break: not an opener
    else
      local close = find(text, FENCE, p + 1)
      if not close then
        return bodies -- never closed: no block (the whole text still sees its brackets)
      end
      if not json_only or vim.trim(text:sub(tag_start, p - 1)):lower() == 'json' then
        bodies[#bodies + 1] = text:sub(p + 1, close - 1)
      end
      from = close + #FENCE
    end
  end
end

-- For the opener at start: the index of its partner, or false if it stays open. One walk fills
-- `ends` for every opener it passes outside a string, which keeps the search linear; `meter`
-- counts the bytes walked (code-kit balancedEnd).
local function balanced_end(s, start, ends, meter)
  local known = ends[start]
  if known ~= nil then
    return known
  end
  local open, in_string, i, n = {}, false, start, #s
  while i <= n do
    local c = s:byte(i)
    if in_string then
      if c == 0x5C then
        i = i + 1
      elseif c == 0x22 then
        in_string = false
      end
    elseif c == 0x22 then
      in_string = true
    elseif c == 0x5B or c == 0x7B then
      open[#open + 1] = i
    elseif c == 0x5D or c == 0x7D then
      local opener = table.remove(open)
      if not opener then
        break
      end
      ends[opener] = i
      if #open == 0 then
        meter.work = meter.work + i - start + 1
        return i
      end
    end
    i = i + 1
  end
  meter.work = meter.work + math.min(i, n + 1) - start
  for _, opener in ipairs(open) do
    ends[opener] = false
  end
  local e = ends[start]
  if e == nil then
    return false
  end
  return e
end

-- Twelve passes over the text plus a floor: past it the search of this source stops (truncated).
local function budget_for(length)
  return 12 * length + 65536
end

local function normalize_quotes(s)
  return (
    s:gsub('\226\128\156', '"')
      :gsub('\226\128\157', '"')
      :gsub('\226\128\158', '"')
      :gsub('\226\128\152', "'")
      :gsub('\226\128\153', "'")
      :gsub('\226\128\154', "'")
  )
end

-- JS \s: ASCII whitespace plus the Unicode space separators, U+00A0, U+FEFF and the line and
-- paragraph separators. Lua's %s knows none of the non-ASCII ones (U+00A0, finding M9).
local UNICODE_SPACES = {
  '\194\160', -- U+00A0
  '\225\154\128', -- U+1680
  '\226\128\168', -- U+2028
  '\226\128\169', -- U+2029
  '\226\128\175', -- U+202F
  '\226\129\159', -- U+205F
  '\227\128\128', -- U+3000
  '\239\187\191', -- U+FEFF
}
for k = 0, 10 do -- U+2000 … U+200A
  UNICODE_SPACES[#UNICODE_SPACES + 1] = string.char(0xE2, 0x80, 0x80 + k)
end

-- Length of the JS whitespace character at i, or 0.
local function space_len(s, i)
  local b = s:byte(i)
  if b == 0x20 or (b and b >= 0x09 and b <= 0x0D) then
    return 1
  end
  if b and b >= 0xC2 then
    for _, u in ipairs(UNICODE_SPACES) do
      if s:sub(i, i + #u - 1) == u then
        return #u
      end
    end
  end
  return 0
end

-- `,\s*([}\]])` → `$1`, as the JS replace does it: left to right, inside strings too.
local function drop_trailing_commas(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == ',' then
      local j = i + 1
      while true do
        local l = space_len(s, j)
        if l == 0 then
          break
        end
        j = j + l
      end
      local nxt = s:sub(j, j)
      if nxt == '}' or nxt == ']' then
        i = j -- drop the comma and the whitespace, keep the bracket
      else
        out[#out + 1] = c
        i = i + 1
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

local function scan_sources(sources, allow_array, repair)
  local scan = { values = {}, truncated = false, broken = false }
  for _, src in ipairs(sources) do
    local ends, meter, budget = {}, { work = 0 }, budget_for(#src)
    local i, n = 1, #src
    while i <= n do
      local c = src:byte(i)
      if c == 0x7B or (allow_array and c == 0x5B) then
        if meter.work > budget then
          scan.truncated = true -- out of budget: the rest of this source stays unread
          break
        end
        local e = balanced_end(src, i, ends, meter)
        if not e then
          scan.truncated = true
        else
          local span = src:sub(i, e)
          meter.work = meter.work + #span
          local ok, value = strict_decode(span)
          if ok then
            scan.values[#scan.values + 1] = value
            i = e -- nothing nested is a candidate of its own again
          else
            scan.broken, scan.error = true, value
            if repair then
              meter.work = meter.work + #span
              ok, value = strict_decode(drop_trailing_commas(span))
              if ok then
                scan.values[#scan.values + 1] = value
                scan.broken = false
                i = e
              else
                scan.error = value
              end
            end
          end
        end
      end
      i = i + 1
    end
  end
  return scan
end

local DEFAULT_THINK = { drop_stray_close = true, drop_unclosed = true }

--- All JSON candidates of a model answer, in reading order (code-kit extractJsonCandidates).
--- opts = { think = <strip_think opts|false>, fence = 'all'|'first'|'last',
---          fence_tag = 'any'|'json', repair = <bool>, allow_array = <bool> }
--- → { ok = true, values, truncated } | { ok = false, reason = 'no-json'|'invalid-json'|'truncated', error }
function M.candidates(raw, opts)
  opts = opts or {}
  local think = opts.think == nil and DEFAULT_THINK or opts.think
  local text = think == false and raw or M.strip_think(raw, think)
  local allow_array = opts.allow_array ~= false
  local mode = opts.fence or 'all'
  local json_only = opts.fence_tag == 'json'
  local function pick(t, fenced)
    if mode == 'all' then
      local all = vim.list_extend({}, fenced)
      all[#all + 1] = t
      return all
    end
    if #fenced == 0 then
      return { t }
    end
    return { mode == 'first' and fenced[1] or fenced[#fenced] }
  end
  local scan = scan_sources(pick(text, fenced_bodies(text, json_only)), allow_array, false)
  if #scan.values == 0 and opts.repair == true then
    local normalized = normalize_quotes(text)
    scan = scan_sources(pick(normalized, fenced_bodies(normalized, json_only)), allow_array, true)
  end
  if #scan.values > 0 then
    return { ok = true, values = scan.values, truncated = scan.truncated }
  end
  local reason = scan.truncated and 'truncated' or scan.broken and 'invalid-json' or 'no-json'
  return { ok = false, reason = reason, error = scan.error }
end

--- The first candidate that is a JSON object, decoded (nulls inside it are absent fields), or nil.
--- Strips <think> first and reads fenced blocks before the whole text; see M.candidates for opts.
function M.first_json_object(raw, opts)
  local o = vim.tbl_extend('force', opts or {}, { allow_array = false })
  local r = M.candidates(raw, o)
  if not r.ok then
    return nil
  end
  local first = r.values[1]
  if type(first) == 'table' and (next(first) == nil or not vim.islist(first)) then
    return first
  end
  return nil
end

return M
