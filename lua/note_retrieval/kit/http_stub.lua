-- vendored from nvim-kit@0.15.0 (lua/nvim_kit/http_stub.lua) — do not edit; re-vendor
-- A tiny HTTP/1.1 server for tests, on 127.0.0.1 with a free port, in the test's own Neovim
-- (vim.uv). It answers fixed responses per route and records every request. Wait for an answer
-- with vim.wait(); the loop runs while the test waits.
--   local srv = stub.start({ ['GET /v1/models'] = { body = { data = { { id = 'm' } } } } })
--   … srv.url, srv.requests[1].headers.authorization … srv.close()
local M = {}

local REASON =
  { [200] = 'OK', [400] = 'Bad Request', [401] = 'Unauthorized', [404] = 'Not Found', [500] = 'Error' }

local function parse(head)
  local method, path = head:match('^(%u+) (%S+) HTTP/1%.%d\r\n')
  local headers = {}
  for name, value in head:gmatch('\r\n([^:\r\n]+):[ \t]*([^\r\n]*)') do
    headers[name:lower()] = value
  end
  return method, path, headers
end

--- routes: ['METHOD /path'] = response | function(request) → response
--- response = { status = 200, body = <string|table, a table is sent as JSON>, hang = true (never
---   answer), raw = <string sent as-is, then the connection closes> }
--- An unknown route answers 404 with {"error":"no route"}. Returns
--- { url, port, requests = { { method, path, headers (lower-case names), body } }, close }.
function M.start(routes)
  local uv = vim.uv
  local server = uv.new_tcp()
  assert(server:bind('127.0.0.1', 0))
  local port = server:getsockname().port
  local srv = { port = port, url = 'http://127.0.0.1:' .. port, requests = {} }
  local clients = {}

  local function respond(client, res)
    if res.hang then
      return
    end
    local out = res.raw
    if not out then
      local body = res.body or ''
      if type(body) == 'table' then
        body = vim.json.encode(body)
      end
      local status = res.status or 200
      out = ('HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s'):format(
        status,
        REASON[status] or 'Status',
        #body,
        body
      )
    end
    client:write(out, function()
      if not client:is_closing() then
        client:close()
      end
    end)
  end

  assert(server:listen(16, function(err)
    assert(not err, err)
    local client = uv.new_tcp()
    server:accept(client)
    clients[#clients + 1] = client
    local buf, continued = '', false
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then
        if not client:is_closing() then
          client:close()
        end
        return
      end
      buf = buf .. chunk
      local head_end = buf:find('\r\n\r\n', 1, true)
      if not head_end then
        return
      end
      local method, path, headers = parse(buf:sub(1, head_end + 1))
      if not continued and (headers.expect or ''):lower() == '100-continue' then
        continued = true
        client:write('HTTP/1.1 100 Continue\r\n\r\n')
      end
      local len = tonumber(headers['content-length'] or '0')
      if #buf < head_end + 3 + len then
        return
      end
      local req =
        { method = method, path = path, headers = headers, body = buf:sub(head_end + 4, head_end + 3 + len) }
      srv.requests[#srv.requests + 1] = req
      local route = routes[method .. ' ' .. path]
      local res
      if type(route) == 'function' then
        res = route(req)
      else
        res = route or { status = 404, body = { error = 'no route' } }
      end
      respond(client, res)
    end)
  end))

  function srv.close()
    for _, c in ipairs(clients) do
      if not c:is_closing() then
        c:close()
      end
    end
    if not server:is_closing() then
      server:close()
    end
  end

  return srv
end

return M
