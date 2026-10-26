local T = require('note_retrieval.kit.test')
local stub = require('note_retrieval.kit.http_stub')
local llm = require('note_retrieval.kit.llm')
local vrix = require('note_retrieval.kit.vrix')
local config = require('note_retrieval.config')
local embedder = require('note_retrieval.embedder')
local index = require('note_retrieval.index')
local search = require('note_retrieval.search')

local DIM = 4

local function matrix(rows)
  local out = {}
  for _, row in ipairs(rows) do
    for _, v in ipairs(row) do
      out[#out + 1] = string.char(v < 0 and v + 256 or v)
    end
  end
  return table.concat(out)
end

local function container(paths, rows)
  local manifest = {
    vault = '',
    embedding_model = 'test-model',
    source_dim = DIM,
    index_dim = DIM,
    granularity = 'note',
    aggregation = 'mean',
    quant = 'int8',
    scale = 127,
    count = #paths,
    source_commit = '',
    built_at = '2026-10-20T00:00:00.000Z',
  }
  return vrix.encode(manifest, paths, matrix(rows))
end

local function put(path, bytes)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'wb'))
  f:write(bytes)
  f:close()
end

-- Rows in index order. `a` is the note the related tests start from; `b` and `d` tie for the
-- closest live note; the three orphans are closer still but have no file; `Templates/t.md` is
-- excluded by the vault; `c` is orthogonal to `a`.
local ROWS = {
  { 'a.md', { 127, 0, 0, 0 } },
  { 'orphan1.md', { 126, 5, 0, 0 } },
  { 'orphan2.md', { 125, 8, 0, 0 } },
  { 'orphan3.md', { 124, 10, 0, 0 } },
  { 'b.md', { 100, 50, 0, 0 } },
  { 'Templates/t.md', { 120, 20, 0, 0 } },
  { 'd.md', { 100, 50, 0, 0 } },
  { 'sub/e.md', { 90, 90, 0, 0 } },
  { 'c.md', { 0, 0, 127, 0 } },
}
local ORPHANS = { ['orphan1.md'] = true, ['orphan2.md'] = true, ['orphan3.md'] = true }

local function bytes_of(rows)
  local paths, vecs = {}, {}
  for i, r in ipairs(rows) do
    paths[i], vecs[i] = r[1], r[2]
  end
  return container(paths, vecs)
end

-- An Obsidian vault with the Vault Retrieval plugin and an index of `rows`; every row except
-- the orphans has its file. `fn(root)`, then everything is removed and the options are reset.
local function with_vault(rows, fn, data_json)
  local base = vim.fn.tempname()
  local root = base .. '/vault'
  put(root .. '/.obsidian/plugins/vault-retrieval/data.json', data_json or '{}')
  for _, r in ipairs(rows) do
    if not ORPHANS[r[1]] then
      put(root .. '/' .. r[1], '# ' .. r[1])
    end
  end
  put(root .. '/_vaultrag/index.bin', bytes_of(rows))
  index.reset()
  llm.reset()
  local ok, err = pcall(fn, root)
  index.reset()
  config.set(nil)
  vim.fn.delete(base, 'rf')
  assert(ok, err)
end

local function paths(results)
  local out = {}
  for i, r in ipairs(results) do
    out[i] = r.path
  end
  return out
end

-- Replaces the embedder for one call: resolve answers a fixed `resolved`, query a fixed vector.
local function with_embedder(vector, fn)
  local resolve, query = embedder.resolve, embedder.query
  local seen = {}
  embedder.resolve = function(_, manifest, cb)
    seen.manifest = manifest
    seen.resolves = (seen.resolves or 0) + 1
    cb({ model = 'test-model', dim = DIM })
  end
  embedder.query = function(_, text, cb)
    seen.query = text
    cb(vector)
  end
  local ok, err = pcall(fn, seen)
  embedder.resolve, embedder.query = resolve, query
  assert(ok, err)
end

local function run_search(query, opts)
  local got
  search.search(query, opts, function(...)
    got = { ... }
  end)
  assert(got, 'search did not call back')
  return got[1], got[2]
end

T.case('related: best first, ties by row, the note itself and the vault excludes left out', function()
  with_vault(ROWS, function(root)
    local results = assert(search.related('a.md', { root = root, min_similarity = 0 }))
    -- b and d tie (row order), Templates/ is excluded by the vault, the orphans have no file
    T.eq(paths(results), { 'b.md', 'd.md', 'sub/e.md', 'c.md' })
    T.eq(results[1].title, 'b')
    T.eq(results[3].title, 'e')
    T.eq(results[1].score, results[2].score)
    T.ok(results[1].score > results[3].score and results[3].score > results[4].score, 'best first')
  end)
end)

