local T = require('note_retrieval.kit.test')
local links = require('note_retrieval.links')

local function targets(text)
  local out = {}
  for i, t in ipairs(links.targets(text)) do
    out[i] = t.kind .. ':' .. t.target
  end
  return out
end

T.case('targets: wikilinks without alias and section, md links decoded, in text order', function()
  local text = table.concat({
    'See [[Alpha]] and [[Beta|the beta]] and [[Gamma#Part]] and [[Delta#^blk|d]].',
    'Also [text](folder/My%20Note.md) and [x](b.md#sec) and ![[Emb]].',
  }, '\n')
  T.eq(targets(text), {
    'wiki:Alpha',
    'wiki:Beta',
    'wiki:Gamma',
    'wiki:Delta',
    'markdown:folder/My Note.md',
    'markdown:b.md',
    'wiki:Emb',
  })
end)

T.case('targets: web addresses, same-note sections and empty targets are not notes', function()
  T.eq(targets('[a](https://x.org/y.md) [b](mailto:a@b.c) [c](#sec) [[#Sec]] [[ ]] [d]()'), {})
end)

T.case('targets: fenced code and inline code do not count, the text after them does', function()
  local text = table.concat({
    '[[One]] `[[Inline]]` and ``[[Double`tick]]`` [[Two]]',
    '```lua',
    '[[InFence]]',
    '```',
    '~~~',
    '[[InTilde]]',
    '~~~',
    '[[Three]]',
    '    ```',
    '[[Four]]',
  }, '\n')
  -- a line indented by four spaces is code, not a fence: it opens no block, so Four is a link
  T.eq(targets(text), { 'wiki:One', 'wiki:Two', 'wiki:Three', 'wiki:Four' })
  -- an unclosed fence swallows the rest, a longer fence is not closed by a shorter one
  T.eq(targets('```\n[[a]]\n[[b]]'), {})
  T.eq(targets('````\n[[a]]\n```\n[[b]]\n````\n[[c]]'), { 'wiki:c' })
end)

local PATHS = { 'a.md', 'Notes/Daily.md', 'Notes/Plan.md', 'Archive/Plan.md', 'sub/deep/Idea.md', 'Idea.md' }

T.case('resolve: shortest unambiguous path, with or without .md, any case', function()
  T.eq(links.resolve('a', PATHS), 'a.md')
  T.eq(links.resolve('A.md', PATHS), 'a.md')
  T.eq(links.resolve('daily', PATHS), 'Notes/Daily.md')
  T.eq(links.resolve('Notes/Daily', PATHS), 'Notes/Daily.md')
  T.eq(links.resolve('./a', PATHS), 'a.md')
  T.eq(links.resolve('deep/Idea', PATHS), 'sub/deep/Idea.md')
end)

T.case('resolve: an ambiguous short name is no match, a longer path or the whole path is', function()
  local path, why = links.resolve('Plan', PATHS)
  T.eq(path, nil)
  T.eq(why, 'ambiguous')
  T.eq(links.resolve('Archive/Plan', PATHS), 'Archive/Plan.md')
  -- the whole path wins over a longer one that merely ends with it
  T.eq(links.resolve('Idea', PATHS), 'Idea.md')
  local none, missing = links.resolve('Nope', PATHS)
  T.eq(none, nil)
  T.eq(missing, 'missing')
  -- an ending is a whole path part: "lan" is not "Plan"
  T.eq(select(2, links.resolve('lan', PATHS)), 'missing')
end)

T.case('format: wiki gives [[title]], markdown gives [title](encoded path)', function()
  T.eq(links.format('wiki', 'Notes/Daily.md', 'Daily'), '[[Daily]]')
  T.eq(links.format('markdown', 'Notes/Daily.md', 'Daily'), '[Daily](Notes/Daily.md)')
  T.eq(links.format('markdown', 'My Notes/A (b)#1.md', 'A [b]'), '[A \\[b\\]](My%20Notes/A%20%28b%29%231.md)')
  T.raises(function()
    links.format('html', 'a.md', 'a')
  end, 'unknown link kind')
end)

T.case('format and targets agree: what markdown format writes, targets reads back, resolve finds', function()
  local path = 'My Notes/Plan (v2).md'
  local text = links.format('markdown', path, 'Plan')
  local got = links.targets(text)
  T.eq(got[1].target, 'My Notes/Plan (v2).md')
  T.eq(links.resolve(got[1].target, { path, 'x.md' }), path)
end)

T.case(
  'targets: the backslash that escapes the bar of an alias in a table cell is not part of the target',
  function()
    T.eq(targets('| [[Target\\|Alias]] | [[Other\\|x]] |'), { 'wiki:Target', 'wiki:Other' })
    T.eq(targets('[[Target\\#Sec]]'), { 'wiki:Target' })
  end
)

-- What resolve did before it had a lookup: scan every path, one comparison each.
local function scanning(target, note_paths)
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

T.case('resolve: the lookup answers exactly what a scan of the paths answers', function()
  local paths = vim.list_extend({ 'readme.TXT', 'x/Y.MD', 'Plan.md', 'a/plan.md', 'a/b/Plan.md' }, PATHS)
  local targets_ = {
    'Plan',
    'plan.md',
    'a/Plan',
    'b/plan',
    'a/b/plan.MD',
    'x/y',
    'Y',
    'readme',
    'readme.txt',
    'Idea',
    'sub/deep/idea',
    '/a',
    './a',
    '',
    'Nope',
    'lan',
    'Notes/Plan',
    'Archive/Plan',
  }
  for _, t in ipairs(targets_) do
    local got, why = links.resolve(t, paths)
    local want, wwhy = scanning(t, paths)
    T.eq({ got, why }, { want, wwhy }, 'target ' .. t)
  end
end)

T.case(
  'resolve: 300 targets over 13,000 paths build one lookup; a new or changed list builds a new one',
  function()
    local paths = {}
    for i = 1, 13000 do
      paths[i] = ('folder%d/sub%d/Note %d.md'):format(i % 40, i % 7, i)
    end
    local before = links._builds
    for i = 1, 300 do
      T.eq(links.resolve(('Note %d'):format(i * 40), paths), paths[i * 40])
    end
    T.eq(links._builds - before, 1)
    -- the same list again: still the lookup of before
    links.resolve('Note 1', paths)
    T.eq(links._builds - before, 1)
    -- a list that is not the same table (the index reloaded) is looked up anew
    local reloaded = vim.deepcopy(paths)
    reloaded[#reloaded + 1] = 'late/Late.md'
    T.eq(links.resolve('Late', reloaded), 'late/Late.md')
    T.eq(links._builds - before, 2)
    -- and so is one that grew, with the same table
    paths[#paths + 1] = 'late/Later.md'
    T.eq(links.resolve('Later', paths), 'late/Later.md')
    T.eq(links._builds - before, 3)
  end
)
