# note-retrieval.nvim

**Related notes and semantic search over a Markdown vault, in Neovim: a panel beside the note you are writing, and a search by meaning.**

[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

`:NoteRetrieval related` opens the panel beside the note you are in. Example for `Baking/hydration.md` of the fixture vault in `tests/fixtures/vault/` (the notes are real, the scores are illustrative, not measured):

```text
Related to Baking/hydration.md: 2 notes
0.82  crumb-notes — Baking
0.74  baking-day — Baking
```

`:NoteRetrieval search <words>` lists notes by meaning, not by the word, in the same form: the score, the title, the folder.

**Status:** 0.1.0 is in preparation, nothing is released yet. The plugin reads and, in its own mode, writes a note index; it never changes a note.

## Requirements

- Neovim ≥ 0.10
- curl on `PATH`
- An OpenAI-compatible embedding server for your own index and for `search`: [Ollama](https://ollama.com) or [LM Studio](https://lmstudio.ai) on this machine work without configuration; any other endpoint is set with the option `endpoints`. Setting up a local server: [jkaindl.de/uplink/llm-setup](https://jkaindl.de/uplink/llm-setup/). The related panel needs no server: it reads the vectors from the index.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'johannes-kaindl/note-retrieval.nvim',
  cmd = 'NoteRetrieval',
  keys = {
    { '<Leader>nr', '<Plug>(note-retrieval-related)', desc = 'related notes' },
    { '<Leader>ns', '<Plug>(note-retrieval-search)', mode = { 'n', 'x' }, desc = 'search notes' },
  },
}
```

Nothing needs `setup()`. If the vault is not found by itself (a folder with `.obsidian/` or `.zk/` above the note), set `vim.g.note_retrieval = { roots = { '~/notes' } }`. Then run `:checkhealth note_retrieval`.

## Quick start

1. Open a note of the vault and run `:NoteRetrieval model` to choose the embedding model of your server.
2. Run `:NoteRetrieval reindex`. It runs in the background; `:NoteRetrieval status` shows the progress, `:NoteRetrieval stop` ends it.
3. Run `:NoteRetrieval related` for the panel, or `:NoteRetrieval search <words>` to search by meaning.

A tutorial with every step is in [docs/tutorials/first-index.md](docs/tutorials/first-index.md).

## Commands

| Command | What it does |
|---|---|
| `:NoteRetrieval related` | Open or close the panel with the notes related to the current note; it follows you from note to note. Keys: `<CR>` opens a note, `l` writes a link to it, `q` closes. |
| `:NoteRetrieval search [query]` | Search by meaning; the closest notes are listed, the one you pick opens. |
| `:NoteRetrieval status` | The notes folder, the mode, the index, the model, the age of the index and the servers. |
| `:NoteRetrieval model` | Choose the embedding model per server; the choice is remembered. |
| `:NoteRetrieval reindex` | Build the own index again from all notes, in the background. |
| `:NoteRetrieval update` | Embed new and changed notes, drop deleted ones, write once. |
| `:NoteRetrieval stop` | Ask a running reindex to stop; what it reached is written. |
| `:NoteRetrieval probe [n] [--json]` | Check that the index finds the notes it holds. |
| `:NoteRetrieval reset` | Forget the index, the vault settings and the save state held in memory. |

Mappings (the plugin sets no key of its own): `<Plug>(note-retrieval-related)` and `<Plug>(note-retrieval-search)` (Normal and Visual mode; in Visual mode the selection is the query).

Options, set in `vim.g.note_retrieval` or `setup()`: `roots`, `endpoints`, `embedding_model`, `k`, `min_similarity`, `hide_linked`, `link_format`, `exclude`, `index_dir`, `index_on_save`, `probe_auto`, `timeout_ms`. Defaults and meaning: `:help note-retrieval-options`, or [docs/reference/options.md](docs/reference/options.md).

## Two modes

The plugin reads one of two indexes of a vault, and writes only one.

- **Own index** (shown as `eigen` by `:NoteRetrieval status`): the plugin builds and updates `index.bin` itself. This is the mode for a vault without Obsidian.
- **Works with Vault Retrieval for Obsidian:** if the vault has the Obsidian plugin Vault Retrieval installed with an index, the plugin reads that index and never writes it (mode `obsidian`). You get related notes and search in Neovim over the index Obsidian maintains; `reindex` and `update` only say that the index is read-only, and update-on-save is never installed. This is an addition, not a requirement.

Why an index has exactly one writer: [docs/explanation/why-one-writer.md](docs/explanation/why-one-writer.md).

## Known limits

Short list; every point, its cause and its way out is in [docs/explanation/limits.md](docs/explanation/limits.md).

- `:NoteRetrieval stop` does not act on a running `update`; it reports that no reindex is running.
- The first step of an `update` stalls Neovim for a moment (about 90 ms on 13,000 notes).
- The mark "changed since the index" is exact only for rows with a real file stamp; see [docs/explanation/stale-mark.md](docs/explanation/stale-mark.md).
- Quitting within a second of a save loses that save's index batch; the next `update` embeds it.

## Documentation

- `:help note-retrieval` — commands, mappings, Lua API, options
- [docs/](docs/README.md) — tutorial, how-tos, reference, background

## License

Code: [AGPL-3.0](LICENSE), with a commercial license available ([LICENSING.md](LICENSING.md)). Documentation: [CC BY-SA 4.0](LICENSE-DOCS).
