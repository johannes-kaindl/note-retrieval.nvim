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

return M
