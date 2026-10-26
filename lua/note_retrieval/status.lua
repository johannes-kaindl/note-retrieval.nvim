-- domain: note_retrieval
-- What the plugin knows about the vault of the current note, without a server call: root, mode,
-- index, notes, model, age, endpoints. `:NoteRetrieval status` prints it, `require('note_retrieval')
-- .status()` returns it.
local config = require('note_retrieval.config')
local index = require('note_retrieval.index')
local llm = require('note_retrieval.kit.llm')
local messages = require('note_retrieval.messages')
local roots = require('note_retrieval.roots')
local state = require('note_retrieval.state')

local M = {}

local MODE_TEXT = {
  obsidian = 'obsidian (the index of the Vault Retrieval plugin, read only)',
  eigen = 'eigen (the index of this plugin)',
}

--- The vault of the current note: from its file name, else from the working directory (the roots
--- option wins, as everywhere). Returns the root, or `nil, message`.
function M.current_root(cfg)
  local name = vim.api.nvim_buf_get_name(0)
  return roots.find_root(name:sub(1, 1) == '/' and name or nil, cfg or (config.resolve()))
end

-- "3 days ago" and the like for a number of milliseconds.
local function ago(ms)
  local minutes = math.floor(ms / 60000)
  if minutes < 1 then
    return 'just now'
  elseif minutes < 120 then
    return ('%d min ago'):format(minutes)
  elseif minutes < 48 * 60 then
    return ('%d h ago'):format(math.floor(minutes / 60))
  end
  return ('%d days ago'):format(math.floor(minutes / 1440))
end

local function endpoints_of(cfg)
  if cfg.endpoints_error then
    return nil, 'invalid: ' .. cfg.endpoints_error
  end
  local out = {}
  for _, ep in ipairs(llm.endpoints({ endpoints = cfg.endpoints })) do
    out[#out + 1] = ep.name and ('%s (%s)'):format(ep.url, ep.name) or ep.url
  end
  return out
end

--- The state of the vault of the current note, for `:NoteRetrieval status` and the Lua API:
--- `{ root, mode, index_path, rows, model, model_from, built_at, age, endpoints, warning, problem,
--- line }`. A field that is unknown is nil; `problem` says in words why (no vault, no index), and
--- `line` is one short line for a status line. Loads the index if it is not loaded yet.
---@return table
function M.collect()
  local cfg = config.resolve()
  local out = {}
  out.endpoints, out.endpoints_problem = endpoints_of(cfg)
  local root, why = M.current_root(cfg)
  if not root then
    out.problem = why
    out.line = 'note-retrieval: no vault'
    return out
  end
  out.root = root
  local loaded, msg = index.current(root, cfg)
  if not loaded then
    out.problem = msg
    out.line = 'note-retrieval: no index'
    return out
  end
  out.warning = msg
  out.mode = loaded.mode
  out.index_path = loaded.path
  out.rows = loaded.index.count
  out.built_at = loaded.manifest.built_at
  if loaded.built_ms then
    out.age = ago(os.time() * 1000 - loaded.built_ms)
  end
  if loaded.mode == 'obsidian' then
    out.model, out.model_from = loaded.manifest.embedding_model, 'the index header'
  elseif cfg.embedding_model then
    out.model, out.model_from = cfg.embedding_model, 'the option embedding_model'
  elseif out.endpoints and out.endpoints[1] then
    local first = llm.endpoints({ endpoints = cfg.endpoints })[1]
    out.model = state.model(first.url) or first.model
    out.model_from = out.model and 'the choice remembered for ' .. first.url or nil
  end
  out.line = ('note-retrieval: %s, %d notes'):format(loaded.mode, out.rows)
  return out
end

--- The lines `:NoteRetrieval status` prints for a `collect` result.
---@param info table
---@return string[]
function M.lines(info)
  local lines = { 'note-retrieval status' }
  local function add(label, value)
    lines[#lines + 1] = ('  %-10s %s'):format(label .. ':', value)
  end
  if info.root then
    add('root', info.root)
  end
  if info.mode then
    add('mode', MODE_TEXT[info.mode] or info.mode)
    add('index', info.index_path)
    add('notes', tostring(info.rows))
    add(
      'model',
      info.model and ('%s (%s)'):format(info.model, info.model_from)
        or 'not chosen yet (asked on the first search)'
    )
    add(
      'built',
      info.age and ('%s (%s)'):format(info.built_at, info.age) or tostring(info.built_at or 'unknown')
    )
  end
  if info.endpoints then
    add('endpoint', table.concat(info.endpoints, ', ') .. ' (the first that answers is used)')
  else
    add('endpoint', info.endpoints_problem)
  end
  if info.problem then
    lines[#lines + 1] = ''
    lines[#lines + 1] = messages.sentence(info.problem)
  end
  if info.warning then
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'warning: ' .. info.warning
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] =
    'The index and the vault settings are read once per session; :NoteRetrieval reset reads them again.'
  return lines
end

return M
