-- vendored from nvim-kit@0.16.1 (lua/nvim_kit/store.lua) — do not edit; re-vendor
-- A JSON state file that two editors can share. Read exactly (null stays vim.NIL, {} stays an
-- object, so the file keeps its shape for other programs), written atomically (temp file, then
-- rename), and re-read right before every write so one editor never overwrites what another
-- saved in between. A file that is not valid JSON is moved aside, never silently dropped.
local M = {}

local uv = vim.uv or vim.loop

-- nil only when the file does not exist. A file that exists but cannot be read (permissions) is an
-- error: treating it as missing would let the next write replace it silently.
local function read_text(path)
  local f, err = io.open(path, 'rb')
  if not f then
    if uv.fs_stat(path) == nil then
      return nil
    end
    error(('nvim-kit store: cannot read %s (%s) — left untouched'):format(path, tostring(err)), 0)
  end
  local text = f:read('*a')
  f:close()
  return text
end

--- Move path aside to <path>.broken-<UTC timestamp>[-n] and return the new path.
function M.set_aside(path)
  local base = ('%s.broken-%s'):format(path, os.date('!%Y%m%dT%H%M%SZ'))
  local aside, n = base, 1
  while uv.fs_stat(aside) do
    aside = ('%s-%d'):format(base, n)
    n = n + 1
  end
  local ok, err = uv.fs_rename(path, aside)
  if not ok then
    error(('nvim-kit store: cannot move %s aside: %s'):format(path, err))
  end
  return aside
end

--- A JSON object as vim.json.decode returns it: a non-list table, or an empty one marked as {}.
function M.is_object(v)
  return type(v) == 'table'
    and (next(v) == nil and getmetatable(v) ~= nil or (next(v) ~= nil and not vim.islist(v)))
end

--- Read path. Returns the decoded value (nil when the file does not exist) and an info table;
--- raises when the file exists but cannot be read, so that update never overwrites it;
--- info.broken names where a file without valid JSON was moved. opts.expect = 'object' also moves
--- aside valid JSON that is not an object (a list, a string, a number).
function M.read(path, opts)
  local text = read_text(path)
  if text == nil then
    return nil, {}
  end
  local ok, value = pcall(vim.json.decode, text)
  if not ok then
    return nil, { broken = M.set_aside(path), error = value }
  end
  if opts and opts.expect == 'object' and not M.is_object(value) then
    return nil, { broken = M.set_aside(path), error = 'not a JSON object' }
  end
  return value, {}
end

--- `mkdir -p`: create `path` and its missing parents (mode 0755, `/`-separated paths). A directory
--- that is there already is fine; a file in the way raises. Written with `vim.uv` only, so unlike
--- `vim.fn.mkdir` it also works in a fast callback (`vim.in_fast_event()`).
function M.mkdir_p(path)
  if type(path) ~= 'string' then
    error('nvim-kit store: mkdir_p(path) takes a string', 2)
  end
  path = path:gsub('/+$', '')
  if path == '' then
    return -- the root, or an empty path: nothing to create
  end
  local st = uv.fs_stat(path)
  if st then
    if st.type ~= 'directory' then
      error(('nvim-kit store: cannot create directory %s: a %s is in the way'):format(path, st.type), 0)
    end
    return
  end
  local parent = path:match('^(.*)/[^/]*$')
  if parent and parent ~= '' then
    M.mkdir_p(parent)
  end
  local ok, err, name = uv.fs_mkdir(path, 493)
  if not ok and name ~= 'EEXIST' then
    error(('nvim-kit store: cannot create directory %s: %s'):format(path, tostring(err)), 0)
  end
end

--- Write bytes to path: parent directories are created, the bytes go to a temp file next to path
--- (.<name>.tmp-<pid>-<hrtime>), are flushed to disk (fsync), and one rename puts them over path.
--- Raises on every failure and leaves no temp file behind; path is either the old or the new
--- content, never a mix. Uses no Vimscript function that a fast callback may not call (0.15.0).
function M.write_bytes(path, bytes)
  if type(path) ~= 'string' or type(bytes) ~= 'string' then
    error('nvim-kit store: write_bytes(path, bytes) takes two strings', 2)
  end
  local dir = vim.fn.fnamemodify(path, ':h')
  M.mkdir_p(dir)
  local tmp = ('%s/.%s.tmp-%d-%d'):format(dir, vim.fn.fnamemodify(path, ':t'), uv.os_getpid(), uv.hrtime())
  local fd, open_err = uv.fs_open(tmp, 'w', 420)
  if not fd then
    error(('nvim-kit store: cannot create %s: %s'):format(tmp, tostring(open_err)), 0)
  end
  local function fail(what, err)
    if fd then
      uv.fs_close(fd)
    end
    uv.fs_unlink(tmp)
    error(('nvim-kit store: cannot %s %s: %s'):format(what, path, tostring(err)), 0)
  end
  local offset = 0
  while offset < #bytes do
    local n, err = uv.fs_write(fd, bytes:sub(offset + 1), offset)
    if not n or n == 0 then
      fail('write', err or 'wrote no bytes')
    end
    offset = offset + n
  end
  local synced, sync_err = uv.fs_fsync(fd)
  if not synced then
    fail('flush', sync_err)
  end
  local closed, close_err = uv.fs_close(fd)
  fd = nil
  if not closed then
    fail('close', close_err)
  end
  local ok, err = uv.fs_rename(tmp, path)
  if not ok then
    fail('replace', err)
  end
end

--- Write value as JSON, atomically (see write_bytes).
function M.write(path, value)
  M.write_bytes(path, vim.json.encode(value))
end

local function finish(path, ...)
  M.write(path, (...))
  return ...
end

--- Re-read path (with opts as for read), apply fn(value_or_nil, info), write fn's first return
--- value, and return all of fn's return values. There is no cache: every update starts from the
--- file on disk.
function M.update(path, fn, opts)
  local value, info = M.read(path, opts)
  return finish(path, fn(value, info))
end

return M
