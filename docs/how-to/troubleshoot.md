# How-to: troubleshoot

Start with `:checkhealth note_retrieval`: it checks Neovim, curl, the notes folder, the index, the options and the servers, and changes nothing.

Every error is one message starting with `note-retrieval:`, ending in the next step.

## Messages

| Message (shortened) | What to do |
|---|---|
| no notes folder found: neither the current path nor a parent holds a .obsidian/ or .zk/ folder | Set `roots`, for example `vim.g.note_retrieval = { roots = { '~/notes' } }`. |
| No embedding server answered. | Start Ollama or LM Studio, or set `endpoints`. |
| The server did not answer in time. | Check that the model is loaded, or raise `timeout_ms`. |
| No model chosen, so nothing was searched. | Run `:NoteRetrieval model`. |
| The server has no model to embed with. | Pull an embedding model (for Ollama `ollama pull nomic-embed-text`), then `:NoteRetrieval model`. |
| The model "…" (option embedding_model) is not offered by the server | Pull the model into the server, or change `embedding_model`. |
| Search is off: this index was built with the model "…", and the server offers … | Load the same model name on the server, or use a server that has it. Related notes still work. |
| The server refused the request. | Check the endpoint and the model name. |
| The server answered with something that is no embedding. | Check that the endpoint speaks the OpenAI API (`/v1/embeddings`) and the model is an embedding model. |
| The API key of this endpoint could not be read (api_key_env or api_key_cmd). | Check the variable in the environment Neovim started from. |
| no row for this note in the index | The note is new, was left out, or the index is older than the note; `:NoteRetrieval update` in your own index. |
| The options are invalid | `:checkhealth note_retrieval` lists the problems. Invalid `endpoints` stop a run: text must not go to a server you did not set. |

## Messages of the writer (own index)

| Message (shortened) | What to do |
|---|---|
| the index of this vault belongs to the Obsidian plugin … this plugin only reads it | Nothing: Obsidian rebuilds and updates it. |
| another Neovim holds the lock on this index (taken … ago) | Try again in a moment. A lock older than 1800 s is taken over. |
| the index on disk was built with another model than "…" | `:NoteRetrieval reindex` rebuilds with this model, or go back to the old model. |
| the index on disk has another vector size than this setup | `:NoteRetrieval reindex`. |
| this write would leave far fewer notes than the index on disk holds | The guard `shrink` fired. `:NoteRetrieval reset` reads the index again; `:NoteRetrieval reindex` rebuilds it. |
| the index at … could not be loaded … so nothing is written over it | Fix or remove the file, or `:NoteRetrieval reindex`. |
| the index on disk cannot be read right now (another Neovim writing it?) | Try again in a moment. |
| the options name another index folder than this session writes to | `:NoteRetrieval reset`, then try again. |
| no reindex is running in … (after `stop`) | Either none runs, or an `update` runs: `stop` does not act on `update`, see [limits](../explanation/limits.md). |
| N could not be embedded and are missing from the index | `:NoteRetrieval reindex` tries again. |

## Where things are

See [the index reference](../reference/index-format.md) for the index, lock and backup paths. The backup `index.bin.bak` is a copy from before the first write of a session or a reindex; to go back, copy it over `index.bin` with Neovim closed.

## Search finds the wrong notes

Run `:NoteRetrieval probe`. It searches with the own text of up to 40 notes and reports how many come back first. A low count with a model you just changed means the index is from another model: `:NoteRetrieval reindex`.
