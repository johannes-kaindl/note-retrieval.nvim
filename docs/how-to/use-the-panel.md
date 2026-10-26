# How-to: use the panel

`:NoteRetrieval related` (or `<Plug>(note-retrieval-related)`) opens the panel on the right; the same command closes it. It lists the notes closest in meaning to the note in your current window, best first, with the similarity. It follows you: when you move to another note, the list changes. It reads the vectors from the index and calls no server.

## Keys in the panel

| Key | Does |
|---|---|
| `<CR>` | Open the note under the cursor. |
| `l` | Write a link to the note under the cursor into the note you came from. The form is the option `link_format` (`wiki` or `markdown`). |
| `q` | Close the panel. |

## What is listed

- At most `k` notes (default 20), none below `min_similarity` (default 0.3).
- With `hide_linked` (default true) the notes your current note already links to are left out.
- With `exclude` (own index only) path prefixes are left out of the index itself.

## The marks

The note you are viewing can have changed since its vector was made. The panel then says so in words, once, at the end of its first line (`Related to <note>: 3 notes; changed since the index`); the listed entries carry no mark of their own:

- `changed since the index`: the file's modification time or size differs from the stamp stored in the index. This is exact.
- `may be stale, index from <date time>`: the row has no real stamp, and the file is newer than the index was built. This is a lower bound, not a promise. Details: [the stale mark](../explanation/stale-mark.md).

Run `:NoteRetrieval update` (own index) to bring the vectors up to date.

## When the panel shows nothing

- `no row for this note in the index`: the note is new, was left out, or the index is older than the note. In your own index, `:NoteRetrieval update` embeds it.
- No notes folder: set `roots`, see [troubleshoot](troubleshoot.md).
