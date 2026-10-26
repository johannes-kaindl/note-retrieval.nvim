-- Fixtures for the command and health specs (loaded with dofile; not a spec itself): an Obsidian
-- vault of three notes with an index, and a fake embedding server.
local config = require('note_retrieval.config')
local index = require('note_retrieval.index')
local llm = require('note_retrieval.kit.llm')
local stub = require('note_retrieval.kit.http_stub')
local vrix = require('note_retrieval.kit.vrix')

local M = {}

M.MODEL = 'test-model'
M.ROWS = {
  { 'a.md', { 127, 0, 0, 0 } },
  { 'b.md', { 100, 50, 0, 0 } },
  { 'c.md', { 0, 0, 127, 0 } },
}

function M.put(path, bytes)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local f = assert(io.open(path, 'wb'))
  f:write(bytes)
  f:close()
end

--- The bytes of an index of `rows` ({ path, int8 vector } list), built with `model`.
function M.index_bytes(rows, model)
  local paths, cells = {}, {}
  for i, r in ipairs(rows) do
    paths[i] = r[1]
    for _, v in ipairs(r[2]) do
      cells[#cells + 1] = string.char(v < 0 and v + 256 or v)
    end
  end
  return vrix.encode({
    vault = '',
    embedding_model = model or M.MODEL,
    source_dim = 4,
    index_dim = 4,
    granularity = 'note',
    aggregation = 'mean',
    quant = 'int8',
    scale = 127,
    count = #rows,
    source_commit = '',
    built_at = '2026-10-20T00:00:00.000Z',
  }, paths, table.concat(cells))
end

--- `fn(root)` with an Obsidian vault in a temporary folder (data.json `{}`, one file per row, the
--- index in _vaultrag). Everything is removed afterwards: the vault, the open buffers, the options.
function M.with_vault(fn, opts)
  opts = opts or {}
  local base = vim.fn.tempname()
  local root = vim.uv.fs_realpath((function()
    vim.fn.mkdir(base, 'p')
    return base
  end)()) .. '/vault'
  M.put(root .. '/.obsidian/plugins/vault-retrieval/data.json', opts.data_json or '{}')
  for _, r in ipairs(M.ROWS) do
    M.put(root .. '/' .. r[1], '# ' .. r[1])
  end
  M.put(root .. '/_vaultrag/index.bin', M.index_bytes(opts.rows or M.ROWS, opts.model))
  index.reset()
  llm.reset()
  vim.cmd('silent! %bwipeout!')
  local cwd = vim.fn.getcwd()
  local ok, err = pcall(fn, root)
  vim.cmd('silent! %bwipeout!')
  vim.cmd.cd(vim.fn.fnameescape(cwd))
  index.reset()
  config.set(nil)
  vim.g.note_retrieval = nil
  vim.fn.delete(base, 'rf')
  assert(ok, err)
end

--- `fn()` with an empty folder as the working directory and no buffer open: no vault anywhere above.
function M.without_vault(fn)
  local dir = vim.uv.fs_realpath(vim.fn.tempname() .. '')
  dir = dir or vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(vim.fn.fnameescape(dir))
  vim.cmd('silent! %bwipeout!')
  local ok, err = pcall(fn)
  vim.cmd.cd(vim.fn.fnameescape(cwd))
  index.reset()
  config.set(nil)
  vim.g.note_retrieval = nil
  vim.fn.delete(dir, 'rf')
  assert(ok, err)
end

--- A fake embedding server offering `models` that answers every embedding with `vector`.
function M.server(models, vector)
  local data = {}
  for i, id in ipairs(models) do
    data[i] = { id = id }
  end
  return stub.start({
    ['GET /v1/models'] = { body = { data = data } },
    ['POST /v1/embeddings'] = {
      body = { data = { { object = 'embedding', index = 0, embedding = vector or { 1, 0, 0, 0 } } } },
    },
  })
end

--- An address nothing listens on.
function M.dead_url()
  local s = stub.start({})
  s.close()
  return s.url
end

--- `endpoints` option for a stub: no probe of the backend.
function M.endpoint(url)
  return { { url = url, backend = 'unknown' } }
end

return M
