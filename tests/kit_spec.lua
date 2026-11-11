local T = require('note_retrieval.kit.test')

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

local function manifest()
  local f = assert(io.open(root .. '/lua/note_retrieval/kit/VENDOR.json', 'rb'))
  local m = vim.json.decode(f:read('*a'))
  f:close()
  return m
end

T.case('kit: every vendored module loads under note_retrieval.kit, none from a global nvim_kit', function()
  local modules = {}
  for _, src in ipairs(manifest().files) do
    local name = src:match('^lua/nvim_kit/([%w_]+)%.lua$')
    if name then
      modules[#modules + 1] = name
      T.ok(require('note_retrieval.kit.' .. name), name)
    end
  end
  table.sort(modules)
  T.eq(modules, {
    'chunker',
    'conformance',
    'data',
    'date',
    'debounce',
    'edits',
    'endpoint_model',
    'health',
    'http_stub',
    'index_delta',
    'index_guard',
    'live_indexer',
    'llm',
    'llm_json',
    'lock',
    'probe',
    'sampling',
    'scratch',
    'store',
    'test',
    'text',
    'vectors',
    'vrix',
    'wait',
    'walk',
  })
  for name in pairs(package.loaded) do
    T.ok(not name:find('^nvim_kit'), 'loaded a global ' .. name)
  end
end)

T.case('kit: every copy has the provenance line the manifest names, and the manifest the tag', function()
  local m = manifest()
  T.eq(m.source, 'nvim-kit')
  T.eq(m.tag, '0.17.1')
  T.eq(m.license, 'AGPL-3.0-only')
  local expected = '-- vendored from nvim-kit@' .. m.tag
  local seen = 0
  for _, path in ipairs(vim.fn.globpath(root .. '/lua/note_retrieval/kit', '*.lua', false, true)) do
    local f = assert(io.open(path, 'rb'))
    local first = f:read('*l')
    f:close()
    T.ok(vim.startswith(first, expected), path .. ': ' .. first)
    seen = seen + 1
  end
  T.eq(seen, 25)
end)

T.case('kit: no module outside kit/ carries a vendored header or lacks its domain line', function()
  for _, path in ipairs(vim.fn.globpath(root .. '/lua', '**/*.lua', false, true)) do
    if not path:find('/kit/', 1, true) then
      local f = assert(io.open(path, 'rb'))
      local head = {}
      for _ = 1, 5 do
        head[#head + 1] = f:read('*l') or ''
      end
      f:close()
      local joined = table.concat(head, '\n')
      T.ok(joined:find('-- domain: note_retrieval', 1, true), path .. ' has no domain line')
      T.ok(not joined:find('-- vendored from', 1, true), path .. ' claims to be vendored')
    end
  end
end)

T.case('kit: vendor-check is green (the manifest matches its source commit)', function()
  local dach = root .. '/../tools/kit/vendor.py'
  if vim.uv.fs_stat(dach) == nil then
    return -- a clone of this repo alone: `make vendor-check` says SKIPPED
  end
  local r = vim
    .system({ 'python3', dach, 'check', '.' }, { cwd = root, env = { PYTHONDONTWRITEBYTECODE = '1' }, text = true })
    :wait()
  T.eq(r.code, 0, (r.stdout or '') .. (r.stderr or ''))
end)

T.case('kit: sampling finds its data beside the vendored copy', function()
  local sampling = require('note_retrieval.kit.sampling')
  T.ok(#sampling.data.backendIds > 0, 'no backends')
end)
