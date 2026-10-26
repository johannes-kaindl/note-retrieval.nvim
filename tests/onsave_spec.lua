local T = require('note_retrieval.kit.test')
local indexer = require('note_retrieval.indexer')
local index = require('note_retrieval.index')
local vrix = require('note_retrieval.kit.vrix')
local wait = require('note_retrieval.kit.wait')

local uv = vim.uv or vim.loop

local DIM = 4
local WINDOW = 40

-- A folder with `n` notes; `fn(root, cfg)`. Indexers, saved buffers and options are reset around it.
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
  indexer.SAVE_DEBOUNCE_MS = WINDOW
  local notify = vim.notify
  local ok, err = pcall(fn, root, cfg)
  vim.notify = notify
  vim.g.note_retrieval = nil
  pcall(vim.cmd, 'silent! %bwipeout!')
  indexer.SAVE_DEBOUNCE_MS = 1000
  indexer.reset()
  index.reset()
  vim.fn.delete(base, 'rf')
  assert(ok, err)
end

local function mem_storage()
  local s = { files = {}, writes = {}, ver = {} }
  s.exists = function(p)
    return s.files[p] ~= nil
  end
  s.read = function(p)
    return s.files[p]
  end
  s.write = function(p, bytes)
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

local function embedder(mode)
  local e = { calls = 0 }
  e.fn = function(texts, cb)
    e.calls = e.calls + 1
    local vecs = {}
    for i, t in ipairs(texts) do
      vecs[i] = { 1 + (#t % 5), 2, 3, 4 }
    end
    if mode == 'defer' or mode == 'slow' then
      vim.defer_fn(function()
        cb(vecs)
      end, mode == 'slow' and 150 or 3)
    else
      cb(vecs)
    end
  end
  return e
end

-- An indexer over an in-memory index with the vault indexed once; returns ix, storage, embedder.
local function ready(root, cfg, mode)
  local st, emb = mem_storage(), embedder(mode)
  local ix =
    assert(indexer.for_root(root, { embedder = emb.fn, model = 'm1', dim = DIM, cfg = cfg, storage = st }))
  local _, answered = wait.result(function(done)
    ix:reindex(function(report, err)
      done({ report, err })
    end)
  end, 20000)
  assert(answered, 'the reindex did not finish')
  return ix, st, emb
end

local function write(path, text)
  local f = assert(io.open(path, 'wb'))
  f:write(text)
  f:close()
end

-- A save as a person does it: open the note, change the buffer, :write.
local function save(path, text)
  vim.cmd('silent edit ' .. vim.fn.fnameescape(path))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, '\n'))
  vim.cmd('silent write')
end

local function settle(ms)
  vim.wait(ms, function()
    return false
  end, 5)
end

local function file_stamp(path)
  local st = assert(uv.fs_stat(path))
  return { st.mtime.sec * 1000 + math.floor(st.mtime.nsec / 1e6), st.size }
end

local function stamps_on_disk(st, ix)
  local d = assert(vrix.decode(st.files[ix.path]))
  local map = {}
  for i, p in ipairs(d.paths) do
    map[p] = d.stamps[i]
  end
  return map
end

local function group_autocmds()
  local ok, list = pcall(vim.api.nvim_get_autocmds, { group = 'NoteRetrievalSave' })
  return ok and #list or 0
end

local function make_obsidian(root)
  vim.fn.mkdir(root .. '/.obsidian/plugins/vault-retrieval', 'p')
  write(root .. '/.obsidian/plugins/vault-retrieval/data.json', '{"indexDir":"_idx","exclude":[]}')
  vim.fn.mkdir(root .. '/_idx', 'p')
  write(root .. '/_idx/index.bin', 'obsidian owns these bytes')
end

local function sha(path)
  local f = assert(io.open(path, 'rb'))
  local s = f:read('*a')
  f:close()
  return vim.fn.sha256(s)
end

T.case('on save: one save is one persist, with the stamp of the file after the write', function()
  with_vault(3, function(root, cfg)
    local ix, st = ready(root, cfg)
    local base = writes_to(st, ix.path)
    local path = root .. '/note-001.md'
    save(path, '# Note 1\n\nchanged words, a few more of them than before')
    T.ok(
      vim.wait(2000, function()
        return writes_to(st, ix.path) > base
      end, 5),
      'nothing was written after the save'
    )
    settle(WINDOW * 3)
    T.eq(writes_to(st, ix.path), base + 1)
    -- the stamp is the file's now; without it the row would keep the stamp of the first index run
    T.eq(stamps_on_disk(st, ix)['note-001.md'], file_stamp(path))
    T.eq(indexer.status(root).running, false)
  end)
end)

