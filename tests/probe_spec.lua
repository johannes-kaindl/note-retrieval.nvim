local T = require('note_retrieval.kit.test')
local V = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/vault.lua')
local embedder = require('note_retrieval.embedder')
local indexer = require('note_retrieval.indexer')
local probe = require('note_retrieval.probe')
local vectors = require('note_retrieval.kit.vectors')

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

local function body(i)
  return ('note %02d '):format(i) .. string.rep('lorem ipsum ', 20) -- 249 units, apart from the first 8
end

-- Eight notes with distinct, close vectors: each is its own nearest neighbour.
local function rows_of(count)
  local rows = {}
  for i = 1, count do
    rows[i] = { ('n%02d.md'):format(i), { 100 + i * 3, i * 9, (i * 7) % 40, 60 - i * 5 } }
  end
  return rows
end

-- An Obsidian vault whose index holds `count` notes with a body each (and the fixture's a, b, c
-- files, which the index does not know). `fn(root, rows)`.
local function with_notes(count, fn)
  local rows = rows_of(count)
  V.with_vault(function(root)
    for i, r in ipairs(rows) do
      V.put(root .. '/' .. r[1], body(i))
    end
    fn(root, rows)
  end, { rows = rows })
end

-- vim.notify recorded for the length of fn.
local function capture(fn)
  local saved = vim.notify
  local notes = {}
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(fn, notes)
  vim.notify = saved
  assert(ok, err)
end

