-- domain: note_retrieval
-- :NoteRetrieval {related|search|status|model|reindex|update|stop|reset}. Each subcommand is a function here;
-- the <Plug> mappings of plugin/note_retrieval.lua call the same ones.
local config = require('note_retrieval.config')
local messages = require('note_retrieval.messages')
local roots = require('note_retrieval.roots')

local M = {}

M.SUBCOMMANDS = { 'model', 'reindex', 'related', 'reset', 'search', 'status', 'stop', 'update' }

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
    local mode = roots.mode(root, cfg) -- fresh: it names the next step of a missing index
    local search = require('note_retrieval.search')
    search.search(text, { root = root }, function(results, err)
      if not results then
        return messages.notify(err, { mode = mode })
      end
      if type(err) == 'string' then
        vim.notify(messages.text(err, { mode = mode }), vim.log.levels.WARN)
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
  -- An indexer whose reindex is running keeps its state: forgetting it would lose the run.
  local kept = require('note_retrieval.indexer').reset()
  local note = #kept > 0
      and ('; a reindex is running in %s and was left alone'):format(table.concat(kept, ', '))
    or ''
  vim.notify('note-retrieval: forgot the loaded index and vault settings' .. note, vim.log.levels.INFO)
end

-- Where an error value of the writer is shown: what the person can fix and run again is a
-- warning, what went wrong in the machine (write, backup, server) an error.
local ERROR_KINDS = {
  ['failed'] = true,
  ['write-failed'] = true,
  ['backup-failed'] = true,
  ['unreadable'] = true,
  ['incomplete'] = true,
}

local function show_writer_error(err)
  local level = type(err) == 'table' and ERROR_KINDS[err.kind] and vim.log.levels.ERROR or vim.log.levels.WARN
  vim.notify('note-retrieval: ' .. tostring(err), level)
end

local function report_run(root, report, err)
  if not report then
    return show_writer_error(err)
  end
  local failed = #(report.failed or {})
  local head
  if err then
    -- The run finished but its result was not written: the old index stays.
    return show_writer_error(err)
  elseif report.cancelled then
    head = ('reindex of %s stopped: %d notes indexed so far, the rest of the index is as it was'):format(
      root,
      report.added
    )
  else
    head = ('%d notes indexed in %s'):format(report.added, root)
  end
  if failed > 0 then
    vim.notify(
      ('note-retrieval: %s; %d could not be embedded and are missing from the index (:NoteRetrieval reindex tries again)'):format(
        head,
        failed
      ),
      vim.log.levels.WARN
    )
  else
    vim.notify('note-retrieval: ' .. head, vim.log.levels.INFO)
  end
end

--- :NoteRetrieval reindex — build the index of the vault of the current note again from its notes,
--- in the background (progress in `:NoteRetrieval status` and `indexer.statusline()`). Only in mode
--- eigen: an index of the Obsidian plugin is never written here.
function M.reindex()
  local cfg = options()
  local root, why = require('note_retrieval.status').current_root(cfg)
  if not root then
    return messages.notify({ kind = 'no-index', detail = why })
  end
  local mode, info = roots.mode(root, cfg)
  if not mode then
    return vim.notify('note-retrieval: ' .. tostring(info), vim.log.levels.ERROR)
  end
  if mode == 'obsidian' then
    return vim.notify(
      'note-retrieval: read only here: Obsidian owns the index of '
        .. root
        .. ' (the Vault Retrieval plugin rebuilds it)',
      vim.log.levels.INFO
    )
  end
  local indexer = require('note_retrieval.indexer')
  local running = indexer.status(root)
  if running.running then
    return vim.notify(
      running.kind == 'sync'
          and ('note-retrieval: an update of %s is running (:NoteRetrieval status shows it); reindex when it is done'):format(
            root
          )
        or ('note-retrieval: a reindex of %s is already running (:NoteRetrieval status shows it, :NoteRetrieval stop ends it)'):format(
          root
        ),
      vim.log.levels.WARN
    )
  end
  -- Not before the index header: in mode eigen the model is the option, the remembered one or asked.
  require('note_retrieval.embedder').resolve(cfg, nil, function(resolved, err)
    if not resolved then
      return messages.notify(err, { mode = mode })
    end
    local ix, msg = indexer.for_root(root, { resolved = resolved, dim = resolved.dim, cfg = cfg })
    if not ix then
      return vim.notify('note-retrieval: ' .. tostring(msg), vim.log.levels.WARN)
    end
    vim.notify(
      ('note-retrieval: reindexing %s with the model %s (:NoteRetrieval status shows the progress, :NoteRetrieval stop ends it)'):format(
        root,
        resolved.model
      ),
      vim.log.levels.INFO
    )
    ix:reindex(function(report, rerr)
      report_run(root, report, rerr)
    end)
  end)
end

-- The sentence for the result of an update: "3 embedded, 1 removed, 0 failed".
local function update_sentence(root, result)
  local text = ('%d embedded, %d removed, %d failed'):format(result.embedded, result.removed, #result.failed)
  if result.embedded == 0 and result.removed == 0 and #result.failed == 0 then
    return ('the index of %s is current: nothing to embed or remove'):format(root)
  end
  if #result.failed > 0 then
    return ('update of %s: %s (:NoteRetrieval update tries the failed notes again)'):format(root, text)
  end
  return ('update of %s: %s'):format(root, text)
end

--- :NoteRetrieval update — bring the own index in line with the notes of the vault of the current
--- note: embed the new and changed ones, drop the deleted ones, write once; in the background. Only in
--- mode eigen: an index of the Obsidian plugin is never written here.
function M.update()
  local cfg = options()
  local root, why = require('note_retrieval.status').current_root(cfg)
  if not root then
    return messages.notify({ kind = 'no-index', detail = why })
  end
  local mode, info = roots.mode(root, cfg)
  if not mode then
    return vim.notify('note-retrieval: ' .. tostring(info), vim.log.levels.ERROR)
  end
  if mode == 'obsidian' then
    return vim.notify(
      'note-retrieval: read only here: Obsidian owns the index of '
        .. root
        .. ' (the Vault Retrieval plugin updates it)',
      vim.log.levels.INFO
    )
  end
  local indexer = require('note_retrieval.indexer')
  local running = indexer.status(root)
  if running.running then
    return show_writer_error({
      kind = 'running',
      message = running.kind == 'sync'
          and ('an update of %s is already running (:NoteRetrieval status shows it)'):format(root)
        or ('a reindex of %s is running; update when it is done'):format(root),
    })
  end
  require('note_retrieval.embedder').resolve(cfg, nil, function(resolved, err)
    if not resolved then
      return messages.notify(err, { mode = mode })
    end
    local ix, msg = indexer.for_root(root, { resolved = resolved, dim = resolved.dim, cfg = cfg })
    if not ix then
      return vim.notify('note-retrieval: ' .. tostring(msg), vim.log.levels.WARN)
    end
    vim.notify(
      ('note-retrieval: updating the index of %s with the model %s (:NoteRetrieval status shows the progress)'):format(
        root,
        resolved.model
      ),
      vim.log.levels.INFO
    )
    indexer.sync(root, function(result, rerr)
      if not result then
        return show_writer_error(rerr)
      end
      vim.notify(
        'note-retrieval: ' .. update_sentence(root, result),
        #result.failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO
      )
    end)
  end)
end

--- :NoteRetrieval stop — ask the running reindex of the vault of the current note to stop; what it
--- reached is written, the rest of the index stays as it was.
function M.stop()
  local cfg = options()
  local root, why = require('note_retrieval.status').current_root(cfg)
  if not root then
    return messages.notify({ kind = 'no-index', detail = why })
  end
  if require('note_retrieval.indexer').stop(root) then
    vim.notify(
      ('note-retrieval: stopping the reindex of %s after the notes in flight; what it reached is written'):format(
        root
      ),
      vim.log.levels.INFO
    )
  else
    vim.notify('note-retrieval: no reindex is running in ' .. root, vim.log.levels.INFO)
  end
end

local function endpoint_label(ep)
  return ep.name and ('%s (%s)'):format(ep.url, ep.name) or ep.url
end

-- Asks every configured endpoint for its models, all at once; `cb(answers)` with one entry per
-- endpoint in priority order: `{ ep, models }` or `{ ep, error, detail }`.
local function probe_endpoints(cfg, cb)
  local llm = require('note_retrieval.kit.llm')
  local eps = llm.endpoints({ endpoints = cfg.endpoints })
  local answers, pending = {}, #eps
  for i, ep in ipairs(eps) do
    llm.models(ep, function(r)
      if answers[i] then
        return
      end
      answers[i] = r.error and { ep = ep, error = r.error, detail = r.detail } or { ep = ep, models = r }
      pending = pending - 1
      if pending == 0 then
        cb(answers)
      end
    end)
  end
end

-- The error to show when no endpoint has a model to pick: the first one that answered with an
-- error (a wrong key must not look like a dead server), else the models are missing, else nobody
-- answered.
local function nothing_to_pick(answers)
  local down, empty = {}, nil
  for _, a in ipairs(answers) do
    if a.error == 'unreachable' or a.error == 'timeout' then
      down[#down + 1] = ('%s (%s)'):format(a.ep.url, a.detail)
    elseif a.error then
      return { kind = a.error, detail = ('%s: %s'):format(a.ep.url, a.detail) }
    else
      empty = empty or a.ep.url
    end
  end
  if empty then
    return { kind = 'no-model', detail = empty .. ': the server lists no model' }
  end
  return { kind = 'unreachable', detail = 'no endpoint answered: ' .. table.concat(down, '; ') }
end

--- :NoteRetrieval model — choose the model of an endpoint and remember it for that endpoint. With
--- several endpoints that answer, the endpoint is asked first (the one a run uses, the first that
--- answers, comes first in the list).
function M.model()
  local cfg = options()
  if cfg.endpoints_error then
    return messages.notify({ kind = 'bad-config' })
  end
  probe_endpoints(cfg, function(answers)
    -- The endpoint a run uses: the first that answers; one that answers with an error ends the walk
    -- (as in the embedder), so its error is shown and nothing is asked of the ones behind it.
    local in_use
    local usable = {}
    for _, a in ipairs(answers) do
      if a.error and a.error ~= 'unreachable' and a.error ~= 'timeout' and not in_use then
        return messages.notify({ kind = a.error, detail = ('%s: %s'):format(a.ep.url, a.detail) })
      end
      if not a.error then
        in_use = in_use or a.ep.url
        if #a.models > 0 then
          usable[#usable + 1] = a
        end
      end
    end
    if #usable == 0 then
      return messages.notify(nothing_to_pick(answers))
    end
    local function choose(a)
      local ep = a.ep
      vim.ui.select(a.models, { prompt = 'note-retrieval: model on ' .. ep.url }, function(id)
        if not id then
          return
        end
        local ok, err = pcall(require('note_retrieval.state').set_model, ep.url, id)
        local note = ep.model and (' — this endpoint sets model = %q, which comes first'):format(ep.model)
          or ''
        if ep.url ~= in_use then
          note = note .. (' — %s answers first, so this choice counts only when it does not'):format(in_use)
        end
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
    end
    if #usable == 1 then
      return choose(usable[1])
    end
    vim.ui.select(usable, {
      prompt = 'note-retrieval: choose the model of which endpoint?',
      format_item = function(a)
        return endpoint_label(a.ep) .. (a.ep.url == in_use and ' (used first)' or '')
      end,
    }, function(a)
      if a then
        choose(a)
      end
    end)
  end)
end

--- :NoteRetrieval — o as nvim_create_user_command passes it.
function M.run(o)
  local sub = o.fargs[1]
  if sub == 'search' then
    -- The query is taken from `args` as typed: `fargs` would split it at every blank, and joining it
    -- again would collapse the blanks and lose a backslash.
    return M.search((o.args or ''):match('^%s*%S+%s?(.*)$'))
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
