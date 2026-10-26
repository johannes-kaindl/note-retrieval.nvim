local T = require('note_retrieval.kit.test')
local roots = require('note_retrieval.roots')

-- A scratch folder per test; `files` maps vault-relative paths to text (a path ending in '/' is
-- an empty folder). Removed afterwards, also when the test fails.
local function with_vault(files, fn)
  local base = vim.fn.tempname()
  local root = base .. '/my vault'
  vim.fn.mkdir(root, 'p')
  for rel, text in pairs(files) do
    if rel:sub(-1) == '/' then
      vim.fn.mkdir(root .. '/' .. rel, 'p')
    else
      vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
      local f = assert(io.open(root .. '/' .. rel, 'wb'))
      f:write(text)
      f:close()
    end
  end
  local ok, err = pcall(fn, root)
  vim.fn.delete(base, 'rf')
  assert(ok, err)
end

local PLUGIN = '.obsidian/plugins/vault-retrieval/'

T.case('find_root: searches upward from a file and from a folder, for .obsidian and .zk', function()
  with_vault({
    ['.obsidian/app.json'] = '{}',
    ['a b/c/note.md'] = 'x',
    ['zk vault/.zk/config.toml'] = '',
    ['zk vault/n/note.md'] = 'x',
  }, function(root)
    T.eq((roots.find_root(root .. '/a b/c/note.md')), root)
    T.eq((roots.find_root(root .. '/a b/c')), root)
    T.eq((roots.find_root(root)), root)
    -- the nearest marker wins, so a vault inside a vault is its own root
    T.eq((roots.find_root(root .. '/zk vault/n/note.md')), root .. '/zk vault')
    -- a path that does not exist yet (a new buffer) still finds its vault
    T.eq((roots.find_root(root .. '/a b/new.md')), root)
  end)
end)

T.case('find_root: no marker gives nil and the sentence that says how to set roots', function()
  with_vault({ ['n/note.md'] = 'x' }, function(root)
    local found, message = roots.find_root(root .. '/n/note.md')
    T.eq(found, nil)
    T.eq(
      message,
      'no notes folder found: neither the current path nor a parent holds a .obsidian/ or .zk/ folder.'
        .. ' Set the option roots, for example vim.g.note_retrieval = { roots = { "~/notes" } }'
        .. ' (:help note-retrieval-option-roots)'
    )
  end)
end)

T.case('find_root: a root from the options wins over the search, the longest one first', function()
  with_vault({ ['.obsidian/app.json'] = '{}', ['sub dir/deep/note.md'] = 'x' }, function(root)
    local note = root .. '/sub dir/deep/note.md'
    T.eq((roots.find_root(note, { roots = { root .. '/sub dir' } })), root .. '/sub dir')
    T.eq(
      (roots.find_root(note, { roots = { root, root .. '/sub dir/deep', root .. '/sub dir' } })),
      root .. '/sub dir/deep'
    )
    -- a trailing slash does not matter; a sibling with the same name start does not match
    T.eq((roots.find_root(note, { roots = { root .. '/sub dir/' } })), root .. '/sub dir')
    T.eq((roots.find_root(note, { roots = { root .. '/sub' } })), root)
    -- a root without the marker folders is still a root, and ~ is expanded
    T.eq((roots.find_root(note, { roots = { root .. '/sub dir/deep/../' } })), root .. '/sub dir')
    T.eq((roots.find_root(vim.fn.expand('~/x.md'), { roots = { '~' } })), vim.fs.normalize('~'))
  end)
end)

T.case('find_root: a path outside every configured root falls back to the search', function()
  with_vault({ ['.obsidian/app.json'] = '{}', ['n/note.md'] = 'x', ['other/'] = '' }, function(root)
    T.eq((roots.find_root(root .. '/n/note.md', { roots = { root .. '/other' } })), root)
  end)
end)

T.case('mode: without the Obsidian plugin the mode is eigen, the options carry over', function()
  with_vault({ ['.obsidian/app.json'] = '{}', ['_vaultrag/index.bin'] = 'x' }, function(root)
    local mode, info = roots.mode(root)
    T.eq({ mode, info }, { 'eigen', { exclude = {} } })
    mode, info = roots.mode(root, { index_dir = '_idx', exclude = { 'Tmp/' } })
    T.eq({ mode, info }, { 'eigen', { index_dir = '_idx', exclude = { 'Tmp/' } } })
  end)
end)

