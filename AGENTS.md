# AGENTS.md — note-retrieval.nvim

> **Role:** context for AI agents working in this repo. Humans start in [`README.md`](README.md). The coordination rules of the Neovim plugins — above all "Bibliothek ab Eins" and its justification gate — live one level up, in `../AGENTS.md` (the `nvim-plugins` Dach).
>
> **Language:** code, comments, identifiers and docs are **English**; commit messages **German**, Conventional Commits. Tags SemVer without `v`.

## Project character

**note-retrieval.nvim** shows related notes and does semantic search over a Markdown vault. It reads the Obsidian index of vault-rag read-only, or keeps its own in the same format (VRIX). Published for any Neovim user; no tie to Obsidian or to one person's setup. Under construction (plan 0.1.0): Block A is done — scaffold and options, roots and modes, the index reader, the embedder, `related` and `search`, the panel, the commands, `<Plug>` mappings and `:checkhealth`. Block B so far: the own index writer (`indexer.lua`) and the commands `reindex`/`update`/`stop` (`status` shows the progress; `update` is the delta of the index against the vault, `indexer.sync`). `update` on save is in: `BufWritePost` on a note of an own-index vault, debounced (`indexer.SAVE_DEBOUNCE_MS`), one `sync` → `update`s → `persist` per window; the autocmd group `NoteRetrievalSave` is installed by `indexer.attach_on_save` (from `for_root` and the first `index.locate` of an eigen root) and never in mode `obsidian`. The self-find probe is in (`probe.lua`, `:NoteRetrieval probe [n] [--json]`, run after a full reindex in mode eigen unless `probe_auto` is false). The user docs are in: `README.md`, `docs/` (Diátaxis: tutorial, how-tos, reference, explanation) and the manual `doc/note-retrieval.txt`; `make live` is one run against a real embedding server (`tests/live.lua`).

## Architecture

