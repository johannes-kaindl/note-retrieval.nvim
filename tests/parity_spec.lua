-- The writer-parity tool (tests/parity.lua, `make parity`) against a small vault and a fake embedder:
-- the verdicts, and the checks that make a verdict impossible when the measurement is not valid.
local T = require('note_retrieval.kit.test')
local vrix = require('note_retrieval.kit.vrix')
local vectors = require('note_retrieval.kit.vectors')
local chunker = require('note_retrieval.kit.chunker')

local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')

local function load_parity()
  vim.g.note_retrieval_parity_lib = true
  local ok, parity = pcall(dofile, here .. '/parity.lua')
  vim.g.note_retrieval_parity_lib = nil
  assert(ok, parity)
  return parity
end

local MODEL = 'fake-embedding'
local SOURCE_DIM, INDEX_DIM = 8, 4

-- A deterministic embedding of a text: 8 numbers from its hash. `salt` gives another "model".
local function fake(salt)
  return function(texts, cb)
    local vecs = {}
    for i, text in ipairs(texts) do
      local h = vim.fn.sha256(salt .. text)
      local v = {}
      for k = 1, SOURCE_DIM do
        v[k] = tonumber(h:sub(k * 4 - 3, k * 4), 16) / 32768 - 1
      end
      vecs[i] = v
    end
    cb(vecs)
  end
end

local function constant(texts, cb)
  local vecs = {}
  for i = 1, #texts do
    vecs[i] = { 1, 0.5, 0.25, 0.1, 0, 0, 0, 0 }
  end
  cb(vecs)
end

local function put(path, bytes)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'wb'))
  f:write(bytes)
  f:close()
end

