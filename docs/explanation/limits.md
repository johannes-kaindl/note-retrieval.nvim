# Explanation: known limits

What the plugin does not do in 0.1.0, written down so that it is not a surprise. None of these loses a note; each has a way out.

## Commands

- **`:NoteRetrieval stop` does not act on a running `update`.** `stop` ends a reindex. During an `update` it says `no reindex is running in <root>`, and the update runs on. Way out: wait for it; an update is a delta and short.
- **The first step of an `update` stalls Neovim for a moment.** Walking the vault and reloading the index take about 90 ms together on 13,000 notes (a sum of single measurements; the delta step after it about 41 ms). The rest runs in the background.

## Update on save

- **Quitting within a second of a save loses that save's batch.** The batch waits 1000 ms for quiet; the timer dies with Neovim. The next `:NoteRetrieval update` embeds the note again.
- **A fresh session indexes nothing on save** until `update` or `reindex` has started the indexer once. The first save prints a one-time hint.
- Only the own index is updated on save. Never an index of the Obsidian plugin.

## Writing the index

- **Another Neovim wrote in between: the write is refused.** The plugin reads the file, embeds, and writes only if the file is unchanged since the read (`changed`). It does not merge. Way out: run `update` again.
- **The lock is per write, not per full reindex.** Two Neovim instances reindexing the same vault do not block each other for the whole run; each write is atomic, and the guards refuse a write that would shrink the index.
- **Notes that cannot be embedded thin the index.** A run writes when it stays above half of the rows; the failed notes are reported as a count and are missing from the index. `reindex` or `update` tries them again.
- **The guard `shrink` blocks an `update` that would drop more than half of the rows while the files still exist** (a vault mount that is gone, for example). Way out: `:NoteRetrieval reset`, or `:NoteRetrieval reindex` to rebuild.
- **Unreadable folders keep their rows.** If a folder cannot be read, its notes are not treated as deleted.

## Model

- **The folder picker of `:NoteRetrieval model` waits for all endpoints.** One server that does not answer delays the picker by its timeout.
- **One model per index.** Changing the model switches search off on the old index until `reindex`; `related` keeps working.

## The mark

- **"Changed since the index" is exact only for rows with a real stamp.** See [the stale mark](stale-mark.md).
