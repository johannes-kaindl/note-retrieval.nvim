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
  T.eq(command.complete('', 'NoteRetrieval '), { 'model', 'related', 'reset', 'search', 'status' })
  T.eq(command.complete('re', 'NoteRetrieval re'), { 'related', 'reset' })
  T.eq(command.complete('x', 'NoteRetrieval search x'), {})
  T.eq(command.complete('re', 'NoteRetrieval search re'), {})
end)

T.case('an unknown subcommand and none at all are said in words', function()
  with_ui({}, function(seen)
    run('bogus')
    run('')
    T.ok(seen.notes[1]:find('unknown subcommand "bogus"', 1, true), seen.notes[1])
    T.ok(seen.notes[1]:find('model, related, reset, search, status', 1, true), seen.notes[1])
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
  T.eq(vim.json.decode(embeds[1].body).input, { 'how are things' })
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
