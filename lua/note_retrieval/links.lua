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

local function decode(s)
  return (s:gsub('%%(%x%x)', function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function trim(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

--- The link targets in `text`, in the order they stand: a list of `{ kind = 'wiki'|'md', target }`.
--- `[[Target|Alias#Section]]` gives `Target` (alias and section dropped; an embed `![[Target]]`
--- counts as a link; `[[#Section]]` points at the note itself and is left out). `[Text](path.md)`
--- gives the path with `%20` and the like decoded and `#section` dropped; web addresses and links
--- to a section of the same note are left out. A target is as written: resolve it with `resolve`.
---@param text string
---@return { kind: 'wiki'|'md', target: string }[]
function M.targets(text)
  local clean = without_code(text)
  local found = {}
  for pos, inner in clean:gmatch('()%[%[([^%[%]\n]-)%]%]') do
    local target = trim(inner:match('^[^|#^]*'))
    if target ~= '' then
      found[#found + 1] = { pos = pos, kind = 'wiki', target = target }
    end
  end
  for pos, inner in clean:gmatch('()%[[^%[%]\n]*%]%(([^()\n]*)%)') do
    local target = trim(inner)
    local angled = target:match('^<(.*)>$')
    target = angled or target:match('^%S+') or ''
    target = decode(target:match('^[^#]*'))
    if target ~= '' and not target:find('^%a[%w+.-]*:') then
      found[#found + 1] = { pos = pos, kind = 'md', target = target }
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

--- The note a target points at, the way Obsidian resolves a link: the target is a path from the
--- vault root or its ending (`Name`, `folder/Name`, with or without `.md`), compared without
--- regard to case, and a path that is the whole target wins over one that only ends with it.
--- Several notes ending with the target and none that is the whole of it: the link is ambiguous
--- and nothing is guessed. Returns the path from `note_paths`, or `nil, 'ambiguous'`, or
--- `nil, 'missing'`.
---@param target string
---@param note_paths string[]
---@return string|nil path
---@return string|nil reason
function M.resolve(target, note_paths)
  local want = target:gsub('^%./', ''):gsub('^/+', ''):gsub('%.[mM][dD]$', ''):lower()
  if want == '' then
    return nil, 'missing'
  end
  local tail = want .. '.md'
  local n = #tail
  local whole, ending, count = nil, nil, 0
  for _, p in ipairs(note_paths) do
    if #p >= n and p:sub(-n):lower() == tail then
      if #p == n then
        whole = whole or p
      elseif p:sub(-n - 1, -n - 1) == '/' then
        count = count + 1
        ending = ending or p
      end
    end
  end
  if whole then
    return whole
  end
  if count == 1 then
    return ending
  end
  return nil, count == 0 and 'missing' or 'ambiguous'
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
--- be ambiguous), 'md' gives `[title](path)` with the path encoded.
---@param kind 'wiki'|'md'
---@param path string
---@param title string
---@return string
function M.format(kind, path, title)
  if kind == 'wiki' then
    return '[[' .. title .. ']]'
  elseif kind == 'md' then
    return '[' .. title:gsub('([%[%]\\])', '\\%1') .. '](' .. encode(path) .. ')'
  end
  error(('note-retrieval links: unknown link kind %q (wiki or md)'):format(tostring(kind)), 2)
end

return M