T.case('mode: the plugin and an index.bin make it obsidian; defaults for keys data.json lacks', function()
  with_vault({ [PLUGIN .. 'main.js'] = '', ['_vaultrag/index.bin'] = 'x' }, function(root)
    -- no data.json at all
    local mode, info = roots.mode(root)
    T.eq({ mode, info }, { 'obsidian', { index_dir = '_vaultrag', exclude = { 'Templates/', 'Archive/' } } })
    -- data.json with other keys only
    local f = assert(io.open(root .. '/' .. PLUGIN .. 'data.json', 'wb'))
    f:write('{"model":"m","indexDir":null}')
    f:close()
    mode, info = roots.mode(root)
    T.eq({ mode, info }, { 'obsidian', { index_dir = '_vaultrag', exclude = { 'Templates/', 'Archive/' } } })
  end)
end)

T.case('mode: indexDir and exclude from data.json, an empty exclude stays empty', function()
  with_vault({
    [PLUGIN .. 'data.json'] = '{"indexDir":"idx dir","exclude":[]}',
    ['idx dir/index.bin'] = 'x',
  }, function(root)
    local mode, info = roots.mode(root)
    T.eq({ mode, info }, { 'obsidian', { index_dir = 'idx dir', exclude = {} } })
  end)
  with_vault({
    [PLUGIN .. 'data.json'] = '{"indexDir":"idx","exclude":["Tmp/","Old/"]}',
    ['idx/index.bin'] = 'x',
  }, function(root)
    local mode, info = roots.mode(root)
    T.eq({ mode, info }, { 'obsidian', { index_dir = 'idx', exclude = { 'Tmp/', 'Old/' } } })
  end)
end)

T.case('mode: the plugin without an index.bin where data.json says is eigen', function()
  with_vault({
    [PLUGIN .. 'data.json'] = '{"indexDir":"idx"}',
    ['_vaultrag/index.bin'] = 'x', -- the default folder is not asked when data.json names another
    ['idx/'] = '',
  }, function(root)
    local mode = roots.mode(root)
    T.eq(mode, 'eigen')
  end)
end)

T.case(
  "mode: an index_dir with an Obsidian index in it makes it obsidian, with the plugin's exclude",
  function()
    with_vault({
      [PLUGIN .. 'data.json'] = '{"indexDir":"idx","exclude":["Tmp/"]}',
      ['mine/index.bin'] = 'x',
    }, function(root)
      local mode, info = roots.mode(root, { index_dir = 'mine' })
      T.eq({ mode, info }, { 'obsidian', { index_dir = 'mine', exclude = { 'Tmp/' } } })
      -- without the plugin an index in index_dir is the plugin's own
      vim.fn.delete(root .. '/.obsidian', 'rf')
      mode, info = roots.mode(root, { index_dir = 'mine' })
      T.eq({ mode, info }, { 'eigen', { index_dir = 'mine', exclude = {} } })
    end)
  end
)

T.case('mode: a broken data.json is reported, left in place, and no defaults stand in for it', function()
  local bad = {
    ['{"indexDir": '] = 'not valid JSON',
    ['[1,2]'] = 'not a JSON object',
    ['"text"'] = 'not a JSON object',
    ['{"indexDir":5}'] = 'indexDir must be a folder inside the vault',
    ['{"indexDir":"../out"}'] = 'indexDir must be a folder inside the vault',
    ['{"indexDir":"/abs"}'] = 'indexDir must be a folder inside the vault',
    ['{"exclude":"Templates/"}'] = 'exclude must be a list of path prefixes',
    ['{"exclude":["a",5]}'] = 'exclude must be a list of path prefixes',
    ['{"exclude":{"a":1}}'] = 'exclude must be a list of path prefixes',
  }
  for text, why in pairs(bad) do
    with_vault({ [PLUGIN .. 'data.json'] = text, ['_vaultrag/index.bin'] = 'x' }, function(root)
      local mode, err = roots.mode(root)
      T.eq(mode, nil, text)
      T.ok(err:find(PLUGIN .. 'data.json', 1, true), err)
      T.ok(err:find(why, 1, true), err)
      -- Obsidian owns the file: it is neither moved aside nor rewritten
      local f = assert(io.open(root .. '/' .. PLUGIN .. 'data.json', 'rb'))
      T.eq(f:read('*a'), text)
      f:close()
      T.eq(vim.fn.glob(root .. '/' .. PLUGIN .. '*'), root .. '/' .. PLUGIN .. 'data.json')
    end)
  end
end)

