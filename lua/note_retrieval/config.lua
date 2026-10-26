-- domain: note_retrieval
-- The options (:help note-retrieval-options): vim.g.note_retrieval, with setup(opts) merged over it.
-- Read at the start of every run, so a change applies to the next one. resolve() checks every field
-- and returns all problems at once — setup() reports them, :checkhealth lists them.
local llm = require('note_retrieval.kit.llm')

local M = {}

---@class note_retrieval.Config
---@field roots? string[] directories holding the notes (nil: the index decides, else the working directory)
---@field index_dir? string folder inside a root that holds index.bin (nil: the own index lives under stdpath('data'))
---@field exclude? string[] path prefixes left out of the notes of the own index (nil: none)
---@field endpoints? table[] embedding servers in priority order (nil: Ollama, then LM Studio)
---@field embedding_model? string model that embeds notes and queries (nil: chosen per server)
---@field k integer how many related notes to show
---@field min_similarity number cosine similarity below which a note is not related
---@field hide_linked boolean leave out notes the current note already links to
---@field link_format 'wiki'|'markdown' how an inserted link is written
---@field index_on_save boolean update the own index when a note is saved
---@field timeout_ms integer how long one embedding request may take
M.DEFAULTS = {
  roots = nil,
  index_dir = nil,
  exclude = nil,
  endpoints = nil,
  embedding_model = nil,
  k = 20,
  min_similarity = 0.3,
  hide_linked = true,
  link_format = 'wiki',
  index_on_save = true,
  timeout_ms = 30000,
}

-- The largest count a request or a limit takes (a C int); anything above is a typo, not a choice.
local MAX_WHOLE = 2147483647
local WHOLE = ('must be a whole number from 1 to %d'):format(MAX_WHOLE)

local function whole(v)
  if type(v) ~= 'number' or v ~= math.floor(v) or v < 1 or v > MAX_WHOLE then
    return WHOLE
  end
end

local function boolean(v)
  if type(v) ~= 'boolean' then
    return 'must be true or false'
  end
end

-- Every option and its check; a check returns nil or the problem.
local CHECKS = {
  roots = function(v)
    if type(v) ~= 'table' or #v == 0 then
      return 'must be a non-empty list of directory paths'
    end
    for i, root in ipairs(v) do
      if type(root) ~= 'string' or vim.trim(root) == '' then
        return ('entry %d must be a directory path'):format(i)
      end
    end
  end,
  index_dir = function(v)
    local why = 'must be a folder inside the root, such as "_index"'
    if type(v) ~= 'string' or v:gsub('/+$', '') == '' or v:find('^[/\\]') or v:find('^%a:') then
      return why
    end
    for part in v:gmatch('[^/\\]+') do
      if part == '..' then
        return why
      end
    end
  end,
  exclude = function(v)
    local why = 'must be a list of non-empty path prefixes such as { "Templates/" }'
    if type(v) ~= 'table' or (next(v) ~= nil and not vim.islist(v)) then
      return why
    end
    for _, prefix in ipairs(v) do
      if type(prefix) ~= 'string' or prefix == '' then
        return why
      end
    end
  end,
  endpoints = function(v)
    -- The kit reads `opts.endpoints or DEFAULT`, so `false` would fall back silently.
    if type(v) ~= 'table' then
      return 'must be a non-empty list of endpoint tables'
    end
    local ok, err = pcall(llm.endpoints, { endpoints = v })
    if not ok then
      -- The problem line already starts with "endpoints: ", so the kit's own prefix goes.
      local why = tostring(err):gsub('^.-nvim%-kit llm: ', '')
      why = why:gsub('^endpoints%[(%d+)%]: ', 'entry %1: '):gsub('^endpoints ', '')
      return why
    end
  end,
  embedding_model = function(v)
    if type(v) ~= 'string' or vim.trim(v) == '' then
      return 'must be a model name such as "nomic-embed-text"'
    end
  end,
  k = whole,
  min_similarity = function(v)
    if type(v) ~= 'number' or v ~= v or v < -1 or v > 1 then
      return 'must be a number from -1 to 1'
    end
  end,
  hide_linked = boolean,
  link_format = function(v)
    if v ~= 'wiki' and v ~= 'markdown' then
      return 'must be "wiki" or "markdown"'
    end
  end,
  index_on_save = boolean,
  timeout_ms = whole,
}

--- Every option name, sorted (DEFAULTS cannot list the ones whose default is nil).
M.NAMES = vim.tbl_keys(CHECKS)
table.sort(M.NAMES)

local from_setup = {}
local NOT_A_TABLE = 'note_retrieval: must be a table'
local setup_not_a_table = false

--- Remember opts as given to setup(); they win over vim.g.note_retrieval. Anything but a table
--- is reported by resolve() instead of raising.
function M.set(opts)
  setup_not_a_table = opts ~= nil and type(opts) ~= 'table'
  from_setup = type(opts) == 'table' and opts or {}
end

--- The options in effect and the problems found: { cfg, problems = { 'option: why', … } }.
--- A field with a problem keeps its default — except `endpoints`: text must not go to a server
--- nobody configured, so cfg.endpoints_error is set and the run stops.
function M.resolve()
  local given = vim.tbl_extend(
    'force',
    {},
    type(vim.g.note_retrieval) == 'table' and vim.g.note_retrieval or {},
    from_setup
  )
  local cfg = vim.deepcopy(M.DEFAULTS)
  local problems = {}
  if setup_not_a_table or (vim.g.note_retrieval ~= nil and type(vim.g.note_retrieval) ~= 'table') then
    problems[1] = NOT_A_TABLE
  end
  local names = vim.tbl_keys(given)
  table.sort(names, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, name in ipairs(names) do
    local value = given[name]
    local check = CHECKS[name]
    if not check then
      problems[#problems + 1] = ('%s: unknown option — ignored'):format(tostring(name))
    else
      local why = value ~= nil and check(value) or nil
      if why then
        problems[#problems + 1] = ('%s: %s'):format(name, why)
        if name == 'endpoints' then
          cfg.endpoints_error = why
        end
      else
        cfg[name] = value
      end
    end
  end
  return cfg, problems
end

return M
