-- vendored from nvim-kit@0.17.0 (lua/nvim_kit/live_indexer.lua) — do not edit; re-vendor
-- The live indexer: one vector per note in memory, kept current note by note (`update`, `remove`,
-- `rename`), rebuilt all at once (`reindex_all`) or only where it is missing (`heal_missing`), and
-- written as one VRIX container with the guards of `index_guard` in front of every write. A
-- behavioural port of code-kit `live-indexer.ts` (tag 0.37.6, from vault-rag's `LiveIndexer`):
-- the same steps in the same order, so what it writes is byte for byte what vault-rag writes.
--
-- Everything outside is injected: the file store (`storage`), the embedding source (`embedder`)
-- and the way a note is read (`read`); there is no I/O in here besides them. The embedder is
-- asynchronous, by callback: `embedder(texts, cb)` with `cb(vectors)` (one list of numbers per
-- text) or `cb(nil, err)`. Call `cb` from the main loop: the indexer carries on right there and
-- then reads, decodes and writes files. A call from a fast `vim.uv` handler (`vim.in_fast_event()`)
-- works too since 0.15.0 (measured 2026-10-26: before, an intermediate state failed with E5560 and
-- the default `warn` aborted the run), with `fs_storage` or any storage that avoids Vimscript
-- functions; the callbacks you pass (`cb`, `on_progress`, `read`, `stamp_for`) then run there as
-- well, so a `cb` that persists or touches buffers should `vim.schedule` first.
--
-- A long run does not block Neovim: between two embedder calls the indexer only does cheap work,
-- and the next call waits for its answer. An embedder that answers at once (a test double) works as
-- well, with no recursion.
--
-- `dim` is the number of columns of the index (default 256, what vault-rag always wrote). An
-- index on disk with other columns is refused like one built with another model. `source_dim` in
-- the header is the length of the vectors the model returned before they were cut to `dim`: the
-- first one this indexer saw, else the value of the manifest it was initialised from, else `dim`.
--
-- Differences from the source, all of them about Lua and none about the bytes: results come by
-- callback or as `nil, err` instead of promises and exceptions; `read` is synchronous
-- (`read(path) -> text` or `nil, err`); numbers in the header are integers (`vrix.encode` raises
-- on a fraction, so a stamp or a `source_dim` that is no whole number is refused, not rounded);
-- a refusal text is English and no contract, the caller words its notice from `kind`.
--
-- Known limits. (1) An embedder answer that `vectors.to_index_vector` rejects (`{ vim.NIL }`,
-- `{ 42 }`) ends the run with `cb(nil, err)`, where the source counts a row of length 0 and `added`;
-- `llm.embed` checks its answer, so only a foreign embedder can get there. (2) Paths are ordered by
-- code point, as JS `.sort()` orders by UTF-16 unit: the two differ only for characters outside
-- the BMP (`！.md` U+FF01 against `😀.md`), and then the CRC differs from vault-rag's, so
-- "byte for byte what vault-rag writes" holds for every path inside the BMP (`text.byte_less`,
-- also used by `probe.order`).
local M = {}

-- Relative requires: a vendored copy loads its siblings under the plugin's namespace.
local base = (...):gsub('live_indexer$', '')
local chunker = require(base .. 'chunker')
local vectors = require(base .. 'vectors')
local vrix = require(base .. 'vrix')
local guard = require(base .. 'index_guard')
local text_lib = require(base .. 'text')
local date = require(base .. 'date')
local store = require(base .. 'store')

local has_ffi, ffi = pcall(require, 'ffi')

local floor = math.floor

--- What vault-rag always used.
M.DEFAULT_INDEX_DIM = 256
--- Notes between two intermediate states of a full reindex: small enough that an abort costs
--- little, large enough that writing the container does not dominate the run.
M.CHECKPOINT_EVERY = 250
--- Chunks per embedding request in a full reindex.
M.EMBED_BATCH = 32
--- int8 quantisation of a unit vector: +-1 is +-127. Part of the format; the reader takes `scale`
--- from the manifest.
M.INT8_SCALE = 127
--- The one file of an index, in the index directory.
M.CONTAINER_FILE = 'index.bin'

local REASONS = { live = true, reindex = true, heal = true }

local Ix = {}
Ix.__index = Ix

local function whole(v, min)
  return type(v) == 'number' and v == floor(v) and v >= min and v < math.huge
end

local function blocked(kind, message)
  return { kind = kind, message = message }
end

-- t[from..to] as a new list (`unpack` would put them all on the stack).
local function slice(t, from, to)
  local out = {}
  for i = from, to do
    out[#out + 1] = t[i]
  end
  return out
end

local function count_keys(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

-- The keys of a map sorted by bytes, never by the locale.
local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys, text_lib.byte_less)
  return keys
end

-- A stamp is { mtime, size }, two whole numbers (the header holds integers only).
local function check_stamp(stamp, fn)
  if stamp ~= nil then
    if type(stamp) ~= 'table' or not whole(stamp[1], -2 ^ 53) or not whole(stamp[2], -2 ^ 53) then
      error(('nvim-kit live_indexer: %s: a stamp is { mtime, size }, two whole numbers'):format(fn), 3)
    end
  end
end

-- Whether a value is a stamp: { mtime, size }, exactly two whole numbers (the test of `check_stamp`
-- as a question instead of an error, and a pair like the container's own check).
local function is_stamp(st)
  return type(st) == 'table' and #st == 2 and whole(st[1], -2 ^ 53) and whole(st[2], -2 ^ 53)
end

-- Milliseconds since the epoch as JavaScript's `toISOString` writes them.
local function iso8601(ms)
  ms = floor(ms)
  local secs = floor(ms / 1000)
  local msec = ms - secs * 1000
  local days = floor(secs / 86400)
  local rest = secs - days * 86400
  local y, m, d = date.civil_from_days(days)
  return ('%04d-%02d-%02dT%02d:%02d:%02d.%03dZ'):format(
    y,
    m,
    d,
    floor(rest / 3600),
    floor(rest % 3600 / 60),
    rest % 60,
    msec
  )
end

-- Coroutines inside, callbacks outside. `run` starts `body(task)`; when it returns, `done` gets
-- its results; an error in it goes to `cleanup` and then `done(nil, message)`. No `pcall` around
-- a yield (plain Lua 5.1 cannot cross one): `coroutine.resume` catches the error.
local function run(body, done, cleanup)
  local co = coroutine.create(body)
  local task = {}
  function task.resume(...)
    local ok, a, b = coroutine.resume(co, ...)
    if not ok then
      if cleanup then
        cleanup()
      end
      done(nil, tostring(a))
    elseif coroutine.status(co) == 'dead' then
      done(a, b)
    end
  end
  task.resume(task)
end

-- Calls `fn(cb)` and returns what `cb` is called with, suspending the task until then. An answer
-- that comes before `fn` returns is taken without suspending; a second answer is ignored.
local function await(task, fn)
  local state, ra, rb = 'running', nil, nil
  local function cb(a, b)
    if state == 'answered' then
      return
    end
    local before = state
    state = 'answered'
    if before == 'running' then
      ra, rb = a, b
    else
      task.resume(a, b)
    end
  end
  fn(cb)
  if state == 'answered' then
    return ra, rb
  end
  state = 'waiting'
  return coroutine.yield()
end

--- A new indexer. `storage = { exists(path) -> bool, read(path) -> bytes | nil, write(path,
--- bytes), mkdir(path) }` (`M.fs_storage()` is one over the file system); `dir` is the index
--- directory, `embedder(texts, cb)` as described on top, `model` the embedding model's name.
--- `opts = { dim = 256, now = function() return ms end, warn = function(message) end }`: `now`
--- is the clock for `built_at` in milliseconds since the epoch (default `os.time() * 1000`),
--- `warn` hears what a run survives (an intermediate state that could not be written; default
--- `vim.notify`, scheduled when called from a fast event). A `dim` that is no positive whole number
--- raises.
function M.new(storage, dir, embedder, model, opts)
  opts = opts or {}
  if
    type(storage) ~= 'table'
    or type(dir) ~= 'string'
    or type(embedder) ~= 'function'
    or type(model) ~= 'string'
  then
    error(
      'nvim-kit live_indexer: new needs storage (table), dir (string), embedder (function) and model (string)',
      2
    )
  end
  local dim = opts.dim
  if dim == nil then
    dim = M.DEFAULT_INDEX_DIM
  end
  if not whole(dim, 1) then
    error(('nvim-kit live_indexer: dim must be a positive whole number, was %s'):format(tostring(dim)), 2)
  end
  return setmetatable({
    dim = dim,
    _storage = storage,
    _dir = dir,
    _embedder = embedder,
    _model = model,
    _now = opts.now or function()
      return os.time() * 1000
    end,
    _warn = opts.warn or function(message)
      local function notify()
        vim.notify('nvim-kit live_indexer: ' .. message, vim.log.levels.WARN)
      end
      if vim.in_fast_event() then
        vim.schedule(notify) -- an embedder that answers from a `vim.uv` callback
      else
        notify()
      end
    end,
    _vectors = {}, -- path -> list of numbers
    -- path -> { mtime, size } of the note when it was embedded; kept in step with `_vectors`:
    -- every change there changes this too, or a stamp points at a foreign vector. Optional: a
    -- caller without stamps gets rows that persist writes as the unknown stamp.
    _stamps = {},
    _manifest = nil,
    _ready = false,
    -- Paths touched by a live handler DURING a `reindex_all` (a set); nil while none runs. A full
    -- reindex works through a snapshot of the paths and replaces the whole stock at the end:
    -- without this record everything that appears or changes meanwhile would fall out. The index
    -- ends up as the vault looks at the END of the run. Paths only, not vectors: the vector is
    -- looked up when applied, and `_vectors` is always the newest. A path that is gone there was
    -- a `remove`. Two runs at once share this field (a known limit, as in the source).
    _live = nil,
    _cancel = false,
    _observed_dim = nil, -- length of the first vector the model returned
    _loaded_dim = nil, -- `source_dim` of the manifest this indexer was initialised from
  }, Ix)
end

--- An storage over the file system: `io.open` for reading, `store.write_bytes` (atomic, fsync)
--- for writing, `mkdir -p` for the directory.
function M.fs_storage()
  return {
    exists = function(path)
      return vim.uv.fs_stat(path) ~= nil
    end,
    read = function(path)
      local f = io.open(path, 'rb')
      if not f then
        return nil
      end
      local data = f:read('*a')
      f:close()
      return data
    end,
    write = function(path, bytes)
      store.write_bytes(path, bytes)
    end,
    mkdir = function(path)
      store.mkdir_p(path)
    end,
  }
end

local function refusal_text(kind, a, b)
  if kind == 'not-ready' then
    return 'persist refused: the index is not initialised (load failure) - the good index on disk stays'
  elseif kind == 'unreadable' then
    return 'persist refused: the index on disk is not readable right now (a running sync or a parallel write) - the good index on disk stays untouched'
  elseif kind == 'shrink' then
    return ('persist refused: the index on disk has %d notes, this write has %d - a confused indexer would flatten a good index'):format(
      a,
      b
    )
  elseif kind == 'model-mismatch' then
    return ('persist refused: the index on disk was built with %q, this indexer embeds with %q - mixing two vector spaces is the damage itself'):format(
      a,
      b
    )
  end
  return ('persist refused: the index has %s columns, this indexer %d - the vectors would be cut or padded with zeros'):format(
    tostring(a),
    b
  )
end

--- Takes over a loaded index (`vectors.parse`, with its container's `manifest` on it as
--- `index.manifest` when `vault` and `source_dim` should be carried over) and, as `stamps`, either
--- the list of `{ mtime, size }` that goes with it row for row (any other length is ignored) or a
--- map by path such as `stamps_snapshot` returns. Raises `{ kind = 'dim-mismatch',
--- message }` when it has other columns than this indexer (an empty index has no vectors to
--- damage and is taken as it is). An indexer that has taken an index is ready.
function Ix:init(index, stamps)
  if type(index) ~= 'table' or type(index.paths) ~= 'table' then
    error('nvim-kit live_indexer: init needs an index (vectors.parse)', 2)
  end
  if index.count > 0 then
    local decision = guard.assert_dim_safe_to_persist(index.dim, self.dim, 'live')
    if not decision.allowed then
      error(
        setmetatable(blocked('dim-mismatch', refusal_text('dim-mismatch', index.dim, self.dim)), {
          __tostring = function(e)
            return 'nvim-kit live_indexer: dim-mismatch: ' .. e.message
          end,
        }),
        0
      )
    end
  end
  self._manifest = index.manifest
  local sd = index.manifest and index.manifest.source_dim
  self._loaded_dim = whole(sd, 1) and sd or nil
  self._vectors, self._stamps = {}, {}
  local dim = index.dim
  local data, first = index.data, index.ffi and 0 or 1
  for r = 1, #index.paths do
    local path = index.paths[r]
    local row = index.rows and index.rows[path] or r -- a path that repeats: the last row (a Map)
    local v = {}
    local at = first + (row - 1) * dim
    for c = 1, dim do
      v[c] = data[at + c - 1]
    end
    self._vectors[path] = v
  end
  -- Without taking the stamps over the guard would be blind after every restart: the first live
  -- persist would write the container without them.
  if type(stamps) == 'table' then
    if type(next(stamps)) == 'string' then
      -- A map by path, as `stamps_snapshot` hands it over: an index carries no stamps, so an
      -- indexer re-seeded from another one's `build_index()` would write `{ 0, 0 }` for every row
      -- it did not touch itself. Entries that are no stamp are skipped; a row without an entry
      -- stays unstamped - nothing is stamped that was not.
      for path in pairs(self._vectors) do
        local st = stamps[path]
        if is_stamp(st) then
          self._stamps[path] = { st[1], st[2] }
        end
      end
    elseif #stamps == #index.paths then
      for i, path in ipairs(index.paths) do
        local st = stamps[i]
        if st and self._vectors[path] then
          self._stamps[path] = { st[1], st[2] }
        end
      end
    end
  end
  self._ready = true
end

--- The stamps this indexer holds, by path, as a copy: hand it to the next indexer's
--- `init(index, stamps)` when the index is re-seeded (`new:init(old:build_index(),
--- old:stamps_snapshot())`). Only the stamped rows appear; a row without a stamp has no entry.
function Ix:stamps_snapshot()
  local out = {}
  for path, st in pairs(self._stamps) do
    out[path] = { st[1], st[2] }
  end
  return out
end

-- The length of the first vector the model returns, for `source_dim`.
function Ix:_observe(vecs)
  if self._observed_dim == nil then
    local first = vecs[1]
    local n = type(first) == 'table' and #first or 0
    if n > 0 then
      self._observed_dim = n
    end
  end
end

-- The vectors of one note (all its chunks) -> the row for the index.
function Ix:_row_from(vecs)
  self:_observe(vecs)
  return vectors.to_index_vector(vecs, self.dim)
end

-- Asks the embedder for `texts`; the list of vectors, or nil and why.
function Ix:_embed(task, texts)
  local vecs, err = await(task, function(cb)
    local ok, thrown = pcall(self._embedder, texts, cb)
    if not ok then
      cb(nil, thrown)
    end
  end)
  if type(vecs) ~= 'table' then
    return nil, err and tostring(err) or 'the embedder returned no vectors'
  end
  return vecs
end

local function chunk_texts(content)
  local out = {}
  for i, c in ipairs(chunker.chunk_markdown(content)) do
    out[i] = c.text
  end
  return out
end

-- The row for a note's content: the row, `false` when it has no chunk, or nil and why.
function Ix:_embed_note(task, content)
  local texts = chunk_texts(content)
  if #texts == 0 then
    return false
  end
  local vecs, err = self:_embed(task, texts)
  if not vecs then
    return nil, err
  end
  return self:_row_from(vecs)
end

-- No-op outside a reindex: the normal case costs one nil check.
function Ix:_note_live(path)
  if self._live then
    self._live[path] = true
  end
end

--- Embeds the note and keeps its vector (and `stamp`, `{ mtime, size }`, when given), then
--- `cb('indexed')`; a note without chunks (empty, frontmatter only) is taken out of the index
--- instead: `cb('empty')`. An embedding that fails changes nothing: `cb(nil, err)`.
function Ix:update(path, content, stamp, cb)
  if type(stamp) == 'function' and cb == nil then
    cb, stamp = stamp, nil
  end
  if type(path) ~= 'string' or type(content) ~= 'string' or type(cb) ~= 'function' then
    error('nvim-kit live_indexer: update(path, content, stamp?, cb) needs strings and a callback', 2)
  end
  check_stamp(stamp, 'update')
  run(function(task)
    local row, err = self:_embed_note(task, content)
    if row == nil then
      return nil, err
    end
    self:_note_live(path)
    if row then
      self._vectors[path] = row
      self._stamps[path] = stamp and { stamp[1], stamp[2] } or nil
      return 'indexed'
    end
    self._vectors[path] = nil
    self._stamps[path] = nil
    return 'empty'
  end, cb)
end

--- Takes a note out of the index, with its stamp.
function Ix:remove(path)
  self:_note_live(path)
  self._vectors[path] = nil
  self._stamps[path] = nil
end

--- Moves a note's vector and stamp to its new path.
function Ix:rename(old, new)
  -- The same path: nothing to move. Without this the entry is set and deleted again, and the
  -- note is gone.
  if old == new then
    return
  end
  self:_note_live(old)
  self:_note_live(new)
  local v = self._vectors[old]
  if v then
    self._vectors[new] = v
    self._vectors[old] = nil
  end
  local st = self._stamps[old]
  if st then
    self._stamps[new] = st
    self._stamps[old] = nil
  end
end

--- The number of notes in memory.
function Ix:note_count()
  return count_keys(self._vectors)
end

function Ix:is_ready()
  return self._ready
end

--- The no-index path: nothing on disk, so an empty indexer may build up safely.
function Ix:mark_fresh()
  self._ready = true
end

--- The danger state in the middle of a session: live persists are refused until `init` or
--- `mark_fresh`.
function Ix:mark_unready()
  self._ready = false
end

--- Asks a running `reindex_all` to stop at the next group boundary. Not the request: the loop. A
--- request that is on its way finishes, so its vectors are not lost. Does nothing when no run is
--- active; otherwise the wish would wait for the next run and kill it at once.
function Ix:cancel_reindex()
  if self._live ~= nil then
    self._cancel = true
  end
end

-- Stamps in row order, WITHOUT GAPS: a row without a known stamp carries the unknown one (a row
-- that is unchecked, not suspect). nil only when no stamp is known at all (an index from before
-- the guard); then the field stays out instead of filling every row with a placeholder. A gap
-- must not cost the stamps of the whole run: the field is parallel to `paths`.
function Ix:_stamps_for(paths, source)
  source = source or self._stamps
  if next(source) == nil then
    return nil
  end
  local out = {}
  for i, p in ipairs(paths) do
    local st = source[p]
    out[i] = st and { st[1], st[2] } or { guard.UNKNOWN_STAMP[1], guard.UNKNOWN_STAMP[2] }
  end
  return out
end

-- Folds the paths a live handler touched during the run into a reindex result. The live state
-- wins: it comes from an event the person caused while the reindex value comes from a read that
-- lay before it. (Where the reindex read is the younger one - debounce - both values come from
-- the same version of the file, as in the source.)
function Ix:_apply_live(result, result_stamps)
  if not self._live then
    return
  end
  for path in pairs(self._live) do
    local current = self._vectors[path]
    if current then
      result[path] = current
      -- Vector and stamp always travel together.
      result_stamps[path] = self._stamps[path]
    else
      result[path] = nil -- a remove, or a note that went empty
      result_stamps[path] = nil
    end
  end
end

--- The index as it is in memory: `{ paths (sorted by bytes), dim, count, data, ffi, rows,
--- manifest }`, shaped like `vectors.parse` makes it (so `vectors.search` and `vectors.related`
--- take it), with the values as they are, not quantised. Its manifest names THIS indexer's
--- model, whatever index it was initialised from.
function Ix:build_index()
  local paths = sorted_keys(self._vectors)
  local n, dim = #paths, self.dim
  local native = has_ffi
  local data = native and ffi.new('float[?]', math.max(n * dim, 1)) or {}
  local first = native and 0 or 1
  local rows = {}
  for r, p in ipairs(paths) do
    rows[p] = r
    local v = self._vectors[p]
    local at = first + (r - 1) * dim
    for c = 1, dim do
      local x = v[c] or 0
      data[at + c - 1] = native and x or vectors.fround(x)
    end
  end
  return {
    paths = paths,
    dim = dim,
    count = n,
    data = data,
    ffi = native,
    rows = rows,
    manifest = {
      schema_version = 1,
      embedding_model = self._model,
      index_dim = dim,
      scale = M.INT8_SCALE,
      count = n,
      granularity = 'note',
      quant = 'int8',
    },
  }
end

-- Number of notes and model of the container on disk, read from the disk itself (not from the
-- memory), ONE read for all the guards. nil: state unknown, refuse to be safe (a container is
-- there but cannot be read or decoded - a foreign process or a sync is writing it, or the CRC or
-- magic is wrong). No container is legitimately fresh (count 0, no model: nothing to protect).
function Ix:_disk_state()
  local path = self._dir .. '/' .. M.CONTAINER_FILE
  local ok, exists = pcall(self._storage.exists, path)
  if not ok then
    return nil
  end
  if not exists then
    return { count = 0, model = '', dim = nil }
  end
  local read_ok, bytes = pcall(self._storage.read, path)
  if not read_ok or type(bytes) ~= 'string' then
    return nil
  end
  local d = vrix.decode(bytes)
  if not d or type(d.manifest.count) ~= 'number' then
    return nil
  end
  local model, dim = d.manifest.embedding_model, d.manifest.index_dim
  return {
    count = d.manifest.count,
    model = type(model) == 'string' and model or '',
    dim = type(dim) == 'number' and dim or nil,
  }
end

-- The model and dimension guards against the disk state; a refusal or nil.
function Ix:_model_and_dim_refusal(disk, reason)
  local model_decision = guard.assert_model_safe_to_persist(disk.model, self._model, reason)
  if not model_decision.allowed then
    return blocked(
      model_decision.kind or 'model-mismatch',
      refusal_text('model-mismatch', disk.model, self._model)
    )
  end
  local dim_decision = guard.assert_dim_safe_to_persist(disk.dim, self.dim, reason)
  if not dim_decision.allowed then
    return blocked(dim_decision.kind or 'dim-mismatch', refusal_text('dim-mismatch', disk.dim, self.dim))
  end
  return nil
end

-- Writes ANY map of vectors as a container. The map is an argument and not `_vectors` because
-- the intermediate states write a map that is not the current stock; hanging it into the field
-- for a moment was the cause of a lost live update in the source (its "hole B").
-- Returns true, or nil and { kind, message } when a guard refuses.
function Ix:_persist_vectors(map, reason, stamp_model, stamps)
  local next_count = count_keys(map)
  if not self._ready and reason == 'live' then
    return nil, blocked('not-ready', refusal_text('not-ready'))
  end
  if reason ~= 'reindex' then
    -- The truth on disk instead of a cached state: a stale memory (a `mark_fresh` while a sync
    -- download was still running) must not overwrite a real, larger index.
    local disk = self:_disk_state()
    -- nil is no disk truth (damaged container, running sync). For `live` that stops the write;
    -- `heal` may go on, or the auto-heal could never overwrite a defective container.
    if disk == nil then
      if reason == 'live' then
        return nil, blocked('unreadable', refusal_text('unreadable'))
      end
    else
      -- The guards decide for themselves for whom they apply; the comparison is always against
      -- the container, never against the manifest in memory.
      local decision = guard.assert_safe_to_persist(disk.count, next_count, reason)
      if not decision.allowed then
        return nil, blocked(decision.kind or 'shrink', refusal_text('shrink', disk.count, next_count))
      end
      local refusal = self:_model_and_dim_refusal(disk, reason)
      if refusal then
        return nil, refusal
      end
    end
  end
  local paths = sorted_keys(map)
  local n, dim = #paths, self.dim
  local chunks = {}
  for r, p in ipairs(paths) do
    local v = map[p]
    -- a row longer than `dim` is cut, a shorter one is padded with zeros
    local q = vectors.quantize_int8(#v > dim and slice(v, 1, dim) or v, M.INT8_SCALE)
    local bytes = {}
    for i = 1, dim do
      local x = q[i] or 0
      bytes[i] = x < 0 and x + 256 or x
    end
    -- string.char takes its arguments from the stack: a row goes out in pieces
    local pieces = {}
    for from = 1, dim, 512 do
      pieces[#pieces + 1] = string.char(unpack(bytes, from, math.min(from + 511, dim)))
    end
    chunks[r] = table.concat(pieces)
  end
  self._storage.mkdir(self._dir)
  local manifest = {
    -- Purely informative, read by nobody. The indexer knows no vault name: empty is more honest
    -- than a stranger's.
    vault = self._manifest and self._manifest.vault or '',
    embedding_model = stamp_model or self._model,
    source_dim = self._observed_dim or self._loaded_dim or dim,
    index_dim = dim,
    granularity = 'note',
    aggregation = 'mean',
    quant = 'int8',
    scale = M.INT8_SCALE,
    count = n,
    source_commit = '',
    built_at = iso8601(self._now()),
  }
  -- ONE container instead of three files: a sync cannot mix generations any more.
  self._storage.write(
    self._dir .. '/' .. M.CONTAINER_FILE,
    vrix.encode(manifest, paths, table.concat(chunks), self:_stamps_for(paths, stamps))
  )
  self._ready = true
  return true
end

--- Writes the vectors in memory as the container, after the guards. `reason` is why: 'live' (a
--- note changed; the default), 'reindex' (a full rebuild; no guard applies) or 'heal' (additions
--- to an existing index). `stamp_model` is the model to write into the manifest when it is not
--- this indexer's: the vectors of an auto-heal that restores a backup come from the backup's
--- model, and stamping the configured endpoint would disarm the model guard at the next live
--- persist. Returns true, or nil and `{ kind, message }` with `kind` one of 'not-ready',
--- 'unreadable', 'shrink', 'model-mismatch', 'dim-mismatch'. Synchronous: it reads the disk
--- state and writes; a failing `storage` raises.
function Ix:persist(reason, stamp_model)
  reason = reason or 'live'
  if not REASONS[reason] then
    error(
      ('nvim-kit live_indexer: persist: unknown reason %q (live, reindex or heal)'):format(tostring(reason)),
      2
    )
  end
  return self:_persist_vectors(self._vectors, reason, stamp_model, nil)
end

--- The question before an ADDITIVE run that embeds first and persists after (`heal_missing`, then
--- `persist('heal')`): same rule and same disk truth as `persist`, asked before. A blocked heal
--- would otherwise leave foreign vectors in memory that nothing takes back, and a later, regular
--- persist would write them. Not embedding is cheaper than rolling back. Returns `{ allowed =
--- true }` or `{ allowed = false, kind, message }`; no mutation. 'reindex' is not asked (a full
--- replacement is the way out). Stricter than `persist` in one point: no readable container
--- (`unreadable`) forbids the run here, while `persist('heal')` lets it through - that case
--- belongs to the auto-heal that works on a proven backup; a person's "complete the index" has no
--- such base and nothing to check an additive mix against.
function Ix:check_model_against_disk(reason)
  if reason == 'reindex' then
    return { allowed = true }
  end
  if not REASONS[reason] then
    error(('nvim-kit live_indexer: check_model_against_disk: unknown reason %q'):format(tostring(reason)), 2)
  end
  local disk = self:_disk_state()
  if disk == nil then
    return { allowed = false, kind = 'unreadable', message = refusal_text('unreadable') }
  end
  local refusal = self:_model_and_dim_refusal(disk, reason)
  if refusal then
    return { allowed = false, kind = refusal.kind, message = refusal.message }
  end
  return { allowed = true }
end

-- Intermediate states only when the model on disk is the current one. They mix old and new
-- vectors: harmless within one model, but two vector spaces in one container otherwise - the
-- very damage `assert_model_safe_to_persist` prevents, and which reason 'reindex' deliberately
-- does not check. Asked with 'heal' on purpose: for 'reindex' the answer is always yes.
function Ix:_checkpoints_allowed()
  local ok, decision = pcall(self.check_model_against_disk, self, 'heal')
  return ok and decision.allowed
end

-- Recomputed rows plus the ones not yet reached from the stock so far: the complete state at any
-- moment of a run. Vector and stamp always come from the same source: a recomputed row with the
-- stamp of its previous embedding is exactly the mismatch the guard is built against.
function Ix:_mix_with_stock(fresh, fresh_stamps, paths)
  local mixed, mixed_stamps = {}, {}
  for _, p in ipairs(paths) do
    local f = fresh[p]
    local v = f or self._vectors[p]
    if v then
      mixed[p] = v
      if f then
        mixed_stamps[p] = fresh_stamps[p]
      else
        mixed_stamps[p] = self._stamps[p]
      end
    end
  end
  return mixed, mixed_stamps
end

-- Writes an intermediate state: complete (see `_mix_with_stock`), with what came in live. A
-- failure does not stop the run; an intermediate state is a bonus, not the promise.
function Ix:_persist_checkpoint(fresh, fresh_stamps, paths)
  local mixed, mixed_stamps = self:_mix_with_stock(fresh, fresh_stamps, paths)
  self:_apply_live(mixed, mixed_stamps)
  local ok, done, refusal = pcall(self._persist_vectors, self, mixed, 'reindex', nil, mixed_stamps)
  if not ok then
    self._warn('an intermediate state could not be written - the run goes on: ' .. tostring(done))
  elseif not done then
    self._warn(
      'an intermediate state was refused - the run goes on: ' .. tostring(refusal and refusal.message)
    )
  end
end

local function new_report()
  return { added = 0, skipped_empty = {}, failed = {}, cancelled = false }
end

--- Rebuilds the whole index from `paths`. `read(path)` returns the note's text, or `nil, err`
--- (a note that cannot be read is `failed`); `on_progress(done, indexed, total)` hears each note
--- as it is settled; `stamp_for(path)` gives `{ mtime, size }` or nil. `cb(report)` with `report =
--- { added, skipped_empty, failed, cancelled }` (`cb(nil, err)` when `read`'s helpers or the
--- indexer itself raise). The stock in memory is replaced at the END of the run, so the old index
--- stays searchable meanwhile; what the live handlers change during the run wins over what the
--- run read. The chunks of several notes go out in ONE embedder call per group of up to
--- `EMBED_BATCH` chunks (one note may cross the limit); a call that fails, or answers with
--- another number of vectors than chunks, falls back to one call per note. Every
--- `CHECKPOINT_EVERY` notes an intermediate state goes to disk (complete: recomputed rows plus
--- the stock) when the model on disk matches. `cancel_reindex` stops at a group boundary and
--- writes the same mix. Without a cancel `reindex_all` does not persist at the end: that is the
--- caller's `persist('reindex')`.
function Ix:reindex_all(paths, read, on_progress, stamp_for, cb)
  if type(paths) ~= 'table' or type(read) ~= 'function' or type(cb) ~= 'function' then
    error(
      'nvim-kit live_indexer: reindex_all(paths, read, on_progress?, stamp_for?, cb) needs a list, a function and a callback',
      2
    )
  end
  local fresh, fresh_stamps = {}, {}
  local report = new_report()
  local checkpoints = self:_checkpoints_allowed()
  -- From here on the live handlers record their paths.
  self._live = {}
  self._cancel = false
  local function cleanup()
    self._live = nil
    self._cancel = false
  end
  run(function(task)
    local since_last, done_count, i, total = 0, 0, 1, #paths
    local function progress()
      done_count = done_count + 1
      if on_progress then
        on_progress(done_count, report.added, total)
      end
    end
    while i <= total do
      -- Cancel ONLY at a group boundary: in the middle the vectors of a request on its way would
      -- be lost. Here the state is consistent - everything before `i` is decided.
      if self._cancel then
        report.cancelled = true
        break
      end
      -- (a) Fill a group: read and chunk until EMBED_BATCH chunks are together. One note may
      --     cross the limit.
      local group, chunk_count, without = {}, 0, 0
      while i <= total and chunk_count < M.EMBED_BATCH do
        local p = paths[i]
        i = i + 1
        local ok, text = pcall(read, p)
        if not ok or type(text) ~= 'string' then
          report.failed[#report.failed + 1] = p
          without = without + 1
          progress()
        else
          -- The stamp AFTER the read: taken before it and the note changing in between, an old
          -- stamp would sit on a new vector - the change would be invisible for good.
          local stamp = stamp_for and stamp_for(p) or nil
          check_stamp(stamp, 'reindex_all (stamp_for)')
          local chunks = chunk_texts(text)
          if #chunks == 0 then
            report.skipped_empty[#report.skipped_empty + 1] = p
            without = without + 1
            progress()
          else
            group[#group + 1] = { path = p, chunks = chunks, stamp = stamp }
            chunk_count = chunk_count + #chunks
          end
        end
      end
      -- (b) ONE call for the whole group.
      if #group > 0 then
        local all = {}
        for _, g in ipairs(group) do
          for _, c in ipairs(g.chunks) do
            all[#all + 1] = c
          end
        end
        local vecs = self:_embed(task, all)
        -- The length check is the seat belt: the answer is split among the notes by chunk count.
        -- An endpoint that returns fewer (or more) vectors than chunks would shift every
        -- assignment from there by the same amount - the staircase mismatch that hit ~79 % of a
        -- vault in the source's history, which a CRC cannot see. When in doubt, slow and right.
        if vecs and #vecs == chunk_count then
          local off = 0
          for _, g in ipairs(group) do
            local rows = slice(vecs, off + 1, off + #g.chunks)
            off = off + #g.chunks
            fresh[g.path] = self:_row_from(rows)
            report.added = report.added + 1
            fresh_stamps[g.path] = g.stamp
            progress()
          end
        else
          -- Fall back to one note at a time: a broken note must not drag the others down.
          for _, g in ipairs(group) do
            local single = self:_embed(task, g.chunks)
            if single then
              fresh[g.path] = self:_row_from(single)
              report.added = report.added + 1
              fresh_stamps[g.path] = g.stamp
            else
              report.failed[#report.failed + 1] = g.path
            end
            progress()
          end
        end
      end
      since_last = since_last + #group + without
      if checkpoints and since_last >= M.CHECKPOINT_EVERY and i <= total then
        since_last = 0
        self:_persist_checkpoint(fresh, fresh_stamps, paths)
      end
    end
    if report.cancelled then
      -- A cancel must cost NOTHING: `fresh` holds only the notes reached so far, and taking it
      -- as the stock would shrink the index from thousands to a handful. The same mix as an
      -- intermediate state is taken over instead.
      if checkpoints then
        local mixed, mixed_stamps = self:_mix_with_stock(fresh, fresh_stamps, paths)
        -- What came in live goes in AFTER the mix: it walks only the paths of the snapshot, and a
        -- note created or renamed during the run is not among them.
        self:_apply_live(mixed, mixed_stamps)
        local ok, done, refusal = pcall(self._persist_vectors, self, mixed, 'reindex', nil, mixed_stamps)
        if not ok then
          self._warn('the state after the cancel could not be written: ' .. tostring(done))
        elseif not done then
          self._warn('the state after the cancel was refused: ' .. tostring(refusal and refusal.message))
        end
        fresh, fresh_stamps = mixed, mixed_stamps
      else
        -- The index on disk belongs to another model (or could not be read): the mix would be one
        -- container of two vector spaces, and `reindex` lets every model through. Write nothing
        -- and keep the stock; the rows computed so far are lost, as an intermediate state would
        -- not have been written for the same reason.
        fresh, fresh_stamps = self._vectors, self._stamps
      end
    else
      -- The vault as it is at the END: what came in during the run wins over the snapshot.
      self:_apply_live(fresh, fresh_stamps)
    end
    cleanup()
    self._vectors, self._stamps = fresh, fresh_stamps
    self._ready = true
    return report
  end, cb, cleanup)
end

--- The additive delta run: embeds only the `missing` paths and adds them to the stock in memory
--- (NO reset): "complete the index", and the resume of an aborted full run. `cb(report)` as for
--- `reindex_all` (`cancelled` stays false: a delta run is not cancelled). A note that cannot be
--- read or embedded is `failed`, one without chunks `skipped_empty`. Ask
--- `check_model_against_disk('heal')` before, and persist with `persist('heal')` after.
function Ix:heal_missing(missing, read, on_progress, stamp_for, cb)
  if type(missing) ~= 'table' or type(read) ~= 'function' or type(cb) ~= 'function' then
    error(
      'nvim-kit live_indexer: heal_missing(missing, read, on_progress?, stamp_for?, cb) needs a list, a function and a callback',
      2
    )
  end
  local report = new_report()
  run(function(task)
    for i, path in ipairs(missing) do
      local ok, text = pcall(read, path)
      if not ok or type(text) ~= 'string' then
        report.failed[#report.failed + 1] = path
      else
        local row = self:_embed_note(task, text)
        if row then
          self._vectors[path] = row
          report.added = report.added + 1
          local st = stamp_for and stamp_for(path) or nil
          check_stamp(st, 'heal_missing (stamp_for)')
          if st then
            self._stamps[path] = { st[1], st[2] }
          end
        elseif row == false then
          report.skipped_empty[#report.skipped_empty + 1] = path
        else
          report.failed[#report.failed + 1] = path
        end
      end
      if on_progress then
        on_progress(i, report.added, #missing)
      end
    end
    self._ready = true
    return report
  end, cb)
end

return M
