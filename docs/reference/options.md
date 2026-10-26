# Reference: options

Set them in `vim.g.note_retrieval` or pass them to `require('note_retrieval').setup()`; `setup()` wins field by field. Nothing needs `setup()`. All problems are found at once; a field that fails its check is reported by `:checkhealth note_retrieval` and keeps its default. The exception is `endpoints`: invalid endpoints stop a run, so text never goes to a server you did not set. The manual (`:help note-retrieval-options`) is the canonical text.

| Option | Type | Default | Meaning |
|---|---|---|---|
| `embedding_model` | string | `nil` (chosen per server) | The model that embeds notes and queries. |
| `endpoints` | list of tables | `nil` (Ollama on `:11434`, then LM Studio on `:1234`) | Embedding servers in priority order. |
| `exclude` | list of strings | `nil` | Path prefixes (relative to the root, case-sensitive) left out of the notes of the own index, for example `{ 'Templates/' }`. An Obsidian index brings its own list (the plugin's defaults exclude `Templates/` and `Archive/`). |
| `hide_linked` | boolean | `true` | Leave out notes the current note already links to. |
| `index_dir` | string | `nil` (under `stdpath('data')`) | Folder inside the root that holds the own `index.bin`. An index of the Vault Retrieval plugin found there is only read. |
| `index_on_save` | boolean | `true` | Update the own index when a note is saved (debounced 1000 ms). |
| `k` | integer | `20` | How many related notes to show. |
| `link_format` | `"wiki"` or `"markdown"` | `"wiki"` | How an inserted link is written. |
| `min_similarity` | number, -1 to 1 | `0.3` | Cosine similarity below which a note is not related. |
| `probe_auto` | boolean | `true` | After a full reindex of the own index, probe 8 notes and show one line. |
| `roots` | list of strings | `nil` | Directories holding the notes. Without it, the nearest parent of the note with `.obsidian/` or `.zk/` is the root; with several matches, the longest wins. |
| `timeout_ms` | integer | `30000` | How long one embedding request may take. |

## Which notes belong to a vault

Every `*.md` file below the root, except a path with a part that starts with a dot, a path under an `exclude` prefix, and the index folder.
