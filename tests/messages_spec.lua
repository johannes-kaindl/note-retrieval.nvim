local T = require('note_retrieval.kit.test')
local messages = require('note_retrieval.messages')
local roots = require('note_retrieval.roots')
local search = require('note_retrieval.search')

local function has(text, ...)
  for _, part in ipairs({ ... }) do
    T.ok(text:find(part, 1, true), ('%q is not in %q'):format(part, text))
  end
end

T.case('text: a model mismatch names both models and says search is off but related works', function()
  local text =
    messages.text({ kind = 'model-mismatch', index_model = 'nomic', endpoint_models = { 'qwen', 'bge' } })
  has(text, 'note-retrieval: ', 'Search is off', '"nomic"', '"qwen", "bge"', 'Related notes still work')
end)

T.case('text: a long model list is cut, an empty one says none', function()
  local many = { 'm1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7' }
  has(
    messages.text({ kind = 'model-mismatch', index_model = 'x', endpoint_models = many }),
    '"m5" and 2 more'
  )
  has(messages.text({ kind = 'model-mismatch', index_model = 'x', endpoint_models = {} }), 'offers none')
end)

T.case('text: a model the option asks for and the server lacks', function()
  local text = messages.text({ kind = 'model-missing', model = 'big', endpoint_models = { 'small' } })
  has(text, '"big"', 'embedding_model', '"small"', 'Pull it')
end)

T.case('text: every other kind has its own sentence with the next step', function()
  local cases = {
    { { kind = 'no-model-chosen' }, ':NoteRetrieval model' },
    { { kind = 'no-model' }, 'ollama pull' },
    { { kind = 'bad-config', detail = 'endpoints: x' }, ':checkhealth note_retrieval', '(endpoints: x)' },
    {
      { kind = 'unreachable', detail = 'no endpoint answered: http://h' },
      'Start Ollama',
      '(no endpoint answered: http://h)',
    },
    { { kind = 'timeout', detail = 'slow' }, 'timeout_ms' },
    { { kind = 'key-missing', detail = 'FOO is not set' }, 'api_key_env', '(FOO is not set)' },
    { { kind = 'http', detail = '401' }, 'refused' },
    { { kind = 'bad-response', detail = 'no vector' }, 'embedding model' },
    { { kind = 'cancelled', detail = 'cancelled' }, 'Cancelled.' },
    {
      { kind = 'no-index', detail = 'no index file at /x/index.bin' },
      'no index file at /x/index.bin',
      ':checkhealth note_retrieval',
    },
  }
  for _, c in ipairs(cases) do
    local text = messages.text(c[1])
    has(text, 'note-retrieval: ', unpack(c, 2))
    T.ok(not text:find('Unexpected', 1, true), text)
  end
end)

T.case('text: no vault gives the roots sentence as it is, as a string and as a table', function()
  T.eq(messages.text(roots.NO_ROOT), 'note-retrieval: ' .. roots.NO_ROOT)
  T.eq(messages.text({ kind = 'no-index', detail = roots.NO_ROOT }), 'note-retrieval: ' .. roots.NO_ROOT)
  T.eq(messages.text({ kind = 'no-root' }), 'note-retrieval: ' .. roots.NO_ROOT)
end)

T.case('text: the strings of related and the index get a sentence', function()
  has(messages.text(search.NO_ROW), 'no row for this note in the index', 'older than the note')
  has(
    messages.text('the index is being written or is damaged (the file is cut short)'),
    'being written',
    ':checkhealth note_retrieval'
  )
end)

T.case('text: an unknown kind and a value that is no error are shown, not hidden', function()
  has(messages.text({ kind = 'strange', detail = 'why' }), 'Unexpected error: strange.', '(why)')
  has(messages.text(42), 'Unexpected error: 42.')
  has(messages.text({}), 'Unexpected error: nil.')
end)

T.case('notify: error level, except cancelled', function()
  local seen = {}
  local saved = vim.notify
  vim.notify = function(msg, level)
    seen[#seen + 1] = { msg, level }
  end
  messages.notify({ kind = 'no-model-chosen' })
  messages.notify({ kind = 'cancelled' })
  vim.notify = saved
  T.eq({ seen[1][2], seen[2][2] }, { vim.log.levels.ERROR, vim.log.levels.INFO })
end)

T.case('text: the hints for a missing index and a missing row name reindex in mode eigen only', function()
  local missing = 'no index file at /x/index.bin'
  for _, mode in ipairs({ 'obsidian', false }) do
    local opts = mode and { mode = mode } or nil
    local text = messages.text(missing, opts)
    has(text, ':checkhealth note_retrieval')
    T.ok(not text:find(':NoteRetrieval reindex', 1, true), text)
    T.ok(
      not messages.text(search.NO_ROW, opts):find(':NoteRetrieval reindex', 1, true),
      'row, ' .. tostring(mode)
    )
    T.ok(not messages.text({ kind = 'no-index', detail = missing }, opts):find('reindex', 1, true), 'table')
  end
  has(
    messages.text(missing, { mode = 'eigen' }),
    ':NoteRetrieval reindex',
    ':checkhealth note_retrieval',
    missing
  )
  has(messages.text(search.NO_ROW, { mode = 'eigen' }), 'older than the note', ':NoteRetrieval reindex')
  has(messages.text({ kind = 'no-index', detail = missing }, { mode = 'eigen' }), ':NoteRetrieval reindex')
  -- the sentence of a vault without a root does not change with the mode
  T.eq(messages.text(roots.NO_ROOT, { mode = 'eigen' }), 'note-retrieval: ' .. roots.NO_ROOT)
end)
