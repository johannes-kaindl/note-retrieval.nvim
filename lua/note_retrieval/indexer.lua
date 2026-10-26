-- domain: note_retrieval
-- The writer of the own index (mode 'eigen'): one indexer per vault root, a full reindex with
-- progress, and every write behind the same four steps - mode check, lock, backup, the kit's guards
-- and atomic write. Nothing here runs in mode 'obsidian': the file belongs to the Obsidian plugin.
--
-- Every write of the kit's `live_indexer` (a live persist, an intermediate state of a reindex, the
-- state after a cancel) goes through the storage wrapper below, so none of them can skip a step.
-- Errors are values `{ kind, message }` (`message` is a plain sentence with the next step); the
-- kinds are: locked, not-eigen, options-changed, model-mismatch, dim-mismatch, shrink, not-ready,
-- unreadable, changed, backup-failed, write-failed, running, no-notes, incomplete, failed, no-indexer.
local config = require('note_retrieval.config')
local debounce = require('note_retrieval.kit.debounce')
local embedder_lib = require('note_retrieval.embedder')
local guard = require('note_retrieval.kit.index_guard')
local live_indexer = require('note_retrieval.kit.live_indexer')
local lock = require('note_retrieval.kit.lock')
local roots = require('note_retrieval.roots')
local vectors = require('note_retrieval.kit.vectors')
local vrix = require('note_retrieval.kit.vrix')

local uv = vim.uv or vim.loop

local M = {}

M.DEFAULT_DIM = 256

-- The indexer of each root (the normalised path), never two.
local entries = {}

local Ix = {}
Ix.__index = Ix

local function now_ms()
  local sec, usec = uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

local function failure(kind, message, extra)
  return setmetatable(vim.tbl_extend('force', extra or {}, { kind = kind, message = message }), {
    __tostring = function(e)
      return e.message
    end,
  })
end

local function age_text(seconds)
  if seconds < 90 then
    return ('%d s'):format(seconds)
  end
  return ('%d min'):format(math.floor(seconds / 60))
end

local function normalise(root)
  return vim.fs.normalize(root)
end

-- Where the session's files for a root live: the lock and the backup, next to nothing the user
-- edits. The hash is the one `roots.index_path` puts in the folder name of the own index.
local function state_files(key)
  local hash = vim.fs.basename(vim.fs.dirname(roots.index_path(key, 'eigen', nil)))
  local dir = vim.fn.stdpath('state') .. '/note-retrieval/' .. hash
  return { dir = dir, lock = dir .. '/index.lock', backup = dir .. '/index.bin.bak' }
end

-- The version of the index file: what a change by another process shows in. A storage may bring
-- its own `stat` (the specs' in-memory one does).
local function default_stat(path)
  local st = uv.fs_stat(path)
  return st and { size = st.size, sec = st.mtime.sec, nsec = st.mtime.nsec } or nil
end

local function stat_of(self)
  return (self.inner.stat or default_stat)(self.path)
end

-- The sentence for a refusal of the kit's guards (`live:persist`'s second result).
local function refusal_failure(self, refusal)
  local kind = refusal.kind
  if kind == 'model-mismatch' then
    return failure(
      kind,
      (
        'the index on disk was built with another model than %q; mixing the two vector spaces would damage it.'
        .. ' Run :NoteRetrieval reindex to rebuild the index with this model, or go back to the old model'
      ):format(self.model)
    )
  elseif kind == 'dim-mismatch' then
    return failure(
      kind,
      ('the index on disk has another vector size than this setup (%d columns); run :NoteRetrieval reindex to rebuild it'):format(
        self.dim
      )
    )
  elseif kind == 'shrink' then
    return failure(
      kind,
      'this write would leave far fewer notes than the index on disk holds, so nothing was written;'
        .. ' :NoteRetrieval reset reads the index again, :NoteRetrieval reindex rebuilds it'
    )
  elseif kind == 'not-ready' then
    return failure(
      kind,
      (
        'the index at %s could not be loaded (%s), so nothing is written over it;'
        .. ' fix or remove the file, or run :NoteRetrieval reindex to rebuild it'
      ):format(self.path, self.not_ready or 'it was not read')
    )
  elseif kind == 'unreadable' then
    return failure(
      kind,
      'the index on disk cannot be read right now (another Neovim writing it?); nothing was written, try again in a moment'
    )
  end
  return failure(kind or 'failed', refusal.message or 'the index was not written')
end

-- An error raised by a write (the storage wrapper raises failure tables), as a value.
local function raised_failure(err)
  if type(err) == 'table' and err.kind then
    return err
  end
  return failure('write-failed', 'the index could not be written: ' .. tostring(err))
end

-- Whether this root is still ours to write: mode 'eigen', read fresh every time (never from the
-- cache of `index.locate`), and the index file the options name is the one this indexer holds.
-- Returns nil, or the failure.
local function mode_refusal(self)
  local mode, info = roots.mode(self.root, self.cfg)
  if mode == nil then
    return failure('not-eigen', 'cannot tell whose index this is, so nothing is written: ' .. tostring(info))
  end
  if mode ~= 'eigen' then
    return failure(
      'not-eigen',
      ('the index of this vault belongs to the Obsidian plugin (%s); this plugin only reads it and writes nothing there'):format(
        roots.index_path(self.root, mode, info)
      )
    )
  end
  if roots.index_path(self.root, 'eigen', info) ~= self.path then
    return failure(
      'options-changed',
      'the options name another index folder than this session writes to; run :NoteRetrieval reset and try again'
    )
  end
