-- Writer parity: the plugin's own writer against the index vault-rag wrote for the same notes.
-- A sample of notes is embedded the way the own index does it (chunks -> embedding server -> truncated,
-- averaged, normalised -> int8) and compared row by row with the row in a reference `index.bin`.
-- Reads only: the reference index and the notes are opened for reading, nothing is written to the vault.
-- Not part of `make check` (CORE-TEST-02: only a real server tests); `make parity`:
--   PARITY_VAULT=/path/to/copy PARITY_URL=http://localhost:11434 make parity
--   optional: PARITY_MODEL (default: the model of the reference header), PARITY_N (default 200),
--             PARITY_SEED (default the probe's), PARITY_OUT (file for the per-note JSON), PARITY_INDEX
--             (default <vault>/_vaultrag/index.bin).
-- Exit 0: parity (the criteria below hold). Exit 1: a valid measurement that misses a criterion.
-- Exit 2: nothing valid was measured (a variable unset, server or index unusable, too few notes
-- embedded, the counter-check did not separate) — never a pass.
--
-- Which notes: only those whose file stamp (mtime and size) equals the stamp of their row in the
-- reference. A note changed since the index was built would differ for a reason that is not the writer.
-- So the claim holds for unchanged notes, the model and the server of the run — not for the whole vault.
-- A spec can load this file as a library (vim.g.note_retrieval_parity_lib set first): it then returns
-- the module and runs nothing.
local M = {}

--- The criteria, fixed before the first measurement (2026-11-10).
M.MIN_COSINE = 0.995 -- the worst row
M.MEDIAN_COSINE = 0.999 -- the middle row
M.MIN_EMBEDDED_SHARE = 0.95 -- of the sample, or the run is not valid
M.COUNTER_MAX_MEAN = 0.9 -- rows paired with the wrong reference must stay below this on average
M.DEFAULT_N = 200
-- A copy of a vault may keep mtimes in whole seconds only (measured 2026-11-10 on a copy of a personal vault:
-- 2 506 of 2 523 notes of equal size differ from their stamp by 0 to 999 ms, none of the others by less
-- than a second but more than two); a larger difference is a different file.
M.STAMP_TOLERANCE_MS = 999

--- Where the lines go; a spec swaps it to capture them.
M.sink = function(line)
  io.write(line, '\n')
end

local function out(line)
  M.sink(line)
end

--- Cosine of two int8 rows given as lists of numbers; nil when a row is all zero or the lengths differ.
function M.cosine(a, b)
  if #a ~= #b or #a == 0 then
    return nil
  end
  local dot, na, nb = 0, 0, 0
  for i = 1, #a do
    dot = dot + a[i] * b[i]
    na = na + a[i] * a[i]
    nb = nb + b[i] * b[i]
  end
  if na == 0 or nb == 0 then
    return nil
  end
  return dot / math.sqrt(na * nb)
end

local function signed(byte)
  return byte >= 128 and byte - 256 or byte
end

--- Row `r` (1-based) of the int8 matrix `matrix` of `dim` columns, as a list of numbers.
function M.row(matrix, dim, r)
  local out_row = {}
  local base = (r - 1) * dim
  for c = 1, dim do
    out_row[c] = signed(matrix:byte(base + c))
  end
  return out_row
end

--- The bytes of an int8 row (what the container holds), for the hash.
function M.row_bytes(row)
  local chars = {}
  for i, v in ipairs(row) do
    chars[i] = string.char((v + 256) % 256)
  end
  return table.concat(chars)
end

--- The comparison of one note: our row against the reference row.
function M.compare(mine, ref)
  local max_diff, equal = 0, #mine == #ref
  for i = 1, math.min(#mine, #ref) do
    local d = math.abs(mine[i] - ref[i])
    if d > max_diff then
      max_diff = d
    end
    if d ~= 0 then
      equal = false
    end
  end
  return {
    cosine = M.cosine(mine, ref),
    equal = equal,
    max_diff = max_diff,
    sha_mine = vim.fn.sha256(M.row_bytes(mine)),
    sha_ref = vim.fn.sha256(M.row_bytes(ref)),
  }
end

local function median(sorted)
  local n = #sorted
  if n == 0 then
    return nil
  end
  if n % 2 == 1 then
    return sorted[(n + 1) / 2]
  end
  return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

--- The verdict over the results `{ cosine, equal, … }` of the embedded notes and the counter-check
--- cosines (our rows against the next note's reference row). `asked` is the sample size.
--- Returns `{ valid, parity, why, stats }`; `valid = false` means no verdict (exit 2).
function M.verdict(results, counter, asked)
  local cos, equal = {}, 0
  for _, r in ipairs(results) do
    if r.cosine then
      cos[#cos + 1] = r.cosine
    end
    if r.equal then
      equal = equal + 1
    end
  end
  table.sort(cos)
  local stats = {
    asked = asked,
    embedded = #results,
    min = cos[1],
    median = median(cos),
    max = cos[#cos],
    equal = equal,
  }
  local csum = 0
  for _, c in ipairs(counter) do
    csum = csum + c
  end
  stats.counter_mean = #counter > 0 and csum / #counter or nil
  if #results < M.MIN_EMBEDDED_SHARE * asked then
    return { valid = false, why = ('only %d of %d notes embedded'):format(#results, asked), stats = stats }
  end
  if #cos < #results then
    return { valid = false, why = 'a row without a cosine (all zero or other length)', stats = stats }
  end
  if not stats.counter_mean then
    return { valid = false, why = 'no counter-check (fewer than two notes)', stats = stats }
  end
  if stats.counter_mean >= M.COUNTER_MAX_MEAN then
    return {
      valid = false,
      why = ('counter-check did not separate: wrong pairs average %.4f (limit %.2f)'):format(
        stats.counter_mean,
        M.COUNTER_MAX_MEAN
      ),
      stats = stats,
    }
  end
  local parity = stats.min >= M.MIN_COSINE and stats.median >= M.MEDIAN_COSINE
  return { valid = true, parity = parity, stats = stats }
end

-- Waits for `start(done)` to call `done(...)`; returns what it got, or nothing after `ms`.
local function await(start, ms)
  local got
  start(function(...)
    got = vim.F.pack_len(...)
  end)
  vim.wait(ms, function()
    return got ~= nil
  end, 20)
  if got then
    return vim.F.unpack_len(got)
  end
end

local function read_all(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local bytes = f:read('*a')
  f:close()
  return bytes
end

--- The notes of the reference whose file is unchanged since the index was built: the list of
--- `{ path, row }` (row = 1-based row of the reference), in the order of the reference.
function M.pool(root, paths, stamps, tolerance)
  local list = {}
  for i, p in ipairs(paths) do
    local st = vim.uv.fs_stat(root .. '/' .. p)
    if st and st.type == 'file' and stamps and stamps[i] then
      local mtime = st.mtime.sec * 1000 + math.floor(st.mtime.nsec / 1e6)
      if st.size == stamps[i][2] and math.abs(mtime - stamps[i][1]) <= tolerance then
        list[#list + 1] = { path = p, row = i }
      end
    end
  end
  return list
end

--- One measurement. `opts`: { vault, index_file?, n, seed, embed(texts, cb), model, out_file? };
--- `embed` answers `cb(vectors)` or `cb(nil, err)`. Returns the exit code.
function M.run(opts)
  local kit = 'note_retrieval.kit.'
  local vrix = require(kit .. 'vrix')
  local vectors = require(kit .. 'vectors')
  local chunker = require(kit .. 'chunker')
  local probe = require(kit .. 'probe')

  local vault = vim.uv.fs_realpath(opts.vault)
  if not vault then
    out(('parity: nothing measured: %s is not a folder'):format(opts.vault))
    return 2
  end
  local index_file = opts.index_file or (vault .. '/_vaultrag/index.bin')
  local bytes = read_all(index_file)
  if not bytes then
    out(('parity: nothing measured: cannot read %s'):format(index_file))
    return 2
  end
  local ref, why = vrix.decode(bytes)
  if not ref then
    out(('parity: nothing measured: the reference index is unusable (%s)'):format(why))
    return 2
  end
  local m = ref.manifest
  local model = opts.model or m.embedding_model
  if model ~= m.embedding_model then
    out(
      ('parity: nothing measured: the run uses %s, the reference was built with %s'):format(
        model,
        m.embedding_model
      )
    )
    return 2
  end
  local pool = M.pool(vault, ref.paths, ref.stamps, M.STAMP_TOLERANCE_MS)
  out(
    ('parity: reference %s, %d rows, model %s, dim %d of %d, built %s'):format(
      index_file,
      #ref.paths,
      m.embedding_model,
      m.index_dim,
      m.source_dim,
      m.built_at
    )
  )
  out(('parity: %d of %d notes unchanged since the index was built (stamp equal)'):format(#pool, #ref.paths))

  -- Notes with at least one chunk, in the probe's stable order; the first n are the sample.
  local ordered = probe.order(pool, opts.seed)
  local sample, contents = {}, {}
  for _, f in ipairs(ordered) do
    if #sample >= opts.n then
      break
    end
    local text = read_all(vault .. '/' .. f.path)
    if text and #chunker.chunk_markdown(text) > 0 then
      sample[#sample + 1] = f
      contents[#sample] = text
    end
  end
  if #sample < 2 then
    out('parity: nothing measured: fewer than two usable notes in the pool')
    return 2
  end

  local results, mine_rows, ref_rows, failed = {}, {}, {}, 0
  local t0 = vim.uv.hrtime()
  local dim_seen
  for i, f in ipairs(sample) do
    local texts = {}
    for k, c in ipairs(chunker.chunk_markdown(contents[i])) do
      texts[k] = c.text
    end
    local vecs, err = await(function(done)
      opts.embed(texts, done)
    end, 300000)
    if type(vecs) ~= 'table' or #vecs ~= #texts then
      failed = failed + 1
      out(('parity: embedding failed for %s: %s'):format(f.path, tostring(err)))
    else
      dim_seen = dim_seen or #vecs[1]
      if #vecs[1] ~= m.source_dim then
        out(
          ('parity: nothing measured: the server returns %d values, the reference came from %d'):format(
            #vecs[1],
            m.source_dim
          )
        )
        return 2
      end
      local mine = vectors.quantize_int8(vectors.to_index_vector(vecs, m.index_dim), m.scale)
      local theirs = M.row(ref.matrix, m.index_dim, f.row)
      local c = M.compare(mine, theirs)
      c.path, c.chunks = f.path, #texts
      results[#results + 1] = c
      mine_rows[#mine_rows + 1] = mine
      ref_rows[#ref_rows + 1] = theirs
    end
    if i % 20 == 0 then
      out(('parity: %d of %d notes, %.0f s'):format(i, #sample, (vim.uv.hrtime() - t0) / 1e9))
    end
  end

  -- Counter-check: the same rows of ours against the next note's reference row.
  local counter = {}
  for i = 1, #mine_rows do
    local c = M.cosine(mine_rows[i], ref_rows[i % #ref_rows + 1])
    if c then
      counter[#counter + 1] = c
    end
  end

  local v = M.verdict(results, counter, opts.n)
  local s = v.stats
  out(
    ('parity: %d of %d embedded (%d failed) in %.0f s; cosine min %s, median %s, max %s; int8 rows equal %d of %d; wrong pairs average %s'):format(
      s.embedded,
      s.asked,
      failed,
      (vim.uv.hrtime() - t0) / 1e9,
      s.min and ('%.6f'):format(s.min) or 'n/a',
      s.median and ('%.6f'):format(s.median) or 'n/a',
      s.max and ('%.6f'):format(s.max) or 'n/a',
      s.equal,
      s.embedded,
      s.counter_mean and ('%.4f'):format(s.counter_mean) or 'n/a'
    )
  )
  table.sort(results, function(a, b)
    return (a.cosine or 0) < (b.cosine or 0)
  end)
  for k = 1, math.min(5, #results) do
    local r = results[k]
    out(
      ('parity: worst %d: %.6f  max |diff| %d  %d chunks  %s'):format(
        k,
        r.cosine or 0,
        r.max_diff,
        r.chunks,
        r.path
      )
    )
  end
  if opts.out_file then
    local f = io.open(opts.out_file, 'w')
    if f then
      f:write(vim.json.encode({ stats = s, model = model, seed = opts.seed, notes = results }), '\n')
      f:close()
      out('parity: per-note results in ' .. opts.out_file)
    end
  end
  if not v.valid then
    out('parity: not valid, no verdict: ' .. v.why)
    return 2
  end
  out(
    v.parity and ('parity: PARITY (min >= %.3f and median >= %.3f)'):format(M.MIN_COSINE, M.MEDIAN_COSINE)
      or ('parity: DEVIATION (needs min >= %.3f and median >= %.3f)'):format(M.MIN_COSINE, M.MEDIAN_COSINE)
  )
  return v.parity and 0 or 1
end

--- Returns the exit code.
function M.main()
  local vault, url = vim.env.PARITY_VAULT, vim.env.PARITY_URL
  if not vault or vault == '' or not url or url == '' then
    out(
      'parity: nothing measured: set PARITY_VAULT (a copy of the vault with its index) and PARITY_URL (embedding server) first'
    )
    return 2
  end
  local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
  vim.opt.rtp:prepend(root)
  package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
  local llm = require('note_retrieval.kit.llm')
  local probe = require('note_retrieval.kit.probe')
  -- The model comes from the header unless PARITY_MODEL says otherwise (run() then refuses a mismatch).
  local model = vim.env.PARITY_MODEL
  if not model or model == '' then
    local bytes = read_all((vim.env.PARITY_INDEX or (vault .. '/_vaultrag/index.bin')))
    local ref = bytes and require('note_retrieval.kit.vrix').decode(bytes)
    model = ref and ref.manifest.embedding_model or ''
  end
  return M.run({
    vault = vault,
    index_file = vim.env.PARITY_INDEX,
    n = tonumber(vim.env.PARITY_N) or M.DEFAULT_N,
    seed = tonumber(vim.env.PARITY_SEED) or probe.SEED,
    model = model,
    out_file = vim.env.PARITY_OUT,
    embed = function(texts, cb)
      llm.embed({ endpoint = { url = url }, model = model, input = texts, timeout_ms = 300000 }, function(res)
        if res.ok then
          cb(res.vectors)
        else
          cb(nil, res.error .. ': ' .. tostring(res.detail))
        end
      end)
    end,
  })
end

if vim.g.note_retrieval_parity_lib then
  return M
end
local code = M.main()
os.exit(code)
