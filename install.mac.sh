#!/bin/bash
# =============================================================================
# install.mac.sh — Interactive setup for macOS (Apple Silicon + Intel)
# Usage:     bash install.mac.sh
#
# Companion to install.sh (Ubuntu + Fedora). Same architecture: ITEM REGISTRY
# drives the tree UI, dispatch, detection, logging, and timeouts.
# Gaming stack is intentionally out of scope on macOS.
#
# NOTES:
#   - Targets stock macOS /bin/bash 3.2 — NO bash 4+ features allowed:
#     no associative arrays, no mapfile, no ${VAR^}, integer-only `read -t`,
#     no `&>`, no `sed -i`, no `readlink -f`, no `sort -V`, no wget (use curl).
#   - Dotfiles (.my.zsh, .tmux.conf, alacritty.toml, config.ghostty) must sit
#     beside this script (referenced via $SCRIPT_DIR).
#   - Log file: ~/setup-mac.log
#   - Re-running is safe — all installs are idempotent
#   - Failures are non-fatal: collected and shown in a summary at the end
#   - Homebrew is NEVER run under sudo (brew refuses; a stray sudo can
#     root-own the brew prefix). Only /etc/pam.d edits use sudo.
#   - `xcode-select --install` pops a GUI dialog — that step needs one manual
#     click and the script exits so you can re-run afterwards.
#
# DEBUGGING:
#   Last run failures:
#     awk '/RUN STARTED/{buf=""} {buf=buf"\n"$0} END{print buf}' ~/setup-mac.log \
#       | grep -E "FAILED|TIMEOUT|WARNING"
#   Watch live:
#     tail -f ~/setup-mac.log
#   Test a single function (WARNING: runs the real install):
#     bash -c 'SCRIPT_DIR="$PWD"; LOG_FILE=~/setup-mac.log; source ./install.mac.sh --source-only; install_brave'
#   Override step timeout (default 300s):
#     STEP_TIMEOUT_SECS=600 bash install.mac.sh
# =============================================================================
set -uo pipefail   # intentionally no -e; errors handled per-step via run_step()

# Sourcable for single-function testing: `source install.mac.sh --source-only`
if [[ "${1:-}" == "--source-only" ]]; then
  _MAC_SOURCE_ONLY=1
else
  _MAC_SOURCE_ONLY=0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Globals
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Export so subshells used by run_step() inherit the correct value
export SCRIPT_DIR
LOG_FILE="$HOME/setup-mac.log"
ERRORS=()

# Platform info — populated by detect_mac()
MACOS_VER=""   # e.g. "15.6.1" or "26.0"
ARCH=""        # "arm64" | "x86_64"
BREW_BIN=""    # full path to brew once known

# ─────────────────────────────────────────────────────────────────────────────
# Platform detection
# ─────────────────────────────────────────────────────────────────────────────
detect_mac() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: install.mac.sh targets macOS only (detected: $(uname -s))."
    echo "       Use install.sh for Ubuntu / Fedora."
    exit 1
  fi
  MACOS_VER="$(sw_vers -productVersion 2>/dev/null || echo "unknown")"
  ARCH="$(uname -m 2>/dev/null || echo "unknown")"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

# Timestamped log line — written to log file only (no stdout during spinner)
log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }

# Timestamped log + stdout — used outside run_step() where no spinner is active
logecho() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# True if a Homebrew formula is installed
brew_installed() { brew list --formula "$1" >/dev/null 2>&1; }

# True if a Homebrew cask is installed
cask_installed() { brew list --cask "$1" >/dev/null 2>&1; }

# True if a GUI app bundle exists in /Applications
app_exists() { [[ -d "/Applications/$1.app" ]]; }

# True if a font family has files in ~/Library/Fonts (substring, case-insensitive)
font_installed() { ls ~/Library/Fonts 2>/dev/null | grep -qi "$1"; }

# ── Homebrew wrappers ─────────────────────────────────────────────────────────
# Idempotent: skip silently-logged when already present. Never use sudo here —
# brew refuses to run as root. Soft-fail (log WARNING) so one bad package
# never fails the whole step.

brew_install() {
  local p
  for p in "$@"; do
    if brew_installed "$p"; then
      log "  $p already installed — skipping."
      continue
    fi
    brew install "$p" || log "  WARNING: brew install failed: $p"
  done
}

brew_cask() {
  local c
  for c in "$@"; do
    if cask_installed "$c"; then
      log "  cask $c already installed — skipping."
      continue
    fi
    brew install --cask "$c" || log "  WARNING: cask install failed: $c"
  done
}

brew_remove() {
  local p
  for p in "$@"; do
    brew uninstall "$p" >/dev/null 2>&1 || true
  done
}

brew_cask_remove() {
  local c
  for c in "$@"; do
    # Plain uninstall (never --zap: that deletes user data, which remove_*
    # functions must preserve).
    brew uninstall --cask "$c" >/dev/null 2>&1 || true
  done
}

# ── Spinner ───────────────────────────────────────────────────────────────────
SPINNER_PID=""
SPINNER_FRAMES='|/-\'
# SPINNER_FRAMES as a plain string (indexed ${arr[i]} arrays are fine in 3.2,
# but a string avoids any empty-array edge cases under `set -u`).

start_spinner() {
  local label="$1"
  local start_ts=$SECONDS
  (
    local i=0
    while true; do
      local elapsed=$(( SECONDS - start_ts ))
      local frame
      frame=$(printf '%s' "$SPINNER_FRAMES" | cut -c $(( i % 4 + 1 )))
      printf "\r  %s  %-50s  %02d:%02d" \
        "$frame" "$label" "$(( elapsed/60 ))" "$(( elapsed%60 ))"
      i=$(( i+1 )); sleep 0.1
    done
  ) &
  SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null || true
}

stop_spinner() {
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf "\r%*s\r" "$(tput cols 2>/dev/null || echo 80)" ""
  fi
}

# ── Step runner ───────────────────────────────────────────────────────────────
# run_step    → background subshell with spinner; inherits all functions
# run_step_fg → foreground; required for interactive steps (prompts, z4h)
# NOTE: background steps have no TTY — never prompt for input inside a bg
# step. Interactive items must be registered with --fg.
STEP_TIMEOUT_SECS="${STEP_TIMEOUT_SECS:-300}"

_run_step_impl() {
  local mode="$1" label="$2"; shift 2
  local func="$1"; shift

  local start_ts=$SECONDS
  echo ""
  logecho "▶ START: $label"
  start_spinner "$label"

  local exit_code=0 bg_pid=""

  _step_abort() {
    stop_spinner
    if [[ -n "$bg_pid" ]]; then
      kill -TERM "-${bg_pid}" 2>/dev/null || kill -TERM "$bg_pid" 2>/dev/null || true
      wait "$bg_pid" 2>/dev/null || true
    fi
    logecho "⚡ INTERRUPTED: $label"
    ERRORS+=("$label (interrupted)")
    trap - INT TERM
    kill -INT "$$"
  }
  trap '_step_abort' INT TERM

  if [[ "$mode" == "bg" ]]; then
    # Plain subshell — inherits all shell functions from parent (unlike setsid)
    ( "$func" "$@" ) >> "$LOG_FILE" 2>&1 &
    bg_pid=$!

    local timeout_secs="${STEP_TIMEOUT_SECS:-300}"
    ( sleep "$timeout_secs"
      if kill -0 "$bg_pid" 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] TIMEOUT: $label exceeded ${timeout_secs}s" >> "$LOG_FILE"
        kill -TERM "$bg_pid" 2>/dev/null || true
      fi
    ) &
    local watchdog_pid=$!

    wait "$bg_pid"; exit_code=$?
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  else
    # Foreground — stop spinner first so interactive UIs get a clean terminal.
    # No stdout/stderr redirection — prompts need a real TTY for both.
    # Output goes to terminal only, not the log.
    stop_spinner
    "$func" "$@"; exit_code=$?
  fi

  trap - INT TERM
  stop_spinner

  local elapsed=$(( SECONDS - start_ts ))
  local mins=$(( elapsed/60 )) secs=$(( elapsed%60 ))

  if   [[ $exit_code -eq 0 ]];               then logecho "✓ DONE:    $label  (${mins}m ${secs}s)"
  elif [[ $exit_code -eq 124 || $exit_code -eq 143 ]]; then
    logecho "✗ TIMEOUT: $label  (${mins}m ${secs}s)"; ERRORS+=("$label (timed out)")
  else
    logecho "✗ FAILED:  $label  (${mins}m ${secs}s, exit $exit_code)"
    logecho "  → Check $LOG_FILE for details"
    ERRORS+=("$label")
  fi
}

