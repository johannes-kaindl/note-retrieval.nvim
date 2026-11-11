-- vendored from nvim-kit@0.17.1 (lua/nvim_kit/endpoint_model.lua) — do not edit; re-vendor
-- The model a person chose per server, remembered across sessions in a JSON state file:
-- { "models": { "<endpoint url>": "<model id>" } }, through nvim_kit.store (atomic write, re-read
-- before every write, a broken file set aside). The file's path belongs to the plugin.
-- Relative require: a vendored copy loads its sibling under lua/<plugin>/kit/.
local store = require(((...):gsub('endpoint_model$', 'store')))

local M = {}

--- A remembered-model store over one state file. `path` is a string or a function returning one
--- (called on every use, so `stdpath('state')` is read late). `opts.prompt_prefix` starts the
--- picker's prompt ("<prefix>: model on <url>"). The functions need no `self`: call them with a dot.
---   model(url)                     the remembered id for an endpoint URL, or nil
---   set_model(url, id)             remember id; raises when the file cannot be written
---   choose(endpoint, models, cb, opts)  vim.ui.select over models (endpoint is a table with .url);
---                                  cb(id) after a pick, cb(nil) when dismissed, nothing stored then;
---                                  when the pick cannot be remembered (state file not writable)
---                                  cb still fires once, as cb(id, err) with err the message of
---                                  the write error: the choice counts, only its memory is lost;
---                                  opts.prompt_prefix overrides the one from `new`
---   path()                         the state file's path
function M.new(path, opts)
  if type(path) ~= 'string' and type(path) ~= 'function' then
    error('nvim-kit endpoint_model: new(path) takes a string or a function', 2)
  end
  local default_prefix = opts and opts.prompt_prefix
  local self = {}

  function self.path()
    return type(path) == 'function' and path() or path
  end

  function self.model(url)
    local ok, value = pcall(store.read, self.path(), { expect = 'object' })
    if not ok or type(value) ~= 'table' or type(value.models) ~= 'table' then
      return nil
    end
    local id = value.models[url]
    return type(id) == 'string' and id or nil
  end

  function self.set_model(url, id)
    store.update(self.path(), function(value)
      value = type(value) == 'table' and value or vim.empty_dict()
      if type(value.models) ~= 'table' or vim.islist(value.models) and next(value.models) ~= nil then
        value.models = vim.empty_dict()
      end
      value.models[url] = id
      return value
    end, { expect = 'object' })
  end

  function self.choose(endpoint, models, cb, choose_opts)
    local prefix = choose_opts and choose_opts.prompt_prefix or default_prefix
    local prompt = (prefix and prefix .. ': ' or '') .. 'model on ' .. endpoint.url
    vim.ui.select(models, { prompt = prompt }, function(id)
      local err
      if id then
        local ok, raised = pcall(self.set_model, endpoint.url, id)
        if not ok then
          err = tostring(raised)
        end
      end
      cb(id, err)
    end)
  end

  return self
end

return M
