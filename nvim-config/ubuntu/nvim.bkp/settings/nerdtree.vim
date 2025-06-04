
" NERDTree config
" source /home/mhakeem/.local/lib/python3.9/site-packages/powerline/bindings/vim/plugin/powerline.     vim
nnoremap <leader>n :NERDTreeFocus<CR>
nnoremap <C-n> :NERDTree<CR>
nnoremap <C-t> :NERDTreeToggle<CR>
nnoremap <C-f> :NERDTreeFind<CR>

" Start NERDTree when Vim is started without file arguments.
autocmd StdinReadPre * let s:std_in=1
autocmd VimEnter * if argc() == 0 && !exists('s:std_in') | NERDTree | endif

" Exit Vim if NERDTree is the only window left.
autocmd BufEnter * if tabpagenr('$') == 1 && winnr('$') == 1 && exists('b:NERDTree') && b:NERDTree.isTabTree() |
    \ quit | endif

" Close NERDTree after opening a file
" let NERDTreeQuitOnOpen=1

" Automatically delete the buffer of the file you just deleted w/ NERDTree
let NERDTreeAutoDeleteBuffer=1

" let NERDTreeMinimalUI=1
" let NERDTreeDirArrow=1

let g:NERDTreeGitStatusUseNerdFonts = 1 " you should install nerdfonts by yourself. default: 0

