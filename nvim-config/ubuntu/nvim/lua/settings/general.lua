-- check for extra config https://www.chrisatmachine.com/Neovim/02-vim-general-settings/
vim.opt.compatible = false                      -- We're running Vim, not Vi!
vim.cmd('syntax enable')                        -- Enables syntax highlighting
vim.opt.encoding = 'utf-8'                      -- The encoding displayed
vim.opt.fileencoding = 'utf-8'                  -- The encoding written to file
vim.opt.mouse = 'a'                             -- Enable your mouse
vim.opt.ruler = true                            -- Show the cursor position all the time
vim.opt.termguicolors = true                    -- Support 256 colors
vim.opt.clipboard = 'unnamedplus'               -- Copy paste between vim and everything else
vim.opt.tabstop = 2                             -- Insert 2 spaces for a tab
vim.opt.shiftwidth = 2                          -- Change the number of space character
vim.opt.smarttab = true                         -- Makes tabbing smarter will realize you have 2 vs 4
vim.opt.expandtab = true                        -- Converts tabs to spaces
vim.opt.smartindent = true                      -- Makes indenting smart
vim.opt.autoindent = true                       -- Good auto indent
vim.opt.laststatus = 0                          -- Always display the status line (commented out in original)
vim.opt.number = true                           -- Line numbers
vim.opt.cursorline = true                       -- Enable highlighting of the current line
vim.opt.clipboard = 'unnamedplus'               -- Copy paste between vim and everything else
vim.opt.formatoptions:remove({ 'c', 'r', 'o' }) -- Stop newline continuation of comments
vim.opt.pumheight = 10                          -- Makes popup menu smaller
vim.opt.cmdheight = 2                           -- More space for displaying messages
vim.opt.iskeyword:append('-')                   -- treat dash separated words as a word text object
vim.opt.showmode = false                        -- We don't need to see things like -- INSERT -- anymore
vim.cmd('filetype indent on')                   -- Enable indentation rules that are file-type specific
vim.cmd('filetype plugin on')                   -- Enable file-specific plugins
vim.cmd('filetype on')                          -- Enable filetype detection
vim.opt.showtabline = 2                         -- Always show tabs (commented out in original)
vim.opt.autochdir = true                        -- Your working directory will always be the same as your working directory (commented out in original)
vim.opt.background = 'dark'                     -- Set background to dark (commented out in original)

-- support colors for nvim and vim8
if vim.fn.has("termguicolors") == 1 then
  vim.opt.termguicolors = true
end

-- vim.cmd('colorscheme ayu') -- Set colorscheme to ayu
vim.cmd.colorscheme "catppuccin"

-- auto source when writing to init.lua
vim.cmd('autocmd BufWritePost init.lua source %')

-- disable auto-commenting for a new line after a comment
vim.cmd('autocmd FileType * setlocal formatoptions-=c formatoptions-=r formatoptions-=o')

-- Search down into subfolders
-- Provides tab-completion for all file-related task
vim.opt.path:append('**')

vim.opt.omnifunc = 'syntaxcomplete#Complete'

-- Display all matching files when we tab complete
vim.opt.wildmenu = true

vim.opt.wildignore:append({
  '*/.git/*', '*/.hg/*', '*/.svn/*', '*/.idea/*', '*/.DS_Store',
  '*/vendor', '*/node_modules/*', '*/tmp/*'
})

vim.g.ctrlp_custom_ignore = 'node_modules\\|DS_Store\\|git\\|tmp'
