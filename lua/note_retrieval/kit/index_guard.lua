-- vendored from nvim-kit@0.17.1 (lua/nvim_kit/index_guard.lua) — do not edit; re-vendor
-- Index guards: the decisions where an index write could lose data, as pure functions. A port of
-- code-kit `index-guard.ts` (tag 0.31.1, from vault-rag), proven by its conformance vectors.
--
-- A decision is `{ allowed = true }` or `{ allowed = false, kind = ... }`; `kind` is one of
-- 'shrink', 'model-mismatch', 'dim-mismatch'. code-kit adds a German `message` to a refusal; the
-- text is vault-rag's and no contract, so this port leaves it out: the caller words its notice
-- from `kind`. `reason` is why the write happens: 'live' (a note changed), 'reindex' (the person
-- asked for a full rebuild) or 'heal' (additions to an existing index).
local M = {}
-- Relative require: a vendored copy loads its sibling under the plugin's namespace.
local text_lib = require(((...):gsub('index_guard$', 'text')))

local js_trim = text_lib.js_trim

--- A stamp for "no stamp could be determined for this row". `{ 0, 0 }` cannot be a real note
--- (mtime 0 is 1970, and an empty note has no chunks, so it is never in an index); a row with it
--- is unchecked, not suspect. Valid under the same `schema_version`, so it breaks no format.
M.UNKNOWN_STAMP = { 0, 0 }

local function check_number(v, name, fn)
  if type(v) ~= 'number' then
    error(('nvim-kit index_guard: %s needs %s (a number)'):format(fn, name), 3)
  end
end

local function check_string(v, name, fn)
  if type(v) ~= 'string' then
    error(('nvim-kit index_guard: %s needs %s (a string)'):format(fn, name), 3)
  end
end

local function check_list(v, name, fn)
  if type(v) ~= 'table' then
    error(('nvim-kit index_guard: %s needs %s (a list)'):format(fn, name), 3)
  end
end

--- Whether a write may replace the index on disk, judged by the number of notes. 'reindex' and
--- 'heal' are asked for by the person and may shrink. 'live' (every note change) moves the count
--- by at most one, so a drop of more than one is data loss (an empty or confused indexer
--- flattening a good index): refused as 'shrink'.
function M.assert_safe_to_persist(disk_count, next_count, reason)
  check_number(disk_count, 'disk_count', 'assert_safe_to_persist')
  check_number(next_count, 'next_count', 'assert_safe_to_persist')
  check_string(reason, 'reason', 'assert_safe_to_persist')
  if reason ~= 'live' then
    return { allowed = true }
  end
  if next_count >= disk_count - 1 then
    return { allowed = true }
  end
  return { allowed = false, kind = 'shrink' }
end

--- Whether an index reloaded from disk is drastically smaller than the one in memory (the
--- suspicion of a clobber from another device): `incoming < current * ratio`, strictly. A
--- moderately smaller foreign index is legitimate. `ratio` defaults to 0.5; an empty `current`
--- (<= 0) is never suspicious.
function M.is_suspicious_shrink(current, incoming, ratio)
  check_number(current, 'current', 'is_suspicious_shrink')
  check_number(incoming, 'incoming', 'is_suspicious_shrink')
  if ratio == nil then
    ratio = 0.5
  end
  check_number(ratio, 'ratio', 'is_suspicious_shrink')
  if current <= 0 then
    return false
  end
  return incoming < current * ratio
end

--- Whether a candidate embedding model may serve the loaded index. A model change changes the
--- vector space: new vectors would not be comparable to the old ones, and no other guard (count,
--- CRC, dimension) sees it. An empty or missing `index_model` (no index, fresh install, an old
--- index without the field) matches everything. Otherwise equal after JavaScript's `trim`; model
--- names are case-sensitive.
function M.embedding_model_matches_index(model, index_model)
  check_string(model, 'model', 'embedding_model_matches_index')
  if index_model == nil then
    return true
  end
  check_string(index_model, 'index_model', 'embedding_model_matches_index')
  local want = js_trim(index_model)
  if want == '' then
    return true
  end
  return js_trim(model) == want
end

--- Whether the embedding model may write to the index that lies on disk. 'reindex' always (a full
--- replacement); 'live' and 'heal' not when the models differ, since mixing foreign vectors into
--- an existing index is the damage itself. A disk model that is missing or blank allows.
function M.assert_model_safe_to_persist(disk_model, model, reason)
  check_string(model, 'model', 'assert_model_safe_to_persist')
  check_string(reason, 'reason', 'assert_model_safe_to_persist')
  if reason == 'reindex' then
    return { allowed = true }
  end
  if disk_model == nil then
    return { allowed = true }
  end
  check_string(disk_model, 'disk_model', 'assert_model_safe_to_persist')
  local disk = js_trim(disk_model)
  if disk == '' then
    return { allowed = true }
  end
  if M.embedding_model_matches_index(model, disk) then
    return { allowed = true }
  end
  return { allowed = false, kind = 'model-mismatch' }
end