| Path | What |
|---|---|
| `lua/note_retrieval/config.lua`, `init.lua` | options from `vim.g.note_retrieval` and `setup()`, every problem at once; invalid `endpoints` stop a run (`endpoints_error`); `resolve()` returns `cfg, problems` |
| `lua/note_retrieval/roots.lua` | the vault root (option `roots`, else the nearest `.obsidian/` or `.zk/`), the mode (`obsidian` reads the index of the Obsidian plugin, `eigen` keeps its own), the index path and the set of note paths; never writes to anything Obsidian owns |
| `lua/note_retrieval/embedder.lua` | server and model of a run (option, else remembered, else asked; in mode `obsidian` the model must be the index header's, else `model-mismatch`), one query embedding with no instruction in front, the adapter for the kit's `live_indexer`; callbacks only |
| `lua/note_retrieval/state.lua` | the model chosen per server, `stdpath('state')/note-retrieval/state.json` |
| `lua/note_retrieval/index.lua`, `search.lua` | the index in memory (loaded on first need, reloaded when the file changes, never written in mode `obsidian`); `related` from a note's row, `search` with one embedding call, `pick` |
| `lua/note_retrieval/indexer.lua` | the writer of the own index (mode `eigen` only): one indexer per root, full reindex with progress (`status`, `statusline`, `stop`), the delta against the vault (`sync`: new, changed by stamp, zero and vanished rows; one `persist('heal')`), every write behind mode check (read fresh), lock under `stdpath('state')`, backup (first write of a session, before a reindex) and the kit's guards; errors are `{ kind, message }` values |
| `lua/note_retrieval/probe.lua` | the self-find probe: the kit's sample order and query over the notes of the loaded index, each searched through `search.search` one after another, rank 0 expected; `run`, `json`, `lines`, `auto` (after a full reindex, never while a writer runs); reads only |
| `lua/note_retrieval/links.lua`, `panel.lua` | link targets and how a link is written (`link_format` `wiki`\|`markdown`); the panel with the related notes |
| `lua/note_retrieval/command.lua`, `status.lua`, `messages.lua`, `health.lua`, `plugin/note_retrieval.lua` | `:NoteRetrieval {related\|search\|status\|model\|reindex\|update\|stop\|probe\|reset}` and the `<Plug>` mappings; the state shown by `status`; one sentence with the next step for every error value (strings of `related` and the index, `{ kind }` tables of `search` and the embedder); `:checkhealth note_retrieval`; the plugin file loads only the command and the mappings, no index is read at start |
| `lua/note_retrieval/kit/` | vendored from `nvim-kit` (`VENDOR.json`) — never edit |
| `tests/` | specs for the kit's headless runner (`tests/run.lua`) |
| `doc/note-retrieval.txt` | the manual, `:help note-retrieval` — the manual: commands, mappings, Lua API, options, limits. `README.md` and `docs/reference/` repeat the names and defaults for reading outside Neovim; `tests/docs_spec.lua` checks the names |

Boundaries: the index core (chunker, vectors, VRIX, guards, live indexer, probe) lives in nvim-kit; this plugin owns the options, the commands and the views.

## Commands

```bash
make check           # stylua --check · selene · tests in headless Neovim · vendor-check (../tools/kit/vendor.py)
make release-check   # Bibliothek gate over everything since the last tag (../tools/bibliothek/gate.py)
make live            # one run against a real embedding server; tests/live.lua (NOTE_RETRIEVAL_LIVE_URL and _MODEL required)
make test NVIM=/path/to/nvim   # the suite with another Neovim — the minimum version run:
# D=$(mktemp -d); curl -sfL https://github.com/neovim/neovim/releases/download/v0.10.4/nvim-macos-arm64.tar.gz | tar -xz -C "$D"; xattr -cr "$D"
# make test NVIM="$D/nvim-macos-arm64/bin/nvim"
```

Tools: `brew install stylua selene`. Neovim ≥ 0.10. The Dach (`..`) must be present for `vendor-check` and `release-check`; without it they print `SKIPPED`, which is not a pass.

## Conventions

- **Never edit vendored files** (`lua/note_retrieval/kit/`). Fix in nvim-kit, tag, re-vendor from the Dach (zsh-safe full form; the module list is in `lua/note_retrieval/kit/VENDOR.json`, 23 files plus `data/`):

  ```
  cd .. && L=(); for m in llm sampling llm_json http_stub chunker vectors vrix index_guard index_delta probe live_indexer lock store scratch text date data walk debounce health test conformance wait; do L+=("lua/nvim_kit/$m.lua:lua/note_retrieval/kit/$m.lua"); done; PYTHONDONTWRITEBYTECODE=1 python3 tools/kit/vendor.py add note-retrieval.nvim --source nvim-kit --ref <tag> --manifest lua/note_retrieval/kit/VENDOR.json --license AGPL-3.0-only --header "${L[@]}" lua/nvim_kit/data/:lua/note_retrieval/kit/data
  ```
- **Every module under `lua/note_retrieval/` except `kit/` carries `-- domain: note_retrieval` in its first five lines** (`tests/kit_spec.lua` checks it). Fachfreie helpers belong in nvim-kit (`../AGENTS.md`, "Bibliothek ab Eins"); the gate does not see `local function`s in a domain module, the reviewer does.
- `http_stub` is vendored for tests only; no plugin module requires it.
- Every test has a counter-check that shows it can fail.
- **A user-visible change updates the docs in the same commit:** `doc/note-retrieval.txt` for commands, keys and options, and `README.md` and `docs/` where they repeat it (the panel text, the marks, the limits). `tests/docs_spec.lua` checks option tags, command tags and `<Plug>` tags against the code, and that README and the reference name every command, option and `<Plug>` mapping.

## Memory

- Cockpit (SSOT for status and tasks): `$VAULT/25_Coding/note-retrieval.nvim/note-retrieval.nvim.md`.

## Abweichungen von der Leitkonvention

- README-Tier: wie transmute.nvim (`nvim-plugin`), nicht gegen die Tier-Spezifikation gemessen. Noch kein Hero-Bild (CORE-META-03): die README zeigt das Panel als Text, ausdrücklich als Beispiel gekennzeichnet (Notizen aus der Fixture, Werte nicht gemessen).
- Nutzer-Doku doppelt angelegt: `:help note-retrieval` ist das Handbuch, `docs/` die Diátaxis-Doku. Anders als bei transmute.nvim stehen Befehle und Optionen auch in README und `docs/reference/`; `tests/docs_spec.lua` prüft Namen von Optionen, Befehlen und `<Plug>`-Belegungen gegen den Code, die Standardwerte prüft kein Test.
