-- Minimal config for the README demo (make demo): this checkout, Neovim's defaults, nothing else.
-- Prerequisite: an OpenAI-compatible embedding server with the model below. The defaults are Ollama on
-- this machine and `ollama pull qwen3-embedding:0.6b` (the pair `make live` uses too). Override them with
--   NOTE_RETRIEVAL_DEMO_URL=http://localhost:1234 NOTE_RETRIEVAL_DEMO_MODEL=<embedding model> make demo
-- The tape runs this in a throw-away copy of the fixture vault with throw-away XDG_*_HOME folders, so the
-- recording never touches your own config, state or index.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
vim.opt.rtp:prepend(root)
vim.o.number = false
vim.o.linebreak = true -- wrap the note text at word ends, not mid-word
vim.o.termguicolors = true
vim.o.laststatus = 2
vim.o.cmdheight = 3 -- the 3-line reindex message fits without a hit-enter prompt
vim.o.shortmess = vim.o.shortmess .. 'I'
vim.o.shadafile = 'NONE' -- the demo's history stays out of the recording machine's ShaDa
local url = os.getenv('NOTE_RETRIEVAL_DEMO_URL') or 'http://localhost:11434'
local model = os.getenv('NOTE_RETRIEVAL_DEMO_MODEL') or 'qwen3-embedding:0.6b'
vim.g.note_retrieval = { endpoints = { { url = url, model = model } }, embedding_model = model }
vim.cmd.runtime('plugin/note_retrieval.lua')
