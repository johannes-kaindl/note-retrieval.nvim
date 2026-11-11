-- domain: note_retrieval
-- The index in memory: loaded on first need, reloaded when the file changes, and never written.
-- In mode 'obsidian' the file belongs to the Obsidian plugin (one writer per index), so nothing in
-- this module has a write path: it reads through `readonly_storage()` only, whose `write` and
-- `mkdir` raise. The own index (mode 'own') gets its writer in a later module.
local config = require('note_retrieval.config')
local date = require('note_retrieval.kit.date')
local guard = require('note_retrieval.kit.index_guard')
local live_indexer = require('note_retrieval.kit.live_indexer')
local roots = require('note_retrieval.roots')
local vectors = require('note_retrieval.kit.vectors')
local vrix = require('note_retrieval.kit.vrix')

local uv = vim.uv or vim.loop

local M = {}

M.READ_ONLY = 'the Obsidian index is read-only here'

-- What a `vrix.decode` or `vectors.parse` reason means to the person. A torn or half-written
-- file is a normal state while Obsidian writes (it does not write atomically), so it is worded
-- as "being written", not as an error.
local REASONS = {
  truncated = 'the index is being written or is damaged (the file is cut short)',
  crc = 'the index is being written or is damaged (the checksum does not match)',
  magic = 'the index is being written or is damaged (this is not an index file)',
  header = 'the index is being written or is damaged (the header cannot be read)',
  corrupt = 'the index is being written or is damaged (the rows do not fit the header)',
  schema = 'the index has a schema version this plugin does not read',
}

--- A storage with the interface of `live_indexer.fs_storage()` (`exists`, `read`, `write`,
--- `mkdir`) that reads like it and raises on `write` and `mkdir`.
function M.readonly_storage()
  local storage = live_indexer.fs_storage()
  storage.write = function()
    error(M.READ_ONLY, 2)
  end
  storage.mkdir = function()
    error(M.READ_ONLY, 2)
  end
  return storage
end

-- The loaded index by root: { path, mode, loaded }. The path is resolved once, so an index file
-- that vanishes for a moment does not switch the root to the own index.
local state = {}

local function same_stat(a, b)
  return a ~= nil
    and b ~= nil
    and a.size == b.size
    and a.mtime.sec == b.mtime.sec
    and a.mtime.nsec == b.mtime.nsec
end

-- Milliseconds since the epoch of a JavaScript `toISOString` text; nil for anything else.
local function iso_ms(text)
  if type(text) ~= 'string' then
    return nil
  end
  local y, mo, d, h, mi, s, frac = text:match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)%.?(%d*)Z$')
  if not y then
    return nil
  end
  local days = date.days_from_civil(tonumber(y), tonumber(mo), tonumber(d))
  local ms = tonumber(((frac or '') .. '000'):sub(1, 3))
  return ((days * 24 + tonumber(h)) * 60 + tonumber(mi)) * 60000 + tonumber(s) * 1000 + ms
end

-- The `mtime` the index stamps carry: whole milliseconds, `floor(mtimeMs)`.
function M.mtime_ms(stat)
  return stat.mtime.sec * 1000 + math.floor(stat.mtime.nsec / 1e6)
end

-- Mode and index file of a root, resolved once. Returns the state entry or `nil, message`.
local function locate(root, cfg)
  root = vim.fs.normalize(root)
  local entry = state[root]
  if entry then
    return entry, root
  end
  cfg = cfg or (config.resolve())
  local mode, info = roots.mode(root, cfg)
  if not mode then
    return nil, info
  end
  entry = { path = roots.index_path(root, mode, info), mode = mode, info = info }
  state[root] = entry
  if mode == 'own' then
    -- Lazy: loading the plugin loads no module; saves of an own index are heard from the first use.
    require('note_retrieval.indexer').attach_on_save(root)
  end
  return entry, root
end

