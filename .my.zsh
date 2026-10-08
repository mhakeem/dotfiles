# Load plugins
z4h load   $ZSH_CUSTOM/plugins/mise
z4h load   $ZSH_CUSTOM/plugins/git-open
z4h load   $ZSH_CUSTOM/plugins/you-should-use

### START My aliases
alias cl=clear

# git aliases
alias gb='git branch'
alias gba='git branch -a'
alias gco='git checkout'
alias gcob='git checkout -b'
alias gst='git status'
alias gpl='git pull'
alias gps='git push'
alias gca='git commit -am'
alias gdf='git diff'
alias glog='git log --oneline --graph --decorate'
alias glogs='git log --stat --graph'
alias glogp='git log -p --graph'

alias mux='tmuxinator'

alias nvplg='nvim +PlugInstall +UpdateRemotePlugins +qa'

alias doco="docker compose"

alias lls="eza --icons"
alias ls='eza -lh --group-directories-first --icons=auto'
alias lsa='ls -a'
alias lt='eza --tree --level=2 --long --icons --git'
alias lta='lt -a'
# fd-find (Debian/Ubuntu package name) vs fd (native name on macOS + Fedora)
if command -v fdfind >/dev/null 2>&1; then
  alias fd='fdfind'
elif command -v fd >/dev/null 2>&1; then
  alias fd='fd'
fi
# batcat (Debian/Ubuntu) vs bat (native name on macOS + Fedora)
if command -v batcat >/dev/null 2>&1; then
  alias ff="fzf --preview 'batcat --style=numbers --color=always {}'"
elif command -v bat >/dev/null 2>&1; then
  alias ff="fzf --preview 'bat --style=numbers --color=always {}'"
fi