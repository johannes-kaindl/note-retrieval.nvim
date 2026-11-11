# Reference: the index

## Modes

| Mode | Shown as | Who writes | When |
|---|---|---|---|
| Own index | `own` | this plugin | Default. |
| Obsidian index | `obsidian` | the Obsidian plugin Vault Retrieval; this plugin never | The vault has `.obsidian/plugins/vault-retrieval/` and an `index.bin` in the plugin's `indexDir` (default `_vaultrag`, read from the plugin's `data.json`) or in the option `index_dir`. |

The mode is read fresh before every write, never from a cache.

## Where files live

| File | Path |
|---|---|
| Own index | `stdpath('data')/note-retrieval/<hash>/index.bin`, where `<hash>` is the first 16 hex digits of the SHA-256 of the root; or `<root>/<index_dir>/index.bin` with the option `index_dir`. |
| Lock | `stdpath('state')/note-retrieval/<hash>/index.lock`. A lock older than 1800 s is taken over. |
| Backup | `stdpath('state')/note-retrieval/<hash>/index.bin.bak`: a copy from before the first write of a session and before a full reindex. |
| Remembered models | `stdpath('state')/note-retrieval/state.json`: `{ "models": { "<endpoint url>": "<model id>" } }`. |

The lock is taken for one write, not for a whole reindex. Writes are atomic.

## The file

`index.bin` is a VRIX container, the format of the Obsidian plugin Vault Retrieval; both plugins read each other's files.

```text
"VRIX" · u32 headerLen (little endian) · header JSON · int8 matrix · u32 CRC32 (little endian)
```

The CRC covers everything before it. The header holds, in this order: `schema_version` (2), `vault`, `embedding_model`, `source_dim`, `index_dim`, `granularity`, `aggregation`, `quant`, `scale`, `count`, `source_commit`, `built_at`, `paths` (the notes, one per matrix row) and `stamps`. A stamp is `[mtime_ms, size]` of the note when its vector was made; `[0, 0]` means no stamp. The format is frozen; the vendored code in `lua/note_retrieval/kit/` is byte-identical to nvim-kit and is checked against the conformance vectors.

## Which index is read

`:NoteRetrieval status` shows the root, the mode, the index path, the number of notes, the model and the age. `:checkhealth note_retrieval` shows which index is looked for.
