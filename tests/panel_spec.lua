local T = require('note_retrieval.kit.test')
local date = require('note_retrieval.kit.date')
local llm = require('note_retrieval.kit.llm')
local vrix = require('note_retrieval.kit.vrix')
local config = require('note_retrieval.config')
local index = require('note_retrieval.index')
local panel = require('note_retrieval.panel')
local search = require('note_retrieval.search')

local uv = vim.uv or vim.loop

local DIM = 4
local BUILT = date.days_from_civil(2026, 10, 20) * 86400 -- built_at, in seconds

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
    built_at = '2026-10-20T00:00:00.000Z',
  }
  return vrix.encode(manifest, paths, matrix(rows), stamps)
end

local function put(path, bytes, mtime)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'wb'))
  f:write(bytes)
  f:close()
  if mtime then
    assert(uv.fs_utime(path, mtime, mtime))
  end
end

-- `a` is the note the tests start from. `b`, `d` and `e` are close to it; the two `Plan` notes
-- share a short name; `orphan1` is the closest of all but has no file; `c` is orthogonal.
local ROWS = {
  { 'a.md', { 127, 0, 0, 0 } },
  { 'orphan1.md', { 126, 5, 0, 0 } },
  { 'b.md', { 100, 50, 0, 0 } },
  { 'Notes/Plan.md', { 90, 60, 0, 0 } },
  { 'Work/Plan.md', { 80, 70, 0, 0 } },
  { 'sub/e.md', { 60, 90, 0, 0 } },
  { 'c.md', { 0, 0, 127, 0 } },
}

-- An Obsidian vault with an index of ROWS; `opts.texts` maps a note to its text (default: its
-- name), `opts.stamps` and `opts.mtimes` (note -> seconds) set what the marks are measured from.
-- Every window and buffer the test opened is gone afterwards, as are the options.
local function with_vault(opts, fn)
  opts = opts or {}
  local base = vim.fn.tempname()
  local root = base .. '/vault'
  put(root .. '/.obsidian/plugins/vault-retrieval/data.json', '{}')
  local paths, vecs = {}, {}
  for i, r in ipairs(ROWS) do
    paths[i], vecs[i] = r[1], r[2]
    if not r[1]:match('^orphan') then
      local mtime = opts.mtimes and opts.mtimes[r[1]] or BUILT - 5000
      put(root .. '/' .. r[1], (opts.texts or {})[r[1]] or ('# ' .. r[1]), mtime)
    end
  end
  put(root .. '/_vaultrag/index.bin', container(paths, vecs, opts.stamps))
  index.reset()
  llm.reset()
  vim.cmd('silent! %bwipeout!')
  local ok, err = pcall(fn, root)
  panel.close()
  vim.cmd('silent! only')
  vim.cmd('silent! %bwipeout!')
  index.reset()
  config.set(nil)
  vim.fn.delete(base, 'rf')
  assert(ok, err)
end

-- Paths as the file system names them: a temporary folder may sit behind a symbolic link.
local function real(path)
  return uv.fs_realpath(path) or path
end

local function panel_buf()
  return vim.fn.bufnr(panel.NAME)
end

local function panel_lines()
  return vim.api.nvim_buf_get_lines(panel_buf(), 0, -1, false)
end

local function panel_win()
  return vim.fn.win_findbuf(panel_buf())[1]
end

-- Presses a key of the panel: the buffer-local mapping, run with the cursor on `lnum` of the panel.
local function press(key, lnum)
  local win = panel_win()
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { lnum, 0 })
  local map
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(panel_buf(), 'n')) do
    if m.lhs == key then
      map = m
    end
  end
  assert(map, 'the panel has no key ' .. key)
  map.callback()
end

local function lnum_of(title)
  for i, l in ipairs(panel_lines()) do
    if l:find(title .. ' — ', 1, true) then
      return i
    end
  end
  error('no panel line for ' .. title)
end

-- Opens `name` in the only window and then the panel; the cursor stays in the note.
local function open_panel(root, name)
  vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. name))
  panel.toggle()
  return vim.api.nvim_get_current_win()
end

