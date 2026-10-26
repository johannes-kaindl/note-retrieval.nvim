local T = require('note_retrieval.kit.test')
local V = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/vault.lua')
local H = require('note_retrieval.health')
local roots = require('note_retrieval.roots')
local state = require('note_retrieval.state')

-- Runs :checkhealth note_retrieval's check with vim.health recorded as "level: text" lines
-- (advice follows its line as "  -> text").
local function check(g)
  local saved, out = {}, {}
  for _, level in ipairs({ 'start', 'ok', 'info', 'warn', 'error' }) do
    saved[level] = vim.health[level]
    vim.health[level] = function(msg, advice)
      out[#out + 1] = level .. ': ' .. msg
      for _, a in ipairs(type(advice) == 'table' and advice or {}) do
        out[#out + 1] = '  -> ' .. a
      end
    end
  end
  vim.g.note_retrieval = g
  local ok, err = pcall(H.check)
  vim.g.note_retrieval = nil
  for level, fn in pairs(saved) do
    vim.health[level] = fn
  end
  assert(ok, err)
  return table.concat(out, '\n')
end

local function has(out, ...)
  for _, part in ipairs({ ... }) do
    T.ok(out:find(part, 1, true), ('%q is not in:\n%s'):format(part, out))
  end
end

local function open_note(root)
  vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.md'))
end

T.case('health: tools, options, vault, index, a server that offers the index model, the kit', function()
  local srv = V.server({ V.MODEL, 'other' })
  V.with_vault(function(root)
    open_note(root)
    local out = check({ endpoints = V.endpoint(srv.url) })
    has(out, 'ok: curl', 'ok: no problems', 'ok: notes folder: ' .. root)
    has(
      out,
      'ok: mode: obsidian',
      'ok: index: ' .. root .. '/_vaultrag/index.bin (3 notes, model test-model)'
    )
    has(out, 'ok: ' .. srv.url .. ': reachable, 2 models')
    has(out, 'ok: model "test-model" (the index header) is offered: search works')
    has(out, 'nvim-kit: nvim-kit@')
    T.ok(not out:find('error:', 1, true), out)
  end)
  srv.close()
end)

T.case('health: a server that lacks the index model is an error naming both, related still works', function()
  local srv = V.server({ 'other' })
  V.with_vault(function(root)
    open_note(root)
    local out = check({ endpoints = V.endpoint(srv.url) })
    has(out, 'error: Search is off', '"test-model"', '"other"', 'Related notes still work')
  end)
  srv.close()
end)

T.case('health: no server answering is a warning with what to do, not an error', function()
  V.with_vault(function(root)
    open_note(root)
    local out = check({ endpoints = V.endpoint(V.dead_url()) })
    has(out, 'warn: no embedding server answered', 'Start Ollama', 'related notes work without')
    T.ok(not out:find('error:', 1, true), out)
  end)
end)

T.case('health: no vault says how to set roots', function()
  V.without_vault(function()
    local out = check({ endpoints = V.endpoint(V.dead_url()) })
    has(out, 'warn: no notes folder found', roots.NO_ROOT)
  end)
end)

T.case('health: a torn index is an error in words, and nothing is written or moved', function()
  V.with_vault(function(root)
    open_note(root)
    local path = root .. '/_vaultrag/index.bin'
    local torn = V.index_bytes(V.ROWS):sub(1, 40)
    V.put(path, torn)
    local out = check({ endpoints = V.endpoint(V.dead_url()) })
    has(out, 'error: the index is being written or is damaged', 'try again in a moment')
    local f = assert(io.open(path, 'rb'))
    local after = f:read('*a')
    f:close()
    T.eq(after, torn)
    T.eq(vim.fn.glob(root .. '/_vaultrag/*'), path) -- no backup, no stray file
  end)
end)

T.case('health: no index yet is a warning with the next step', function()
  V.with_vault(function(root)
    open_note(root)
    os.remove(root .. '/_vaultrag/index.bin')
    local out = check({ endpoints = V.endpoint(V.dead_url()) })
    has(out, 'warn: no index file at', 'mode: eigen')
  end)
end)

T.case('health: a data.json that cannot be read is an error and stays as it is', function()
  V.with_vault(function(root)
    open_note(root)
    local data = root .. '/.obsidian/plugins/vault-retrieval/data.json'
    V.put(data, '{broken')
    local out = check({ endpoints = V.endpoint(V.dead_url()) })
    has(out, 'error: ', 'is not valid JSON', 'belongs to the Vault Retrieval plugin')
    T.eq(vim.fn.readfile(data), { '{broken' })
  end)
end)

T.case('health: option problems; invalid endpoints are not contacted', function()
  V.without_vault(function()
    local out = check({ endpoints = { { url = 'localhost' } }, timeout_ms = 0 })
    has(out, 'error: endpoints: entry 1: url must be an http(s) URL')
    has(out, 'warn: timeout_ms: must be a whole number from 1 to 2147483647')
    has(out, 'error: not checked: the endpoints option is invalid')
  end)
end)

T.case('health: options that are no table are named', function()
  V.without_vault(function()
    local out = check('x')
    has(out, 'warn: note_retrieval: must be a table')
  end)
end)

T.case('health: curl and ffi missing are said in words', function()
  V.without_vault(function()
    local executable, has_ffi = vim.fn.executable, H.has_ffi
    vim.fn.executable = function(name)
      return name == 'curl' and 0 or executable(name)
    end
    H.has_ffi = function()
      return false
    end
    local ok, out = pcall(check, { endpoints = V.endpoint(V.dead_url()) })
    vim.fn.executable, H.has_ffi = executable, has_ffi
    assert(ok, out)
    has(out, 'error: curl not found on PATH', 'Install curl')
    has(out, 'warn: no ffi', 'slower on a large vault')
  end)
end)

T.case('health: a remembered model the server no longer lists is a warning (own index)', function()
  local srv = V.server({ 'a', 'b' })
  V.without_vault(function()
    state.set_model(srv.url, 'gone')
    local out = check({ endpoints = V.endpoint(srv.url) })
    has(
      out,
      'warn: model "gone" (the remembered choice) is not offered by this server',
      ':NoteRetrieval model'
    )
  end)
  srv.close()
end)

T.case('health: the state file is not created by a check', function()
  V.without_vault(function()
    local path = state.path()
    os.remove(path)
    check({ endpoints = V.endpoint(V.dead_url()) })
    T.eq(vim.uv.fs_stat(path), nil)
  end)
end)

T.case(
  'health: run as :checkhealth, from the page it opens, the vault is that of the note you came from',
  function()
    local srv = V.server({ V.MODEL })
    V.with_vault(function(root)
      vim.g.note_retrieval = { endpoints = V.endpoint(srv.url) }
      open_note(root)
      vim.cmd('silent checkhealth note_retrieval')
      local page = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
      has(page, 'notes folder: ' .. root, 'index: ' .. root .. '/_vaultrag/index.bin (3 notes')
      T.ok(not page:find('no notes folder found', 1, true), page)
    end)
    srv.close()
  end
)
