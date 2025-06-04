require('nvim-treesitter.configs').setup({
  -- check for more supported languages https://github.com/nvim-treesitter/nvim-treesitter?tab=readme-ov-file#supported-languages
  ensure_installed = { "lua", "vim", "vimdoc", "query", "javascript", "html", "ruby" },
  sync_install = false,
  -- auto_install = true,
  highlight = { enable = true },
  indent = { enable = true },
  endwise = { enable = true }, -- must install nvim-treesitter-endwise plugin
})
