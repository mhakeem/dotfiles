" check for extra config https://www.chrisatmachine.com/Neovim/02-vim-general-settings/
set nocompatible                        " We're running Vim, not Vi!
syntax enable                           " Enables syntax highlighing
set encoding=utf-8			                " The encoding displayed
set fileencoding=utf-8                  " The encoding written to file
set mouse=a                             " Enable your mouse
set ruler              			            " Show the cursor position all the time
set t_Co=256                            " Support 256 colors
set clipboard=unnamedplus               " Copy paste between vim and everything else
set tabstop=2                           " Insert 2 spaces for a tab
set shiftwidth=2                        " Change the number of space character
set smarttab                            " Makes tabbing smarter will realize you have 2 vs 4
set expandtab                           " Converts tabs to spaces
set smartindent                         " Makes indenting smart
set autoindent                          " Good auto indent
" set laststatus=0                        " Always display the status line
set number                              " Line numbers
set cursorline                          " Enable highlighting of the current line
set clipboard=unnamedplus               " Copy paste between vim and everything else
set formatoptions-=cro                  " Stop newline continution of comments
set pumheight=10                        " Makes popup menu smaller
set cmdheight=2                         " More space for displaying messages
set iskeyword+=-                      	" treat dash separated words as a word text object
set noshowmode                          " We don't need to see things like -- INSERT -- anymore
filetype indent on                      " Enable indentation rules that are file-type specific
filetype plugin on                      " Enable file-sepcific plugins
filetype on                             " Enable filetype detection
"set showtabline=2                       " Always show tabs
"set autochdir                          " Your working directory will always be the same as your working directory
" set background=dark

" support colors for nvim and vim8
if (has("termguicolors"))
 set termguicolors
endif

" colorscheme murphy
" let g:oceanic_next_terminal_bold = 1
" let g:oceanic_next_terminal_italic = 1
" colorscheme OceanicNext

" let ayucolor="light"  " for light version of theme
let g:ayucolor="mirage" " for mirage version of theme
" let ayucolor="dark"   " for dark version of theme
colorscheme ayu


" au! BufWritePost $MYVIMRC source %      " auto source when writing to init.vm alternatively you can run :source $MYVIMRC

au! BufWritePost init.vim source %      " auto source when writing to init.vm alternatively you can run :source $MYVIMRC

" disable auto-commenting for a new line after a comment
autocmd FileType * setlocal formatoptions-=c formatoptions-=r formatoptions-=o

" Search down into subfolders
" Provides tab-completion for all file-related task
set path+=**

set omnifunc=syntaxcomplete#Complete

" Display all matching files when we tab complete
set wildmenu

set wildignore+=*/.git/*,*/.hg/*,*/.svn/*,*/.idea/*,*/.DS_Store,*/vendor,*/node_modules/*,*/tmp/*

let g:ctrlp_custom_ignore = 'node_modules\|DS_Store\|git\|tmp'
