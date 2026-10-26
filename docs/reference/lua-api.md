# Reference: Lua API

All functions are in `require('note_retrieval')`. The manual (`:help note-retrieval-api`) is the canonical text.

## `search(query, opts, cb)`

The notes closest in meaning to `query`. Calls `cb(results)` with a list of `{ path, score, title }`, best first, or `cb(nil, err)`. `err` is a table `{ kind, … }`; `require('note_retrieval.messages').text(err)` makes a sentence of it. `opts` is `{ k, min_similarity, exclude, root }`; `root` defaults to the vault of the current note. The query is embedded once, with no instruction in front.

## `related(path, opts)`

The same list for the note at `path`, from its row in the index: no server call. A path that is not absolute is relative to the vault of the current note. Returns the list, or `nil, message`.

## `status()`

What the plugin knows about the vault of the current note: a table with `root`, `root_mode`, `loaded`, `mode`, `rows`, `model`, `age`, `endpoints`, `reindex`, `warning`, `problem` and `line`. `line` is one short line for a status line. The call is cheap: an index that is not in memory yet is not read (`loaded = false`, and `mode`, `rows`, `model` and `age` are `nil`). `reindex` is the state of the own index writer: `running`, `done`, `total`, `lock`, `last_error`, `report`.

## `setup(opts)` and `resolve()`

`setup(opts)` sets options (see [options](options.md)); it is never required. `resolve()` returns the options in effect and the problems found.
