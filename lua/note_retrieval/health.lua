-- domain: note_retrieval
-- :checkhealth note_retrieval — what to check first when something does not work. Diagnosis only:
-- it reads the index and asks each configured server for its model list; it writes nothing and
-- never loads the index into the plugin's memory. A key is reported as readable or not, never shown.
local config = require('note_retrieval.config')
local guard = require('note_retrieval.kit.index_guard')
local index = require('note_retrieval.index')
local kit = require('note_retrieval.kit.health')
local llm = require('note_retrieval.kit.llm')
local messages = require('note_retrieval.messages')
local roots = require('note_retrieval.roots')
local state = require('note_retrieval.state')
local status = require('note_retrieval.status')
local wait = require('note_retrieval.kit.wait')

local M = {}

--- Whether LuaJIT's `ffi` exists (the ranking is faster with it). A field so a test can say no.
function M.has_ffi()
  return (pcall(require, 'ffi'))
end

local function models(ep)
  local result, answered, handle = wait.result(function(cb)
    return llm.models(ep, cb)
  end, llm.PING_TIMEOUT_MS + 1000)
  if not answered then
    if handle then
      handle.cancel() -- stop the request; its late answer is ignored
    end
    return { error = 'timeout', detail = 'no answer' }
  end
  return result
end

local function tools()
  vim.health.start('note-retrieval: Neovim and tools')
  kit.neovim('0.10')
  if vim.fn.executable('curl') == 1 then
    vim.health.ok('curl (talks to the embedding server)')
  else
    vim.health.error(
      'curl not found on PATH',
      { 'Install curl; search sends its requests with it. Related notes work without it.' }
    )
  end
  if M.has_ffi() then
    vim.health.ok('ffi (LuaJIT): the ranking uses native vectors')
  else
    vim.health.warn('no ffi: this Neovim is built without LuaJIT', {
      'The ranking falls back to Lua tables, which works but is slower on a large vault.',
      'Use a Neovim built with LuaJIT (the standard builds are).',
    })
  end
end

local function options()
  vim.health.start('note-retrieval: options')
  local cfg, problems = config.resolve()
  if #problems == 0 then
    vim.health.ok('no problems')
  end
  for _, p in ipairs(problems) do
    if p:match('^endpoints:') then
      vim.health.error(p, { 'See :help note-retrieval-option-endpoints.' })
    else
      vim.health.warn(p, { 'See :help note-retrieval-options.' })
    end
  end
  return cfg
end

-- The vault of the current note and its index; returns the loaded index or nil.
local function vault(cfg)
  vim.health.start('note-retrieval: notes and index')
  local root = status.current_root(cfg)
  if not root then
    vim.health.warn('no notes folder found', {
      messages.sentence({ kind = 'no-root' }),
      'Open a note of the vault first, or set roots.',
    })
    return nil
  end
  vim.health.ok('notes folder: ' .. root)
  local mode, info = roots.mode(root, cfg)
  if not mode then
    vim.health.error(
      info,
      { 'The file belongs to the Vault Retrieval plugin; fix or delete it, then :NoteRetrieval reset.' }
    )
    return nil
  end
  if mode == 'obsidian' then
    vim.health.ok('mode: obsidian (the index of the Vault Retrieval plugin; read only here)')
  else
    vim.health.ok('mode: eigen (the index of this plugin)')
  end
  local path = roots.index_path(root, mode, info)
  local loaded, msg = index.load(root, cfg)
  if not loaded then
    if (vim.uv or vim.loop).fs_stat(path) then
      vim.health.error(
        msg,
        { 'Obsidian writes the file in pieces; try again in a moment, or rebuild the index.' }
      )
    else
      vim.health.warn(msg, {
        mode == 'obsidian' and 'Let the Vault Retrieval plugin build the index in Obsidian.'
          or 'There is no index for this folder yet; the Vault Retrieval plugin of Obsidian can build one.',
      })
    end
    return nil
  end
  vim.health.ok(
    ('index: %s (%d notes, model %s)'):format(
      path,
      loaded.index.count,
      tostring(loaded.manifest.embedding_model)
    )
  )
  return loaded
end

-- The model this run would use on `ep`: the index header in mode obsidian, else the option, the
-- endpoint's own and the remembered one. Returns the model and where it comes from.
local function wanted(cfg, ep, loaded)
  if loaded and loaded.mode == 'obsidian' then
    local model = loaded.manifest.embedding_model
    if type(model) == 'string' and vim.trim(model) ~= '' then
      return vim.trim(model), 'the index header'
    end
  end
  if ep.model then
    return ep.model, 'the endpoint'
  elseif cfg.embedding_model then
    return cfg.embedding_model, 'the option embedding_model'
  end
  local remembered = state.model(ep.url)
  return remembered, 'the remembered choice'
end

local function servers(cfg, loaded)
  vim.health.start('note-retrieval: embedding servers')
  if cfg.endpoints_error then
    vim.health.error('not checked: the endpoints option is invalid')
    return
  end
  local reachable = 0
  for _, ep in ipairs(llm.endpoints({ endpoints = cfg.endpoints })) do
    local label = ep.name and ('%s (%s)'):format(ep.name, ep.url) or ep.url
    local r = models(ep)
    if r.error == 'unreachable' or r.error == 'timeout' then
      vim.health.info(('%s: no answer (%s)'):format(label, r.detail))
    elseif r.error then
      reachable = reachable + 1
      vim.health.error(('%s: %s (%s)'):format(label, r.error, r.detail), {
        r.error == 'key-missing' and 'Set api_key_env or api_key_cmd of this endpoint.'
          or 'Check the endpoint and its key.',
      })
    else
      reachable = reachable + 1
      vim.health.ok(('%s: reachable, %d model%s'):format(label, #r, #r == 1 and '' or 's'))
      local model, from = wanted(cfg, ep, loaded)
      if model and loaded and loaded.mode == 'obsidian' then
        local offered = false
        for _, id in ipairs(r) do
          offered = offered or guard.embedding_model_matches_index(id, model)
        end
        if offered then
          vim.health.ok(('model "%s" (%s) is offered: search works'):format(model, from))
        else
          vim.health.error(
            messages.sentence({ kind = 'model-mismatch', index_model = model, endpoint_models = r }),
            {
              'Related notes work without the server.',
            }
          )
        end
      elseif model and vim.tbl_contains(r, model) then
        vim.health.ok(('model "%s" (%s) is offered'):format(model, from))
      elseif model then
        vim.health.warn(('model "%s" (%s) is not offered by this server'):format(model, from), {
          'Pick another with :NoteRetrieval model, or pull it into the server.',
        })
      elseif #r > 1 then
        vim.health.info('no model chosen yet: the first search asks, or use :NoteRetrieval model')
      end
    end
  end
  if reachable == 0 then
    vim.health.warn('no embedding server answered', {
      'Search needs one; related notes work without. Start Ollama (port 11434) or LM Studio (port 1234), or set endpoints: :help note-retrieval-option-endpoints.',
    })
  end
end

function M.check()
  tools()
  local cfg = options()
  local loaded = vault(cfg)
  servers(cfg, loaded)
  vim.health.start('note-retrieval: vendored')
  local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
  kit.vendored(root .. '/lua/note_retrieval/kit/VENDOR.json', 'nvim-kit')
end

return M