run_step()    { _run_step_impl "bg" "$@"; }
run_step_fg() { _run_step_impl "fg" "$@"; }

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight — Homebrew + CLT foundation (runs in foreground, may prompt)
# ─────────────────────────────────────────────────────────────────────────────
ensure_brew_on_path() {
  if cmd_exists brew; then
    BREW_BIN="$(command -v brew)"
    return 0
  fi
  # Fresh machine: brew installed but shellenv never evaluated
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  if cmd_exists brew; then
    BREW_BIN="$(command -v brew)"
    return 0
  fi
  return 1
}

preflight_mac() {
  logecho "macOS $MACOS_VER ($ARCH) — setup starting"
  logecho "Log: $LOG_FILE"

  if [[ $EUID -eq 0 ]]; then
    logecho "ERROR: Do not run install.mac.sh as root — Homebrew refuses root."
    exit 1
  fi

  # ── Xcode Command Line Tools ──────────────────────────────────────────────
  # xcode-select --install pops a GUI dialog with one manual click, so we stop
  # here and ask for a re-run rather than hanging the script.
  if ! xcode-select -p >/dev/null 2>&1; then
    logecho "Xcode Command Line Tools not found — requesting install."
    logecho "A system dialog will appear: click Install, accept the license,"
    logecho "wait for it to finish, then re-run:  bash install.mac.sh"
    xcode-select --install 2>/dev/null || true
    exit 1
  fi
  log "  CLT present: $(xcode-select -p)"

  # ── Homebrew ────────────────────────────────────────────────────────────
  # Official installer MUST run under bash (not zsh) — /bin/bash is explicit.
  if ! ensure_brew_on_path; then
    logecho "Homebrew not found — installing (needs your password + one RETURN)."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      || { logecho "ERROR: Homebrew install failed."; exit 1; }
    ensure_brew_on_path || { logecho "ERROR: brew still not on PATH."; exit 1; }
  fi
  log "  brew: $BREW_BIN"
  brew update >/dev/null 2>&1 || log "  WARNING: brew update failed — continuing"

  # Cache sudo credentials once so background cask installs that need a
  # privileged helper don't hang waiting for a password with no TTY.
  sudo -v 2>/dev/null || true
}

# =============================================================================
# INSTALL FUNCTIONS
# =============================================================================

install_mise() {
  curl -fsSL https://mise.run | sh
  local mise_bin="$HOME/.local/bin/mise"
  if [[ ! -x "$mise_bin" ]]; then
    log "  WARNING: mise binary not found after install"; return 1
  fi
  export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
  "$mise_bin" use --global python@latest
  "$mise_bin" use --global node@lts
  "$mise_bin" use --global ruby@latest
  "$mise_bin" settings add idiomatic_version_file_enable_tools ruby,node
  local rc
  for rc in ~/.zshrc ~/.bashrc; do
    if [[ -f "$rc" ]] && ! grep -q 'mise activate' "$rc"; then
      echo 'eval "$(~/.local/bin/mise activate $(basename $SHELL))"' >> "$rc"
    fi
  done
  "$mise_bin" exec -- npm install -g tree-sitter-cli 2>/dev/null || true
  log "  mise installed. Python, Node, and Ruby available."
}

remove_mise() {
  rm -rf ~/.local/share/mise ~/.local/bin/mise ~/.config/mise ~/.cache/mise 2>/dev/null || true
  # No `sed -i` (BSD sed needs an argument) — rewrite via temp file instead.
  local rc tmpf
  for rc in ~/.zshrc ~/.bashrc; do
    if [[ -f "$rc" ]]; then
      tmpf=$(mktemp /tmp/mise-rm-XXXXXX)
      grep -v 'mise activate' "$rc" > "$tmpf" 2>/dev/null || true
      command cp "$tmpf" "$rc" || true
      rm -f "$tmpf"
    fi
  done
  log "  mise removed."
}

install_fastfetch() {
  brew_install fastfetch
}

remove_fastfetch() {
  brew_remove fastfetch || true
  log "  Fastfetch removed."
}

configure_git() {
  git config --global init.defaultBranch main
  git config --global alias.gh 'config user.email "mhakeem@users.noreply.github.com"'
  git config --global user.name "mhakeem"
}

remove_git_config() {
  git config --global --unset user.name 2>/dev/null || true
  git config --global --unset alias.gh 2>/dev/null || true
  git config --global --unset init.defaultBranch 2>/dev/null || true
  log "  Git global config cleared."
}

# ── macOS tweaks ──────────────────────────────────────────────────────────────
# Individually selectable via a numbered prompt (no whiptail on macOS).
# Keep-list agreed: extensions, hidden files (default OFF), Finder bars,
# minimize-to-app, mru-spaces, screenshots, Touch ID for sudo (opt-in).
TWEAK_LABELS=(
  "Finder: show all filename extensions"
  "Finder: show hidden files (can be noisy)"
  "Finder: show status bar + path bar"
  "Dock: minimize windows into app icon"
  "Dock: don't rearrange Spaces by recent use"
  "Screenshots: save PNGs to ~/Pictures/Screenshots"
  "Touch ID for sudo (writes /etc/pam.d/sudo_local)"
)
# Defaults aligned with TWEAK_LABELS (1 = selected by default)
TWEAK_DEFAULTS=(1 0 1 1 1 1 0)

tweak_extensions() {
  defaults write NSGlobalDomain AppleShowAllExtensions -bool true
  log "  Extensions shown."
}

tweak_hidden() {
  defaults write com.apple.finder AppleShowAllFiles -bool true
  log "  Hidden files shown."
}

tweak_finderbar() {
  defaults write com.apple.finder ShowStatusBar -bool true
  defaults write com.apple.finder ShowPathbar -bool true
  log "  Finder status + path bar shown."
}

tweak_mindock() {
  defaults write com.apple.dock minimize-to-application -bool true
  log "  Minimize-to-app-icon enabled."
}

tweak_spaces() {
  defaults write com.apple.dock mru-spaces -bool false
  log "  Spaces order pinned (mru-spaces off)."
}

tweak_shots() {
  mkdir -p ~/Pictures/Screenshots
  defaults write com.apple.screencapture location -string "$HOME/Pictures/Screenshots"
  defaults write com.apple.screencapture type -string "png"
  log "  Screenshots → ~/Pictures/Screenshots (PNG)."
}

tweak_touchid() {
  # Update-safe method (Sonoma+): /etc/pam.d/sudo_local survives OS updates,
  # unlike /etc/pam.d/sudo. Ref: Apple sudo_local.template.
  if grep -q 'pam_tid\.so' /etc/pam.d/sudo_local 2>/dev/null; then
    log "  Touch ID for sudo already enabled."
    return 0
  fi
  if [[ ! -f /etc/pam.d/sudo_local ]] && [[ -f /etc/pam.d/sudo_local.template ]]; then
    sed -e 's/^#auth/auth/' /etc/pam.d/sudo_local.template \
      | sudo tee /etc/pam.d/sudo_local >/dev/null \
      || { log "  WARNING: could not write /etc/pam.d/sudo_local"; return 1; }
  elif [[ -f /etc/pam.d/sudo_local ]]; then
    echo "auth       sufficient     pam_tid.so" \
      | sudo tee -a /etc/pam.d/sudo_local >/dev/null \
      || { log "  WARNING: could not update /etc/pam.d/sudo_local"; return 1; }
  else
    log "  WARNING: no sudo_local.template (macOS older than Sonoma?) — skipping Touch ID."
    return 1
  fi
  log "  Touch ID for sudo enabled (takes effect in new terminal sessions)."
}

