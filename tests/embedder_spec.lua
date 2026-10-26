local T = require('note_retrieval.kit.test')
local stub = require('note_retrieval.kit.http_stub')
local llm = require('note_retrieval.kit.llm')
local vectors = require('note_retrieval.kit.vectors')
local embedder = require('note_retrieval.embedder')
local state = require('note_retrieval.state')

-- Runs an async call and waits for its answer; `calls()` says how often the callback fired.
local function await(start)
  local got, calls = nil, 0
  start(function(...)
    calls = calls + 1
    got = { ... }
  end)
  vim.wait(5000, function()
    return got ~= nil
  end, 5)
  assert(got, 'the callback never fired')
  return got, function()
    return calls
  end
end

-- A server with the given models and one 3-number vector per input text: { #text, 1, 0 }.
-- `shape(data, body)` may change the embeddings answer.
local function server(models, shape)
  local ids = {}
  for i, m in ipairs(models) do
    ids[i] = { id = m }
  end
  return stub.start({
    ['GET /v1/models'] = { body = { data = ids } },
    ['POST /v1/embeddings'] = function(req)
      local body = vim.json.decode(req.body)
      local data = {}
      for i, s in ipairs(body.input) do
        data[i] = { object = 'embedding', index = i - 1, embedding = { #s, 1, 0 } }
      end
      return { body = { data = shape and shape(data, body) or data } }
    end,
  })
end

local function cfg_for(srv, extra)
  return vim.tbl_extend('force', {
    endpoints = { { url = srv.url, backend = 'unknown' } },
    timeout_ms = 5000,
  }, extra or {})
end

local function resolve(cfg, manifest)
  local got, calls = await(function(cb)
    embedder.resolve(cfg, manifest, cb)
  end)
  return got[1], got[2], calls
end

-- Replaces vim.ui.select for one case; `pick(items)` returns the choice (nil: dismissed).
-- Returns the list of the item lists it was shown.
local function with_picker(pick, fn)
  local original, shown = vim.ui.select, {}
  vim.ui.select = function(items, _, on_choice)
    shown[#shown + 1] = items
    on_choice(pick(items))
  end
  local ok, err = pcall(fn, shown)
  vim.ui.select = original
  assert(ok, err)
end

local function fresh()
  llm.reset()
  vim.fn.delete(vim.fn.fnamemodify(state.path(), ':h'), 'rf')
end

local function embeddings_requests(srv)
  local out = {}
  for _, r in ipairs(srv.requests) do
    if r.path == '/v1/embeddings' then
      out[#out + 1] = vim.json.decode(r.body)
    end
  end
  return out
end

T.case('resolve: cfg.embedding_model wins and nobody is asked', function()
  fresh()
  local srv = server({ 'a', 'b' })
  state.set_model(srv.url, 'a')
  with_picker(function()
    error('asked')
  end, function(shown)
    local r = resolve(cfg_for(srv, { embedding_model = 'b' }), nil)
    T.eq(r.model, 'b')
    T.eq(r.endpoint.url, srv.url)
    T.eq(r.models, { 'a', 'b' })
    T.eq(r.timeout_ms, 5000)
    T.eq(r.dim, 256)
    T.eq(#shown, 0)
  end)
  srv.close()
end)

T.case('resolve: without a configured model the remembered one is used, if the server lists it', function()
  fresh()
  local srv = server({ 'a', 'b' })
  state.set_model(srv.url, 'b')
  with_picker(function()
    error('asked')
  end, function()
    T.eq(resolve(cfg_for(srv), nil).model, 'b')
  end)
  state.set_model(srv.url, 'gone')
  with_picker(function(items)
    return items[1]
  end, function(shown)
    T.eq(resolve(cfg_for(srv), nil).model, 'a')
    T.eq(#shown, 1) -- a remembered model the server no longer lists is asked about again
  end)
  srv.close()
end)

T.case('resolve: nothing configured or remembered asks over the models and remembers the pick', function()
  fresh()
  local srv = server({ 'a', 'b' })
  with_picker(function(items)
    return items[2]
  end, function(shown)
    local r = resolve(cfg_for(srv), nil)
    T.eq(r.model, 'b')
    T.eq(shown, { { 'a', 'b' } })
    T.eq(state.model(srv.url), 'b')
  end)
  srv.close()
end)

T.case('resolve: a dismissed picker is an error and remembers nothing', function()
  fresh()
  local srv = server({ 'a', 'b' })
  with_picker(function() end, function()
    local r, err, calls = resolve(cfg_for(srv), nil)
    T.eq(r, nil)
    T.eq(calls(), 1)
    T.eq(err, { kind = 'no-model-chosen', endpoint_models = { 'a', 'b' } })
    T.eq(state.model(srv.url), nil)
  end)
  srv.close()
end)

T.case(
  'resolve: a single model is used without asking; a configured model the server lacks is an error',
  function()
    fresh()
    local srv = server({ 'only' })
    with_picker(function()
      error('asked')
    end, function()
      T.eq(resolve(cfg_for(srv), nil).model, 'only')
      local r, err = resolve(cfg_for(srv, { embedding_model = 'other' }), nil)
      T.eq(r, nil)
      T.eq(err, { kind = 'model-missing', model = 'other', endpoint_models = { 'only' } })
    end)
    srv.close()
  end
)

T.case('resolve: mode obsidian — the header model is used, trimmed, and its index_dim travels', function()
  fresh()
  local srv = server({ 'a', 'nomic' })
  with_picker(function()
    error('asked')
  end, function()
    local r = resolve(cfg_for(srv), { embedding_model = ' nomic\t', index_dim = 128 })
    T.eq(r.model, 'nomic')
    T.eq(r.dim, 128)
    -- the same model named in the configuration is fine
    T.eq(resolve(cfg_for(srv, { embedding_model = 'nomic' }), { embedding_model = 'nomic' }).model, 'nomic')
  end)
  srv.close()
end)

T.case('resolve: mode obsidian — a model other than the header names both models', function()
  fresh()
  -- the header model is not served (several models, or a single other one)
  local many = server({ 'a', 'b' })
  local r, err = resolve(cfg_for(many), { embedding_model = 'nomic' })
  T.eq(r, nil)
  T.eq(err, { kind = 'model-mismatch', index_model = 'nomic', endpoint_models = { 'a', 'b' } })
  many.close()
  fresh()
  local lone = server({ 'other' })
  r, err = resolve(cfg_for(lone), { embedding_model = 'nomic' })
  T.eq(r, nil)
  T.eq(err, { kind = 'model-mismatch', index_model = 'nomic', endpoint_models = { 'other' } })
  -- model names are case-sensitive
  r, err = resolve(cfg_for(lone), { embedding_model = 'Other' })
  T.eq(r, nil)
  T.eq(err.kind, 'model-mismatch')
  lone.close()
  -- a configured model that is served but is not the header's
  fresh()
  local both = server({ 'a', 'nomic' })
  r, err = resolve(cfg_for(both, { embedding_model = 'a' }), { embedding_model = 'nomic' })
  T.eq(r, nil)
  T.eq(err, { kind = 'model-mismatch', index_model = 'nomic', endpoint_models = { 'a', 'nomic' } })
  both.close()
end)

T.case('resolve: a pick that cannot be remembered is still used, and cb fires once', function()
  fresh()
  local srv = server({ 'a', 'b' })
  local original = state.set_model
  state.set_model = function()
    error('state dir not writable')
  end
  local ok, err = pcall(function()
    with_picker(function(items)
      return items[2]
    end, function()
      local r, e, calls = resolve(cfg_for(srv), nil)
      T.eq(e, nil)
      T.eq(r.model, 'b')
      T.eq(calls(), 1)
    end)
  end)
  state.set_model = original
  srv.close()
  assert(ok, err)
end)

T.case('resolve: an index_dim that is no positive whole number falls back to 256', function()
  fresh()
  local srv = server({ 'nomic' })
  for _, bad in ipairs({ '128', -4, 0, 12.5 }) do
    T.eq(resolve(cfg_for(srv), { embedding_model = 'nomic', index_dim = bad }).dim, 256, tostring(bad))
  end
  T.eq(resolve(cfg_for(srv), { embedding_model = 'nomic', index_dim = 128 }).dim, 128)
  srv.close()
end)

T.case(
  'resolve: a header without a model demands nothing; a remembered model does not override a header',
  function()
    fresh()
    local srv = server({ 'a', 'nomic' })
    state.set_model(srv.url, 'a')
    with_picker(function()
      error('asked')
    end, function()
      T.eq(resolve(cfg_for(srv, { embedding_model = 'a' }), { embedding_model = '  ' }).model, 'a')
      T.eq(resolve(cfg_for(srv), { embedding_model = 'nomic' }).model, 'nomic')
    end)
    srv.close()
  end
)

T.case('resolve: errors are values — unreachable server, bad endpoints option', function()
  fresh()
  local dead = stub.start({})
  dead.close()
  local r, err, calls = resolve(cfg_for(dead), nil)
  T.eq(r, nil)
  T.eq(calls(), 1)
  T.eq(err.kind, 'unreachable')
  T.eq(type(err.detail), 'string')
  r, err = resolve({ endpoints_error = 'must be a list', timeout_ms = 1000 }, nil)
  T.eq(r, nil)
  T.eq(err, { kind = 'bad-config', detail = 'endpoints: must be a list' })
end)

local function resolved_for(srv, extra)
  return vim.tbl_extend('force', {
    endpoint = { url = srv.url, backend = 'unknown' },
    model = 'm',
    dim = 256,
    timeout_ms = 5000,
  }, extra or {})
end

T.case('query: one request, the text exactly as typed — no instruction in front', function()
  local srv = server({ 'm' })
  local text = 'how do I fold a fitted sheet?'
  local got = await(function(cb)
    embedder.query(resolved_for(srv), text, cb)
  end)
  srv.close()
  local sent = embeddings_requests(srv)
  T.eq(#sent, 1)
  T.eq(sent[1].input, { text })
  T.eq(sent[1].model, 'm')
  T.eq(got[2], nil)
end)

T.case('query: the vector goes through to_index_vector — cut to dim, unit length, as for a note', function()
  local srv = server({ 'm' })
  local text = 'abcd' -- the stub answers { 4, 1, 0 }
  local got = await(function(cb)
    embedder.query(resolved_for(srv), text, cb)
  end)
  T.eq(got[1], vectors.to_index_vector({ { 4, 1, 0 } }, 256))
  local cut = await(function(cb)
    embedder.query(resolved_for(srv, { dim = 2 }), text, cb)
  end)
  srv.close()
  T.eq(cut[1], vectors.to_index_vector({ { 4, 1, 0 } }, 2))
  T.eq(#cut[1], 2)
  local norm = 0
  for _, x in ipairs(cut[1]) do
    norm = norm + x * x
  end
  T.ok(math.abs(norm - 1) < 1e-6, 'unit length')
end)

T.case('query: too few vectors is an error and no vector; a refusing server is an error too', function()
  local srv = server({ 'm' }, function()
    return {} -- no embedding for the one text
  end)
  local got, calls = await(function(cb)
    embedder.query(resolved_for(srv), 'x', cb)
  end)
  srv.close()
  T.eq(got[1], nil)
  T.eq(got[2].kind, 'bad-response')
  T.eq(type(got[2].detail), 'string')
  T.eq(calls(), 1)
  local refusing = stub.start({
    ['POST /v1/embeddings'] = { status = 500, body = { error = { message = 'boom' } } },
  })
  got = await(function(cb)
    embedder.query(resolved_for(refusing), 'x', cb)
  end)
  refusing.close()
  T.eq(got[1], nil)
  T.eq(got[2].kind, 'http')
end)

T.case('for_indexer: texts go out in one list, vectors come back in order, errors as values', function()
  local srv = server({ 'm' })
  local embed = embedder.for_indexer(resolved_for(srv))
  local got = await(function(cb)
    embed({ 'a', 'bb', 'ccc' }, cb)
  end)
  T.eq(got[1], { { 1, 1, 0 }, { 2, 1, 0 }, { 3, 1, 0 } })
  T.eq(got[2], nil)
  T.eq(embeddings_requests(srv)[1].input, { 'a', 'bb', 'ccc' })
  srv.close()
  local short = server({ 'm' }, function(data)
    return { data[1] } -- one vector for three texts
  end)
  got = await(function(cb)
    embedder.for_indexer(resolved_for(short))({ 'a', 'bb', 'ccc' }, cb)
  end)
  short.close()
  T.eq(got[1], nil)
  -- the indexer shows tostring(err): a string with the kind and the reason, never a table
  T.eq(type(got[2]), 'string')
  T.ok(got[2]:find('bad-response', 1, true), 'names the kind')
  T.ok(got[2]:find('vector', 1, true), 'carries the detail')
end)
