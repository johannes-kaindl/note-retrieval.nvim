-- vendored from nvim-kit@0.16.1 (lua/nvim_kit/chunker.lua) — do not edit; re-vendor
-- Splitting Markdown into overlapping chunks for embedding: a Lua port of code-kit `chunker.ts`
-- (0.31.1), which in turn is vault-rag's indexer (800 characters per unit, 150 overlap).
-- Lengths and offsets count UTF-16 code units like JavaScript's `string.length`, so the chunks of
-- this port equal the TypeScript ones for any text; the conformance vectors of code-kit prove it.
local M = {}
-- Relative require: a vendored copy loads its sibling under the plugin's namespace.
local text_lib = require(((...):gsub('chunker$', 'text')))

local char_at = text_lib.char_at
local is_js_space = text_lib.is_js_space
local js_trim = text_lib.js_trim

local NL = 10
local CR = 13
local LS = 0x2028
local PS = 0x2029
local HASH = 35

-- The byte length of the JavaScript whitespace character (`\s`) at byte i of s, or nil.
local function space_len(s, i)
  local b = s:byte(i)
  if not b then
    return nil
  end
  if b < 0x80 then
    return ((b >= 0x09 and b <= 0x0D) or b == 0x20) and 1 or nil
  end
  local cp, len = char_at(s, i)
  return is_js_space(cp) and len or nil
end

-- Where the text after a closing `---` begins: from byte `from` (after the three dashes) a run
-- of whitespace that holds at least one line feed; the match takes everything up to the LAST
-- line feed of the run (`\s*\n`, greedy). nil if the run has none.
local function close_end(s, from)
  local last
  local i = from
  while i <= #s do
    local len = space_len(s, i)
    if not len then
      break
    end
    if s:byte(i) == NL then
      last = i
    end
    i = i + len
  end
  return last and last + 1
end

--- `text` without a leading YAML frontmatter block: exactly what
--- `text.replace(/^---\s*\n[\s\S]*?\n---\s*\n/, "")` returns in JavaScript (`\s` is JavaScript's
--- whitespace, see `text.is_js_space`), in linear time. Port of code-kit `stripFrontmatter`;
--- how the regex decides, which this follows: the opening `---` is followed by whitespace that
--- holds a line break; the greedy `\s*` first tries the LAST line break of that run as the end of
--- the opening line, so the body starts after it and the closing `\n---` must lie after it. Only
--- when no closing line is found that way does it fall back to an earlier line break, and the one
--- closing line that can then still match is the last line break of the run itself
--- (`"---\n\n---\nBody"`). `"---\n---\nBody"` is therefore not frontmatter.
function M.strip_frontmatter(s)
  if type(s) ~= 'string' then
    error('nvim-kit chunker: strip_frontmatter needs s (a string)', 2)
  end
  if s:sub(1, 3) ~= '---' then
    return s
  end
  local last_nl, nl_count = nil, 0
  local i = 4
  while i <= #s do
    local len = space_len(s, i)
    if not len then
      break
    end
    if s:byte(i) == NL then
      last_nl = i
      nl_count = nl_count + 1
    end
    i = i + len
  end
  if nl_count == 0 then
    return s
  end
  -- The closing line: the earliest `\n---` after the opening line whose dashes are followed by
  -- whitespace with a line feed.
  local from = last_nl + 1
  while true do
    local c = s:find('\n---', from, true)
    if not c then
      break
    end
    local e = close_end(s, c + 4)
    if e then
      return s:sub(e)
    end
    from = c + 1
  end
  -- Fallback of the backtracking: the closing line is the last line break of the opening run
  -- (it needs an earlier line break to open).
  if nl_count >= 2 and s:sub(last_nl + 1, last_nl + 3) == '---' then
    local e = close_end(s, last_nl + 4)
    if e then
      return s:sub(e)
    end
  end
  return s
end

local function check_whole(v, name, min)
  if type(v) ~= 'number' or v % 1 ~= 0 or v < min then
    error(('nvim-kit chunker: chunk_markdown: %s must be a whole number of at least %d'):format(name, min), 3)
  end
end

