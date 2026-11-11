-- domain: note_retrieval
-- The embedding model of a run: which server and model, and the two ways text goes to it — one
-- query (`query`) and the notes of the own index (`for_indexer`). Callbacks only, errors are
-- values `{ kind, detail, ... }`.
--
-- A query is embedded exactly as written, with no instruction or prefix in front: Obsidian's
-- index (vault-rag) holds vectors of raw note text, so a prefixed query would lie in another
-- space than the notes it is compared with.
local guard = require('note_retrieval.kit.index_guard')
local live_indexer = require('note_retrieval.kit.live_indexer')
local llm = require('note_retrieval.kit.llm')
local state = require('note_retrieval.state')
local vectors = require('note_retrieval.kit.vectors')

local M = {}

local function failure(res)
  return { kind = res.error, detail = res.detail }
end

-- The model the index header demands, or nil when there is no header model (no index, an old
-- index without the field, a blank name): then nothing is demanded, like the kit's guard.
local function demanded_model(manifest)
  local model = type(manifest) == 'table' and manifest.embedding_model or nil
  if type(model) == 'string' and vim.trim(model) ~= '' then
    return vim.trim(model) -- the name the server is asked for; the guard still compares as JS trim does
  end
end

local function done(cb, r, model, cfg, manifest)
  local dim = type(manifest) == 'table' and manifest.index_dim or nil
  if type(dim) ~= 'number' or dim <= 0 or dim ~= math.floor(dim) then
    dim = nil -- a header without a usable index_dim: the default
  end
  cb({
    endpoint = r.endpoint,
    model = model,
    backend = r.backend,
    models = r.models,
    dim = dim or live_indexer.DEFAULT_INDEX_DIM,
    timeout_ms = cfg.timeout_ms,
  })
end

--- Choose the server and the model. `index_manifest` is the header of the index the run is
--- compared with, or nil: pass it only when the index is not ours to change (mode "obsidian"),
--- since then the model must be the header's — equal after trim, case-sensitive, as
--- `index_guard.embedding_model_matches_index` says. Otherwise the model is `cfg.embedding_model`,
--- else the one remembered for the server, else the person picks one (`vim.ui.select`, remembered).
--- cb(resolved) with resolved = { endpoint, model, backend, models, dim, timeout_ms }
---   | cb(nil, { kind = 'model-mismatch', index_model, endpoint_models })  -- the header model is not served
---   | cb(nil, { kind = 'model-missing', model, endpoint_models })         -- cfg.embedding_model is not served
---   | cb(nil, { kind = 'no-model-chosen', endpoint_models })              -- the picker was dismissed
---   | cb(nil, { kind = 'bad-config' | <llm error kind>, detail })
function M.resolve(cfg, index_manifest, cb)
  if cfg.endpoints_error then
    return cb(nil, { kind = 'bad-config', detail = 'endpoints: ' .. cfg.endpoints_error })
  end
  local index_model = demanded_model(index_manifest)
  llm.resolve({ endpoints = cfg.endpoints, model = index_model or cfg.embedding_model }, function(r)
    if r.error and r.error ~= 'no-model' then
      return cb(nil, failure(r))
    end
    if index_model then
      -- The header decides; a configured model that differs from it is a mismatch too.
      local configured = cfg.embedding_model
      if
        r.error
        or not guard.embedding_model_matches_index(r.model, index_model)
        or (configured and not guard.embedding_model_matches_index(configured, index_model))
      then
        return cb(nil, { kind = 'model-mismatch', index_model = index_model, endpoint_models = r.models })
      end
      return done(cb, r, r.model, cfg, index_manifest)
    end
    local wanted = cfg.embedding_model
    if wanted and r.model ~= wanted and not r.endpoint.model then
      return cb(nil, { kind = 'model-missing', model = wanted, endpoint_models = r.models })
    end
    if not r.error then
      return done(cb, r, r.model, cfg, index_manifest)
    end
    local remembered = state.model(r.endpoint.url)
    if remembered and vim.tbl_contains(r.models, remembered) then
      return done(cb, r, remembered, cfg, index_manifest)
    end
    if #r.models == 0 then
      return cb(nil, { kind = 'no-model', detail = r.detail, endpoint_models = r.models })
    end
    -- A pick that cannot be remembered still arrives (the kit gives cb(id, err)): the run goes on
    -- with the picked model, the write error is of no use here.
    state.choose(r.endpoint, r.models, function(id)
      if not id then
        return cb(nil, { kind = 'no-model-chosen', endpoint_models = r.models })
      end
      done(cb, r, id, cfg, index_manifest)
    end)
  end)
end

--- Embed one search query. One request, the text unchanged; the vector is cut to `resolved.dim`,
--- normalised by the same function as a note's. cb(vector) | cb(nil, { kind, detail }).
function M.query(resolved, text, cb)
  llm.embed({
    endpoint = resolved.endpoint,
    model = resolved.model,
    input = { text },
    timeout_ms = resolved.timeout_ms,
  }, function(res)
    if not res.ok then
      return cb(nil, failure(res))
    end
    cb(vectors.to_index_vector({ res.vectors[1] }, resolved.dim))
  end)
end

--- The embedder the kit's `live_indexer` takes: `embedder(texts, cb)` with cb(vectors) |
--- cb(nil, 'kind: detail'). The error is a string because the indexer shows `tostring(err)`; the
--- vectors are cut and averaged by the indexer itself.
function M.for_indexer(resolved)
  return function(texts, cb)
    llm.embed({
      endpoint = resolved.endpoint,
      model = resolved.model,
      input = texts,
      timeout_ms = resolved.timeout_ms,
    }, function(res)
      if not res.ok then
        return cb(nil, ('%s: %s'):format(res.error, res.detail))
      end
      cb(res.vectors)
    end)
  end
end

return M
