local T = require('note_retrieval.kit.test')
local V = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/vault.lua')
local command = require('note_retrieval.command')
local roots = require('note_retrieval.roots')
local state = require('note_retrieval.state')

-- Runs fn with vim.notify recorded and vim.ui.input / vim.ui.select answered from `ui`:
-- ui.answer is what input returns, ui.pick the item number select returns (nil: dismissed).
local function with_ui(ui, fn)
  local saved = { vim.notify, vim.ui.input, vim.ui.select }
  local seen = { notes = {}, prompts = {}, items = {} }
  vim.notify = function(msg, level)
    seen.notes[#seen.notes + 1] = msg
    seen.levels = seen.levels or {}
    seen.levels[#seen.notes] = level
  end
  vim.ui.input = function(o, cb)
    seen.prompts[#seen.prompts + 1] = o.prompt
    cb(ui.answer)
  end
  vim.ui.select = function(items, o, cb)
    seen.items[#seen.items + 1] = { items = items, prompt = o.prompt, format = o.format_item }
    cb(ui.pick and items[ui.pick] or nil)
  end
  local ok, err = pcall(fn, seen)
  vim.notify, vim.ui.input, vim.ui.select = unpack(saved)
  assert(ok, err)
end

-- Waits until the recorded notes or select calls show an answer.
local function settle(seen, what)
  T.ok(
    vim.wait(5000, function()
      return #seen[what or 'notes'] > 0
    end, 5),
    'no ' .. (what or 'notes')
  )
end

local function run(args)
  vim.cmd('NoteRetrieval ' .. args)
end

T.case('the command is defined by the plugin file and by nothing else', function()
  vim.cmd('runtime plugin/note_retrieval.lua')
  T.ok(vim.api.nvim_get_commands({}).NoteRetrieval, 'no :NoteRetrieval')
end)

T.case('complete: the subcommands only, and only in the first place', function()
  T.eq(
    command.complete('', 'NoteRetrieval '),
    { 'model', 'probe', 'reindex', 'related', 'reset', 'search', 'status', 'stop', 'update' }
  )
  T.eq(command.complete('re', 'NoteRetrieval re'), { 'reindex', 'related', 'reset' })
  T.eq(command.complete('st', 'NoteRetrieval st'), { 'status', 'stop' })
  T.eq(command.complete('x', 'NoteRetrieval search x'), {})
  T.eq(command.complete('re', 'NoteRetrieval search re'), {})
  T.eq(command.complete('', 'NoteRetrieval probe '), { '--json' })
  T.eq(command.complete('--j', 'NoteRetrieval probe 5 --j'), { '--json' })
  T.eq(command.complete('x', 'NoteRetrieval probe x'), {})
end)

T.case('an unknown subcommand and none at all are said in words', function()
  with_ui({}, function(seen)
    run('bogus')
    run('')
    T.ok(seen.notes[1]:find('unknown subcommand "bogus"', 1, true), seen.notes[1])
    T.ok(
      seen.notes[1]:find('model, probe, reindex, related, reset, search, status, stop, update', 1, true),
      seen.notes[1]
    )
    T.ok(seen.notes[2]:find('a subcommand is needed', 1, true), seen.notes[2])
    T.eq(seen.levels[1], vim.log.levels.ERROR)
  end)
end)

T.case('status: root, mode, notes, model, age, endpoint of the vault of the current note', function()
  V.with_vault(function(root)
    vim.g.note_retrieval = { endpoints = V.endpoint('http://127.0.0.1:9') }
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    with_ui({}, function(seen)
      run('status')
      local text = seen.notes[1]
      for _, want in ipairs({
        'root:      ' .. root,
        'mode:      obsidian',
        'notes:     3',
        'model:     test-model (the index header)',
        'built:     2026-10-20T00:00:00.000Z (',
        'days ago)',
        'endpoint:  http://127.0.0.1:9',
        ':NoteRetrieval reset',
      }) do
        T.ok(text:find(want, 1, true), ('%q is not in:\n%s'):format(want, text))
      end
      T.ok(not text:find('warning:', 1, true), text)
    end)
  end)
end)

T.case('status: a torn index file is shown as a warning, the old index still answers', function()
  V.with_vault(function(root)
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    with_ui({}, function(seen)
      run('status')
      V.put(root .. '/_vaultrag/index.bin', V.index_bytes(V.ROWS):sub(1, 40))
      run('status')
      T.ok(seen.notes[2]:find('notes:     3', 1, true), seen.notes[2])
      T.ok(
        seen.notes[2]:find('warning: ', 1, true)
          and seen.notes[2]:find('using the index loaded earlier', 1, true),
        seen.notes[2]
      )
    end)
  end)
end)

T.case('status: without a vault the roots sentence, without an index the reason', function()
  V.without_vault(function()
    with_ui({}, function(seen)
      run('status')
      T.ok(seen.notes[1]:find(roots.NO_ROOT, 1, true), seen.notes[1])
    end)
  end)
  V.with_vault(function(root)
    os.remove(root .. '/_vaultrag/index.bin')
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    with_ui({}, function(seen)
      run('status')
      T.ok(seen.notes[1]:find('mode:', 1, true) == nil, seen.notes[1])
      T.ok(
        seen.notes[1]:find('no index file at', 1, true) or seen.notes[1]:find('mode', 1, true) == nil,
        seen.notes[1]
      )
    end)
  end)
end)

T.case('reset: the vault settings read once are read again', function()
  V.with_vault(function(root)
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    with_ui({}, function(seen)
      run('status')
      T.ok(seen.notes[1]:find('mode:      obsidian', 1, true), seen.notes[1])
      V.put(root .. '/.obsidian/plugins/vault-retrieval/data.json', '{"indexDir":"elsewhere"}')
      run('status')
      T.ok(seen.notes[2]:find('mode:      obsidian', 1, true), 'cached per session: ' .. seen.notes[2])
      run('reset')
      run('status')
      T.ok(seen.notes[4]:find('mode:      eigen', 1, true) == nil, seen.notes[4]) -- no index there: no mode line
      T.ok(seen.notes[4]:find('is missing', 1, true), seen.notes[4])
    end)
  end)
end)

T.case('related: opens the panel on the right and closes it again', function()
  V.with_vault(function(root)
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    local panel = require('note_retrieval.panel')
    run('related')
    T.ok(vim.fn.bufwinnr(panel.NAME) > 0, 'panel not open')
    run('related')
    T.eq(vim.fn.bufwinnr(panel.NAME), -1)
  end)
end)

T.case('search: the query goes to the server once, the picked note opens', function()
  local srv = V.server({ V.MODEL }, { 1, 0, 0, 0 })
  V.with_vault(function(root)
    vim.g.note_retrieval = { endpoints = V.endpoint(srv.url), min_similarity = 0 }
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/c.md'))
    with_ui({ pick = 1 }, function(seen)
      run('search how are  things')
      settle(seen, 'items')
      T.eq(seen.items[1].items[1].path, 'a.md') -- the vector (1,0,0,0) is a.md's
      T.eq(#seen.items[1].items, 3) -- unlike related, search leaves no note out
      vim.wait(2000, function()
        return vim.fn.expand('%:t') == 'a.md'
      end, 5)
      T.eq(vim.fn.expand('%:t'), 'a.md')
    end)
  end)
  local embeds = vim.tbl_filter(function(r)
    return r.path == '/v1/embeddings'
  end, srv.requests)
  srv.close()
  T.eq(#embeds, 1)
  T.eq(vim.json.decode(embeds[1].body).input, { 'how are  things' }) -- the blanks are the person's
end)

T.case('search: without a query it asks; an empty answer does nothing', function()
  V.with_vault(function(root)
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    with_ui({ answer = '  ' }, function(seen)
      run('search')
      T.eq(seen.prompts, { 'Search notes: ' })
      T.eq({ #seen.notes, #seen.items }, { 0, 0 })
    end)
  end)
end)

T.case('search: no server answering is a sentence with the next step', function()
  V.with_vault(function(root)
    vim.g.note_retrieval = { endpoints = V.endpoint(V.dead_url()), timeout_ms = 2000 }
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    with_ui({}, function(seen)
      run('search anything')
      settle(seen)
      T.ok(seen.notes[1]:find('^note%-retrieval: No embedding server answered%. Start Ollama'), seen.notes[1])
      T.eq(seen.levels[1], vim.log.levels.ERROR)
    end)
  end)
end)

T.case('search: an index of another model turns search off in words, related still works', function()
  local srv = V.server({ 'other-model' })
  V.with_vault(function(root)
    vim.g.note_retrieval = { endpoints = V.endpoint(srv.url) }
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    with_ui({}, function(seen)
      run('search anything')
      settle(seen)
      local text = seen.notes[1]
      for _, want in ipairs({ 'Search is off', '"test-model"', '"other-model"', 'Related notes still work' }) do
        T.ok(text:find(want, 1, true), ('%q is not in %q'):format(want, text))
      end
      T.ok(
        require('note_retrieval').related('a.md', { root = root, min_similarity = 0 }),
        'related stopped working'
      )
    end)
  end)
  srv.close()
end)

T.case('search: no vault says how to set roots', function()
  V.without_vault(function()
    with_ui({}, function(seen)
      run('search anything')
      T.eq(seen.notes, { 'note-retrieval: ' .. roots.NO_ROOT })
    end)
  end)
end)

T.case('search in Visual mode: the selected lines are the query', function()
  local srv = V.server({ V.MODEL })
  V.with_vault(function(root)
    vim.g.note_retrieval = { endpoints = V.endpoint(srv.url) }
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'first line', 'second line', 'third' })
    vim.cmd('runtime plugin/note_retrieval.lua')
    with_ui({}, function(seen)
      vim.cmd(
        [[execute "normal! ggVj\<Cmd>lua vim.fn.maparg('<Plug>(note-retrieval-search)', 'x', false, true).callback()\<CR>"]]
      )
      settle(seen, 'items')
      T.eq(vim.fn.mode(), 'n')
    end)
  end)
  local embeds = vim.tbl_filter(function(r)
    return r.path == '/v1/embeddings'
  end, srv.requests)
  srv.close()
  T.eq(vim.json.decode(embeds[1].body).input, { 'first line\nsecond line' })
end)

T.case(
  'model: the pick is remembered for the server and said, with the index model in obsidian mode',
  function()
    local srv = V.server({ 'm1', V.MODEL })
    V.with_vault(function(root)
      vim.g.note_retrieval = { endpoints = V.endpoint(srv.url) }
      vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
      with_ui({ pick = 1 }, function(seen)
        run('model')
        settle(seen)
        T.eq(seen.items[1].items, { 'm1', V.MODEL })
        T.eq(state.model(srv.url), 'm1')
        T.ok(seen.notes[1]:find('model on ' .. srv.url .. ': m1', 1, true), seen.notes[1])
        T.ok(
          seen.notes[1]:find('built with "test-model", and a search uses that one', 1, true),
          seen.notes[1]
        )
      end)
    end)
    srv.close()
  end
)

T.case(
  'model: the prompt names the server, and a pick that cannot be remembered still counts and says why',
  function()
    local srv = V.server({ 'm1', V.MODEL })
    V.with_vault(function(root)
      vim.g.note_retrieval = { endpoints = V.endpoint(srv.url) }
      vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
      local original = state.set_model
      state.set_model = function()
        error('state dir not writable')
      end
      local ok, err = pcall(function()
        with_ui({ pick = 1 }, function(seen)
          run('model')
          settle(seen)
          T.eq(#seen.items, 1)
          T.eq(seen.items[1].prompt, 'note-retrieval: model on ' .. srv.url)
          T.eq(#seen.notes, 1)
          T.ok(seen.notes[1]:find('model on ' .. srv.url .. ': m1', 1, true), seen.notes[1])
          T.ok(seen.notes[1]:find(' — but it could not be remembered: ', 1, true), seen.notes[1])
          T.ok(seen.notes[1]:find('state dir not writable', 1, true), seen.notes[1])
        end)
      end)
      state.set_model = original
      assert(ok, err)
      T.eq(state.model(srv.url), nil) -- the write was refused, nothing was stored
    end)
    srv.close()
  end
)

T.case('model: dismissing the list remembers nothing; no server is a sentence', function()
  local srv = V.server({ 'only-a', 'only-b' })
  V.with_vault(function()
    vim.g.note_retrieval = { endpoints = V.endpoint(srv.url) }
    with_ui({ pick = nil }, function(seen)
      run('model')
      settle(seen, 'items')
      T.eq(state.model(srv.url), nil)
      T.eq(#seen.notes, 0)
    end)
    vim.g.note_retrieval = { endpoints = V.endpoint(V.dead_url()) }
    with_ui({}, function(seen)
      run('model')
      settle(seen)
      T.ok(seen.notes[1]:find('No embedding server answered', 1, true), seen.notes[1])
    end)
  end)
  srv.close()
end)

T.case('option problems are shown once, not on every command', function()
  V.with_vault(function(root)
    vim.g.note_retrieval = { k = 0 }
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    with_ui({}, function(seen)
      run('status')
      run('status')
      local problems = vim.tbl_filter(function(m)
        return m:find('k: must be', 1, true)
      end, seen.notes)
      T.eq(#problems, 1)
    end)
  end)
end)

T.case('API: related and search take the vault of the current note, not of the working directory', function()
  local api = require('note_retrieval')
  local srv = V.server({ V.MODEL }, { 1, 0, 0, 0 })
  V.with_vault(function(root)
    vim.g.note_retrieval = { endpoints = V.endpoint(srv.url), min_similarity = 0 }
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    vim.cmd.cd('/')
    local near = assert(api.related('a.md', { k = 1 }))
    T.eq(near[1].path, 'b.md')
    local got
    api.search('anything', { k = 2 }, function(...)
      got = { ... }
    end)
    T.ok(
      vim.wait(5000, function()
        return got ~= nil
      end, 5),
      'no answer'
    )
    T.eq({ got[1][1].path, #got[1] }, { 'a.md', 2 })
    T.eq(api.status().rows, 3)
  end)
  srv.close()
end)

-- ---------------------------------------------------------------------------------------------
-- reindex, stop, status (the own index writer)

local embedder_lib = require('note_retrieval.embedder')
local indexer = require('note_retrieval.indexer')
local index = require('note_retrieval.index')
local lock = require('note_retrieval.kit.lock')
local vrix = require('note_retrieval.kit.vrix')

-- An embedding source double for `embedder.for_indexer`: answers on the main loop `delay` ms later;
-- `die_after` calls it answers an error instead (a server that went away).
local function double(opts)
  opts = opts or {}
  local d = { calls = 0 }
  d.fn = function(texts, cb)
    d.calls = d.calls + 1
    local n = d.calls
    vim.defer_fn(function()
      if opts.die_after and n > opts.die_after then
        return cb(nil, 'unreachable: the server went away')
      end
      local vecs = {}
      for i, t in ipairs(texts) do
        vecs[i] = { 1 + (#t % 5), 2, 3, 4 }
      end
      cb(vecs)
    end, opts.delay or 1)
  end
  return d
end

-- `fn(root, d)` with an own-index vault (no Obsidian plugin folder; the index lives in _idx of the
-- vault, the lock and backup in a temporary state folder), `extra` notes, `embedder.resolve` and
-- `embedder.for_indexer` replaced so that `:NoteRetrieval reindex` talks to the double `d`.
local function with_eigen(extra, dbl, fn)
  V.with_vault(function(root)
    vim.fn.delete(root .. '/.obsidian/plugins', 'rf')
    vim.fn.delete(root .. '/_vaultrag', 'rf')
    for i = 1, extra do
      V.put(('%s/n%03d.md'):format(root, i), ('# Note %d\n\nwords about note %d'):format(i, i))
    end
    local state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = root .. '/_state'
    vim.g.note_retrieval = { index_dir = '_idx' }
    indexer.reset()
    local saved = { embedder_lib.resolve, embedder_lib.for_indexer }
    embedder_lib.resolve = function(_, _, cb)
      cb({ endpoint = { url = 'http://double' }, model = 'm1', dim = 4, timeout_ms = 1000 })
    end
    embedder_lib.for_indexer = function()
      return dbl.fn
    end
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    local ok, err = pcall(fn, root)
    embedder_lib.resolve, embedder_lib.for_indexer = saved[1], saved[2]
    for _ = 1, 400 do
      if not indexer.status(root).running then
        break
      end
      indexer.stop(root)
      vim.wait(5)
    end
    indexer.reset()
    vim.env.XDG_STATE_HOME = state_home
    assert(ok, err)
  end)
end

-- The bytes of a file (compared as they are: `vim.fn.sha256` of a string with NUL fails on Neovim 0.10).
local function sha_of(path)
  local f = assert(io.open(path, 'rb'))
  local s = f:read('*a')
  f:close()
  return s
end

-- Waits until the notes recorded hold one with `part`.
local function wait_note(seen, part)
  T.ok(
    vim.wait(10000, function()
      for _, n in ipairs(seen.notes) do
        if n:find(part, 1, true) then
          return true
        end
      end
    end, 5),
    ('no note with %q in %s'):format(part, vim.inspect(seen.notes))
  )
end

local function note_with(seen, part)
  for i, n in ipairs(seen.notes) do
    if n:find(part, 1, true) then
      return n, seen.levels[i]
    end
  end
end

T.case('reindex in mode obsidian: a sentence, the index of Obsidian untouched, no indexer made', function()
  V.with_vault(function(root)
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    local before = sha_of(root .. '/_vaultrag/index.bin')
    with_ui({}, function(seen)
      run('reindex')
      T.ok(seen.notes[1]:find('read only here: Obsidian owns the index', 1, true), seen.notes[1])
      T.eq(seen.levels[1], vim.log.levels.INFO)
      T.eq(#seen.notes, 1)
    end)
    T.eq(sha_of(root .. '/_vaultrag/index.bin'), before)
    T.eq(indexer.status(root).indexer, false)
  end)
end)

T.case('reindex in mode eigen: runs in the background, says how many notes it indexed', function()
  local dbl = double()
  with_eigen(2, dbl, function(root)
    with_ui({}, function(seen)
      run('reindex')
      T.ok(seen.notes[1]:find('reindexing ' .. root .. ' with the model m1', 1, true), seen.notes[1])
      wait_note(seen, 'notes indexed in')
      -- a.md, b.md, c.md of the fixture and the two added notes
      T.ok(note_with(seen, '5 notes indexed in ' .. root), vim.inspect(seen.notes))
      local _, level = note_with(seen, 'notes indexed in')
      T.eq(level, vim.log.levels.INFO)
    end)
    local d = assert(vrix.decode(assert(io.open(root .. '/_idx/index.bin', 'rb')):read('*a')))
    T.eq(#d.paths, 5)
    T.ok(dbl.calls > 0, 'the embedder double was not used')
  end)
end)

T.case('reindex: the command returns at once, Neovim stays responsive during the run', function()
  local dbl = double({ delay = 15 })
  with_eigen(30, dbl, function(root)
    with_ui({}, function(seen)
      run('reindex')
      T.ok(indexer.status(root).running, 'the run did not go to the background')
      local ticks, timer = 0, vim.uv.new_timer()
      timer:start(0, 5, function()
        ticks = ticks + 1
      end)
      wait_note(seen, 'notes indexed in')
      timer:close()
      T.ok(ticks >= 3, 'the main loop was blocked: ' .. ticks .. ' ticks')
    end)
  end)
end)

T.case('stop during a run: the run ends early, what it reached is written, the rest stays', function()
  local dbl = double({ delay = 15 })
  with_eigen(200, dbl, function(root)
    with_ui({}, function(seen)
      run('stop') -- nothing runs yet
      T.ok(seen.notes[1]:find('no reindex is running in ' .. root, 1, true), seen.notes[1])
      run('reindex')
      T.ok(
        vim.wait(5000, function()
          return indexer.status(root).done > 0
        end, 5),
        'the run made no progress'
      )
      run('stop')
      T.ok(note_with(seen, 'stopping the reindex of ' .. root), vim.inspect(seen.notes))
      wait_note(seen, 'stopped:')
      local text = assert(note_with(seen, 'stopped:'))
      T.ok(text:find('the rest of the index is as it was', 1, true), text)
      T.ok(indexer.status(root).done < 203, 'the run was not cut short')
      T.eq(indexer.status(root).running, false)
    end)
  end)
end)

T.case('stop during an update: says the update runs and cannot be stopped, the update still ends', function()
  local dbl = double({ delay = 15 })
  with_eigen(200, dbl, function(root)
    with_ui({}, function(seen)
      run('update')
      T.ok(
        vim.wait(5000, function()
          return indexer.status(root).running and indexer.status(root).done > 0
        end, 5),
        'the update made no progress'
      )
      T.eq(indexer.status(root).kind, 'sync')
      run('stop')
      local text = assert(note_with(seen, 'cannot be stopped'), vim.inspect(seen.notes))
      T.ok(text:find('an update of ' .. root .. ' is running', 1, true), text)
      T.eq(note_with(seen, 'no reindex is running'), nil)
      T.ok(
        vim.wait(30000, function()
          return not indexer.status(root).running
        end, 5),
        'the update did not end'
      )
    end)
  end)
end)

T.case('reindex: a second one while one runs is refused in words', function()
  local dbl = double({ delay = 15 })
  with_eigen(30, dbl, function()
    with_ui({}, function(seen)
      run('reindex')
      run('reindex')
      local text, level = note_with(seen, 'already running')
      T.ok(text, vim.inspect(seen.notes))
      T.eq(level, vim.log.levels.WARN)
      T.eq(dbl.calls <= 3, true)
      wait_note(seen, 'notes indexed in')
    end)
  end)
end)

T.case('reindex: refusals of the writer are the plain sentences, at the right level', function()
  local dbl = double()
  with_eigen(0, dbl, function(root)
    -- locked by another process
    local ix = assert(indexer.for_root(root, { embedder = dbl.fn, model = 'm1', dim = 4 }))
    local other = assert(lock.acquire(ix.files.lock))
    with_ui({}, function(seen)
      run('reindex')
      wait_note(seen, 'lock')
      local text, level = note_with(seen, 'lock')
      T.ok(text:find('note-retrieval: ', 1, true) == 1, text)
      T.eq(level, vim.log.levels.WARN)
    end)
    other.release()
    -- no notes at all: the index stays as it is
    for _, name in ipairs({ 'a.md', 'b.md', 'c.md' }) do
      os.remove(root .. '/' .. name)
    end
    with_ui({}, function(seen)
      run('reindex')
      wait_note(seen, 'no Markdown notes')
      T.eq(select(2, note_with(seen, 'no Markdown notes')), vim.log.levels.WARN)
    end)
    T.eq(vim.uv.fs_stat(root .. '/_idx/index.bin'), nil)
  end)
end)

T.case('reindex: a server that dies mid-run leaves the failed count in the report and in status', function()
  local dbl = double({ die_after = 1 })
  with_eigen(70, dbl, function(root)
    with_ui({}, function(seen)
      run('reindex')
      wait_note(seen, 'could not be embedded')
      local text, level = note_with(seen, 'could not be embedded')
      T.ok(text:find('missing from the index', 1, true), text)
      T.eq(level, vim.log.levels.WARN)
      local failed = #indexer.status(root).report.failed
      T.ok(failed > 0, 'no failed notes')
      run('status')
      local status = seen.notes[#seen.notes]
      T.ok(
        status:find(
          ('last run:  %d embedded, %d failed'):format(indexer.status(root).report.added, failed),
          1,
          true
        ),
        status
      )
      T.ok(status:find('failed:', 1, true), status)
      -- counter: this run was written (the index holds its notes), so it is not marked
      T.ok(status:find('not written', 1, true) == nil, status)
    end)
  end)
end)

T.case('reindex: a run that embedded nothing writes nothing and is an error', function()
  local dbl = double({ die_after = 0 })
  with_eigen(3, dbl, function(root)
    with_ui({}, function(seen)
      run('reindex')
      wait_note(seen, 'could not be embedded')
      local text, level = note_with(seen, 'could not be embedded')
      T.ok(text:find('the index on disk was not replaced', 1, true), text)
      T.eq(level, vim.log.levels.ERROR)
      T.eq(vim.uv.fs_stat(root .. '/_idx/index.bin'), nil)
      -- status must not read like a success: nothing of this run is on disk
      run('status')
      local status = seen.notes[#seen.notes]
      T.ok(status:match('last run:  0 embedded, %d+ failed %(not written%)'), status)
      T.ok(status:find('error:', 1, true), status)
      T.ok(status:find('missing from the index', 1, true) == nil, status) -- nothing was lost: the run changed nothing
    end)
  end)
end)

T.case('status: progress of a running reindex, then the result', function()
  local dbl = double({ delay = 15 })
  with_eigen(30, dbl, function(root)
    with_ui({}, function(seen)
      run('status') -- no indexer yet: no reindex rows
      T.ok(seen.notes[1]:find('reindex:', 1, true) == nil, seen.notes[1])
      run('reindex')
      T.ok(
        vim.wait(5000, function()
          return indexer.status(root).done > 0
        end, 5),
        'the run made no progress'
      )
      run('status')
      local text = seen.notes[#seen.notes]
      T.ok(text:match('reindex:%s+running %d+/33 notes %(started'), text)
      wait_note(seen, 'notes indexed in')
      run('status')
      text = seen.notes[#seen.notes]
      T.ok(text:match('reindex:%s+not running'), text)
      T.ok(text:find('last run:  33 embedded, 0 failed', 1, true), text)
      T.ok(text:find('failed:', 1, true) == nil, text)
      T.ok(text:find('lock:', 1, true) == nil, text)
    end)
  end)
end)

T.case('status: the lock of another Neovim and the last error of a refused write', function()
  local dbl = double()
  with_eigen(1, dbl, function(root)
    local ix = assert(indexer.for_root(root, { embedder = dbl.fn, model = 'm1', dim = 4 }))
    local other = assert(lock.acquire(ix.files.lock))
    with_ui({}, function(seen)
      run('reindex')
      wait_note(seen, 'lock')
      run('status')
      local text = seen.notes[#seen.notes]
      T.ok(text:match('lock:%s+held by another Neovim for %d+ s'), text)
      T.ok(text:match('error:%s+another Neovim holds the lock on this index'), text)
      other.release()
      run('status')
      text = seen.notes[#seen.notes]
      T.ok(text:find('lock:', 1, true) == nil, text) -- counter: free again, no row
    end)
  end)
end)

T.case('status: a vault in mode obsidian shows no writer rows', function()
  V.with_vault(function(root)
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    with_ui({}, function(seen)
      run('status')
      for _, label in ipairs({ 'reindex:', 'lock:', 'last run:' }) do
        T.ok(seen.notes[1]:find(label, 1, true) == nil, seen.notes[1])
      end
    end)
  end)
end)

-- ---------------------------------------------------------------------------------------------
-- fixes of the review of block A

local status = require('note_retrieval.status')

local function folder_vault(name, note)
  local dir = vim.uv.fs_realpath(vim.fn.tempname() .. '') or vim.fn.tempname()
  vim.fn.mkdir(dir .. '/' .. name .. '/.zk', 'p')
  V.put(dir .. '/' .. name .. '/' .. note, '# ' .. note)
  return vim.uv.fs_realpath(dir .. '/' .. name), dir
end

T.case(
  'current_root: only the panel and the health page take the vault of the buffer you came from',
  function()
    local a, base_a = folder_vault('vault-a', 'x.md')
    local b, base_b = folder_vault('vault-b', 'y.md')
    local cwd = vim.fn.getcwd()
    vim.cmd.cd(vim.fn.fnameescape(b))
    vim.cmd('edit ' .. vim.fn.fnameescape(a .. '/x.md'))
    T.eq(status.current_root({}), a) -- a note: its own vault
    -- a plain scratch buffer (a terminal, a prompt): `#` is a note of vault a, the working directory is vault b
    vim.cmd('enew')
    vim.bo.buftype = 'nofile'
    T.eq(vim.fn.bufnr('#') > 0, true)
    T.eq(status.current_root({}), b)
    -- the panel's buffer and the health page: the vault of the buffer you came from
    for _, ft in ipairs({ 'note-retrieval', 'checkhealth' }) do
      vim.cmd('edit ' .. vim.fn.fnameescape(a .. '/x.md'))
      vim.cmd('enew')
      vim.bo.buftype = 'nofile'
      vim.bo.filetype = ft
      T.eq(status.current_root({}), a)
    end
    vim.cmd('enew')
    vim.cmd('silent! %bwipeout!')
    vim.cmd.cd(vim.fn.fnameescape(cwd))
    vim.fn.delete(base_a, 'rf')
    vim.fn.delete(base_b, 'rf')
  end
)

T.case('search: the query is taken as typed, blanks and backslashes kept', function()
  local srv = V.server({ V.MODEL })
  V.with_vault(function(root)
    vim.g.note_retrieval = { endpoints = V.endpoint(srv.url) }
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    with_ui({ pick = 1 }, function(seen)
      run([[search  a  b\c \d  ]])
      settle(seen, 'items')
    end)
  end)
  local embeds = vim.tbl_filter(function(r)
    return r.path == '/v1/embeddings'
  end, srv.requests)
  srv.close()
  T.eq(vim.json.decode(embeds[1].body).input, { [[a  b\c \d]] })
end)

T.case('model: per endpoint, the endpoint is asked first, the choice is kept for that endpoint', function()
  local one = V.server({ 'a1', 'a2' })
  local two = V.server({ 'b1', 'b2' })
  V.with_vault(function(root)
    vim.g.note_retrieval =
      { endpoints = { { url = one.url, backend = 'unknown' }, { url = two.url, backend = 'unknown' } } }
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    with_ui({ pick = 2 }, function(seen)
      run('model')
      settle(seen)
      T.eq(#seen.items, 2)
      T.ok(seen.items[1].prompt:find('which endpoint', 1, true), seen.items[1].prompt)
      T.eq(vim.tbl_map(seen.items[1].format, seen.items[1].items), {
        one.url .. ' (used first)',
        two.url,
      })
      T.eq(seen.items[2].items, { 'b1', 'b2' }) -- the models of the endpoint picked, not of the first
      T.eq(state.model(two.url), 'b2')
      T.eq(state.model(one.url), nil)
      T.ok(
        seen.notes[1]:find('answers first, so this choice counts only when it does not', 1, true),
        seen.notes[1]
      )
    end)
    -- counter: the first endpoint down, the second is the only one left and is not asked about
    one.close()
    vim.g.note_retrieval = {
      endpoints = { { url = one.url, backend = 'unknown' }, { url = two.url, backend = 'unknown' } },
      timeout_ms = 2000,
    }
    with_ui({ pick = 1 }, function(seen)
      run('model')
      settle(seen)
      T.eq(#seen.items, 1)
      T.eq(seen.items[1].items, { 'b1', 'b2' })
      T.eq(state.model(two.url), 'b1')
    end)
  end)
  two.close()
end)

T.case('status API: cheap, an index that is not in memory is not read', function()
  V.with_vault(function(root)
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    local api = require('note_retrieval')
    local info = api.status()
    T.eq(info.loaded, false)
    T.eq(info.rows, nil)
    T.eq(info.root_mode, 'obsidian')
    T.eq(index.peek(root), nil) -- the call did not load it
    -- counter: the command loads it, and the API then answers from memory
    with_ui({}, function(seen)
      run('status')
      T.ok(seen.notes[1]:find('notes:     3', 1, true), seen.notes[1])
    end)
    info = api.status()
    T.eq({ info.loaded, info.rows, info.mode }, { true, 3, 'obsidian' })
  end)
end)

local function visual_search(root, keys)
  vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'abcdef', 'ghijkl', 'mnopqr' })
  vim.cmd('runtime plugin/note_retrieval.lua')
  with_ui({}, function(seen)
    vim.cmd(
      'execute "normal! '
        .. keys
        .. [[\<Cmd>lua vim.fn.maparg('<Plug>(note-retrieval-search)', 'x', false, true).callback()\<CR>"]]
    )
    settle(seen, 'items')
  end)
end

local function last_query(srv)
  local embeds = vim.tbl_filter(function(r)
    return r.path == '/v1/embeddings'
  end, srv.requests)
  return vim.json.decode(embeds[#embeds].body).input
end

T.case('search in Visual mode: a block selects the columns, not the lines', function()
  local srv = V.server({ V.MODEL })
  V.with_vault(function(root)
    vim.g.note_retrieval = { endpoints = V.endpoint(srv.url) }
    visual_search(root, [[gg0l\<C-v>jjll]])
  end)
  local got = last_query(srv)
  srv.close()
  T.eq(got, { 'bcd\nhij\nnop' })
end)

T.case('search in Visual mode: a selection of multibyte characters is cut at characters', function()
  local srv = V.server({ V.MODEL })
  V.with_vault(function(root)
    vim.g.note_retrieval = { endpoints = V.endpoint(srv.url) }
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'äöü日本語 x', 'ß€' })
    vim.cmd('runtime plugin/note_retrieval.lua')
    with_ui({}, function(seen)
      -- from the second character (ö) over the line end to the first of the next line (ß): `v` + `j` + `0`
      vim.cmd(
        [[execute "normal! gg0lvj0\<Cmd>lua vim.fn.maparg('<Plug>(note-retrieval-search)', 'x', false, true).callback()\<CR>"]]
      )
      settle(seen, 'items')
    end)
    -- and a block over wide characters: columns 2-3 of both lines
    with_ui({}, function(seen)
      vim.cmd(
        [[execute "normal! gg0l\<C-v>jl\<Cmd>lua vim.fn.maparg('<Plug>(note-retrieval-search)', 'x', false, true).callback()\<CR>"]]
      )
      settle(seen, 'items')
    end)
  end)
  local embeds = vim.tbl_filter(function(r)
    return r.path == '/v1/embeddings'
  end, srv.requests)
  srv.close()
  T.eq(vim.json.decode(embeds[1].body).input, { 'öü日本語 x\nß' })
  T.eq(vim.json.decode(embeds[2].body).input, { 'öü\n€' })
end)

T.case(
  'update in mode obsidian: the same read-only sentence, the index of Obsidian untouched, no indexer',
  function()
    V.with_vault(function(root)
      vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
      local before = sha_of(root .. '/_vaultrag/index.bin')
      with_ui({}, function(seen)
        run('update')
        T.ok(seen.notes[1]:find('read only here: Obsidian owns the index', 1, true), seen.notes[1])
        T.eq(seen.levels[1], vim.log.levels.INFO)
        T.eq(#seen.notes, 1)
      end)
      T.eq(sha_of(root .. '/_vaultrag/index.bin'), before)
      T.eq(indexer.status(root).indexer, false)
    end)
  end
)

T.case(
  'update in mode eigen: embeds what is missing, says the counts, a second one finds nothing to do',
  function()
    local dbl = double()
    with_eigen(2, dbl, function(root)
      with_ui({}, function(seen)
        run('update')
        T.ok(
          seen.notes[1]:find('updating the index of ' .. root .. ' with the model m1', 1, true),
          seen.notes[1]
        )
        wait_note(seen, 'update of ' .. root)
        T.ok(note_with(seen, '5 embedded, 0 removed, 0 failed'), vim.inspect(seen.notes))
        V.put(root .. '/n001.md', '')
        os.remove(root .. '/n002.md')
        run('update')
        T.ok(
          vim.wait(10000, function()
            return note_with(seen, '0 embedded, 2 removed, 0 failed') ~= nil
          end, 5),
          vim.inspect(seen.notes)
        )
        run('update')
        T.ok(
          vim.wait(10000, function()
            return note_with(seen, 'is current: nothing to embed or remove') ~= nil
          end, 5),
          vim.inspect(seen.notes)
        )
      end)
      local d = assert(vrix.decode(assert(io.open(root .. '/_idx/index.bin', 'rb')):read('*a')))
      T.eq(#d.paths, 3)
    end)
  end
)
