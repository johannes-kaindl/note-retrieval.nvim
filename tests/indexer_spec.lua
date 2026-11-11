local T = require('note_retrieval.kit.test')
local indexer = require('note_retrieval.indexer')
local index = require('note_retrieval.index')
local lock = require('note_retrieval.kit.lock')
local roots = require('note_retrieval.roots')
local vrix = require('note_retrieval.kit.vrix')
local wait = require('note_retrieval.kit.wait')

local uv = vim.uv or vim.loop

local DIM = 4

-- A folder with `n` notes; `fn(root, cfg)`. The indexers are forgotten before and after, the
-- folder is removed (a read-only index folder made by a case is opened up first).
local function with_vault(n, fn, cfg_extra)
  local base = vim.fn.tempname()
  vim.fn.mkdir(base .. '/vault', 'p')
  local root = uv.fs_realpath(base .. '/vault')
  for i = 1, n do
    local f = assert(io.open(('%s/note-%03d.md'):format(root, i), 'wb'))
    f:write(('# Note %d\n\nsome words about note number %d'):format(i, i))
    f:close()
  end
  local cfg = vim.tbl_extend('force', { exclude = {} }, cfg_extra or {})
  indexer.reset()
  index.reset()
  local ok, err = pcall(fn, root, cfg)
  indexer.reset()
  index.reset()
  vim.fn.system({ 'chmod', '-R', 'u+rwx', base })
  vim.fn.delete(base, 'rf')
  assert(ok, err)
end