install_mac_tweaks() {
  echo ""
  echo "  macOS tweaks — SPACE-separated numbers, ENTER = defaults, n = none:"
  local i=0
  while [[ $i -lt ${#TWEAK_LABELS[@]} ]]; do
    local n=$(( i + 1 )) mark="[ ]"
    [[ "${TWEAK_DEFAULTS[$i]}" == "1" ]] && mark="[x]"
    echo "    $n) $mark ${TWEAK_LABELS[$i]}"
    i=$(( i + 1 ))
  done
  local sel
  read -p "  Select: " sel </dev/tty
  [[ "$sel" == "n" || "$sel" == "N" ]] && { log "  No tweaks selected."; return 0; }

  local applied=0 n
  n=1
  while [[ $n -le ${#TWEAK_LABELS[@]} ]]; do
    local want=0
    if [[ -z "$sel" ]]; then
      [[ "${TWEAK_DEFAULTS[$(( n - 1 ))]}" == "1" ]] && want=1
    else
      case " $sel " in *" $n "*) want=1 ;; esac
    fi
    if [[ $want == 1 ]]; then
      case $n in
        1) tweak_extensions ;;
        2) tweak_hidden ;;
        3) tweak_finderbar ;;
        4) tweak_mindock ;;
        5) tweak_spaces ;;
        6) tweak_shots ;;
        7) tweak_touchid ;;
      esac
      applied=1
    fi
    n=$(( n + 1 ))
  done

  if [[ $applied == 1 ]]; then
    killall Dock >/dev/null 2>&1 || true
    killall Finder >/dev/null 2>&1 || true
    killall SystemUIServer >/dev/null 2>&1 || true
    log "  Tweaks applied (Dock/Finder restarted)."
  else
    log "  No tweaks selected."
  fi
}

remove_mac_tweaks() {
  defaults delete NSGlobalDomain AppleShowAllExtensions 2>/dev/null || true
  defaults delete com.apple.finder AppleShowAllFiles 2>/dev/null || true
  defaults delete com.apple.finder ShowStatusBar 2>/dev/null || true
  defaults delete com.apple.finder ShowPathbar 2>/dev/null || true
  defaults delete com.apple.dock minimize-to-application 2>/dev/null || true
  defaults delete com.apple.dock mru-spaces 2>/dev/null || true
  defaults delete com.apple.screencapture location 2>/dev/null || true
  defaults delete com.apple.screencapture type 2>/dev/null || true
  # Only remove sudo_local if it contains nothing but our Touch ID line —
  # never touch a file the user (or MDM) customized further.
  if [[ -f /etc/pam.d/sudo_local ]]; then
    local rest
    rest=$(grep -v '^[[:space:]]*#' /etc/pam.d/sudo_local | grep -v '^[[:space:]]*$' || true)
    if [[ "$rest" == "auth       sufficient     pam_tid.so" ]]; then
      sudo rm -f /etc/pam.d/sudo_local 2>/dev/null || true
    else
      log "  NOTE: /etc/pam.d/sudo_local has other content — left in place."
    fi
  fi
  killall Dock >/dev/null 2>&1 || true
  killall Finder >/dev/null 2>&1 || true
  log "  macOS tweaks removed."
}

# ── Terminal tools ────────────────────────────────────────────────────────────
install_terminal_tools() {
  # fzf, ripgrep, bat, eza, zoxide, btop, fd, tldr — each idempotent via wrapper
  brew_install fzf ripgrep bat eza zoxide btop fd tldr
  log "  NOTE: fzf key bindings are opt-in — run: $(brew --prefix)/opt/fzf/install"
}

remove_terminal_tools() {
  brew_remove fzf ripgrep bat eza zoxide btop fd tldr || true
  log "  Terminal tools removed."
}

install_alacritty() {
  brew_cask alacritty
  # Theme collection
  mkdir -p ~/.config/alacritty/themes
  if [[ -d ~/.config/alacritty/themes/.git ]]; then
    git -C ~/.config/alacritty/themes pull 2>/dev/null || true
  else
    git clone --depth=1 https://github.com/alacritty/alacritty-theme \
      ~/.config/alacritty/themes 2>/dev/null || true
  fi
  if [[ -f "$SCRIPT_DIR/alacritty.toml" ]]; then
    cp "$SCRIPT_DIR/alacritty.toml" ~/.config/alacritty/
  fi
}

remove_alacritty() {
  brew_cask_remove alacritty || true
  rm -rf ~/.config/alacritty 2>/dev/null || true
  log "  Alacritty removed."
}

install_iterm2() {
  brew_cask iterm2
  # Community theme collection (450+ schemes). Sparse checkout keeps it small —
  # only schemes/, no screenshots. Import manually:
  # iTerm2 → Settings → Profiles → Colors → Color Presets → Import.
  local dest=~/.config/iterm2/schemes
  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" pull 2>/dev/null || true
  else
    mkdir -p ~/.config/iterm2
    if git clone --depth=1 --filter=blob:none --sparse \
        https://github.com/mbadolato/iTerm2-Color-Schemes.git "$dest" 2>/dev/null; then
      (cd "$dest" && git sparse-checkout set schemes 2>/dev/null) || true
    else
      git clone --depth=1 https://github.com/mbadolato/iTerm2-Color-Schemes.git \
        "$dest" 2>/dev/null || log "  WARNING: Could not clone iTerm2 themes"
    fi
  fi
  log "  iTerm2 installed. Import themes: Settings → Profiles → Colors → Color Presets → Import"
  log "  Schemes live at: $dest/schemes/*.itermcolors"
}

remove_iterm2() {
  brew_cask_remove iterm2 || true
  rm -rf ~/.config/iterm2 2>/dev/null || true
  log "  iTerm2 removed."
}

install_ghostty() {
  brew_cask ghostty
  # Same XDG path as Linux — Ghostty honors it on macOS too.
  # (Native dir ~/Library/Application Support/com.mitchellh.ghostty/ also works
  # but XDG keeps one rule for both OSes.)
  mkdir -p ~/.config/ghostty
  if [[ -f "$SCRIPT_DIR/config.ghostty" ]]; then
    cp "$SCRIPT_DIR/config.ghostty" ~/.config/ghostty/config.ghostty
  else
    log "  WARNING: config.ghostty not found beside script."
  fi
}

remove_ghostty() {
  brew_cask_remove ghostty || true
  rm -rf ~/.config/ghostty 2>/dev/null || true
  log "  Ghostty removed."
}

install_zellij() {
  brew_install zellij
}

remove_zellij() {
  brew_remove zellij || true
  rm -rf ~/.config/zellij 2>/dev/null || true
  log "  Zellij removed."
}

install_tmux() {
  brew_install tmux yq
  if [[ ! -d ~/.tmux/plugins/tpm ]]; then
    git clone --depth=1 https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
  fi
  [[ -f "$SCRIPT_DIR/.tmux.conf" ]] && cp "$SCRIPT_DIR/.tmux.conf" ~/
}

remove_tmux() {
  brew_remove tmux || true
  rm -rf ~/.tmux ~/.tmux.conf 2>/dev/null || true
  log "  tmux and TPM removed."
}

install_lazygit() {
  brew_install lazygit
  mkdir -p ~/.config/lazygit && touch ~/.config/lazygit/config.yml
}

remove_lazygit() {
  brew_remove lazygit || true
  rm -rf ~/.config/lazygit 2>/dev/null || true
  log "  LazyGit removed."
}

install_dotfiles() {
  # Resolve script directory — SCRIPT_DIR may be empty if the subshell lost it
  local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)}"
  log "  Looking for dotfiles in: $script_dir"
  local missing=()
  if [[ -f "$script_dir/.my.zsh" ]]; then
    cp "$script_dir/.my.zsh" ~/
    # Copy-only: sourcing into .zshrc is owned by install_zsh (post-wizard).
    # This step runs before zsh in dispatch order, when z4h doesn't exist yet,
    # so an append here would silently never happen.
  else missing+=(".my.zsh"); fi
  if [[ -f "$script_dir/.tmux.conf" ]]; then
    cp "$script_dir/.tmux.conf" ~/
  else missing+=(".tmux.conf"); fi
  if [[ -f "$script_dir/alacritty.toml" ]]; then
    mkdir -p ~/.config/alacritty && cp "$script_dir/alacritty.toml" ~/.config/alacritty/
  else missing+=("alacritty.toml"); fi
  if [[ -f "$script_dir/config.ghostty" ]]; then
    mkdir -p ~/.config/ghostty && cp "$script_dir/config.ghostty" ~/.config/ghostty/config.ghostty
  else missing+=("config.ghostty"); fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "  WARNING: Dotfiles not found beside script: ${missing[*]}"
    log "  Expected: $script_dir/{.my.zsh,.tmux.conf,alacritty.toml,config.ghostty}"
    return 1
  fi
}

