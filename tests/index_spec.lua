local T = require('note_retrieval.kit.test')
local date = require('note_retrieval.kit.date')
local index = require('note_retrieval.index')
local vectors = require('note_retrieval.kit.vectors')
local vrix = require('note_retrieval.kit.vrix')

local uv = vim.uv or vim.loop

local BUILT = date.days_from_civil(2026, 10, 20) * 86400 -- built_at, in seconds
local BUILT_AT = '2026-10-20T00:00:00.000Z'
local DIM = 4

-- Rows of int8 values (a list of DIM numbers) as the matrix bytes.
local function matrix(rows)
  local out = {}
  for _, row in ipairs(rows) do
    for _, v in ipairs(row) do
      out[#out + 1] = string.char(v < 0 and v + 256 or v)
    end
  end
  return table.concat(out)
end

local function container(paths, rows, stamps)
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
    built_at = BUILT_AT,
  }
  return vrix.encode(manifest, paths, matrix(rows), stamps)
end

local function put(path, bytes, mtime)
  local f = assert(io.open(path, 'wb'))
  f:write(bytes)
  f:close()
  if mtime then
    assert(uv.fs_utime(path, mtime, mtime))
  end
end

local function sha(path)
  local f = assert(io.open(path, 'rb'))
  local s = f:read('*a')
  f:close()
  -- hex first: Neovim 0.10 reads a string with NUL bytes as a Blob and sha256() refuses it
  return vim.fn.sha256((s:gsub('.', function(c)
    return ('%02x'):format(c:byte())
  end)))
end

local seq = 0
-- Writes `bytes` as the index and gives it a modification time no earlier write had.
local function put_index(root, bytes)
  seq = seq + 1
  put(root .. '/_vaultrag/index.bin', bytes, 1700000000 + seq)
end

local ROWS = { { 127, 0, 0, 0 }, { 100, 50, 0, 0 }, { 0, 0, 127, 0 } }
local PATHS = { 'a.md', 'b.md', 'c.md' }

-- A vault the Obsidian plugin has indexed: `index_bytes` is the file, `notes` maps a note to its
-- modification time in seconds. Removed afterwards.
local function with_vault(index_bytes, notes, fn)
  local base = vim.fn.tempname()
  local root = base .. '/vault'
  vim.fn.mkdir(root .. '/.obsidian/plugins/vault-retrieval', 'p')
  vim.fn.mkdir(root .. '/_vaultrag', 'p')
  put(root .. '/.obsidian/plugins/vault-retrieval/data.json', '{}')
  for name, mtime in pairs(notes or {}) do
    put(root .. '/' .. name, 'hello', mtime)
  end
  index.reset()
  put_index(root, index_bytes)
  local ok, err = pcall(fn, root)
  index.reset()
  vim.fn.delete(base, 'rf')
  assert(ok, err)
end

local GOOD = container(PATHS, ROWS)

