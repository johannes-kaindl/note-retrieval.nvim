local T = require('note_retrieval.kit.test')
local C = require('note_retrieval.config')

local function with(g, setup, fn)
  local saved = vim.g.note_retrieval
  vim.g.note_retrieval = g
  C.set(setup)
  local ok, err = pcall(fn)
  vim.g.note_retrieval = saved
  C.set(nil)
  assert(ok, err)
end

local DEFAULTS = {
  k = 20,
  min_similarity = 0.3,
  hide_linked = true,
  link_format = 'wiki',
  index_on_save = true,
  probe_auto = true,
  timeout_ms = 30000,
}

-- Per option: values that pass, values that fail with the stated reason.
local CASES = {
  roots = {
    good = { { '/notes' }, { '/a', '/b' } },
    bad = { {}, '/notes', false, 5 },
    why = 'must be a non-empty list of directory paths',
  },
  index_dir = {
    good = { '_index', 'a/b', '.notes-index' },
    bad = { '', '/abs', 'C:/x', '../out', 'a/../../b', 5, false },
    why = 'must be a folder inside the root, such as "_index"',
  },
  exclude = {
    good = { {}, { 'Templates/' }, { 'Templates/', 'Archive/' } },
    bad = { { 'Templates/', '' }, { 5 }, 'Templates/', false, { a = 'b' } },
    why = 'must be a list of non-empty path prefixes such as { "Templates/" }',
  },
  embedding_model = {
    good = { 'nomic-embed-text' },
    bad = { '', '  ', 5, false },
    why = 'must be a model name such as "nomic-embed-text"',
  },
  k = {
    good = { 1, 50, 2147483647 },
    bad = { 0, -3, 2.5, '20', false, math.huge, -math.huge, 1e300, 2147483648, 0 / 0 },
    why = 'must be a whole number from 1 to 2147483647',
  },
  min_similarity = {
    good = { -1, 0, 0.55, 1 },
    bad = { 1.5, -2, '0.3', false },
    why = 'must be a number from -1 to 1',
  },
  hide_linked = { good = { true, false }, bad = { 'yes', 1, {} }, why = 'must be true or false' },
  link_format = {
    good = { 'wiki', 'markdown' },
    bad = { 'html', 'md', '', 1, false },
    why = 'must be "wiki" or "markdown"',
  },
  index_on_save = { good = { true, false }, bad = { 'no', 0 }, why = 'must be true or false' },
  probe_auto = { good = { true, false }, bad = { 'no', 0 }, why = 'must be true or false' },
  timeout_ms = {
    good = { 1, 90000, 2147483647 },
    bad = { 0, -1, 1.5, '5', math.huge, 1e300, 2147483648 },
    why = 'must be a whole number from 1 to 2147483647',
  },
}

T.case('resolve: without options the defaults, no problems', function()
  with(nil, nil, function()
    local cfg, problems = C.resolve()
    T.eq(problems, {})
    for name, want in pairs(DEFAULTS) do
      T.eq(cfg[name], want, name)
    end
    T.eq({ cfg.roots, cfg.endpoints, cfg.embedding_model }, {})
  end)
end)

