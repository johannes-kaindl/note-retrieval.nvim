-- domain: note_retrieval
-- The self-find probe (spec 6.4): take a stable, scattered sample of notes that are in the index,
-- search with the first 300 UTF-16 units of each note's own text through the same search as
-- `:NoteRetrieval search`, and expect the note itself at rank 0. A meaning check, not a form check:
-- a checksum says the index is consistent, this says it finds what it holds. The rule (sample
-- order, window 200 < len <= 800, 300-unit query) is the kit's `probe`; this module reads the notes,
-- asks the search one query after another and counts. It only reads: nothing here writes to the index.
local index = require('note_retrieval.index')
local kit = require('note_retrieval.kit.probe')
local messages = require('note_retrieval.messages')
local search = require('note_retrieval.search')

local M = {}

M.SEED = kit.SEED
M.N = kit.N
--- Sample size of the run that follows a full reindex (option `probe_auto`).
M.AUTO_N = 8

-- How many files a scan step reads before it hands the main loop back (reading is cheap, not free).
local SCAN_BUDGET = 200

--- The index paths in probe order: the kit's stable, scattered order for `seed` (path and seed only,
--- so a note added to the vault slots in between the old ones).
---@param paths string[]
---@param seed? integer
---@return string[]
function M.order(paths, seed)
  local files = {}
  for i, p in ipairs(paths) do
    files[i] = { path = p }
  end
  local out = {}
  for i, f in ipairs(kit.order(files, seed or M.SEED)) do
    out[i] = f.path
  end
  return out
end

--- The query for the note at `root/path`: the first 300 units of its body, or nil when the note is
--- no candidate (unreadable, or a body of 200 or fewer or more than 800 UTF-16 units).
---@param root string
---@param path string vault-relative
---@return string|nil
function M.query_of(root, path)
  local f = io.open(root .. '/' .. path, 'rb')
  if not f then
    return nil
  end
  local text = f:read('*a')
  f:close()
  return kit.query(text or '')
end

--- A scan over the candidates of an index: `next(budget)` reads at most `budget` notes in probe order
--- and returns `{ path, query }, true` for the next candidate, `nil, true` when the budget ran out
--- first (call again) and `nil, false` when the notes are used up. A note the index does not know is
--- never read: `paths` are the index's row paths.
---@param root string
---@param paths string[]
---@param seed? integer
---@return fun(budget: integer): table|nil, boolean
function M.scanner(root, paths, seed)
  local ordered = M.order(paths, seed)
  local pos = 0
  return function(budget)
    while pos < #ordered do
      if budget <= 0 then
        return nil, true
      end
      pos = pos + 1
      budget = budget - 1
      local query = M.query_of(root, ordered[pos])
      if query then
        return { path = ordered[pos], query = query }, true
      end
    end
    return nil, false
  end
end

