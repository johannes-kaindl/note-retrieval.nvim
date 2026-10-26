# Changelog

All notable changes to this project are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/), and the project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `:NoteRetrieval related|search|status|model|reset`, `<Plug>(note-retrieval-related)` and `<Plug>(note-retrieval-search)` (Visual mode: the selection is the query), the Lua API `search`, `related` and `status`, and `:checkhealth note_retrieval`; every error is one sentence with the next step.
- Scaffold: the options (`roots`, `endpoints`, `embedding_model`, `k`, `min_similarity`, `hide_linked`, `link_format`, `index_on_save`, `timeout_ms`) from `vim.g.note_retrieval` or `setup()`, checked all at once; vendors nvim-kit 0.15.0 (`lua/note_retrieval/kit/VENDOR.json`).
