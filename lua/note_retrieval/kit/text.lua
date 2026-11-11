-- vendored from nvim-kit@0.17.0 (lua/nvim_kit/text.lua) — do not edit; re-vendor
-- Small text pieces for plugin views.
local M = {}

--- A text progress bar: `[███░░░░░░░]` for pct (0–100, clamped) over width cells.
function M.bar(pct, width)
  pct = math.max(0, math.min(100, pct))
  local filled = math.floor(pct / 100 * width + 0.5)
  return '[' .. string.rep('█', filled) .. string.rep('░', width - filled) .. ']'
end

-- The length of a valid UTF-8 sequence starting at byte i of s, or nil (RFC 3629: no overlong
-- forms, no surrogates, nothing above U+10FFFF).
local function utf8_len(s, i)
  local c = s:byte(i)
  local len, lo, hi
  if c < 0x80 then
    return 1
  elseif c >= 0xC2 and c <= 0xDF then
    len, lo, hi = 2, 0x80, 0xBF
  elseif c >= 0xE0 and c <= 0xEF then
    len = 3
    lo = c == 0xE0 and 0xA0 or 0x80
    hi = c == 0xED and 0x9F or 0xBF
  elseif c >= 0xF0 and c <= 0xF4 then
    len = 4
    lo = c == 0xF0 and 0x90 or 0x80
    hi = c == 0xF4 and 0x8F or 0xBF
  else
    return nil
  end
  if i + len - 1 > #s then
    return nil
  end
  local b = s:byte(i + 1)
  if b < lo or b > hi then
    return nil
  end
  for k = 2, len - 1 do
    b = s:byte(i + k)
    if b < 0x80 or b > 0xBF then
      return nil
    end
  end
  return len
end

