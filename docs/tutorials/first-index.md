# Tutorial: your first index

You build the index of a small vault and open the first related note. It takes a few minutes. You need Neovim ≥ 0.10, curl, and an embedding server: Ollama or LM Studio running on this machine with an embedding model (for Ollama, for example `ollama pull nomic-embed-text`). Setting one up: [jkaindl.de/uplink/llm-setup](https://jkaindl.de/uplink/llm-setup/).

## 1. Open a note

Open any Markdown note inside a folder that has a `.obsidian/` or `.zk/` folder, or set `vim.g.note_retrieval = { roots = { '~/notes' } }` first. This is the notes folder (the root).

Run `:checkhealth note_retrieval`. It checks Neovim, curl, the notes folder, the index, the options and the servers, and changes nothing. A missing index is expected at this point.

## 2. Choose the model

Run `:NoteRetrieval model`. The plugin asks every server for its models and lets you pick one; the choice is remembered per server. An embedding model is part of the index: all notes and every later query must be embedded by the same one.

## 3. Build the index

Run `:NoteRetrieval reindex`. The message says which model is used. The work runs in the background and you can keep writing. `:NoteRetrieval status` shows the progress.

When it is done, one line shows the result. By default (`probe_auto`) a check follows: `note-retrieval: probe after the reindex: 8/8 on rank 0` means eight notes, searched with their own text, each came back first.

## 4. See the first related note

Run `:NoteRetrieval related`. The panel opens on the right with the notes closest in meaning to the note you are in. Move to another note: the panel follows. Press `<CR>` on an entry to open it, `l` to write a link to it into the note, `q` to close the panel.

## 5. Search by meaning

Run `:NoteRetrieval search` and type a few words, or select text in Visual mode and use `<Plug>(note-retrieval-search)`. The query is embedded once and the closest notes are listed; pick one to open it.

## 6. Keep it current

Save a note: after one second of quiet the plugin updates the index for it (option `index_on_save`). In a new Neovim session, run `:NoteRetrieval update` once; it embeds what changed while Neovim was closed and starts the update-on-save. More: [keep the index current](../how-to/keep-the-index-current.md).

## Next

- [Map keys](../how-to/map-keys.md)
- [Use the panel](../how-to/use-the-panel.md)
- [Troubleshoot](../how-to/troubleshoot.md)
