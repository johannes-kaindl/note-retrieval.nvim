-- Live run against a real embedding server: the fixture vault is indexed in its own mode through the
-- plugin, then `related` and the self-find probe run over that index. Not part of `make check`
-- (CORE-TEST-02: a stubbed server specifies, only a real one tests).
--   NOTE_RETRIEVAL_LIVE_URL=http://localhost:1234 NOTE_RETRIEVAL_LIVE_MODEL=<embedding model> make live
-- Exit 0: a note of the same topic is among the related notes of a fixture note. Exit 1: it is not,
-- or the run failed. Exit 2: nothing was measured (a variable unset, or no server) — never a pass.
-- `make live` prints the script's code as the line `live: exit N`; make itself exits 2 on any non-zero.
-- A spec can load this file as a library (vim.g.note_retrieval_live_lib set first): it then returns
-- `{ parse_env, main }` and runs nothing.
local M = {}

M.URL, M.MODEL = 'NOTE_RETRIEVAL_LIVE_URL', 'NOTE_RETRIEVAL_LIVE_MODEL'
M.NOTE = 'Baking/hydration.md'

--- `env` is a table with the two variables. Returns `{ url, model }`, or `nil, message` when one is
--- missing or empty (the message names both variables).
function M.parse_env(env)
  local url, model = env[M.URL], env[M.MODEL]
  if type(url) ~= 'string' or url == '' or type(model) ~= 'string' or model == '' then
    return nil,
      ('live: nothing measured: set %s (server address) and %s (embedding model) first'):format(
        M.URL,
        M.MODEL
      )
  end
  return { url = url, model = model }
end

--- The result line. The notes that failed to embed stand in it: a partial failure passes the run
--- (some notes are enough to relate), and the number is the only place it shows.
function M.summary(f)
  return ('live: %s, %d notes in %.1f s (%d failed), %s: %d of %d related in %s, probe %s'):format(
    f.model,
    f.added,
    f.secs,
    f.failed,
    f.note,
    f.same,
    f.related,
    f.topic,
    f.probe and ('%d of %d found'):format(f.probe.hits, f.probe.n) or ('failed: ' .. vim.inspect(f.probe_err))
  )
end

local function out(line)
  io.write(line, '\n')
end

-- Waits for `start(done)` to call `done(...)`; returns what it got, or nothing after `ms`.
local function await(start, ms)
  local got
  start(function(...)
    got = vim.F.pack_len(...)
  end)
  vim.wait(ms, function()
    return got ~= nil
  end, 20)
  if got then
    return vim.F.unpack_len(got)
  end
end

--- Returns the exit code.
function M.main()
  local env, message = M.parse_env({
    [M.URL] = vim.env[M.URL],
    [M.MODEL] = vim.env[M.MODEL],
  })
  if not env then
    out(message)
    return 2
  end
  local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
  vim.opt.rtp:prepend(root)
  vim.env.XDG_STATE_HOME = vim.fn.tempname()
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, 'p')
  vim.fn.system({ 'cp', '-R', root .. '/tests/fixtures/vault', base .. '/vault' })
  local vault = vim.uv.fs_realpath(base .. '/vault')
  vim.g.note_retrieval = {
    endpoints = { { url = env.url, model = env.model } },
    index_dir = '_index',
    probe_auto = false,
    min_similarity = 0,
    timeout_ms = 60000,
  }
  local code = (function()
    local cfg = require('note_retrieval.config').resolve()
    local t = vim.uv.hrtime()
    local resolved, rerr = await(function(done)
      require('note_retrieval.embedder').resolve(cfg, nil, done)
    end, 90000)
    if not resolved then
      local kind = rerr and rerr.kind or 'timeout'
      out(('live: no embedding server (%s): %s'):format(kind, vim.inspect(rerr and rerr.detail or '')))
      return 2
    end
    local ix, why = require('note_retrieval.indexer').for_root(
      vault,
      { resolved = resolved, dim = resolved.dim, cfg = cfg }
    )
    if not ix then
      out('live: FAIL no indexer: ' .. tostring(why))
      return 1
    end
    local report, err = await(function(done)
      ix:reindex(done)
    end, 600000)
    if not report then
      out('live: FAIL reindex: ' .. (err and err.message or 'did not finish'))
      return 1
    end
    if report.added == 0 then
      out(('live: nothing embedded (%d failed): the server did not answer'):format(#(report.failed or {})))
      return 2
    end
    local hits, rel_err = require('note_retrieval.search').related(M.NOTE, { root = vault, k = 5 })
    if not hits then
      out('live: FAIL related: ' .. tostring(rel_err))
      return 1
    end
    local topic = M.NOTE:match('^(%a+)/')
    local same = 0
    for _, h in ipairs(hits) do
      if h.path:match('^(%a+)/') == topic then
        same = same + 1
      end
    end
    local probe, perr = await(function(done)
      require('note_retrieval.probe').run(vault, { n = 6 }, done)
    end, 120000)
    local secs = (vim.uv.hrtime() - t) / 1e9
    out(M.summary({
      model = resolved.model,
      added = report.added,
      failed = #(report.failed or {}),
      secs = secs,
      note = M.NOTE,
      same = same,
      related = #hits,
      topic = topic,
      probe = probe,
      probe_err = perr,
    }))
    local pass = same > 0
    out(pass and 'live: PASS' or 'live: FAIL (no note of the same topic among the related notes)')
    return pass and 0 or 1
  end)()
  require('note_retrieval.indexer').reset()
  vim.fn.delete(base, 'rf')
  return code
end

if vim.g.note_retrieval_live_lib then
  return M
end
os.exit(M.main())
