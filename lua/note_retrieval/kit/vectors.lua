-- vendored from nvim-kit@0.17.1 (lua/nvim_kit/vectors.lua) — do not edit; re-vendor
-- Index vectors: unit vectors for notes and queries, their int8 form on disk, and the cosine rank over
-- a matrix of them. A port of code-kit's embed-vector.ts, vector-index.ts and retriever (tag 0.31.1),
-- proven by its conformance vectors. Every float32 in the source (Float32Array) is rounded here with
-- `fround`, and the arithmetic keeps the source's order step by step, so results agree to the last
-- bit. The matrix is a LuaJIT `float[]` where `ffi` exists, a Lua list of already-rounded values
-- where it does not; both give the same numbers.
local M = {}

local has_ffi, ffi = pcall(require, 'ffi')
local use_ffi = has_ffi
local float1 = has_ffi and ffi.new('float[1]') or nil

local floor, sqrt = math.floor, math.sqrt

--- For tests only: switches the `ffi` backend off and on (on only where `ffi` exists). New indexes and
--- every `fround` follow it; an index keeps the backend it was built with.
function M._use_ffi(on)
  use_ffi = on and has_ffi or false
end

local TWO_POW_128 = 2 ^ 128

-- Round half to even on an integer-valued scale: y is a double, the result its nearest integer.
local function round_even(y)
  local f = floor(y)
  local d = y - f
  if d > 0.5 or (d == 0.5 and f % 2 == 1) then
    return f + 1
  end
  return f
end

local function fround_lua(x)
  if x ~= x or x == 0 or x == math.huge or x == -math.huge then
    return x
  end
  local _, e = math.frexp(x) -- x = m * 2^e, 0.5 <= |m| < 1: a float32 has 24 bits below 2^e
  if e < -125 then
    e = -125 -- subnormals: the step stops at 2^-149
  end
  local step = math.ldexp(1, e - 24)
  local r = round_even(x / step) * step
  if r >= TWO_POW_128 or r <= -TWO_POW_128 then
    return r > 0 and math.huge or -math.huge
  end
  return r
end

--- x rounded to the nearest float32 (ties to even), as a double: JavaScript's `Math.fround`.
function M.fround(x)
  if use_ffi then
    float1[0] = x
    return float1[0]
  end
  return fround_lua(x)
end

local fround = M.fround