-- The embedder replaced: the answer to a query is the vector of the note whose text starts with it
-- (`redirect[path] = other path` sends that note's query to another note's vector, `redirect[path] =
-- vec` to a vector of its own). Answers come back on a later tick; the double counts the queries
-- in flight at once. `fn(stats)`.
local function with_double(root, rows, redirect, fn)
  local saved = { embedder.resolve, embedder.query }
  local stats = { calls = 0, active = 0, max_active = 0, queries = {} }
  local by_query = {}
  local vec_of = {}
  for _, r in ipairs(rows) do
    vec_of[r[1]] = r[2]
    by_query[probe.query_of(root, r[1]) or ''] = r[1]
  end
  embedder.resolve = function(_, _, cb)
    cb({ model = 'test-model', dim = 4, timeout_ms = 1000 })
  end
  embedder.query = function(_, text, cb)
    stats.calls = stats.calls + 1
    stats.active = stats.active + 1
    stats.max_active = math.max(stats.max_active, stats.active)
    stats.queries[#stats.queries + 1] = text
    local path = by_query[text]
    local want = redirect and redirect[path]
    local vec = type(want) == 'table' and want or vec_of[want or path]
    vim.defer_fn(function()
      stats.active = stats.active - 1
      cb(vectors.to_index_vector({ vec }, 4))
    end, 2)
  end
  local ok, err = pcall(fn, stats)
  embedder.resolve, embedder.query = saved[1], saved[2]
  assert(ok, err)
end

local function run_probe(root, opts)
  local got
  probe.run(root, opts, function(...)
    got = { ... }
  end)
  T.ok(
    vim.wait(10000, function()
      return got ~= nil
    end, 2),
    'the probe did not finish'
  )
  return unpack(got)
end

local function bytes(path)
  local f = assert(io.open(path, 'rb'))
  local s = f:read('*a')
  f:close()
  return s
end

-- The kit's conformance vectors of code-kit (probeOrder, probeQuery) live in the nvim-kit repo of the
-- Dach, not in the vendored copy: without the Dach this says so instead of passing quietly.
local function vectors_file(name)
  local path = repo .. '/../nvim-kit/tests/conformance/code-kit/' .. name .. '.json'
  if vim.uv.fs_stat(path) then
    return vim.json.decode(bytes(path), { luanil = { object = true } }).cases
  end
  io.write(('    SKIPPED %s: no nvim-kit at %s\n'):format(name, path))
end

T.case('the order of the sample is the kit conformance order (probeOrder)', function()
  local cases = vectors_file('probeOrder')
  if not cases then
    return
  end
  for _, c in ipairs(cases) do
    local paths, want = {}, {}
    for i, f in ipairs(c.args[1]) do
      paths[i] = f.path
    end
    for i, f in ipairs(c.expected) do
      want[i] = f.path
    end
    T.eq(probe.order(paths, c.args[2]), want, c.name)
  end
end)

T.case('the query and the window are the kit conformance ones (probeQuery), read from the note', function()
  local cases = vectors_file('probeQuery')
  if not cases then
    return
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local checked = 0
  for _, c in ipairs(cases) do
    if c.args[2] == nil or c.args[2].strict ~= true then
      V.put(dir .. '/q.md', c.args[1])
      T.eq(probe.query_of(dir, 'q.md'), c.expected, c.name)
      checked = checked + 1
    end
  end
  vim.fn.delete(dir, 'rf')
  T.ok(checked >= 14, 'too few cases checked: ' .. checked)
end)

T.case('select: the sample is the first n candidates in the order of the seed', function()
  with_notes(8, function(root, rows)
    local paths = {}
    for i, r in ipairs(rows) do
      paths[i] = r[1]
    end
    local picked = probe.select(root, paths, 3)
    T.eq(#picked, 3)
    local order = probe.order(paths)
    T.eq({ picked[1].path, picked[2].path, picked[3].path }, { order[1], order[2], order[3] })
    -- fixed by hand from the kit's order (FNV-1a over "20260903:<path>"; recomputed in Python)
    T.eq(order, { 'n08.md', 'n01.md', 'n04.md', 'n07.md', 'n06.md', 'n02.md', 'n05.md', 'n03.md' })
    T.eq(picked[1].query, vim.trim(body(8))) -- the whole body (249 units), trimmed
    -- another seed, another sample
    T.ok(not vim.deep_equal(probe.order(paths, 7), order), 'the seed did not change the order')
    local other = probe.select(root, paths, 3, 7)
    T.ok(
      not vim.deep_equal({ other[1].path, other[2].path, other[3].path }, { order[1], order[2], order[3] }),
      'the seed did not change the selection'
    )
  end)
end)

T.case('a note the index does not know is no candidate', function()
  with_notes(4, function(root, rows)
    V.put(root .. '/stranger.md', body(9)) -- a fine body, but no row
    local run, result = nil, nil
    with_double(root, rows, nil, function(stats)
      result = run_probe(root, { n = 10 })
      run = stats
    end)
    T.eq(result.n, 4)
    for _, q in ipairs(run.queries) do
      T.ok(not q:find('note 09', 1, true), 'the stranger was searched')
    end
    -- and not through `select` either, which is given the index's paths
    local all = probe.select(root, { 'n01.md', 'n02.md', 'n03.md', 'n04.md' }, 10)
    T.eq(#all, 4)
  end)
end)

T.case('the window is 200 < len <= 800 UTF-16 units, an astral character counts 2', function()
  V.with_vault(function(root)
    local bounds = {
      ['x200.md'] = { string.rep('x', 200), false },
      ['x201.md'] = { string.rep('x', 201), true },
      ['x800.md'] = { string.rep('x', 800), true },
      ['x801.md'] = { string.rep('x', 801), false },
      ['e100.md'] = { string.rep('😀', 100), false }, -- 200 units
      ['e101.md'] = { string.rep('😀', 101), true }, -- 202 units
      ['e400.md'] = { string.rep('😀', 400), true }, -- 800 units
      ['e401.md'] = { string.rep('😀', 401), false }, -- 802 units
      ['fm.md'] = { '---\ntitle: ' .. string.rep('t', 300) .. '\n---\n' .. string.rep('x', 150), false },
      ['pad.md'] = { '\n\n  ' .. string.rep('x', 201) .. '  \n', true },
    }
    local paths = {}
    for name, b in pairs(bounds) do
      V.put(root .. '/' .. name, b[1])
      paths[#paths + 1] = name
    end
    table.sort(paths)
    local got = {}
    for _, c in ipairs(probe.select(root, paths, 100)) do
      got[c.path] = true
    end
    for name, b in pairs(bounds) do
      T.eq(got[name] == true, b[2], name)
    end
    T.eq(#probe.select(root, { 'e400.md' }, 1)[1].query, #string.rep('😀', 150)) -- 300 units = 150 emoji
  end)
end)

T.case('run: every note finds itself; the result has the counts, the seed and the model', function()
  with_notes(8, function(root, rows)
    with_double(root, rows, nil, function(stats)
      local result = run_probe(root, { n = 5 })
      T.eq(result.n, 5)
      T.eq(result.hits, 5)
      T.eq(result.rate, 1)
      T.eq(result.failures, {})
      T.eq(result.seed, 20260903)
      T.eq(result.model, V.MODEL)
      T.eq(stats.calls, 5)
      -- no instruction in front: the query is the first 300 units of the body, as it is
      T.ok(stats.queries[1]:find('^note %d%d lorem'), stats.queries[1])
    end)
  end)
end)

T.case(
  'run: a miss is listed with the rank found and the best hit; a note not among the hits has no rank',
  function()
    with_notes(8, function(root, rows)
      -- n08 is the first of the sample (see the order above): it is sent to the vector of n07, n01
      -- (second) to one nothing is close to
      with_double(root, rows, { ['n08.md'] = 'n07.md', ['n01.md'] = { -127, -5, -5, 0 } }, function()
        local result = run_probe(root, { n = 2 })
        T.eq(result.n, 2)
        T.eq(result.hits, 0)
        T.eq(result.failures[1], { path = 'n08.md', rank = 1, top = 'n07.md' })
        T.eq(result.failures[2], { path = 'n01.md', rank = nil, top = nil })
        local text = table.concat(probe.lines(result), '\n')
        T.ok(text:find('0/2 on rank 0', 1, true), text)
        T.ok(text:find('n08.md: rank 1, best hit n07.md', 1, true), text)
        T.ok(text:find('n01.md: not found, best hit none', 1, true), text)
      end)
    end)
  end
)

T.case('run: the queries go out one after another, never two at a time', function()
  with_notes(8, function(root, rows)
    with_double(root, rows, nil, function(stats)
      local result = run_probe(root, { n = 8 })
      T.eq(result.n, 8)
      T.eq(stats.calls, 8)
      T.eq(stats.max_active, 1)
    end)
  end)
end)

T.case('run: a search that fails ends the run with its error and what was counted', function()
  with_notes(4, function(root, rows)
    with_double(root, rows, nil, function()
      embedder.resolve = function(_, _, cb)
        cb(nil, { kind = 'unreachable', detail = 'down' })
      end
      local result, err, partial = run_probe(root, { n = 4 })
      T.eq(result, nil)
      T.eq(err.kind, 'unreachable')
      T.eq(partial.n, 0)
    end)
  end)
end)

T.case('command: probe prints x/n on rank 0 and the misses; the Obsidian index is not written', function()
  with_notes(8, function(root, rows)
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/n01.md'))
    local before = bytes(root .. '/_vaultrag/index.bin')
    local listing = vim.fn.glob(root .. '/**/*', true, true)
    with_double(root, rows, { ['n08.md'] = 'n07.md' }, function()
      capture(function(notes)
        vim.cmd('NoteRetrieval probe 4')
        T.ok(
          vim.wait(10000, function()
            return #notes >= 2
          end, 2),
          vim.inspect(notes)
        )
        T.ok(notes[1].msg:find('probing up to 4 notes', 1, true), notes[1].msg)
        T.ok(notes[2].msg:find('3/4 on rank 0', 1, true), notes[2].msg)
        T.ok(notes[2].msg:find('n08.md: rank 1, best hit n07.md', 1, true), notes[2].msg)
        T.eq(notes[2].level, vim.log.levels.WARN)
      end)
    end)
    T.eq(bytes(root .. '/_vaultrag/index.bin'), before)
    T.eq(vim.fn.glob(root .. '/**/*', true, true), listing)
  end)
end)

T.case('command: probe --json is one JSON line with n, hits, rate, failures, seed and model', function()
  with_notes(8, function(root, rows)
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/n01.md'))
    with_double(root, rows, { ['n08.md'] = 'n07.md', ['n01.md'] = { -127, -5, -5, 0 } }, function()
      capture(function(notes)
        vim.cmd('NoteRetrieval probe --json 3')
        T.ok(
          vim.wait(10000, function()
            return #notes >= 1
          end, 2),
          'no output'
        )
        T.eq(#notes, 1) -- no start message in front of the JSON
        T.ok(not notes[1].msg:find('\n', 1, true), 'more than one line')
        local j = vim.json.decode(notes[1].msg)
        T.eq(j.n, 3)
        T.eq(j.hits, 1)
        T.eq(j.rate, 1 / 3)
        T.eq(j.seed, 20260903)
        T.eq(j.model, V.MODEL)
        T.eq(j.failures, {
          { path = 'n08.md', rank = 1, top = 'n07.md' },
          { path = 'n01.md', rank = vim.NIL, top = vim.NIL },
        })
      end)
    end)
  end)
end)

T.case('command: a bad argument is refused in words, nothing is searched', function()
  with_notes(4, function(root, rows)
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/n01.md'))
    with_double(root, rows, nil, function(stats)
      capture(function(notes)
        vim.cmd('NoteRetrieval probe many')
        vim.cmd('NoteRetrieval probe 0')
        T.eq(#notes, 2)
        T.ok(notes[1].msg:find('probe takes a number of notes and --json, not "many"', 1, true), notes[1].msg)
        T.eq(notes[1].level, vim.log.levels.ERROR)
      end)
      T.eq(stats.calls, 0)
    end)
  end)
end)

-- The own-index vault of the reindex tests: ten notes that qualify, embeddings of the writer from a
-- double, `embedder.query` from `with_double`.
local function with_eigen(fn)
  V.with_vault(function(root)
    vim.fn.delete(root .. '/.obsidian/plugins', 'rf')
    vim.fn.delete(root .. '/_vaultrag', 'rf')
    for i = 1, 10 do
      V.put(('%s/p%02d.md'):format(root, i), body(i))
    end
    local state_home = vim.env.XDG_STATE_HOME
    vim.env.XDG_STATE_HOME = root .. '/_state'
    vim.g.note_retrieval = { index_dir = '_idx' }
    indexer.reset()
    local saved = { embedder.resolve, embedder.for_indexer, embedder.query }
    local calls = { query = 0 }
    embedder.resolve = function(_, _, cb)
      cb({ endpoint = { url = 'http://double' }, model = 'm1', dim = 4, timeout_ms = 1000 })
    end
    embedder.for_indexer = function()
      return function(texts, cb)
        vim.defer_fn(function()
          local vecs = {}
          for i, t in ipairs(texts) do
            vecs[i] = { 1 + (#t % 5), 2 + i, 3, 4 }
          end
          cb(vecs)
        end, 1)
      end
    end
    embedder.query = function(_, text, cb)
      calls.query = calls.query + 1
      vim.defer_fn(function()
        cb(vectors.to_index_vector({ { 1 + (#text % 5), 2, 3, 4 } }, 4))
      end, 1)
    end
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/p01.md'))
    local ok, err = pcall(fn, root, calls)
    embedder.resolve, embedder.for_indexer, embedder.query = saved[1], saved[2], saved[3]
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

local function wait_for(notes, part)
  T.ok(
    vim.wait(10000, function()
      for _, n in ipairs(notes) do
        if n.msg:find(part, 1, true) then
          return true
        end
      end
    end, 2),
    ('no note with %q in %s'):format(part, vim.inspect(notes))
  )
end

T.case('reindex in mode eigen: the probe follows on 8 notes and says so in one line', function()
  with_eigen(function(_, calls)
    capture(function(notes)
      vim.cmd('NoteRetrieval reindex')
      wait_for(notes, 'probe after the reindex: ')
      local line
      for _, n in ipairs(notes) do
        if n.msg:find('probe after the reindex', 1, true) then
          line = n.msg
        end
      end
      T.ok(line:match('probe after the reindex: %d/8 on rank 0'), line)
      T.ok(not line:find('\n', 1, true), 'more than one line')
      T.eq(calls.query, 8)
    end)
  end)
end)

T.case('reindex in mode eigen: probe_auto = false switches the follow-up off', function()
  with_eigen(function(_, calls)
    vim.g.note_retrieval = { index_dir = '_idx', probe_auto = false }
    capture(function(notes)
      vim.cmd('NoteRetrieval reindex')
      wait_for(notes, 'notes indexed in')
      vim.wait(100)
      for _, n in ipairs(notes) do
        T.ok(not n.msg:find('probe', 1, true), n.msg)
      end
      T.eq(calls.query, 0)
    end)
  end)
end)

T.case('the automatic probe waits while a writer run is active, and is silent without candidates', function()
  with_eigen(function(root, calls)
    capture(function(notes)
      local status = indexer.status
      indexer.status = function()
        return { running = true, kind = 'save' }
      end
      probe.auto(root)
      indexer.status = status
      vim.wait(50)
      T.eq(calls.query, 0)
      T.eq(#notes, 0)
    end)
  end)
end)
