local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
-- Tests never touch the person's own state: stdpath('state') follows XDG_STATE_HOME.
vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.o.showmode = false
vim.opt.shortmess:append('Sq')
-- Notices a test does not capture would print without a newline and glue onto the next result line.
vim.notify = function() end
require('note_retrieval.kit.test').main(root .. '/tests')
