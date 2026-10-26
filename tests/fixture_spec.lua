-- The fixture vault (tests/fixtures/vault, also the target of `make live`): twenty small notes in
-- five topic folders. Its index is not checked in as a blob; it is generated here with deterministic
-- vectors, one direction per topic, so what is related to what is known beforehand.
local T = require('note_retrieval.kit.test')
local config = require('note_retrieval.config')
local index = require('note_retrieval.index')
local indexer = require('note_retrieval.indexer')
local probe = require('note_retrieval.probe')
local roots = require('note_retrieval.roots')
local search = require('note_retrieval.search')
local vrix = require('note_retrieval.kit.vrix')

local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local FIXTURE = here .. '/fixtures/vault'
local TOPICS = { 'Astronomy', 'Baking', 'Budget', 'Hiking', 'Lua' }
local DIM = 8

-- int8 rows: the topic's own axis at 120, and a small deterministic offset on one of the last three
-- axes, so the notes of a topic are close to each other and far from the other topics.
local function row_of(path, nth)
  local topic = path:match('^(%a+)/')
  local v = {}
  for i = 1, DIM do
    v[i] = 0
  end
  for i, name in ipairs(TOPICS) do
    if name == topic then
      v[i] = 120
    end
  end
  v[6 + (nth % 3)] = 10 + nth
  return v
end

local function index_bytes(paths, rule)
  local cells = {}
  for i, p in ipairs(paths) do
    for _, x in ipairs((rule or row_of)(p, i)) do
      cells[#cells + 1] = string.char(x)
    end
  end
  return vrix.encode({
    vault = '',
    embedding_model = 'fixture-model',
    source_dim = DIM,
    index_dim = DIM,
    granularity = 'note',
    aggregation = 'mean',
    quant = 'int8',
    scale = 127,
    count = #paths,
    source_commit = '',
    built_at = '2026-10-26T12:00:00.000Z',
  }, paths, table.concat(cells))
end

-- `fn(root, paths)` with a copy of the fixture vault in a scratch folder and the generated index in
-- its folder `_index` (option index_dir). Everything is put back afterwards.
local function with_fixture(fn, opts)
  opts = opts or {}
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, 'p')
  vim.fn.system({ 'cp', '-R', FIXTURE, base .. '/vault' })
  T.eq(vim.v.shell_error, 0)
  local root = vim.uv.fs_realpath(base .. '/vault')
  if opts.before then
    opts.before(root)
  end
  local paths = assert(roots.note_paths(root, nil, '_index'))
  vim.fn.mkdir(root .. '/_index', 'p')
  local f = assert(io.open(root .. '/_index/index.bin', 'wb'))
  f:write(index_bytes(paths, opts.rule))
  f:close()
  index.reset()
  vim.g.note_retrieval = { index_dir = '_index', probe_auto = false }
  local ok, err = pcall(fn, root, paths)
  indexer.reset()
  index.reset()
  config.set(nil)
  vim.g.note_retrieval = nil
  vim.fn.delete(base, 'rf')
  assert(ok, err)
end

T.case('the fixture vault has twenty notes in five topics, found through roots', function()
  with_fixture(function(root, paths)
    T.eq(#paths, 20)
    local per_topic = {}
    for _, p in ipairs(paths) do
      local topic = p:match('^(%a+)/')
      per_topic[topic] = (per_topic[topic] or 0) + 1
    end
    T.eq(per_topic, { Astronomy = 4, Baking = 4, Budget = 4, Hiking = 4, Lua = 4 })
    -- the marker folder makes it a vault, found from any note, and is no note itself
    T.eq(roots.find_root(root .. '/Lua/closures.md', {}), root)
    for _, p in ipairs(paths) do
      T.ok(not p:find('^%.'), p)
    end
  end)
end)

T.case('the generated index of the fixture loads: twenty rows, the notes in order', function()
  with_fixture(function(root, paths)
    local loaded = assert(index.load(root, config.resolve()))
    T.eq(loaded.index.count, 20)
    T.eq(loaded.paths, paths)
    T.eq(loaded.mode, 'eigen')
    T.eq(loaded.manifest.embedding_model, 'fixture-model')
  end)
end)

-- True when every one of the three nearest notes of each probe note is from its own topic.
local function related_stay_in_topic(root)
  for _, note in ipairs({ 'Baking/hydration.md', 'Hiking/weather.md', 'Lua/testing.md' }) do
    local hits = assert(search.related(note, { root = root, k = 3 }))
    if #hits ~= 3 then
      return false, note
    end
    for _, hit in ipairs(hits) do
      if hit.path:match('^(%a+)/') ~= note:match('^(%a+)/') then
        return false, note .. ' -> ' .. hit.path
      end
    end
  end
  return true
end

T.case('related notes of the fixture come from the same topic', function()
  with_fixture(function(root)
    local ok, where = related_stay_in_topic(root)
    T.ok(ok, where)
  end)
end)

T.case('counter-proof: vectors that ignore the topic make the related check fail', function()
  with_fixture(function(root)
    T.eq((related_stay_in_topic(root)), false)
  end, {
    -- the axis follows the position in the list, not the folder
    rule = function(_, nth)
      local v = { 0, 0, 0, 0, 0, 0, 0, 0 }
      v[(nth % 5) + 1] = 120
      return v
    end,
  })
end)

-- Exactly the notes with a body of 201 to 800 UTF-16 units (measured 2026-10-26: 17 of 20); the probe
-- needs three. Pinned, so that cutting a note below the window shows up here.
T.case('the fixture has seventeen notes of 201 to 800 UTF-16 units for the probe', function()
  with_fixture(function(root, paths)
    T.eq(#probe.select(root, paths, 40), 17)
  end)
end)

T.case('counter-proof: a vault without its note bodies has no probe candidates', function()
  with_fixture(function(root, paths)
    T.eq(#probe.select(root, paths, 40), 0)
  end, {
    before = function(root)
      for _, p in ipairs(vim.fn.globpath(root, '**/*.md', false, true)) do
        vim.fn.writefile({ 'short' }, p)
      end
    end,
  })
end)
