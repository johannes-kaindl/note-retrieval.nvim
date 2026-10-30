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

T.case('README, the manual and the reference name every subcommand, option and <Plug> mapping', function()
  local command = require('note_retrieval.command')
  local function missing(file, words)
    local text = read(file)
    local out = {}
    for _, w in ipairs(words) do
      if not text:find(w, 1, true) then
        out[#out + 1] = file .. ' lacks ' .. w
      end
    end
    return out
  end
  local subs = vim.tbl_map(function(n)
    return ':NoteRetrieval ' .. n
  end, command.SUBCOMMANDS)
  local plugs = { '<Plug>(note-retrieval-related)', '<Plug>(note-retrieval-search)' }
  local gaps = {}
  local function add(list)
    vim.list_extend(gaps, list)
  end
  add(missing('README.md', subs))
  -- In backticks, not as bare text: a short name like `k` would be found in any word.
  local function quoted(names)
    return vim.tbl_map(function(n)
      return '`' .. n .. '`'
    end, names)
  end
  add(missing('README.md', quoted(config.NAMES)))
  add(missing('README.md', plugs))
  add(missing('doc/note-retrieval.txt', subs))
  add(missing(
    'docs/reference/commands.md',
    vim.tbl_map(function(n)
      return '| `' .. n .. '` |'
    end, command.SUBCOMMANDS)
  ))
  add(missing('docs/reference/commands.md', plugs))
  add(missing(
    'docs/reference/options.md',
    vim.tbl_map(function(n)
      return '| `' .. n .. '` |'
    end, config.NAMES)
  ))
  T.eq(gaps, {})
end)

T.case('the Default column of the options reference is config.DEFAULTS', function()
  local cells = {}
  for name, default in read('docs/reference/options.md'):gmatch('\n| `([%w_]+)` | [^|]+ | ([^|]+) |') do
    cells[name] = default
  end
  local wrong = {}
  for _, name in ipairs(config.NAMES) do
    local want = config.DEFAULTS[name]
    local cell = cells[name]
    if cell == nil then
      wrong[#wrong + 1] = name .. ': no row'
    elseif want == nil then
      if not cell:find('^`nil`') then
        wrong[#wrong + 1] = name .. ': default is nil, the column says ' .. cell
      end
    elseif cell ~= '`' .. (type(want) == 'string' and ('"%s"'):format(want) or tostring(want)) .. '`' then
      wrong[#wrong + 1] = ('%s: default is %s, the column says %s'):format(name, vim.inspect(want), cell)
    end
  end
  T.eq(wrong, {})
end)
