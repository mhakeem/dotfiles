require('core.plugins')
require('settings')

-- #### Other settings

-- defined in language-client.vim
-- keymaps for Deoplete language server autocompletion
-- source: https://www.vimfromscratch.com/articles/vim-for-javascript-and-react-in-2019/
-- vim.api.nvim_set_keymap('n', '<leader>l', ':call LanguageClient_contextMenu()<CR>', { noremap = true })
-- vim.api.nvim_set_keymap('n', 'K', ':call LanguageClient#textDocument_hover()<CR>', { noremap = true })
-- vim.api.nvim_set_keymap('n', 'gd', ':call LanguageClient#textDocument_definition()<CR>', { noremap = true })
-- vim.api.nvim_set_keymap('n', '<leader>r', ':call LanguageClient#textDocument_rename()<CR>', { noremap = true })

-- Create the `tags` file (may need to install ctags first)
-- This'll allow to jump through tags in a file eg. finding class definitions
-- How to use after running ctags:
-- - ctrl+] to jump to tag under cursor
-- - g+ctrl+] for ambiguous tags
-- - ctrl+t to jump back up the tag stack
vim.cmd('command! MakeTags !ctags -R --exclude=.git --exclude=node_modules --exclude=test')

-- let g:SuperTabDefaultCompletionType = "<C-X><C-O>"
-- let g:SuperTabDefaultCompletionType = "context"

-- vim indent guides
-- set ts=4 sw=4 et
vim.g.indent_guides_enable_on_vim_startup = 1
vim.g.indent_guides_start_level = 2
vim.g.indent_guides_guide_size = 1

-- -- SnipMate config
-- vim.g.snipMate = { snippet_version = 1 }

-- -- Emmet config
-- vim.g.user_emmet_install_global = 0
-- vim.cmd('autocmd FileType html,css,eruby,erb,javascript,js,jsx EmmetInstall') -- only html/css files
-- vim.cmd('autocmd FileType html,css,eruby,erb,javascript,js,jsx imap <S-tab> <plug>(emmet-expand-abbr)')

-- -- let g:user_emmet_leader_key='<C-Z>'
-- -- let g:user_emmet_leader_key='<S-Tab>'
-- vim.g.user_emmet_settings = {
--   javascript = {
--     jsx = {
--       extends = 'jsx',
--     },
--   },
-- }

-- -- vim-javascript config
-- vim.g.vim_jsx_pretty_colorful_config = 1

-- -- TagBar Config
-- vim.api.nvim_set_keymap('n', '<F8>', ':TagbarToggle<CR>', { noremap = true })

-- -- vim-prettier config
-- -- vim.g.prettier_autoformat = 0
-- -- vim.cmd('autocmd BufWritePre *.js,*.jsx,*.mjs,*.ts,*.tsx,*.css,*.less,*.scss,*.json,*.graphql,*.md,*.vue PrettierAsync')

-- for Ruby
vim.g.ruby_host_prog = vim.fn.expand('/home/mhakeem/.asdf/shims/neovim-ruby-host')
-- vim.g.ruby_host_prog = '/home/mhakeem/.asdf/installs/ruby/3.2.2/bin/neovim-ruby-host'
-- vim.g.ruby_host_prog = '/home/mhakeem/.asdf/shims/neovim-ruby-host'
-- vim.cmd("let g:ruby_host_prog = '/home/mhakeem/.asdf/shims/neovim-ruby-host'")
vim.cmd('autocmd FileType ruby setlocal expandtab shiftwidth=2 tabstop=2')
vim.cmd('autocmd FileType eruby setlocal expandtab shiftwidth=2 tabstop=2')

-- for JS & JSX
vim.cmd('autocmd BufEnter *.{js,jsx,ts,tsx} :syntax sync fromstart')
vim.cmd('autocmd BufLeave *.{js,jsx,ts,tsx} :syntax sync clear')
