-- vendored from nvim-kit@0.17.1 (lua/nvim_kit/probe.lua) — do not edit; re-vendor
-- The core of the self-find probe: pick a stable, scattered sample of notes, query the index with
-- each note's own text, and compare two runs over the same notes. A port of code-kit
-- `probe-core.ts` (tag 0.31.1, from vault-rag), proven by its conformance vectors. What does not
-- have to run inside the host lives here as plain code; reading the notes and asking the index
-- stay with the caller.
local M = {}
-- Relative require: a vendored copy loads its siblings under the plugin's namespace.
local base = (...):gsub('probe$', '')
local text_lib = require(base .. 'text')
local chunker = require(base .. 'chunker')

local bit = require('bit')

--- Default seed of the probe (the day of its first run).
M.SEED = 20260903
--- Default sample size.
M.N = 40

local TWO_32 = 2 ^ 32

-- FNV-1a over the UTF-16 code units of s, 32 bit. `h * 0x01000193` needs 56 bits and a double
-- keeps 53, so the multiplication is split: 0x01000193 = 2^24 + 403, and `lshift(h, 24)` is the
-- first term already reduced to 32 bits. Both terms and their sum stay exact (below 2^41).
local function fnv1a(s)
  local h = bit.tobit(0x811c9dc5)
  local xor, lshift, tobit = bit.bxor, bit.lshift, bit.tobit
  local function mix(unit)
    h = xor(h, unit)
    h = tobit(lshift(h, 24) + h * 403)
  end
  local i, n = 1, #s
  while i <= n do
    local cp, len = text_lib.char_at(s, i)
    if cp >= 0x80 and len == 1 then
      -- a byte that is no UTF-8: the U+FFFD `clean_utf8` would put there
      cp = 0xFFFD
    end
    if cp >= 0x10000 then
      cp = cp - 0x10000
      mix(0xD800 + math.floor(cp / 0x400))
      mix(0xDC00 + cp % 0x400)
    else
      mix(cp)
    end
    i = i + len
  end
  return h < 0 and h + TWO_32 or h
end

--- The deterministic rank of a path: FNV-1a (32 bit, an unsigned number) over `<seed>:<path>` on
--- UTF-16 code units, so a character beyond U+FFFF contributes its two surrogates. It depends
--- ONLY on path and seed, never on the other files: a sample drawn by rank keeps its members when
--- the vault grows, which a shuffle seeded by position did not (2026-09-05). `seed` is a whole
--- number; `path` is valid UTF-8.
function M.rank(path, seed)
  if type(path) ~= 'string' then
    error('nvim-kit probe: rank needs path (a string)', 2)
  end
  if type(seed) ~= 'number' or seed % 1 ~= 0 then
    error('nvim-kit probe: rank needs seed (a whole number)', 2)
  end
  return fnv1a(('%d'):format(seed) .. ':' .. path)
end

--- All files (tables with a `path`) in stable, scattered order: ascending `rank`, equal ranks by
--- `text.byte_less` of the path (never the locale: Lua's `<` may collate; the source sorts by
--- code unit order), equal paths in input order. A new list; the file tables are the caller's.
--- The caller takes as many as it needs, and a note added to the vault slots in between the old
--- ones instead of reshuffling them.
function M.order(files, seed)
  if type(files) ~= 'table' then
    error('nvim-kit probe: order needs files (a list of tables with a path)', 2)
  end
  local rows = {}
  for i, f in ipairs(files) do
    if type(f) ~= 'table' or type(f.path) ~= 'string' then
      error(('nvim-kit probe: order: files[%d] has no path (a string)'):format(i), 2)
    end
    rows[i] = { file = f, rank = M.rank(f.path, seed), path = f.path, index = i }
  end
  table.sort(rows, function(a, b)
    if a.rank ~= b.rank then
      return a.rank < b.rank
    end
    if a.path ~= b.path then
      return text_lib.byte_less(a.path, b.path)
    end
    return a.index < b.index
  end)
  local out = {}
  for i, r in ipairs(rows) do
    out[i] = r.file
  end
  return out
end

--- The query for one note, or nil when the note is no candidate: its body (frontmatter stripped,
--- trimmed the JavaScript way) must not be empty, and unless `opts.strict` its length must lie in
--- the window 200 < len <= 800 UTF-16 units. The query is the first 300 units of the body (a cut
--- inside a surrogate pair keeps the whole character, see `text.utf16_sub`).
function M.query(s, opts)
  if type(s) ~= 'string' then
    error('nvim-kit probe: query needs s (a string)', 2)
  end
  local strict = opts ~= nil and opts.strict or false
  local body = text_lib.js_trim(chunker.strip_frontmatter(s))
  if body == '' then
    return nil
  end
  if not strict then
    local len = text_lib.utf16_len(body)
    if len <= 200 or len > 800 then
      return nil
    end
  end
  return text_lib.utf16_sub(body, 0, 300)
end

--- The pair comparison of two runs over the SAME notes (lists of attempts `{ path, rank, ... }`).
--- Only this supports "the reindex helped": two runs with the same seed are otherwise two
--- independent samples. The RANK is compared, not the score; rank 0 is the expected value, fixed
--- beforehand. Returns `{ shared, healed, worsened, unchanged, missing }`: the counts of notes in
--- both runs and of those that did not change (a hit stays a hit, a miss stays a miss), the
--- attempts of `next` that went from a miss to a hit (`healed`) or back (`worsened`), and the
--- paths of `previous` that `next` lacks — `missing` is the honesty condition: a shrunken
--- comparison must not look like a clean one.
function M.compare_runs(previous, next)
  if type(previous) ~= 'table' or type(next) ~= 'table' then
    error('nvim-kit probe: compare_runs needs two lists of attempts', 2)
  end
  local by_path = {}
  for _, a in ipairs(next) do
    by_path[a.path] = a
  end
  local r = { shared = 0, healed = {}, worsened = {}, unchanged = 0, missing = {} }
  for _, a in ipairs(previous) do
    local n = by_path[a.path]
    if not n then
      r.missing[#r.missing + 1] = a.path
    else
      r.shared = r.shared + 1
      if a.rank ~= 0 and n.rank == 0 then
        r.healed[#r.healed + 1] = n
      elseif a.rank == 0 and n.rank ~= 0 then
        r.worsened[#r.worsened + 1] = n
      else
        r.unchanged = r.unchanged + 1
      end
    end
  end
  return r
end

return M