end

-- Takes the lock for one write: the handle, or nil and the failure.
local function take_lock(self)
  local ok, handle, err = pcall(lock.acquire, self.files.lock)
  if not ok then
    return nil, failure('write-failed', 'cannot take the lock for the index: ' .. tostring(handle))
  end
  if not handle then
    if type(err.detail) == 'number' then
      return nil,
        failure(
          'locked',
          (
            'another Neovim holds the lock on this index (taken %s ago); try again in a moment.'
            .. ' A lock older than %s is taken over'
          ):format(age_text(err.detail), age_text(lock.STALE_AFTER_S)),
          { age = err.detail }
        )
    end
    return nil, failure('locked', 'the lock on this index could not be taken: ' .. tostring(err.detail))
  end
  return handle
end

-- A copy of the index file before it is overwritten: the first write of a session and the first
-- write of a full reindex. Raises when the copy cannot be made; then nothing is written over it.
local function backup(self)
  if self.backed_up and not self.backup_next then
    return
  end
  local storage = self.inner
  if storage.exists(self.path) then
    local bytes = storage.read(self.path)
    if type(bytes) ~= 'string' then
      error(
        failure('backup-failed', ('cannot read %s to back it up, so nothing was written'):format(self.path)),
        0
      )
    end
    local ok, err = pcall(function()
      storage.mkdir(self.files.dir)
      storage.write(self.files.backup, bytes)
    end)
    if not ok then
      error(
        failure(
          'backup-failed',
          ('cannot back up the index to %s (%s), so nothing was written'):format(
            self.files.backup,
            tostring(err)
          )
        ),
        0
      )
    end
  end
  self.backed_up = true
  self.backup_next = false
end

-- The storage the kit's indexer writes through. Only the write of the index file is different.
local function guarded_storage(self)
  local inner = self.inner
  local s = {
    exists = inner.exists,
    read = inner.read,
    mkdir = inner.mkdir,
    write = function(path, bytes)
      if path ~= self.path then
        return inner.write(path, bytes)
      end
      local handle
      if not self.lock then
        local err
        handle, err = take_lock(self)
        if not handle then
          error(err, 0)
        end
      end
      local ok, err = pcall(function()
        local refusal = mode_refusal(self)
        if refusal then
          error(refusal, 0)
        end
        backup(self)
        inner.write(path, bytes)
        self.seen = stat_of(self)
      end)
      if handle then
        handle.release()
      end
      if not ok then
        -- The kit swallows a failed write after a cancel (it only warns); `reindex` reads this.
        self.write_error = raised_failure(err)
        error(self.write_error, 0)
      end
      self.write_error = nil
      self.wrote = true
    end,
  }
  return s
end

-- The embedder the kit's indexer takes: the one of the moment (`embedder` can be replaced between
-- runs), answering on the main loop. An answer from a `vim.uv` callback would run the lock and the
-- file writes of the indexer in a fast event, where `vim.fn` and the lock's autocmd are not allowed.
local function main_loop_embedder(self)
  return function(texts, cb)
    self.embedder(texts, function(a, b)
      if vim.in_fast_event() then
        vim.schedule(function()
          cb(a, b)
        end)
      else
        cb(a, b)
      end
    end)
  end
end