--- Whether a write with this dimension may go to the index on disk. A different dimension would
--- cut the vectors or pad them with zeros while count, CRC and structure look perfect. 'reindex'
--- always; 'live' and 'heal' not when they differ. A disk dimension that is missing, not a
--- finite number, or <= 0 (a fresh index, a container without the field) allows.
function M.assert_dim_safe_to_persist(disk_dim, dim, reason)
  check_number(dim, 'dim', 'assert_dim_safe_to_persist')
  check_string(reason, 'reason', 'assert_dim_safe_to_persist')
  if reason == 'reindex' then
    return { allowed = true }
  end
  if
    type(disk_dim) ~= 'number'
    or disk_dim ~= disk_dim
    or disk_dim == math.huge
    or disk_dim == -math.huge
  then
    return { allowed = true }
  end
  if disk_dim <= 0 or disk_dim == dim then
    return { allowed = true }
  end
  return { allowed = false, kind = 'dim-mismatch' }
end

--- The difference of two path lists as sets: `missing` is in the vault but not in the index
--- (candidates for healing), `stale` in the index but no longer in the vault. Each keeps its
--- list's order.
function M.diff_index_vs_vault(index_paths, vault_paths)
  check_list(index_paths, 'index_paths', 'diff_index_vs_vault')
  check_list(vault_paths, 'vault_paths', 'diff_index_vs_vault')
  local in_index, in_vault = {}, {}
  for _, p in ipairs(index_paths) do
    in_index[p] = true
  end
  for _, p in ipairs(vault_paths) do
    in_vault[p] = true
  end
  local missing, stale = {}, {}
  for _, p in ipairs(vault_paths) do
    if not in_index[p] then
      missing[#missing + 1] = p
    end
  end
  for _, p in ipairs(index_paths) do
    if not in_vault[p] then
      stale[#stale + 1] = p
    end
  end
  return { missing = missing, stale = stale }
end

--- The paths whose row of `values` is all zeros: structurally dead entries. The path is in the
--- index, but a zero vector fits no query (cosine against it is always 0), so the note cannot be
--- found while no other check reports it. `values` is a row-major matrix, one number per
--- element, 1-based like any Lua list (`dim` per row); `paths[r]` names row r.
function M.find_dead_vector_paths(paths, values, dim)
  check_list(paths, 'paths', 'find_dead_vector_paths')
  check_list(values, 'values', 'find_dead_vector_paths')
  check_number(dim, 'dim', 'find_dead_vector_paths')
  local dead = {}
  for r = 1, #paths do
    local alive = false
    for c = 1, dim do
      if values[(r - 1) * dim + c] ~= 0 then
        alive = true
        break
      end
    end
    if not alive then
      dead[#dead + 1] = paths[r]
    end
  end
  return dead
end

--- The paths whose vector is OLDER than the note: the stamp stored with the row (`{ mtime, size }`)
--- differs from the note's `current[path]`. A false alarm only costs re-embedding; the dangerous
--- opposite would need a write that changes neither time nor size. `stamps` nil, or not as long
--- as `paths` (an index from before stamps), reports nothing: unchecked is not suspect. A row
--- stamped `UNKNOWN_STAMP` is skipped, and so is a path missing from `current` (a deleted note
--- belongs to `diff_index_vs_vault`, or two guards would report one finding).
function M.find_stale_vector_paths(paths, stamps, current)
  check_list(paths, 'paths', 'find_stale_vector_paths')
  check_list(current, 'current', 'find_stale_vector_paths')
  if stamps == nil or #stamps ~= #paths then
    return {}
  end
  local stale = {}
  for r = 1, #paths do
    local path = paths[r]
    local now = current[path]
    local stamp = stamps[r]
    if now and stamp then
      local mtime, size = stamp[1], stamp[2]
      if not (mtime == M.UNKNOWN_STAMP[1] and size == M.UNKNOWN_STAMP[2]) then
        if now[1] ~= mtime or now[2] ~= size then
          stale[#stale + 1] = path
        end
      end
    end
  end
  return stale
end

--- How many rows carry no usable stamp: the rows stamped `UNKNOWN_STAMP`, `{ 0, 0 }`. The
--- counterpart of `find_stale_vector_paths`, which skips exactly these rows ("not checked is not
--- suspect"), so a stale vector under such a row passes unseen; this says how many rows those are.
--- Only `{ 0, 0 }` counts, both numbers zero: `{ 0, 1 }` and `{ 1, 0 }` are stamps of a real note,
--- however odd. `stamps` nil (an index from before the guard) gives `0`: the whole index is
--- unchecked, a different statement from "some rows are", and the caller tells them apart by
--- `stamps == nil`. A hole or a row that is not a pair is not counted either.
function M.count_unstamped_rows(stamps)
  if stamps == nil then
    return 0
  end
  check_list(stamps, 'stamps', 'count_unstamped_rows')
  local n = 0
  for _, stamp in ipairs(stamps) do
    if type(stamp) == 'table' and stamp[1] == M.UNKNOWN_STAMP[1] and stamp[2] == M.UNKNOWN_STAMP[2] then
      n = n + 1
    end
  end
  return n
end

return M
