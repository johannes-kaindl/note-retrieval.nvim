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
    'md:folder/My Note.md',
    'md:b.md',
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

T.case('format: wiki gives [[title]], md gives [title](encoded path)', function()
  T.eq(links.format('wiki', 'Notes/Daily.md', 'Daily'), '[[Daily]]')
  T.eq(links.format('md', 'Notes/Daily.md', 'Daily'), '[Daily](Notes/Daily.md)')
  T.eq(links.format('md', 'My Notes/A (b)#1.md', 'A [b]'), '[A \\[b\\]](My%20Notes/A%20%28b%29%231.md)')
  T.raises(function()
    links.format('html', 'a.md', 'a')
  end, 'unknown link kind')
end)

T.case('format and targets agree: what md format writes, targets reads back, resolve finds', function()
  local path = 'My Notes/Plan (v2).md'
  local text = links.format('md', path, 'Plan')
  local got = links.targets(text)
  T.eq(got[1].target, 'My Notes/Plan (v2).md')
  T.eq(links.resolve(got[1].target, { path, 'x.md' }), path)
end)