T.case('load: reads rows, paths, stamps and built_at of an index in mode obsidian', function()
  local stamps = { { 5, 5 }, { 0, 0 }, { 0, 0 } }
  with_vault(container(PATHS, ROWS, stamps), nil, function(root)
    local loaded = assert(index.load(root, {}))
    T.eq(loaded.paths, PATHS)
    T.eq(loaded.stamps, stamps)
    T.eq(loaded.index.count, 3)
    T.eq(loaded.index.dim, DIM)
    T.eq(loaded.manifest.embedding_model, 'test-model')
    T.eq(loaded.mode, 'obsidian')
    T.eq(loaded.built_ms, BUILT * 1000)
    T.eq(loaded.stat.size, #container(PATHS, ROWS, stamps))
    -- the rows are the vectors: a is closest to b, c is orthogonal to a
    local related = vectors.related(loaded.index, 'a.md', { k = 5, min_sim = 0.1 })
    T.eq(related[1].path, 'b.md')
    T.eq(#related, 1)
  end)
end)

T.case('load: an index without stamps has stamps = nil', function()
  with_vault(GOOD, nil, function(root)
    T.eq(assert(index.load(root, {})).stamps, nil)
  end)
end)

T.case('current: loads on first call, hands out the same table while the file is unchanged', function()
  with_vault(GOOD, nil, function(root)
    local first, warning = index.current(root, {})
    T.eq(warning, nil)
    T.eq(first.index.count, 3)
    T.ok(index.current(root, {}) == first, 'an unchanged file must not be loaded again')
  end)
end)

T.case('current: reloads when the file changed (mtime and size)', function()
  with_vault(GOOD, nil, function(root)
    T.eq(index.current(root, {}).index.count, 3)
    put_index(root, container({ 'a.md', 'b.md' }, { ROWS[1], ROWS[2] }))
    local now, warning = index.current(root, {})
    T.eq(warning, nil)
    T.eq(now.paths, { 'a.md', 'b.md' })
    -- same size, only the time moved
    local same = container({ 'a.md', 'b.md' }, { ROWS[2], ROWS[1] })
    put_index(root, same)
    T.eq(index.current(root, {}).index.count, 2)
    T.eq(vectors.values(index.current(root, {}).index)[1] > 0.7, true)
  end)
end)

T.case('current: a cut-short file keeps the old index, says so, and the next access tries again', function()
  with_vault(GOOD, nil, function(root)
    local old = index.current(root, {})
    put_index(root, GOOD:sub(1, #GOOD - 20))
    local kept, warning = index.current(root, {})
    T.ok(kept == old, 'the old index must stay')
    T.ok(warning:find('being written or is damaged', 1, true), warning)
    -- the file is still torn: still the old index, still the words
    local again, warning2 = index.current(root, {})
    T.ok(again == old)
    T.ok(warning2:find('being written or is damaged', 1, true), warning2)
    -- load itself reports it as a result, not an error
    local none, why = index.load(root, {})
    T.eq(none, nil)
    T.ok(why:find('being written or is damaged', 1, true), why)
  end)
end)

T.case('current: a broken checksum keeps the old index', function()
  with_vault(GOOD, nil, function(root)
    local old = index.current(root, {})
    local bad = GOOD:sub(1, 40) .. string.char((GOOD:byte(41) + 1) % 256) .. GOOD:sub(42)
    put_index(root, bad)
    local kept, warning = index.current(root, {})
    T.ok(kept == old)
    T.ok(warning:find('checksum', 1, true), warning)
  end)
end)

T.case('current: an error, then a good file: the new index is taken and the warning is gone', function()
  with_vault(GOOD, nil, function(root)
    local old = index.current(root, {})
    put_index(root, GOOD:sub(1, 30))
    T.ok(select(2, index.current(root, {})) ~= nil)
    put_index(root, container({ 'x.md' }, { ROWS[1] }))
    local now, warning = index.current(root, {})
    T.eq(warning, nil)
    T.ok(now ~= old)
    T.eq(now.paths, { 'x.md' })
  end)
end)

T.case('current: an empty index never replaces a filled one', function()
  with_vault(GOOD, nil, function(root)
    local old = index.current(root, {})
    put_index(root, container({}, {}))
    local kept, warning = index.current(root, {})
    T.ok(kept == old)
    T.ok(warning:find('empty', 1, true), warning)
    put_index(root, container({ 'z.md' }, { ROWS[3] }))
    T.eq(index.current(root, {}).paths, { 'z.md' })
  end)
end)

T.case('current: an empty index is taken when there is nothing older', function()
  with_vault(container({}, {}), nil, function(root)
    local loaded, warning = index.current(root, {})
    T.eq(warning, nil)
    T.eq(loaded.index.count, 0)
  end)
end)

T.case('current: a vanished file keeps the old index; no index at all is nil and a message', function()
  with_vault(GOOD, nil, function(root)
    local old = index.current(root, {})
    os.remove(root .. '/_vaultrag/index.bin')
    local kept, warning = index.current(root, {})
    T.ok(kept == old)
    T.ok(warning:find('missing', 1, true), warning)
  end)
  with_vault(GOOD, nil, function(root)
    put_index(root, 'not an index')
    local none, why = index.current(root, {})
    T.eq(none, nil)
    T.ok(why:find('being written or is damaged', 1, true), why)
  end)
end)

-- A container whose header has a valid checksum but lacks `key` (vectors.parse raises on it).
local function without(key)
  local manifest = {
    vault = '',
    embedding_model = 'test-model',
    source_dim = DIM,
    index_dim = DIM,
    granularity = 'note',
    aggregation = 'mean',
    quant = 'int8',
    scale = 127,
    count = #PATHS,
    source_commit = '',
    built_at = BUILT_AT,
  }
  manifest[key] = nil
  return vrix.encode(manifest, PATHS, matrix(ROWS))
end

T.case('load and current: a header without scale or index_dim is a reason, not a raise', function()
  for _, key in ipairs({ 'scale', 'index_dim' }) do
    with_vault(without(key), nil, function(root)
      local none, why = index.load(root, {})
      T.eq(none, nil)
      T.ok(why:find('being written or is damaged', 1, true), why)
    end)
  end
  with_vault(GOOD, nil, function(root)
    local first = assert(index.current(root, {}))
    put_index(root, without('scale'))
    local kept, warning = index.current(root, {})
    T.eq(kept, first) -- the old index stays
    T.ok(warning and warning:find('using the index loaded earlier', 1, true), tostring(warning))
  end)
end)

T.case('current and load without a cfg argument use the options in effect', function()
  with_vault(GOOD, nil, function(root)
    local loaded = assert(index.current(root))
    T.eq(loaded.index.count, 3)
    index.reset()
    T.eq(assert(index.load(root)).mode, 'obsidian')
  end)
  -- the options in effect decide the own index folder: without the plugin the vault is "eigen"
  with_vault(GOOD, nil, function(root)
    vim.fn.delete(root .. '/.obsidian/plugins', 'rf')
    require('note_retrieval.config').set({ index_dir = '_vaultrag' })
    local loaded = assert(index.current(root))
    T.eq(loaded.mode, 'eigen')
    require('note_retrieval.config').set(nil)
  end)
end)

T.case('stale_mark: the root is required, there is no last-served fallback', function()
  with_vault(container({ 'n.md' }, { ROWS[1] }), { ['n.md'] = BUILT + 5000 }, function(root)
    index.current(root, {})
    T.eq(index.stale_mark('n.md', root), 'maybe')
    T.ok(not pcall(index.stale_mark, 'n.md'), 'a call without root must raise')
  end)
end)

local function marks(stamp, file_mtime, file_size)
  local out
  with_vault(container({ 'n.md' }, { ROWS[1] }, { stamp }), { ['n.md'] = file_mtime }, function(root)
    if file_size then
      put(root .. '/n.md', ('x'):rep(file_size), file_mtime)
    end
    index.current(root, {})
    out = index.stale_mark('n.md', root)
  end)
  return out
end

T.case('stale_mark: a real stamp that differs is changed, one that matches is nothing', function()
  local mtime = BUILT - 5000
  T.eq(marks({ mtime * 1000, 5 }, mtime), nil)
  T.eq(marks({ (mtime - 60) * 1000, 5 }, mtime), 'changed')
  T.eq(marks({ mtime * 1000, 6 }, mtime), 'changed')
  T.eq(marks({ mtime * 1000, 5 }, mtime, 9), 'changed')
  -- a real stamp is trusted over built_at: a file newer than the index but with the stamp
  T.eq(marks({ (BUILT + 5000) * 1000, 5 }, BUILT + 5000), nil)
end)

T.case('stale_mark: stamp [0,0] and a file newer than built_at is maybe', function()
  T.eq(marks({ 0, 0 }, BUILT + 5000), 'maybe')
end)

T.case('stale_mark: stamp [0,0] and a file older than built_at has no mark', function()
  T.eq(marks({ 0, 0 }, BUILT - 5000), nil)
  -- exactly at built_at is not newer
  T.eq(marks({ 0, 0 }, BUILT), nil)
end)

T.case('stale_mark: no row, no file, no index in memory, no stamps at all', function()
  with_vault(
    container({ 'n.md', 'gone.md' }, { ROWS[1], ROWS[2] }),
    { ['n.md'] = BUILT + 5000 },
    function(root)
      T.eq(index.stale_mark('n.md', root), nil) -- nothing loaded yet
      index.current(root, {})
      T.eq(index.stale_mark('other.md', root), nil) -- not in the index
      T.eq(index.stale_mark('gone.md', root), nil) -- in the index, no file
      T.eq(index.stale_mark('n.md', root), 'maybe') -- an index without stamps: every row is unstamped
      T.eq(index.stale_mark('n.md', root), 'maybe') -- the root can be given
      T.eq(index.stale_mark('n.md', root .. '/elsewhere'), nil)
    end
  )
end)

T.case(
  'stale_mark: a file written after the load is seen without a reload; the index is not re-stamped',
  function()
    with_vault(container({ 'n.md' }, { ROWS[1] }, { { 0, 0 } }), { ['n.md'] = BUILT - 5000 }, function(root)
      local loaded = index.current(root, {})
      T.eq(index.stale_mark('n.md', root), nil)
      put(root .. '/n.md', 'edited', BUILT + 9000)
      T.eq(index.stale_mark('n.md', root), 'maybe')
      T.eq(loaded.stamps, { { 0, 0 } })
    end)
  end
)

T.case(
  'the index file is byte for byte the same after load, current, stale_mark and related, also over a torn file',
  function()
    with_vault(
      container(PATHS, ROWS, { { 0, 0 }, { 5, 5 }, { 0, 0 } }),
      { ['a.md'] = BUILT + 5000 },
      function(root)
        local file = root .. '/_vaultrag/index.bin'
        local before = sha(file)
        index.load(root, {})
        local loaded = index.current(root, {})
        for _, p in ipairs(PATHS) do
          index.stale_mark(p, root)
        end
        vectors.related(loaded.index, 'a.md', { k = 5, min_sim = 0 })
        put(root .. '/a.md', 'newer', BUILT + 9000)
        index.current(root, {})
        index.stale_mark('a.md', root)
        T.eq(sha(file), before)
        -- a torn file goes through the same paths: the reload fails, nothing is repaired or replaced
        put_index(root, GOOD:sub(1, 33))
        local torn = sha(file)
        index.current(root, {})
        index.current(root, {})
        index.stale_mark('a.md', root)
        T.eq(sha(file), torn)
      end
    )
  end
)

T.case('the sha256 of an untouched index file does not change over a long run of reads', function()
  with_vault(
    container(PATHS, ROWS, { { 0, 0 }, { 5, 5 }, { 0, 0 } }),
    { ['a.md'] = BUILT + 5000 },
    function(root)
      local file = root .. '/_vaultrag/index.bin'
      local before, mtime = sha(file), uv.fs_stat(file).mtime
      for _ = 1, 5 do
        index.load(root, {})
        local loaded = index.current(root, {})
        index.stale_mark('a.md', root)
        index.stale_mark('b.md', root)
        vectors.related(loaded.index, 'a.md', { k = 5, min_sim = 0 })
      end
      T.eq(sha(file), before)
      T.eq(uv.fs_stat(file).mtime, mtime)
      -- nothing else appeared in the index folder either (no temp file, no backup)
      T.eq(vim.fn.readdir(root .. '/_vaultrag'), { 'index.bin' })
    end
  )
end)

T.case('readonly_storage: reads like fs_storage, write and mkdir raise and leave the file alone', function()
  with_vault(GOOD, nil, function(root)
    local file = root .. '/_vaultrag/index.bin'
    local before = sha(file)
    local storage = index.readonly_storage()
    T.eq(storage.exists(file), true)
    T.eq(storage.exists(file .. '.nope'), false)
    T.eq(storage.read(file), GOOD)
    T.raises(function()
      storage.write(file, 'overwritten')
    end, 'the Obsidian index is read-only here')
    T.raises(function()
      storage.mkdir(root .. '/_vaultrag/new')
    end, 'the Obsidian index is read-only here')
    T.eq(sha(file), before)
    T.eq(uv.fs_stat(root .. '/_vaultrag/new'), nil)
    -- the same four functions a live indexer takes
    local live = require('note_retrieval.kit.live_indexer').fs_storage()
    local names, want = vim.tbl_keys(storage), vim.tbl_keys(live)
    table.sort(names)
    table.sort(want)
    T.eq(names, want)
  end)
end)