--- s with every byte that is not part of valid UTF-8 replaced by U+FFFD; s itself when it is valid.
--- vim.json.encode copies invalid bytes into its output, and a server then rejects the JSON.
function M.clean_utf8(s)
  local out, i, from = nil, 1, 1
  while i <= #s do
    local len = utf8_len(s, i)
    if len then
      i = i + len
    else
      out = out or {}
      out[#out + 1] = s:sub(from, i - 1)
      out[#out + 1] = '\239\191\189'
      i = i + 1
      from = i
    end
  end
  if not out then
    return s
  end
  out[#out + 1] = s:sub(from)
  return table.concat(out)
end

-- The length of the character at byte i of s as Vim counts it (utf_ptr2len): the length its lead
-- byte announces when all those continuation bytes follow, else 1.
local function char_len(s, i)
  local c = s:byte(i)
  local len = c >= 0xFC and c <= 0xFD and 6
    or c >= 0xF8 and c <= 0xFB and 5
    or c >= 0xF0 and c <= 0xF7 and 4
    or c >= 0xE0 and c <= 0xEF and 3
    or c >= 0xC0 and c <= 0xDF and 2
    or 1
  for k = 1, len - 1 do
    local b = s:byte(i + k)
    if not b or b < 0x80 or b > 0xBF then
      return 1
    end
  end
  return len
end

--- s cut to its first max_chars characters plus mark (default U+2026) when it is longer, else s
--- itself. Counts characters (UTF-8 code points), not bytes, so it never cuts inside a multibyte
--- character. Counted in plain Lua the way vim.fn.strchars counts: a lead byte 0xC0..0xFD
--- followed by all the continuation bytes (0x80..0xBF) it announces is one character (2 to 6
--- bytes, as Vim reads them: overlong forms and surrogates included); every other byte is one
--- character, so a run of stray continuation bytes counts byte by byte. A NUL byte is a
--- character too (vim.fn.strchars raised E976 on it), and it runs in a fast callback.
function M.truncate(s, max_chars, mark)
  if type(s) ~= 'string' then
    error('nvim-kit text: truncate needs s (a string)', 2)
  end
  if type(max_chars) ~= 'number' or max_chars < 0 or max_chars % 1 ~= 0 then
    error('nvim-kit text: truncate needs max_chars (a non-negative whole number)', 2)
  end
  if mark ~= nil and type(mark) ~= 'string' then
    error('nvim-kit text: truncate: mark must be a string', 2)
  end
  local n, i = 0, 1
  while i <= #s do
    n = n + 1
    if n > max_chars then
      return s:sub(1, i - 1) .. (mark == nil and '…' or mark)
    end
    i = i + char_len(s, i)
  end
  return s
end

-- Language code (lower case, two letters) → the name a model understands; a code alone is too quiet a hint.
local LANGUAGES = {
  cs = 'Czech',
  da = 'Danish',
  de = 'German',
  en = 'English',
  es = 'Spanish',
  fi = 'Finnish',
  fr = 'French',
  it = 'Italian',
  ja = 'Japanese',
  ko = 'Korean',
  nb = 'Norwegian',
  nl = 'Dutch',
  no = 'Norwegian',
  pl = 'Polish',
  pt = 'Portuguese',
  ru = 'Russian',
  sv = 'Swedish',
  tr = 'Turkish',
  uk = 'Ukrainian',
  zh = 'Chinese',
}

--- The English name of the language in a locale or language code: `'de_DE.UTF-8'`, `'de'` and
--- `'pt_BR'` give `'German'`, `'German'`, `'Portuguese'`. A code is two letters, alone or followed
--- by `_`, `.`, `-` or `@` and anything (region, encoding, modifier), in either case. `lang` nil
--- reads `vim.v.lang`. `'C'`, `'POSIX'`, an empty string and every code outside the 20 known
--- ones (cs da de en es fi fr it ja ko nb nl no pl pt ru sv tr uk zh) give `'English'`. Raises
--- when `lang` is neither nil nor a string. Which option or variable to read is the caller's.
function M.language_name(lang)
  if lang == nil then
    lang = vim.v.lang
  end
  if type(lang) ~= 'string' then
    error('nvim-kit text: language_name: lang must be a string or nil', 2)
  end
  local code = lang:match('^(%a%a)[_.%-@]') or lang:match('^(%a%a)$')
  return LANGUAGES[(code or ''):lower()] or 'English'
end

-- The code point and byte length of the character at byte i of s, read from its lead byte. The
-- UTF-16 and trim helpers below assume valid UTF-8 (`clean_utf8` first): a stray byte reads as
-- one character of its own, like the U+FFFD that `clean_utf8` would put there.
local function decode(s, i)
  local c = s:byte(i)
  if c < 0xC2 or c > 0xF4 then
    return c, 1
  end
  local b1, b2, b3 = s:byte(i + 1, i + 3)
  if c < 0xE0 then
    if b1 and b1 >= 0x80 and b1 <= 0xBF then
      return (c - 0xC0) * 0x40 + (b1 - 0x80), 2
    end
  elseif c < 0xF0 then
    if b1 and b2 and b1 >= 0x80 and b1 <= 0xBF and b2 >= 0x80 and b2 <= 0xBF then
      return ((c - 0xE0) * 0x40 + (b1 - 0x80)) * 0x40 + (b2 - 0x80), 3
    end
  elseif
    b1
    and b2
    and b3
    and b1 >= 0x80
    and b1 <= 0xBF
    and b2 >= 0x80
    and b2 <= 0xBF
    and b3 >= 0x80
    and b3 <= 0xBF
  then
    return (((c - 0xF0) * 0x40 + (b1 - 0x80)) * 0x40 + (b2 - 0x80)) * 0x40 + (b3 - 0x80), 4
  end
  return c, 1
end

--- The code point and the byte length of the character at byte index i of s (1-based), read from
--- its lead byte; a byte that starts no complete sequence is one character of its own, with its
--- byte value as code point. Valid UTF-8 is read exactly (`clean_utf8` first when in doubt).
function M.char_at(s, i)
  if type(s) ~= 'string' then
    error('nvim-kit text: char_at needs s (a string)', 2)
  end
  if type(i) ~= 'number' or i % 1 ~= 0 or i < 1 or i > #s then
    error('nvim-kit text: char_at needs i (a byte index inside s)', 2)
  end
  return decode(s, i)
end

-- The UTF-16 length of one character: two code units from U+10000 on.
local function units_of(cp)
  return cp >= 0x10000 and 2 or 1
end

local function check_string(s, fn)
  if type(s) ~= 'string' then
    error(('nvim-kit text: %s needs s (a string)'):format(fn), 3)
  end
end

--- The length of s in UTF-16 code units, as JavaScript's `.length` counts it: a character up to
--- U+FFFF is one unit, one from U+10000 on (emoji) is two. Assumes valid UTF-8 (`clean_utf8`
--- first): a stray byte counts as one unit, like the U+FFFD that `clean_utf8` puts there.
function M.utf16_len(s)
  check_string(s, 'utf16_len')
  local n, i = 0, 1
  while i <= #s do
    local cp, len = decode(s, i)
    n = n + units_of(cp)
    i = i + len
  end
  return n
end

--- The part of s from UTF-16 unit i up to (not including) unit j, both 0-based like JavaScript's
--- `slice`; j nil runs to the end, j <= i gives an empty string. Both bounds are whole numbers
--- of at least 0. A bound inside a surrogate pair cannot cut a UTF-8 character: the whole
--- character stays in the front part (so `utf16_sub('a😀b', 1, 2)` is `'😀'`, and a start inside
--- the pair begins after it). Assumes valid UTF-8, like `utf16_len`.
function M.utf16_sub(s, i, j)
  check_string(s, 'utf16_sub')
  if type(i) ~= 'number' or i < 0 or i % 1 ~= 0 then
    error('nvim-kit text: utf16_sub needs i (a whole number of at least 0)', 2)
  end
  if j ~= nil and (type(j) ~= 'number' or j < 0 or j % 1 ~= 0) then
    error('nvim-kit text: utf16_sub: j must be nil or a whole number of at least 0', 2)
  end
  if j ~= nil and j <= i then
    return ''
  end
  local unit, pos, first = 0, 1, nil
  while pos <= #s do
    if not first and unit >= i then
      first = pos
    end
    if j ~= nil and unit >= j then
      return first and s:sub(first, pos - 1) or ''
    end
    local cp, len = decode(s, pos)
    unit = unit + units_of(cp)
    pos = pos + len
  end
  if not first then
    return ''
  end
  return s:sub(first)
end

--- Whether code point cp is whitespace to JavaScript (`\s`, `trim()`): U+0009-U+000D, U+0020,
--- U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F, U+3000 and U+FEFF. Lua's `%s`
--- and `vim.trim` know the ASCII ones only.
function M.is_js_space(cp)
  if type(cp) ~= 'number' then
    error('nvim-kit text: is_js_space needs cp (a code point)', 2)
  end
  return (cp >= 0x09 and cp <= 0x0D)
    or cp == 0x20
    or cp == 0xA0
    or cp == 0x1680
    or (cp >= 0x2000 and cp <= 0x200A)
    or cp == 0x2028
    or cp == 0x2029
    or cp == 0x202F
    or cp == 0x205F
    or cp == 0x3000
    or cp == 0xFEFF
end

local is_js_space = M.is_js_space

--- s without the whitespace JavaScript's `trim()` strips at both ends (see `is_js_space`).
function M.js_trim(s)
  check_string(s, 'js_trim')
  local first, i = 1, 1
  while i <= #s do
    local cp, len = decode(s, i)
    if not is_js_space(cp) then
      break
    end
    i = i + len
    first = i
  end
  if first > #s then
    return ''
  end
  local last = #s
  while last >= first do
    -- the start of the last character: back over continuation bytes, at most three
    local start = last
    while start > first and last - start < 3 and s:byte(start) >= 0x80 and s:byte(start) <= 0xBF do
      start = start - 1
    end
    local cp, len = decode(s, start)
    if start + len - 1 ~= last then
      -- not one complete character ending at last: the stray byte is a character of its own
      cp = s:byte(last)
      start = last
    end
    if not is_js_space(cp) then
      break
    end
    last = start - 1
  end
  return s:sub(first, last)
end

--- Whether a sorts before b by bytes, never by the locale (Lua's `<` may use `strcoll`; a
--- collating locale puts `a` before `Z`). For valid UTF-8 byte order is code point order, which
--- is JavaScript's UTF-16 order except for one pair: a character beyond U+FFFF sorts before
--- U+E000-U+FFFF in UTF-16 and after it in bytes.
function M.byte_less(a, b)
  if type(a) ~= 'string' or type(b) ~= 'string' then
    error('nvim-kit text: byte_less needs two strings', 2)
  end
  local n = math.min(#a, #b)
  local i = 1
  while i <= n do
    -- compare in blocks of eight bytes while they are equal, then byte by byte
    local ca, cb = a:sub(i, i + 7), b:sub(i, i + 7)
    if ca == cb then
      i = i + 8
    else
      local m = math.min(#ca, #cb)
      for k = 1, m do
        local x, y = ca:byte(k), cb:byte(k)
        if x ~= y then
          return x < y
        end
      end
      break
    end
  end
  return #a < #b
end

return M
