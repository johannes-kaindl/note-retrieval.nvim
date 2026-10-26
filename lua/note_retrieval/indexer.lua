-- domain: note_retrieval
-- The writer of the own index (mode 'eigen'): one indexer per vault root, a full reindex with
-- progress, and every write behind the same four steps - mode check, lock, backup, the kit's guards
-- and atomic write. Nothing here runs in mode 'obsidian': the file belongs to the Obsidian plugin.
--
-- Every write of the kit's `live_indexer` (a live persist, an intermediate state of a reindex, the
-- state after a cancel) goes through the storage wrapper below, so none of them can skip a step.
-- Errors are values `{ kind, message }` (`message` is a plain sentence with the next step); the
-- kinds are: locked, not-eigen, options-changed, model-mismatch, dim-mismatch, shrink, not-ready,
-- unreadable, changed, backup-failed, write-failed, running, no-notes, incomplete, failed.
local config = require('note_retrieval.config')
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

local function on_main_loop(fn)
  if vim.in_fast_event() then
    vim.schedule(fn)
  else
    fn()
  end
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
    return fail(failure('running', 'a reindex is already running; :NoteRetrieval stop ends it'))
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
  local run = { running = true, done = 0, indexed = 0, total = #paths, started = now_ms(), stopping = false }
  self.run = run
  self.backup_next = true
  self.last_error = nil
  local root = self.root
  local function read(path)
    local f, err = io.open(root .. '/' .. path, 'rb')
    if not f then
      return nil, err
    end
    local text = f:read('*a')
    f:close()
    return text
  end
  -- The stamp is taken by the kit AFTER `read`, so an old stamp never sits on a new vector.
  local function stamp_for(path)
    local st = uv.fs_stat(root .. '/' .. path)
    if not st then
      return nil
    end
    return { st.mtime.sec * 1000 + math.floor(st.mtime.nsec / 1e6), st.size }
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

--- Asks a running reindex to stop at the next group of notes; what it reached is written, nothing
--- else is lost. Returns true when one was running.
function M.stop(root)
  local ix = entries[normalise(root)]
  if not ix or not ix.run.running then
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

--- What `root` has: `{ indexer, running, stopping, done, indexed, total, started (ms since the
--- epoch), lock = { state = 'free'|'own'|'other'|'stale', age }, last_error, warnings, report,
--- model, path }`. Needs no indexer; the lock is read from the file.
function M.status(root)
  local key = normalise(root)
  local ix = entries[key]
  local run = ix and ix.run or { running = false }
  return {
    indexer = ix ~= nil,
    running = run.running == true,
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
        ix.run.stopping and 'stopping' or 'indexing',
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
  local keys = root and { normalise(root) } or vim.tbl_keys(entries)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local ix = entries[key]
    if ix then
      if ix.run.running then
        kept[#kept + 1] = key
      else
        entries[key] = nil
      end
    end
  end
  return kept
end

return M