-- An in-memory storage: `files`, the paths written in order, an optional write failure.
local function mem_storage()
  local s = { files = {}, writes = {}, ver = {}, fail = false }
  s.exists = function(p)
    return s.files[p] ~= nil
  end
  s.read = function(p)
    return s.files[p]
  end
  s.write = function(p, bytes)
    if s.fail or s.fail_path == p then
      error('disk full', 0)
    end
    s.files[p] = bytes
    s.writes[#s.writes + 1] = p
    s.ver[p] = (s.ver[p] or 0) + 1
  end
  s.mkdir = function() end
  s.stat = function(p)
    return s.files[p] and { size = #s.files[p], v = s.ver[p] or 0 } or nil
  end
  return s
end

local function writes_to(storage, path)
  local n = 0
  for _, p in ipairs(storage.writes) do
    if p == path then
      n = n + 1
    end
  end
  return n
end

-- An embedding source double. mode: 'sync' answers at once, 'defer' on the main loop a few ms
-- later, 'fast' from a `vim.uv` timer callback, 'fail' with an error. `calls` counts requests.
local function embedder(mode)
  local e = { calls = 0 }
  e.fn = function(texts, cb)
    e.calls = e.calls + 1
    local vecs = {}
    for i, t in ipairs(texts) do
      vecs[i] = { 1 + (#t % 5), 2, 3, 4 }
    end
    if mode == 'fail' then
      return cb(nil, 'boom: the server went away')
    elseif mode == 'defer' then
      vim.defer_fn(function()
        cb(vecs)
      end, 3)
    elseif mode == 'fast' then
      local timer = uv.new_timer()
      timer:start(1, 0, function()
        timer:close()
        cb(vecs)
      end)
    else
      cb(vecs)
    end
  end
  return e
end

local function new_ix(root, cfg, storage, emb, model)
  return assert(indexer.for_root(root, {
    embedder = emb.fn,
    model = model or 'm1',
    dim = DIM,
    cfg = cfg,
    storage = storage,
  }))
end

local function reindex(ix, opts)
  local res, answered = wait.result(function(done)
    ix:reindex(function(report, err)
      done({ report, err })
    end, opts)
  end, 20000)
  assert(answered, 'the reindex did not finish')
  return res[1], res[2]
end

local function update(ix, path, text)
  local res, answered = wait.result(function(done)
    ix.live:update(path, text, nil, done)
  end, 5000)
  assert(answered and res == 'indexed', 'update failed')
end

local function decode(bytes)
  return assert(vrix.decode(bytes))
end

local function sha(path)
  local f = assert(io.open(path, 'rb'))
  local s = f:read('*a')
  f:close()
  return vim.fn.sha256((s:gsub('.', function(c)
    return ('%02x'):format(c:byte())
  end)))
end

T.case('for_root: one indexer per root, however the path is spelled', function()
  with_vault(1, function(root, cfg)
    local ix = new_ix(root, cfg, mem_storage(), embedder('sync'))
    T.ok(indexer.for_root(root .. '/') == ix, 'a trailing slash is the same root')
    T.ok(indexer.for_root(root) == ix, 'a call without options returns the indexer')
    -- counter: a root without an indexer and without options gets none
    T.eq((indexer.for_root(root .. '/other')), nil)
  end)
end)

T.case('for_root: lock and backup live in the state folder named by roots.hash', function()
  with_vault(2, function(root, cfg)
    local ix = new_ix(root, cfg, mem_storage(), embedder('sync'))
    local dir = vim.fn.stdpath('state') .. '/note-retrieval/' .. roots.hash(root)
    T.eq(ix.files.dir, dir)
    T.eq(ix.files.lock, dir .. '/index.lock')
    T.eq(ix.files.backup, dir .. '/index.bin.bak')
    -- the own index of the same root has the same folder name under stdpath('data')
    T.eq(vim.fs.basename(vim.fs.dirname(roots.index_path(root, 'own'))), vim.fs.basename(dir))
  end)
end)

T.case('reindex: every note gets a row and its stamp, taken from the file', function()
  with_vault(5, function(root, cfg)
    local st = mem_storage()
    local ix = new_ix(root, cfg, st, embedder('sync'))
    local seen = {}
    local report, err = reindex(ix, {
      on_progress = function(done, _, total)
        seen[#seen + 1] = { done, total, indexer.status(root).running, indexer.statusline(root) }
      end,
    })
    T.eq(err, nil)
    T.eq(report.added, 5)
    local d = decode(st.files[ix.path])
    T.eq(#d.paths, 5)
    T.eq(d.manifest.embedding_model, 'm1')
    for i, path in ipairs(d.paths) do
      local fs = assert(uv.fs_stat(root .. '/' .. path))
      T.eq(d.stamps[i], { fs.mtime.sec * 1000 + math.floor(fs.mtime.nsec / 1e6), fs.size })
    end
    -- progress was readable while the run was going, and is gone after it
    T.eq(seen[#seen], { 5, 5, true, 'indexing 5/5' })
    T.eq(indexer.status(root).running, false)
    T.eq(indexer.statusline(root), '')
    T.eq(indexer.status(root).lock.state, 'free')
    T.eq(indexer.status(root).report.added, 5)
  end)
end)

T.case('reindex: a cancel keeps every note it did not reach', function()
  with_vault(70, function(root, cfg)
    local st = mem_storage()
    local ix = new_ix(root, cfg, st, embedder('defer'))
    local _, err = reindex(ix)
    T.eq(err, nil)
    T.eq(decode(st.files[ix.path]).manifest.count, 70)
    local stopped = false
    local report, err2 = reindex(ix, {
      on_progress = function()
        if not stopped then
          stopped = true
          T.eq(indexer.stop(root), true)
        end
      end,
    })
    T.eq(err2, nil)
    T.eq(report.cancelled, true)
    T.eq(decode(st.files[ix.path]).manifest.count, 70)
    T.eq(ix.live:note_count(), 70)
    T.eq(indexer.stop(root), false)
  end)
end)

T.case('persist: a lock held by another Neovim is reported with its age and nothing is written', function()
  with_vault(2, function(root, cfg)
    local st = mem_storage()
    local ix = new_ix(root, cfg, st, embedder('sync'))
    update(ix, 'a.md', '# a\n\nsome text')
    local other = assert(lock.acquire(ix.files.lock))
    T.eq(indexer.status(root).lock.state, 'other')
    local ok, err = ix:persist()
    T.eq(ok, nil)
    T.eq(err.kind, 'locked')
    T.eq(type(err.age), 'number')
    T.ok(err.message:find('another Neovim holds the lock', 1, true), err.message)
    T.eq(#st.writes, 0)
    other.release()
    T.eq(ix:persist(), true)
    T.eq(#st.writes, 1)
    T.eq(uv.fs_stat(ix.files.lock), nil)
  end)
end)

T.case('persist: a lock left behind by a dead process is taken over', function()
  with_vault(2, function(root, cfg)
    local st = mem_storage()
    local ix = new_ix(root, cfg, st, embedder('sync'))
    update(ix, 'a.md', '# a\n\nsome text')
    vim.fn.mkdir(vim.fs.dirname(ix.files.lock), 'p')
    local f = assert(io.open(ix.files.lock, 'wb'))
    f:write('99999 2026-01-01T00:00:00\n')
    f:close()
    local old = os.time() - 7200
    assert(uv.fs_utime(ix.files.lock, old, old))
    T.eq(indexer.status(root).lock.state, 'stale')
    T.eq(ix:persist(), true)
    T.eq(#st.writes, 1)
    T.eq(uv.fs_stat(ix.files.lock), nil)
  end)
end)

T.case('backup: before the first write of a session and before a reindex, not on every save', function()
  with_vault(3, function(root, cfg)
    local st = mem_storage()
    local first = new_ix(root, cfg, st, embedder('sync'))
    reindex(first)
    T.eq(st.files[first.files.backup], nil) -- nothing there to back up yet
    local built = st.files[first.path]
    indexer.reset(root) -- a new session on the index that is there
    local ix = new_ix(root, cfg, st, embedder('sync'))
    for i = 1, 3 do
      update(ix, 'extra-' .. i .. '.md', '# x\n\nnote ' .. i)
      T.eq(ix:persist(), true)
    end
    T.eq(writes_to(st, ix.files.backup), 1)
    T.eq(st.files[ix.files.backup], built)
    local before_reindex = st.files[ix.path]
    reindex(ix)
    T.eq(writes_to(st, ix.files.backup), 2)
    T.eq(st.files[ix.files.backup], before_reindex)
    -- a save after that one makes no third copy
    update(ix, 'again.md', '# x\n\nagain')
    T.eq(ix:persist(), true)
    T.eq(writes_to(st, ix.files.backup), 2)
  end)
end)

T.case('persist: a write error is a value, the old container stays and the lock is released', function()
  with_vault(3, function(root, cfg)
    local st = mem_storage()
    local ix = new_ix(root, cfg, st, embedder('sync'))
    reindex(ix)
    local before = st.files[ix.path]
    update(ix, 'extra.md', '# x\n\nmore')
    st.fail = true
    local ok, err = ix:persist()
    T.eq(ok, nil)
    T.eq(err.kind, 'write-failed')
    T.ok(err.message:find('disk full', 1, true), err.message)
    T.eq(st.files[ix.path], before)
    T.eq(uv.fs_stat(ix.files.lock), nil)
    T.eq(indexer.status(root).last_error.kind, 'write-failed')
    st.fail = false
    T.eq(ix:persist(), true)
    T.eq(indexer.status(root).last_error, nil)
  end)
end)

T.case('reindex: a failing final write reaches the caller with the report', function()
  with_vault(3, function(root, cfg)
    local st = mem_storage()
    local ix = new_ix(root, cfg, st, embedder('sync'))
    st.fail = true
    local report, err = reindex(ix)
    T.eq(report.added, 3)
    T.eq(err.kind, 'write-failed')
    T.eq(st.files[ix.path], nil)
    T.eq(indexer.status(root).last_error.kind, 'write-failed')
  end)
end)

T.case(
  'model change: a live write is refused in words that name the reindex, a reindex goes through',
  function()
    with_vault(3, function(root, cfg)
      local st = mem_storage()
      local ix = new_ix(root, cfg, st, embedder('sync'))
      reindex(ix)
      local before = st.files[ix.path]
      local again =
        assert(indexer.for_root(root, { embedder = embedder('sync').fn, model = 'm2', dim = DIM }))
      T.ok(again == ix, 'still the one indexer')
      T.eq(ix.model, 'm2')
      update(ix, 'extra.md', '# x\n\nmore')
      local ok, err = ix:persist()
      T.eq(ok, nil)
      T.eq(err.kind, 'not-ready')
      T.ok(err.message:find(':NoteRetrieval reindex', 1, true), err.message)
      T.ok(err.message:find('built with "m1"', 1, true), err.message)
      T.eq(st.files[ix.path], before)
      T.eq(reindex(ix).added, 3)
      T.eq(decode(st.files[ix.path]).manifest.embedding_model, 'm2')
    end)
  end
)

T.case('dim change: the vectors in memory are not taken over, a live write is refused', function()
  with_vault(3, function(root, cfg)
    local st = mem_storage()
    local ix = new_ix(root, cfg, st, embedder('sync'))
    reindex(ix)
    local before = st.files[ix.path]
    assert(indexer.for_root(root, { embedder = embedder('sync').fn, model = 'm1', dim = 8 }))
    local ok, err = ix:persist()
    T.eq(ok, nil)
    T.eq(err.kind, 'not-ready')
    T.ok(err.message:find(':NoteRetrieval reindex', 1, true), err.message)
    T.eq(st.files[ix.path], before)
  end)
end)

T.case('a run keeps Neovim responsive between two embedder calls', function()
  with_vault(70, function(root, cfg)
    local function ticks_during(mode)
      indexer.reset(root)
      local ix = new_ix(root, cfg, mem_storage(), embedder(mode))
      local ticks = 0
      local timer = uv.new_timer()
      timer:start(
        0,
        1,
        vim.schedule_wrap(function()
          ticks = ticks + 1
        end)
      )
      reindex(ix)
      timer:stop()
      timer:close()
      return ticks
    end
    T.ok(ticks_during('defer') >= 3, 'a timer must run while the embedder is being waited for')
    -- the control: an embedder that answers at once leaves no gap, so the measurement can fail
    T.eq(ticks_during('sync'), 0)
  end)
end)

T.case('mode flip: a root that turns into an Obsidian vault is not written to', function()
  with_vault(3, function(root, cfg)
    local obsidian_index = root .. '/_idx/index.bin'
    local ix = new_ix(root, cfg, nil, embedder('sync'), 'm1')
    T.eq(ix.path, obsidian_index)
    -- the Obsidian plugin appears after the indexer was made, with its index in the same folder
    vim.fn.mkdir(root .. '/.obsidian/plugins/vault-retrieval', 'p')
    vim.fn.mkdir(root .. '/_idx', 'p')
    local f = assert(io.open(obsidian_index, 'wb'))
    f:write('not ours')
    f:close()
    local before = sha(obsidian_index)
    update(ix, 'extra.md', '# x\n\nmore')
    local ok, err = ix:persist()
    T.eq(ok, nil)
    T.eq(err.kind, 'not-own')
    T.ok(err.message:find('belongs to the Obsidian plugin', 1, true), err.message)
    local report, rerr = reindex(ix)
    T.eq(report, nil)
    T.eq(rerr.kind, 'not-own')
    T.eq(sha(obsidian_index), before)
    T.eq(uv.fs_stat(ix.files.lock), nil)
    -- and a root that is Obsidian's gets no new indexer
    indexer.reset(root)
    local none, why = indexer.for_root(root, { embedder = embedder('sync').fn, model = 'm1', cfg = cfg })
    T.eq(none, nil)
    T.ok(why:find('Obsidian', 1, true), why)
  end, { index_dir = '_idx' })
end)

T.case('reindex: an embedder that answers from a fast callback does not break lock or write', function()
  with_vault(270, function(root, cfg)
    local st = mem_storage()
    local ix = new_ix(root, cfg, st, embedder('fast'))
    local in_fast
    local res, answered = wait.result(function(done)
      ix:reindex(function(report, err)
        in_fast = vim.in_fast_event()
        done({ report, err })
      end)
    end, 30000)
    assert(answered, 'the reindex did not finish')
    T.eq(res[2], nil)
    T.eq(res[1].added, 270)
    T.eq(in_fast, false)
    T.eq(#ix.warnings, 0) -- the intermediate state at 250 notes was written too
    T.ok(#st.writes >= 2, 'an intermediate state and the final one')
    T.eq(decode(st.files[ix.path]).manifest.count, 270)
  end)
end)

T.case('reindex: notes that failed to embed do not replace a good index with a thin one', function()
  with_vault(70, function(root, cfg)
    local st = mem_storage()
    local ix = new_ix(root, cfg, st, embedder('sync'))
    reindex(ix)
    local before, writes = st.files[ix.path], #st.writes
    ix.embedder = embedder('fail').fn
    local report, err = reindex(ix)
    T.eq(#report.failed, 70)
    T.eq(err.kind, 'incomplete')
    T.ok(err.message:find('index on disk was not replaced', 1, true), err.message)
    T.eq(st.files[ix.path], before)
    T.eq(#st.writes, writes)
    T.eq(ix.live:note_count(), 70) -- memory was read from disk again
  end)
end)

T.case('reindex: a vault without notes leaves the index alone', function()
  with_vault(0, function(root, cfg)
    local st = mem_storage()
    local ix = new_ix(root, cfg, st, embedder('sync'))
    local report, err = reindex(ix)
    T.eq(report, nil)
    T.eq(err.kind, 'no-notes')
    T.eq(#st.writes, 0)
  end)
end)

T.case('reindex: a second one while one runs is refused', function()
  with_vault(70, function(root, cfg)
    local ix = new_ix(root, cfg, mem_storage(), embedder('defer'))
    local second
    reindex(ix, {
      on_progress = function()
        if not second then
          ix:reindex(function(report, err)
            second = { report, err }
          end)
        end
      end,
    })
    T.eq(second[1], nil)
    T.eq(second[2].kind, 'running')
  end)
end)

T.case('reset: a running reindex keeps its indexer, an idle one is forgotten', function()
  with_vault(70, function(root, cfg)
    local ix = new_ix(root, cfg, mem_storage(), embedder('defer'))
    local kept
    reindex(ix, {
      on_progress = function()
        kept = kept or indexer.reset()
      end,
    })
    T.eq(kept, { root })
    T.ok(indexer.for_root(root) == ix, 'the indexer of the run is still the one')
    T.eq(ix.live:note_count(), 70)
    T.eq(indexer.reset(), {})
    T.eq((indexer.for_root(root)), nil)
  end)
end)

T.case('sync and changed: another writer is noticed, never overwritten', function()
  with_vault(5, function(root, cfg)
    local st = mem_storage()
    local ix = new_ix(root, cfg, st, embedder('sync'))
    reindex(ix)
    -- another Neovim writes its own, smaller index of the same format
    local base = vim.fn.tempname() .. '/v'
    vim.fn.mkdir(base, 'p')
    for i = 1, 3 do
      local f = assert(io.open(('%s/other-%d.md'):format(base, i), 'wb'))
      f:write('# other\n\nwords ' .. i)
      f:close()
    end
    local st2 = mem_storage()
    local other = indexer.for_root(
      base,
      { embedder = embedder('sync').fn, model = 'm1', dim = DIM, cfg = cfg, storage = st2 }
    )
    reindex(other)
    local theirs = st2.files[other.path]
    st.write(ix.path, theirs)
    update(ix, 'extra.md', '# x\n\nmore')
    local writes = #st.writes
    local ok, err = ix:persist()
    T.eq(ok, nil)
    T.eq(err.kind, 'changed')
    T.eq(#st.writes, writes)
    T.eq(st.files[ix.path], theirs)
    T.eq(ix:sync(), true)
    T.eq(ix.live:note_count(), 3)
    T.eq(ix:sync(), true) -- unchanged now: nothing is read again
    vim.fn.delete(vim.fs.dirname(base), 'rf')
  end)
end)

T.case('real file system: reindex, load back, backup, and a read-only folder keeps the old file', function()
  with_vault(4, function(root, cfg)
    local ix = new_ix(root, cfg, nil, embedder('sync'))
    T.eq(ix.path, root .. '/_nr/index.bin')
    local report, err = reindex(ix)
    T.eq(err, nil)
    T.eq(report.added, 4)
    T.eq(uv.fs_stat(ix.files.lock), nil)
    T.eq(uv.fs_stat(ix.files.backup), nil)
    -- the reader of the plugin reads what the writer wrote; the index folder is not a note
    local loaded = assert(index.load(root, cfg))
    T.eq(loaded.index.count, 4)
    T.eq(loaded.mode, 'own')
    T.eq(loaded.stamps[1][2] > 0, true)
    -- a second reindex backs up the first
    local first = sha(ix.path)
    T.eq(select(2, reindex(ix)), nil)
    T.ok(uv.fs_stat(ix.files.backup) ~= nil, 'the backup is there')
    T.eq(sha(ix.files.backup), first)
    -- a folder that cannot be written to
    local dir = vim.fs.dirname(ix.path)
    assert(uv.fs_chmod(dir, tonumber('500', 8)))
    if uv.fs_access(dir, 'W') then
      assert(uv.fs_chmod(dir, tonumber('700', 8)))
      return -- running as a user who can write anywhere: nothing to measure
    end
    local before = sha(ix.path)
    update(ix, 'extra.md', '# x\n\nmore')
    local ok, werr = ix:persist()
    T.eq(ok, nil)
    T.eq(werr.kind, 'write-failed')
    T.eq(sha(ix.path), before)
    T.eq(uv.fs_stat(ix.files.lock), nil)
    assert(uv.fs_chmod(dir, tonumber('700', 8)))
    T.eq(select(2, reindex(ix)), nil)
  end, { index_dir = '_nr' })
end)

T.case(':NoteRetrieval reset: names a running reindex and leaves it alone', function()
  with_vault(70, function(root, cfg)
    local ix = new_ix(root, cfg, mem_storage(), embedder('defer'))
    local seen = {}
    local notify = vim.notify
    reindex(ix, {
      on_progress = function()
        if #seen == 0 then
          vim.notify = function(msg)
            seen[#seen + 1] = msg
          end
          require('note_retrieval.command').reset()
          vim.notify = notify
        end
      end,
    })
    vim.notify = notify
    T.ok(seen[1]:find('a reindex is running in ' .. root .. ' and was left alone', 1, true), seen[1])
    T.ok(indexer.for_root(root) == ix, 'the indexer survived the reset')
    -- counter: with nothing running the message says nothing about a run
    require('note_retrieval.command').reset()
    T.eq((indexer.for_root(root)), nil)
  end)
end)

T.case('model change: the old vectors are not carried over, also when the index file goes away', function()
  with_vault(3, function(root, cfg)
    local st = mem_storage()
    local ix = new_ix(root, cfg, st, embedder('sync'))
    reindex(ix)
    assert(indexer.for_root(root, { embedder = embedder('sync').fn, model = 'm2', dim = DIM }))
    T.eq(ix.live:note_count(), 0)
    -- the file is removed behind our back: nothing of model m1 may come back under the name m2
    st.files[ix.path] = nil
    T.eq(ix:sync(), true)
    update(ix, 'extra.md', '# x\n\nmore')
    T.eq(ix:persist(), true)
    local d = decode(st.files[ix.path])
    T.eq(d.paths, { 'extra.md' })
    T.eq(d.manifest.embedding_model, 'm2')
  end)
end)

T.case("reindex: memory behind the disk does not let a dying server thin another Neovim's index", function()
  with_vault(10, function(root, cfg)
    local st = mem_storage()
    -- this indexer starts with no index file (memory empty)
    local ix = new_ix(root, cfg, st, embedder('sync'))
    T.eq(ix.live:note_count(), 0)
    -- another Neovim then writes a full index of the same vault and model: built here by the
    -- same indexer with a storage of its own, then put in place as the other process's write
    local base = vim.fn.tempname() .. '/v'
    vim.fn.mkdir(base, 'p')
    for i = 1, 10 do
      local f = assert(io.open(('%s/note-%03d.md'):format(base, i), 'wb'))
      f:write(('# Note %d\n\nsome words about note number %d'):format(i, i))
      f:close()
    end
    local st2 = mem_storage()
    local other = new_ix(base, cfg, st2, embedder('sync'))
    T.eq(select(2, reindex(other)), nil)
    local theirs = st2.files[other.path]
    vim.fn.delete(vim.fs.dirname(base), 'rf')
    T.eq(decode(theirs).manifest.count, 10)
    st.files[ix.path], st.ver[ix.path] = theirs, 99
    T.eq(ix.live:note_count(), 0) -- memory still as it was before their write
    -- the server dies after two notes
    local calls = 0
    ix.embedder = function(texts, cb)
      calls = calls + 1
      if calls == 1 or calls > 3 then
        return cb(nil, 'server gone')
      end
      local vecs = {}
      for i = 1, #texts do
        vecs[i] = { 1, 2, 3, 4 }
      end
      cb(vecs)
    end
    local report, err = reindex(ix)
    T.eq(#report.failed > 0, true)
    T.eq(err.kind, 'incomplete')
    T.eq(st.files[ix.path], theirs)
  end)
end)

T.case('reindex: a failed write after a cancel reaches the caller', function()
  with_vault(70, function(root, cfg)
    local st = mem_storage()
    local ix = new_ix(root, cfg, st, embedder('sync'))
    reindex(ix)
    local before = st.files[ix.path]
    ix.embedder = embedder('defer').fn
    local stopped = false
    local report, err = reindex(ix, {
      on_progress = function()
        if not stopped then
          stopped = true
          st.fail_path = ix.path -- the copy is made, the write of the index fails
          indexer.stop(root)
        end
      end,
    })
    T.eq(report.cancelled, true)
    T.eq(err.kind, 'write-failed')
    T.ok(err.message:find('disk full', 1, true), err.message)
    T.eq(indexer.status(root).last_error.kind, 'write-failed')
    T.eq(st.files[ix.path], before)
  end)
end)

T.case('reindex after a model change: a dying server does not thin the index of the old model', function()
  with_vault(10, function(root, cfg)
    local st = mem_storage()
    local ix = new_ix(root, cfg, st, embedder('sync'))
    reindex(ix)
    local before = st.files[ix.path]
    -- the new model: memory starts empty and the disk holds model m1, so only the count read from
    -- the disk tells how much a thin result would lose
    local calls = 0
    local dying = function(texts, cb)
      calls = calls + 1
      if calls == 1 or calls > 3 then
        return cb(nil, 'server gone')
      end
      local vecs = {}
      for i = 1, #texts do
        vecs[i] = { 1, 2, 3, 4 }
      end
      cb(vecs)
    end
    assert(indexer.for_root(root, { embedder = dying, model = 'm2', dim = DIM }))
    local report, err = reindex(ix)
    T.eq(#report.failed > 0, true)
    T.eq(err.kind, 'incomplete')
    T.eq(st.files[ix.path], before)
  end)
end)

T.case(
  'reindex: a cancel that wrote nothing keeps the disk count, a rerun with a dying server is refused',
  function()
    with_vault(70, function(root, cfg)
      local st = mem_storage()
      local ix = new_ix(root, cfg, st, embedder('sync'))
      reindex(ix)
      local before = st.files[ix.path]
      -- the new model: the disk holds m1, so the kit writes nothing when the run is cancelled
      assert(indexer.for_root(root, { embedder = embedder('defer').fn, model = 'm2', dim = DIM }))
      local stopped = false
      local report, err = reindex(ix, {
        on_progress = function()
          if not stopped then
            stopped = true
            indexer.stop(root)
          end
        end,
      })
      T.eq(report.cancelled, true)
      T.eq(err, nil)
      T.eq(st.files[ix.path], before)
      -- the rerun: the server dies after two notes
      local calls = 0
      local dying = function(texts, cb)
        calls = calls + 1
        if calls == 1 or calls > 3 then
          return cb(nil, 'server gone')
        end
        local vecs = {}
        for i = 1, #texts do
          vecs[i] = { 1, 2, 3, 4 }
        end
        cb(vecs)
      end
      assert(indexer.for_root(root, { embedder = dying, model = 'm2', dim = DIM }))
      local report2, err2 = reindex(ix)
      T.eq(#report2.failed > 0, true)
      T.eq(err2.kind, 'incomplete')
      T.eq(st.files[ix.path], before)
    end)
  end
)

-- ix:sync_vault to its end: result, err.
local function sync_vault(ix)
  local res, answered = wait.result(function(done)
    ix:sync_vault(function(result, err)
      done({ result, err })
    end)
  end, 20000)
  assert(answered, 'the update did not finish')
  return res[1], res[2]
end

local function write(path, text)
  local f = assert(io.open(path, 'wb'))
  f:write(text)
  f:close()
end

T.case(
  'sync: new, changed, deleted and emptied notes; a note empty after the front matter gets no row',
  function()
    with_vault(5, function(root, cfg)
      local st = mem_storage()
      local ix = new_ix(root, cfg, st, embedder('sync'))
      T.eq(select(2, reindex(ix)), nil)
      local before = decode(st.files[ix.path])
      T.eq(#before.paths, 5)
      write(root .. '/new.md', '# New\n\nfresh words')
      write(root .. '/note-002.md', '# Note 2\n\nchanged, and now a good deal longer than it was')
      os.remove(root .. '/note-003.md')
      write(root .. '/note-004.md', '---\ntitle: x\n---\n')
      write(root .. '/empty.md', '---\ntitle: y\n---\n')
      local result, err = sync_vault(ix)
      T.eq(err, nil)
      T.eq(result.embedded, 2)
      T.eq(result.removed, 2)
      T.eq(#result.failed, 0)
      local d = decode(st.files[ix.path])
      T.eq(d.paths, { 'new.md', 'note-001.md', 'note-002.md', 'note-005.md' })
      -- the changed note carries the stamp of the new file; counter-proof: the stamp comparison
      local fs = assert(uv.fs_stat(root .. '/note-002.md'))
      for i, path in ipairs(d.paths) do
        if path == 'note-002.md' then
          T.eq(d.stamps[i], { fs.mtime.sec * 1000 + math.floor(fs.mtime.nsec / 1e6), fs.size })
        end
      end
      -- nothing left to do: a second update embeds nothing and writes nothing
      local writes, calls = #st.writes, ix.live and 0
      local again = sync_vault(ix)
      T.eq({ again.embedded, again.removed }, { 0, 0 })
      T.eq(#st.writes, writes)
      T.eq(calls, 0)
      T.eq(indexer.status(root).running, false)
    end)
  end
)

T.case('sync: a zero row is embedded again', function()
  with_vault(3, function(root, cfg)
    local st = mem_storage()
    local zero = false
    local emb = embedder('sync')
    local inner = emb.fn
    emb.fn = function(texts, cb)
      if zero then
        local vecs = {}
        for i = 1, #texts do
          vecs[i] = { 0, 0, 0, 0 }
        end
        return cb(vecs)
      end
      inner(texts, cb)
    end
    local ix = new_ix(root, cfg, st, emb)
    zero = true
    T.eq(select(2, reindex(ix)), nil)
    zero = false
    local result = sync_vault(ix)
    T.eq(result.embedded, 3)
  end)
end)

T.case('sync: a foreign model on disk blocks the update before anything is embedded', function()
  with_vault(3, function(root, cfg)
    local st = mem_storage()
    local emb = embedder('sync')
    local ix = new_ix(root, cfg, st, emb, 'm1')
    T.eq(select(2, reindex(ix)), nil)
    -- the setup changes its model: the index on disk is m1's
    new_ix(root, cfg, st, emb, 'm2')
    write(root .. '/new.md', '# New\n\nfresh words')
    local calls, bytes = emb.calls, st.files[ix.path]
    local result, err = sync_vault(ix)
    T.eq(result, nil)
    T.eq(err.kind, 'model-mismatch')
    T.eq(emb.calls, calls)
    T.eq(st.files[ix.path], bytes)
    T.eq(indexer.status(root).running, false)
  end)
end)

T.case('sync: the model on disk is asked again even when the stat of the file looks the same', function()
  with_vault(3, function(root, cfg)
    local st = mem_storage()
    local emb = embedder('sync')
    local ix = new_ix(root, cfg, st, emb, 'm1')
    T.eq(select(2, reindex(ix)), nil)
    local own = st.files[ix.path]
    -- the same index built with m2, kept as the foreign bytes
    new_ix(root, cfg, st, emb, 'm2')
    T.eq(select(2, reindex(ix)), nil)
    local foreign = st.files[ix.path]
    new_ix(root, cfg, st, emb, 'm1')
    T.eq(select(2, reindex(ix)), nil)
    T.eq(#foreign, #own)
    -- another process swaps the file without the stat changing (same size, same version)
    st.files[ix.path] = foreign
    write(root .. '/new.md', '# New\n\nfresh words')
    local calls = emb.calls
    local result, err = sync_vault(ix)
    T.eq(result, nil)
    T.eq(err.kind, 'model-mismatch')
    T.eq(emb.calls, calls)
    T.eq(st.files[ix.path], foreign)
  end)
end)

T.case('sync and reindex refuse each other while one runs', function()
  with_vault(60, function(root, cfg)
    local st = mem_storage()
    local ix = new_ix(root, cfg, st, embedder('defer'))
    local finished
    ix:reindex(function()
      finished = true
    end)
    local result, err
    ix:sync_vault(function(r, e)
      result, err = r, e
    end)
    T.eq(result, nil)
    T.eq(err.kind, 'running')
    T.ok(tostring(err):find('reindex is already running', 1, true), tostring(err))
    T.ok(
      vim.wait(20000, function()
        return finished
      end, 5),
      'the reindex did not finish'
    )
    -- and the other way round: a vault with new notes makes the update embed for a while
    write(root .. '/new.md', '# New\n\nfresh words')
    local done
    ix:sync_vault(function()
      done = true
    end)
    T.eq(indexer.status(root).kind, 'sync')
    T.eq(indexer.statusline(root):find('^updating') ~= nil, true)
    local rerr
    ix:reindex(function(_, e)
      rerr = e
    end)
    T.eq(rerr.kind, 'running')
    T.ok(tostring(rerr):find('update of the index is running', 1, true), tostring(rerr))
    T.eq(indexer.stop(root), false)
    T.ok(
      vim.wait(20000, function()
        return done
      end, 5),
      'the update did not finish'
    )
    T.eq(indexer.status(root).running, false)
  end)
end)

T.case('sync: Neovim stays responsive while the update runs', function()
  with_vault(40, function(root, cfg)
    local ix = new_ix(root, cfg, mem_storage(), embedder('defer'))
    local ticks, done = 0, false
    local timer = uv.new_timer()
    timer:start(1, 2, function()
      ticks = ticks + 1
    end)
    local returned_before_done
    ix:sync_vault(function()
      done = true
    end)
    returned_before_done = not done
    T.ok(
      vim.wait(20000, function()
        return done
      end, 5),
      'the update did not finish'
    )
    timer:stop()
    timer:close()
    T.eq(returned_before_done, true)
    T.ok(ticks >= 3, 'the timer ticked only ' .. ticks .. ' times')
  end)
end)

T.case('real file system: an update replaces the loaded paths table and never changes the old one', function()
  with_vault(4, function(root, cfg)
    local ix = new_ix(root, cfg, nil, embedder('sync'))
    T.eq(select(2, reindex(ix)), nil)
    local first = assert(index.current(root, cfg))
    local copy = vim.deepcopy(first.paths)
    T.eq(#copy, 4)
    -- nothing to do: nothing is written, the same table stays
    local noop = sync_vault(ix)
    T.eq({ noop.embedded, noop.removed }, { 0, 0 })
    T.ok(assert(index.current(root, cfg)).paths == first.paths, 'the table changed without a write')
    write(root .. '/new.md', '# New\n\nfresh words')
    os.remove(root .. '/note-001.md')
    local result, err = sync_vault(ix)
    T.eq(err, nil)
    T.eq({ result.embedded, result.removed }, { 1, 1 })
    local second = assert(index.current(root, cfg))
    T.ok(second.paths ~= first.paths, 'the paths table was not replaced')
    T.eq(first.paths, copy)
    T.eq(#second.paths, 4)
    T.eq(second.paths[1], 'new.md')
    T.eq(uv.fs_stat(ix.files.lock), nil)
  end, { index_dir = '_nr' })
end)

-- A vault of `n` top-level notes and `sub_n` notes in sub/, indexed; `fn(root, cfg, ix, st)`.
local function with_indexed_sub(n, sub_n, fn)
  with_vault(n, function(root, cfg)
    for i = 1, sub_n do
      vim.fn.mkdir(root .. '/sub', 'p')
      write(('%s/sub/s%03d.md'):format(root, i), ('# Sub %d\n\nwords of sub note %d'):format(i, i))
    end
    local st = mem_storage()
    local ix = new_ix(root, cfg, st, embedder('sync'))
    T.eq(select(2, reindex(ix)), nil)
    T.eq(#decode(st.files[ix.path]).paths, n + sub_n)
    fn(root, cfg, ix, st)
  end)
end

T.case('sync: the notes of a folder that cannot be read stay in the index, and the result says so', function()
  with_indexed_sub(4, 6, function(root, _, ix, st)
    local ok, err = pcall(function()
      assert(vim.fn.system({ 'chmod', '000', root .. '/sub' }) == '', 'chmod failed')
      if uv.fs_scandir(root .. '/sub') then
        -- running as root: the permission does not stop us. Say so, a silent pass proves nothing; the
        -- cases below with a patched walk cover the same logic everywhere.
        uv.fs_write(
          2,
          'SKIPPED (chmod does not stop a scan here): sync keeps the rows of an unreadable folder\n'
        )
        return 'readable'
      end
      write(root .. '/new.md', '# New\n\nfresh words')
      local result, e = sync_vault(ix)
      T.eq(e, nil)
      T.eq(result.unreadable, 1)
      T.eq(result.removed, 0)
      T.eq(result.embedded, 1)
      local d = decode(st.files[ix.path])
      local n_sub = 0
      for _, p in ipairs(d.paths) do
        if p:find('^sub/') then
          n_sub = n_sub + 1
        end
      end
      T.eq(n_sub, 6)
      T.eq(#d.paths, 11)
    end)
    vim.fn.system({ 'chmod', '755', root .. '/sub' })
    assert(ok, err)
    -- counter-proof of the cleanup: the folder is readable again, a note deleted there is dropped
    os.remove(root .. '/sub/s001.md')
    local result = sync_vault(ix)
    T.eq({ result.unreadable, result.removed }, { 0, 1 })
  end)
end)

T.case('sync: more than half of the rows dropped while their files are still there is refused', function()
  with_indexed_sub(2, 6, function(root, cfg, ix, st)
    local before = #st.writes
    cfg.exclude = { 'sub/' } -- the walk no longer lists sub/, the files are still there
    local result, err = sync_vault(ix)
    T.eq(result, nil)
    T.eq(err.kind, 'shrink')
    T.eq(#st.writes, before)
    T.eq(#decode(st.files[ix.path]).paths, 8)
    -- counter-proof: the same share of rows may go when the files are really gone
    for i = 1, 6 do
      os.remove(('%s/sub/s%03d.md'):format(root, i))
    end
    local ok_result, ok_err = sync_vault(ix)
    T.eq(ok_err, nil)
    T.eq(ok_result.removed, 6)
    T.eq(#decode(st.files[ix.path]).paths, 2)
  end)
end)

-- Runs `fn` with the walk of the vault patched: `hide(path)` is true for the notes the walk does not
-- see, `skipped` the folders it reports as not (fully) read. A failed read cannot be provoked on every
-- system (chmod does nothing as root, a read that fails half way never), so these cases always run.
local function with_walk(hide, skipped, fn)
  local original = roots.note_paths
  roots.note_paths = function(...)
    local paths, sk = original(...)
    if not paths then
      return paths, sk
    end
    local seen = {}
    for _, p in ipairs(paths) do
      if not hide(p) then
        seen[#seen + 1] = p
      end
    end
    return seen, skipped
  end
  local ok, err = pcall(fn)
  roots.note_paths = original
  assert(ok, err)
end

local function paths_on_disk(st, ix)
  return decode(st.files[ix.path]).paths
end

T.case('sync: a vault folder read only in part keeps every row, also those of folders below it', function()
  with_indexed_sub(4, 6, function(root, _, ix, st)
    -- the walk lists the notes of the root, then fails: the folder sub/ may have been after the failure
    with_walk(function(p)
      return p:find('^sub/') ~= nil
    end, { '.' }, function()
      local result, err = sync_vault(ix)
      T.eq(err, nil)
      T.eq({ result.removed, result.unreadable }, { 0, 1 })
      T.eq(#paths_on_disk(st, ix), 10)
    end)
    -- counter-proof: with the walk whole again a note that is really gone is dropped
    os.remove(root .. '/sub/s001.md')
    local again = sync_vault(ix)
    T.eq({ again.removed, again.unreadable }, { 1, 0 })
    T.eq(#paths_on_disk(st, ix), 9)
  end)
end)

T.case(
  'sync: an unreadable folder protects its own notes and those below, not a folder with the same start',
  function()
    with_indexed_sub(2, 3, function(root, _, ix, st)
      vim.fn.mkdir(root .. '/sub/deep', 'p')
      vim.fn.mkdir(root .. '/sub2', 'p')
      write(root .. '/sub/deep/d.md', '# Deep\n\nwords of a deep note')
      write(root .. '/sub2/x.md', '# Other\n\nwords of a note in sub2')
      T.eq(select(2, sync_vault(ix)), nil)
      T.eq(#paths_on_disk(st, ix), 7)
      -- sub/ cannot be read: its notes, also below it, stay. sub2/x.md is gone for real and goes.
      os.remove(root .. '/sub2/x.md')
      with_walk(function(p)
        return p:find('^sub/') ~= nil
      end, { 'sub' }, function()
        local result, err = sync_vault(ix)
        T.eq(err, nil)
        T.eq({ result.removed, result.unreadable }, { 1, 1 })
        T.eq(#paths_on_disk(st, ix), 6)
        T.ok(vim.tbl_contains(paths_on_disk(st, ix), 'sub/deep/d.md'), 'the note below sub/ stays')
      end)
      -- only sub/deep is unreadable: a note gone from sub/ itself is dropped, the one below stays
      os.remove(root .. '/sub/s001.md')
      with_walk(function(p)
        return p:find('^sub/deep/') ~= nil
      end, { 'sub/deep' }, function()
        local result, err = sync_vault(ix)
        T.eq(err, nil)
        T.eq({ result.removed, result.unreadable }, { 1, 1 })
        T.ok(
          vim.tbl_contains(paths_on_disk(st, ix), 'sub/deep/d.md'),
          'the note of the unreadable folder stays'
        )
        T.ok(not vim.tbl_contains(paths_on_disk(st, ix), 'sub/s001.md'), 'the gone note beside it is dropped')
      end)
    end)
  end
)

-- A note that is empty after its front matter.
local function empty_note(path)
  write(path, '---\ntitle: x\n---\n')
end

T.case('sync: more than half of the rows emptied at once is refused like vanished files', function()
  with_vault(8, function(root, cfg)
    local st = mem_storage()
    local emb = embedder('sync')
    local ix = new_ix(root, cfg, st, emb)
    T.eq(select(2, reindex(ix)), nil)
    local before, writes = st.files[ix.path], #st.writes
    for i = 1, 6 do
      empty_note(('%s/note-%03d.md'):format(root, i))
    end
    local result, err = sync_vault(ix)
    T.eq(result, nil)
    T.eq(err.kind, 'shrink')
    T.eq(#st.writes, writes)
    T.eq(st.files[ix.path], before)
    T.eq(ix.live:note_count(), 8) -- memory is the disk again
    -- counter-proof: four of them have text again, two stay empty - that many rows may go
    for i = 1, 4 do
      write(('%s/note-%03d.md'):format(root, i), ('# Note %d\n\nwritten again, longer than before'):format(i))
    end
    local ok_result, ok_err = sync_vault(ix)
    T.eq(ok_err, nil)
    T.eq({ ok_result.removed, ok_result.embedded }, { 2, 4 })
    T.eq(#paths_on_disk(st, ix), 6)
  end)
end)

T.case('start: damaged bytes on disk are not an empty index; nothing is written over them', function()
  with_vault(3, function(root, cfg)
    local st = mem_storage()
    local first = new_ix(root, cfg, st, embedder('sync'))
    T.eq(select(2, reindex(first)), nil)
    local path = first.path
    local good = st.files[path]
    local function damaged_case(bytes, label)
      indexer.reset()
      st.files[path] = bytes
      local writes = #st.writes
      local ix = new_ix(root, cfg, st, embedder('sync'))
      T.ok(
        ix.not_ready ~= nil and ix.not_ready:find('damaged', 1, true),
        label .. ': ' .. tostring(ix.not_ready)
      )
      local ok, err = ix:persist()
      T.eq(ok, nil)
      T.eq(err.kind, 'not-ready')
      T.ok(err.message:find(':NoteRetrieval reindex', 1, true), err.message)
      local result, serr = sync_vault(ix)
      T.eq(result, nil)
      T.eq(serr.kind, 'unreadable') -- the kit cannot tell damaged from being written: "try again"
      T.eq(st.files[path], bytes)
      T.eq(#st.writes, writes)
      return ix
    end
    damaged_case('this is not a container', 'garbage')
    local ix = damaged_case(good:sub(1, math.floor(#good / 2)), 'cut short')
    -- the way out the message names: a reindex replaces the damaged file
    T.eq(select(2, reindex(ix)), nil)
    T.eq(#paths_on_disk(st, ix), 3)
  end)
end)
