-- Key mappings for tabs
vim.api.nvim_set_keymap('n', 'tn', ':tabnew<Space>', { noremap = true })
vim.api.nvim_set_keymap('n', 'tk', ':tabnext<CR>', { noremap = true })
vim.api.nvim_set_keymap('n', 'tj', ':tabprev<CR>', { noremap = true })
vim.api.nvim_set_keymap('n', 'th', ':tabfirst<CR>', { noremap = true })
vim.api.nvim_set_keymap('n', 'tl', ':tablast<CR>', { noremap = true })

-- Some helpers to edit mode
-- http://vimcasts.org/e/14
vim.api.nvim_set_keymap('n', '<leader>ew', ':e <C-R>=expand("%:h") . "/"<cr>', { noremap = true })
vim.api.nvim_set_keymap('n', '<leader>es', ':sp <C-R>=expand("%:h") . "/"<cr>', { noremap = true })
vim.api.nvim_set_keymap('n', '<leader>ev', ':vsp <C-R>=expand("%:h") . "/"<cr>', { noremap = true })
vim.api.nvim_set_keymap('n', '<leader>et', ':tabe <C-R>=expand("%:h") . "/"<cr>', { noremap = true })

-- Better nav for omnicomplete
vim.api.nvim_set_keymap('i', '<c-j>', '("\\<C-n>")', { expr = true, noremap = true })
vim.api.nvim_set_keymap('i', '<c-k>', '("\\<C-p>")', { expr = true, noremap = true })

-- Use alt + hjkl to resize windows
vim.api.nvim_set_keymap('n', '<M-j>', ':resize -2<CR>', { noremap = true })
vim.api.nvim_set_keymap('n', '<M-k>', ':resize +2<CR>', { noremap = true })
vim.api.nvim_set_keymap('n', '<M-h>', ':vertical resize -2<CR>', { noremap = true })
vim.api.nvim_set_keymap('n', '<M-l>', ':vertical resize +2<CR>', { noremap = true })

-- I hate escape more than anything else
vim.api.nvim_set_keymap('i', 'jk', '<Esc>', { noremap = true })
vim.api.nvim_set_keymap('i', 'kj', '<Esc>', { noremap = true })

-- Better tabbing
vim.api.nvim_set_keymap('v', '<', '<gv', { noremap = true })
vim.api.nvim_set_keymap('v', '>', '>gv', { noremap = true })

-- Better window navigation
vim.api.nvim_set_keymap('n', '<C-h>', '<C-w>h', { noremap = true })
vim.api.nvim_set_keymap('n', '<C-j>', '<C-w>j', { noremap = true })
vim.api.nvim_set_keymap('n', '<C-k>', '<C-w>k', { noremap = true })
vim.api.nvim_set_keymap('n', '<C-l>', '<C-w>l', { noremap = true })


-- Key mappings for NvimTree
-- vim.api.nvim_set_keymap('n', '<leader>n', ':NvimTreeFocus<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<leader>n', ':NvimTreeToggle<CR>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<C-f>', ':NvimTreeFindFile<CR>', { noremap = true, silent = true })

-- telescope file search
local telescope_builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>ff', telescope_builtin.find_files, {})
vim.keymap.set('n', '<leader>fg', telescope_builtin.live_grep, {})
vim.keymap.set('n', '<leader>fb', telescope_builtin.buffers, {})
vim.keymap.set('n', '<leader>fh', telescope_builtin.help_tags, {})
