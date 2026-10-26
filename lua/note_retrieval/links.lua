-- domain: note_retrieval
-- The links of a note, the way Obsidian reads and writes them: `[[Target|Alias#Section]]` and
-- `[Text](path.md)` found in a text (fenced code and inline code do not count), a target resolved
-- to a note of the vault by its shortest unambiguous path, and a link written for a note.
local M = {}

-- The text without fenced code blocks (a line of three or more backticks or tildes opens one, the
-- same fence closes it) and without inline code spans; both are replaced by blanks of the same
-- length so that the order of what is left does not change.
local function without_code(text)
  local out, fence = {}, nil
  for line in (text .. '\n'):gmatch('(.-)\n') do
    local mark = line:match('^ ? ? ?(```+)') or line:match('^ ? ? ?(~~~+)')
    if fence then
      if mark and mark:sub(1, 1) == fence:sub(1, 1) and #mark >= #fence then
        fence = nil
      end
      out[#out + 1] = ''
    elseif mark then
      fence = mark
      out[#out + 1] = ''
    else
      out[#out + 1] = (line:gsub('(`+)(.-)%1', ' '))
    end
  end
  return table.concat(out, '\n')
end

--- The link targets in `text`, in the order they stand: a list of `{ kind = 'wiki'|'markdown', target }`.
--- `[[Target|Alias#Section]]` gives `Target` (alias and section dropped; an embed `![[Target]]`
--- counts as a link; `[[#Section]]` points at the note itself and is left out). `[Text](path.md)`
--- gives the path with `%20` and the like decoded and `#section` dropped; web addresses and links
--- to a section of the same note are left out. A target is as written: resolve it with `resolve`.
---@param text string
---@return { kind: 'wiki'|'markdown', target: string }[]
function M.targets(text)
  local clean = without_code(text)
  local found = {}
  for pos, inner in clean:gmatch('()%[%[([^%[%]\n]-)%]%]') do
    -- `\|` is how a table cell writes the bar of an alias
    local target = vim.trim((vim.trim(inner:match('^[^|#^]*')):gsub('\\+$', '')))
    if target ~= '' then
      found[#found + 1] = { pos = pos, kind = 'wiki', target = target }
    end
  end
  for pos, inner in clean:gmatch('()%[[^%[%]\n]*%]%(([^()\n]*)%)') do
    local target = vim.trim(inner)
    local angled = target:match('^<(.*)>$')
    target = angled or target:match('^%S+') or ''
    target = vim.uri_decode(target:match('^[^#]*'))
    if target ~= '' and not target:find('^%a[%w+.-]*:') then
      found[#found + 1] = { pos = pos, kind = 'markdown', target = target }
    end
  end
  table.sort(found, function(a, b)
    return a.pos < b.pos
  end)
  for _, f in ipairs(found) do
    f.pos = nil
  end
  return found
end

-- What `resolve` looks up, built once per list of paths: `whole[key]` is the first note whose
-- path (lower case, without `.md`) is `key`; `ending[key]` lists the notes whose path ends with
-- `/key` (a whole path part), so no lookup scans the paths. Kept per list, weakly, so it goes with
-- the list; a list that changed its length is built again.
local lookups = setmetatable({}, { __mode = 'k' })
M._builds = 0 -- how often a lookup was built (the tests count it)

local function lookup_of(note_paths)
  local have = lookups[note_paths]
  if have and have.n == #note_paths then
    return have
  end
  M._builds = M._builds + 1
  have = { n = #note_paths, whole = {}, ending = {} }
  for _, p in ipairs(note_paths) do
    if p:sub(-3):lower() == '.md' then
      local key = p:sub(1, -4):lower()
      have.whole[key] = have.whole[key] or p
      local at = key:find('/', 1, true)
      while at do
        local tail = key:sub(at + 1)
        local list = have.ending[tail]
        if not list then
          list = {}
          have.ending[tail] = list
        end
        list[#list + 1] = p
        at = key:find('/', at + 1, true)
      end
    end
  end
  lookups[note_paths] = have
  return have
end

--- The note a target points at, the way Obsidian resolves a link: the target is a path from the
--- vault root or its ending (`Name`, `folder/Name`, with or without `.md`), compared without
--- regard to case, and a path that is the whole target wins over one that only ends with it.
--- Several notes ending with the target and none that is the whole of it: the link is ambiguous
--- and nothing is guessed. Returns the path from `note_paths`, or `nil, 'ambiguous'`, or
--- `nil, 'missing'`. The first call for a list of paths builds a lookup over it (kept as long as
--- the list lives; pass a new list when the paths change), every later call is a table access.
---@param target string
---@param note_paths string[]
---@return string|nil path
---@return string|nil reason
function M.resolve(target, note_paths)
  local want = target:gsub('^%./', ''):gsub('^/+', ''):gsub('%.[mM][dD]$', ''):lower()
  if want == '' then
    return nil, 'missing'
  end
  local lookup = lookup_of(note_paths)
  if lookup.whole[want] then
    return lookup.whole[want]
  end
  local ending = lookup.ending[want]
  if not ending then
    return nil, 'missing'
  elseif #ending == 1 then
    return ending[1]
  end
  return nil, 'ambiguous'
end

-- The path of a Markdown link the way Obsidian writes it: spaces as %20; what would end the link
-- or start a section (`%`, `#`, parentheses, angle brackets) encoded too.
local function encode(path)
  return (path:gsub('[%% #()<>]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

--- A link to the note at `path` (vault-relative, with `.md`): `kind` 'wiki' gives `[[title]]`
--- (`title` is what the link says: the name of the note, or its path where the name alone would
--- be ambiguous), 'markdown' gives `[title](path)` with the path encoded.
---@param kind 'wiki'|'markdown'
---@param path string
---@param title string
---@return string
function M.format(kind, path, title)
  if kind == 'wiki' then
    return '[[' .. title .. ']]'
  elseif kind == 'markdown' then
    return '[' .. title:gsub('([%[%]\\])', '\\%1') .. '](' .. encode(path) .. ')'
  end
  error(('note-retrieval links: unknown link kind %q (wiki or markdown)'):format(tostring(kind)), 2)
end

return M
