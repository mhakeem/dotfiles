" Plugins must be on the first line
source $HOME/.config/nvim/vim-plug/plugins.vim
" general and plugins settings
source $HOME/.config/nvim/settings/general.vim
source $HOME/.config/nvim/settings/nerdtree.vim
source $HOME/.config/nvim/settings/airline.vim
" LanguageClient-neovim config
source $HOME/.config/nvim/settings/language-client.vim
" deoplete won't work w/o language-client
source $HOME/.config/nvim/settings/deoplete.vim

" #### Other settings 

" Key mappings for tabs
nnoremap tn :tabnew<Space>
nnoremap tk :tabnext<CR>  " default is gt
nnoremap tj :tabprev<CR>  " default is gT
nnoremap th :tabfirst<CR>
nnoremap tl :tablast<CR>

" Some helpers to edit mode
" http://vimcasts.org/e/14
nmap <leader>ew :e <C-R>=expand('%:h').'/'<cr>
nmap <leader>es :sp <C-R>=expand('%:h').'/'<cr>
nmap <leader>ev :vsp <C-R>=expand('%:h').'/'<cr>
nmap <leader>et :tabe <C-R>=expand('%:h').'/'<cr>

" Better nav for omnicomplete
inoremap <expr> <c-j> ("\<C-n>")
inoremap <expr> <c-k> ("\<C-p>")

" Use alt + hjkl to resize windows
nnoremap <M-j>    :resize -2<CR>
nnoremap <M-k>    :resize +2<CR>
nnoremap <M-h>    :vertical resize -2<CR>
nnoremap <M-l>    :vertical resize +2<CR>

" I hate escape more than anything else
inoremap jk <Esc>
inoremap kj <Esc>

" Better tabbing
vnoremap < <gv
vnoremap > >gv

" Better window navigation
nnoremap <C-h> <C-w>h
nnoremap <C-j> <C-w>j
nnoremap <C-k> <C-w>k
nnoremap <C-l> <C-w>l


" Create the `tags` file (may need to install ctags first)
" This'll allow to jump through tags in a file eg. finding class definitions
" How to use after running ctags:
" - ctrl+] to jump to tag undre cursor
" - g+ctrl+] for ambiguous tags
" - ctrl+t to jump back up the tag stack
" command! MakeTags !ctags -R .
command! MakeTags !ctags -R --exclude=.git --exclude=node_modules --exclude=test

" let g:SuperTabDefaultCompletionType = "<C-X><C-O>"
" let g:SuperTabDefaultCompletionType = "context"

" vim indent guides
" set ts=4 sw=4 et
let g:indent_guides_enable_on_vim_startup = 1
let g:indent_guides_start_level=2
let g:indent_guides_guide_size=1


" Emmet config
let g:user_emmet_install_global = 0
autocmd FileType html,css,eruby,erb EmmetInstall " only html/css files
" let g:user_emmet_leader_key='<C-Z>'


" TagBar Config
nmap <F8> :TagbarToggle<CR>

" for Ruby
autocmd FileType ruby setlocal expandtab shiftwidth=2 tabstop=2
autocmd FileType eruby setlocal expandtab shiftwidth=2 tabstop=2

" For Snipmate
let g:snipMate = { 'snippet_version': 1 }


