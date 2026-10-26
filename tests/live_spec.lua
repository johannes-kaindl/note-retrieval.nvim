-- The argument handling of tests/live.lua (`make live`): exit 2 and a message that names both
-- variables when one is missing. The run against a server is not tested here (it needs one).
local T = require('note_retrieval.kit.test')

local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')

local function load_live()
  vim.g.note_retrieval_live_lib = true
  local ok, live = pcall(dofile, here .. '/live.lua')
  vim.g.note_retrieval_live_lib = nil
  assert(ok, live)
  return live
end

T.case('live: both variables set give url and model', function()
  local live = load_live()
  T.eq(
    live.parse_env({ NOTE_RETRIEVAL_LIVE_URL = 'http://h:1', NOTE_RETRIEVAL_LIVE_MODEL = 'm' }),
    { url = 'http://h:1', model = 'm' }
  )
end)

T.case('live: a missing or empty variable gives a message naming both, so main exits 2', function()
  local live = load_live()
  for _, env in ipairs({
    {},
    { NOTE_RETRIEVAL_LIVE_URL = 'http://h:1' },
    { NOTE_RETRIEVAL_LIVE_MODEL = 'm' },
    { NOTE_RETRIEVAL_LIVE_URL = '', NOTE_RETRIEVAL_LIVE_MODEL = 'm' },
  }) do
    local parsed, message = live.parse_env(env)
    T.eq(parsed, nil)
    T.ok(message:find('NOTE_RETRIEVAL_LIVE_URL', 1, true), message)
    T.ok(message:find('NOTE_RETRIEVAL_LIVE_MODEL', 1, true), message)
  end
end)

T.case('live: loaded as a library it runs nothing and does not exit', function()
  local live = load_live()
  T.eq(type(live.main), 'function')
  T.eq(type(live.parse_env), 'function')
end)