T.case("related: the caller's exclude prefixes add to the vault's", function()
  with_vault(ROWS, function(root)
    local more = assert(search.related('a.md', { root = root, min_similarity = 0, exclude = { 'sub/' } }))
    T.eq(paths(more), { 'b.md', 'd.md', 'c.md' })
  end)
end)

T.case('related: an empty exclude list in data.json lets the Templates note in', function()
  with_vault(ROWS, function(root)
    local results = assert(search.related('a.md', { root = root, min_similarity = 0 }))
    T.eq(vim.tbl_contains(paths(results), 'Templates/t.md'), true)
  end, '{"exclude":[]}')
end)

T.case('related: k and min_similarity cut the list; the defaults come from the options', function()
  with_vault(ROWS, function(root)
    T.eq(paths(assert(search.related('a.md', { root = root, k = 1, min_similarity = 0 }))), { 'b.md' })
    T.eq(
      paths(assert(search.related('a.md', { root = root, k = 3, min_similarity = 0 }))),
      { 'b.md', 'd.md', 'sub/e.md' }
    )
    -- 0.89 keeps the tie (0.894), 0.9 drops it
    T.eq(paths(assert(search.related('a.md', { root = root, min_similarity = 0.89 }))), { 'b.md', 'd.md' })
    T.eq(search.related('a.md', { root = root, min_similarity = 0.9 }), {})
    -- no options: min_similarity 0.3 (default) drops c, k 20 keeps the rest
    T.eq(paths(assert(search.related('a.md', { root = root }))), { 'b.md', 'd.md', 'sub/e.md' })
    config.set({ k = 2, min_similarity = 0 })
    T.eq(paths(assert(search.related('a.md', { root = root }))), { 'b.md', 'd.md' })
  end)
end)