T.case(
  'index_path: eigen without index_dir under stdpath(data), keyed by 16 hex characters of the root',
  function()
    with_vault({}, function(root)
      local path = roots.index_path(root, 'eigen', { exclude = {} })
      local want = vim.fn.stdpath('data')
        .. '/note-retrieval/'
        .. vim.fn.sha256(root):sub(1, 16)
        .. '/index.bin'
      T.eq(path, want)
      T.ok(path:find('/note%-retrieval/%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x/index%.bin$'), path)
      T.eq(roots.index_path(root, 'eigen'), want)
      -- the same vault gives the same folder; another one another
      T.eq(roots.index_path(root .. '/', 'eigen'), want)
      T.ok(roots.index_path(root .. '/x', 'eigen') ~= want)
    end)
    -- a fixed vector, so that the key is the SHA-256 of the path and not just something stable
    T.eq(
      roots.index_path('/x', 'eigen'),
      vim.fn.stdpath('data') .. '/note-retrieval/b3d1db318671a024/index.bin'
    )
  end
)

T.case('index_path: with an index_dir the index lies inside the root, in either mode', function()
  with_vault({}, function(root)
    T.eq(roots.index_path(root, 'eigen', { index_dir = '_idx' }), root .. '/_idx/index.bin')
    T.eq(roots.index_path(root, 'obsidian', { index_dir = 'a b/c/' }), root .. '/a b/c/index.bin')
    T.raises(function()
      roots.index_path(root, 'obsidian', {})
    end, 'obsidian index needs info.index_dir')
  end)
end)

T.case('note_paths: markdown only, vault-relative with /, sorted by bytes, odd names intact', function()
  local names = {
    'plain.md',
    'with space/Ein Satz.md',
    'ümlaut/ß.md',
    'emoji/😀 note.md',
    'upper/Case.MD', -- the kit lists the lower-case extension only
    'sym#%[x]{y}*/a&b.md',
    'z.md',
    'readme.txt',
  }
  local files = {}
  for _, n in ipairs(names) do
    files[n] = 'x'
  end
  with_vault(files, function(root)
    local paths = roots.note_paths(root)
    T.eq(paths, {
      'emoji/😀 note.md',
      'plain.md',
      'sym#%[x]{y}*/a&b.md',
      'with space/Ein Satz.md',
      'z.md',
      'ümlaut/ß.md',
    })
    for _, p in ipairs(paths) do
      T.ok(not p:find('^/') and not p:find(root, 1, true), p)
    end
  end)
end)

T.case('note_paths: a part that starts with a dot drops the path (.obsidian, .git, dot files)', function()
  with_vault({
    ['.obsidian/x.md'] = 'x',
    ['.git/y.md'] = 'x',
    ['a/.hidden/z.md'] = 'x',
    ['a/.dot.md'] = 'x',
    ['a/keep.md'] = 'x',
    ['top.md'] = 'x',
  }, function(root)
    T.eq((roots.note_paths(root)), { 'a/keep.md', 'top.md' })
  end)
end)

T.case('note_paths: exclude is a case-sensitive prefix, and the index folder is left out', function()
  with_vault({
    ['Templates/t.md'] = 'x',
    ['Templates2/t.md'] = 'x',
    ['Archive/a.md'] = 'x',
    ['keep/Templates/k.md'] = 'x',
    ['_vaultrag/stray.md'] = 'x',
    ['top.md'] = 'x',
  }, function(root)
    T.eq((roots.note_paths(root, { 'Templates/', 'Archive/' })), {
      'Templates2/t.md',
      '_vaultrag/stray.md',
      'keep/Templates/k.md',
      'top.md',
    })
    T.eq((roots.note_paths(root, { 'Templates/', 'Archive/' }, '_vaultrag')), {
      'Templates2/t.md',
      'keep/Templates/k.md',
      'top.md',
    })
    T.eq((roots.note_paths(root, {}, '_vaultrag/')), {
      'Archive/a.md',
      'Templates/t.md',
      'Templates2/t.md',
      'keep/Templates/k.md',
      'top.md',
    })
  end)
end)

T.case('note_paths: the exclude prefix is case-sensitive', function()
  -- one folder only: on a case-insensitive file system (macOS) two names would be one folder
  with_vault({ ['templates/t.md'] = 'x' }, function(root)
    T.eq((roots.note_paths(root, { 'Templates/' })), { 'templates/t.md' })
    T.eq((roots.note_paths(root, { 'templates/' })), {})
  end)
end)

T.case('note_paths: a root that cannot be read gives nil and a message, not a raise', function()
  with_vault({}, function(root)
    local paths, err = roots.note_paths(root .. '/missing')
    T.eq(paths, nil)
    T.ok(type(err) == 'string' and err ~= '', 'no message')
  end)
end)