remove_dotfiles() {
  rm -f ~/.my.zsh ~/.tmux.conf ~/.config/alacritty/alacritty.toml \
    ~/.config/ghostty/config.ghostty 2>/dev/null || true
  if [[ -f ~/.zshrc ]]; then
    local tmpf; tmpf=$(mktemp /tmp/dotfiles-rm-XXXXXX)
    grep -v 'z4h source ~/\.my\.zsh' ~/.zshrc > "$tmpf" 2>/dev/null || true
    command cp "$tmpf" ~/.zshrc || true
    rm -f "$tmpf"
  fi
  log "  Dotfiles removed."
}

# ── Fonts ─────────────────────────────────────────────────────────────────────
install_mac_font_zip() {
  # Direct-download helper for fonts with no Homebrew cask (iA Writer).
  # Usage: install_mac_font_zip <display_name> <zip_url> <file_glob>
  local font_name="$1" url="$2" glob="$3"
  if font_installed "$font_name"; then
    log "  Font already installed: $font_name"; return 0
  fi
  local tmp; tmp=$(mktemp -d /tmp/setup-XXXXXX)
  if curl -fsSL --connect-timeout 15 --max-time 120 -o "$tmp/font.zip" "$url" \
      && unzip -q -o "$tmp/font.zip" -d "$tmp/font" 2>/dev/null; then
    # shellcheck disable=SC2086
    find "$tmp/font" -name "$glob" -exec cp {} ~/Library/Fonts/ \; 2>/dev/null || true
  else
    log "  WARNING: Could not download font: $font_name"
  fi
  rm -rf "$tmp"
}

install_fonts() {
  mkdir -p ~/Library/Fonts
  # 0xProto Nerd Font Mono + MesloLGS Nerd Font via official casks
  brew_cask font-0xproto-nerd-font
  brew_cask font-meslo-lg-nerd-font
  # iA Writer Mono — served from master branch (no versioned releases)
  install_mac_font_zip "iAWriterMonoS" \
    "https://github.com/iaolo/iA-Fonts/archive/refs/heads/master.zip" \
    "iAWriterMonoS-*.ttf"
  # Monaspace — cloned over HTTPS so no GitHub key setup is needed
  if font_installed "Monaspace"; then
    log "  Font already installed: Monaspace"
  else
    local tmp2; tmp2=$(mktemp -d /tmp/setup-XXXXXX)
    if git clone --depth=1 https://github.com/githubnext/monaspace.git \
        "$tmp2/monaspace" 2>/dev/null; then
      mkdir -p ~/Library/Fonts/Monaspace
      find "$tmp2/monaspace/fonts" \( -name "*.otf" -o -name "*.ttf" \) \
        -exec cp {} ~/Library/Fonts/Monaspace/ \; 2>/dev/null || true
    else
      log "  WARNING: Could not clone Monaspace"
    fi
    rm -rf "$tmp2"
  fi
  log "  Fonts installed (macOS activates ~/Library/Fonts automatically)."
}

remove_fonts() {
  brew_cask_remove font-0xproto-nerd-font font-meslo-lg-nerd-font || true
  rm -rf ~/Library/Fonts/Monaspace 2>/dev/null || true
  find ~/Library/Fonts -maxdepth 1 \( -iname "0xProto*" -o -iname "MesloLGS*" \
    -o -iname "MesloLGMDZ*" -o -iname "iAWriterMono*" \) \
    -delete 2>/dev/null || true
  log "  Fonts removed."
}

# ── Editors ───────────────────────────────────────────────────────────────────
install_neovim() {
  brew_install neovim luarocks
  if cmd_exists npm; then
    npm install -g tree-sitter-cli || true
  else
    log "  NOTE: tree-sitter-cli needs Node — select 'mise' too, or run later:"
    log "        npm install -g tree-sitter-cli"
  fi
  if [[ ! -d ~/.config/nvim ]]; then
    git clone https://github.com/LazyVim/starter ~/.config/nvim
    rm -rf ~/.config/nvim/.git
  else
    log "  ~/.config/nvim already exists — skipping LazyVim clone"
  fi
}

remove_neovim() {
  brew_remove neovim luarocks || true
  rm -rf ~/.config/nvim ~/.local/share/nvim ~/.cache/nvim 2>/dev/null || true
  log "  Neovim removed."
}

install_zed() {
  brew_cask zed
}

remove_zed() {
  brew_cask_remove zed || true
  # Config preserved deliberately — same approach as other editors
  log "  Zed removed. Config preserved at ~/.config/zed/"
}

install_vscode() {
  brew_cask visual-studio-code
}

remove_vscode() {
  brew_cask_remove visual-studio-code || true
  log "  VS Code removed."
}

install_vscodium() {
  brew_cask vscodium
}

remove_vscodium() {
  brew_cask_remove vscodium || true
  log "  VSCodium removed."
}

install_sublime() {
  brew_cask sublime-text sublime-merge
}

remove_sublime() {
  brew_cask_remove sublime-text sublime-merge || true
  log "  Sublime removed."
}

# ── Browsers ──────────────────────────────────────────────────────────────────
install_brave() {
  brew_cask brave-browser
}

remove_brave() {
  brew_cask_remove brave-browser || true
  log "  Brave removed."
}

install_chrome() {
  brew_cask google-chrome
}

remove_chrome() {
  brew_cask_remove google-chrome || true
  log "  Chrome removed."
}

install_firefox_dev() {
  brew_cask firefox@developer-edition
}

remove_firefox_dev() {
  brew_cask_remove firefox@developer-edition || true
  log "  Firefox Dev removed."
}

install_edge() {
  brew_cask microsoft-edge
}

remove_edge() {
  brew_cask_remove microsoft-edge || true
  log "  Edge removed."
}

# ── Dev Tools ─────────────────────────────────────────────────────────────────
install_docker() {
  # Runs in foreground (--fg in registry) so the choice prompt has a real TTY.
  # Docker Desktop needs a paid subscription at large companies — OrbStack is
  # the license-safe alternative (Docker-compatible socket, same `docker` CLI).
  echo ""
  echo "  Docker provider:"
  echo "    1) Docker Desktop (official GUI app)"
  echo "    2) OrbStack (lightweight, Docker-compatible)"
  echo "    3) Both"
  local choice
  read -p "  Choose [1/2/3]: " choice </dev/tty
  case "$choice" in
    1) brew_cask docker-desktop ;;
    2) brew_cask orbstack ;;
    3) brew_cask docker-desktop orbstack ;;
    *) log "  No Docker provider selected — skipping." ;;
  esac
  log "  After install, verify with: docker ps"
}

remove_docker() {
  brew_cask_remove docker-desktop orbstack || true
  log "  Docker providers removed."
}

# ── Launchers ─────────────────────────────────────────────────────────────────
install_raycast() {
  brew_cask raycast
}

remove_raycast() {
  brew_cask_remove raycast || true
  log "  Raycast removed."
}

install_alfred() {
  brew_cask alfred
}

remove_alfred() {
  brew_cask_remove alfred || true
  log "  Alfred removed."
}

# ── Apps ──────────────────────────────────────────────────────────────────────
install_slack() {
  brew_cask slack
}

remove_slack() {
  brew_cask_remove slack || true
  log "  Slack removed."
}

install_spotify() {
  brew_cask spotify
}

remove_spotify() {
  brew_cask_remove spotify || true
  log "  Spotify removed."
}

install_zoom() {
  brew_cask zoom
}

remove_zoom() {
  brew_cask_remove zoom || true
  log "  Zoom removed."
}

install_obsidian() {
  brew_cask obsidian
}

remove_obsidian() {
  brew_cask_remove obsidian || true
  log "  Obsidian removed."
}

install_dropbox() {
  brew_cask dropbox
}

remove_dropbox() {
  brew_cask_remove dropbox || true
  log "  Dropbox removed."
}

