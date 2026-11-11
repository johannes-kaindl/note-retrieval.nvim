-- vendored from nvim-kit@0.17.1 (lua/nvim_kit/wait.lua) — do not edit; re-vendor
-- Waiting for an asynchronous answer where a plugin must return a value (a health check, a
-- `:write` that has to know the result).
local M = {}

--- Call `start(cb)` and block, with `vim.wait`, until `cb` has been called or `timeout_ms` has
--- passed. Returns `value, true, handle` with the first value given to `cb`, or `nil, false,
--- handle` on timeout; the second result tells an answer of `nil` (`nil, true`) from no answer,
--- and `handle` is what `start` returned (a request handle to `cancel()` after a timeout). Only
--- the first argument of `cb` is kept: `cb(nil, err)` gives `nil, true`. Ctrl-C during the wait
--- ends `vim.wait` early and looks like a timeout. Later calls of `cb`
--- (a second answer, one after the timeout) are ignored. Events and callbacks keep running while
--- it waits. Must not be called from a fast callback (`vim.uv` handlers, `vim.system`'s
--- callbacks): it raises before `start` runs. Raises when `start` is not a function or `timeout_ms`
--- is not a number >= 0; an error in `start` propagates.
function M.result(start, timeout_ms)
  if type(start) ~= 'function' then
    error('nvim-kit wait: result: start must be a function', 2)
  end
  if type(timeout_ms) ~= 'number' or timeout_ms ~= timeout_ms or timeout_ms < 0 then
    error('nvim-kit wait: result: timeout_ms must be a number >= 0', 2)
  end
  if vim.in_fast_event() then
    error('nvim-kit wait: result: cannot wait in a fast callback (vim.schedule first)', 2)
  end
  local done, value = false, nil
  local handle = start(function(v)
    if not done then
      done, value = true, v
    end
  end)
  local answered = vim.wait(timeout_ms, function()
    return done
  end, 10)
  if not answered then
    done = true -- the late callback must not store anything
    return nil, false, handle
  end
  return value, true, handle
end

return M