T.case('build: header with the count, rows with two decimals, title and folder', function()
  local lines, rows = panel.build({
    note = 'a.md',
    results = {
      { path = 'sub/e.md', score = 0.8, title = 'e' },
      { path = 'b.md', score = 0.456, title = 'b' },
    },
  })
  T.eq(lines, { 'Related to a.md: 2 notes', '0.80  e — sub', '0.46  b — (vault root)' })
  T.eq(rows, { [2] = 'sub/e.md', [3] = 'b.md' })
  T.eq(
    panel.build({ note = 'a.md', results = { { path = 'b.md', score = 1, title = 'b' } } })[1],
    'Related to a.md: 1 note'
  )
  T.eq(
    panel.build({ note = 'a.md', message = 'no matching notes' }),
    { 'Related to a.md: 0 notes', 'no matching notes' }
  )
end)

T.case('toggle opens a panel on the right with the related notes; the cursor stays in the note', function()
  with_vault(nil, function(root)
    config.set({ min_similarity = 0 })
    local note_win = open_panel(root, 'a.md')
    T.eq(vim.api.nvim_get_current_win(), note_win)
    local panel_w = panel_win()
    T.ok(panel_w ~= nil and panel_w ~= note_win, 'a window of its own')
    T.ok(vim.fn.win_screenpos(panel_w)[2] > vim.fn.win_screenpos(note_win)[2], 'on the right')
    local lines = panel_lines()
    T.eq(lines[1], 'Related to a.md: 5 notes')
    T.eq(lines[2], '0.89  b — (vault root)') -- orphan1 is closer but has no file
    T.ok(lines[3]:match('^0%.%d%d  Plan — Notes$'), lines[3])
    T.ok(lines[4]:match('^0%.%d%d  Plan — Work$'), lines[4])
    T.ok(not table.concat(lines, '\n'):find('orphan1', 1, true), 'a row without a file is not shown')
  end)
end)

T.case('keys: only in the panel buffer, no global mapping', function()
  with_vault(nil, function(root)
    local before = #vim.api.nvim_get_keymap('n')
    open_panel(root, 'a.md')
    T.eq(#vim.api.nvim_get_keymap('n'), before)
    local keys = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(panel_buf(), 'n')) do
      keys[#keys + 1] = m.lhs
    end
    table.sort(keys)
    T.eq(keys, { '<CR>', 'l', 'q' })
  end)
end)

T.case('<CR> opens the note in the previous window', function()
  with_vault(nil, function(root)
    config.set({ min_similarity = 0 })
    local note_win = open_panel(root, 'a.md')
    press('<CR>', lnum_of('e'))
    T.eq(vim.api.nvim_get_current_win(), note_win)
    T.eq(real(vim.api.nvim_buf_get_name(0)), real(root .. '/sub/e.md'))
    T.ok(panel_win() ~= nil, 'the panel stays open')
    press('<CR>', 1) -- the header line stands for no note
    T.eq(vim.api.nvim_get_current_win(), panel_win())
  end)
end)

T.case(
  '<CR> never opens a note whose file is gone, also one that vanished after the panel was drawn',
  function()
    with_vault(nil, function(root)
      config.set({ min_similarity = 0 })
      local note_win = open_panel(root, 'a.md')
      local seen = {}
      local notify = vim.notify
      vim.notify = function(msg)
        seen[#seen + 1] = msg
      end
      local lnum = lnum_of('b')
      assert(os.remove(root .. '/b.md'))
      press('<CR>', lnum)
      vim.notify = notify
      T.eq(real(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(note_win))), real(root .. '/a.md'))
      T.eq(vim.api.nvim_get_current_win(), panel_win())
      T.ok(seen[1] and seen[1]:find('b.md no longer exists', 1, true), 'it says so')
      T.eq(vim.fn.bufnr(root .. '/b.md'), -1)
    end)
  end
)

T.case('l writes a wiki link at the cursor of the previous window; undo takes back the link only', function()
  with_vault({ texts = { ['a.md'] = 'hello world' } }, function(root)
    config.set({ min_similarity = 0 })
    local note_win = open_panel(root, 'a.md')
    vim.api.nvim_win_set_cursor(note_win, { 1, 6 })
    vim.api.nvim_set_current_win(note_win)
    vim.cmd('normal! ix ') -- a typed change right before: the link must not merge into its undo step
    vim.api.nvim_win_set_cursor(note_win, { 1, 8 })
    press('l', lnum_of('e'))
    T.eq(
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(note_win), 0, -1, false),
      { 'hello x w[[e]]orld' }
    )
    T.eq(vim.api.nvim_win_get_cursor(note_win), { 1, 13 })
    vim.api.nvim_set_current_win(note_win)
    vim.cmd('silent undo')
    T.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'hello x world' })
  end)
