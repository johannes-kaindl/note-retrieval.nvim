-- domain: note_retrieval
-- :NoteRetrieval {related|search|status|model|reset}. Each subcommand is a function here;
-- the <Plug> mappings of plugin/note_retrieval.lua call the same ones.
local config = require('note_retrieval.config')
local messages = require('note_retrieval.messages')

local M = {}

M.SUBCOMMANDS = { 'model', 'related', 'reset', 'search', 'status' }

local reported -- the option problems last shown, so a run does not repeat them every time

-- The options in effect; their problems are shown once (until they change).
local function options()
  local cfg, problems = config.resolve()
  local key = table.concat(problems, '\n')
  if #problems > 0 and key ~= reported then
    vim.notify('note-retrieval: ' .. table.concat(problems, '; '), vim.log.levels.WARN)
  end
  reported = key
  return cfg
end

--- :NoteRetrieval related — the panel with the notes related to the current one, open or closed.
function M.related()
  options()
  require('note_retrieval.panel').toggle()
end

--- :NoteRetrieval search [query] — embed the query, pick one of the closest notes, open it.
--- Without a query it asks for one.
---@param query? string
function M.search(query)
  local cfg = options()
  local function run(text)
    text = vim.trim(text or '')
    if text == '' then
      return
    end
    local root, why = require('note_retrieval.status').current_root(cfg)
    if not root then
      return messages.notify({ kind = 'no-index', detail = why })
    end
    local search = require('note_retrieval.search')
    search.search(text, { root = root }, function(results, err)
      if not results then
        return messages.notify(err)
      end
      if type(err) == 'string' then
        vim.notify(messages.text(err), vim.log.levels.WARN)
      end
      search.pick(results, { root = root })
    end)
  end
  if query and vim.trim(query) ~= '' then
    return run(query)
  end
  vim.ui.input({ prompt = 'Search notes: ' }, run)
end

--- The text selected in Visual mode (all three kinds), lines joined with a newline.
---@return string
function M.selection()
  local mode = vim.fn.mode()
  return table.concat(vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = mode }), '\n')
end

--- <Plug>(note-retrieval-search) in Visual mode: the selection is the query.
function M.search_selection()
  local text = M.selection()
  vim.cmd('normal! ' .. vim.keycode('<Esc>'))
  M.search(text)
end

--- :NoteRetrieval status — where the notes are, which index, which model, how old, which server.
function M.status()
  options()
  local status = require('note_retrieval.status')
  vim.notify(table.concat(status.lines(status.collect()), '\n'), vim.log.levels.INFO)
end

--- :NoteRetrieval reset — forget the index and the vault settings held in memory; the next command
--- reads them again (after editing data.json of the Obsidian plugin, say).
function M.reset()
  require('note_retrieval.index').reset()
  vim.notify('note-retrieval: forgot the loaded index and vault settings', vim.log.levels.INFO)
end

--- :NoteRetrieval model — list the models of the first server that answers and remember the choice.
function M.model()
  local cfg = options()
  if cfg.endpoints_error then
    return messages.notify({ kind = 'bad-config' })
  end
  local llm = require('note_retrieval.kit.llm')
  llm.resolve({ endpoints = cfg.endpoints }, function(r)
    if r.error and r.error ~= 'no-model' then
      return messages.notify({ kind = r.error, detail = r.detail })
    end
    if not r.models or #r.models == 0 then
      return messages.notify({ kind = 'no-model', detail = r.detail })
    end
    local ep = r.endpoint
    vim.ui.select(r.models, { prompt = 'note-retrieval: model on ' .. ep.url }, function(id)
      if not id then
        return
      end
      local ok, err = pcall(require('note_retrieval.state').set_model, ep.url, id)
      local note = ep.model and (' — this endpoint sets model = %q, which comes first'):format(ep.model)
        or ''
      -- An Obsidian index decides the model of a search: say so rather than let the choice mislead.
      local root = require('note_retrieval.status').current_root(cfg)
      local loaded = root and require('note_retrieval.index').current(root, cfg)
      if loaded and loaded.mode == 'obsidian' then
        note = ("%s — this vault's index was built with %q, and a search uses that one"):format(
          note,
          tostring(loaded.manifest.embedding_model)
        )
      end
      if not ok then
        note = note .. ' — but it could not be remembered: ' .. tostring(err)
      end
      vim.notify(('note-retrieval: model on %s: %s%s'):format(ep.url, id, note), vim.log.levels.INFO)
    end)
  end)
end

--- :NoteRetrieval — o as nvim_create_user_command passes it.
function M.run(o)
  local sub = o.fargs[1]
  if sub == 'search' then
    return M.search(table.concat(o.fargs, ' ', 2))
  elseif sub and vim.tbl_contains(M.SUBCOMMANDS, sub) then
    return M[sub]()
  end
  local why = sub and ('unknown subcommand %q'):format(sub) or 'a subcommand is needed'
  vim.notify(
    ('note-retrieval: %s (%s; see :help :NoteRetrieval)'):format(why, table.concat(M.SUBCOMMANDS, ', ')),
    vim.log.levels.ERROR
  )
end

function M.complete(arglead, cmdline)
  -- Only the subcommand completes: after it come free words (the query) or nothing.
  local before = (cmdline or ''):sub(1, #(cmdline or '') - #arglead)
  if #vim.split(vim.trim(before), '%s+') > 1 then
    return {}
  end
  return vim.tbl_filter(function(c)
    return c:find(arglead, 1, true) == 1
  end, M.SUBCOMMANDS)
end

return M
