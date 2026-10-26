-- domain: note_retrieval
-- What the plugin knows about the vault of the current note, without a server call: root, mode,
-- index, notes, model, age, endpoints. `:NoteRetrieval status` prints it, `require('note_retrieval')
-- .status()` returns it.
local config = require('note_retrieval.config')
local index = require('note_retrieval.index')
local indexer = require('note_retrieval.indexer')
local llm = require('note_retrieval.kit.llm')
local messages = require('note_retrieval.messages')
local roots = require('note_retrieval.roots')
local state = require('note_retrieval.state')

local M = {}

local MODE_TEXT = {
  obsidian = 'obsidian (the index of the Vault Retrieval plugin, read only)',
  eigen = 'eigen (the index of this plugin)',
}

-- The path of a buffer that holds a file, or nil (a scratch buffer such as the panel or the
-- :checkhealth page has none).
local function file_of(buf)
  if buf > 0 and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == '' then
    local name = vim.api.nvim_buf_get_name(buf)
    if name:sub(1, 1) == '/' then
      return name
    end
  end
end

-- The buffers that stand for no note of their own and so take the vault of the buffer you came
-- from: the panel and the :checkhealth page. Any other buffer without a file (a terminal, a scratch
-- buffer, an explorer) says nothing about a vault, and `#` could be one of another vault.
local function is_view(buf)
  if vim.bo[buf].filetype == 'note-retrieval' then
    return true
  end
  -- The page of :checkhealth: its file type is set late, so the name counts too.
  return vim.bo[buf].filetype == 'checkhealth' or vim.api.nvim_buf_get_name(buf):find('^health://') ~= nil
end

--- The vault of the current note: from its file name, else — only when the current buffer is the
--- panel or the :checkhealth page — from the buffer you came from, else from the working directory
--- (the roots option wins, as everywhere). Returns the root, or `nil, message`.
function M.current_root(cfg)
  local buf = vim.api.nvim_get_current_buf()
  local name = file_of(buf)
  if not name and is_view(buf) then
    name = file_of(vim.fn.bufnr('#'))
  end
  return roots.find_root(name, cfg or (config.resolve()))
end

local function now_ms()
  local sec, usec = (vim.uv or vim.loop).gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
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
--- `{ root, root_mode, mode, loaded, index_path, rows, model, model_from, built_at, age, endpoints,
--- reindex, warning, problem, line }`. A field that is unknown is nil; `problem` says in words why
--- (no vault, no index), and `line` is one short line for a status line. `root_mode` is the mode of
--- the vault, read fresh (`mode` is the one of the loaded index); `reindex` is `indexer.status`.
--- Loads the index if it is not loaded yet, unless `opts.load == false`: then an index that is not
--- in memory is not read (`loaded = false`, no `mode`, no `rows`), so the call stays cheap.
---@param opts? { load?: boolean }
---@return table
function M.collect(opts)
  local cfg = config.resolve()
  local out = { loaded = false }
  out.endpoints, out.endpoints_problem = endpoints_of(cfg)
  local root, why = M.current_root(cfg)
  if not root then
    out.problem = why
    out.line = 'note-retrieval: no vault'
    return out
  end
  out.root = root
  out.root_mode = roots.mode(root, cfg)
  out.reindex = indexer.status(root)
  local loaded, msg
  if opts and opts.load == false then
    loaded = index.peek(root)
    if not loaded then
      out.line = 'note-retrieval: index not loaded'
      return out
    end
  else
    loaded, msg = index.current(root, cfg)
  end
  if not loaded then
    out.problem = msg
    out.line = 'note-retrieval: no index'
    return out
  end
  out.warning = msg
  out.loaded = true
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

-- The lock of the index file in words, or nil when nobody holds it.
local function lock_text(lock)
  if lock.state == 'own' then
    return 'held by this Neovim (a write is going on)'
  elseif lock.state == 'other' then
    return ('held by another Neovim for %d s'):format(lock.age or 0)
  elseif lock.state == 'stale' then
    return ('left behind %d s ago by a process that is gone; the next write takes it over'):format(
      lock.age or 0
    )
  end
end

--- The rows about the own index writer: progress of a running reindex, the lock, the last result
--- and the last error (a run whose result was refused shows its embedded count too: the error row
--- says what was not written). Nothing for a vault in mode obsidian (the plugin writes nothing there) and
--- nothing while no reindex ran in this session and the lock is free. `add(label, value)` adds a row.
function M.reindex_lines(info, add)
  local r = info.reindex
  if not r or info.root_mode ~= 'eigen' then
    return
  end
  if r.running then
    add(
      r.kind == 'sync' and 'update' or 'reindex',
      ('%s %d/%d notes (started %s)'):format(
        r.stopping and 'stopping' or 'running',
        r.done,
        r.total,
        ago(math.max(0, now_ms() - (r.started or now_ms())))
      )
    )
  elseif r.indexer then
    add('reindex', 'not running')
  end
  local lock = lock_text(r.lock)
  if lock then
    add('lock', lock)
  end
  if r.report then
    local failed = #(r.report.failed or {})
    add(
      'last run',
      ('%d embedded, %d failed%s'):format(
        r.report.added or 0,
        failed,
        r.report.cancelled and ', stopped early' or ''
      )
    )
    if failed > 0 then
      add('failed', 'those notes are missing from the index; :NoteRetrieval reindex tries them again')
    end
  end
  if r.last_error then
    add('error', tostring(r.last_error))
  end
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
  M.reindex_lines(info, add)
  if info.problem then
    lines[#lines + 1] = ''
    lines[#lines + 1] = messages.sentence(info.problem, { mode = info.root_mode })
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
