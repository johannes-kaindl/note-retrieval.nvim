-- vendored from nvim-kit@0.15.0 (lua/nvim_kit/lock.lua) — do not edit; re-vendor
-- A lock file, so that two Neovim instances never write the same file at once. A port of the
-- Lock of code-kit's retrieval store (`src/py/retrieval/store.py`, 0.31.1): the exclusive create
-- ('wx') is the arbiter; a lock older than stale_after_s belongs to a dead process and is taken
-- over. Errors are values: nil, { error = 'locked', detail }.
local M = {}

local uv = vim.uv or vim.loop

M.STALE_AFTER_S = 1800

local function now_seconds()
  local sec, usec = uv.gettimeofday()
  if sec then
    return sec + usec / 1e6
  end
  return os.time()
end

local function mtime_seconds(stat)
  return stat.mtime.sec + stat.mtime.nsec / 1e9
end

local function read_all(path)
  local f = io.open(path, 'rb')
  if not f then
    return nil
  end
  local text = f:read('*a')
  f:close()
  return text
end

--- Take the lock file at path (parent directories are created). Returns a handle with
--- `path` and an idempotent `release()`, or nil and { error = 'locked', detail }: detail is the
--- lock's age in seconds while another holder's lock is not older than opts.stale_after_s
--- (default 1800), or a message when three attempts did not get the lock. An older lock is
--- removed and the create is tried again. The handle also releases on VimLeavePre. release()
--- deletes the file only while it is still this handle's own (same content and inode): a lock
--- that went stale and was taken over is never deleted by its former holder.
function M.acquire(path, opts)
  if type(path) ~= 'string' or path == '' then
    error('nvim-kit lock: acquire(path, opts?) needs a path', 2)
  end
  local stale_after_s = opts and opts.stale_after_s or M.STALE_AFTER_S
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  for _ = 1, 3 do
    local fd, open_err, open_name = uv.fs_open(path, 'wx', 420)
    if fd then
      local content = ('%d %s\n'):format(uv.os_getpid(), os.date('%Y-%m-%dT%H:%M:%S'))
      local written = uv.fs_write(fd, content, 0)
      local own = uv.fs_fstat(fd)
      uv.fs_close(fd)
      if not written or not own then
        uv.fs_unlink(path)
        error(('nvim-kit lock: cannot write %s'):format(path), 0)
      end
      local handle = { path = path }
      local autocmd
      local held = true
      function handle.release()
        if not held then
          return
        end
        held = false
        if autocmd then
          pcall(vim.api.nvim_del_autocmd, autocmd)
          autocmd = nil
        end
        local now = uv.fs_stat(path)
        if now and now.ino == own.ino and read_all(path) == content then
          uv.fs_unlink(path)
        end
      end
      autocmd = vim.api.nvim_create_autocmd('VimLeavePre', { callback = handle.release })
      return handle
    end
    if open_name ~= 'EEXIST' then
      -- Permissions, a file where a directory should be, a full disk: not contention, and
      -- reporting "locked" would send the person looking for another instance.
      error(('nvim-kit lock: cannot create %s: %s'):format(path, tostring(open_err)), 0)
    end
    local stat = uv.fs_stat(path)
    if stat then
      if stat.type ~= 'file' then
        error(('nvim-kit lock: %s exists and is a %s, not a lock file'):format(path, stat.type), 0)
      end
      local age = now_seconds() - mtime_seconds(stat)
      if age <= stale_after_s then
        return nil, { error = 'locked', detail = math.floor(age) }
      end
      -- Stale. Look again right before the unlink: if another process took the lock over in the
      -- meantime, its file has a new mtime and stays. What is left is the window between this
      -- stat and the unlink, the same as in the Python original.
      local again = uv.fs_stat(path)
      if again and again.mtime.sec == stat.mtime.sec and again.mtime.nsec == stat.mtime.nsec then
        local removed, unlink_err, unlink_name = uv.fs_unlink(path)
        if not removed and unlink_name ~= 'ENOENT' then
          error(('nvim-kit lock: cannot remove stale lock %s: %s'):format(path, tostring(unlink_err)), 0)
        end
      end
    end
  end
  return nil,
    { error = 'locked', detail = ('lock %s could not be acquired'):format(vim.fn.fnamemodify(path, ':t')) }
end

return M
