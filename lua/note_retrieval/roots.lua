-- domain: note_retrieval
-- Where the notes are and where their index lives: the root of the vault, the mode (an Obsidian
-- index that is only read, or the plugin's own), the index file and the set of note paths.
-- Everything takes its options as a parameter (`cfg` as `config.resolve()` returns it), nothing
-- here reads vim.g.
local store = require('note_retrieval.kit.store')
local walk = require('note_retrieval.kit.walk')

local uv = vim.uv or vim.loop

local M = {}

M.NO_ROOT = 'no notes folder found: neither the current path nor a parent holds a .obsidian/ or'
  .. ' .zk/ folder. Set the option roots, for example'
  .. ' vim.g.note_retrieval = { roots = { "~/notes" } } (:help note-retrieval-option-roots)'

--- The defaults of the Obsidian plugin (DEFAULT_SETTINGS of vault-retrieval), used for a key
--- that data.json does not carry.
M.OBSIDIAN_DEFAULTS = { index_dir = '_vaultrag', exclude = { 'Templates/', 'Archive/' } }

local PLUGIN_DIR = '.obsidian/plugins/vault-retrieval'

local function kind(path)
  local st = uv.fs_stat(path)
  return st and st.type or nil
end

-- An absolute, normalised path without a trailing slash ('~' and variables expanded).
local function absolute(path)
  path = vim.fs.normalize(path or '')
  if not (path:find('^/') or path:find('^%a:/')) then
    path = vim.fs.normalize(uv.cwd() .. '/' .. path)
  end
  if #path > 1 then
    path = path:gsub('/+$', '')
  end
  return path
end

local function inside(path, root)
  return root == '/' or path == root or path:sub(1, #root + 1) == root .. '/'
end

--- The root of the vault `start` (a file or folder; nil or '' means the working directory) is in.
--- A root from `cfg.roots` wins, the longest matching one first; otherwise the nearest parent
--- with a `.obsidian/` or `.zk/` folder. Returns the absolute path, or `nil, message` that says
--- how to set `roots`.
function M.find_root(start, cfg)
  local path = absolute(start)
  local best
  for _, root in ipairs(cfg and cfg.roots or {}) do
    root = absolute(root)
    if inside(path, root) and (best == nil or #root > #best) then
      best = root
    end
  end
  if best then
    return best
  end
  local dir = kind(path) == 'directory' and path or vim.fs.dirname(path)
  while true do
    if kind(dir .. '/.obsidian') == 'directory' or kind(dir .. '/.zk') == 'directory' then
      return dir
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir or parent == '.' then
      return nil, M.NO_ROOT
    end
    dir = parent
  end
end

-- data.json of the Obsidian plugin: the decoded object, `nil` when there is no file, or
-- `nil, message` when it cannot be read or is not what the plugin writes. Read-only on purpose:
-- store.read would move a broken file aside, and the file belongs to Obsidian.
local function read_settings(path)
  local f, err = io.open(path, 'rb')
  if not f then
    if kind(path) == nil then
      return nil
    end
    return nil, ('cannot read %s: %s'):format(path, err)
  end
  local text = f:read('*a')
  f:close()
  local ok, value = pcall(vim.json.decode, text, { luanil = { object = true } })
  if not ok then
    return nil, ('%s is not valid JSON (%s); fix or delete it'):format(path, tostring(value))
  end
  if not store.is_object(value) then
    return nil, ('%s is not a JSON object; fix or delete it'):format(path)
  end
  return value
end

-- The title of a note is the file name without `.md` (spec 5.3): no file is read for it.
---@param path string
---@return string
function M.title_of(path)
  return (vim.fs.basename(path):gsub('%.md$', ''))
end

--- Whether `name` is a folder inside a root: a non-empty path that is neither absolute (`/`, `\\`,
--- a drive) nor climbs out with `..`.
---@param name any
---@return boolean
function M.relative_dir(name)
  if type(name) ~= 'string' or name:gsub('/+$', '') == '' or name:find('^[/\\]') or name:find('^%a:') then
    return false
  end
  for part in name:gmatch('[^/\\]+') do
    if part == '..' then
      return false
    end
  end
  return true
end

--- The mode of the vault at `root`: `'obsidian'` when the Vault Retrieval plugin of Obsidian is
--- installed in it (`.obsidian/plugins/vault-retrieval/`) and an `index.bin` lies in the folder
--- its `data.json` names (`indexDir`, default `_vaultrag`) or in `cfg.index_dir`; otherwise
--- `'eigen'`. The second result carries what the caller needs next: `{ index_dir, exclude }`
--- (obsidian: from `data.json`, a missing key meaning the plugin's default; eigen: from `cfg`).
--- A `data.json` that cannot be read or has the wrong shape gives `nil, message`: it is reported,
--- the defaults do not stand in for it, and the file is left alone.
function M.mode(root, cfg)
  cfg = cfg or {}
  local own = { index_dir = cfg.index_dir, exclude = cfg.exclude or {} }
  local plugin = root .. '/' .. PLUGIN_DIR
  if kind(plugin) ~= 'directory' then
    return 'eigen', own
  end
  local data, err = read_settings(plugin .. '/data.json')
  if err then
    return nil, err
  end
  data = data or {}
  local dir = data.indexDir == nil and M.OBSIDIAN_DEFAULTS.index_dir or data.indexDir
  local exclude = data.exclude == nil and M.OBSIDIAN_DEFAULTS.exclude or data.exclude
  if not M.relative_dir(dir) then
    return nil, ('%s/data.json: indexDir must be a folder inside the vault'):format(plugin)
  end
  if type(exclude) ~= 'table' or (next(exclude) ~= nil and not vim.islist(exclude)) then
    return nil, ('%s/data.json: exclude must be a list of path prefixes'):format(plugin)
  end
  for _, prefix in ipairs(exclude) do
    if type(prefix) ~= 'string' then
      return nil, ('%s/data.json: exclude must be a list of path prefixes'):format(plugin)
    end
  end
  for _, candidate in ipairs({ dir, cfg.index_dir }) do
    if kind(root .. '/' .. candidate .. '/index.bin') == 'file' then
      return 'obsidian', { index_dir = candidate, exclude = exclude }
    end
  end
  return 'eigen', own
end

--- The name of the folders a vault gets under `stdpath('data')` (its own index) and `stdpath('state')`
--- (lock and backup): the first 16 characters of the SHA-256 of the root's absolute path, so a
--- trailing slash or a relative spelling gives the same name.
---@param root string
---@return string
function M.hash(root)
  return vim.fn.sha256(absolute(root)):sub(1, 16)
end

--- The index file: in mode `'eigen'` without `info.index_dir` under `stdpath('data')`, in the folder
--- `M.hash(root)`; otherwise `<root>/<info.index_dir>/index.bin`. `info` is the second result of `mode`.
function M.index_path(root, mode, info)
  root = absolute(root)
  local dir = info and info.index_dir
  if dir then
    return root .. '/' .. dir:gsub('/+$', '') .. '/index.bin'
  end
  assert(mode == 'eigen', 'note_retrieval.roots: an obsidian index needs info.index_dir')
  return vim.fn.stdpath('data') .. '/note-retrieval/' .. M.hash(root) .. '/index.bin'
end

--- The notes of the vault: the vault-relative `*.md` paths (`/`-separated, sorted by bytes), without
--- any path that has a part starting with `.`, without the `exclude` prefixes and without the
--- index folder `index_dir` (nil: none). Second result: the folders that could not be read.
--- A root that cannot be read gives `nil, message`.
function M.note_paths(root, exclude, index_dir)
  local skip = vim.list_extend({}, exclude or {})
  if index_dir then
    skip[#skip + 1] = index_dir:gsub('/+$', '') .. '/'
  end
  local ok, res = pcall(walk.markdown, root, { exclude = skip })
  if not ok then
    return nil, tostring(res)
  end
  return res.paths, res.skipped
end

return M
