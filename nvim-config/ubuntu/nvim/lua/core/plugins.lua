-- bootstrapping and initializing lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- plugins list
local plugins = {
  { "catppuccin/nvim",            name = "catppuccin", priority = 1000 },
  { "nvim-tree/nvim-tree.lua" },
  { "nvim-tree/nvim-web-devicons" },
  { "lewis6991/gitsigns.nvim" },
  {
    'nvim-lualine/lualine.nvim',
    dependencies = { 'nvim-tree/nvim-web-devicons' }
  },

  -- BEGIN telescope plugins
  -- ** required and optional plugins for telescope **
  -- NOTE: run `:checkhealth telescope` to check for missing packages
  -- install fd-find using apt (ubuntu) or brew (macOS)
  {
    'nvim-telescope/telescope.nvim',
    tag = '0.1.6',
    dependencies = { 'nvim-lua/plenary.nvim' }
  },
  { "nvim-treesitter/nvim-treesitter",          build = ":TSUpdate" },
  { 'nvim-telescope/telescope-fzf-native.nvim', build = 'make' },
  -- END telescope plugins

  -- lsp
  {
    "williamboman/mason.nvim",
    "williamboman/mason-lspconfig.nvim"
  },
  { 'neovim/nvim-lspconfig' },
  { 'VonHeikemen/lsp-zero.nvim',     branch = 'v3.x' },

  -- automplete
  { 'hrsh7th/nvim-cmp' },     -- autocompletion for nvim
  { 'hrsh7th/cmp-nvim-lsp' }, -- autocompletion support for lsp
  { 'hrsh7th/cmp-buffer' },
  { 'hrsh7th/cmp-path' },
  { 'hrsh7th/cmp-cmdline' },
  { 'L3MON4D3/LuaSnip' },
  { 'saadparwaiz1/cmp_luasnip' },

  -- Ruby
  { 'tpope/vim-rails' },
  { 'vim-ruby/vim-ruby' },
  { 'RRethy/nvim-treesitter-endwise' }

}

local opts = {}

require("lazy").setup(plugins, opts)
