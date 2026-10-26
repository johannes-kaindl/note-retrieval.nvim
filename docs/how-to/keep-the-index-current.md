# How-to: keep the index current

This applies to your own index (`eigen`). An index of the Obsidian plugin is kept by Obsidian; here `reindex`, `update` and update-on-save only say that the index is read-only.

## Update on save

With `index_on_save` (default true), saving a Markdown note (`BufWritePost` on `*.md`) in a vault with an own index updates the index for that note:

- The update waits for 1000 ms of quiet. All notes saved in that window go in one batch: each is embedded, then the index is written once.
- It starts only after something has started an indexer in this session. In a fresh session, a save prints once per vault: `note-retrieval: saved notes are not indexed yet in this session; run :NoteRetrieval update once to start`. It never asks for a model by itself.
- Quitting Neovim within a second of a save loses that batch (the timer dies with the process). Nothing is damaged: the next `:NoteRetrieval update` embeds the note again.

## Update by hand

`:NoteRetrieval update` compares the notes on disk with the index: it embeds new notes, notes whose file is newer than their row, and rows with an all-zero vector, drops the rows of deleted notes and writes once, in the background. It first writes any batch that is still waiting for its second of quiet. The result is one line, such as `update of <root>: 3 embedded, 1 removed, 0 failed`; failed notes are tried again by the next `update`.

## Rebuild everything

`:NoteRetrieval reindex` embeds every note again. Use it when you changed the model, after the message about another vector size, or when `update` refuses with the guard `shrink`. It runs in the background; `:NoteRetrieval status` shows the progress and `:NoteRetrieval stop` ends it (what it reached is written, the rest of the index is as it was). A full reindex is followed by a self-check of 8 notes unless `probe_auto` is false.

## Start over

`:NoteRetrieval reset` forgets what the plugin holds in memory: the loaded index, the vault settings, the attach to saves, the waiting batch and the one-time hint. The next command reads everything again. A running reindex is left alone, and the message says so.

## Turn it off

Set `index_on_save = false` to stop update-on-save; `update` and `reindex` still work by hand.
