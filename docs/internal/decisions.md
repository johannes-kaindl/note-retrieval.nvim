# Decisions: why it is as it is

Short reasons for choices that look like gaps. User-visible limits are in [limits](../explanation/limits.md); this file says why a limit stays. Each entry carries the measurement or the test that backs it, and the date; a reason that no longer holds is a reason to change the code.

## Writing the index

### A refused write is not merged (`changed`)
`Ix:persist` refuses a live or heal write when the index file changed on disk since this indexer read or wrote it, and does not merge. The sequence `sync`, `update`, `persist` runs in one step with nothing in between (`save_batch`, `indexer.lua`); one retry on `changed` re-reads the disk and embeds the batch again (two requests for one saved note, `tests/onsave_spec.lua`, "a changed index file is retried once").
Why not merge: a merge helper belongs in nvim-kit and has no second user (rule "Ort ab Eins, Abstraktion ab Zwei", `../AGENTS.md`); the cost of the retry is one repeated embedding of a small batch, and it needs two Neovim instances writing one index within the save window. Revisit when a second plugin needs the merge, or when the retry shows up in a user report. (Checked 2026-11-11, task 8a.)

### The mode is read once per session by the readers, fresh by the writer
`index.locate` caches mode and index path per root until `:NoteRetrieval reset` or `:checkhealth` (which resets it). Every write resolves the mode again (`mode_refusal`, `indexer.lua`), so a stale cache cannot let the writer touch an index that became the Obsidian plugin's (`tests/indexer_spec.lua`, "mode flip"). A reader with a stale mode shows `eigen` for a vault that turned `obsidian` until `reset`; `status` says so in its last line.
Why not re-resolve on every read: every `related` call would read `data.json` from disk; the case needs the person to install the Obsidian plugin into a vault during a session. (Checked 2026-11-11.)

### The debouncer polls while a run is busy
A save during a reindex or an update leaves its notes pending; `run_batches` finds the indexer busy and arms the debouncer again, once per window (1000 ms). It does not hook into the end of the run. The cost is one table lookup and one timer per second while a run lasts (`tests/onsave_spec.lua`, "a save during a reindex waits until it ends").
Why not hook the end: three code paths end a run (reindex, update, save batch), each would have to call back into the save machinery, and an order mistake there would write between an `update` and its `persist`. The polling cannot do that. Revisit if a profile shows the timer. (2026-11-11.)

## Commands

### The model picker waits for all endpoints
`:NoteRetrieval model` shows the picker when every endpoint has answered or failed, so a silent server delays it by `timeout_ms`.
Why not show it after the first answer: the marker `(used first)` names the first endpoint in priority order that answers, which is known only when every higher-priority endpoint has answered; and the list of endpoints to pick from would grow after it was shown. A picker that fills in later or marks the wrong endpoint is worse than a wait that ends at the timeout. Documented in `docs/how-to/choose-a-model.md`. (2026-11-11.)

## Stalls

### The first step of `update` and `reindex` is not split
Walking the vault and re-reading the index run in one step before the first tick. Measured on a synthetic vault (10,000 and 20,000 notes, 256 columns, 2026-11-11) and on a copy of a personal vault of about 10,800 notes (2026-10-30): see [limits](../explanation/limits.md) for the numbers. Johannes decided on 2026-10-30 to document the stall and to split the step only when someone feels it or a vault is clearly larger than 11,000 notes; the open task is `sync_vault — Walk und Index-Neuladen im selben Tick` in the cockpit. The measurement of 2026-11-11 stands behind that decision, with the re-read at 20,000 notes at about 150 ms as the figure to watch.
The check for all-zero vectors that was feared to be the cost (2.5 million reads) is not: 1.6 ms at most, even when every row is read to its last cell. The cost of the delta step is building and copying the matrix.
