# Changelog

All notable changes to this project are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/), and the project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- `:NoteRetrieval stop` during an `update` (or the update after a save) says that the update is running and cannot be stopped, instead of "no reindex is running". It still does not stop it.

### Changed
- `:NoteRetrieval probe` tells a tie from a real miss, as `index-probe.ts` of vault-rag does: a note that stands behind the best hit with exactly its own score (notes with the same vector, the order between them is arbitrary) is shown as `tie`, counted apart (`7/8 on rank 0 (1 tie with the best hit, 0 real misses)`) and no longer makes the message a warning; the line of a real miss gives both scores. `--json` gains `ties`, `misses` and, per failure, `score`, `top_score` and `tie`. The probe after a reindex names ties too and warns only for real misses.
- Vendors nvim-kit 0.17.0 (was 0.16.1): the kit's `endpoint_model.choose` reports a write error of the remembered model as `cb(id, err)` instead of raising. No visible change yet.
- The two model pickers (`:NoteRetrieval model` and the question of a first search) use the kit's `endpoint_model.choose` (through `state.choose`) instead of their own `vim.ui.select` call, so the prompt text lives in one place. Same prompt, same behaviour: a pick that cannot be remembered still counts, and `model` still says so.
- Vendors nvim-kit 0.16.1 (was 0.15.0); `state.lua` is the kit's `endpoint_model` over this plugin's state file (same file, same behaviour: a broken file reads as nothing and is set aside).
- `make live` prints the number of notes that failed to embed in its result line.
- The stall of the first `update` step is documented as measured in one step: about 45 ms with an unchanged index, 60 to 70 ms when the index is read again (11,000 notes); earlier text said about 90 ms, a sum of single measurements.

## [0.1.0] - 2026-10-27

### Added
- The own index writer and its commands: `:NoteRetrieval reindex` (full build in the background), `update` (the delta against the notes, written once), `stop` (ends a reindex; it does not act on a running `update`), update on save (debounced 1000 ms, own mode only, option `index_on_save`; the first save of a session prints a one-time hint until `update` has started the indexer), and `reset` also forgets the attach, the waiting batch and the hint. The index file is written under a lock, with a backup and the guards of the index core; the Obsidian index is never written.
- `:NoteRetrieval probe [n] [--json]` and the option `probe_auto` (a probe of 8 notes after a full reindex): notes of 201 to 800 UTF-16 code units are searched with their own first 300 units and should come back at rank 0; read-only, so it works on an Obsidian index too.
- Options `exclude`, `index_dir`, `probe_auto`.
- Documentation: README, `docs/` (tutorial, how-tos, reference, explanation, including the limits and the stale mark), and the complete manual `:help note-retrieval`; `make live` for one run against a real embedding server (`NOTE_RETRIEVAL_LIVE_URL`, `NOTE_RETRIEVAL_LIVE_MODEL`); a fixture vault of twenty notes for tests.
- `:NoteRetrieval related|search|status|model|reset`, `<Plug>(note-retrieval-related)` and `<Plug>(note-retrieval-search)` (Visual mode: the selection is the query), the Lua API `search`, `related` and `status`, and `:checkhealth note_retrieval`; every error is one sentence with the next step.
- Scaffold: the options (`roots`, `endpoints`, `embedding_model`, `k`, `min_similarity`, `hide_linked`, `link_format`, `index_on_save`, `timeout_ms`) from `vim.g.note_retrieval` or `setup()`, checked all at once; vendors nvim-kit 0.15.0 (`lua/note_retrieval/kit/VENDOR.json`).
