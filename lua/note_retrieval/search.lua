-- domain: note_retrieval
-- Related notes and search over the loaded index. `related` reads the note's own row (no
-- endpoint call); `search` embeds the query once. Both answer `{ path, score, title }` lists,
-- best first. Rows whose file is gone are left out of what is returned (an index can name notes
-- that were deleted or moved since it was built), so a pick never opens a missing note.
local config = require('note_retrieval.config')
local embedder = require('note_retrieval.embedder')
local index = require('note_retrieval.index')
local roots = require('note_retrieval.roots')
local vectors = require('note_retrieval.kit.vectors')

local uv = vim.uv or vim.loop

local M = {}

M.NO_ROW = 'no row for this note in the index'
M.NO_RESULTS = 'no matching notes'

-- Where the vault is: the `root` option, else the vault `start` lies in.
local function find_root(start, opts)
  if opts.root then
    return vim.fs.normalize(opts.root)
  end
  return roots.find_root(start, (config.resolve()))
end

-- The vault's own exclude prefixes (what the index resolved for its root: data.json in mode
-- obsidian, the option in mode eigen) plus the ones the caller passes.
local function excludes(loaded, opts)
  local out = {}
  for _, p in ipairs(loaded.info and loaded.info.exclude or {}) do
    out[#out + 1] = p
  end
  for _, p in ipairs(opts.exclude or {}) do
    out[#out + 1] = p
  end
  return out
end

-- The title is the file name without `.md` (spec 5.3): no file is read for it.
local function title_of(path)
  return (vim.fs.basename(path):gsub('%.md$', ''))
end

-- How many results `k` asks for: a whole number, 0 for anything that is not a number of at least 1.
local function count_of(k)
  if type(k) ~= 'number' or k ~= k or k < 1 then
    return 0
  end
  return math.floor(k)
end

-- The ranking of the whole index (`rank()` returns every hit, best first) cut to the first `k`
-- whose file exists: the hits are stat-ed from the top and only until `k` are found, so the
-- cost is one rank plus a few stats, never a stat of the whole index. Rows whose file is gone
-- are dropped.
local function live_hits(root, k, rank)
  k = count_of(k)
  if k == 0 then
    return {}
  end
  local out = {}
  for _, hit in ipairs(rank()) do
    if uv.fs_stat(root .. '/' .. hit.path) then
      out[#out + 1] = { path = hit.path, score = hit.score, title = title_of(hit.path) }
      if #out == k then
        break
      end
    end
  end
  return out
end

-- The options of the kit's rank: every hit (the cut to `k` is `live_hits`' job).
local function rank_opts(loaded, opts)
  local cfg = (config.resolve())
  return {
    k = loaded.index.count,
    min_sim = opts.min_similarity or cfg.min_similarity,
    exclude = excludes(loaded, opts),
  }
end

--- The notes closest to the note at `path` (vault-relative, or absolute inside the vault), from
--- its row in the index: no endpoint call. `opts = { k, min_similarity, exclude, root }` (`k` and
--- `min_similarity` default to the options in effect, `exclude` adds prefixes to the vault's own,
--- `root` names the vault, else it is found from the path). Returns `{ { path, score, title } }`,
--- the note itself left out; `nil, message` without a vault, an index or a row for the note
--- (`M.NO_ROW`). A second result on success is a warning about the index (a torn reload).
---@param path string
---@param opts? { k?: integer, min_similarity?: number, exclude?: string[], root?: string }
function M.related(path, opts)
  opts = opts or {}
  local root, why = find_root(path:sub(1, 1) == '/' and path or nil, opts)
  if not root then
    return nil, why
  end
  local rel = vim.fs.normalize(path)
  if vim.startswith(rel, root .. '/') then
    rel = rel:sub(#root + 2)
  end
  local loaded, warning = index.current(root)
  if not loaded then
    return nil, warning
  end
  if not loaded.index.rows[rel] then
    return nil, M.NO_ROW
  end
  local k = opts.k or (config.resolve()).k
  return live_hits(root, k, function()
    return vectors.related(loaded.index, rel, rank_opts(loaded, opts))
  end),
    warning
end

--- The notes closest to the meaning of `query`: one embedding call for the text, then the rank
--- over the index. Unlike `related`, no note is left out. `opts` as for `related` (`root` defaults
--- to the vault of the working directory). Calls `cb(results)` or `cb(nil, err)`, `err` a table
--- `{ kind, … }`: the embedder's (`model-mismatch` when the index of the Obsidian plugin was built
--- with a model the server does not serve — search is off then, `related` still works) or
--- `{ kind = 'no-index', detail }`. As for `related`, a second argument on success is the warning
--- about the index (a torn reload; the index loaded earlier answered).
---@param query string
---@param opts? { k?: integer, min_similarity?: number, exclude?: string[], root?: string }
---@param cb fun(results?: table[], err_or_warning?: table|string)
function M.search(query, opts, cb)
  opts = opts or {}
  local cfg = (config.resolve())
  local root, why = find_root(nil, opts)
  if not root then
    return cb(nil, { kind = 'no-index', detail = why })
  end
  local loaded, msg = index.current(root)
  local warning = loaded and msg
  if not loaded then
    return cb(nil, { kind = 'no-index', detail = msg })
  end
  -- Only an index that is not ours to change binds the model to its header.
  local manifest = loaded.mode == 'obsidian' and loaded.manifest or nil
  embedder.resolve(cfg, manifest, function(resolved, err)
    if not resolved then
      return cb(nil, err)
    end
    embedder.query(resolved, query, function(vector, qerr)
      if not vector then
        return cb(nil, qerr)
      end
      cb(
        live_hits(root, opts.k or cfg.k, function()
          return vectors.search(loaded.index, vector, rank_opts(loaded, opts))
        end),
        warning
      )
    end)
  end)
end

--- Shows `results` with `vim.ui.select`, one line per note ("0.82  Title — Folder"), and opens
--- the chosen one. `opts.root` names the vault (default: the one of the working directory).
---@param results table[]
---@param opts? { root?: string }
function M.pick(results, opts)
  opts = opts or {}
  if #results == 0 then
    vim.notify(M.NO_RESULTS, vim.log.levels.INFO)
    return
  end
  local root = find_root(nil, opts)
  if not root then
    vim.notify('note-retrieval: no notes folder found', vim.log.levels.WARN)
    return
  end
  vim.ui.select(results, {
    prompt = 'Related notes',
    format_item = function(hit)
      local dir = vim.fs.dirname(hit.path)
      return ('%.2f  %s%s'):format(hit.score, hit.title, dir ~= '.' and ' — ' .. dir or '')
    end,
  }, function(choice)
    if choice then
      vim.cmd.edit(vim.fn.fnameescape(root .. '/' .. choice.path))
    end
  end)
end

return M
