# Explanation: why an index has exactly one writer

An index is one file, `index.bin`, with the vectors of all notes of a vault. Two programs that both write it can damage it in ways nobody notices: one overwrites the other's rows, or they mix vectors of two models in one matrix, where cosine similarity between them means nothing. The related panel would still show a list. It would be a wrong list.

So each index has one owner:

- If the vault has an index of the Obsidian plugin Vault Retrieval, Obsidian owns it. This plugin reads it and cannot write it: the reader in `index.lua` is given a storage whose `write` and `mkdir` raise, so there is no write path to get wrong. `reindex`, `update` and update-on-save say so and do nothing.
- Otherwise this plugin owns its own index, in a different place (under `stdpath('data')`, or in `index_dir`). Obsidian's folder is never touched.

The mode is decided from what is on disk at the moment of each write, not from a cache: if the Obsidian plugin appears later, the next write is refused instead of overwriting its index.

## What the owner still guards

Even a single owner can have two Neovim instances. Every write of the own index goes through the same four steps:

1. The mode check.
2. A lock file, taken for that write only.
3. A backup, before the first write of a session and before a full reindex.
4. The guards of the index core: a model other than the index's, another vector size, a drop to far fewer rows than the file on disk holds (`shrink`), and a file changed by another process between read and write (`changed`) are refused, not merged. The write itself is atomic.

A refusal is a sentence with the next step, not a half-written file. The price is that a refused write is lost until you retry; see [known limits](limits.md).

## Why not read and write both

Writing into the Obsidian plugin's index would let Neovim keep it current while Obsidian is closed. The cost is a second writer on a file whose format and rebuild the other plugin controls. The decision here is the cheaper failure: Neovim may show an index that is a little old, and says how old.