--- The unit vector of a note or query from the embeddings of its chunks `vecs` (lists of numbers):
--- truncated to `dim` (Matryoshka), averaged, L2-normalised, every step in float32. A source with
--- fewer values than `dim` gives a vector of its own length; no vectors give `{}`. One function for
--- the note path and the query path, so both land in the same space.
function M.to_index_vector(vecs, dim)
  local n = #vecs
  local d = math.min(dim, n > 0 and #vecs[1] or 0)
  local mean = {}
  for i = 1, d do
    mean[i] = 0
  end
  for r = 1, n do
    local v = vecs[r]
    for i = 1, d do
      -- Float32Array accumulates in a double and rounds on every store.
      mean[i] = fround(mean[i] + fround(v[i] or 0) / n)
    end
  end
  local norm = 0
  for i = 1, d do
    norm = norm + mean[i] * mean[i]
  end
  norm = sqrt(norm)
  if norm == 0 or norm ~= norm then
    norm = 1
  end
  for i = 1, d do
    mean[i] = fround(mean[i] / norm)
  end
  return mean
end

--- int8 quantisation of a unit vector: each value times `scale`, rounded like `Math.round` (halves
--- toward +infinity), clamped to +-scale. The one place of the rule that a writer applies and
--- `parse` reads back. `scale` defaults to 127 and must be an integer from 1 to 127 (an int8 holds
--- no more).
function M.quantize_int8(vec, scale)
  scale = scale or 127
  if type(scale) ~= 'number' or scale < 1 or scale > 127 or scale ~= floor(scale) then
    error('nvim-kit vectors: quantize_int8 needs an integer scale from 1 to 127', 2)
  end
  local out = {}
  for i = 1, #vec do
    local y = (vec[i] or 0) * scale
    local r = 0
    if y == y then
      local f = floor(y)
      r = (y - f >= 0.5) and f + 1 or f
    end
    out[i] = math.max(-scale, math.min(scale, r))
  end
  return out
end

--- The row for a path: the last one wins when a path repeats (a `Map` in the source).
local function row_map(paths)
  local rows = {}
  for i, p in ipairs(paths) do
    rows[p] = i
  end
  return rows
end

--- Reads the int8 matrix `matrix` (a byte string, two's complement, row by row) into an index
--- `{ paths, dim, count, data, rows }`: every value divided by `manifest.scale`, every row
--- renormalised (quantisation drift; an all-zero row stays zero). `data` is a `float[count * dim]`
--- (0-based) with `ffi`, a list (1-based) without; `index.ffi` says which. A manifest whose `count`
--- differs from the paths, or a matrix that is not `count * index_dim` bytes, is `nil, 'corrupt'`.
function M.parse(manifest, paths, matrix)
  if type(manifest) ~= 'table' or type(paths) ~= 'table' or type(matrix) ~= 'string' then
    error('nvim-kit vectors: parse needs a manifest table, a list of paths and a byte string', 2)
  end
  local dim, scale, n = manifest.index_dim, manifest.scale, #paths
  if manifest.count ~= n or #matrix ~= n * dim then
    return nil, 'corrupt'
  end
  local native = use_ffi
  local data, norms_from
  local byte = string.byte
  if native then
    data = ffi.new('float[?]', math.max(n * dim, 1))
    local i8 = ffi.cast('const int8_t*', matrix)
    norms_from = function(r)
      local norm = 0
      for c = 0, dim - 1 do
        local v = i8[r * dim + c] / scale
        data[r * dim + c] = v
        norm = norm + v * v
      end
      return norm
    end
  else
    data = {}
    norms_from = function(r)
      local norm = 0
      for c = 1, dim do
        local b = byte(matrix, r * dim + c)
        local v = (b >= 128 and b - 256 or b) / scale
        data[r * dim + c] = v
        norm = norm + v * v
      end
      return norm
    end
  end
  for r = 0, n - 1 do
    local norm = sqrt(norms_from(r))
    if norm == 0 or norm ~= norm then
      norm = 1
    end
    if native then
      for c = 0, dim - 1 do
        data[r * dim + c] = data[r * dim + c] / norm
      end
    else
      for c = 1, dim do
        data[r * dim + c] = fround(fround(data[r * dim + c]) / norm)
      end
    end
  end
  return { paths = paths, dim = dim, count = n, data = data, ffi = native, rows = row_map(paths) }
end

--- The values of the index matrix as a flat list (row by row), for tests and checks.
function M.values(index)
  local out = {}
  local data, total = index.data, index.count * index.dim
  local base = index.ffi and 0 or 1
  for i = 0, total - 1 do
    out[i + 1] = data[base + i]
  end
  return out
end

local function check_opts(opts)
  if type(opts) ~= 'table' or type(opts.k) ~= 'number' or type(opts.min_sim) ~= 'number' then
    error('nvim-kit vectors: opts needs k and min_sim (numbers) and optionally exclude (path prefixes)', 3)
  end
end

local function excluded(path, exclude)
  for _, prefix in ipairs(exclude) do
    if vim.startswith(path, prefix) then
      return true
    end
  end
  return false
end

-- Cosine rank of q (dim float32 values as a list) over all rows, skipping `skip` and the excluded
-- prefixes: score >= min_sim, best first, equal scores in row order, at most k.
local function rank(index, q, opts, skip)
  local dim = index.dim
  if #q < dim then
    return {}
  end
  local data, paths = index.data, index.paths
  local base = index.ffi and 0 or 1
  local exclude = opts.exclude or {}
  local min_sim = opts.min_sim
  local hits, count = {}, 0
  for r = 1, index.count do
    local p = paths[r]
    if p ~= skip and not excluded(p, exclude) then
      local at = base + (r - 1) * dim - 1
      local dot = 0
      for c = 1, dim do
        dot = dot + q[c] * data[at + c] -- a float64 sum over float32 values, as in the source
      end
      if dot >= min_sim then
        count = count + 1
        hits[count] = { path = p, score = dot, row = r }
      end
    end
  end
  -- table.sort is not stable: the row number makes the order total (the source's sort is stable).
  table.sort(hits, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.row < b.row
  end)
  local out = {}
  for i = 1, math.min(opts.k, count) do
    out[i] = { path = hits[i].path, score = hits[i].score }
  end
  return out
end

--- The notes closest to `query` (a list of numbers, at least `dim` long): `{ { path, score } }`,
--- best first. `opts = { k, min_sim, exclude }`; `exclude` lists path PREFIXES (give folders with a
--- slash: "Templates/"). A query shorter than the index has no cosine with it: `{}`.
function M.search(index, query, opts)
  check_opts(opts)
  local q = {}
  for i = 1, #query do
    q[i] = fround(query[i])
  end
  return rank(index, q, opts, nil)
end

--- The notes closest to the note at `path`, which itself is left out: as `search`, with the note's
--- own row as the query. `{}` for a path that is not in the index.
function M.related(index, path, opts)
  check_opts(opts)
  local r = index.rows[path]
  if not r then
    return {}
  end
  local dim, data = index.dim, index.data
  local base = index.ffi and 0 or 1
  local q = {}
  for c = 1, dim do
    q[c] = data[base + (r - 1) * dim + c - 1]
  end
  return rank(index, q, opts, path)
end

return M