--- Splits Markdown into overlapping chunks for embedding: frontmatter off, a cut preferably at a
--- heading, after a hard cut an overlap for continuity. Returns a list of
--- `{ text, start_offset, end_offset }`. `max_units` (default 800) is the window in UTF-16 code
--- units, `overlap` (default 150) the units a hard cut repeats; `overlap` must be smaller than
--- `max_units`. Offsets are 0-based UTF-16 units in the text AFTER `strip_frontmatter` and
--- `text.js_trim` and belong to the untrimmed window; `text` is the window trimmed again, and a
--- window that trims to nothing gives no chunk. A heading is `#` one to six times, then
--- whitespace, at the start of a line (after `\n`, `\r`, U+2028 or U+2029, or at the start). The
--- next chunk after a heading cut starts at the heading, with no overlap; after a hard cut it
--- starts `overlap` units back, but at least `max(max_units - overlap, floor(max_units / 2))`
--- after the previous start. A cut inside a surrogate pair (JavaScript can split one) cannot cut
--- a UTF-8 character: the whole character stays in the leading chunk and the next one starts
--- after it, while the offsets stay the unit numbers the algorithm computed. Invalid UTF-8 is
--- replaced by U+FFFD first (`text.clean_utf8`); the offsets refer to the cleaned text.
function M.chunk_markdown(s, max_units, overlap)
  if type(s) ~= 'string' then
    error('nvim-kit chunker: chunk_markdown needs s (a string)', 2)
  end
  if max_units == nil then
    max_units = 800
  end
  if overlap == nil then
    overlap = 150
  end
  check_whole(max_units, 'max_units', 1)
  check_whole(overlap, 'overlap', 0)
  if overlap >= max_units then
    error('nvim-kit chunker: chunk_markdown: overlap must be smaller than max_units', 2)
  end
  local trimmed = js_trim(M.strip_frontmatter(text_lib.clean_utf8(s)))
  if trimmed == '' then
    return {}
  end

  -- One pass over the text: the byte where each UTF-16 unit boundary lies (a boundary inside a
  -- surrogate pair lies after the character) and the units where a heading starts.
  local ubyte, headings = {}, {}
  local n = #trimmed
  local unit, i = 0, 1
  local line_start = true
  while i <= n do
    local cp, len = char_at(trimmed, i)
    if line_start and cp == HASH then
      local j = i
      while trimmed:byte(j) == HASH do
        j = j + 1
      end
      if j - i <= 6 and space_len(trimmed, j) then
        headings[#headings + 1] = unit
      end
    end
    ubyte[unit] = i
    if cp >= 0x10000 then
      ubyte[unit + 1] = i + len
      unit = unit + 2
    else
      unit = unit + 1
    end
    line_start = cp == NL or cp == CR or cp == LS or cp == PS
    i = i + len
  end
  local total = unit
  ubyte[total] = n + 1
  if total <= max_units then
    return { { text = trimmed, start_offset = 0, end_offset = total } }
  end

  -- Candidate cuts, ascending and without duplicates: 0, every heading, the end.
  local positions = { 0 }
  for _, h in ipairs(headings) do
    if h > positions[#positions] then
      positions[#positions + 1] = h
    end
  end
  positions[#positions + 1] = total

  local min_chunk = math.max(max_units - overlap, math.floor(max_units / 2))
  local chunks = {}
  local cur_start = 0
  -- Index of the first position after cur_start. cur_start only grows, so the index only moves
  -- forward and the search costs the positions inside the window, not all of them.
  local lo = 1
  while cur_start < total do
    local target_end = cur_start + max_units
    while lo <= #positions and positions[lo] <= cur_start do
      lo = lo + 1
    end
    -- The positions are sorted, so the last one in the window is the largest.
    local last_in_range
    for k = lo, #positions do
      local p = positions[k]
      if p > target_end then
        break
      end
      last_in_range = p
    end
    local cur_end, at_heading
    if last_in_range then
      cur_end = last_in_range
      at_heading = true
    else
      cur_end = math.min(target_end, total)
      at_heading = false
    end
    if cur_end <= cur_start then
      cur_end = math.min(cur_start + max_units, total)
    end

    local chunk_text = js_trim(trimmed:sub(ubyte[cur_start], ubyte[cur_end] - 1))
    if chunk_text ~= '' then
      chunks[#chunks + 1] = { text = chunk_text, start_offset = cur_start, end_offset = cur_end }
    end
    if cur_end >= total then
      break
    end
    -- At a heading: the next chunk starts at the heading (clean break, no overlap). After a hard
    -- cut: the overlap for continuity.
    cur_start = at_heading and cur_end or math.max(cur_end - overlap, cur_start + min_chunk)
  end
  return chunks
end

return M
