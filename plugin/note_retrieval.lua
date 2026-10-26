if vim.g.loaded_note_retrieval then
  return
end
vim.g.loaded_note_retrieval = true

if vim.fn.has('nvim-0.10') == 0 then
  vim.notify('note-retrieval.nvim needs Neovim 0.10 or newer.', vim.log.levels.ERROR)
  return
end

-- Nothing is loaded here but the command: no module, no index, until the first command runs.
vim.api.nvim_create_user_command('NoteRetrieval', function(o)
  require('note_retrieval.command').run(o)
end, {
  nargs = '*',
  desc = 'note-retrieval: related notes and semantic search over a Markdown vault',
  complete = function(arglead, cmdline)
    return require('note_retrieval.command').complete(arglead, cmdline)
  end,
})

vim.keymap.set('n', '<Plug>(note-retrieval-related)', function()
  require('note_retrieval.command').related()
end, { desc = 'note-retrieval: open or close the panel of related notes' })
vim.keymap.set('n', '<Plug>(note-retrieval-search)', function()
  require('note_retrieval.command').search()
end, { desc = 'note-retrieval: search the notes by meaning' })
vim.keymap.set('x', '<Plug>(note-retrieval-search)', function()
  require('note_retrieval.command').search_selection()
end, { desc = 'note-retrieval: search the notes for the selected text' })
