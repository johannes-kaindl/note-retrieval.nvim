-- domain: note_retrieval
-- The model chosen per server, remembered across sessions: stdpath('state')/note-retrieval/state.json,
-- { "models": { "<endpoint url>": "<model id>" } }, through the kit's store (atomic, re-read
-- before every write, a broken file set aside).
local store = require('note_retrieval.kit.store')

local M = {}

function M.path()
  return vim.fn.stdpath('state') .. '/note-retrieval/state.json'
end

--- The remembered model for an endpoint URL, or nil.
function M.model(url)
  local ok, value = pcall(store.read, M.path(), { expect = 'object' })
  if not ok or type(value) ~= 'table' or type(value.models) ~= 'table' then
    return nil
  end
  local id = value.models[url]
  return type(id) == 'string' and id or nil
end

--- Remember id as the model for an endpoint URL.
function M.set_model(url, id)
  store.update(M.path(), function(value)
    value = type(value) == 'table' and value or vim.empty_dict()
    if type(value.models) ~= 'table' or vim.islist(value.models) and next(value.models) ~= nil then
      value.models = vim.empty_dict()
    end
    value.models[url] = id
    return value
  end, { expect = 'object' })
end

return M
