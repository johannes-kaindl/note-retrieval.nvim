-- vendored from nvim-kit@0.15.0 (lua/nvim_kit/index_delta.lua) — do not edit; re-vendor
-- The numbers behind "embedded / total notes" and the split of the healing targets. A port of
-- code-kit `index-delta.ts` (tag 0.31.1, from vault-rag), proven by its conformance vectors.
-- Empty notes (nothing but frontmatter) have no chunks and so can never land in an index: they
-- count neither as missing nor in the target.
local M = {}

local function check_list(v, name, fn)
  if type(v) ~= 'table' then
    error(('nvim-kit index_delta: %s needs %s (a list of paths)'):format(fn, name), 3)
  end
end

local function set_of(list)
  local set = {}
  for _, p in ipairs(list) do
    set[p] = true
  end
  return set
end

--- `{ embedded, total, emptyCount }` for a vault of `total` notes of which `missing` (paths) are
--- not in the index and `empty` (paths, a list) are known to be chunkless. Only the intersection
--- missing ∩ empty counts as empty: an empty path that is (still) in the index stays in the
--- target.
function M.compute(total, missing, empty)
  if type(total) ~= 'number' then
    error('nvim-kit index_delta: compute needs total (a number)', 2)
  end
  check_list(missing, 'missing', 'compute')
  check_list(empty, 'empty', 'compute')
  local empties = set_of(empty)
  local empty_count = 0
  for _, p in ipairs(missing) do
    if empties[p] then
      empty_count = empty_count + 1
    end
  end
  local net = total - empty_count
  return { embedded = net - (#missing - empty_count), total = net, emptyCount = empty_count }
end

--- Splits the missing paths into work to do (`embeddable`) and paths already known to be empty
--- (`knownEmpty`), each in the order of `missing`: empty ones are not embedded again, so they
--- distort neither the progress counter nor the closing message.
function M.split_heal_targets(missing, empty)
  check_list(missing, 'missing', 'split_heal_targets')
  check_list(empty, 'empty', 'split_heal_targets')
  local empties = set_of(empty)
  local embeddable, known_empty = {}, {}
  for _, p in ipairs(missing) do
    if empties[p] then
      known_empty[#known_empty + 1] = p
    else
      embeddable[#embeddable + 1] = p
    end
  end
  return { embeddable = embeddable, knownEmpty = known_empty }
end

return M