local function new_live(self, model, dim)
  return live_indexer.new(guarded_storage(self), vim.fs.dirname(self.path), main_loop_embedder(self), model, {
    dim = dim,
    warn = function(message)
      self.warnings[#self.warnings + 1] = message
      if #self.warnings > 20 then
        table.remove(self.warnings, 1)
      end
      vim.schedule(function()
        vim.notify('note-retrieval: ' .. message, vim.log.levels.WARN)
      end)
    end,
  })
end

-- The index file as it is now: { index, stamps, stat } for a readable one, { absent = true, stat }
-- for none, or nil and why.
local function read_disk(self)
  local stat = stat_of(self)
  if not self.inner.exists(self.path) then
    return { absent = true, stat = stat }
  end
  local bytes = self.inner.read(self.path)
  if type(bytes) ~= 'string' then
    return nil, ('cannot read the index file %s'):format(self.path)
  end
  local decoded, reason = vrix.decode(bytes)
  if not decoded then
    return nil, ('the index file is damaged or being written (%s)'):format(tostring(reason))
  end
  local ok, index = pcall(vectors.parse, decoded.manifest, decoded.paths, decoded.matrix)
  if not ok or not index then
    return nil, 'the header of the index file cannot be read'
  end
  index.manifest = decoded.manifest
  return { index = index, stamps = decoded.stamps, stat = stat }
end

-- Takes the index on disk into the EXISTING kit indexer (`init` copies the rows, nothing of the
-- loaded tables is kept or changed). Returns true, or nil and why; then the indexer is not ready
-- and refuses live writes until a reindex or a later successful read.
local function adopt(self)
  local disk, why = read_disk(self)
  if not disk then
    self.live:mark_unready()
    self.not_ready = why
    return nil, why
  end
  if disk.absent then
    self.live:mark_fresh()
    self.not_ready = nil
    self.seen = disk.stat
    self.disk_count = 0
    return true
  end
  self.disk_count = disk.index.count
  -- Vectors of another model never sit in memory under this model's name: only a reindex writes then.
  local disk_model = disk.index.manifest and disk.index.manifest.embedding_model
  if
    type(disk_model) == 'string'
    and vim.trim(disk_model) ~= ''
    and not guard.embedding_model_matches_index(self.model, disk_model)
  then
    self.live:mark_unready()
    self.not_ready = ('the index on disk was built with %q, this setup embeds with %q'):format(
      vim.trim(disk_model),
      self.model
    )
    self.seen = disk.stat
    return nil, self.not_ready
  end
  local ok, err = pcall(self.live.init, self.live, disk.index, disk.stamps)
  if not ok then
    self.live:mark_unready()
    self.seen = disk.stat
    if type(err) == 'table' and err.kind == 'dim-mismatch' then
      self.not_ready = ('the index on disk has %d columns, this setup %d'):format(disk.index.dim, self.dim)
    else
      self.not_ready = tostring(err)
    end
    return nil, self.not_ready
  end
  self.not_ready = nil
  self.seen = disk.stat
  return true
end

local function same_stat(a, b)
  return vim.deep_equal(a, b)
end

--- The indexer of the own index of `root`; one per root, the same table on every call. The first
--- call needs `opts` = `{ embedder = function(texts, cb), model = string, dim = 256, cfg = options }`
--- or `{ resolved = <embedder.resolve result>, cfg = ... }`; `cfg` defaults to `config.resolve()`.
--- A later call may bring a new embedder or model: the embedder is taken over, a new model (or
--- size) builds a new kit indexer that starts from the disk and carries nothing over from memory
--- (the old vectors would sit there under the new model's name); live writes are refused until a
--- reindex when the index on disk has another model. While a reindex runs nothing is replaced. Returns `ix`, or `nil, message` (not mode 'eigen', no embedder).
--- `ix.live` is the kit's indexer (`update`, `remove`, `rename`); write only through `ix:persist`.
function M.for_root(root, opts)
  opts = opts or {}
  local key = normalise(root)
  local embedder, model, dim = opts.embedder, opts.model, opts.dim
  if opts.resolved then
    embedder = embedder_lib.for_indexer(opts.resolved)
    model = opts.resolved.model
  end
  dim = dim or M.DEFAULT_DIM
  local ix = entries[key]
  if ix then
    if embedder and not ix.run.running then
      ix.embedder = embedder
      if model and (model ~= ix.model or dim ~= ix.dim) then
        -- The vectors in memory belong to the old model: none of them is carried over. The new
        -- indexer starts from the disk, which it takes only when the model there is its own.
        ix.model, ix.dim = model, dim
        ix.live = new_live(ix, model, dim)
        ix.seen = nil
        adopt(ix)
      end
    end
    return ix
  end
  if type(embedder) ~= 'function' or type(model) ~= 'string' then
    return nil, 'no embedding model is chosen yet, so there is no indexer for this vault'
  end
  local cfg = opts.cfg or (config.resolve())
  local mode, info = roots.mode(key, cfg)
  if mode ~= 'eigen' then
    return nil,
      mode == nil and tostring(info)
        or 'this vault uses the index of the Obsidian plugin; the plugin never writes it'
  end
  ix = setmetatable({
    root = key,
    cfg = cfg,
    path = roots.index_path(key, 'eigen', info),
    files = state_files(key),
    inner = opts.storage or live_indexer.fs_storage(),
    embedder = embedder,
    model = model,
    dim = dim,
    warnings = {},
    backed_up = false,
    backup_next = false,
    lock = nil,
    seen = nil,
    not_ready = nil,
    run = { running = false },
  }, Ix)
  ix.live = new_live(ix, model, dim)
  entries[key] = ix
  adopt(ix)
  M.attach_on_save(key)
  return ix
end

--- Reads the index file again when it changed since this indexer saw it (another Neovim wrote
--- it). Refused while a reindex runs. Returns true, or nil and why.
function Ix:sync()
  if self.run.running then
    return nil, 'a reindex is running'
  end
  if same_stat(stat_of(self), self.seen) and self.live:is_ready() then
    return true
  end
  return adopt(self)
end

--- Writes the state in memory: mode check, lock, the kit's guards, backup, atomic write, unlock.
--- `reason` is 'live' (default), 'heal' or 'reindex'. A 'live' or 'heal' write is refused when the
--- file changed on disk since this indexer read or wrote it (call `sync` first). Returns true, or
--- nil and `{ kind, message }`; a write error is a value here, never raised.
function Ix:persist(reason)
  reason = reason or 'live'
  local refusal = mode_refusal(self)
  if refusal then
    self.last_error = refusal
    return nil, refusal
  end
  local handle, lerr = take_lock(self)
  if not handle then
    self.last_error = lerr
    return nil, lerr
  end
  self.lock = handle
  local ok, res, why = pcall(function()
    if reason ~= 'reindex' and not same_stat(stat_of(self), self.seen) then
      return nil,
        failure(
          'changed',
          'the index file changed on disk since it was read (another Neovim?); nothing was written.'
            .. ' Read it again and repeat the change'
        )
    end
    local done, refused = self.live:persist(reason)
    if not done then
      return nil, refusal_failure(self, refused)
    end
    return true
  end)
  self.lock = nil
  handle.release()
  if not ok then
    res, why = nil, raised_failure(res)
  end
  if not res then
    self.last_error = why
    return nil, why
  end
  self.last_error = nil
  self.disk_count = self.live:note_count()
  return true
end

-- The refusal when a run is going: a reindex and an update of the index never run together.
local function running_failure(self)
  if self.run.kind == 'save' then
    return failure(
      'running',
      'the index is being updated after a save (:NoteRetrieval status shows it); try again in a moment'
    )
  end
  if self.run.kind == 'sync' then
    return failure(
      'running',
      'an update of the index is running (:NoteRetrieval status shows it); try again when it is done'
    )
  end
  return failure('running', 'a reindex is already running; :NoteRetrieval stop ends it')
end

local function on_main_loop(fn)
  if vim.in_fast_event() then
    vim.schedule(fn)
  else
    fn()
  end
end

-- The text of a note (vault-relative path), or nil and why.
local function read_note(root, path)
  local f, err = io.open(root .. '/' .. path, 'rb')
  if not f then
    return nil, err
  end
  local text = f:read('*a')
  f:close()
  return text
end

-- The stamp the index keeps with a row, `{ mtime in ms, size }` of the file, or nil. The kit takes
-- it AFTER `read`, so an old stamp never sits on a new vector.
local function stamp_note(root, path)
  local st = uv.fs_stat(root .. '/' .. path)
  if not st then
    return nil
  end
  return { st.mtime.sec * 1000 + math.floor(st.mtime.nsec / 1e6), st.size }
end

--- Rebuilds the whole index from the notes of the vault. `cb(report, err)`: `report` is
--- `{ added, skipped_empty, failed, cancelled }` of the kit, or nil when the run itself failed;
--- `err` is nil, or `{ kind, message }` when the result was not written (the old index stays).
--- `opts.on_progress(done, indexed, total)` hears each note. A cancelled run keeps every note it
--- did not reach. A run in which notes failed and that would leave far fewer notes than before
--- (a server that went away) is not written.
function Ix:reindex(cb, opts)
  cb = cb or function() end
  opts = opts or {}
  local function fail(err)
    self.last_error = err
    cb(nil, err)
  end
  if self.run.running then
    return fail(running_failure(self))
  end
  local refusal = mode_refusal(self)
  if refusal then
    return fail(refusal)
  end
  local _, info = roots.mode(self.root, self.cfg)
  local paths, skipped = roots.note_paths(self.root, info.exclude, info.index_dir)
  if not paths then
    return fail(failure('no-notes', 'cannot read the notes: ' .. tostring(skipped)))
  end
  if #paths == 0 then
    return fail(
      failure('no-notes', 'no Markdown notes found under ' .. self.root .. ', so the index stays as it is')
    )
  end
  -- Memory can be behind the disk (another Neovim wrote, or the file was unreadable at start): the
  -- stock of the run and the "thin result" check must start from what is on disk.
  self:sync()
  self.write_error = nil
  self.wrote = false
  local before = math.max(self.live:note_count(), self.disk_count or 0)
  local run = {
    running = true,
    kind = 'reindex',
    done = 0,
    indexed = 0,
    total = #paths,
    started = now_ms(),
    stopping = false,
  }
  self.run = run
  self.backup_next = true
  self.last_error = nil
  local root = self.root
  local function read(path)
    return read_note(root, path)
  end
  local function stamp_for(path)
    return stamp_note(root, path)
  end
  local function progress(done, indexed, total)
    run.done, run.indexed, run.total = done, indexed, total
    if opts.on_progress then
      opts.on_progress(done, indexed, total)
    end
  end
  self.live:reindex_all(paths, read, progress, stamp_for, function(report, err)
    on_main_loop(function()
      run.running = false
      if not report then
        self.backup_next = false
        local e = failure('failed', 'the reindex failed: ' .. tostring(err))
        self.last_error = e
        return cb(nil, e)
      end
      run.report = report
      local result_err
      if not report.cancelled then
        local after = self.live:note_count()
        if #report.failed > 0 and (after == 0 or guard.is_suspicious_shrink(before, after)) then
          -- Memory holds the partial result now; the disk keeps the good index and is read again.
          self.seen = nil
          adopt(self)
          result_err = failure(
            'incomplete',
            (
              '%d of %d notes could not be embedded (is the server still up?); the index on disk was not replaced.'
              .. ' Run :NoteRetrieval reindex again'
            ):format(#report.failed, #paths)
          )
        else
          local ok, persisted, why = pcall(self.persist, self, 'reindex')
          if not ok then
            persisted, why = nil, raised_failure(persisted)
          end
          if not persisted then
            result_err = why
          end
        end
      end
      -- A cancelled run was written by the kit (the mix of the new rows and the old stock) or, when
      -- the index on disk belongs to another model, deliberately not. The kit only warns when that
      -- write fails; the wrapper kept the failure.
      if report.cancelled then
        result_err = self.write_error
        -- Only a write moves the disk: a cancel that wrote nothing (foreign model on disk) leaves it.
        if not result_err and self.wrote then
          self.disk_count = self.live:note_count()
        end
      end
      self.backup_next = false
      self.last_error = result_err
      cb(report, result_err)
    end)
  end)
end

-- `stat_of` for every note: `{ [path] = { mtime in ms, size } }`, taken in groups so Neovim stays
-- responsive on a big vault. `cb(map)`.
local STAT_GROUP = 300
local function stamps_of_notes(root, paths, cb)
  local map = {}
  local i = 1
  local function step()
    local last = math.min(i + STAT_GROUP - 1, #paths)
    for k = i, last do
      local st = stamp_note(root, paths[k])
      if st then
        map[paths[k]] = st
      end
    end
    i = last + 1
    if i > #paths then
      return cb(map)
    end
    vim.schedule(step)
  end
  vim.schedule(step)
end

-- Whether `path` lies in one of the folders `skipped` (vault-relative, as the walk lists them; '.' is
-- the vault folder itself, read only in part): a note there was not seen, which is not "gone".
local function under_skipped(path, skipped)
  for _, dir in ipairs(skipped) do
    if dir == '.' then
      if not path:find('/', 1, true) then
        return true
      end
    elseif path:sub(1, #dir + 1) == dir .. '/' then
      return true
    end
  end
  return false
end

-- What the index holds against the vault: the paths to embed (not in the index, older than the
-- note, or a zero row) and the paths to drop (no longer a note). No embedding, no write. The rows of
-- notes under a folder that could not be read (`skipped`) are neither embedded nor dropped.
local function delta_of(self, note_paths, current, skipped)
  local built = self.live:build_index()
  local snapshot = self.live:stamps_snapshot()
  local stamps, values = {}, {}
  for r, p in ipairs(built.paths) do
    stamps[r] = snapshot[p] or guard.UNKNOWN_STAMP
  end
  local first = built.ffi and 0 or 1
  for k = 0, built.count * built.dim - 1 do
    values[k + 1] = built.data[first + k]
  end
  local diff = guard.diff_index_vs_vault(built.paths, note_paths)
  local gone = {}
  for _, p in ipairs(diff.stale) do
    gone[p] = true
  end
  local want, seen = {}, {}
  local function add(list)
    for _, p in ipairs(list) do
      if not seen[p] and not gone[p] then
        seen[p] = true
        want[#want + 1] = p
      end
    end
  end
  add(diff.missing)
  add(guard.find_stale_vector_paths(built.paths, stamps, current))
  add(guard.find_dead_vector_paths(built.paths, values, built.dim))
  table.sort(want)
  local had = {}
  for _, p in ipairs(built.paths) do
    had[p] = true
  end
  local drop, kept = {}, 0
  for _, p in ipairs(diff.stale) do
    if under_skipped(p, skipped or {}) then
      kept = kept + 1
    else
      drop[#drop + 1] = p
    end
  end
  return { embed = want, drop = drop, had = had, rows = #built.paths, unreadable_kept = kept }
end

-- Whether dropping `#drop` of `rows` rows leaves less than half AND one of the files is still
-- there (the walk missed it): then the vault was not read, the notes did not go. Files that are
-- truly gone (no entry) may take any share of the index with them.
local function drop_refused(rows, drop, root)
  if not guard.is_suspicious_shrink(rows, rows - #drop) then
    return false
  end
  for _, p in ipairs(drop) do
    local _, _, code = uv.fs_stat(root .. '/' .. p)
    if code ~= 'ENOENT' then
      return true
    end
  end
  return false
end

--- Brings the own index in line with the notes of the vault, in the background: embeds the notes
--- that are new, changed since their vector was made (the stamp `{ mtime, size }` of the row against
--- the file) or have a zero row, drops the rows of notes that are gone, then writes once
--- (`persist('heal')`). Notes empty after the front matter get no row (a row they had is dropped).
--- Reads the index file again first when it changed (`Ix:sync`), which replaces unsaved live changes
--- in memory: call this before own changes, never between an `update` and its `persist`. Asks the
--- guard about the model on disk BEFORE it embeds anything. Refused while a reindex or another
--- update runs. Progress is in `status(root)` (`kind = 'sync'`). `cb(result, err)`: `result` is
--- `{ embedded, removed, failed (paths), skipped_empty (paths), total, unreadable (folders the walk
--- could not read; the rows of their notes stay) }` or nil when the run did not
--- start; `err` is nil or `{ kind, message }` (the result was not written, memory is the disk again).
--- A write rewrites the file, so `index.current` loads a NEW `paths` table; nothing is mutated.
function Ix:sync_vault(cb)
  cb = cb or function() end
  local function fail(err)
    self.last_error = err
    cb(nil, err)
  end
  if self.run.running then
    return fail(running_failure(self))
  end
  local refusal = mode_refusal(self)
  if refusal then
    return fail(refusal)
  end
  local _, info = roots.mode(self.root, self.cfg)
  local paths, skipped = roots.note_paths(self.root, info.exclude, info.index_dir)
  if not paths then
    return fail(failure('no-notes', 'cannot read the notes: ' .. tostring(skipped)))
  end
  if #paths == 0 then
    return fail(
      failure('no-notes', 'no Markdown notes found under ' .. self.root .. ', so the index stays as it is')
    )
  end
  self:sync()
  -- Before any embedding: a blocked heal must not leave foreign vectors or spent calls behind.
  local decision = self.live:check_model_against_disk('heal')
  if not decision.allowed then
    return fail(refusal_failure(self, decision))
  end
  if not self.live:is_ready() then
    return fail(refusal_failure(self, { kind = 'not-ready' }))
  end
  local run = { running = true, kind = 'sync', done = 0, indexed = 0, total = 0, started = now_ms() }
  self.run = run
  self.last_error = nil
  self.write_error = nil
  local root = self.root
  local function finish(result, err)
    run.running = false
    self.last_error = err
    cb(result, err)
  end
  stamps_of_notes(root, paths, function(current)
    local ok, delta = pcall(delta_of, self, paths, current, skipped)
    if not ok then
      return finish(
        nil,
        failure('failed', 'the index could not be compared with the notes: ' .. tostring(delta))
      )
    end
    if drop_refused(delta.rows, delta.drop, root) then
      return finish(
        nil,
        failure(
          'shrink',
          'this update would drop more than half of the notes of the index although their files are still there,'
            .. ' so nothing was written; :NoteRetrieval reindex rebuilds the index'
        )
      )
    end
    run.total = #delta.embed
    for _, p in ipairs(delta.drop) do
      self.live:remove(p)
    end
    local removed = #delta.drop
    local function wrap_up(report)
      for _, p in ipairs(report.skipped_empty) do
        if delta.had[p] then
          self.live:remove(p)
          removed = removed + 1
        end
      end
      local result = {
        embedded = report.added,
        removed = removed,
        failed = report.failed,
        skipped_empty = report.skipped_empty,
        total = #delta.embed,
        unreadable = #(skipped or {}),
      }
      run.report = report
      if report.added == 0 and removed == 0 then
        return finish(result, nil)
      end
      local done, persisted, why = pcall(self.persist, self, 'heal')
      if not done then
        persisted, why = nil, raised_failure(persisted)
      end
      if not persisted then
        -- Memory holds a state that was refused: the disk is the truth again.
        self.seen = nil
        adopt(self)
        return finish(nil, why)
      end
      finish(result, nil)
    end
    if #delta.embed == 0 then
      return wrap_up({ added = 0, failed = {}, skipped_empty = {} })
    end
    self.live:heal_missing(delta.embed, function(path)
      return read_note(root, path)
    end, function(done_n, indexed, total)
      run.done, run.indexed, run.total = done_n, indexed, total
    end, function(path)
      return stamp_note(root, path)
    end, function(report, err)
      on_main_loop(function()
        if not report then
          -- Rows already embedded are in memory but unsaved; the disk is the truth again.
          self.seen = nil
          adopt(self)
          return finish(nil, failure('failed', 'the update failed: ' .. tostring(err)))
        end
        wrap_up(report)
      end)
    end)
  end)
end

--- `Ix:sync_vault` for the indexer of `root` (made by `for_root` before). `cb(result, err)`.
function M.sync(root, cb)
  local ix = entries[normalise(root)]
  if not ix then
    local err = failure('no-indexer', 'no indexer for this vault yet; :NoteRetrieval update makes one')
    return (cb or function() end)(nil, err)
  end
  ix:sync_vault(cb)
end

-- Update on save ---------------------------------------------------------------------------------

--- How long saves stay quiet before they are written, in milliseconds (read when the debouncer is made).
M.SAVE_DEBOUNCE_MS = 1000

local SAVE_GROUP = 'NoteRetrievalSave'

local attached = {} -- the roots whose saves are heard: { [root] = true }
local pending = {} -- the notes saved and not yet written: { [root] = { [relative path] = true } }
local reported = {} -- the refusals shown since the last success: { [root] = { [kind] = true } }
local hinted = {} -- the roots told once that a save finds no indexer: { [root] = true }
local save_group
local debouncer, debouncer_ms

-- Forgets a root for saves; the group goes when no root is left. An idle indexer is dropped (the
-- next `for_root` starts from the disk and the options of the moment).
local function detach(root)
  attached[root] = nil
  pending[root] = nil
  reported[root] = nil
  local ix = entries[root]
  if ix and not ix.run.running then
    entries[root] = nil
  end
  if save_group and next(attached) == nil then
    pcall(vim.api.nvim_del_augroup_by_id, save_group)
    save_group = nil
    if debouncer then
      debouncer.cancel()
    end
  end
end

-- A refusal is shown once per kind until the next success.
local function report_once(root, err)
  local kind = type(err) == 'table' and err.kind or 'failed'
  reported[root] = reported[root] or {}
  if reported[root][kind] then
    return
  end
  reported[root][kind] = true
  vim.notify('note-retrieval: ' .. tostring(type(err) == 'table' and err.message or err), vim.log.levels.WARN)
end

-- Writes the notes `rels` of the indexer after a save, in one sequence: read the disk state, apply
-- the updates, persist - nothing reads the disk between an update and its persist. A `changed`
-- refusal repeats the sequence once.
local function save_batch(ix, rels)
  local root = ix.root
  local function done_all(err, partial)
    ix.run = { running = false }
    if err then
      report_once(root, err)
    else
      reported[root] = nil
      if partial then
        report_once(root, partial)
      end
    end
    local waiting = ix.save_waiters
    ix.save_waiters = nil
    for _, cb in ipairs(waiting or {}) do
      cb()
    end
  end
  local function attempt(retried)
    ix:sync()
    if not ix.live:is_ready() then
      return done_all(refusal_failure(ix, { kind = 'not-ready' }))
    end
    local run = { running = true, kind = 'save', done = 0, indexed = 0, total = #rels, started = now_ms() }
    ix.run = run
    local updated, failed, i = 0, 0, 0
    local function persist_step()
      -- Persisting is synchronous: from here on nothing runs in between.
      ix.run = { running = false }
      if updated == 0 then
        return done_all(
          failed > 0
              and failure(
                'failed',
                ('%d saved note(s) could not be embedded (is the server still up?); :NoteRetrieval update tries again'):format(
                  failed
                )
              )
            or nil
        )
      end
      local ok, res, why = pcall(ix.persist, ix, 'live')
      if not ok then
        res, why = nil, raised_failure(res)
      end
      if res then
        return done_all(
          nil,
          failed > 0
              and failure(
                'failed',
                ('%d saved note(s) could not be embedded; :NoteRetrieval update tries again'):format(failed)
              )
            or nil
        )
      end
      -- Memory holds a state that was refused: the disk is the truth again.
      ix.seen = nil
      adopt(ix)
      if why.kind == 'changed' and not retried then
        return attempt(true)
      end
      done_all(why)
    end
    local function step()
      i = i + 1
      run.done = i - 1
      if i > #rels then
        return persist_step()
      end
      local rel = rels[i]
      local text = read_note(root, rel)
      if not text then
        return step() -- gone: :NoteRetrieval update finds it
      end
      local stamp = stamp_note(root, rel) -- after the read: an old stamp never sits on a new vector
      local started, err = pcall(ix.live.update, ix.live, rel, text, stamp, function(result)
        on_main_loop(function()
          if result then
            updated = updated + 1
            run.indexed = updated
          else
            failed = failed + 1
          end
          step()
        end)
      end)
      if not started then
        failed = failed + 1
        report_once(root, failure('failed', 'a saved note could not be indexed: ' .. tostring(err)))
        step()
      end
    end
    step()
  end
  attempt(false)
end

local function sorted_keys(set)
  local keys = vim.tbl_keys(set)
  table.sort(keys)
  return keys
end

-- The debouncer's run: every root with saved notes gets one batch, unless a reindex, an update or
-- another batch is running there; then the notes wait for the next window.
local function run_batches()
  local again = false
  for _, root in ipairs(sorted_keys(pending)) do
    local ix = entries[root]
    local set = pending[root]
    if not ix then
      pending[root] = nil
    elseif ix.run.running then
      again = true
    else
      pending[root] = nil
      local mode = roots.mode(root, ix.cfg)
      if mode == 'eigen' then
        save_batch(ix, sorted_keys(set))
      elseif mode ~= nil then
        detach(root)
      end
    end
  end
  if again then
    debouncer.call()
  end
end

local function get_debouncer()
  if not debouncer or debouncer_ms ~= M.SAVE_DEBOUNCE_MS then
    if debouncer then
      debouncer.cancel()
    end
    debouncer, debouncer_ms = debounce.new(M.SAVE_DEBOUNCE_MS, run_batches), M.SAVE_DEBOUNCE_MS
  end
  return debouncer
end

local function root_of(file)
  local best
  for root in pairs(attached) do
    if vim.startswith(file, root .. '/') and (not best or #root > #best) then
      best = root
    end
  end
  return best
end

-- Whether a saved note is one the index holds: relative path of a Markdown note, no dot parts,
-- not in an excluded folder or the index folder.
local function is_note(rel, info)
  if not rel:match('%.md$') or rel:match('^%.') or rel:match('/%.') then
    return false
  end
  for _, prefix in ipairs(info.exclude or {}) do
    if vim.startswith(rel, prefix) then
      return false
    end
  end
  return not (info.index_dir and vim.startswith(rel, (info.index_dir:gsub('/+$', '')) .. '/'))
end

local function on_write(ev)
  local file = vim.fs.normalize(vim.api.nvim_buf_get_name(ev.buf))
  local root = root_of(file)
  if not root then
    local real = uv.fs_realpath(file)
    file = real and vim.fs.normalize(real) or file
    root = root_of(file)
  end
  if not root then
    return
  end
  local ix = entries[root]
  local fresh = config.resolve()
  -- Read fresh at write time: a vault that became the Obsidian plugin's is not ours any more.
  local mode, info = roots.mode(root, ix and ix.cfg or fresh)
  if mode ~= 'eigen' then
    if mode ~= nil then
      detach(root)
    end
    return
  end
  if not fresh.index_on_save then
    return
  end
  local rel = file:sub(#root + 2)
  if not is_note(rel, info) then
    return
  end
  if not ix then
    -- No model is chosen in this session yet; a save never asks for one.
    if not hinted[root] then
      hinted[root] = true
      vim.notify(
        'note-retrieval: saved notes are not indexed yet in this session; run :NoteRetrieval update once to start',
        vim.log.levels.INFO
      )
    end
    return
  end
  pending[root] = pending[root] or {}
  pending[root][rel] = true
  get_debouncer().call()
end

--- Starts listening for saved notes of `root` (a vault whose mode is 'eigen'; the callers check):
--- one `BufWritePost` autocmd for all roots, installed on the first call, idempotent. A saved note
--- is written after `M.SAVE_DEBOUNCE_MS` of quiet: the notes of all saves in the window go in one
--- sequence (`sync`, `update` of each, one `persist`). The mode is read again at every save; when
--- the vault is not ours any more the root is dropped and the group goes with the last root.
--- Needs an indexer (`for_root`) to write; a save without one only hints once per root.
function M.attach_on_save(root)
  attached[normalise(root)] = true
  if not save_group then
    save_group = vim.api.nvim_create_augroup(SAVE_GROUP, { clear = true })
    vim.api.nvim_create_autocmd('BufWritePost', {
      group = save_group,
      pattern = '*.md',
      desc = 'note-retrieval: update the own index after a save',
      callback = on_write,
    })
  end
end

--- Writes the notes saved so far in `root` now, then calls `cb()` when no batch of it is running
--- any more (at once when there is nothing to wait for). `:NoteRetrieval update` starts with it, so
--- it never runs between unsaved changes and their persist.
function M.flush_saves(root, cb)
  local key = normalise(root)
  if debouncer and pending[key] then
    debouncer.flush()
  end
  local ix = entries[key]
  if ix and ix.run.running and ix.run.kind == 'save' then
    ix.save_waiters = ix.save_waiters or {}
    table.insert(ix.save_waiters, cb)
    return
  end
  cb()
end

--- Asks a running reindex to stop at the next group of notes; what it reached is written, nothing
--- else is lost. Returns true when one was running.
function M.stop(root)
  local ix = entries[normalise(root)]
  if not ix or not ix.run.running or ix.run.kind == 'sync' or ix.run.kind == 'save' then
    return false
  end
  ix.run.stopping = true
  ix.live:cancel_reindex()
  return true
end

local function lock_info(files, own)
  if own then
    return { state = 'own' }
  end
  local st = uv.fs_stat(files.lock)
  if not st then
    return { state = 'free' }
  end
  local sec, usec = uv.gettimeofday()
  local age = math.floor(sec + usec / 1e6 - (st.mtime.sec + st.mtime.nsec / 1e9))
  return { state = age > lock.STALE_AFTER_S and 'stale' or 'other', age = math.max(age, 0) }
end

--- What `root` has: `{ indexer, running, kind ('reindex'|'sync' while running), stopping, done, indexed, total, started (ms since the
--- epoch), lock = { state = 'free'|'own'|'other'|'stale', age }, last_error, warnings, report,
--- model, path }`. Needs no indexer; the lock is read from the file.
function M.status(root)
  local key = normalise(root)
  local ix = entries[key]
  local run = ix and ix.run or { running = false }
  return {
    indexer = ix ~= nil,
    running = run.running == true,
    kind = run.running and run.kind or nil,
    stopping = run.stopping == true,
    done = run.done or 0,
    indexed = run.indexed or 0,
    total = run.total or 0,
    started = run.started,
    report = run.report,
    lock = lock_info(ix and ix.files or state_files(key), ix ~= nil and ix.lock ~= nil),
    last_error = ix and ix.last_error or nil,
    warnings = ix and vim.list_slice(ix.warnings, 1) or {},
    model = ix and ix.model or nil,
    path = ix and ix.path or nil,
  }
end

--- The text for a statusline: `indexing 12/340` while a reindex runs in `root` (default: any root),
--- else the empty string. `vim.o.statusline = '%{v:lua.require("note_retrieval.indexer").statusline()}'`.
function M.statusline(root)
  local keys = root and { normalise(root) } or vim.tbl_keys(entries)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local ix = entries[key]
    if ix and ix.run.running then
      return ('%s %d/%d'):format(
        ix.run.stopping and 'stopping'
          or (ix.run.kind == 'sync' and 'updating' or (ix.run.kind == 'save' and 'saving' or 'indexing')),
        ix.run.done or 0,
        ix.run.total or 0
      )
    end
  end
  return ''
end

--- Forgets the idle indexers (of `root`, or of every root) so the next `for_root` starts from the
--- index on disk and the options of the moment. An indexer whose reindex is running is left alone.
--- Returns the roots that were kept for that reason.
function M.reset(root)
  local kept = {}
  local keys = {}
  if root then
    keys[1] = normalise(root)
  else
    local set = {}
    for key in pairs(entries) do
      set[key] = true
    end
    for key in pairs(attached) do
      set[key] = true
    end
    keys = sorted_keys(set)
  end
  for _, key in ipairs(keys) do
    local ix = entries[key]
    if ix and ix.run.running then
      kept[#kept + 1] = key
    else
      entries[key] = nil
      hinted[key] = nil
      detach(key)
    end
  end
  return kept
end

return M