install_1password() {
  brew_cask 1password
}

remove_1password() {
  brew_cask_remove 1password || true
  log "  1Password removed."
}

install_localsend() {
  brew_cask localsend
}

remove_localsend() {
  brew_cask_remove localsend || true
  log "  LocalSend removed."
}

# ── AI ────────────────────────────────────────────────────────────────────────
install_claude_code() {
  # Official cask — installs the `claude` CLI to $HOMEBREW_PREFIX/bin
  brew_cask claude-code
}

remove_claude_code() {
  brew_cask_remove claude-code || true
  log "  Claude Code removed."
}

install_claude_desktop() {
  # Anthropic's official desktop app (/Applications/Claude.app)
  brew_cask claude
}

remove_claude_desktop() {
  brew_cask_remove claude || true
  log "  Claude Desktop removed."
}

install_lmstudio() {
  brew_cask lm-studio
}

remove_lmstudio() {
  brew_cask_remove lm-studio || true
  log "  LM Studio removed."
}

install_chatbox() {
  brew_cask chatbox
}

remove_chatbox() {
  brew_cask_remove chatbox || true
  log "  Chatbox removed."
}

install_opencode() {
  # Official Homebrew core formula (stable; the anomalyco/tap variant tracks
  # upstream faster but adds a third-party tap — skipped for corporate safety).
  brew_install opencode
}

remove_opencode() {
  brew_remove opencode || true
  log "  opencode removed."
}

# Ensure ~/.my.zsh is sourced from ~/.zshrc via z4h. Called by install_zsh
# AFTER the wizard completes — never from install_dotfiles, which runs before
# zsh in dispatch order (when z4h doesn't exist yet). Mirrors install.sh.
# Note z4h is a zsh function, not a binary, so presence is checked via
# ~/.local/share/z4h — `command -v z4h` in bash would always fail.
ensure_myzsh_sourced() {
  if [[ ! -f ~/.my.zsh ]]; then
    log "  NOTE: ~/.my.zsh not present — select 'dotfiles' to copy it."
    return 0
  fi
  if [[ ! -d ~/.local/share/z4h ]]; then
    log "  NOTE: z4h not installed — open a new zsh, then re-run this step."
    return 0
  fi
  if [[ ! -f ~/.zshrc ]]; then
    log "  NOTE: ~/.zshrc not found — skipping source line."
    return 0
  fi
  if grep -qxF 'z4h source ~/.my.zsh' ~/.zshrc; then
    log "  ~/.my.zsh already sourced from ~/.zshrc."
  else
    echo 'z4h source ~/.my.zsh' >> ~/.zshrc
    log "  ~/.my.zsh now sourced from ~/.zshrc."
  fi
}

# ── Shell (registered last — see registry note) ───────────────────────────────
install_zsh() {
  # macOS already defaults to zsh — only fix it if something changed it.
  if [[ "${SHELL:-}" != */zsh ]]; then
    chsh -s /bin/zsh \
      || log "  WARNING: Could not change shell — run: chsh -s /bin/zsh"
  fi

  # Pre-flight: z4h clones from GitHub, and p10k wants MesloLGS NF present
  # before the wizard runs (font-blind wizard picks degraded glyphs).
  if ! command -v git >/dev/null 2>&1; then
    log "  WARNING: git not found — z4h needs it to clone. Install git first."
    return 1
  fi
  if ! font_installed "MesloLGS"; then
    log "  WARNING: MesloLGS NF not installed — p10k wizard may pick wrong glyphs."
    log "  Install fonts first, or re-run 'p10k configure' afterwards."
  fi

  # Idempotent: skip the interactive wizard when z4h already exists (matters
  # for update mode, which re-runs every selected installer).
  if [[ -d ~/.local/share/z4h ]]; then
    log "  zsh4humans already installed — skipping wizard."
    ensure_myzsh_sourced
    return 0
  fi

  # z4h replaces its own shell on completion, which would kill this script —
  # run it in a NEW terminal window and wait for a sentinel file.
  # Prefer the user's own terminal: iTerm2 is AppleScript-able
  # (`create window with default profile command`); Ghostty and Alacritty have
  # no scriptable "open window with command", so they fall through to
  # Terminal.app, which is always present on macOS.
  local z4h_url="https://raw.githubusercontent.com/romkatv/zsh4humans/v5/install"
  local sentinel="/tmp/z4h-done-mac"
  rm -f "$sentinel"
  local runner; runner=$(mktemp /tmp/z4h-run-XXXXXX)
  {
    echo '#!/bin/sh'
    echo '# Auto-generated by install.mac.sh — safe to delete.'
    echo "sh -c \"\$(curl -fsSL $z4h_url)\""
    echo "touch \"$sentinel\""
  } > "$runner"
  chmod +x "$runner"

  local opened=0 opener="Terminal"
  if cmd_exists osascript; then
    if [[ -d /Applications/iTerm.app ]]; then
      osascript -e 'tell application "iTerm2"' \
                -e "create window with default profile command \"$runner\"" \
                -e 'end tell' >/dev/null 2>&1 \
        && { opened=1; opener="iTerm2"; }
    fi
    if [[ $opened == 0 ]]; then
      osascript -e 'tell application "Terminal"' \
                -e "do script \"$runner\"" \
                -e 'end tell' >/dev/null 2>&1 && opened=1
    fi
  fi

  echo ""
  echo "  A new $opener window will open for the zsh4humans wizard."
  echo "  Complete the wizard in that window, then return here."
  echo ""

  if [[ $opened == 1 ]]; then
    echo "  Waiting for z4h wizard to complete..."
    echo "  (Complete the wizard in the new window; it signals back automatically)"
    local waited=0
    while [[ ! -f "$sentinel" && $waited -lt 1800 ]]; do
      sleep 5
      waited=$(( waited + 5 ))
    done
    if [[ ! -f "$sentinel" ]]; then
      log "  WARNING: timed out waiting for z4h wizard (30 min)."
    fi
    rm -f "$runner" "$sentinel"
  else
    # No osascript — run inline. zsh is the LAST registry item, so even if
    # z4h replaces this shell, nothing else is left to run.
    echo "  WARNING: osascript unavailable — running z4h inline."
    rm -f "$runner" "$sentinel"
    sh -c "$(curl -fsSL "$z4h_url")" || true
  fi
  ensure_myzsh_sourced
}

remove_zsh() {
  # zsh is the macOS default shell — never remove the shell itself, only z4h.
  rm -rf ~/.config/zsh ~/.p10k.zsh ~/.zsh_history \
    ~/.local/share/z4h ~/.cache/zsh 2>/dev/null || true
  log "  zsh4humans data removed. System zsh left intact."
}

# =============================================================================
# ITEM REGISTRY (bash 3.2-safe: parallel indexed arrays, no associative arrays)
# Add/remove/move apps here. Everything else (UI, dispatch, detection) is
# derived automatically.
# =============================================================================

_REG_KEYS=()
_REG_CAT=()
_REG_LABEL=()
_REG_DEF=()
_REG_DET=()
_REG_INST=()
_REG_REM=()
_REG_FG=()

register_item() {
  local key="" cat="" label="" default="OFF" detect="false"
  local install_fn="" remove_fn="" fg="0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --key)     key="$2";        shift 2 ;;
      --cat)     cat="$2";        shift 2 ;;
      --label)   label="$2";      shift 2 ;;
      --default) default="$2";    shift 2 ;;
      --detect)  detect="$2";     shift 2 ;;
      --install) install_fn="$2"; shift 2 ;;
      --remove)  remove_fn="$2";  shift 2 ;;
      --fg)      fg="1";          shift   ;;
      *)         shift ;;
    esac
  done
  _REG_KEYS+=("$key")
  _REG_CAT+=("$cat")
  _REG_LABEL+=("$label")
  _REG_DEF+=("$default")
  _REG_DET+=("$detect")
  _REG_INST+=("$install_fn")
  _REG_REM+=("$remove_fn")
  _REG_FG+=("$fg")
}

# Category keys + display labels (order = UI order)
_CAT_KEYS=("system" "terminal" "editors" "browsers" "devtools" "launchers" "apps" "ai")
_CAT_LABELS=("System" "Terminal" "Editors" "Browsers" "Dev Tools" "Launchers" "Apps" "AI & Local LLMs")