T.case('related: rows without a file are skipped and the list is still filled to k', function()
  with_vault(ROWS, function(root)
    -- three orphans rank before b.md; k = 1 still finds a live note
    T.eq(paths(assert(search.related('a.md', { root = root, k = 1, min_similarity = 0 }))), { 'b.md' })
    T.eq(#assert(search.related('a.md', { root = root, k = 20, min_similarity = 0 })), 4)
    -- a file that disappears after the load is dropped at the next call
    os.remove(root .. '/b.md')
    T.eq(
      paths(assert(search.related('a.md', { root = root, k = 2, min_similarity = 0 }))),
      { 'd.md', 'sub/e.md' }
    )
  end)
end)

T.case('related: a note without a row gives the message in words, not an empty list', function()
  with_vault(ROWS, function(root)
    local results, msg = search.related('new-note.md', { root = root })
    T.eq(results, nil)
    T.eq(msg, 'no row for this note in the index')
    T.eq(search.NO_ROW, 'no row for this note in the index')
  end)
end)

T.case('related: finds the vault from an absolute path and takes the row of the relative one', function()
  with_vault(ROWS, function(root)
    local results = assert(search.related(root .. '/a.md', { min_similarity = 0 }))
    T.eq(paths(results), { 'b.md', 'd.md', 'sub/e.md', 'c.md' })
  end)
end)

T.case('related: an empty index gives no row, search an empty list', function()
  with_vault({}, function(root)
    local results, msg = search.related('a.md', { root = root })
    T.eq(results, nil)
    T.eq(msg, search.NO_ROW)
    with_embedder({ 1, 0, 0, 0 }, function()
      local found, err = run_search('anything', { root = root })
      T.eq(found, {})
      T.eq(err, nil)
    end)
  end)
end)

T.case('search: embeds the query once, ranks all notes including the closest, without Templates/', function()
  with_vault(ROWS, function(root)
    with_embedder({ 1, 0, 0, 0 }, function(seen)
      local results = assert(run_search('a query', { root = root, min_similarity = 0 }))
      T.eq(seen.query, 'a query')
      T.eq(seen.resolves, 1)
      -- the note a.md itself is a result (no self exclusion); ties by row; orphans and Templates/ gone
      T.eq(paths(results), { 'a.md', 'b.md', 'd.md', 'sub/e.md', 'c.md' })
      T.eq(results[1].title, 'a')
      T.eq(paths(assert(run_search('q', { root = root, k = 2, min_similarity = 0 }))), { 'a.md', 'b.md' })
      T.eq(paths(assert(run_search('q', { root = root, min_similarity = 0.89 }))), { 'a.md', 'b.md', 'd.md' })
    end)
  end)
end)

T.case(
  'search: the vault excludes and the caller excludes apply; an empty vault list lets Templates in',
  function()
    with_vault(ROWS, function(root)
      with_embedder({ 120, 20, 0, 0 }, function()
        local with = assert(run_search('q', { root = root, k = 20, min_similarity = 0.9 }))
        T.eq(vim.tbl_contains(paths(with), 'Templates/t.md'), false)
        local more = assert(run_search('q', { root = root, min_similarity = 0.9, exclude = { 'a.md' } }))
        T.eq(vim.tbl_contains(paths(more), 'a.md'), false)
      end)
    end)
    with_vault(ROWS, function(root)
      with_embedder({ 120, 20, 0, 0 }, function()
        local results = assert(run_search('q', { root = root, min_similarity = 0.9 }))
        T.eq(results[1].path, 'Templates/t.md')
      end)
    end, '{"exclude":[]}')
  end
)

T.case('search: the header model binds only an index that is not ours (mode obsidian)', function()
  with_vault(ROWS, function(root)
    with_embedder({ 1, 0, 0, 0 }, function(seen)
      run_search('q', { root = root })
      T.eq(seen.manifest.embedding_model, 'test-model')
    end)
  end)
  -- the same index file in a vault without the Obsidian plugin is "eigen": no manifest is passed
  with_vault(ROWS, function(root)
    vim.fn.delete(root .. '/.obsidian/plugins', 'rf')
    config.set({ index_dir = '_vaultrag' })
    index.reset()
    with_embedder({ 1, 0, 0, 0 }, function(seen)
      local results = run_search('q', { root = root })
      T.ok(results, 'search ran')
      T.eq(seen.manifest, nil)
    end)
  end)
end)

T.case(
  'search: an index built with another model than the server serves turns search off, related stays',
  function()
    local srv = stub.start({
      ['GET /v1/models'] = { body = { data = { { id = 'other-model' } } } },
      ['POST /v1/embeddings'] = {
        body = { data = { { object = 'embedding', index = 0, embedding = { 1, 0, 0, 0 } } } },
      },
    })
    with_vault(ROWS, function(root)
      config.set({ endpoints = { { url = srv.url, backend = 'unknown' } }, timeout_ms = 5000 })
      local got
      search.search('q', { root = root }, function(...)
        got = { ... }
      end)
      vim.wait(5000, function()
        return got ~= nil
      end, 5)
      T.eq(got[1], nil)
      T.eq(
        got[2],
        { kind = 'model-mismatch', index_model = 'test-model', endpoint_models = { 'other-model' } }
      )
      -- related reads the row and asks nobody
      T.eq(
        paths(assert(search.related('a.md', { root = root, k = 2, min_similarity = 0 }))),
        { 'b.md', 'd.md' }
      )
      for _, r in ipairs(srv.requests) do
        T.ok(r.path ~= '/v1/embeddings', 'no embedding request was made')
      end
    end)
    srv.close()
  end
)

T.case('search: no vault index gives a no-index error', function()
  local base = vim.fn.tempname()
  put(base .. '/vault/.obsidian/x', '')
  index.reset()
  local results, err = run_search('q', { root = base .. '/vault' })
  T.eq(results, nil)
  T.eq(err.kind, 'no-index')
  T.ok(err.detail ~= nil and err.detail ~= '', 'the detail says why')
  vim.fn.delete(base, 'rf')
end)

-- Replaces vim.ui.select for one call: `pick(items)` returns the chosen item (nil: dismissed).
local function with_select(pick, fn)
  local original = vim.ui.select
  local shown = {}
  vim.ui.select = function(items, opts, on_choice)
    local lines = {}
    for i, item in ipairs(items) do
      lines[i] = opts.format_item(item)
    end
    shown[#shown + 1] = lines
    on_choice(pick(items))
  end
  local ok, err = pcall(fn, shown)
  vim.ui.select = original
  assert(ok, err)
end

T.case('pick: lines read "0.82  Title — Folder" and the choice opens the note', function()
  with_vault(ROWS, function(root)
    local results = {
      { path = 'sub/e.md', score = 0.82, title = 'e' },
      { path = 'b.md', score = 0.5, title = 'b' },
    }
    with_select(function(items)
      return items[1]
    end, function(shown)
      search.pick(results, { root = root })
      T.eq(shown[1], { '0.82  e — sub', '0.50  b' })
      T.eq(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)), vim.uv.fs_realpath(root .. '/sub/e.md'))
    end)
    -- dismissed: nothing opens
    local before = vim.api.nvim_buf_get_name(0)
    with_select(function()
      return nil
    end, function()
      search.pick(results, { root = root })
      T.eq(vim.api.nvim_buf_get_name(0), before)
    end)
    vim.cmd('silent! %bwipeout!')
  end)
end)

T.case('pick: an empty list says so and shows no picker', function()
  local original = vim.notify
  local said
  vim.notify = function(msg)
    said = msg
  end
  with_select(function()
    error('the picker must not open')
  end, function()
    search.pick({}, { root = '/nonexistent' })
  end)
  vim.notify = original
  T.eq(said, 'no matching notes')
end)