end)

T.case(
  'l writes the link in the form link_format asks for; a short name that is no longer unique gets its path',
  function()
    with_vault({ texts = { ['a.md'] = '' } }, function(root)
      config.set({ min_similarity = 0, link_format = 'markdown' })
      local note_win = open_panel(root, 'a.md')
      press('l', lnum_of('e'))
      T.eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(note_win), 0, -1, false), { '[e](sub/e.md)' })
      config.set({ min_similarity = 0, link_format = 'wiki' })
      vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(note_win), 0, -1, false, { '' })
      vim.api.nvim_win_set_cursor(note_win, { 1, 0 })
      panel.update(vim.api.nvim_win_get_buf(note_win))
      -- two notes are called Plan: [[Plan]] would be ambiguous in Obsidian
      local lines = panel_lines()
      local at
      for i, l in ipairs(lines) do
        if l:find('Plan — Work', 1, true) then
          at = i
        end
      end
      press('l', at)
      T.eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(note_win), 0, -1, false), { '[[Work/Plan]]' })
      press('l', lnum_of('b'))
      T.eq(
        vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(note_win), 0, -1, false),
        { '[[Work/Plan]][[b]]' }
      )
    end)
  end
)

T.case('q closes the panel: window, buffer, autocmds and a pending refresh are gone', function()
  with_vault(nil, function(root)
    local note_win = open_panel(root, 'a.md')
    local nb = vim.api.nvim_get_current_buf()
    T.ok(#vim.api.nvim_get_autocmds({ group = 'NoteRetrievalPanel' }) > 0, 'autocmds while open')
    local calls = 0
    local update = panel.update
    panel.update = function(...)
      calls = calls + 1
      return update(...)
    end
    vim.api.nvim_exec_autocmds('BufEnter', { buffer = nb })
    press('q', 1)
    vim.wait(panel.DEBOUNCE_MS * 3)
    panel.update = update
    T.eq(calls, 0)
    T.eq(panel_buf(), -1)
    T.eq(vim.api.nvim_list_wins(), { note_win })
    T.ok(not pcall(vim.api.nvim_get_autocmds, { group = 'NoteRetrievalPanel' }), 'the group is gone')
    -- and it opens again, and toggle closes it
    panel.toggle()
    T.ok(panel_win() ~= nil, 'open again')
    panel.toggle()
    T.eq(panel_buf(), -1)
  end)
end)

T.case('a refresh pending when the panel closes does not reach the panel opened next', function()
  with_vault(nil, function(root)
    config.set({ min_similarity = 0 })
    open_panel(root, 'a.md')
    local abuf = vim.api.nvim_get_current_buf()
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/c.md'))
    vim.api.nvim_exec_autocmds('BufEnter', { buffer = vim.api.nvim_get_current_buf() })
    panel.close()
    vim.cmd('buffer ' .. abuf)
    panel.toggle()
    vim.wait(panel.DEBOUNCE_MS * 3)
    T.ok(panel_lines()[1]:find('Related to a.md', 1, true), panel_lines()[1])
  end)
end)

T.case(
  'the panel follows BufEnter on a note, once for a burst (debounced); other buffers leave it alone',
  function()
    with_vault(nil, function(root)
      config.set({ min_similarity = 0 })
      local note_win = open_panel(root, 'a.md')
      vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/c.md'))
      local calls, seen = 0, nil
      local update = panel.update
      panel.update = function(buf)
        calls = calls + 1
        seen = buf
        return update(buf)
      end
      local cbuf = vim.api.nvim_get_current_buf()
      vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/b.md'))
      local bbuf = vim.api.nvim_get_current_buf()
      for _ = 1, 6 do
        vim.api.nvim_exec_autocmds('BufEnter', { buffer = cbuf })
      end
      vim.api.nvim_exec_autocmds('BufEnter', { buffer = bbuf })
      -- not a note of a vault: a scratch buffer, a file outside every vault
      vim.api.nvim_exec_autocmds('BufEnter', { buffer = panel_buf() })
      local other = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(other, vim.fn.tempname() .. '/outside.md')
      vim.api.nvim_exec_autocmds('BufEnter', { buffer = other })
      T.eq(calls, 0) -- nothing ran yet: the timer is still waiting for quiet
      vim.wait(2000, function()
        return calls > 0
      end)
      vim.wait(panel.DEBOUNCE_MS * 3)
      panel.update = update
      T.eq(calls, 1)
      T.eq(seen, bbuf) -- the last note of the burst
      T.ok(panel_lines()[1]:find('Related to b.md', 1, true), panel_lines()[1])
      T.eq(panel.update(panel_buf()), nil)
      T.eq(panel.update(other), nil)
      T.ok(note_win ~= nil)
    end)
  end
)

T.case('hide_linked hides the notes the note links to; an ambiguous short name hides nothing', function()
  with_vault(
    { texts = { ['a.md'] = 'See [[b]] and [[Plan]] and [x](sub/e.md) and `[[c]]`.' } },
    function(root)
      config.set({ min_similarity = 0 })
      open_panel(root, 'a.md')
      local text = table.concat(panel_lines(), '\n')
      -- b and sub/e are linked; Plan names two notes, so neither is hidden; c is in code
      T.eq(panel_lines()[1], 'Related to a.md: 3 notes')
      T.ok(not text:find('b — ', 1, true) and not text:find('e — ', 1, true), 'linked notes are hidden')
      T.ok(
        text:find('Plan — Notes', 1, true) and text:find('Plan — Work', 1, true),
        'ambiguous: both stay'
      )
      T.ok(text:find('c — ', 1, true), 'a link in code is no link')
      -- the full path of one of them hides exactly that one
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { '[[Notes/Plan]]' })
      panel.update(0)
      text = table.concat(panel_lines(), '\n')
      T.ok(not text:find('Plan — Notes', 1, true) and text:find('Plan — Work', 1, true), text)
      -- hidden notes do not take places from k: ask for two, get two
      config.set({ min_similarity = 0, k = 2 })
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { '[[b]]' })
      panel.update(0)
      T.eq(#panel_lines(), 3)
      config.set({ min_similarity = 0, hide_linked = false })
      panel.update(0)
      T.ok(table.concat(panel_lines(), '\n'):find('b — ', 1, true), 'hide_linked = false shows everything')
    end
  )
end)