# ── System ─────────────────────────────────────────────────────────────────────
register_item --key mise --cat system --fg \
  --label "Mise + Python / Node LTS / Ruby" --default ON \
  --detect 'cmd_exists mise || [[ -x ~/.local/bin/mise ]]' \
  --install install_mise --remove remove_mise

register_item --key fonts --cat system \
  --label "0xProto + MesloLGS Nerd Fonts + iA Writer + Monaspace" --default ON \
  --detect 'font_installed "0xProto" && font_installed "MesloLGS"' \
  --install install_fonts --remove remove_fonts

register_item --key fastfetch --cat system \
  --label "Fastfetch system info" --default ON \
  --detect 'cmd_exists fastfetch' \
  --install install_fastfetch --remove remove_fastfetch

register_item --key git --cat system \
  --label "Global git config (name + default branch)" --default ON \
  --detect 'git config --global user.name >/dev/null 2>&1' \
  --install configure_git --remove remove_git_config

register_item --key mac_tweaks --cat system --fg \
  --label "macOS tweaks: Finder / Dock / screenshots / Touch ID sudo" --default ON \
  --detect '[[ "$(defaults read NSGlobalDomain AppleShowAllExtensions 2>/dev/null)" == "1" ]]' \
  --install install_mac_tweaks --remove remove_mac_tweaks

# ── Terminal ───────────────────────────────────────────────────────────────────
register_item --key terminal --cat terminal \
  --label "CLI tools: fzf + ripgrep + bat + eza + zoxide + btop + fd + tldr" \
  --default ON \
  --detect 'cmd_exists fzf && cmd_exists bat' \
  --install install_terminal_tools --remove remove_terminal_tools

register_item --key alacritty --cat terminal \
  --label "Alacritty (GPU-accelerated terminal)" \
  --default ON \
  --detect 'cask_installed alacritty || app_exists Alacritty' \
  --install install_alacritty --remove remove_alacritty

register_item --key iterm2 --cat terminal \
  --label "iTerm2 (macOS-native terminal + 450 theme collection)" \
  --default ON \
  --detect 'cask_installed iterm2 || app_exists iTerm' \
  --install install_iterm2 --remove remove_iterm2

register_item --key ghostty --cat terminal \
  --label "Ghostty (GPU-accelerated, native mac app)" --default ON \
  --detect 'cask_installed ghostty || app_exists Ghostty' \
  --install install_ghostty --remove remove_ghostty

register_item --key zellij --cat terminal \
  --label "Zellij (terminal multiplexer)" \
  --default ON \
  --detect 'cmd_exists zellij' \
  --install install_zellij --remove remove_zellij

register_item --key tmux --cat terminal \
  --label "tmux + TPM plugin manager" --default ON \
  --detect 'cmd_exists tmux && [[ -d ~/.tmux/plugins/tpm ]]' \
  --install install_tmux --remove remove_tmux

register_item --key lazygit --cat terminal \
  --label "LazyGit (terminal git UI)" --default ON \
  --detect 'cmd_exists lazygit' \
  --install install_lazygit --remove remove_lazygit

register_item --key dotfiles --cat terminal \
  --label "Copy dotfiles from script directory" --default ON \
  --detect '[[ -f ~/.my.zsh ]]' \
  --install install_dotfiles --remove remove_dotfiles

# ── Editors ────────────────────────────────────────────────────────────────────
register_item --key neovim --cat editors \
  --label "Neovim + LazyVim" --default ON \
  --detect 'cmd_exists nvim && [[ -d ~/.config/nvim ]]' \
  --install install_neovim --remove remove_neovim

register_item --key zed --cat editors \
  --label "Zed (GPU-accelerated, multiplayer, Rust-based)" --default ON \
  --detect 'cmd_exists zed || app_exists Zed' \
  --install install_zed --remove remove_zed

register_item --key vscode --cat editors \
  --label "VS Code" --default ON \
  --detect 'cmd_exists code || app_exists "Visual Studio Code"' \
  --install install_vscode --remove remove_vscode

register_item --key vscodium --cat editors \
  --label "VSCodium (open-source VS Code)" --default ON \
  --detect 'cmd_exists codium || app_exists VSCodium' \
  --install install_vscodium --remove remove_vscodium

register_item --key sublime --cat editors \
  --label "Sublime Text + Sublime Merge" --default ON \
  --detect 'cmd_exists subl || app_exists "Sublime Text"' \
  --install install_sublime --remove remove_sublime

# ── Browsers ───────────────────────────────────────────────────────────────────
register_item --key brave --cat browsers \
  --label "Brave" --default ON \
  --detect 'cask_installed brave-browser || app_exists "Brave Browser"' \
  --install install_brave --remove remove_brave

register_item --key chrome --cat browsers \
  --label "Google Chrome" --default ON \
  --detect 'cask_installed google-chrome || app_exists "Google Chrome"' \
  --install install_chrome --remove remove_chrome

register_item --key firefox_dev --cat browsers \
  --label "Firefox Developer Edition" --default ON \
  --detect 'cask_installed firefox@developer-edition || app_exists "Firefox Developer Edition"' \
  --install install_firefox_dev --remove remove_firefox_dev

register_item --key edge --cat browsers \
  --label "Microsoft Edge" --default OFF \
  --detect 'cask_installed microsoft-edge || app_exists "Microsoft Edge"' \
  --install install_edge --remove remove_edge

# ── Dev Tools ──────────────────────────────────────────────────────────────────
register_item --key docker --cat devtools --fg \
  --label "Docker: Desktop and/or OrbStack (you choose)" --default ON \
  --detect 'cmd_exists docker' \
  --install install_docker --remove remove_docker

# ── Launchers ──────────────────────────────────────────────────────────────────
register_item --key raycast --cat launchers \
  --label "Raycast (Spotlight replacement)" --default OFF \
  --detect 'cask_installed raycast || app_exists Raycast' \
  --install install_raycast --remove remove_raycast

register_item --key alfred --cat launchers \
  --label "Alfred (Spotlight replacement)" --default OFF \
  --detect 'cask_installed alfred || app_exists Alfred' \
  --install install_alfred --remove remove_alfred

# ── Apps ───────────────────────────────────────────────────────────────────────
register_item --key slack --cat apps \
  --label "Slack" --default ON \
  --detect 'cask_installed slack || app_exists Slack' \
  --install install_slack --remove remove_slack

register_item --key spotify --cat apps \
  --label "Spotify" --default ON \
  --detect 'cask_installed spotify || app_exists Spotify' \
  --install install_spotify --remove remove_spotify

register_item --key zoom --cat apps \
  --label "Zoom" --default ON \
  --detect 'cask_installed zoom || app_exists zoom.us' \
  --install install_zoom --remove remove_zoom

register_item --key obsidian --cat apps \
  --label "Obsidian (notes)" --default ON \
  --detect 'cask_installed obsidian || app_exists Obsidian' \
  --install install_obsidian --remove remove_obsidian

register_item --key dropbox --cat apps \
  --label "Dropbox (cloud storage)" --default ON \
  --detect 'cask_installed dropbox || app_exists Dropbox' \
  --install install_dropbox --remove remove_dropbox

register_item --key 1password --cat apps \
  --label "1Password" --default ON \
  --detect 'cask_installed 1password || app_exists "1Password"' \
  --install install_1password --remove remove_1password

register_item --key localsend --cat apps \
  --label "LocalSend (local file sharing)" --default ON \
  --detect 'cask_installed localsend || app_exists LocalSend' \
  --install install_localsend --remove remove_localsend

# ── AI & Local LLMs ────────────────────────────────────────────────────────────
register_item --key claude_code --cat ai \
  --label "Claude Code (CLI)" --default OFF \
  --detect 'cmd_exists claude' \
  --install install_claude_code --remove remove_claude_code

register_item --key claude_desktop --cat ai \
  --label "Claude Desktop (official app)" --default OFF \
  --detect 'cask_installed claude || app_exists Claude' \
  --install install_claude_desktop --remove remove_claude_desktop

