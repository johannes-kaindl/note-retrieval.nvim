-- vendored from nvim-kit@0.15.0 (lua/nvim_kit/data.lua) — do not edit; re-vendor
-- Load a JSON data file that declares its schema version. Fails loudly on a missing file,
-- broken JSON or a different schema — never returns half-understood data. Nulls inside
-- objects are absent fields (luanil).
local M = {}

function M.load(path, opts)
  if type(opts) ~= 'table' or type(opts.schema) ~= 'number' then
    error('nvim-kit data: opts.schema (number) is required', 2)
  end
  local f = io.open(path, 'r')
  if not f then
    error(('nvim-kit data: cannot read %s'):format(path), 2)
  end
  local text = f:read('*a')
  f:close()
  local ok, decoded = pcall(vim.json.decode, text, { luanil = { object = true } })
  if not ok then
    error(('nvim-kit data: %s is not valid JSON: %s'):format(path, decoded), 2)
  end
  local schema = type(decoded) == 'table' and decoded.schema or nil
  if schema ~= opts.schema then
    error(('nvim-kit data: %s has schema %s, expected %s'):format(path, tostring(schema), opts.schema), 2)
  end
  return decoded
end

--- Absolute path of `rel` beside a Lua file, given as its debug source:
---   data.beside(debug.getinfo(1, 'S').source, 'data/x.json')
--- A module finds its data this way in the kit and in a vendored copy under lua/<plugin>/kit/
--- alike, where no lookup by module name could. The caller passes its own source (level 1) on
--- purpose: a helper that looked one level up itself would see past a tail call
--- (`return data.beside(…)`) and resolve against the wrong file. Raises for a source that is not
--- a file (a chunk loaded from a string has no directory).
function M.beside(source, rel)
  if type(source) ~= 'string' or source:sub(1, 1) ~= '@' then
    error(
      ("nvim-kit data: beside() needs a file source (debug.getinfo(1, 'S').source), got %s"):format(
        vim.inspect(source)
      ),
      2
    )
  end
  return vim.fn.fnamemodify(source:sub(2), ':p:h') .. '/' .. rel
end

return M
