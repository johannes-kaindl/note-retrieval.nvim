-- vendored from nvim-kit@0.16.1 (lua/nvim_kit/debounce.lua) — do not edit; re-vendor
-- Debouncing: many calls in a burst, one run after things have been quiet for a while.
local M = {}

local uv = vim.uv or vim.loop

--- A debouncer: `d.call(...)` (re)starts a timer of `ms` milliseconds and remembers the
--- arguments; when `ms` pass without another call, `fn` runs once with the arguments of the LAST
--- call. `d.cancel()` drops a pending call (also one whose timer has fired but whose run has not
--- come round yet) and returns whether there was one. `d.flush()` runs a pending call now,
--- synchronously, with its arguments, and returns true; with nothing pending it does nothing and
--- returns false. `fn` runs on the main loop (`vim.schedule`), so it may use the whole Neovim API;
--- an error in it surfaces like any scheduled callback's. `call` is safe from a fast callback
--- (`vim.uv` handlers). The timer is created here, so `new` must not run in a fast callback;
--- on `VimLeavePre` the timer is closed and a pending call is dropped, not run (`flush()` first
--- where it matters); `call` after that does nothing. Raises when `ms` is not a number >= 0 or
--- `fn` is not a function.
function M.new(ms, fn)
  if type(ms) ~= 'number' or ms ~= ms or ms < 0 then
    error('nvim-kit debounce: new(ms, fn) needs ms as a number >= 0', 2)
  end
  if type(fn) ~= 'function' then
    error('nvim-kit debounce: new(ms, fn) needs fn as a function', 2)
  end
  local self = {}
  local timer = uv.new_timer()
  local generation = 0 -- bumped by every call, cancel and run: a stale timer or schedule is ignored
  local pending = nil -- the last call's arguments, packed with `vim.F.pack_len`
  local closed = false

  local function run()
    local args = pending
    pending = nil
    generation = generation + 1
    fn(vim.F.unpack_len(args))
  end

  function self.call(...)
    if closed then
      return
    end
    generation = generation + 1
    local mine = generation
    pending = vim.F.pack_len(...)
    timer:stop()
    timer:start(ms, 0, function()
      vim.schedule(function()
        if pending and generation == mine then
          run()
        end
      end)
    end)
  end

  function self.cancel()
    local had = pending ~= nil
    pending = nil
    generation = generation + 1
    if not closed then
      timer:stop()
    end
    return had
  end

  function self.flush()
    if not pending then
      return false
    end
    timer:stop()
    run()
    return true
  end

  vim.api.nvim_create_autocmd('VimLeavePre', {
    once = true,
    callback = function()
      closed = true
      pending = nil
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
    end,
  })
  return self
end

return M