register_item --key lmstudio --cat ai \
  --label "LM Studio (local AI GUI)" --default OFF \
  --detect 'cask_installed lm-studio || app_exists "LM Studio"' \
  --install install_lmstudio --remove remove_lmstudio

register_item --key chatbox --cat ai \
  --label "Chatbox AI" --default OFF \
  --detect 'cask_installed chatbox || app_exists Chatbox' \
  --install install_chatbox --remove remove_chatbox

register_item --key opencode --cat ai \
  --label "opencode (AI coding agent, terminal)" --default OFF \
  --detect 'cmd_exists opencode' \
  --install install_opencode --remove remove_opencode

# ORDER CONSTRAINT — do not reorder without reading install_zsh:
# zsh stays LAST (wizard needs fonts installed first for p10k glyph detection,
# and its installer execs a shell that would kill the script mid-run), while
# fonts and dotfiles stay BEFORE it. Sourcing of ~/.my.zsh is owned by
# install_zsh (ensure_myzsh_sourced, post-wizard) — never by install_dotfiles.
# zsh runs last — its installer opens a new terminal window; keeping it last
# mirrors install.sh (terminal emulators and fonts are in place by then).
register_item --key zsh --cat system --fg \
  --label "zsh4humans + Powerlevel10k (zsh itself is macOS default)" --default ON \
  --detect '[[ -d ~/.local/share/z4h ]]' \
  --install install_zsh --remove remove_zsh

# =============================================================================
# TREE UI — bash 3.2-safe port of install.sh (indexed arrays only, no mapfile,
# no associative arrays; `read -t` takes integer seconds on bash 3.2, so the
# escape-sequence wait is 1s — only affects a lone ESC press, which is unbound)
# =============================================================================

# Checked flags + category expanded flags, parallel to registry/category arrays
CHECKED=()
EXPANDED=()
# Visible rows rebuilt on every draw: entries are "cat:<catidx>" / "item:<keyidx>"
ROWS=()
SELECTED_ITEMS=()