local function header(texts_mtime, stamps)
  local lines
  with_vault({ stamps = stamps, mtimes = texts_mtime }, function(root)
    config.set({ min_similarity = 0 })
    open_panel(root, 'a.md')
    lines = panel_lines()
  end)
  return lines[1]
end

local NO_STAMPS = { { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } }

T.case('the mark in words: changed since the index, may be stale with the index time, none', function()
  local changed = header(
    { ['a.md'] = BUILT - 5000 },
    { { 123000, 7 }, { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } }
  )
  T.ok(changed:find('; changed since the index', 1, true), changed)
  local maybe = header({ ['a.md'] = BUILT + 5000 }, NO_STAMPS)
  local when = os.date('%Y-%m-%d %H:%M', BUILT)
  T.ok(maybe:find('; may be stale, index from ' .. when, 1, true), maybe)
  local none = header({ ['a.md'] = BUILT - 5000 }, NO_STAMPS)
  T.eq(none, 'Related to a.md: 5 notes')
end)

T.case('a note without a row, and a vault without an index, are said in words', function()
  with_vault({ texts = {} }, function(root)
    put(root .. '/new.md', 'brand new')
    open_panel(root, 'new.md')
    T.eq(panel_lines(), { 'Related to new.md: 0 notes', search.NO_ROW })
    os.remove(root .. '/_vaultrag/index.bin')
    index.reset()
    panel.update(0)
    T.eq(#panel_lines(), 2)
    T.ok(panel_lines()[2]:find('index', 1, true), panel_lines()[2])
  end)
end)

T.case(
  'a torn index reload: the panel shows the warning, with the rows of the index loaded earlier',
  function()
    with_vault(nil, function(root)
      config.set({ min_similarity = 0 })
      open_panel(root, 'a.md')
      T.ok(not table.concat(panel_lines(), '\n'):find('Warning:', 1, true), 'no warning on a clean index')
      local paths, vecs = {}, {}
      for i, r in ipairs(ROWS) do
        paths[i], vecs[i] = r[1], r[2]
      end
      put(root .. '/_vaultrag/index.bin', container(paths, vecs):sub(1, 33))
      panel.update(vim.api.nvim_get_current_buf())
      local lines = panel_lines()
      T.eq(lines[1], 'Related to a.md: 5 notes')
      T.ok(lines[2]:match('^Warning: .*using the index loaded earlier'), lines[2])
      T.ok(lines[3]:match('^0%.%d%d  b — '), lines[3])
    end)
  end
)

T.case('<CR> with the panel alone opens a note window to its left; the panel keeps its width', function()
  with_vault(nil, function(root)
    config.set({ min_similarity = 0 })
    local columns = vim.o.columns
    vim.o.columns = 120
    local note_win = open_panel(root, 'a.md')
    local width = vim.api.nvim_win_get_width(panel_win())
    vim.api.nvim_win_close(note_win, true) -- the window the person came from is gone
    vim.api.nvim_set_current_win(panel_win())
    press('<CR>', lnum_of('e'))
    local cur = vim.api.nvim_get_current_win()
    T.eq(real(vim.api.nvim_buf_get_name(0)), real(root .. '/sub/e.md'))
    T.ok(cur ~= panel_win())
    T.ok(vim.fn.win_screenpos(cur)[2] < vim.fn.win_screenpos(panel_win())[2], 'to the left')
    T.eq(vim.api.nvim_win_get_width(panel_win()), width)
    local took = vim.api.nvim_win_get_width(cur)
    vim.o.columns = columns
    T.ok(took > width, 'it took the rest of the width, not half of the panel: ' .. took)
  end)
end)

T.case('<CR> and l leave a window that is no note window (explorer, help, quickfix) alone', function()
  with_vault(nil, function(root)
    config.set({ min_similarity = 0 })
    local other = open_panel(root, 'a.md')
    local tree = vim.api.nvim_create_buf(false, true) -- buftype nofile, like an explorer
    vim.api.nvim_win_set_buf(other, tree)
    vim.api.nvim_buf_set_lines(tree, 0, -1, false, { 'tree' })
    local seen = {}
    local notify = vim.notify
    vim.notify = function(msg)
      seen[#seen + 1] = msg
    end
    press('l', lnum_of('e'))
    vim.notify = notify
    T.eq(vim.api.nvim_buf_get_lines(tree, 0, -1, false), { 'tree' })
    T.ok(seen[1] and seen[1]:find('no note window', 1, true), tostring(seen[1]))
    press('<CR>', lnum_of('e'))
    T.eq(vim.api.nvim_win_get_buf(other), tree)
    T.eq(real(vim.api.nvim_buf_get_name(0)), real(root .. '/sub/e.md'))
    T.ok(vim.api.nvim_get_current_win() ~= other and vim.api.nvim_get_current_win() ~= panel_win())
  end)
end)

T.case('a torn index reload and a note without a row: the warning and the message both stand', function()
  with_vault(nil, function(root)
    put(root .. '/new.md', 'brand new')
    open_panel(root, 'a.md')
    local paths, vecs = {}, {}
    for i, r in ipairs(ROWS) do
      paths[i], vecs[i] = r[1], r[2]
    end
    put(root .. '/_vaultrag/index.bin', container(paths, vecs):sub(1, 33))
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/new.md'))
    panel.update(vim.api.nvim_get_current_buf())
    local lines = panel_lines()
    T.eq(#lines, 3)
    T.ok(lines[2]:match('^Warning: .*using the index loaded earlier'), lines[2])
    T.eq(lines[3], search.NO_ROW)
  end)
end)