T.case('on save: ten saves in a burst are one write of the last content', function()
  with_vault(3, function(root, cfg)
    local ix, st, emb = ready(root, cfg)
    local base, calls = writes_to(st, ix.path), emb.calls
    local path = root .. '/note-001.md'
    for i = 1, 10 do
      save(path, '# Note 1\n\n' .. ('x'):rep(i * 7))
      settle(4)
    end
    settle(WINDOW * 4)
    T.eq(writes_to(st, ix.path), base + 1)
    T.eq(emb.calls, calls + 1)
    T.eq(stamps_on_disk(st, ix)['note-001.md'], file_stamp(path))
  end)
end)

T.case('on save: saves of two notes in one window are one persist with both', function()
  with_vault(3, function(root, cfg)
    local ix, st = ready(root, cfg)
    local base = writes_to(st, ix.path)
    save(root .. '/note-001.md', '# Note 1\n\nnew words for the first note, longer than before')
    save(root .. '/note-002.md', '# Note 2\n\nnew words for the second note, also longer than before')
    settle(WINDOW * 4)
    T.eq(writes_to(st, ix.path), base + 1)
    local stamps = stamps_on_disk(st, ix)
    T.eq(stamps['note-001.md'], file_stamp(root .. '/note-001.md'))
    T.eq(stamps['note-002.md'], file_stamp(root .. '/note-002.md'))
  end)
end)

T.case('on save: a vault of the Obsidian plugin gets no autocmd and no write', function()
  with_vault(2, function(root, cfg)
    make_obsidian(root)
    local emb = embedder()
    index.load(root, cfg) -- resolves the mode, as every first use does
    T.eq((indexer.for_root(root, { embedder = emb.fn, model = 'm1', dim = DIM, cfg = cfg })), nil)
    T.eq(group_autocmds(), 0)
    local before = sha(root .. '/_idx/index.bin')
    save(root .. '/note-001.md', '# Note 1\n\nsaved in a vault the Obsidian plugin owns')
    settle(WINDOW * 4)
    T.eq(sha(root .. '/_idx/index.bin'), before)
    T.eq(emb.calls, 0)
  end)
end)

T.case("on save: a vault that became the Obsidian plugin's is dropped at the next save", function()
  with_vault(2, function(root, cfg)
    local ix, st, emb = ready(root, cfg)
    T.eq(group_autocmds(), 1)
    local base, calls = writes_to(st, ix.path), emb.calls
    make_obsidian(root)
    save(root .. '/note-001.md', '# Note 1\n\nthe mode changed under the session')
    settle(WINDOW * 4)
    T.eq(group_autocmds(), 0)
    T.eq(emb.calls, calls)
    T.eq(writes_to(st, ix.path), base)
  end)
end)

T.case('on save: index_on_save = false updates nothing', function()
  with_vault(2, function(root, cfg)
    local ix, st, emb = ready(root, cfg)
    local base, calls = writes_to(st, ix.path), emb.calls
    vim.g.note_retrieval = { index_on_save = false }
    save(root .. '/note-001.md', '# Note 1\n\nsaved with the option off')
    settle(WINDOW * 4)
    T.eq(writes_to(st, ix.path), base)
    T.eq(emb.calls, calls)
  end)
end)

