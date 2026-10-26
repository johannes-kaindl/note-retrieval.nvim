local T = require('note_retrieval.kit.test')
local config = require('note_retrieval.config')

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

local function read(rel)
  local f = assert(io.open(root .. '/' .. rel, 'rb'))
  local s = f:read('*a')
  f:close()
  return s
end

local function tags(text, pattern)
  local out = {}
  for tag in text:gmatch('%*(' .. pattern .. ')%*') do
    out[#out + 1] = tag
  end
  table.sort(out)
  return out
end

T.case('the manual has one tag per option, and only those', function()
  local want = vim.tbl_map(function(n)
    return 'note-retrieval-option-' .. n
  end, config.NAMES)
  T.eq(tags(read('doc/note-retrieval.txt'), 'note%-retrieval%-option%-[%w_]+'), want)
end)

T.case('the manual has one tag per user command the plugin defines', function()
  vim.cmd('runtime plugin/note_retrieval.lua') -- the plugin file, if there is one yet
  local want = {}
  for name in pairs(vim.api.nvim_get_commands({})) do
    if name:find('^NoteRetrieval') then
      want[#want + 1] = ':' .. name
    end
  end
  table.sort(want)
  T.eq(tags(read('doc/note-retrieval.txt'), ':NoteRetrieval[%w]*'), want)
end)

T.case('the manual names every <Plug> mapping the plugin defines', function()
  -- Every mode a mapping can be defined in: one defined for Visual mode only must be found too.
  local seen, want = {}, {}
  for _, mode in ipairs({ 'n', 'x', 'o', 'i' }) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      if m.lhs:find('^<Plug>%(note%-retrieval') and not seen[m.lhs] then
        seen[m.lhs] = true
        want[#want + 1] = m.lhs
      end
    end
  end
  table.sort(want)
  T.eq(tags(read('doc/note-retrieval.txt'), '<Plug>%(note%-retrieval[%w-]*%)'), want)
end)

T.case(':helptags accepts the manual (no duplicate tags)', function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile(vim.fn.readfile(root .. '/doc/note-retrieval.txt'), dir .. '/note-retrieval.txt')
  local ok, err = pcall(vim.cmd.helptags, dir)
  T.ok(ok, err)
  T.ok(#vim.fn.readfile(dir .. '/tags') >= #config.NAMES, 'too few tags')
end)

T.case('every relative link in README.md points to a file that exists', function()
  local dead = {}
  local files = vim.fn.globpath(root .. '/docs', '**/*.md', false, true)
  files[#files + 1] = root .. '/README.md'
  for _, path in ipairs(files) do
    local text = read(path:sub(#root + 2))
    for target in text:gmatch('%]%(([^)]+)%)') do
      local file = target:gsub('#.*$', '')
      if file ~= '' and not file:match('^%a+:') then
        local abs = vim.fn.fnamemodify(vim.fn.fnamemodify(path, ':h') .. '/' .. file, ':p')
        if vim.uv.fs_stat(abs) == nil then
          dead[#dead + 1] = path:sub(#root + 2) .. ' → ' .. target
        end
      end
    end
  end
  T.eq(dead, {})
end)
