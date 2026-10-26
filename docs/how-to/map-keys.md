# How-to: map keys

The plugin sets no key of its own. It defines two `<Plug>` mappings:

| Mapping | Modes | Does |
|---|---|---|
| `<Plug>(note-retrieval-related)` | Normal | Same as `:NoteRetrieval related`: open or close the panel. |
| `<Plug>(note-retrieval-search)` | Normal, Visual | Same as `:NoteRetrieval search`; in Visual mode the selected text is the query. |

With lazy.nvim:

```lua
{
  'johannes-kaindl/note-retrieval.nvim',
  cmd = 'NoteRetrieval',
  keys = {
    { '<Leader>nr', '<Plug>(note-retrieval-related)', desc = 'related notes' },
    { '<Leader>ns', '<Plug>(note-retrieval-search)', mode = { 'n', 'x' }, desc = 'search notes' },
  },
}
```

Without a plugin manager:

```lua
vim.keymap.set('n', '<Leader>nr', '<Plug>(note-retrieval-related)')
vim.keymap.set({ 'n', 'x' }, '<Leader>ns', '<Plug>(note-retrieval-search)')
```

The keys inside the panel (`<CR>`, `l`, `q`) belong to the panel buffer and are not configurable in 0.1.0.