T.case('on save: a save without an indexer in the session only hints, once', function()
  with_vault(2, function(root, cfg)
    local seen = {}
    vim.notify = function(msg, level)
      seen[#seen + 1] = { msg, level }
    end
    index.load(root, cfg) -- an own-index vault: the saves are heard, but no model is chosen
    save(root .. '/note-001.md', '# Note 1\n\nfirst save')
    save(root .. '/note-001.md', '# Note 1\n\nsecond save')
    settle(WINDOW * 3)
    T.eq(#seen, 1)
    T.ok(seen[1][1]:find(':NoteRetrieval update', 1, true), seen[1][1])
    T.eq(seen[1][2], vim.log.levels.INFO)
  end)
end)

T.case(
  'on save: the index changed by a second device is adopted into the same indexer, foreign stamps kept',
  function()
    with_vault(3, function(root, cfg)
      local st, emb = mem_storage(), embedder()
      local function make()
        return assert(
          indexer.for_root(root, { embedder = emb.fn, model = 'm1', dim = DIM, cfg = cfg, storage = st })
        )
      end
      local other = make()
      wait.result(function(done)
        other:reindex(function()
          done(true)
        end)
      end, 20000)
      indexer.reset()
      local ix = make() -- this device: starts from the index on disk
      local live = ix.live
      -- the second device re-embeds note-002 and stamps it
      wait.result(function(done)
        other.live:update('note-002.md', '# Note 2\n\nwritten on the other machine', { 111, 22 }, done)
      end, 5000)
      T.eq(select(1, other:persist('live')), true)
      local base = writes_to(st, ix.path)
      save(root .. '/note-001.md', '# Note 1\n\nsaved here, longer than it was before')
      settle(WINDOW * 4)
      T.eq(writes_to(st, ix.path), base + 1)
      T.ok(ix.live == live, 'the kit indexer was replaced')
      local stamps = stamps_on_disk(st, ix)
      T.eq(stamps['note-002.md'], { 111, 22 })
      T.eq(stamps['note-001.md'], file_stamp(root .. '/note-001.md'))
    end)
  end
)

T.case('on save: a save during a reindex waits until it ends', function()
  with_vault(70, function(root, cfg)
    local st, emb = mem_storage(), embedder('slow')
    local ix =
      assert(indexer.for_root(root, { embedder = emb.fn, model = 'm1', dim = DIM, cfg = cfg, storage = st }))
    local finished = false
    ix:reindex(function()
      finished = true
    end)
    T.ok(ix.run.running, 'the reindex did not start')
    local path = root .. '/note-001.md'
    save(path, '# Note 1\n\nsaved while the reindex runs, and long enough to change the size')
    settle(WINDOW * 2)
    T.ok(ix.run.running and ix.run.kind == 'reindex', 'the reindex ended too early for this case')
    T.eq(finished, false)
    T.ok(vim.wait(20000, function()
      return finished
    end, 5))
    local after_reindex = writes_to(st, ix.path)
    T.ok(
      vim.wait(3000, function()
        return writes_to(st, ix.path) > after_reindex
      end, 5),
      'the queued save was never written'
    )
    T.eq(stamps_on_disk(st, ix)['note-001.md'], file_stamp(path))
  end)
end)

T.case('on save: a changed index file is retried once, then reported once', function()
  with_vault(2, function(root, cfg)
    local ix, st, emb = ready(root, cfg)
    local base, calls = writes_to(st, ix.path), emb.calls
    local tick = 0
    st.stat = function()
      tick = tick + 1 -- another Neovim writes all the time
      return { size = 0, v = tick }
    end
    local warnings = {}
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        warnings[#warnings + 1] = msg
      end
    end
    save(root .. '/note-001.md', '# Note 1\n\nsaved while another machine writes')
    settle(WINDOW * 4)
    T.eq(emb.calls, calls + 2) -- the sequence ran twice, not more
    T.eq(#warnings, 1)
    T.ok(warnings[1]:find('changed on disk', 1, true), warnings[1])
    T.eq(writes_to(st, ix.path), base)
    save(root .. '/note-002.md', '# Note 2\n\nand another save')
    settle(WINDOW * 4)
    T.eq(#warnings, 1) -- shown once until the next success
    T.eq(indexer.status(root).running, false)
  end)
end)

T.case('flush_saves: writes the waiting batch at once, then calls back', function()
  with_vault(2, function(root, cfg)
    local ix, st = ready(root, cfg)
    indexer.SAVE_DEBOUNCE_MS = 60000
    local base = writes_to(st, ix.path)
    save(root .. '/note-001.md', '# Note 1\n\nsaved, and a window of a minute')
    T.eq(writes_to(st, ix.path), base)
    local at_callback
    indexer.flush_saves(root, function()
      at_callback = writes_to(st, ix.path)
    end)
    T.eq(at_callback, base + 1)
    -- nothing waiting: the callback comes at once
    local again = false
    indexer.flush_saves(root, function()
      again = true
    end)
    T.eq(again, true)
  end)
end)

T.case(':NoteRetrieval update starts by flushing the saved notes', function()
  with_vault(2, function(root, cfg)
    -- the index must exist on disk for the command to find the vault
    local ix =
      assert(indexer.for_root(root, { embedder = embedder().fn, model = 'm1', dim = DIM, cfg = cfg }))
    wait.result(function(done)
      ix:reindex(function()
        done(true)
      end)
    end, 20000)
    vim.g.note_retrieval = { roots = { root } }
    local original = indexer.flush_saves
    local asked
    indexer.flush_saves = function(r)
      asked = r
    end
    local ok, err = pcall(function()
      vim.cmd('silent edit ' .. vim.fn.fnameescape(root .. '/note-001.md'))
      require('note_retrieval.command').update()
    end)
    indexer.flush_saves = original
    assert(ok, err)
    T.eq(asked, root)
  end)
end)

T.case('real file system: a save is written to the index file and read back', function()
  with_vault(3, function(root, cfg)
    local emb = embedder()
    local ix = assert(indexer.for_root(root, { embedder = emb.fn, model = 'm1', dim = DIM, cfg = cfg }))
    wait.result(function(done)
      ix:reindex(function()
        done(true)
      end)
    end, 20000)
    local path = root .. '/note-002.md'
    local before = assert(index.load(root, cfg)).stamps
    save(path, '# Note 2\n\nreal files, a real save, and some more words than before')
    T.ok(
      vim.wait(3000, function()
        local loaded = index.load(root, cfg)
        return loaded and not vim.deep_equal(loaded.stamps, before)
      end, 10),
      'the index file did not change'
    )
    local loaded = assert(index.load(root, cfg))
    local at
    for i, p in ipairs(loaded.paths) do
      if p == 'note-002.md' then
        at = i
      end
    end
    T.eq(loaded.stamps[at], file_stamp(path))
    T.eq(uv.fs_stat(ix.files.lock), nil)
  end, { index_dir = '_nr' })
end)
