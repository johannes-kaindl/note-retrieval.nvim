-- domain: note_retrieval
-- One sentence per error, with the next step. Every error value of the plugin goes through
-- `text`: the strings that `search.related` and the index return, and the tables `{ kind, … }` of
-- `search.search` and the embedder (their own kinds and those of the kit's llm). Nothing here
-- decides anything; callers show the sentence.
local roots = require('note_retrieval.roots')

local M = {}

local LIST_MAX = 5

-- 'a, b, c' for a list of model names: the first few, then how many more; 'none' when empty.
local function names(list)
  if type(list) ~= 'table' or #list == 0 then
    return 'none'
  end
  local shown = {}
  for i = 1, math.min(#list, LIST_MAX) do
    shown[i] = '"' .. tostring(list[i]) .. '"'
  end
  local out = table.concat(shown, ', ')
  if #list > LIST_MAX then
    out = ('%s and %d more'):format(out, #list - LIST_MAX)
  end
  return out
end

local function with_detail(text, err)
  local detail = err.detail
  if type(detail) == 'string' and detail ~= '' and detail ~= err.kind then
    return ('%s (%s)'):format(text, detail)
  end
  return text
end

-- Kinds that carry their own fields say all of it in the sentence; the others append `detail`.
local FIELDS = {
  ['model-mismatch'] = function(e)
    return (
      'Search is off: this index was built with the model "%s", and the server offers %s. Related'
      .. ' notes still work. Load "%s" on the server (the same name), or use a server that has it.'
    ):format(tostring(e.index_model), names(e.endpoint_models), tostring(e.index_model))
  end,
  ['model-missing'] = function(e)
    return (
      'The model "%s" (option embedding_model) is not offered by the server, which has %s. Pull it'
      .. ' into the server, or change embedding_model.'
    ):format(tostring(e.model), names(e.endpoint_models))
  end,
}

local TEXT = {
  ['no-model-chosen'] = 'No model chosen, so nothing was searched. Run :NoteRetrieval model to choose one.',
  ['no-model'] = 'The server has no model to embed with. Pull an embedding model (for example'
    .. ' "ollama pull nomic-embed-text"), then run :NoteRetrieval model.',
  ['bad-config'] = 'The options are invalid; :checkhealth note_retrieval lists the problems.',
  ['unreachable'] = 'No embedding server answered. Start Ollama or LM Studio, or set endpoints'
    .. ' (:help note-retrieval-option-endpoints).',
  ['timeout'] = 'The server did not answer in time. Check that the model is loaded, or raise timeout_ms'
    .. ' (:help note-retrieval-option-timeout_ms).',
  ['key-missing'] = 'The API key of this endpoint could not be read (api_key_env or api_key_cmd).',
  ['http'] = 'The server refused the request. Check the endpoint and the model name.',
  ['bad-response'] = 'The server answered with something that is no embedding. Check that the endpoint speaks'
    .. ' the OpenAI API (/v1/embeddings) and that the model is an embedding model.',
  ['cancelled'] = 'Cancelled.',
}

-- The next step for a missing or unusable index. In mode own the plugin builds the index
-- itself; in mode obsidian (or when the mode is not known) it only says where to look.
local function no_index_step(mode)
  if mode == 'own' then
    return 'Run :NoteRetrieval reindex to build it (:checkhealth note_retrieval shows which index is looked for).'
  end
  return 'Run :checkhealth note_retrieval to see which index is looked for.'
end

local function of_string(msg, mode)
  if msg == roots.NO_ROOT then
    return msg
  end
  -- Loaded here, not on top: the search module brings the index in, and a command that fails
  -- early (an unknown subcommand) must not.
  if msg == require('note_retrieval.search').NO_ROW then
    local text = msg .. '. It is new, was left out, or the index is older than the note.'
    if mode == 'own' then
      text = text .. ' :NoteRetrieval reindex brings the index up to date.'
    end
    return text
  end
  return msg .. '. ' .. no_index_step(mode)
end

local function of_table(err, mode)
  local kind = err.kind
  if kind == 'no-root' or (kind == 'no-index' and err.detail == roots.NO_ROOT) then
    return roots.NO_ROOT
  end
  if kind == 'no-index' then
    return of_string(tostring(err.detail or 'no index'), mode)
  end
  if FIELDS[kind] then
    return FIELDS[kind](err)
  end
  if TEXT[kind] then
    return with_detail(TEXT[kind], err)
  end
  return with_detail(('Unexpected error: %s.'):format(tostring(kind)), err)
end

--- The sentence for an error value, without the plugin's name (for :checkhealth, which has its own
--- heading). `opts.mode` is the mode of the vault the error is about, when the caller knows it: in
--- mode `own` the hints for a missing index and a missing row name `:NoteRetrieval reindex`.
---@param err string|table a message from `related`/the index, or `{ kind, detail, … }`
---@param opts? { mode?: string }
---@return string
function M.sentence(err, opts)
  local mode = opts and opts.mode
  if type(err) == 'string' then
    return of_string(err, mode)
  elseif type(err) == 'table' then
    return of_table(err, mode)
  end
  return 'Unexpected error: ' .. tostring(err) .. '.'
end

--- The sentence for an error value, `note-retrieval: …`.
---@param err string|table
---@param opts? { mode?: string }
---@return string
function M.text(err, opts)
  return 'note-retrieval: ' .. M.sentence(err, opts)
end

--- Shows the sentence of `err` (`vim.notify`, error level; "cancelled" is information).
function M.notify(err, opts)
  local cancelled = type(err) == 'table' and err.kind == 'cancelled'
  vim.notify(M.text(err, opts), cancelled and vim.log.levels.INFO or vim.log.levels.ERROR)
end

return M