T.case('NAMES lists every option, sorted, and CASES covers each (but endpoints)', function()
  local names = vim.tbl_keys(CASES)
  names[#names + 1] = 'endpoints'
  table.sort(names)
  T.eq(C.NAMES, names)
end)

T.case('resolve: every option takes a valid value from vim.g and from setup()', function()
  for name, spec in pairs(CASES) do
    for _, value in ipairs(spec.good) do
      with({ [name] = value }, nil, function()
        local cfg, problems = C.resolve()
        T.eq(problems, {}, name)
        T.eq(cfg[name], value, name)
      end)
      with(nil, { [name] = value }, function()
        local cfg, problems = C.resolve()
        T.eq(problems, {}, name)
        T.eq(cfg[name], value, name)
      end)
    end
  end
end)

T.case('resolve: every option names its problem for an invalid value and keeps its default', function()
  for name, spec in pairs(CASES) do
    for _, value in ipairs(spec.bad) do
      with({ [name] = value }, nil, function()
        local cfg, problems = C.resolve()
        T.eq(#problems, 1, name .. ' = ' .. vim.inspect(value))
        T.ok(vim.startswith(problems[1], name .. ': '), problems[1])
        T.eq(problems[1], name .. ': ' .. spec.why)
        T.eq(cfg[name], C.DEFAULTS[name], name)
      end)
    end
  end
end)

T.case('resolve: setup() wins over vim.g.note_retrieval, field by field', function()
  with({ k = 5, hide_linked = false }, { k = 8 }, function()
    local cfg = C.resolve()
    T.eq({ cfg.k, cfg.hide_linked }, { 8, false })
  end)
end)

T.case('resolve: every problem at once, sorted by name; unknown options are named', function()
  with({ k = 0, kk = 3, link_format = 'html', timeout_ms = 1.5 }, nil, function()
    local cfg, problems = C.resolve()
    T.eq(problems, {
      'k: must be a whole number from 1 to 2147483647',
      'kk: unknown option — ignored',
      'link_format: must be "wiki" or "markdown"',
      'timeout_ms: must be a whole number from 1 to 2147483647',
    })
    T.eq({ cfg.k, cfg.link_format, cfg.timeout_ms }, { 20, 'wiki', 30000 })
  end)
end)

T.case('resolve: valid endpoints are taken as given', function()
  local endpoints = { { url = 'http://localhost:11434' } }
  with({ endpoints = endpoints }, nil, function()
    local cfg, problems = C.resolve()
    T.eq(problems, {})
    T.eq(cfg.endpoints, endpoints)
    T.eq(cfg.endpoints_error, nil)
  end)
end)

T.case('resolve: invalid endpoints stop the run instead of falling back to the defaults', function()
  with({ endpoints = { { url = 'localhost:11434' } } }, nil, function()
    local cfg, problems = C.resolve()
    T.eq(#problems, 1)
    T.eq(problems[1], 'endpoints: entry 1: url must be an http(s) URL')
    T.ok(cfg.endpoints_error, 'endpoints_error not set')
    T.eq(cfg.endpoints, nil)
  end)
end)

T.case('resolve: endpoints that are not a list stop the run, also false', function()
  for _, bad in ipairs({ false, 'http://localhost:11434', 5 }) do
    with({ endpoints = bad }, nil, function()
      local cfg, problems = C.resolve()
      T.eq(problems, { 'endpoints: must be a non-empty list of endpoint tables' })
      T.ok(cfg.endpoints_error, 'endpoints_error not set for ' .. tostring(bad))
      T.eq(cfg.endpoints, nil)
    end)
  end
end)

T.case('setup(): no call is needed; a call reports problems once and replaces the earlier one', function()
  local init = require('note_retrieval')
  local notes = {}
  local saved = vim.notify
  vim.notify = function(msg)
    notes[#notes + 1] = msg
  end
  local ok, err = pcall(function()
    init.setup({ k = 0 })
    T.eq(notes, { 'note-retrieval: k: must be a whole number from 1 to 2147483647' })
    init.setup({ k = 7 })
    T.eq(#notes, 1)
    T.eq(init.resolve().k, 7)
  end)
  vim.notify = saved
  C.set(nil)
  assert(ok, err)
  T.eq(init.resolve().k, 20)
end)

T.case('resolve: a roots entry that is no path names its position', function()
  local why = 'entry %d must be a directory path'
  for _, want in ipairs({ { '' }, { 5 }, { '/a', '  ' } }) do
    with({ roots = want }, nil, function()
      local _, problems = C.resolve()
      T.eq(problems, { 'roots: ' .. why:format(#want) }, vim.inspect(want))
    end)
  end
end)

T.case('resolve: endpoints that are an empty list name the field once', function()
  with({ endpoints = {} }, nil, function()
    local cfg, problems = C.resolve()
    T.eq(problems, { 'endpoints: must be a non-empty list' })
    T.ok(cfg.endpoints_error, 'endpoints_error not set')
  end)
end)

T.case('resolve: options that are not a table are one problem, from vim.g and from setup()', function()
  for _, bad in ipairs({ 'x', 5, true }) do
    with(bad, nil, function()
      local cfg, problems = C.resolve()
      T.eq(problems, { 'note_retrieval: must be a table' }, vim.inspect(bad))
      T.eq(cfg.k, 20)
    end)
    with(nil, bad, function()
      local _, problems = C.resolve()
      T.eq(problems, { 'note_retrieval: must be a table' }, vim.inspect(bad))
    end)
  end
  with(nil, nil, function()
    T.eq(select(2, C.resolve()), {})
  end)
end)

T.case('setup(): a value that is no table is reported, not raised', function()
  local init = require('note_retrieval')
  local notes = {}
  local saved = vim.notify
  vim.notify = function(msg)
    notes[#notes + 1] = msg
  end
  local ok, err = pcall(init.setup, 'x')
  vim.notify = saved
  C.set(nil)
  T.ok(ok, err)
  T.eq(notes, { 'note-retrieval: note_retrieval: must be a table' })
end)
