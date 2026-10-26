---
tags: [lua, neovim]
---
# Neovim API

Plugins call vim.api functions to read and change buffers, and vim.uv for files and timers. Callbacks of vim.uv run in a fast event where most of the API is not allowed, so wrap the work in vim.schedule. Keep the load of a plugin cheap: require a module only when its command runs, as with the private helpers kept in [[Lua/closures]].