cat_index() {
  local want="$1" i=0
  while [[ $i -lt ${#_CAT_KEYS[@]} ]]; do
    if [[ "${_CAT_KEYS[$i]}" == "$want" ]]; then echo "$i"; return 0; fi
    i=$(( i + 1 ))
  done
  return 1
}

_checked_get() {
  local i="$1"
  if [[ $i -lt ${#CHECKED[@]} ]]; then echo "${CHECKED[$i]}"; else echo "0"; fi
}

_build_rows() {
  ROWS=()
  local ci=0
  while [[ $ci -lt ${#_CAT_KEYS[@]} ]]; do
    ROWS+=("cat:$ci")
    local exp="0"
    if [[ $ci -lt ${#EXPANDED[@]} ]]; then exp="${EXPANDED[$ci]}"; fi
    if [[ "$exp" == "1" ]]; then
      local ki=0
      while [[ $ki -lt ${#_REG_KEYS[@]} ]]; do
        if [[ "${_REG_CAT[$ki]}" == "${_CAT_KEYS[$ci]}" ]]; then
          ROWS+=("item:$ki")
        fi
        ki=$(( ki + 1 ))
      done
    fi
    ci=$(( ci + 1 ))
  done
}

run_tree_ui() {
  local mode="$1"
  local ci=0
  CHECKED=()
  EXPANDED=()
  while [[ $ci -lt ${#_CAT_KEYS[@]} ]]; do
    EXPANDED+=("1")
    ci=$(( ci + 1 ))
  done
  local ki=0
  while [[ $ki -lt ${#_REG_KEYS[@]} ]]; do
    if [[ "$mode" == "install" ]]; then
      if [[ "${_REG_DEF[$ki]}" == "ON" ]]; then CHECKED+=("1"); else CHECKED+=("0"); fi
    else
      if eval "${_REG_DET[$ki]}" 2>/dev/null; then CHECKED+=("1"); else CHECKED+=("0"); fi
    fi
    ki=$(( ki + 1 ))
  done

  local B='\033[1m' BRV='\033[1;7m' RST='\033[0m' CLR='\033[2K'
  local term_h; term_h=$(tput lines 2>/dev/null || echo 30)
  local term_w; term_w=$(tput cols  2>/dev/null || echo 80)
  local viewport=$(( term_h - 6 ))
  if [[ $viewport -lt 4 ]]; then viewport=4; fi
  local cursor=0 scroll=0

  printf '\033[?25l'
  tput smcup 2>/dev/null || true
  trap 'tput rmcup 2>/dev/null; printf "\033[?25h"' EXIT INT TERM
  clear

  _draw() {
    _build_rows
    local total=${#ROWS[@]}
    if [[ $cursor -ge $total ]]; then cursor=$(( total - 1 )); fi
    if [[ $cursor -lt 0 ]]; then cursor=0; fi
    if [[ $cursor -lt $scroll ]]; then scroll=$cursor; fi
    if [[ $cursor -ge $(( scroll + viewport )) ]]; then scroll=$(( cursor - viewport + 1 )); fi
    tput cup 0 0

    local mode_label
    case "$mode" in install) mode_label="INSTALL";; uninstall) mode_label="UNINSTALL";; *) mode_label="UPDATE";; esac
    printf "${CLR}${B}  Setup — macOS %s (%s)  ·  %s${RST}\n" "$MACOS_VER" "$ARCH" "$mode_label"
    printf "${CLR}${B}  ─────────────────────────────────────────────────────────${RST}\n"

    local i=$scroll
    while [[ $i -lt $(( scroll + viewport )) && $i -lt $total ]]; do
      local row="${ROWS[$i]}" line
      case "$row" in
        cat:*)
          local ck="${row#cat:}" clabel="${_CAT_LABELS[$ck]}"
          local nc=0 nt=0 k
          k=0
          while [[ $k -lt ${#_REG_KEYS[@]} ]]; do
            if [[ "${_REG_CAT[$k]}" == "${_CAT_KEYS[$ck]}" ]]; then
              nt=$(( nt + 1 ))
              if [[ "$(_checked_get "$k")" == "1" ]]; then nc=$(( nc + 1 )); fi
            fi
            k=$(( k + 1 ))
          done
          local box arr
          if [[ $nc -eq 0 ]]; then box="[ ]"
          elif [[ $nc -eq $nt ]]; then box="[x]"
          else box="[-]"; fi
          if [[ "${EXPANDED[$ck]}" == "1" ]]; then arr="▼"; else arr="▶"; fi
          line="  ${box} ${arr} ${clabel}  (${nc}/${nt})"
          ;;
        item:*)
          local idx="${row#item:}" chk
          if [[ "$(_checked_get "$idx")" == "1" ]]; then chk="[x]"; else chk="[ ]"; fi
          line="      ${chk} ${_REG_LABEL[$idx]}"
          ;;
      esac
      printf "${CLR}"
      if [[ $i -eq $cursor ]]; then
        printf "${BRV}%-${term_w}s${RST}\n" "$line"
      else
        printf "%-${term_w}s\n" "$line"
      fi
      i=$(( i + 1 ))
    done

    local ci2=$(( total - scroll ))
    while [[ $ci2 -lt $viewport ]]; do printf "${CLR}\n"; ci2=$(( ci2 + 1 )); done
    printf "${CLR}\n"
    printf "${CLR}${B}  Space${RST}=toggle  ${B}up/dn|jk${RST}=move  ${B}l/r|hl${RST}=collapse/expand  ${B}a${RST}=all  ${B}n${RST}=none  ${B}Enter${RST}=confirm  ${B}q${RST}=quit\n"
  }

  _draw
  while true; do
    _build_rows
    local total=${#ROWS[@]} cur_row="${ROWS[$cursor]}"
    local key esc
    IFS= read -rsn1 key
    # Integer timeout: bash 3.2 `read -t` accepts seconds only
    if [[ $key == $'\033' ]]; then IFS= read -rsn2 -t 1 esc; key="${key}${esc}"; fi

    case "$key" in
      $'\033[A'|k) if [[ $cursor -gt 0 ]]; then cursor=$(( cursor - 1 )); fi ;;
      $'\033[B'|j) if [[ $cursor -lt $(( total - 1 )) ]]; then cursor=$(( cursor + 1 )); fi ;;
      $'\033[C'|l)
        case "$cur_row" in cat:*) EXPANDED["${cur_row#cat:}"]="1" ;; esac ;;
      $'\033[D'|h)
        case "$cur_row" in
          cat:*) EXPANDED["${cur_row#cat:}"]="0" ;;
          item:*)
            local idx="${cur_row#item:}" parent ck2
            parent="${_REG_CAT[$idx]}"
            ck2=$(cat_index "$parent")
            EXPANDED["$ck2"]="0"
            local ri=0
            while [[ $ri -lt $total ]]; do
              if [[ "${ROWS[$ri]}" == "cat:$ck2" ]]; then cursor=$ri; break; fi
              ri=$(( ri + 1 ))
            done
            ;;
        esac ;;
      ' ')
        case "$cur_row" in
          cat:*)
            local ck="${cur_row#cat:}" all1=1 k
            k=0
            while [[ $k -lt ${#_REG_KEYS[@]} ]]; do
              if [[ "${_REG_CAT[$k]}" == "${_CAT_KEYS[$ck]}" ]]; then
                if [[ "$(_checked_get "$k")" != "1" ]]; then all1=0; break; fi
              fi
              k=$(( k + 1 ))
            done
            local ns=$(( 1 - all1 ))
            k=0
            while [[ $k -lt ${#_REG_KEYS[@]} ]]; do
              if [[ "${_REG_CAT[$k]}" == "${_CAT_KEYS[$ck]}" ]]; then CHECKED[$k]=$ns; fi
              k=$(( k + 1 ))
            done
            ;;
          item:*)
            local idx="${cur_row#item:}"
            if [[ "$(_checked_get "$idx")" == "1" ]]; then CHECKED[$idx]=0; else CHECKED[$idx]=1; fi
            ;;
        esac ;;
      a|A)
        local k=0
        while [[ $k -lt ${#_REG_KEYS[@]} ]]; do CHECKED[$k]=1; k=$(( k + 1 )); done ;;
      n|N)
        local k=0
        while [[ $k -lt ${#_REG_KEYS[@]} ]]; do CHECKED[$k]=0; k=$(( k + 1 )); done ;;
      ''|$'\n') break ;;
      q|Q) tput rmcup 2>/dev/null; printf '\033[?25h\n'; echo "Cancelled."; exit 0 ;;
    esac
    _draw
  done

  tput rmcup 2>/dev/null; printf '\033[?25h'
  trap - EXIT INT TERM
  SELECTED_ITEMS=()
  local k=0
  while [[ $k -lt ${#_REG_KEYS[@]} ]]; do
    if [[ "$(_checked_get "$k")" == "1" ]]; then SELECTED_ITEMS+=("$k"); fi
    k=$(( k + 1 ))
  done
}

# =============================================================================
# DISPATCH
# =============================================================================
dispatch() {
  local mode="$1" si
  si=0
  while [[ $si -lt ${#SELECTED_ITEMS[@]} ]]; do
    local idx="${SELECTED_ITEMS[$si]}" fn label fg
    label="${_REG_LABEL[$idx]:-$idx}"
    fg="${_REG_FG[$idx]:-0}"
    if [[ "$mode" == "uninstall" ]]; then
      fn="${_REG_REM[$idx]:-}"; label="Remove: $label"
    else
      fn="${_REG_INST[$idx]:-}"
    fi
    if [[ -z "$fn" ]]; then
      log "  WARNING: No function for ${_REG_KEYS[$idx]} in $mode mode"
      si=$(( si + 1 )); continue
    fi

    # Per-item timeouts for known slow steps
    local timeout="${STEP_TIMEOUT_SECS:-300}"
    case "${_REG_KEYS[$idx]}" in
      docker)   timeout=600 ;;
      mise)     timeout=600 ;;
      lmstudio) timeout=600 ;;
      zoom)     timeout=600 ;;
      dropbox)  timeout=600 ;;
      1password) timeout=600 ;;
      fonts)    timeout=300 ;;
      neovim)   timeout=300 ;;
      iterm2)   timeout=300 ;;
    esac

    if [[ "$fg" == "1" ]]; then STEP_TIMEOUT_SECS="$timeout" run_step_fg "$label" "$fn"
    else                        STEP_TIMEOUT_SECS="$timeout" run_step    "$label" "$fn"
    fi
    si=$(( si + 1 ))
  done
}

# =============================================================================
# MODE CHOOSER — arrow-key selector, no buttons (bash 3.2-safe)
# =============================================================================
MODE=""

choose_mode() {
  local options=("install" "uninstall" "update")
  local labels=(
    "  Install    — add selected items to this machine      "
    "  Uninstall  — remove selected items                   "
    "  Update     — re-run installs to get latest versions  "
  )
  local selected=0
  local B='\033[1m' BRV='\033[1;7m' RST='\033[0m' CLR='\033[2K'

  printf '\033[?25l'; tput smcup 2>/dev/null || true; clear

  _draw_mode() {
    tput cup 0 0
    printf "${CLR}\n"
    printf "${CLR}  Setup — macOS %s (%s)\n" "$MACOS_VER" "$ARCH"
    printf "${CLR}  ─────────────────────────────────────────────────────────\n"
    local i=0
    while [[ $i -lt ${#options[@]} ]]; do
      printf "${CLR}"
      if [[ $i -eq $selected ]]; then
        printf "  ${BRV}▶ %s${RST}\n" "${labels[$i]}"
      else
        printf "    %s\n" "${labels[$i]}"
      fi
      i=$(( i + 1 ))
    done
    printf "${CLR}\n"
    printf "${CLR}  up/dn | j/k = move  |  Enter = confirm  |  q = quit\n"
  }

  _draw_mode
  while true; do
    local key esc
    IFS= read -rsn1 key
    if [[ $key == $'\033' ]]; then IFS= read -rsn2 -t 1 esc; key="${key}${esc}"; fi
    case "$key" in
      $'\033[A'|k) if [[ $selected -gt 0 ]]; then selected=$(( selected - 1 )); fi; _draw_mode ;;
      $'\033[B'|j) if [[ $selected -lt $(( ${#options[@]} - 1 )) ]]; then selected=$(( selected + 1 )); fi; _draw_mode ;;
      ''|$'\n')    break ;;
      q|Q) tput rmcup 2>/dev/null; printf '\033[?25h\n'; echo "Cancelled."; exit 0 ;;
    esac
  done
  tput rmcup 2>/dev/null; printf '\033[?25h'
  MODE="${options[$selected]}"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo ""                                                         >> "$LOG_FILE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$LOG_FILE"
  echo "  RUN STARTED: $(date '+%Y-%m-%d %H:%M:%S')"               >> "$LOG_FILE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$LOG_FILE"

  trap 'stop_spinner; tput rmcup 2>/dev/null; printf "\033[?25h"' EXIT INT TERM

  detect_mac
  preflight_mac

  logecho "macOS $MACOS_VER ($ARCH) — platform detected, starting setup"

  choose_mode
  echo "  MODE: $MODE" >> "$LOG_FILE"

  run_tree_ui "$MODE"

  if [[ ${#SELECTED_ITEMS[@]} -eq 0 ]]; then
    logecho "No items selected — nothing to do."; exit 0
  fi

  trap 'stop_spinner' EXIT INT TERM
  logecho "Starting ${MODE} of ${#SELECTED_ITEMS[@]} item(s)..."

  dispatch "$MODE"

  trap - EXIT INT TERM

  local action
  case "$MODE" in install) action="installed";; uninstall) action="removed";; *) action="updated";; esac

  echo ""
  if [[ ${#ERRORS[@]} -eq 0 ]]; then
    logecho "━━━ All selected items ${action} successfully ━━━"
  else
    logecho "━━━ Finished with ${#ERRORS[@]} warning(s) ━━━"
    local ei=0
    while [[ $ei -lt ${#ERRORS[@]} ]]; do
      logecho "  • ${ERRORS[$ei]}"
      ei=$(( ei + 1 ))
    done
  fi
  logecho "Log: $LOG_FILE"
  logecho "Reminder: open a new terminal (or run 'exec zsh') so PATH/shell changes take effect."

  echo ""
  echo "Done — press ENTER to finish."
  read -r _ </dev/tty
}

if [[ $_MAC_SOURCE_ONLY -eq 0 ]]; then
  main "$@"
fi
