local T = require('note_retrieval.kit.test')

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

-- The note_retrieval modules a fresh Neovim has loaded after `lua`, one per line.
local function loaded_after(lua)
  local script = vim.fn.tempname() .. '.lua'
  vim.fn.writefile({
    'vim.opt.rtp:prepend(' .. vim.inspect(root) .. ')',
    'vim.cmd("runtime plugin/note_retrieval.lua")',
    lua,
    'local names = {}',
    'for name in pairs(package.loaded) do',
    '  if name:find("^note_retrieval") then names[#names + 1] = name end',
    'end',
    'table.sort(names)',
    'io.stdout:write(table.concat(names, "\\n"))',
  }, script)
  local r = vim
    .system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', script }, { text = true })
    :wait(20000)
  vim.fn.delete(script)
  T.eq(r.code, 0, r.stderr)
  return vim.split(r.stdout, '\n', { trimempty = true })
end

T.case('the plugin file loads no module of the plugin, only the command and the mappings', function()
  T.eq(loaded_after(''), {})
end)

T.case('require("note_retrieval") alone loads neither the index nor the search', function()
  local names = loaded_after('require("note_retrieval")')
  T.ok(not vim.tbl_contains(names, 'note_retrieval.index'), vim.inspect(names))
  T.ok(not vim.tbl_contains(names, 'note_retrieval.search'), vim.inspect(names))
  T.ok(vim.tbl_contains(names, 'note_retrieval'), vim.inspect(names))
end)

T.case('a command that needs no index (an unknown subcommand) loads none either', function()
  local names = loaded_after('vim.cmd("silent! NoteRetrieval bogus")')
  T.ok(not vim.tbl_contains(names, 'note_retrieval.index'), vim.inspect(names))
  T.ok(vim.tbl_contains(names, 'note_retrieval.command'), vim.inspect(names))
end)

T.case('the plugin defines no global mapping, only <Plug> ones', function()
  local script = vim.fn.tempname() .. '.lua'
  vim.fn.writefile({
    'vim.opt.rtp:prepend(' .. vim.inspect(root) .. ')',
    'local function keys()',
    '  local set = {}',
    '  for _, mode in ipairs({ "n", "x", "o", "i", "c", "s", "t" }) do',
    '    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do set[mode .. " " .. m.lhs] = true end',
    '  end',
    '  return set',
    'end',
    'local before = keys()',
    'vim.cmd("runtime plugin/note_retrieval.lua")',
    'local added = {}',
    'for key in pairs(keys()) do',
    '  if not before[key] then added[#added + 1] = key end',
    'end',
    'table.sort(added)',
    'io.stdout:write(table.concat(added, ","))',
  }, script)
  local r = vim
    .system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', script }, { text = true })
    :wait(20000)
  vim.fn.delete(script)
  T.eq(
    r.stdout,
    'n <Plug>(note-retrieval-related),n <Plug>(note-retrieval-search),x <Plug>(note-retrieval-search)'
  )
end)
