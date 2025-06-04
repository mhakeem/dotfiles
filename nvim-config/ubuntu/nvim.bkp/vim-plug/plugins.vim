
" Plugins
call plug#begin()
  " NERDTree and its plugins
  Plug 'preservim/nerdtree'
  Plug 'Xuyuanp/nerdtree-git-plugin'
  Plug 'ryanoasis/vim-devicons'
  Plug 'tiagofumo/vim-nerdtree-syntax-highlight'

  Plug 'vim-airline/vim-airline'
  Plug 'vim-airline/vim-airline-themes'

  Plug 'ctrlpvim/ctrlp.vim'
  Plug 'mattn/emmet-vim'
  Plug 'jiangmiao/auto-pairs'
  Plug 'tpope/vim-commentary'
  Plug 'vim-syntastic/syntastic'
  Plug 'tpope/vim-endwise'
  Plug 'preservim/tagbar'
  Plug 'airblade/vim-gitgutter'
  Plug 'tpope/vim-fugitive'
  Plug 'tpope/vim-surround'
  Plug 'nathanaelkane/vim-indent-guides'
  Plug 'ap/vim-css-color'

  if has('nvim')
    Plug 'Shougo/deoplete.nvim', { 'do': ':UpdateRemotePlugins' }
  else
    Plug 'Shougo/deoplete.nvim'
    Plug 'roxma/nvim-yarp'
    Plug 'roxma/vim-hug-neovim-rpc'
  endif

  Plug 'autozimu/LanguageClient-neovim', {
    \ 'branch': 'next',
    \ 'do': 'bash install.sh',
    \ }

  " Snipmate
  Plug 'MarcWeber/vim-addon-mw-utils'
  Plug 'tomtom/tlib_vim'
  Plug 'garbas/vim-snipmate'
  " Optional:
  " Plugin 'honza/vim-snippets'


  " Ruby
  Plug 'tpope/vim-rails'
  Plug 'vim-ruby/vim-ruby'

  " themes
  Plug 'joshdick/onedark.vim'
  Plug 'mhartington/oceanic-next'
  Plug 'morhetz/gruvbox'
  " Plug 'ayu-theme/ayu-vim'
  Plug 'Luxed/ayu-vim'
  Plug 'dracula/vim', { 'as': 'dracula' }
  Plug 'catppuccin/nvim', { 'as': 'catppuccin' }

call plug#end()

