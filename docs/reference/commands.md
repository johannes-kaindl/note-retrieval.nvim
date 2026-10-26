# Reference: commands

One user command, `:NoteRetrieval {subcommand}`, with completion. The manual (`:help :NoteRetrieval`) is the canonical text. Every command works on the vault of the current note. The commands that write (`reindex`, `update`, `stop`) act only on an own index; on an index of the Obsidian plugin they say it is read-only.

| Subcommand | Arguments | Reads / writes | Does |
|---|---|---|---|
| `model` | none | state file | Choose the embedding model per server; remembered in `stdpath('state')/note-retrieval/state.json`. |
| `probe` | `[n] [--json]`, in any order | reads only | Search with the own text of up to `n` notes (default 40) and count how many come back first. Works in mode `obsidian`. |
| `reindex` | none | writes the own index | Embed every note again, in the background. |
| `related` | none | reads only | Open or close the panel with the related notes. No server call. |
| `reset` | none | memory only | Forget the loaded index, the vault settings, the attach to saves, the waiting batch and the one-time hint. A running reindex is left alone. |
| `search` | `[query]` | reads only | Search by meaning. Without a query it asks for one. |
| `status` | none | reads only | Show the notes folder, mode, index, number of notes, model, age of the index, servers and the progress of a running reindex or update. |
| `stop` | none | own index | Ask a running **reindex** to stop after the notes in flight; what it reached is written. It does not act on an `update` (it then says `no reindex is running in <root>`). |
| `update` | none | writes the own index | Embed notes that are new, older in the index than on disk, or whose row holds an all-zero vector; drop deleted ones, write once, in the background. Writes a waiting save batch first. |

## `probe`

The rule for a note to be probed: the body (frontmatter removed, trimmed) has more than 200 and at most 800 UTF-16 code units (JavaScript string length; a character outside the Basic Multilingual Plane counts 2). The query is the first 300 units of the body. A note is found when it comes back at rank 0. Output: `probe: x/n on rank 0` and one line per miss with the path and the rank found (or "not found").

With `--json`, one JSON line with the keys:

| Key | Content |
|---|---|
| `n` | Notes probed. |
| `hits` | Notes found at rank 0. |
| `rate` | `hits / n`. |
| `failures` | List of `{ path, rank, top }`: the note, the rank it came back at (null when it was not found), and the path of the best hit (null when there was none). |
| `seed` | The seed of the sample. |
| `model` | The model of the index. |

After a full reindex of an own index the plugin runs the probe on 8 notes by itself and shows one line (option `probe_auto`, default true).

## Mappings

| Mapping | Modes | Same as |
|---|---|---|
| `<Plug>(note-retrieval-related)` | Normal | `:NoteRetrieval related` |
| `<Plug>(note-retrieval-search)` | Normal, Visual | `:NoteRetrieval search`; in Visual mode the selection is the query |

## Panel keys

`<CR>` opens the note, `l` writes a link, `q` closes.

## `:checkhealth note_retrieval`

Checks Neovim, curl, the notes folder, the index, the options and the servers; says what to do about each problem; changes nothing.
