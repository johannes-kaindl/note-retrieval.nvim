-- domain: note_retrieval
-- The model chosen per server, remembered across sessions: stdpath('state')/note-retrieval/state.json,
-- { "models": { "<endpoint url>": "<model id>" } }. The behaviour lives in the kit's endpoint_model
-- (model, set_model, choose, path); this file only says where the state file is.
return require('note_retrieval.kit.endpoint_model').new(function()
  return vim.fn.stdpath('state') .. '/note-retrieval/state.json'
end, { prompt_prefix = 'note-retrieval' })