--- The first `n` candidates of `paths` in probe order, all at once (no yielding): for tests and
--- tools; `run` scans in steps.
---@param root string
---@param paths string[]
---@param n? integer
---@param seed? integer
---@return table[] { { path, query } }
function M.select(root, paths, n, seed)
  local scan = M.scanner(root, paths, seed)
  local out = {}
  while #out < (n or M.N) do
    local cand = scan(math.huge)
    if not cand then
      break
    end
    out[#out + 1] = cand
  end
  return out
end

-- The rank of `path` among the hits (0 = first), nil when it is not among them.
local function rank_of(results, path)
  for i, hit in ipairs(results) do
    if hit.path == path then
      return i - 1
    end
  end
end

--- Runs the probe on the index of `root`: up to `opts.n` (default `M.N`) candidates of the loaded
--- index, each searched with its own text, one after another (the next query goes out when the
--- answer to the last is in, never two at a time; the main loop is handed back between queries).
--- `opts = { n, seed }`. Calls `cb(result)` with `{ n, hits, rate, failures = { { path, rank, top } },
--- seed, model }` (`n` the notes probed, which can be fewer than asked; `rank` nil when the note is
--- not among the hits; `top` the best hit's path), or `cb(nil, err, partial)` with `err` the error
--- value of the search (`{ kind, detail }`) and `partial` what was counted so far. It reads only.
---@param root string
---@param opts? { n?: integer, seed?: integer }
---@param cb fun(result?: table, err?: table, partial?: table)
function M.run(root, opts, cb)
  opts = opts or {}
  local want = opts.n or M.N
  local seed = opts.seed or M.SEED
  local loaded, why = index.current(root)
  if not loaded then
    return cb(nil, { kind = 'no-index', detail = why })
  end
  local scan = M.scanner(root, loaded.paths, seed)
  local result = {
    n = 0,
    hits = 0,
    rate = 0,
    failures = {},
    seed = seed,
    model = loaded.manifest and loaded.manifest.embedding_model or nil,
  }
  local function finish()
    result.rate = result.n > 0 and result.hits / result.n or 0
    cb(result)
  end
  local function step()
    if result.n >= want then
      return finish()
    end
    local cand, more = scan(SCAN_BUDGET)
    if not cand then
      if more then
        return vim.schedule(step)
      end
      return finish()
    end
    search.search(cand.query, { root = root }, function(results, err)
      if not results then
        return cb(nil, err, result)
      end
      local rank = rank_of(results, cand.path)
      result.n = result.n + 1
      if rank == 0 then
        result.hits = result.hits + 1
      else
        result.failures[#result.failures + 1] = {
          path = cand.path,
          rank = rank,
          top = results[1] and results[1].path or nil,
        }
      end
      vim.schedule(step)
    end)
  end
  step()
end

--- The result as one JSON line (`rank` and `top` are null when there is none).
---@param result table
---@return string
function M.json(result)
  local failures = {}
  for i, f in ipairs(result.failures) do
    failures[i] =
      { path = f.path, rank = f.rank == nil and vim.NIL or f.rank, top = f.top == nil and vim.NIL or f.top }
  end
  return vim.json.encode({
    n = result.n,
    hits = result.hits,
    rate = result.rate,
    failures = failures,
    seed = result.seed,
    model = result.model == nil and vim.NIL or result.model,
  })
end

--- The lines to show: `x/n on rank 0` and one line per failure (path, rank found or "not found",
--- best hit). Without a candidate it says so and names the window.
---@param result table
---@return string[]
function M.lines(result)
  if result.n == 0 then
    return {
      'note-retrieval: probe: no note in the index has a text between 201 and 800 characters to search with',
    }
  end
  local lines = { ('note-retrieval: probe: %d/%d on rank 0'):format(result.hits, result.n) }
  for _, f in ipairs(result.failures) do
    lines[#lines + 1] = ('  %s: %s, best hit %s'):format(
      f.path,
      f.rank and ('rank ' .. f.rank) or 'not found',
      f.top or 'none'
    )
  end
  return lines
end

--- The run after a full reindex in mode eigen (option `probe_auto`): `M.AUTO_N` notes, one short
--- message. It does nothing while a writer run is active in `root`, says nothing when no note
--- qualifies, and reports a search that fails instead of raising.
---@param root string
function M.auto(root)
  local ok = pcall(function()
    if require('note_retrieval.indexer').status(root).running then
      return
    end
    M.run(root, { n = M.AUTO_N }, function(result, err, partial)
      if not result then
        local done = partial and partial.n or 0
        return vim.notify(
          ('note-retrieval: probe after the reindex stopped after %d notes: %s'):format(
            done,
            messages.sentence(err, { mode = 'eigen' })
          ),
          vim.log.levels.WARN
        )
      end
      if result.n == 0 then
        return
      end
      local missed = #result.failures
      vim.notify(
        ('note-retrieval: probe after the reindex: %d/%d on rank 0%s'):format(
          result.hits,
          result.n,
          missed > 0 and ' (:NoteRetrieval probe lists the misses)' or ''
        ),
        missed > 0 and vim.log.levels.WARN or vim.log.levels.INFO
      )
    end)
  end)
  if not ok then
    vim.notify('note-retrieval: probe after the reindex could not run', vim.log.levels.WARN)
  end
end

return M
