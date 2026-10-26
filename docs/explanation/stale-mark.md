# Explanation: what the "changed" mark promises

The panel can mark a note whose file may be newer than its vector. There are two marks and they do not mean the same.

## Exact: `changed since the index`

When an index row carries a real stamp, `[mtime_ms, size]` of the file at the time its vector was made, the plugin compares it with the file now. If the modification time or the size differs, the note has changed since the index. This is as exact as a file stamp is: a copy that keeps the same time and size is not noticed, and a change that only touches the file's time is.

## A lower bound: `may be stale, index from <date time>`

Almost every row written by the Obsidian plugin has the stamp `[0, 0]`, which means "no stamp". The plugin cannot compare. What it can do is compare the file's modification time with the header's `built_at`, the moment the index was built. A file modified after that is marked `may be stale`.

This is a lower bound, not a promise:

- A note modified after the build is marked, whether or not its vector was made from the new text: the plugin cannot tell.
- A note whose vector is outdated but whose file time is not newer than `built_at` (a file restored with its old time, for example) is not marked.

So an unmarked note is not proof that its vector is current. A marked one is a hint to look.

## Nothing is ever re-stamped

The mark is a reading aid, computed from what is in memory and the file's time; it never writes anything. Nothing re-stamps a row to make it exact, so a `[0, 0]` row stays a `[0, 0]` row until a real embedding of that note replaces the row.
