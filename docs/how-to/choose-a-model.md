# How-to: choose a model

Run `:NoteRetrieval model`. Every configured server is asked for its models; with one server that lists models you pick the model directly; with several, you pick the server first (the one a run uses is marked `(used first)`) and then its model. A server that lists no model or does not answer is not offered. The picker waits until all servers have answered or failed (a server that does not answer slows the picker down by its timeout). The model you pick is remembered per server in `stdpath('state')/note-retrieval/state.json`.

## Which model

Use an embedding model, not a chat model: for Ollama `nomic-embed-text` or `mxbai-embed-large`, for LM Studio any embedding model you have loaded. The server must speak the OpenAI API (`/v1/models` and `/v1/embeddings`).

## Fix the model in the options

Set `embedding_model` to override the remembered choice, and `endpoints` for servers other than the defaults (Ollama on `http://localhost:11434`, then LM Studio on `http://localhost:1234`):

```lua
vim.g.note_retrieval = {
  endpoints = { { url = 'http://localhost:1234', model = 'my-embedding-model' } },
}
```

## Changing the model later

An index belongs to one model. If you change it, `search` is switched off on the old index ("Search is off: this index was built with the model …") and a write refuses to mix the two vector spaces. Run `:NoteRetrieval reindex` to rebuild the index with the new model. `related` keeps working on the old index, because it needs no server.

## An index from the Obsidian plugin

In mode `obsidian` the model is the one named in the index header; `:NoteRetrieval model` is only needed to pick which server and model name serves it. If the server does not offer that exact model, `search` is off and `related` still works.