-- A vault of six notes with a reference index written by the same chain, using `embed`.
-- `tamper(root, paths)` may change the notes after the index was written.
local function with_vault(embed, fn, tamper)
  local base = vim.uv.fs_realpath(vim.fn.tempname() .. '') or vim.fn.tempname()
  vim.fn.mkdir(base, 'p')
  base = vim.uv.fs_realpath(base)
  local paths, cells, stamps = {}, {}, {}
  for i = 1, 6 do
    local p = ('Notes/note-%d.md'):format(i)
    local text = ('# Note %d\n\nThis is note number %d, about topic %s.\n'):format(i, i, ('x'):rep(i * 3))
    put(base .. '/' .. p, text)
    local st = vim.uv.fs_stat(base .. '/' .. p)
    paths[i] = p
    stamps[i] = { st.mtime.sec * 1000 + math.floor(st.mtime.nsec / 1e6), st.size }
    local texts = {}
    for k, c in ipairs(chunker.chunk_markdown(text)) do
      texts[k] = c.text
    end
    local vecs
    embed(texts, function(v)
      vecs = v
    end)
    for _, v in ipairs(vectors.quantize_int8(vectors.to_index_vector(vecs, INDEX_DIM), 127)) do
      cells[#cells + 1] = string.char((v + 256) % 256)
    end
  end
  put(
    base .. '/_vaultrag/index.bin',
    vrix.encode({
      vault = '',
      embedding_model = MODEL,
      source_dim = SOURCE_DIM,
      index_dim = INDEX_DIM,
      granularity = 'note',
      aggregation = 'mean',
      quant = 'int8',
      scale = 127,
      count = #paths,
      source_commit = '',
      built_at = '2026-11-01T00:00:00.000Z',
    }, paths, table.concat(cells), stamps)
  )
  if tamper then
    tamper(base, paths)
  end
  local ok, err = pcall(fn, base)
  vim.fn.delete(base, 'rf')
  assert(ok, err)
end

local function measure(parity, vault, embed)
  local lines = {}
  parity.sink = function(line)
    lines[#lines + 1] = line
  end
  local code = parity.run({ vault = vault, n = 6, seed = 1, model = MODEL, embed = embed })
  parity.sink = nil
  return code, table.concat(lines, '\n')
end

T.case('parity: the same chain on the same notes is parity (exit 0), every row equal', function()
  local parity = load_parity()
  with_vault(fake('a'), function(vault)
    local code, log = measure(parity, vault, fake('a'))
    T.eq(code, 0, log)
    T.ok(log:find('int8 rows equal 6 of 6', 1, true), log)
  end)
end)

T.case('parity: counter-check, another embedding gives a deviation (exit 1), not parity', function()
  local parity = load_parity()
  with_vault(fake('a'), function(vault)
    local code, log = measure(parity, vault, fake('b'))
    T.eq(code, 1, log)
    T.ok(log:find('DEVIATION', 1, true), log)
  end)
end)

T.case(
  'parity: counter-check, a constant embedder cannot pass: wrong pairs match too, so no verdict (exit 2)',
  function()
    local parity = load_parity()
    with_vault(constant, function(vault)
      local code, log = measure(parity, vault, constant)
      T.eq(code, 2, log)
      T.ok(log:find('did not separate', 1, true), log)
    end)
  end
)

T.case(
  'parity: a note changed since the index was built leaves the pool (exit 2 when too few remain)',
  function()
    local parity = load_parity()
    with_vault(fake('a'), function(vault)
      local code, log = measure(parity, vault, fake('a'))
      T.eq(code, 2, log)
      T.ok(log:find('0 of 6 notes unchanged', 1, true), log)
    end, function(base, paths)
      for _, p in ipairs(paths) do
        put(base .. '/' .. p, 'changed after the index was built, and longer than before\n')
      end
    end)
  end
)

T.case('parity: embeddings that fail leave too few notes, so no verdict (exit 2)', function()
  local parity = load_parity()
  with_vault(fake('a'), function(vault)
    local function failing(_, cb)
      cb(nil, 'server down')
    end
    local code, log = measure(parity, vault, failing)
    T.eq(code, 2, log)
    T.ok(log:find('embedding failed', 1, true), log)
  end)
end)

T.case('parity: a server with another vector length is refused (exit 2)', function()
  local parity = load_parity()
  with_vault(fake('a'), function(vault)
    local function short(texts, cb)
      local vecs = {}
      for i = 1, #texts do
        vecs[i] = { 1, 0, 0, 0 }
      end
      cb(vecs)
    end
    local code, log = measure(parity, vault, short)
    T.eq(code, 2, log)
    T.ok(log:find('returns 4 values', 1, true), log)
  end)
end)

T.case('parity: a model other than the reference header is refused (exit 2)', function()
  local parity = load_parity()
  with_vault(fake('a'), function(vault)
    local lines = {}
    parity.sink = function(line)
      lines[#lines + 1] = line
    end
    local code = parity.run({ vault = vault, n = 6, seed = 1, model = 'another', embed = fake('a') })
    parity.sink = nil
    T.eq(code, 2)
    T.ok(table.concat(lines, '\n'):find('built with fake-embedding', 1, true))
  end)
end)

T.case('parity: cosine and compare', function()
  local parity = load_parity()
  T.eq(parity.cosine({ 1, 0 }, { 1, 0 }), 1)
  T.eq(parity.cosine({ 1, 0 }, { 0, 1 }), 0)
  T.eq(parity.cosine({ 0, 0 }, { 1, 0 }), nil)
  local c = parity.compare({ 1, -2, 3 }, { 1, -2, 4 })
  T.eq(c.equal, false)
  T.eq(c.max_diff, 1)
  T.ok(c.sha_mine ~= c.sha_ref)
  T.eq(parity.compare({ 5, -5 }, { 5, -5 }).equal, true)
end)

T.case('parity: a sample smaller than asked (the pool is short) gives no verdict (exit 2)', function()
  local parity = load_parity()
  with_vault(fake('a'), function(vault)
    local lines = {}
    parity.sink = function(line)
      lines[#lines + 1] = line
    end
    local code = parity.run({ vault = vault, n = 20, seed = 1, model = MODEL, embed = fake('a') })
    parity.sink = nil
    local log = table.concat(lines, '\n')
    T.eq(code, 2, log)
    T.ok(log:find('only 6 of 20', 1, true), log)
  end)
end)

T.case('parity: a note whose mtime is cut to whole seconds still counts as unchanged', function()
  local parity = load_parity()
  local pool = parity.pool('/nonexistent', {}, {}, parity.STAMP_TOLERANCE_MS)
  T.eq(#pool, 0)
  with_vault(fake('a'), function(vault)
    local code, log = measure(parity, vault, fake('a'))
    T.eq(code, 0, log)
  end, function(base, paths)
    for _, p in ipairs(paths) do
      local st = vim.uv.fs_stat(base .. '/' .. p)
      vim.uv.fs_utime(base .. '/' .. p, st.atime.sec, st.mtime.sec)
    end
  end)
end)
