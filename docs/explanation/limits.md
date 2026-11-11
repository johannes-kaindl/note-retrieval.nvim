# Explanation: known limits

What the plugin does not do in 0.1.0, written down so that it is not a surprise. None of these loses a note; each has a way out.

## Commands

- **`:NoteRetrieval stop` does not act on a running `update`.** `stop` ends a reindex. During an `update` it says that the update is running and cannot be stopped, and the update runs on. Way out: wait for it; an update is a delta and short.
- **The first step of an `update` stalls Neovim for a moment.** Walking the vault and reloading the index block Neovim for about 45 ms when the index is unchanged and 60 to 70 ms when it has to be read again (11,000 notes, measured as one step on a copy of the vault, 2026-10-30; the delta step after it about 41 ms). The rest runs in the background. Measured again on a synthetic vault (2026-11-11, 256 columns, warm cache, five runs each): at 10,000 notes 32 to 53 ms unchanged and 85 to 88 ms when the index is read again; at 20,000 notes 50 to 60 ms and 130 to 160 ms. The delta step after it takes 29 to 49 ms at 10,000 notes (42 to 49 ms at 20,000). The check for all-zero vectors inside it is no part of the cost (1.6 ms at most, even when every row is read to its last cell); the matrix is built (14 to 18 ms) and copied into a list for the check (13 to 31 ms). `reindex` starts with the same walk and reload and returns to the editor after 36 to 60 ms (53 to 80 ms when the index is read again) at 10,000 notes. Neither is split into steps; see [decisions](../internal/decisions.md).

## Update on save

- **Quitting within a second of a save loses that save's batch.** The batch waits 1000 ms for quiet; the timer dies with Neovim. The next `:NoteRetrieval update` embeds the note again.
- **A fresh session indexes nothing on save** until `update` or `reindex` has started the indexer once. The first save prints a one-time hint.
- Only the own index is updated on save. Never an index of the Obsidian plugin.

## Writing the index

- **Another Neovim wrote in between: the write is refused.** The plugin reads the file, embeds, and writes only if the file is unchanged since the read (`changed`). It does not merge. Way out: run `update` again. The update after a save repeats its whole sequence once on `changed` (read the index again, embed, write), so the notes of that batch are embedded twice (measured with a counting embedder: two requests for one saved note, `tests/onsave_spec.lua`); a second refusal is reported once and the notes wait for the next `update`. There is no merge helper in the kit because there is no second user for one; see [decisions](../internal/decisions.md).
- **The lock is per write, not per full reindex.** Two Neovim instances reindexing the same vault do not block each other for the whole run; each write is atomic, and the guards refuse a write that would shrink the index. Measured with two Neovim processes started 300 ms apart on 6,000 notes (2026-11-11, three runs): both finished with all 6,000 notes, the index file was valid every time, and each process embedded all 6,000 notes (the work is done twice). The intermediate states every 250 notes collide with the other's lock now and then: each process then prints `an intermediate state could not be written - the run goes on` (1 to 9 times per run); the last write wins. Nothing is lost, but start a reindex in one Neovim only.
- **Notes that cannot be embedded thin the index.** A run writes when it stays above half of the rows; the failed notes are reported as a count and are missing from the index. `reindex` or `update` tries them again.
- **The guard `shrink` blocks an `update` that would drop more than half of the rows while the files still exist** (a vault mount that is gone, or one that reads every note as empty, for example; notes that are empty after the front matter lose their row, and that counts too). Way out: `:NoteRetrieval reset`, or `:NoteRetrieval reindex` to rebuild.
- **Unreadable folders keep their rows.** If a folder cannot be read, its notes (and those in the folders below it) are not treated as deleted. If the vault folder itself could only be read in part, no row is dropped at all, because it is not known which entries are missing; the message of the `update` says how many folders could not be read.

## Model

- **The folder picker of `:NoteRetrieval model` waits for all endpoints.** One server that does not answer delays the picker by its timeout.
- **One model per index.** Changing the model switches search off on the old index until `reindex`; `related` keeps working.

## The mark

- **"Changed since the index" is exact only for rows with a real stamp.** See [the stale mark](stale-mark.md).
