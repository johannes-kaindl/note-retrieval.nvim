-- domain: note_retrieval
-- Nothing needs setup(): the options can come from vim.g.note_retrieval. setup(opts) only takes
-- options (:help note-retrieval-options) and reports problems with them; each call replaces the
-- previous one's.
local config = require('note_retrieval.config')

local M = {}

---@param opts? note_retrieval.Config
function M.setup(opts)
  config.set(opts)
  local _, problems = config.resolve()
  if #problems > 0 then
    vim.notify('note-retrieval: ' .. table.concat(problems, '; '), vim.log.levels.WARN)
  end
end

--- The options in effect and the problems found (see note_retrieval.config).
function M.resolve()
  return config.resolve()
end

--- The notes closest to the meaning of `query`, as `cb(results)` (`{ path, score, title }`, best
--- first) or `cb(nil, err)`; `err` is a table `{ kind, … }`, `require('note_retrieval.messages').text(err)`
--- makes a sentence of it. `opts = { k, min_similarity, exclude, root }`; `root` defaults to the
--- vault of the current note.
---@param query string
---@param opts? { k?: integer, min_similarity?: number, exclude?: string[], root?: string }
---@param cb fun(results?: table[], err_or_warning?: table|string)
function M.search(query, opts, cb)
  opts = opts or {}
  if not opts.root then
    local root = require('note_retrieval.status').current_root()
    opts = vim.tbl_extend('force', opts, { root = root })
  end
  require('note_retrieval.search').search(query, opts, cb)
end

--- The notes closest to the note at `path`, from its row in the index (no server call): a list of
--- `{ path, score, title }`, or `nil, message`. `opts` as for `search`.
---@param path string
---@param opts? { k?: integer, min_similarity?: number, exclude?: string[], root?: string }
function M.related(path, opts)
  return require('note_retrieval.search').related(path, opts)
end

--- What the plugin knows about the vault of the current note: `{ root, mode, rows, model, age,
--- endpoints, warning, problem, line }`, `line` one short line for a status line.
function M.status()
  return require('note_retrieval.status').collect()
end

return M