--- Reads the index file of `root` (`cfg` as `config.resolve()` gives it, default: the options
--- in effect) and returns `{ index, manifest, paths, stamps, stat, path, mode, built_ms }`:
--- `index` is `vectors.parse`'s index (with `index.manifest` set), `paths` its row paths in row
--- order, `stamps` the `{ mtime, size }` list row for row or nil (an index without usable
--- stamps), `stat` the file's `uv.fs_stat` taken before the read, `built_ms` the header's
--- `built_at` in milliseconds (nil when it is missing), `mode` and `info` what `roots.mode` resolved. Without a result: `nil, message`, the
--- message in words ("the index is being written or is damaged"). It only reads, and it does not
--- touch what `current` holds.
function M.load(root, cfg)
  local entry, key = locate(root, cfg)
  if not entry then
    return nil, key
  end
  local stat = uv.fs_stat(entry.path)
  if not stat then
    return nil, ('no index file at %s'):format(entry.path)
  end
  local bytes = M.readonly_storage().read(entry.path)
  if not bytes then
    return nil, ('cannot read the index file %s'):format(entry.path)
  end
  local decoded, reason = vrix.decode(bytes)
  if not decoded then
    return nil, REASONS[reason] or ('the index cannot be read (%s)'):format(tostring(reason))
  end
  -- `parse` raises on a header with a valid checksum but without `scale` or `index_dim`; that is a
  -- file this plugin cannot read, not a bug, so it is answered like any other unreadable index.
  local parsed, index, why = pcall(vectors.parse, decoded.manifest, decoded.paths, decoded.matrix)
  if not parsed then
    index, why = nil, 'header'
  end
  if not index then
    return nil, REASONS[why] or ('the index cannot be read (%s)'):format(tostring(why))
  end
  index.manifest = decoded.manifest
  return {
    index = index,
    manifest = decoded.manifest,
    paths = decoded.paths,
    stamps = decoded.stamps,
    stat = stat,
    path = entry.path,
    mode = entry.mode,
    info = entry.info,
    built_ms = iso_ms(decoded.manifest.built_at),
  }
end

--- The index of `root` for a query: loads it on first need and, before every later call, takes a
--- `fs_stat` and reloads when `mtime` or size changed. A reload that fails (torn file, bad
--- checksum, file gone) keeps the old index and says why as the second result; the next call
--- tries again, because the stat of the failed file differs from the one that was loaded. An
--- empty index never replaces a filled one. Returns `loaded, warning` (`load`'s table; `warning`
--- nil or words), or `nil, message` when there is no index yet.
function M.current(root, cfg)
  local entry, key = locate(root, cfg)
  if not entry then
    return nil, key
  end
  local old = entry.loaded
  local stat = uv.fs_stat(entry.path)
  if old and same_stat(old.stat, stat) then
    return old
  end
  if not stat then
    local msg = ('the index file %s is missing'):format(entry.path)
    if old then
      return old, msg .. '; using the index loaded earlier'
    end
    return nil, msg
  end
  local fresh, msg = M.load(key, cfg)
  if not fresh then
    if old then
      return old, msg .. '; using the index loaded earlier, trying again on the next access'
    end
    return nil, msg
  end
  if old and old.index.count > 0 and fresh.index.count == 0 then
    return old, 'the index on disk is empty; using the index loaded earlier, trying again on the next access'
  end
  entry.loaded = fresh
  return fresh
end

--- What is held in memory for `root` (`load`'s table), or nil: no file access, no stat, nothing
--- is loaded. For callers that must not pay for a first read.
---@param root string
function M.peek(root)
  local entry = state[vim.fs.normalize(root)]
  return entry and entry.loaded or nil
end

--- Forgets what is held for `root` (all roots without argument): the next `current` resolves the
--- mode and file again and loads from scratch.
function M.reset(root)
  if root then
    state[vim.fs.normalize(root)] = nil
  else
    state = {}
  end
end

--- Whether the note `row_path` may be newer than its vector, from what is in memory (no reload,
--- nothing is ever written or re-stamped): `'changed'` when the row has a real stamp and the
--- file's `{ mtime, size }` differ from it; `'maybe'` when the row carries the stamp `{ 0, 0 }`
--- (nobody stamped it) and the file is newer than the index's `built_at`; otherwise `nil` (also
--- for a note without a row or a file, and when there is no index in memory). `root` is required:
--- the vault whose index `current` holds.
function M.stale_mark(row_path, root)
  assert(type(root) == 'string' and root ~= '', 'index.stale_mark needs the root')
  root = vim.fs.normalize(root)
  local entry = state[root]
  local loaded = entry and entry.loaded
  local row = loaded and loaded.index.rows[row_path]
  if not row then
    return nil
  end
  local file = uv.fs_stat(root .. '/' .. row_path)
  if not file then
    return nil
  end
  local now = { M.mtime_ms(file), file.size }
  local stamp = loaded.stamps and loaded.stamps[row] or guard.UNKNOWN_STAMP
  if stamp[1] ~= guard.UNKNOWN_STAMP[1] or stamp[2] ~= guard.UNKNOWN_STAMP[2] then
    if #guard.find_stale_vector_paths({ row_path }, { stamp }, { [row_path] = now }) > 0 then
      return 'changed'
    end
    return nil
  end
  if loaded.built_ms and now[1] > loaded.built_ms then
    return 'maybe'
  end
  return nil
end

return M
