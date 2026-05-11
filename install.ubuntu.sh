#!/usr/bin/env bash
# =============================================================================
# setup-ubuntu.sh — Interactive Ubuntu setup / autoinstaller
# Usage:     bash setup-ubuntu.sh
#
# NOTES:
#   - No step is irreversible; re-running is safe (installs are idempotent)
#   - Failures are non-fatal: collected and shown in a summary at the end
#   - Full timestamped log written to ~/setup-ubuntu.log
#   - Dotfiles (.tmux.conf, alacritty.toml, .my.zsh) must sit beside this script
# =============================================================================
set -uo pipefail   # intentionally no -e; errors handled per-step via run_step()

# ─────────────────────────────────────────────────────────────────────────────
# Globals
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$HOME/setup-ubuntu.log"
ERRORS=()   # non-fatal failures; shown in the whiptail summary at the end

# Load distro metadata: $ID, $VERSION_ID, $VERSION_CODENAME, $UBUNTU_CODENAME
# shellcheck disable=SC1091
. /etc/os-release

# Ubuntu 22.04+ sets UBUNTU_CODENAME; older releases fall back to VERSION_CODENAME
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"

# ─────────────────────────────────────────────────────────────────────────────
# Guard: Ubuntu only
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$ID" != "ubuntu" ]]; then
  echo "ERROR: This script targets Ubuntu only. Detected: $ID"
  echo "       For Arch / Fedora support use setup-multiplatform.sh instead."
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

# Timestamped log line — written to log file only (not stdout) so it doesn't
# interfere with the spinner that's already on stdout during a step.
log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }

# Same as log() but also prints to stdout — used outside of run_step() calls
# (e.g. the final summary, pre-flight messages) where no spinner is active.
logecho() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ── Spinner ───────────────────────────────────────────────────────────────────
# Frames cycle at ~10fps. SPINNER_PID is set when a spinner is running so
# stop_spinner() can kill it from run_step() even if the step fails.
SPINNER_PID=""
SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

start_spinner() {
  local label="$1"
  local start_ts=$SECONDS
  (
    local i=0
    while true; do
      local elapsed=$(( SECONDS - start_ts ))
      local mins=$(( elapsed / 60 ))
      local secs=$(( elapsed % 60 ))
      printf "\r  %s  %-45s  %02d:%02d" \
        "${SPINNER_FRAMES[$(( i % ${#SPINNER_FRAMES[@]} ))]}" \
        "$label" "$mins" "$secs"
      i=$(( i + 1 ))
      sleep 0.1
    done
  ) &
  SPINNER_PID=$!
  # Ensure the spinner subprocess dies if the parent exits unexpectedly
  disown "$SPINNER_PID" 2>/dev/null || true
}

stop_spinner() {
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf "\r%*s\r" "$(tput cols 2>/dev/null || echo 80)" ""  # clear the line
  fi
}

# ── Step runner ───────────────────────────────────────────────────────────────
#
# run_step <label> <function>
#   - Runs in a background subshell with spinner + elapsed time
#   - Ctrl+C kills the background job and the entire process group cleanly
#   - Timeout: steps are killed after $STEP_TIMEOUT_SECS (default 300s / 5 min)
#     Override per-step: STEP_TIMEOUT_SECS=600 run_step "label" fn
#
# run_step_fg <label> <function>
#   - Runs in the foreground (required for mise, zsh — modify current shell)
#
STEP_TIMEOUT_SECS="${STEP_TIMEOUT_SECS:-300}"  # 5 min default; override as needed

_run_step_impl() {
  local mode="$1" label="$2"
  shift 2
  local func="$1"
  shift

  local start_ts=$SECONDS
  echo ""
  logecho "▶ START: $label"
  start_spinner "$label"

  local exit_code=0 bg_pid=""

  # SIGINT/SIGTERM handler — kills background job + its entire process group
  # then propagates so the main script's own trap fires next
  _step_abort() {
    stop_spinner
    if [[ -n "$bg_pid" ]]; then
      # Kill the whole process group (negative PID = group)
      kill -TERM "-${bg_pid}" 2>/dev/null || kill -TERM "$bg_pid" 2>/dev/null || true
      wait "$bg_pid" 2>/dev/null || true
    fi
    logecho "⚡ INTERRUPTED: $label"
    ERRORS+=("$label (interrupted)")
    # Re-raise so the outer trap in main() also fires
    trap - INT TERM
    kill -INT "$$"
  }
  trap '_step_abort' INT TERM

  if [[ "$mode" == "bg" ]]; then
    # Run in its own process group (set -m / setsid) so we can kill the tree
    # setsid not always available; fallback to plain backgrounding
    if command -v setsid &>/dev/null; then
      setsid bash -c "$func \"\$@\"" _ "$@" >> "$LOG_FILE" 2>&1 &
    else
      "$func" "$@" >> "$LOG_FILE" 2>&1 &
    fi
    bg_pid=$!

    # Timeout watchdog — kills the job if it runs too long
    local timeout_secs="${STEP_TIMEOUT_SECS:-300}"
    (
      sleep "$timeout_secs"
      if kill -0 "$bg_pid" 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] TIMEOUT: $label exceeded ${timeout_secs}s — killing" \
          >> "$LOG_FILE"
        kill -TERM "-${bg_pid}" 2>/dev/null || kill -TERM "$bg_pid" 2>/dev/null || true
      fi
    ) &
    local watchdog_pid=$!

    wait "$bg_pid"
    exit_code=$?

    # Cancel the watchdog if the job finished normally
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  else
    "$func" "$@" >> "$LOG_FILE" 2>&1
    exit_code=$?
  fi

  # Restore default signal handling for this step
  trap - INT TERM

  stop_spinner

  local elapsed=$(( SECONDS - start_ts ))
  local mins=$(( elapsed / 60 ))
  local secs=$(( elapsed % 60 ))

  if [[ $exit_code -eq 0 ]]; then
    logecho "✓ DONE:  $label  (${mins}m ${secs}s)"
  elif [[ $exit_code -eq 124 ]] || [[ $exit_code -eq 143 ]]; then
    logecho "✗ TIMEOUT: $label  (${mins}m ${secs}s — killed after ${STEP_TIMEOUT_SECS}s)"
    ERRORS+=("$label (timed out)")
  else
    logecho "✗ FAILED: $label  (${mins}m ${secs}s, exit $exit_code)"
    logecho "  → Check $LOG_FILE for details"
    ERRORS+=("$label")
  fi
}

run_step()    { _run_step_impl "bg" "$@"; }
run_step_fg() { _run_step_impl "fg" "$@"; }

# Capture whiptail output — swaps stdout/stderr so the selection lands in a variable
ask() { whiptail "$@" 3>&1 1>&2 2>&3; }

# version_gte A B → true if A >= B   e.g. version_gte "26.04" "25.04" → true
version_gte() { [ "$(printf '%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

# ─────────────────────────────────────────────────────────────────────────────
# apt_add_repo — safe key → repo → apt install in three guarded steps
#
# Usage:
#   apt_add_repo \
#     --name       "brave"                               # used for keyring/list filenames
#     --key-url    "https://..."                         # GPG key URL
#     --keyring    "/usr/share/keyrings/brave.gpg"      # where to write the keyring
#     --repo-line  "deb [signed-by=...] https://... stable main"
#     --repo-file  "/etc/apt/sources.list.d/brave.list"
#     --packages   "brave-browser"                      # space-separated
#
# Each step is explicitly guarded:
#   1. Key fetch + dearmor — if this fails/times out, abort. Clean up partial file.
#   2. Repo file write    — if key file doesn't exist or is empty, abort.
#   3. apt-get update    — if repo file doesn't exist, abort.
#   4. apt-get install   — only runs if all prior steps succeeded.
#
# Returns 1 on any failure so the caller's run_step registers it as FAILED.
# ─────────────────────────────────────────────────────────────────────────────
apt_add_repo() {
  local name="" key_url="" keyring="" repo_line="" repo_file="" packages=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)      name="$2";      shift 2 ;;
      --key-url)   key_url="$2";   shift 2 ;;
      --keyring)   keyring="$2";   shift 2 ;;
      --repo-line) repo_line="$2"; shift 2 ;;
      --repo-file) repo_file="$2"; shift 2 ;;
      --packages)  packages="$2";  shift 2 ;;
      *) shift ;;
    esac
  done

  # ── Step 1: fetch and dearmor the GPG key ──────────────────────────────────
  log "  [$name] Fetching GPG key..."
  if ! curl -fsSL --connect-timeout 15 --max-time 30 "$key_url" \
      | sudo gpg --dearmor -o "$keyring"; then
    log "  WARNING: [$name] GPG key fetch failed or timed out — aborting install"
    sudo rm -f "$keyring"   # remove any partial/corrupt file
    return 1
  fi

  # Verify the keyring file was actually written and is non-empty
  if [[ ! -s "$keyring" ]]; then
    log "  WARNING: [$name] Keyring file is empty after fetch — aborting install"
    sudo rm -f "$keyring"
    return 1
  fi
  log "  [$name] GPG key OK."

  # ── Step 2: write the repo file ────────────────────────────────────────────
  log "  [$name] Adding apt repository..."
  if ! echo "$repo_line" | sudo tee "$repo_file" > /dev/null; then
    log "  WARNING: [$name] Could not write repo file — aborting install"
    sudo rm -f "$keyring"
    return 1
  fi
  log "  [$name] Repository added."

  # ── Step 3: apt-get update ─────────────────────────────────────────────────
  log "  [$name] Updating package index..."
  if ! sudo apt-get update -y; then
    log "  WARNING: [$name] apt-get update failed — aborting install"
    return 1
  fi

  # ── Step 4: install packages ───────────────────────────────────────────────
  log "  [$name] Installing: $packages..."
  # shellcheck disable=SC2086  # intentional word splitting of $packages
  if ! DEBIAN_FRONTEND=noninteractive sudo -E apt-get install -y \
      -o DPkg::Options::="--force-confnew" $packages; then
    log "  WARNING: [$name] Package install failed"
    return 1
  fi
  log "  [$name] Install complete."
}

# Add an openSUSE Build Service (OBS) apt repo, auto-detecting the nearest
# supported Ubuntu version when the exact one isn't published yet.
# Usage: add_obs_repo <obs_project> <package_name>
add_obs_repo() {
  local obs_project="$1" package_name="$2"
  local base_url="https://download.opensuse.org/repositories/${obs_project}"
  local try_url="${base_url}/xUbuntu_${VERSION_ID}/"

  # Fall back to the closest older version if this Ubuntu release isn't on OBS yet
  if ! curl -fsSL --head "${try_url}Release" &>/dev/null; then
    local prev_ver
    prev_ver=$(curl -fsSL "${base_url}/" 2>/dev/null \
      | grep -oP "xUbuntu_\K[0-9]+\.[0-9]+" \
      | sort -V \
      | awk -v cur="$VERSION_ID" '$0 <= cur' \
      | tail -1)
    if [[ -n "$prev_ver" ]]; then
      log "  OBS: Ubuntu $VERSION_ID not yet available for $package_name — using $prev_ver"
      try_url="${base_url}/xUbuntu_${prev_ver}/"
    else
      log "  WARNING: No OBS repo found for $package_name — skipping"
      return 1
    fi
  fi

  curl -fsSL "${try_url}Release.key" \
    | gpg --dearmor \
    | sudo tee "/etc/apt/trusted.gpg.d/${obs_project//:/--}.gpg" > /dev/null
  echo "deb ${try_url} /" \
    | sudo tee "/etc/apt/sources.list.d/${package_name}.list" > /dev/null
}

# Install a Nerd Font (or any zipped font collection) from a URL
# Usage: install_font <display_name> <zip_url> <extension>
install_font() {
  local font_name="$1" url="$2" ext="$3"
  if fc-list | grep -qi "$font_name"; then
    log "  Font already installed: $font_name — skipping"
    return 0
  fi
  local tmp; tmp=$(mktemp -d)
  if wget -q --tries=1 --connect-timeout=15 -O "$tmp/font.zip" "$url" && unzip -q "$tmp/font.zip" -d "$tmp/font"; then
    find "$tmp/font" -name "*.$ext" -exec cp {} ~/.local/share/fonts/ \;
  else
    log "  WARNING: Could not download font: $font_name"
  fi
  rm -rf "$tmp"
}

# Return the browser_download_url for the latest GitHub release asset matching a pattern
# Usage: github_latest <owner/repo> <filename_substring>
github_latest() {
  local repo="$1" glob="$2"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | grep -Po '"browser_download_url": "\K[^"]+'"$glob"'[^"]*(?=")' \
    | head -1
}

# ─────────────────────────────────────────────────────────────────────────────
# Idempotency helpers — used by show_menu to pre-tick already-done steps
# ─────────────────────────────────────────────────────────────────────────────

# Return 0 if an apt package is installed (any state other than not-installed)
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "^install ok"; }

# Return 0 if a command (binary) exists on PATH
cmd_exists() { command -v "$1" &>/dev/null; }

# Return 0 if a Flatpak app ID is installed for the current user or system-wide
flatpak_installed() { flatpak info "$1" &>/dev/null 2>&1; }

# Return 0 if a Snap is installed
snap_installed() { snap list "$1" &>/dev/null 2>&1; }

# Guess whether a given menu step looks already done.
# Used to pre-tick the whiptail checklist so reruns are less tedious.
# Returns 0 (pre-tick ON) or 1 (pre-tick OFF) based on lightweight signal checks.
step_done() {
  local step="$1"
  case "$step" in
    base)
      # Consider done if the core build toolchain is present
      pkg_installed build-essential && pkg_installed libssl-dev ;;
    zsh)
      pkg_installed zsh && [[ "$(getent passwd "$USER" | cut -d: -f7)" == */zsh ]] ;;
    fonts)
      fc-list | grep -qi "FiraMono Nerd" ;;
    terminal)
      pkg_installed alacritty && cmd_exists fzf ;;
    neovim)
      cmd_exists nvim && [[ -d ~/.config/nvim ]] ;;
    editors)
      cmd_exists code || cmd_exists codium ;;
    browsers)
      cmd_exists brave-browser || cmd_exists google-chrome || cmd_exists microsoft-edge ;;
    docker)
      cmd_exists docker ;;
    lazygit)
      cmd_exists lazygit ;;
    mise)
      cmd_exists mise || [[ -x ~/.local/bin/mise ]] ;;
    flatpak)
      flatpak_installed md.obsidian.Obsidian ;;
    launcher)
      cmd_exists albert || cmd_exists ulauncher ;;
    nvidia)
      # Check if any nvidia driver module is loaded
      lsmod 2>/dev/null | grep -q "^nvidia " ;;
    gaming)
      pkg_installed steam-installer || flatpak_installed com.valvesoftware.Steam ;;
    wine_stack)
      command -v wine &>/dev/null && command -v winetricks &>/dev/null \
        && flatpak_installed com.usebottles.bottles ;;
    gaming_extras)
      flatpak_installed org.freedesktop.Platform.VulkanLayer.vkBasalt \
        && flatpak_installed io.github.antimicrox.antimicrox ;;
    controller)
      dkms status 2>/dev/null | grep -q "xpadneo" ;;
    lmstudio)
      dpkg-query -W lmstudio &>/dev/null 2>&1 ;;
    jan)
      dpkg-query -W jan &>/dev/null 2>&1 ;;
    chatbox)
      [[ -x /opt/ChatboxAi/ChatboxAi.AppImage ]] ;;
    comms)
      snap_installed slack || flatpak_installed com.slack.Slack ;;
    1password)
      pkg_installed 1password ;;
    localsend)
      pkg_installed localsend ;;
    pomodoro)
      pkg_installed pomatez ;;
    gnome)
      # Consider done if gnome-tweaks is installed
      pkg_installed gnome-tweaks ;;
    tmux)
      pkg_installed tmux && [[ -d ~/.tmux/plugins/tpm ]] ;;
    dotfiles)
      [[ -f ~/.my.zsh ]] ;;
    fastfetch)
      cmd_exists fastfetch ;;
    git)
      git config --global user.name &>/dev/null ;;
    *)
      return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight
# ─────────────────────────────────────────────────────────────────────────────
preflight() {
  logecho "Ubuntu $VERSION_ID ($CODENAME) — setup starting"
  logecho "Log: $LOG_FILE"

  # whiptail ships on every Ubuntu install, but guard just in case
  if ! command -v whiptail &>/dev/null; then
    sudo apt-get install -y whiptail >> "$LOG_FILE" 2>&1
  fi

  # ── Whiptail colour theme ─────────────────────────────────────────────────────
  # NEWT_COLORS named colours (white, cyan, brightyellow etc.) map to ANSI
  # colour slots 0-15, which terminals freely remap via their own palette.
  # A terminal with a custom theme (like yours) will show cyan or yellow as
  # whatever colour it has assigned to that slot — often an indistinct grey.
  #
  # The only reliable fix is to use ANSI 256-colour or true-colour escapes,
  # which bypass the palette entirely. newt supports this via a NEWT_COLORS_FILE
  # with explicit escape sequences for each element, but that requires a temp
  # file and is fragile across newt versions.
  #
  # Simplest robust solution: keep the checklist theme neutral (black/white only
  # — slots 0 and 7, almost never remapped) and replace the whiptail --menu
  # button-based mode chooser with a plain terminal prompt where there are no
  # buttons to confuse at all. See choose_mode() below.
  export NEWT_COLORS='
root=white,black
border=white,black
window=white,black
shadow=black,black
title=white,black
button=black,white
actbutton=white,black
checkbox=white,black
actcheckbox=black,white
entry=white,black
label=white,black
listbox=white,black
actlistbox=black,white
textbox=white,black
acttextbox=black,white
helpline=black,white
roottext=white,black
'

  # Pre-seed the EULA for ttf-mscorefonts so it never blocks the script
  echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" \
    | sudo debconf-set-selections
}

# ─────────────────────────────────────────────────────────────────────────────
# Install functions — one per logical group
# ─────────────────────────────────────────────────────────────────────────────

install_base() {
  log "  Updating package index..."
  sudo apt-get update -y

  # ── Network and archive essentials ───────────────────────────────────────────
  log "  Installing network and archive tools..."
  sudo apt-get install -y \
    curl gpg wget git unzip ca-certificates

  # ── Multimedia codecs (fonts, audio, video) — EULA pre-seeded in preflight ──
  log "  Installing multimedia codecs..."
  sudo apt-get install -y \
    ubuntu-restricted-extras

  # ── Ruby build dependencies ───────────────────────────────────────────────────
  # mise compiles Ruby from source; every package below is required for a
  # successful 'mise use --global ruby@latest' (see install_mise()).
  # autoconf/patch/build-essential: C toolchain
  # rustc: Ruby 3.x ships a bundled Rust extension (YJIT)
  # libssl-dev, libyaml-dev, libreadline-dev: Ruby core feature deps
  # zlib1g-dev, libgmp-dev, libncurses5-dev: compression / math / terminal libs
  # libffi-dev: needed for the ffi gem (used by many Rails dependencies)
  # libgdbm6, libgdbm-dev, libdb-dev: database binding libs
  # uuid-dev: required by some native gems
  # pkg-config, bison: build helpers used by the configure step
  # clang: alternative C compiler; some Ruby extensions prefer it
  # libjemalloc2: optional but recommended allocator for lower memory fragmentation
  log "  Installing Ruby build dependencies (for mise)..."
  sudo apt-get install -y \
    autoconf patch build-essential rustc \
    libssl-dev libyaml-dev libreadline-dev \
    zlib1g-dev libgmp-dev libncurses5-dev \
    libffi-dev libgdbm6 libgdbm-dev libdb-dev uuid-dev \
    pkg-config bison clang libjemalloc2

  # ── Image and document processing ────────────────────────────────────────────
  # libvips / imagemagick: used by Rails Active Storage and image processing gems
  # mupdf / mupdf-tools: lightweight PDF rendering (faster than poppler for previews)
  log "  Installing image and document processing libraries..."
  sudo apt-get install -y \
    libvips imagemagick libmagickwand-dev \
    mupdf mupdf-tools

  # ── Database clients and dev headers ─────────────────────────────────────────
  # redis-tools: CLI for inspecting Redis caches
  # sqlite3 / libsqlite3-0: embedded DB used heavily in development
  # libpq-dev / postgresql-client: PostgreSQL client headers and CLI
  # gir1.2-gtop-2.0: system resource introspection (used by GNOME extensions)
  log "  Installing database clients and headers..."
  sudo apt-get install -y \
    redis-tools \
    sqlite3 libsqlite3-0 \
    libpq-dev postgresql-client \
    gir1.2-gtop-2.0

  # ── MySQL client headers ──────────────────────────────────────────────────────
  # Package was renamed in Ubuntu 25.04+ to avoid the Oracle dependency
  log "  Installing MySQL client headers..."
  if version_gte "$VERSION_ID" "25.04"; then
    sudo apt-get install -y default-libmysqlclient-dev || true
  else
    sudo apt-get install -y libmysqlclient-dev || true
  fi

  # ── Desktop integration ───────────────────────────────────────────────────────
  # wl-clipboard: Wayland clipboard CLI (wl-copy / wl-paste) used by Neovim etc.
  # xdg-utils: xdg-open, xdg-mime — used by many apps to open files/URLs
  log "  Installing desktop integration tools..."
  sudo apt-get install -y \
    wl-clipboard xdg-utils
}

install_zsh() {
  sudo apt-get install -y zsh fonts-font-awesome

  # chsh takes effect after the next login; the script continues under bash
  sudo chsh -s "$(which zsh)" "$USER"
  log "  NOTE: Shell changed to Zsh — log out and back in to activate."

  # zsh4humans bootstrap is semi-interactive (asks a few setup prompts)
  log "  Running zsh4humans bootstrap (may prompt)..."
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/romkatv/zsh4humans/v5/install)" || true
  log "  NOTE: Run 'p10k configure' after your first Zsh login."
}

install_fonts() {
  mkdir -p ~/.local/share/fonts

  # Nerd Fonts — fetched from latest GitHub release, no hardcoded version
  install_font "FiraMono Nerd Font" \
    "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraMono.zip" "otf"
  install_font "JetBrainsMono Nerd Font" \
    "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip" "ttf"
  install_font "MesloLGS Nerd Font" \
    "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip" "ttf"
  install_font "CaskaydiaMono Nerd Font" \
    "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/CascadiaMono.zip" "ttf"

  # iA Writer Mono — served from master branch (no versioned releases)
  local tmp; tmp=$(mktemp -d)
  wget -q --tries=1 --connect-timeout=15 -O "$tmp/ia.zip" "https://github.com/iaolo/iA-Fonts/archive/refs/heads/master.zip" \
    && unzip -q "$tmp/ia.zip" -d "$tmp/ia" \
    && find "$tmp/ia" -name "iAWriterMonoS-*.ttf" -exec cp {} ~/.local/share/fonts/ \; || true
  rm -rf "$tmp"

  # MesloLGS NF — Powerlevel10k's own patched variant of Meslo
  local p10k_base="https://github.com/romkatv/powerlevel10k-media/raw/master"
  for f in "MesloLGS NF Regular" "MesloLGS NF Bold" "MesloLGS NF Italic" "MesloLGS NF Bold Italic"; do
    wget -q --tries=1 --connect-timeout=15 -O ~/.local/share/fonts/"${f}.ttf" "${p10k_base}/${f// /%20}.ttf" || true
  done

  # Monaspace — cloned over HTTPS (not SSH) so no GitHub key setup is needed
  local tmp2; tmp2=$(mktemp -d)
  git clone --depth=1 https://github.com/githubnext/monaspace.git "$tmp2/monaspace"
  mkdir -p ~/.local/share/fonts/Monaspace
  find "$tmp2/monaspace/fonts" \( -name "*.otf" -o -name "*.ttf" -o -name "*.woff2" \) \
    -exec cp {} ~/.local/share/fonts/Monaspace/ \;
  rm -rf "$tmp2"

  fc-cache -f
}

install_terminal_tools() {
  sudo apt-get install -y \
    fzf ripgrep bat eza zoxide plocate btop tmux alacritty

  # fd is packaged as 'fd-find' on Ubuntu (name conflict with another package);
  # create a 'fd' symlink so muscle memory works the same as on Arch/Fedora
  if ! sudo apt-get install -y fd-find 2>/dev/null; then
    sudo apt-get install -y fd || true
  fi
  if command -v fdfind &>/dev/null && ! command -v fd &>/dev/null; then
    mkdir -p ~/.local/bin
    ln -sf "$(which fdfind)" ~/.local/bin/fd
  fi

  sudo apt-get install -y tldr || true

  # Alacritty colour theme collection (separate from the binary)
  mkdir -p ~/.config/alacritty/themes
  git clone --depth=1 https://github.com/alacritty/alacritty-theme \
    ~/.config/alacritty/themes 2>/dev/null \
    || git -C ~/.config/alacritty/themes pull || true

  # Copy alacritty config from script directory if present
  [[ -f "$SCRIPT_DIR/alacritty.toml" ]] && \
    cp "$SCRIPT_DIR/alacritty.toml" ~/.config/alacritty/

  # Zellij — snap is the simplest cross-version install path on Ubuntu
  sudo snap install zellij --classic || true
}

install_ghostty() {
  # Ghostty — fast, native, GPU-accelerated terminal emulator by Mitchell Hashimoto
  # Config file: ~/.config/ghostty/config
  # Docs: https://ghostty.org/docs

  # Ubuntu 26.04+ ships Ghostty in the universe repo — plain apt is enough.
  # Older Ubuntu releases (24.04, 25.x) need the community PPA from mkasberg.
  # The PPA installer script auto-detects the version and does the right thing,
  # so we try apt first (fast, no PPA needed on 26.04) and fall back to the
  # installer script for older releases.
  if version_gte "$VERSION_ID" "26.04"; then
    sudo add-apt-repository -y universe
    sudo apt-get update -y
    sudo apt-get install -y ghostty \
      && return 0 \
      || log "  WARNING: ghostty not found in universe on $VERSION_ID — falling back to PPA"
  fi

  # PPA installer: detects Ubuntu version, adds mkasberg/ghostty-ubuntu PPA,
  # and installs the appropriate .deb. Handles 24.04, 25.04, 25.10 automatically.
  curl -fsSL --connect-timeout 15 --max-time 60 \
    https://raw.githubusercontent.com/mkasberg/ghostty-ubuntu/HEAD/install.sh \
    | bash \
    || log "  WARNING: Ghostty PPA install failed"
}

remove_ghostty() {
  sudo apt-get purge -y ghostty || true
  sudo apt-get autoremove -y
  # Remove PPA if it was added (no-op on 26.04 where it came from universe)
  sudo add-apt-repository -r -y ppa:mkasberg/ghostty-ubuntu 2>/dev/null || true
  sudo apt-get update -y
  log "  Ghostty removed. Config preserved at ~/.config/ghostty/"
}

install_zed() {
  # Zed — high-performance, GPU-accelerated, multiplayer code editor
  # Created by the makers of Atom and Tree-sitter. Built in Rust.
  # Config file: ~/.config/zed/settings.json
  # Docs: https://zed.dev/docs
  #
  # Official install script: installs to ~/.local/bin/zed and places a desktop
  # launcher at ~/.local/share/applications/zed.desktop. Self-updates on launch.
  # No system-wide apt repo — the script is the canonical install method on Linux.
  curl -fsSL --connect-timeout 15 --max-time 120 https://zed.dev/install.sh | sh \
    || log "  WARNING: Zed install failed"
}

remove_zed() {
  # Zed has no official uninstall script — remove the binary and desktop file manually.
  # The install script places files under ~/.local (user-local, not system-wide).
  rm -f ~/.local/bin/zed \
        ~/.local/share/applications/zed.desktop \
        ~/.local/share/icons/zed.png 2>/dev/null || true
  rm -rf ~/.local/lib/zed 2>/dev/null || true
  # Config is preserved deliberately — same approach as other editors
  log "  Zed removed. Config preserved at ~/.config/zed/"
}

install_neovim() {
  sudo snap install nvim --classic

  # luarocks: Lua package manager, required by some LazyVim plugins
  sudo apt-get install -y luarocks

  # tree-sitter-cli: required by Neovim / LazyVim for syntax tree parsing.
  # NOT available in apt — must be installed via npm.
  # If npm isn't on PATH yet (e.g. this step runs before mise/node is set up),
  # we warn and skip; install_mise() will retry once Node is available.
  if command -v npm &>/dev/null; then
    npm install -g tree-sitter-cli || true
  else
    log "  NOTE: tree-sitter-cli requires Node/npm (not yet installed)."
    log "        After Node is available, run: npm install -g tree-sitter-cli"
    log "        Or select 'mise' — it will install tree-sitter-cli automatically."
  fi

  # LazyVim starter config — skip if ~/.config/nvim already exists
  if [[ ! -d ~/.config/nvim ]]; then
    git clone https://github.com/LazyVim/starter ~/.config/nvim
    rm -rf ~/.config/nvim/.git
  else
    log "  ~/.config/nvim already exists — skipping LazyVim clone"
  fi
}

install_editors() {
  # Legacy bundled function — individual items (vscode, vscodium, sublime) are
  # now registered separately in the registry. This remains for compatibility.
  install_vscode
  install_vscodium
  install_sublime
}

install_browsers() {
  # Legacy bundled function — individual items (brave, chrome, firefox_dev, edge)
  # are now registered separately in the registry. This remains for compatibility.
  install_brave
  install_chrome
  install_firefox_dev
  install_edge
}


install_docker() {
  sudo install -m 0755 -d /etc/apt/keyrings

  # apt_add_repo handles key fetch → repo write → apt-get update → install
  # as four guarded steps; aborts cleanly if any step fails or times out
  apt_add_repo \
    --name      "docker" \
    --key-url   "https://download.docker.com/linux/ubuntu/gpg" \
    --keyring   "/etc/apt/keyrings/docker.asc" \
    --repo-line "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    --repo-file "/etc/apt/sources.list.d/docker.list" \
    --packages  "docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras" \
    || return 1

  # Add current user to the docker group (takes effect after re-login)
  sudo usermod -aG docker "$USER"

  # Cap container log size to avoid filling disk on long-running machines
  echo '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"5"}}' \
    | sudo tee /etc/docker/daemon.json > /dev/null

  # ── LazyDocker — version resolved at runtime from GitHub API ─────────────────
  local url
  url=$(github_latest "jesseduffield/lazydocker" "Linux_x86_64.tar.gz")
  if [[ -n "$url" ]]; then
    local tmp; tmp=$(mktemp -d)
    wget -q --tries=1 --connect-timeout=15 -O "$tmp/ld.tar.gz" "$url"
    tar -xf "$tmp/ld.tar.gz" -C "$tmp" lazydocker
    sudo install "$tmp/lazydocker" /usr/local/bin/lazydocker
    rm -rf "$tmp"
  else
    log "  WARNING: Could not resolve LazyDocker download URL"
  fi
}

install_lazygit() {
  # Version resolved at runtime from GitHub API — no hardcoded version
  local url
  url=$(github_latest "jesseduffield/lazygit" "Linux_x86_64.tar.gz")
  if [[ -n "$url" ]]; then
    local tmp; tmp=$(mktemp -d)
    wget -q --tries=1 --connect-timeout=15 -O "$tmp/lg.tar.gz" "$url"
    tar -xf "$tmp/lg.tar.gz" -C "$tmp" lazygit
    sudo install "$tmp/lazygit" /usr/local/bin/lazygit
    mkdir -p ~/.config/lazygit
    touch ~/.config/lazygit/config.yml
    rm -rf "$tmp"
  else
    log "  WARNING: Could not resolve LazyGit download URL"
  fi
}

install_mise() {
  # curl https://mise.run auto-detects distro and arch; always fetches latest
  curl -fsSL https://mise.run | sh

  local mise_bin="$HOME/.local/bin/mise"
  if [[ ! -x "$mise_bin" ]]; then
    log "  WARNING: mise binary not found after install"
    return 1
  fi

  # Use shims PATH injection so mise-managed tools are available in this
  # non-interactive script session without needing eval "$(mise activate)"
  export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

  "$mise_bin" use --global python@latest
  "$mise_bin" use --global node@lts
  "$mise_bin" use --global ruby@latest
  "$mise_bin" settings add idiomatic_version_file_enable_tools ruby,node

  # Append activation line to shell configs (idempotent — skips if already present)
  for rc in ~/.zshrc ~/.bashrc; do
    if [[ -f "$rc" ]] && ! grep -q 'mise activate' "$rc"; then
      echo 'eval "$(~/.local/bin/mise activate $(basename $SHELL))"' >> "$rc"
    fi
  done

  # Now that Node is available via mise, install tree-sitter-cli for Neovim.
  # This catches the case where neovim was selected but mise/node was not yet
  # installed when install_neovim() ran.
  if "$mise_bin" exec -- npm install -g tree-sitter-cli 2>/dev/null; then
    log "  tree-sitter-cli installed via mise-managed Node"
  fi
}

install_flatpak_apps() {
  sudo apt-get install -y flatpak gnome-software-plugin-flatpak
  flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo

  local apps=(
    "md.obsidian.Obsidian"
    "us.zoom.Zoom"
    "net.nokyan.Resources"
  )
  for app in "${apps[@]}"; do
    flatpak install -y --noninteractive flathub "$app" \
      || log "  WARNING: Flatpak install failed: $app"
  done
}

install_launcher() {
  # ── Albert — via OBS with auto-version fallback (see add_obs_repo above) ─────
  if add_obs_repo "home:manuelschneid3r" "albert"; then
    sudo apt-get update -y && sudo apt-get install -y albert \
      || log "  WARNING: albert not installable on $VERSION_ID yet"
  fi

  # ── ULauncher — PPA-based; may lag a few weeks on new Ubuntu releases ─────────
  sudo add-apt-repository -y universe
  sudo add-apt-repository -y ppa:agornostal/ulauncher
  sudo apt-get update -y && sudo apt-get install -y ulauncher \
    || log "  WARNING: ulauncher install failed (PPA may not support $VERSION_ID yet)"
}

install_lmstudio() {
  # LM Studio — .deb via lmstudio.ai's versioned redirect.
  # URL confirmed working: returns HTTP 302 → installers.lmstudio.ai/.../LM-Studio-x.y.z-x64.deb
  # Always serves the latest stable release; no hardcoded version needed.
  local tmp; tmp=$(mktemp -d)
  if wget -q --tries=1 --connect-timeout=15 -O "$tmp/lmstudio.deb" \
      "https://lmstudio.ai/download/latest/linux/x64?format=deb"; then
    sudo apt-get install -y "$tmp/lmstudio.deb" \
      || log "  WARNING: LM Studio .deb install failed"
  else
    log "  WARNING: Could not download LM Studio .deb"
  fi
  rm -rf "$tmp"
}

install_jan() {
  # Jan.ai — GitHub releases at janhq/jan provide a .deb for Debian/Ubuntu
  local url
  url=$(github_latest "janhq/jan" "_amd64.deb")
  if [[ -n "$url" ]]; then
    local tmp; tmp=$(mktemp -d)
    wget -q --tries=1 --connect-timeout=15 -O "$tmp/jan.deb" "$url"
    sudo apt-get install -y "$tmp/jan.deb" \
      || log "  WARNING: Jan.ai .deb install failed"
    rm -rf "$tmp"
  else
    log "  WARNING: Could not resolve Jan.ai .deb download URL"
  fi
}

install_chatbox() {
  # Chatbox AI — AppImage; requires libfuse2 on Ubuntu 24.04+
  # (Ubuntu 24.04 shipped fuse3 by default, dropping libfuse2)
  if version_gte "$VERSION_ID" "24.04"; then
    sudo apt-get install -y libfuse2t64 || sudo apt-get install -y libfuse2 || true
  else
    sudo apt-get install -y libfuse2 || true
  fi
  sudo add-apt-repository -y universe && sudo apt-get update -y

  local tmp; tmp=$(mktemp -d)
  if wget -q --tries=1 --connect-timeout=15 -O "$tmp/Chatbox.AppImage" "https://chatboxai.app/install_chatbox/linux"; then
    sudo mkdir -p /opt/ChatboxAi
    sudo install "$tmp/Chatbox.AppImage" /opt/ChatboxAi/ChatboxAi.AppImage

    # Download the official Chatbox icon from the app's own site
    sudo wget -q --timeout=15 -O /usr/share/icons/chatboxai.png \
      https://chatboxai.app/icon.png \
      || log "  NOTE: Could not download Chatbox icon — app will show a generic icon"

    mkdir -p ~/.local/share/applications
    # Electron app — --ozone-platform=wayland enables native Wayland rendering on 26.04+
    cat > ~/.local/share/applications/chatboxai.desktop << 'EOF'
[Desktop Entry]
Name=Chatbox AI
Comment=Chatbox AI Launcher
Exec=/opt/ChatboxAi/ChatboxAi.AppImage --ozone-platform=wayland --no-sandbox
Icon=/usr/share/icons/chatboxai.png
Terminal=false
Type=Application
Categories=Development;ArtificialIntelligence;
EOF
  else
    log "  WARNING: Could not download Chatbox AppImage"
  fi
  rm -rf "$tmp"
}

install_comms() {
  sudo snap install slack   || log "  WARNING: slack snap install failed"
  sudo snap install spotify || log "  WARNING: spotify snap install failed"

  # Zoom via Flatpak — more reliable than the .deb on newer Ubuntu releases
  flatpak install -y --noninteractive flathub us.zoom.Zoom 2>/dev/null \
    || log "  WARNING: Zoom Flatpak install failed"
}

install_1password() {
  # 1Password maintains a stable 'latest' .deb URL — no version pinning needed
  local tmp; tmp=$(mktemp -d)
  wget -q --tries=1 --connect-timeout=15 -O "$tmp/1password.deb" \
    https://downloads.1password.com/linux/debian/amd64/stable/1password-latest.deb
  sudo apt-get install -y "$tmp/1password.deb" \
    || log "  WARNING: 1Password .deb install failed"
  rm -rf "$tmp"
}

install_localsend() {
  local url
  url=$(github_latest "localsend/localsend" "linux-x86-64.deb")
  if [[ -n "$url" ]]; then
    local tmp; tmp=$(mktemp -d)
    wget -q --tries=1 --connect-timeout=15 -O "$tmp/localsend.deb" "$url"
    sudo apt-get install -y "$tmp/localsend.deb" \
      || log "  WARNING: LocalSend .deb install failed"
    rm -rf "$tmp"
  else
    log "  WARNING: Could not resolve LocalSend download URL"
  fi
}

install_pomodoro() {
  local url
  url=$(github_latest "roldanjr/pomatez" "linux-amd64.deb")
  if [[ -n "$url" ]]; then
    local tmp; tmp=$(mktemp -d)
    wget -q --tries=1 --connect-timeout=15 -O "$tmp/pomatez.deb" "$url"
    sudo apt-get install -y "$tmp/pomatez.deb" \
      || log "  WARNING: Pomatez .deb install failed"
    rm -rf "$tmp"
  else
    log "  WARNING: Could not resolve Pomatez download URL"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Gaming
# ─────────────────────────────────────────────────────────────────────────────

# Detect whether an NVIDIA GPU is present in this machine.
# Uses lspci (always available) with a PCI ID fallback via /sys.
# Returns 0 (true) if NVIDIA found, 1 (false) otherwise.
has_nvidia() {
  # lspci is the most reliable — covers discrete, MXM, and external eGPU
  if command -v lspci &>/dev/null; then
    lspci | grep -qi "NVIDIA" && return 0
  fi
  # Fallback: check /sys PCI device vendor IDs (0x10de = NVIDIA)
  grep -rqi "0x10de" /sys/bus/pci/devices/*/vendor 2>/dev/null && return 0
  return 1
}

install_nvidia_drivers() {
  # Guard: skip entirely if no NVIDIA GPU is detected
  if ! has_nvidia; then
    log "  No NVIDIA GPU detected — skipping driver install."
    log "  If you have an NVIDIA card and this is wrong, check 'lspci | grep -i nvidia'."
    return 0
  fi

  log "  NVIDIA GPU detected."
  sudo apt-get update -y
  sudo apt-get install -y ubuntu-drivers-common pciutils

  # Show what ubuntu-drivers sees before installing anything
  log "  Available drivers (ubuntu-drivers devices):"
  ubuntu-drivers devices 2>&1 | tee -a "$LOG_FILE" || true

  # ubuntu-drivers install picks the production branch (580 as of 2026).
  # This is intentional — 580 is the WHQL-equivalent stable branch.
  # For RTX 50-series (Blackwell) cards that need 595, the user can run:
  #   sudo ubuntu-drivers install nvidia:595
  # after setup completes.
  sudo ubuntu-drivers install \
    || log "  WARNING: ubuntu-drivers install failed — try manually: sudo ubuntu-drivers install nvidia:580"

  # Ensure 32-bit Vulkan libraries are present for DXVK / 32-bit game support.
  # dpkg --add-architecture i386 is idempotent.
  sudo dpkg --add-architecture i386
  sudo apt-get update -y
  sudo apt-get install -y \
    vulkan-tools \
    libvulkan1 libvulkan1:i386 \
    || log "  WARNING: Vulkan 32-bit libs install failed"

  log "  NOTE: A reboot is required before the NVIDIA driver takes effect."
}

install_gaming_stack() {
  # Core gaming compatibility layer — Steam, Proton, 32-bit support
  # Enable i386 (32-bit) architecture — required for Steam and many game libraries
  sudo dpkg --add-architecture i386
  sudo apt-get update -y

  # ── Steam ────────────────────────────────────────────────────────────────────
  # Valve explicitly recommends their official .deb over snap (which "has a lot
  # of issues") and over Ubuntu's universe package (which lags behind).
  # The .deb self-bootstraps: it downloads and installs the latest Steam client
  # into ~/.steam on first launch, and registers Valve's apt repo for future updates.
  #
  # Remove any manually-written steam.list from previous script runs — Steam's .deb
  # writes its own repo file (steam-stable.list) and having both causes apt warnings
  # about "configured multiple times".
  sudo rm -f /etc/apt/sources.list.d/steam.list
  local tmp_steam; tmp_steam=$(mktemp -d)
  if wget -q --tries=1 --connect-timeout=15 -O "$tmp_steam/steam.deb" \
      "https://cdn.akamai.steamstatic.com/client/installer/steam.deb"; then
    sudo apt-get install -y "$tmp_steam/steam.deb" \
      || log "  WARNING: Steam .deb install failed"
  else
    log "  WARNING: Could not download Steam .deb — trying apt universe fallback"
    sudo apt-get install -y steam-installer \
      || log "  WARNING: Steam apt fallback also failed"
  fi
  rm -rf "$tmp_steam"

  # ── Vulkan + 32-bit libs (needed for DXVK inside Proton) ─────────────────────
  sudo apt-get install -y \
    vulkan-tools \
    libvulkan1 libvulkan1:i386 \
    || log "  WARNING: Vulkan libs install failed"

  # ── GameMode — CPU/IO performance daemon from Feral Interactive ───────────────
  # Switches CPU governor to 'performance' while a game is running, then reverts.
  # Steam launch option: gamemoderun %command%
  sudo apt-get install -y gamemode libgamemode0 libgamemodeauto0 \
    || log "  WARNING: gamemode install failed"

  # ── MangoHud — in-game FPS / GPU / CPU overlay (like MSI Afterburner on Linux)
  # Steam launch option: mangohud %command%
  # Combined with GameMode: gamemoderun mangohud %command%
  sudo apt-get install -y mangohud \
    || log "  WARNING: mangohud install failed"

  # ── ProtonPlus — GUI manager for GE-Proton and other Proton forks ─────────────
  # GTK4/Libadwaita, GNOME-native feel. Manages tools for Steam, Lutris, Heroic.
  # Alternative: ProtonUp-Qt (Qt-based, same function) — flatpak id: net.davidotek.pupgui2
  flatpak install -y --noninteractive flathub com.vysp3r.ProtonPlus \
    || log "  WARNING: ProtonPlus Flatpak install failed"

  # ── Lutris — game manager for GOG, Epic, Battle.net, direct downloads ─────────
  # Provides community-maintained install scripts that configure Wine/DXVK per game.
  flatpak install -y --noninteractive flathub net.lutris.Lutris \
    || log "  WARNING: Lutris Flatpak install failed"

  # ── Heroic Games Launcher — native Linux client for Epic and GOG libraries ─────
  # Better GOG integration than Lutris; deep GE-Proton support.
  flatpak install -y --noninteractive flathub com.heroicgameslauncher.hgl \
    || log "  WARNING: Heroic Flatpak install failed"

  # ── vm.swappiness tweak — keeps game data in RAM longer, reduces stutter ───────
  # Default is 60; 10 is a widely recommended gaming value on machines with ≥16GB RAM.
  # Written to /etc/sysctl.d/ so it persists across reboots.
  if ! grep -q 'vm.swappiness' /etc/sysctl.d/99-gaming.conf 2>/dev/null; then
    echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-gaming.conf > /dev/null
    sudo sysctl --system > /dev/null
  fi

  log "  Gaming stack installed."
  log "  Recommended Steam launch options:"
  log "    Standard:              gamemoderun mangohud %command%"
  log "    With DLSS (RTX cards): PROTON_ENABLE_NVAPI=1 DXVK_ENABLE_NVAPI=1 gamemoderun mangohud %command%"
}

install_xbox_controller() {
  # Install support for Xbox controllers over all three connection methods.
  # USB wired works out of the box via the kernel's built-in xpad driver — no setup needed.

  sudo apt-get install -y \
    dkms \
    "linux-headers-$(uname -r)" \
    bluez bluez-tools \
    evtest \
    || log "  WARNING: Some controller dependencies failed to install"

  # ── uhid kernel module — required for Xbox controller firmware 5.x over Bluetooth
  # uhid creates user-space HID devices; without it, newer Xbox controllers won't
  # pair correctly over Bluetooth. Load it now and persist across reboots.
  if ! lsmod | grep -q "^uhid"; then
    sudo modprobe uhid 2>/dev/null \
      && log "  uhid module loaded." \
      || log "  WARNING: Could not load uhid module — Bluetooth firmware 5.x support may not work"
  fi
  if ! grep -q "^uhid" /etc/modules 2>/dev/null; then
    echo "uhid" | sudo tee -a /etc/modules > /dev/null
    log "  uhid added to /etc/modules (loads on boot)."
  fi

  # ── xpadneo — advanced Bluetooth driver for Xbox One / Series X|S ────────────
  # Handles Xbox One and Xbox Series X|S controllers over Bluetooth (BLE).
  # Adds proper rumble, trigger effects, paddle buttons on Elite Series 2,
  # and profile switching. Installed via DKMS so it rebuilds on kernel upgrades.
  #
  # Two important fixes vs a naive git clone + install:
  # 1. Do NOT use --depth=1 (shallow clone). xpadneo's install.sh calls
  #    'git describe --tags' to derive its version. A shallow clone has no tags,
  #    causing "fatal: No names found, cannot describe anything" → build failure.
  # 2. sudo runs git in a different user context. git 2.35.2+ blocks operations
  #    in directories not owned by root. We mark the clone dir as safe before
  #    running install.sh as root.
  if [[ -d /usr/src/hid-xpadneo-* ]] || dkms status 2>/dev/null | grep -q xpadneo; then
    log "  xpadneo already installed — skipping"
  else
    local tmp; tmp=$(mktemp -d)
    git clone https://github.com/atar-axis/xpadneo.git "$tmp/xpadneo"
    sudo git config --global --add safe.directory "$tmp/xpadneo"
    (cd "$tmp/xpadneo" && sudo ./install.sh) \
      || log "  WARNING: xpadneo install failed"
    sudo git config --global --unset safe.directory "$tmp/xpadneo" 2>/dev/null || true
    rm -rf "$tmp"
  fi

  # ── xone — driver for Xbox Wireless Adapter (the USB dongle) ─────────────────
  # Required only when using Microsoft's proprietary wireless USB dongle instead
  # of Bluetooth. Replaces the built-in xpad driver for GIP-protocol devices.
  # NOTE: xone disables xpad; if you also use Xbox 360 controllers you'll need
  # to separately install xpad-noone from: https://github.com/medusalix/xpad-noone
  if dkms status 2>/dev/null | grep -q xone; then
    log "  xone already installed — skipping"
  else
    local tmp2; tmp2=$(mktemp -d)
    # dlundqvist/xone is the actively maintained fork of the original medusalix/xone
    git clone https://github.com/dlundqvist/xone.git "$tmp2/xone"
    sudo git config --global --add safe.directory "$tmp2/xone"
    (cd "$tmp2/xone" && sudo ./install.sh --skip-disclaimer) \
      || log "  WARNING: xone install failed"
    sudo git config --global --unset safe.directory "$tmp2/xone" 2>/dev/null || true
    rm -rf "$tmp2"
  fi

  log "  Controller setup complete."
  log "  USB wired:        plug in and it works (kernel xpad driver)"
  log "  Bluetooth:        pair via GNOME Bluetooth or bluetoothctl"
  log "  Wireless dongle:  plug in dongle, press Xbox button on controller"
  log "  NOTE: If Bluetooth pairing is unreliable, update controller"
  log "        firmware first using Xbox Accessories on Windows."
}

install_wine_stack() {
  # ── Wine — Windows application compatibility layer ────────────────────────────
  # We use the official WineHQ repo (winehq-stable) rather than Ubuntu's universe
  # package, which lags behind. winehq-stable ships Wine 11+ on Ubuntu 26.04.
  # --install-recommends is REQUIRED — skipping it gives a broken 64-bit-only
  # install that can't run most Windows apps (pulls needed 32-bit counterparts).

  # Enable i386 architecture first — Wine 32-bit deps won't resolve without it
  sudo dpkg --add-architecture i386
  sudo apt-get update -y
  sudo mkdir -p /etc/apt/keyrings

  # apt_add_repo guards each step: key fetch → repo file → apt update → install
  # If the key fetch times out or fails, apt-get install will NOT be attempted.
  # Note: WineHQ uses DEB822 .sources format; we write it manually after the key.
  log "  [wine] Fetching WineHQ GPG key..."
  if ! curl -fsSL --connect-timeout 15 --max-time 30 \
      https://dl.winehq.org/wine-builds/winehq.key \
      | sudo gpg --dearmor -o /etc/apt/keyrings/winehq-archive.key; then
    log "  WARNING: [wine] GPG key fetch failed — aborting Wine install"
    sudo rm -f /etc/apt/keyrings/winehq-archive.key
    return 1
  fi
  if [[ ! -s /etc/apt/keyrings/winehq-archive.key ]]; then
    log "  WARNING: [wine] Keyring file empty — aborting Wine install"
    sudo rm -f /etc/apt/keyrings/winehq-archive.key
    return 1
  fi
  log "  [wine] GPG key OK."

  # DEB822 .sources format — compatible with APT 3.x on Ubuntu 26.04+
  printf 'Types: deb\nURIs: https://dl.winehq.org/wine-builds/ubuntu/\nSuites: %s\nComponents: main\nSigned-By: /etc/apt/keyrings/winehq-archive.key\n' \
    "$CODENAME" \
    | sudo tee /etc/apt/sources.list.d/winehq.sources > /dev/null \
    || { log "  WARNING: [wine] Could not write repo file"; return 1; }

  sudo apt-get update -y \
    || { log "  WARNING: [wine] apt-get update failed after adding WineHQ repo"; return 1; }

  DEBIAN_FRONTEND=noninteractive sudo -E apt-get install -y \
    --install-recommends winehq-stable \
    || log "  WARNING: winehq-stable install failed — falling back to Ubuntu's wine"

  # Fallback: Ubuntu's universe wine if WineHQ repo doesn't support this codename yet
  if ! command -v wine &>/dev/null; then
    sudo apt-get install -y wine wine32:i386 wine64 \
      || log "  WARNING: Wine fallback also failed"
  fi

  # ── Winetricks — installs Windows runtimes inside Wine prefixes ───────────────
  # Used to install VC++ redistributables, .NET, DirectX, and other deps that
  # many Windows games and launchers silently require.
  # The apt version is often outdated; fetch latest from GitHub instead.
  local wt_latest
  wt_latest=$(github_latest "Winetricks/winetricks" "winetricks$")
  if [[ -n "$wt_latest" ]]; then
    wget -q --timeout=30 -O /tmp/winetricks "$wt_latest"
    chmod +x /tmp/winetricks
    sudo mv /tmp/winetricks /usr/local/bin/winetricks
    log "  Winetricks installed from GitHub (latest)"
  else
    sudo apt-get install -y winetricks \
      || log "  WARNING: Winetricks install failed"
  fi

  # ── Bottles — graphical Wine prefix manager ───────────────────────────────────
  # Officially distributed as Flatpak only — no .deb or apt package exists.
  flatpak install -y --noninteractive flathub com.usebottles.bottles \
    || log "  WARNING: Bottles Flatpak install failed"

  log "  Wine stack installed."
  log "  Quick start: run 'wine program.exe' or launch Bottles from the app menu."
  log "  Common Winetricks packages: winetricks vcrun2022 dotnet48 corefonts dxvk"
}

install_gaming_extras() {
  # ── scx-scheds — sched-ext BPF CPU schedulers ────────────────────────────────
  # sched-ext (merged into Linux 6.12+, which Ubuntu 25.04+ ships) lets you swap
  # the CPU scheduler at runtime without rebooting. Gaming-relevant schedulers:
  #   scx_lavd  — latency-aware; best for gaming (lower frame-time variance)
  #   scx_bpfland — best for mixed gaming + background workloads
  #   scx_flash  — soft real-time; audio/multimedia workloads
  # Install via the upstream PPA (Ubuntu 25.04+); skip on older kernels.
  if version_gte "$VERSION_ID" "25.04"; then
    sudo add-apt-repository -y --enable-source ppa:arighi/sched-ext 2>/dev/null || true
    sudo apt-get update -y
    sudo apt-get install -y scx \
      || log "  WARNING: scx-scheds install failed (kernel may not have sched-ext support)"
    # Enable and start the scx service with the gaming-friendly lavd scheduler
    if command -v systemctl &>/dev/null && systemctl list-unit-files scx.service &>/dev/null; then
      sudo sed -i 's/SCX_SCHEDULER=.*/SCX_SCHEDULER=scx_lavd/' /etc/default/scx 2>/dev/null || true
      sudo systemctl enable --now scx 2>/dev/null || true
      log "  scx_lavd scheduler enabled (gaming-optimised, low frame-time variance)."
      log "  To switch scheduler: sudo sed -i 's/SCX_SCHEDULER=.*/SCX_SCHEDULER=scx_bpfland/' /etc/default/scx && sudo systemctl restart scx"
    fi
  else
    log "  NOTE: scx-scheds requires Ubuntu 25.04+ (kernel 6.12+) — skipping on $VERSION_ID"
  fi

  # ── vkBasalt — Vulkan post-processing injection layer ─────────────────────────
  # Injects visual enhancements into any Vulkan game without modifying the game:
  # CAS (Contrast Adaptive Sharpening), SMAA, FXAA, colour LUT grading.
  # Steam launch option to enable globally: ENABLE_VKBASALT=1 %command%
  # Installed as a Flatpak Vulkan layer, alongside the MangoHud layer.
  flatpak install -y --noninteractive flathub \
    org.freedesktop.Platform.VulkanLayer.vkBasalt \
    org.freedesktop.Platform.VulkanLayer.MangoHud \
    || log "  WARNING: vkBasalt/MangoHud Flatpak layer install failed"

  # ── GOverlay — GUI to configure MangoHud and vkBasalt ─────────────────────────
  # Lets you visually configure MangoHud overlays and vkBasalt effects without
  # editing config files. Saves to ~/.config/MangoHud/MangoHud.conf automatically.
  flatpak install -y --noninteractive flathub io.github.benjamimgois.goverlay \
    || log "  WARNING: GOverlay Flatpak install failed"

  # ── OpenRGB — open-source RGB lighting control ────────────────────────────────
  # Controls RGB on motherboards, GPUs, RAM, keyboards, mice, and other peripherals
  # without needing manufacturer software (no iCUE, no Armory Crate, etc.).
  flatpak install -y --noninteractive flathub org.openrgb.OpenRGB \
    || log "  WARNING: OpenRGB Flatpak install failed"

  # ── Input Remapper — remap any input device to anything ──────────────────────
  # Maps controller buttons, keyboard keys, and mouse buttons to keyboard/mouse
  # actions, macros, or scripts. Works on Wayland. Useful for games with poor
  # native controller support, or for remapping extra mouse/keyboard buttons.
  # No Flatpak exists — installed via .deb from GitHub releases.
  local ir_url
  ir_url=$(github_latest "sezanzeb/input-remapper" "_amd64.deb")
  if [[ -n "$ir_url" ]]; then
    local tmp; tmp=$(mktemp -d)
    wget -q --tries=1 --connect-timeout=15 -O "$tmp/input-remapper.deb" "$ir_url"
    sudo apt-get install -y "$tmp/input-remapper.deb" \
      && sudo systemctl enable --now input-remapper \
      || log "  WARNING: Input Remapper install failed"
    rm -rf "$tmp"
  else
    log "  WARNING: Could not resolve Input Remapper download URL"
  fi

  # ── AntiMicroX — GUI gamepad mapper ──────────────────────────────────────────
  # Maps gamepad buttons/joysticks to keyboard keys, mouse moves, scripts, or macros.
  # Useful for games with no gamepad support at all, or for remapping controller
  # layouts. Supports Wayland. Available on Flathub.
  flatpak install -y --noninteractive flathub io.github.antimicrox.antimicrox \
    || log "  WARNING: AntiMicroX Flatpak install failed"

  # ── jstest-gtk — graphical controller testing and calibration tool ────────────
  # Lets you visually test a connected controller: see every axis value in
  # real time, test rumble/force feedback, and calibrate deadzones. Useful
  # for verifying xpadneo or xone installed correctly.
  sudo apt-get install -y jstest-gtk \
    || log "  WARNING: jstest-gtk install failed"

  # ── nvidia-vaapi-driver — NVIDIA hardware video decode via VAAPI ──────────────
  # Enables NVDEC hardware acceleration for video playback in Firefox, VLC, MPV.
  # Only meaningful if an NVIDIA GPU is present; silently skipped otherwise.
  if has_nvidia; then
    sudo apt-get install -y nvidia-vaapi-driver \
      || log "  WARNING: nvidia-vaapi-driver install failed"
    log "  nvidia-vaapi-driver installed: hardware video decode enabled for Firefox, VLC, MPV."
  fi

  # ── Waydroid — run Android apps natively on the Linux desktop ─────────────────
  # Boots a full Android (LineageOS-based) system in a Linux container with direct
  # hardware access. Android apps appear as native windows in the GNOME app menu.
  # Requires Wayland (not Xorg) — Ubuntu 26.04 is Wayland-only, so this fits.
  # First launch opens an initialisation dialog where you choose:
  #   Vanilla — no Google services (use F-Droid for apps)
  #   GApps   — includes Google Play Store (requires registering device with Google)
  # NOTE: binder_linux kernel module is required; Ubuntu 26.04's kernel ships it.
  sudo apt-get install -y curl ca-certificates
  if curl -fsSL --connect-timeout 15 --max-time 30 https://repo.waydro.id/waydroid.gpg \
      | sudo tee /usr/share/keyrings/waydroid.gpg > /dev/null; then
    # The installer script detects the codename; pass it explicitly as fallback
    # in case 26.04 (resolute) isn't in the supported list yet — use noble as fallback
    local waydroid_suite="$CODENAME"
    local supported_suites="focal jammy noble plucky questing bookworm bullseye trixie sid"
    if ! echo "$supported_suites" | grep -qw "$waydroid_suite"; then
      log "  Waydroid: $waydroid_suite not yet in supported list — using 'noble' as fallback"
      waydroid_suite="noble"
    fi
    echo "deb [signed-by=/usr/share/keyrings/waydroid.gpg] https://repo.waydro.id/ ${waydroid_suite} main" \
      | sudo tee /etc/apt/sources.list.d/waydroid.list > /dev/null
    sudo apt-get update -y
    # apt-get install may return non-zero due to postinstall service start warnings
    # even when the package installs correctly — check the binary instead
    sudo apt-get install -y waydroid || true
    if command -v waydroid &>/dev/null; then
      log "  Waydroid installed. Launch from the app menu to initialise the Android image."
      log "  Choose 'GApps' for Google Play or 'Vanilla' for F-Droid (open-source apps)."
    else
      log "  WARNING: Waydroid install failed — binary not found after install attempt"
    fi
  else
    log "  WARNING: Could not fetch Waydroid GPG key — skipping"
  fi
}

install_gnome() {
  # Guard: gsettings keys and gnome-shell extensions are GNOME-specific.
  # They will error silently or do nothing under KDE, XFCE, Sway, etc.
  local current_de="${XDG_CURRENT_DESKTOP:-}"
  if [[ "$current_de" != *"GNOME"* ]]; then
    log "  WARNING: Current desktop is '${current_de:-unknown}', not GNOME."
    log "           Extensions and gsettings require a GNOME session — skipping."
    log "           Log into GNOME and re-run this step to apply them."
    return 0
  fi

  sudo apt-get install -y \
    gnome-tweaks gnome-shell-extension-manager \
    gnome-sushi pipx

  # gnome-extensions-cli (gext) — lets us install extensions from the CLI
  if ! command -v gext &>/dev/null; then
    pipx install gnome-extensions-cli --system-site-packages || true
    export PATH="$HOME/.local/bin:$PATH"
  fi

  local extensions=(
    "tactile@lundal.io"               # keyboard-driven tiling layout
    "blur-my-shell@aunetx"            # blur effect on overview / dash
    "space-bar@luchrioh"              # workspace names in the top bar
    "tophat@fflewddur.github.io"      # CPU / RAM / network monitor in top bar
    "AlphabeticalAppGrid@stuarthayhurst"
    "caffeine@patapon.info"           # prevent screen lock on demand
  )
  for ext in "${extensions[@]}"; do
    gext install "$ext" 2>/dev/null \
      || log "  WARNING: Could not install extension: $ext"
  done

  # Tactile requires its gsettings schema to be compiled before we can write values
  local tactile_schema="$HOME/.local/share/gnome-shell/extensions/tactile@lundal.io/schemas/org.gnome.shell.extensions.tactile.gschema.xml"
  if [[ -f "$tactile_schema" ]]; then
    sudo cp "$tactile_schema" /usr/share/glib-2.0/schemas/
    sudo glib-compile-schemas /usr/share/glib-2.0/schemas/

    # Tiling layout: 3 columns (ratio 1:2:1), 2 rows, 32 px gap
    gsettings set org.gnome.shell.extensions.tactile col-0 1
    gsettings set org.gnome.shell.extensions.tactile col-1 2
    gsettings set org.gnome.shell.extensions.tactile col-2 1
    gsettings set org.gnome.shell.extensions.tactile col-3 0
    gsettings set org.gnome.shell.extensions.tactile row-0 1
    gsettings set org.gnome.shell.extensions.tactile row-1 1
    gsettings set org.gnome.shell.extensions.tactile gap-size 32
  fi

  # Click a focused dock icon to minimise/restore (macOS-style behaviour)
  gsettings set org.gnome.shell.extensions.dash-to-dock click-action 'minimize' \
    2>/dev/null || true
}

install_tmux() {
  sudo apt-get install -y tmux yq

  # TPM — Tmux Plugin Manager; plugins are installed on first tmux launch
  if [[ ! -d ~/.tmux/plugins/tpm ]]; then
    git clone --depth=1 https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
  fi

  # Copy tmux config from script directory if present
  [[ -f "$SCRIPT_DIR/.tmux.conf" ]] && cp "$SCRIPT_DIR/.tmux.conf" ~/
}

install_dotfiles() {
  local missing=()

  if [[ -f "$SCRIPT_DIR/.my.zsh" ]]; then
    cp "$SCRIPT_DIR/.my.zsh" ~/
    # Append z4h source line to .zshrc (idempotent — skips if already present)
    if [[ -f "$HOME/.zshrc" ]]; then
      grep -qxF 'z4h source ~/.my.zsh' ~/.zshrc \
        || echo 'z4h source ~/.my.zsh' >> ~/.zshrc
    fi
  else
    missing+=(".my.zsh")
  fi

  if [[ -f "$SCRIPT_DIR/.tmux.conf" ]]; then
    cp "$SCRIPT_DIR/.tmux.conf" ~/
  else
    missing+=(".tmux.conf")
  fi

  if [[ -f "$SCRIPT_DIR/alacritty.toml" ]]; then
    mkdir -p ~/.config/alacritty
    cp "$SCRIPT_DIR/alacritty.toml" ~/.config/alacritty/
  else
    missing+=("alacritty.toml")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log "  WARNING: The following dotfiles were not found beside this script"
    log "           and could not be copied: ${missing[*]}"
    log "           Expected location: $SCRIPT_DIR/"
  fi
}

install_fastfetch() {
  # fastfetch landed in Ubuntu's own repos from 24.04 onward;
  # fall back to the upstream PPA for older releases
  if version_gte "$VERSION_ID" "24.04"; then
    sudo apt-get install -y fastfetch 2>/dev/null || {
      sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
      sudo apt-get update -y && sudo apt-get install -y fastfetch
    }
  else
    sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
    sudo apt-get update -y && sudo apt-get install -y fastfetch
  fi
}

configure_git() {
  git config --global init.defaultBranch main
  git config --global alias.gh 'config user.email "mhakeem@users.noreply.github.com"'
  git config --global user.name "mhakeem"
}

# ─────────────────────────────────────────────────────────────────────────────
# Selection menu
# ─────────────────────────────────────────────────────────────────────────────
remove_base() {
  log "  SKIPPED: Base packages are shared system dependencies."
  log "           Removing them could break other software."
  log "           If you need to clean up, run: sudo apt autoremove"
}

remove_zsh() {
  sudo chsh -s "$(which bash)" "$USER"
  sudo apt-get purge -y zsh fonts-font-awesome || true
  sudo apt-get autoremove -y
  rm -rf ~/.config/zsh ~/.zshrc ~/.p10k.zsh ~/.zsh_history \
         ~/.local/share/z4h ~/.cache/zsh 2>/dev/null || true
  log "  Zsh removed. Shell restored to bash. Log out and back in to apply."
}

remove_fonts() {
  rm -rf ~/.local/share/fonts/Monaspace 2>/dev/null || true
  find ~/.local/share/fonts \
    \( -name "MesloLGS*" -o -name "iAWriterMono*" \
    -o -name "FiraMono*" -o -name "JetBrainsMono*" \
    -o -name "CaskaydiaMono*" \) -delete 2>/dev/null || true
  fc-cache -f
  log "  Fonts removed and font cache refreshed."
}

remove_terminal_tools() {
  sudo apt-get purge -y \
    fzf ripgrep bat eza zoxide plocate btop tmux alacritty \
    fd-find tldr || true
  sudo apt-get autoremove -y
  sudo snap remove zellij 2>/dev/null || true
  rm -rf ~/.config/alacritty 2>/dev/null || true
  log "  Terminal tools removed."
}

remove_neovim() {
  sudo snap remove nvim 2>/dev/null || true
  sudo apt-get purge -y luarocks || true
  sudo apt-get autoremove -y
  rm -rf ~/.config/nvim ~/.local/share/nvim ~/.cache/nvim 2>/dev/null || true
  log "  Neovim and LazyVim config removed."
}

remove_editors() {
  sudo apt-get purge -y code codium sublime-text sublime-merge || true
  sudo apt-get autoremove -y
  sudo rm -f \
    /etc/apt/sources.list.d/vscode.list \
    /etc/apt/sources.list.d/vscodium.list \
    /etc/apt/sources.list.d/sublime-text.sources \
    /etc/apt/keyrings/packages.microsoft.gpg \
    /usr/share/keyrings/vscodium-archive-keyring.gpg \
    /etc/apt/keyrings/sublimehq-pub.asc
  sudo apt-get update -y
  log "  Editors removed."
}

remove_browsers() {
  sudo apt-get purge -y brave-browser microsoft-edge-stable \
    google-chrome-stable || true
  sudo apt-get autoremove -y
  sudo rm -f \
    /etc/apt/sources.list.d/brave-browser-release.list \
    /etc/apt/sources.list.d/microsoft-edge.list \
    /usr/share/keyrings/brave-browser-archive-keyring.gpg \
    /usr/share/keyrings/microsoft-edge.gpg
  sudo rm -rf /opt/firefox /usr/local/bin/firefox-dev \
    ~/.local/share/applications/firefox-dev.desktop
  sudo apt-get update -y
  log "  Browsers removed."
}

remove_docker() {
  log "  WARNING: This will remove Docker AND ALL containers, images, volumes."
  if whiptail --title "Remove Docker" \
    --yesno "Remove Docker and ALL containers/images/volumes?\n\nThis CANNOT be undone — data will be lost." \
    10 62; then
    sudo systemctl stop docker 2>/dev/null || true
    sudo apt-get purge -y docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || true
    sudo apt-get autoremove -y
    sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker
    sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
    sudo gpasswd -d "$USER" docker 2>/dev/null || true
    sudo rm -f /usr/local/bin/lazydocker
    sudo apt-get update -y
    log "  Docker removed."
  else
    log "  Docker removal cancelled by user."
  fi
}

remove_lazygit() {
  sudo rm -f /usr/local/bin/lazygit
  rm -rf ~/.config/lazygit 2>/dev/null || true
  log "  LazyGit removed."
}

remove_mise() {
  rm -rf ~/.local/share/mise ~/.local/bin/mise \
         ~/.config/mise ~/.cache/mise 2>/dev/null || true
  for rc in ~/.zshrc ~/.bashrc; do
    [[ -f "$rc" ]] && sed -i '/mise activate/d' "$rc" || true
  done
  log "  mise removed. Runtimes (Python/Node/Ruby) managed by mise are also gone."
}

remove_flatpak_apps() {
  flatpak uninstall -y --noninteractive \
    md.obsidian.Obsidian us.zoom.Zoom net.nokyan.Resources 2>/dev/null || true
  log "  Flatpak apps removed."
}

remove_launcher() {
  sudo apt-get purge -y albert ulauncher || true
  sudo apt-get autoremove -y
  sudo rm -f /etc/apt/sources.list.d/albert.list \
    /etc/apt/trusted.gpg.d/home--manuelschneid3r.gpg
  sudo add-apt-repository -r -y ppa:agornostal/ulauncher 2>/dev/null || true
  sudo apt-get update -y
  log "  Albert and ULauncher removed."
}

remove_nvidia() {
  # Removing NVIDIA drivers from a live GUI session can black-screen the machine.
  # We refuse to automate this and instead write clear instructions to the log.
  log "  WARNING: NVIDIA driver removal is not automated — see instructions below."
  log "  To remove safely:"
  log "    1. Log out of your desktop session"
  log "    2. Switch to a TTY: Ctrl+Alt+F3"
  log "    3. sudo apt purge ~nnvidia"
  log "    4. sudo apt autoremove"
  log "    5. sudo reboot"
  whiptail --title "NVIDIA — Manual Removal Required" --msgbox \
    "NVIDIA driver removal cannot be automated safely from a live session.\n\nInstructions written to:\n$LOG_FILE\n\nShort version:\n  1. Log out\n  2. Ctrl+Alt+F3 (TTY)\n  3. sudo apt purge ~nnvidia\n  4. sudo apt autoremove\n  5. sudo reboot" \
    18 62
}

remove_gaming() {
  sudo apt-get purge -y gamemode libgamemode0 libgamemodeauto0 mangohud || true
  sudo apt-get autoremove -y
  flatpak uninstall -y --noninteractive \
    com.vysp3r.ProtonPlus net.lutris.Lutris \
    com.heroicgameslauncher.hgl 2>/dev/null || true
  sudo apt-get purge -y steam steam-launcher 2>/dev/null || true
  sudo rm -f /etc/apt/sources.list.d/steam*.list /usr/share/keyrings/steam.gpg
  sudo rm -f /etc/sysctl.d/99-gaming.conf
  sudo sysctl -w vm.swappiness=60 >/dev/null 2>&1 || true
  sudo apt-get update -y
  log "  Gaming stack removed. Steam library data in ~/.steam is preserved."
}

remove_wine_stack() {
  sudo apt-get purge -y winehq-stable wine wine32 wine64 winetricks || true
  sudo apt-get autoremove -y
  sudo rm -f /usr/local/bin/winetricks \
    /etc/apt/sources.list.d/winehq.sources \
    /etc/apt/keyrings/winehq-archive.key
  flatpak uninstall -y --noninteractive com.usebottles.bottles 2>/dev/null || true
  sudo apt-get update -y
  log "  Wine stack removed. Wine prefix data in ~/.wine is preserved."
}

remove_gaming_extras() {
  sudo systemctl stop scx 2>/dev/null || true
  sudo systemctl disable scx 2>/dev/null || true
  sudo apt-get purge -y scx || true
  sudo add-apt-repository -r -y ppa:arighi/sched-ext 2>/dev/null || true
  flatpak uninstall -y --noninteractive \
    org.freedesktop.Platform.VulkanLayer.vkBasalt \
    org.freedesktop.Platform.VulkanLayer.MangoHud \
    io.github.benjamimgois.goverlay \
    org.openrgb.OpenRGB \
    io.github.antimicrox.antimicrox 2>/dev/null || true
  sudo systemctl stop input-remapper 2>/dev/null || true
  sudo systemctl disable input-remapper 2>/dev/null || true
  sudo apt-get purge -y input-remapper jstest-gtk || true
  sudo apt-get autoremove -y
  if command -v waydroid &>/dev/null; then
    sudo waydroid container stop 2>/dev/null || true
    sudo apt-get purge -y waydroid || true
    sudo rm -rf /var/lib/waydroid ~/.local/share/waydroid \
      /etc/apt/sources.list.d/waydroid.list \
      /usr/share/keyrings/waydroid.gpg
  fi
  sudo apt-get update -y
  log "  Gaming extras removed."
}

remove_controller() {
  # xpadneo — re-clone to get the uninstall script (deleted after install)
  if dkms status 2>/dev/null | grep -q xpadneo; then
    local tmp; tmp=$(mktemp -d)
    git clone https://github.com/atar-axis/xpadneo.git "$tmp/xpadneo"
    sudo git config --global --add safe.directory "$tmp/xpadneo"
    (cd "$tmp/xpadneo" && sudo ./uninstall.sh) || {
      local ver; ver=$(dkms status | grep xpadneo | grep -oP '\d+\.\d+\.\d+' | head -1)
      [[ -n "$ver" ]] && sudo dkms remove "hid-xpadneo/$ver" --all 2>/dev/null || true
    }
    sudo git config --global --unset safe.directory "$tmp/xpadneo" 2>/dev/null || true
    rm -rf "$tmp"
  fi
  # xone — same pattern
  if dkms status 2>/dev/null | grep -q xone; then
    local tmp2; tmp2=$(mktemp -d)
    git clone https://github.com/dlundqvist/xone.git "$tmp2/xone"
    sudo git config --global --add safe.directory "$tmp2/xone"
    (cd "$tmp2/xone" && sudo ./uninstall.sh --skip-disclaimer) || true
    sudo git config --global --unset safe.directory "$tmp2/xone" 2>/dev/null || true
    rm -rf "$tmp2"
  fi
  sudo apt-get purge -y evtest jstest-gtk || true
  sudo apt-get autoremove -y
  log "  Controller drivers removed."
}

remove_lmstudio() {
  sudo apt-get purge -y lmstudio || true
  sudo apt-get autoremove -y
  log "  LM Studio removed. Model files in ~/.lmstudio are preserved."
}

remove_jan() {
  sudo apt-get purge -y jan || true
  sudo apt-get autoremove -y
  log "  Jan.ai removed."
}

remove_chatbox() {
  sudo rm -f /opt/ChatboxAi/ChatboxAi.AppImage \
    ~/.local/share/applications/chatboxai.desktop
  sudo rmdir /opt/ChatboxAi 2>/dev/null || true
  log "  Chatbox AI removed."
}

remove_comms() {
  sudo snap remove slack 2>/dev/null || true
  sudo snap remove spotify 2>/dev/null || true
  flatpak uninstall -y --noninteractive us.zoom.Zoom 2>/dev/null || true
  log "  Slack, Spotify, Zoom removed."
}

remove_1password() {
  sudo apt-get purge -y 1password || true
  sudo apt-get autoremove -y
  log "  1Password removed."
}

remove_localsend() {
  sudo apt-get purge -y localsend || true
  sudo apt-get autoremove -y
  log "  LocalSend removed."
}

remove_pomodoro() {
  sudo apt-get purge -y pomatez || true
  sudo apt-get autoremove -y
  log "  Pomatez removed."
}

remove_gnome() {
  sudo apt-get purge -y gnome-tweaks gnome-shell-extension-manager \
    gnome-sushi || true
  sudo apt-get autoremove -y
  if command -v gext &>/dev/null; then
    local extensions=(
      "tactile@lundal.io" "blur-my-shell@aunetx" "space-bar@luchrioh"
      "tophat@fflewddur.github.io" "AlphabeticalAppGrid@stuarthayhurst"
      "caffeine@patapon.info"
    )
    for ext in "${extensions[@]}"; do
      gext uninstall "$ext" 2>/dev/null || true
    done
  fi
  log "  GNOME extras removed. Core GNOME shell is unaffected."
}

remove_tmux() {
  sudo apt-get purge -y tmux || true
  sudo apt-get autoremove -y
  rm -rf ~/.tmux ~/.tmux.conf 2>/dev/null || true
  log "  tmux and TPM removed."
}

remove_dotfiles() {
  rm -f ~/.my.zsh ~/.tmux.conf ~/.config/alacritty/alacritty.toml 2>/dev/null || true
  [[ -f ~/.zshrc ]] && sed -i '/z4h source ~\/.my.zsh/d' ~/.zshrc || true
  log "  Dotfiles removed."
}

remove_fastfetch() {
  sudo apt-get purge -y fastfetch || true
  sudo apt-get autoremove -y
  sudo add-apt-repository -r -y ppa:zhangsongcui3371/fastfetch 2>/dev/null || true
  log "  Fastfetch removed."
}

remove_git_config() {
  git config --global --unset user.name 2>/dev/null || true
  git config --global --unset alias.gh 2>/dev/null || true
  git config --global --unset init.defaultBranch 2>/dev/null || true
  log "  Git global config cleared."
}

# ─────────────────────────────────────────────────────────────────────────────
# Mode-aware checklist menu
# MODE: "install" | "uninstall" | "update"
# Pre-ticks items based on step_done() — installed items show ON in all modes.
# In uninstall mode this means "these are installed and eligible to remove."
install_claude_code() {
  # Official install script from Anthropic — always fetches latest version
  curl -fsSL https://claude.ai/install.sh | bash \
    || log "  WARNING: Claude Code install failed"
}

remove_claude_code() {
  # claude is installed as an npm global via the install script
  npm uninstall -g @anthropic-ai/claude-code 2>/dev/null \
    || rm -f "$(command -v claude 2>/dev/null)" \
    || log "  WARNING: Could not locate Claude Code binary to remove"
  log "  Claude Code removed."
}

# ─────────────────────────────────────────────────────────────────────────────
# Claude Desktop — unofficial community package by aaddrick/claude-desktop-debian
# Repo: https://github.com/aaddrick/claude-desktop-debian
# Installs via the official apt repo at pkg.claude-desktop-debian.dev
# NOTE: repo URL moved April 2026 from aaddrick.github.io — old sources.list entries
#       will fail on apt update. Fix: sed -i 's|aaddrick.github.io/claude-desktop-debian|pkg.claude-desktop-debian.dev|g' \
#       /etc/apt/sources.list.d/claude-desktop.list
# ─────────────────────────────────────────────────────────────────────────────
install_claude_desktop() {
  # apt_add_repo guards each step: key fetch → non-empty check → repo write →
  # apt update → install. Aborts cleanly at the first failure.
  apt_add_repo \
    --name      "claude-desktop" \
    --key-url   "https://pkg.claude-desktop-debian.dev/KEY.gpg" \
    --keyring   "/usr/share/keyrings/claude-desktop.gpg" \
    --repo-line "deb [signed-by=/usr/share/keyrings/claude-desktop.gpg arch=amd64,arm64] https://pkg.claude-desktop-debian.dev stable main" \
    --repo-file "/etc/apt/sources.list.d/claude-desktop.list" \
    --packages  "claude-desktop" \
    || return 1
  log "  Claude Desktop installed."
  log "  MCP config: ~/.config/Claude/claude_desktop_config.json"
  log "  Diagnostics: claude-desktop --doctor"
}

remove_claude_desktop() {
  sudo apt-get purge -y claude-desktop || true
  sudo apt-get autoremove -y
  sudo rm -f /usr/share/keyrings/claude-desktop.gpg \
    /etc/apt/sources.list.d/claude-desktop.list
  sudo apt-get update -y
  log "  Claude Desktop removed."
}

# ─────────────────────────────────────────────────────────────────────────────
# step_done entries for new items
# (appended to the existing step_done case — called via the categorised menu)
# ─────────────────────────────────────────────────────────────────────────────
step_done_ai() {
  # Used by the AI category checker
  local step="$1"
  case "$step" in
    claude_code)    command -v claude &>/dev/null ;;
    claude_desktop) flatpak info ai.claude.desktop &>/dev/null 2>&1 ;;
    lmstudio)       dpkg-query -W lmstudio &>/dev/null 2>&1 ;;
    jan)            dpkg-query -W jan &>/dev/null 2>&1 ;;
    chatbox)        [[ -x /opt/ChatboxAi/ChatboxAi.AppImage ]] ;;
    *) return 1 ;;
  esac
}

# =============================================================================
# ITEM REGISTRY
# =============================================================================
# The ONLY place to edit when adding, removing, or recategorising an app.
# Everything else — tree UI, step detection, install dispatch, uninstall —
# is derived automatically from this registry.
#
# Each register_item call:
#   --key       unique identifier used internally (never shown to user)
#   --cat       category key — must match one of the CATEGORIES entries below
#   --label     text shown in the tree UI
#   --default   ON = ticked by default in install mode / OFF = unticked
#   --detect    bash expression returning 0 if this item is already installed
#   --install   function name to call when installing
#   --remove    function name to call when removing
#   --fg        (flag, no value) run in foreground; required for steps that
#               export variables or write to shell configs (mise, zsh, claude code)
# =============================================================================

declare -a _REG_KEYS=()
declare -A _REG_CAT=()
declare -A _REG_LABEL=()
declare -A _REG_DEFAULT=()
declare -A _REG_DETECT=()
declare -A _REG_INSTALL=()
declare -A _REG_REMOVE=()
declare -A _REG_FG=()

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
  _REG_CAT["$key"]="$cat"
  _REG_LABEL["$key"]="$label"
  _REG_DEFAULT["$key"]="$default"
  _REG_DETECT["$key"]="$detect"
  _REG_INSTALL["$key"]="$install_fn"
  _REG_REMOVE["$key"]="$remove_fn"
  _REG_FG["$key"]="$fg"
}

# Category display order and labels — edit to add new categories
CATEGORIES=(
  "system:System"
  "terminal:Terminal"
  "editors:Editors"
  "browsers:Browsers"
  "devtools:Dev Tools"
  "launchers:Launchers"
  "apps:Apps"
  "gnome:GNOME"
  "ai:AI & Local LLMs"
  "gaming:Gaming"
)

# ── System ─────────────────────────────────────────────────────────────────────
register_item --key base --cat system \
  --label "Base packages + build tools + Ruby deps" --default ON \
  --detect 'pkg_installed build-essential && pkg_installed libssl-dev' \
  --install install_base --remove remove_base

register_item --key zsh --cat system --fg \
  --label "Zsh + zsh4humans + Powerlevel10k" --default ON \
  --detect 'pkg_installed zsh && [[ "$(getent passwd "$USER"|cut -d: -f7)" == */zsh ]]' \
  --install install_zsh --remove remove_zsh

register_item --key fonts --cat system \
  --label "Nerd Fonts + iA Writer + Monaspace" --default ON \
  --detect 'fc-list | grep -qi "FiraMono Nerd"' \
  --install install_fonts --remove remove_fonts

register_item --key fastfetch --cat system \
  --label "Fastfetch system info" --default ON \
  --detect 'cmd_exists fastfetch' \
  --install install_fastfetch --remove remove_fastfetch

register_item --key git --cat system \
  --label "Global git config (name + default branch)" --default ON \
  --detect 'git config --global user.name &>/dev/null' \
  --install configure_git --remove remove_git_config

# ── Terminal ───────────────────────────────────────────────────────────────────
register_item --key terminal --cat terminal \
  --label "Alacritty + Zellij + fzf + eza + bat + btop + fd + ripgrep" \
  --default ON \
  --detect 'pkg_installed alacritty && cmd_exists fzf' \
  --install install_terminal_tools --remove remove_terminal_tools

register_item --key ghostty --cat terminal \
  --label "Ghostty (GPU-accelerated, native GTK4 terminal)" \
  --default ON \
  --detect 'cmd_exists ghostty' \
  --install install_ghostty --remove remove_ghostty

register_item --key tmux --cat terminal \
  --label "tmux + TPM plugin manager" --default ON \
  --detect 'pkg_installed tmux && [[ -d ~/.tmux/plugins/tpm ]]' \
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
  --detect 'cmd_exists zed' \
  --install install_zed --remove remove_zed

register_item --key vscode --cat editors \
  --label "VS Code" --default ON \
  --detect 'cmd_exists code' \
  --install install_vscode --remove remove_vscode

register_item --key vscodium --cat editors \
  --label "VSCodium (open-source VS Code)" --default ON \
  --detect 'cmd_exists codium' \
  --install install_vscodium --remove remove_vscodium

register_item --key sublime --cat editors \
  --label "Sublime Text + Sublime Merge" --default ON \
  --detect 'cmd_exists subl' \
  --install install_sublime --remove remove_sublime

# ── Browsers ───────────────────────────────────────────────────────────────────
register_item --key brave --cat browsers \
  --label "Brave" --default ON \
  --detect 'cmd_exists brave-browser' \
  --install install_brave --remove remove_brave

register_item --key chrome --cat browsers \
  --label "Google Chrome" --default ON \
  --detect 'cmd_exists google-chrome' \
  --install install_chrome --remove remove_chrome

register_item --key firefox_dev --cat browsers \
  --label "Firefox Developer Edition" --default ON \
  --detect '[[ -x /usr/local/bin/firefox-dev ]]' \
  --install install_firefox_dev --remove remove_firefox_dev

register_item --key edge --cat browsers \
  --label "Microsoft Edge" --default OFF \
  --detect 'cmd_exists microsoft-edge' \
  --install install_edge --remove remove_edge

# ── Dev Tools ──────────────────────────────────────────────────────────────────
register_item --key docker --cat devtools \
  --label "Docker engine + LazyDocker" --default ON \
  --detect 'cmd_exists docker' \
  --install install_docker --remove remove_docker

register_item --key mise --cat devtools --fg \
  --label "Mise + Python / Node LTS / Ruby" --default ON \
  --detect 'cmd_exists mise || [[ -x ~/.local/bin/mise ]]' \
  --install install_mise --remove remove_mise

register_item --key flatpak --cat devtools \
  --label "Flatpak + Flathub (base setup)" --default ON \
  --detect 'cmd_exists flatpak && flatpak remotes | grep -q flathub' \
  --install install_flatpak_base --remove remove_flatpak_base

# ── Launchers ──────────────────────────────────────────────────────────────────
register_item --key albert --cat launchers \
  --label "Albert launcher" --default ON \
  --detect 'cmd_exists albert' \
  --install install_albert --remove remove_albert

register_item --key ulauncher --cat launchers \
  --label "ULauncher" --default ON \
  --detect 'cmd_exists ulauncher' \
  --install install_ulauncher --remove remove_ulauncher

# ── Apps ───────────────────────────────────────────────────────────────────────
register_item --key slack --cat apps \
  --label "Slack" --default ON \
  --detect 'pkg_installed slack-desktop || snap_installed slack || flatpak_installed com.slack.Slack' \
  --install install_slack --remove remove_slack

register_item --key spotify --cat apps \
  --label "Spotify" --default ON \
  --detect 'pkg_installed spotify-client || snap_installed spotify || flatpak_installed com.spotify.Client' \
  --install install_spotify --remove remove_spotify

register_item --key zoom --cat apps \
  --label "Zoom" --default ON \
  --detect 'pkg_installed zoom || flatpak_installed us.zoom.Zoom' \
  --install install_zoom --remove remove_zoom

register_item --key obsidian --cat apps \
  --label "Obsidian (notes)" --default ON \
  --detect 'pkg_installed obsidian || flatpak_installed md.obsidian.Obsidian' \
  --install install_obsidian --remove remove_obsidian

register_item --key 1password --cat apps \
  --label "1Password" --default ON \
  --detect 'pkg_installed 1password' \
  --install install_1password --remove remove_1password

register_item --key localsend --cat apps \
  --label "LocalSend (local file sharing)" --default ON \
  --detect 'pkg_installed localsend' \
  --install install_localsend --remove remove_localsend

register_item --key pomodoro --cat apps \
  --label "Pomatez Pomodoro timer" --default ON \
  --detect 'pkg_installed pomatez' \
  --install install_pomodoro --remove remove_pomodoro

# ── GNOME ──────────────────────────────────────────────────────────────────────
register_item --key gnome_setup --cat gnome \
  --label "GNOME tweaks + extensions + gsettings" --default ON \
  --detect 'pkg_installed gnome-tweaks' \
  --install install_gnome --remove remove_gnome

# ── AI & Local LLMs ────────────────────────────────────────────────────────────
register_item --key claude_code --cat ai --fg \
  --label "Claude Code (CLI — curl installer)" --default OFF \
  --detect 'cmd_exists claude' \
  --install install_claude_code --remove remove_claude_code

register_item --key claude_desktop --cat ai \
  --label "Claude Desktop (apt — aaddrick/claude-desktop-debian)" --default OFF \
  --detect 'pkg_installed claude-desktop' \
  --install install_claude_desktop --remove remove_claude_desktop

register_item --key lmstudio --cat ai \
  --label "LM Studio (local AI GUI)" --default OFF \
  --detect 'dpkg-query -W lmstudio &>/dev/null 2>&1' \
  --install install_lmstudio --remove remove_lmstudio

register_item --key jan --cat ai \
  --label "Jan.ai (local AI GUI)" --default OFF \
  --detect 'dpkg-query -W jan &>/dev/null 2>&1' \
  --install install_jan --remove remove_jan

register_item --key chatbox --cat ai \
  --label "Chatbox AI (AppImage)" --default OFF \
  --detect '[[ -x /opt/ChatboxAi/ChatboxAi.AppImage ]]' \
  --install install_chatbox --remove remove_chatbox

# ── Gaming ─────────────────────────────────────────────────────────────────────
register_item --key nvidia --cat gaming \
  --label "NVIDIA drivers (auto-detects GPU)" --default OFF \
  --detect 'lsmod 2>/dev/null | grep -q "^nvidia "' \
  --install install_nvidia_drivers --remove remove_nvidia

register_item --key gaming_stack --cat gaming \
  --label "Steam + Proton + GameMode + MangoHud + Lutris + Heroic" --default OFF \
  --detect 'pkg_installed steam-installer || flatpak_installed com.valvesoftware.Steam' \
  --install install_gaming_stack --remove remove_gaming

register_item --key wine_stack --cat gaming \
  --label "Wine (WineHQ) + Winetricks + Bottles" --default OFF \
  --detect 'cmd_exists wine && cmd_exists winetricks' \
  --install install_wine_stack --remove remove_wine_stack

register_item --key gaming_extras --cat gaming \
  --label "scx schedulers + vkBasalt + OpenRGB + AntiMicroX + Waydroid" --default OFF \
  --detect 'flatpak_installed io.github.antimicrox.antimicrox' \
  --install install_gaming_extras --remove remove_gaming_extras

register_item --key controller --cat gaming \
  --label "Xbox controller (Bluetooth xpadneo + dongle xone)" --default OFF \
  --detect 'dkms status 2>/dev/null | grep -q xpadneo' \
  --install install_xbox_controller --remove remove_controller

# =============================================================================
# THIN WRAPPERS — individual install/remove per split item
# (browsers, launchers, apps that used to be bundled are now separate items)
# =============================================================================

# ── Browsers ───────────────────────────────────────────────────────────────────
install_brave() {
  apt_add_repo \
    --name      "brave" \
    --key-url   "https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg" \
    --keyring   "/usr/share/keyrings/brave-browser-archive-keyring.gpg" \
    --repo-line "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" \
    --repo-file "/etc/apt/sources.list.d/brave-browser-release.list" \
    --packages  "brave-browser"
}
remove_brave() {
  sudo apt-get purge -y brave-browser || true
  sudo rm -f /etc/apt/sources.list.d/brave-browser-release.list \
    /usr/share/keyrings/brave-browser-archive-keyring.gpg
  sudo apt-get update -y; sudo apt-get autoremove -y
  log "  Brave removed."
}

install_chrome() {
  local tmp; tmp=$(mktemp -d)
  wget -q --tries=1 --connect-timeout=15 -O "$tmp/chrome.deb" \
    https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  sudo apt-get install -y "$tmp/chrome.deb" || log "  WARNING: Chrome install failed"
  rm -rf "$tmp"
}
remove_chrome() {
  sudo apt-get purge -y google-chrome-stable || true
  sudo apt-get autoremove -y; log "  Chrome removed."
}

install_firefox_dev() {
  local tmp; tmp=$(mktemp -d)
  wget -q --tries=1 --connect-timeout=15 -O "$tmp/firefox-dev.tar.xz" \
    "https://download.mozilla.org/?product=firefox-devedition-latest-ssl&os=linux64&lang=en-US"
  sudo tar -xf "$tmp/firefox-dev.tar.xz" -C /opt/
  sudo chown -R "$USER" /opt/firefox
  sudo ln -sf /opt/firefox/firefox /usr/local/bin/firefox-dev
  rm -rf "$tmp"
  mkdir -p ~/.local/share/applications
  cat > ~/.local/share/applications/firefox-dev.desktop << 'EOF'
[Desktop Entry]
Name=Firefox Developer Edition
Exec=/usr/local/bin/firefox-dev %u
Icon=/opt/firefox/browser/chrome/icons/default/default128.png
Type=Application
Terminal=false
Categories=Network;WebBrowser;
EOF
}
remove_firefox_dev() {
  sudo rm -rf /opt/firefox /usr/local/bin/firefox-dev \
    ~/.local/share/applications/firefox-dev.desktop
  log "  Firefox Dev removed."
}

install_edge() {
  apt_add_repo \
    --name      "microsoft-edge" \
    --key-url   "https://packages.microsoft.com/keys/microsoft.asc" \
    --keyring   "/usr/share/keyrings/microsoft-edge.gpg" \
    --repo-line "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-edge.gpg] https://packages.microsoft.com/repos/edge stable main" \
    --repo-file "/etc/apt/sources.list.d/microsoft-edge.list" \
    --packages  "microsoft-edge-stable"
}
remove_edge() {
  sudo apt-get purge -y microsoft-edge-stable || true
  sudo rm -f /etc/apt/sources.list.d/microsoft-edge.list \
    /usr/share/keyrings/microsoft-edge.gpg
  sudo apt-get update -y; sudo apt-get autoremove -y; log "  Edge removed."
}

# ── Editors (split) ────────────────────────────────────────────────────────────
install_vscode() {
  apt_add_repo \
    --name      "vscode" \
    --key-url   "https://packages.microsoft.com/keys/microsoft.asc" \
    --keyring   "/etc/apt/keyrings/packages.microsoft.gpg" \
    --repo-line "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    --repo-file "/etc/apt/sources.list.d/vscode.list" \
    --packages  "code"
}
remove_vscode() {
  sudo apt-get purge -y code || true
  sudo rm -f /etc/apt/sources.list.d/vscode.list \
    /etc/apt/keyrings/packages.microsoft.gpg
  sudo apt-get update -y; sudo apt-get autoremove -y; log "  VS Code removed."
}

install_vscodium() {
  apt_add_repo \
    --name      "vscodium" \
    --key-url   "https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg" \
    --keyring   "/usr/share/keyrings/vscodium-archive-keyring.gpg" \
    --repo-line "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/vscodium-archive-keyring.gpg] https://download.vscodium.com/debs vscodium main" \
    --repo-file "/etc/apt/sources.list.d/vscodium.list" \
    --packages  "codium"
}
remove_vscodium() {
  sudo apt-get purge -y codium || true
  sudo rm -f /etc/apt/sources.list.d/vscodium.list \
    /usr/share/keyrings/vscodium-archive-keyring.gpg
  sudo apt-get update -y; sudo apt-get autoremove -y; log "  VSCodium removed."
}

install_sublime() {
  # Sublime uses a plain .asc key (not gpg dearmored) — fetch with guard
  if ! wget -q --tries=1 --connect-timeout=15 --timeout=30 \
      -O - https://download.sublimetext.com/sublimehq-pub.gpg \
      | sudo tee /etc/apt/keyrings/sublimehq-pub.asc > /dev/null; then
    log "  WARNING: [sublime] GPG key fetch failed — aborting install"
    sudo rm -f /etc/apt/keyrings/sublimehq-pub.asc
    return 1
  fi
  if [[ ! -s /etc/apt/keyrings/sublimehq-pub.asc ]]; then
    log "  WARNING: [sublime] Key file empty — aborting install"
    sudo rm -f /etc/apt/keyrings/sublimehq-pub.asc
    return 1
  fi
  printf 'Types: deb\nURIs: https://download.sublimetext.com/\nSuites: apt/stable/\nSigned-By: /etc/apt/keyrings/sublimehq-pub.asc\n' \
    | sudo tee /etc/apt/sources.list.d/sublime-text.sources > /dev/null \
    || { log "  WARNING: [sublime] Could not write repo file"; return 1; }
  sudo apt-get update -y \
    || { log "  WARNING: [sublime] apt update failed"; return 1; }
  DEBIAN_FRONTEND=noninteractive sudo -E apt-get install -y sublime-text sublime-merge \
    || log "  WARNING: Sublime install failed"
}
remove_sublime() {
  sudo apt-get purge -y sublime-text sublime-merge || true
  sudo rm -f /etc/apt/sources.list.d/sublime-text.sources \
    /etc/apt/keyrings/sublimehq-pub.asc
  sudo apt-get update -y; sudo apt-get autoremove -y; log "  Sublime removed."
}

# ── Launchers ──────────────────────────────────────────────────────────────────
install_albert() {
  if add_obs_repo "home:manuelschneid3r" "albert"; then
    sudo apt-get update -y && sudo apt-get install -y albert \
      || log "  WARNING: albert not installable on $VERSION_ID yet"
  fi
}
remove_albert() {
  sudo apt-get purge -y albert || true
  sudo rm -f /etc/apt/sources.list.d/albert.list \
    /etc/apt/trusted.gpg.d/home--manuelschneid3r.gpg
  sudo apt-get update -y; log "  Albert removed."
}

install_ulauncher() {
  sudo add-apt-repository -y universe
  sudo add-apt-repository -y ppa:agornostal/ulauncher
  sudo apt-get update -y && sudo apt-get install -y ulauncher \
    || log "  WARNING: ulauncher install failed (PPA may not support $VERSION_ID yet)"
}
remove_ulauncher() {
  sudo apt-get purge -y ulauncher || true
  sudo add-apt-repository -r -y ppa:agornostal/ulauncher 2>/dev/null || true
  sudo apt-get update -y; log "  ULauncher removed."
}

# ── Apps (split) ───────────────────────────────────────────────────────────────
install_slack() {
  # Native .deb from Slack's official download — self-updating via apt repo
  local tmp; tmp=$(mktemp -d)
  if wget -q --tries=1 --connect-timeout=15 -O "$tmp/slack.deb" \
      "https://downloads.slack-edge.com/desktop-releases/linux/x64/latest/slack-desktop-latest-amd64.deb" 2>/dev/null; then
    sudo apt-get install -y "$tmp/slack.deb" \
      && { rm -rf "$tmp"; return 0; } \
      || log "  WARNING: Slack native .deb failed — trying snap"
  fi
  rm -rf "$tmp"
  # Snap fallback
  sudo snap install slack 2>/dev/null && return 0 \
    || log "  WARNING: Slack snap failed — trying Flatpak"
  # Flatpak last resort
  flatpak install -y --noninteractive flathub com.slack.Slack 2>/dev/null \
    || log "  WARNING: All Slack install methods failed"
}
remove_slack() {
  sudo apt-get purge -y slack-desktop 2>/dev/null || true
  sudo snap remove slack 2>/dev/null || true
  flatpak uninstall -y --noninteractive com.slack.Slack 2>/dev/null || true
  sudo apt-get autoremove -y; log "  Slack removed."
}

install_spotify() {
  # Native apt repo — official Spotify Linux repository
  curl -fsSL --connect-timeout 15 --max-time 30 https://download.spotify.com/debian/pubkey_6224F9941A8AA6D1.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/spotify.gpg 2>/dev/null \
    && echo "deb [signed-by=/usr/share/keyrings/spotify.gpg] https://repository.spotify.com stable non-free" \
      | sudo tee /etc/apt/sources.list.d/spotify.list > /dev/null \
    && sudo apt-get update -y \
    && sudo apt-get install -y spotify-client \
    && return 0 \
    || log "  WARNING: Spotify apt repo failed — trying snap"
  # Snap fallback
  sudo snap install spotify 2>/dev/null && return 0 \
    || log "  WARNING: Spotify snap failed — trying Flatpak"
  # Flatpak last resort
  flatpak install -y --noninteractive flathub com.spotify.Client 2>/dev/null \
    || log "  WARNING: All Spotify install methods failed"
}
remove_spotify() {
  sudo apt-get purge -y spotify-client 2>/dev/null || true
  sudo rm -f /usr/share/keyrings/spotify.gpg /etc/apt/sources.list.d/spotify.list
  sudo snap remove spotify 2>/dev/null || true
  flatpak uninstall -y --noninteractive com.spotify.Client 2>/dev/null || true
  sudo apt-get update -y; sudo apt-get autoremove -y; log "  Spotify removed."
}

install_zoom() {
  # Try native .deb from Zoom's download page first — self-updating via apt repo
  local tmp; tmp=$(mktemp -d)
  if wget -q --tries=1 --connect-timeout=15 -O "$tmp/zoom.deb" \
      "https://zoom.us/client/latest/zoom_amd64.deb" 2>/dev/null; then
    sudo apt-get install -y "$tmp/zoom.deb" \
      && { rm -rf "$tmp"; return 0; } \
      || log "  WARNING: Zoom native .deb install failed — trying Flatpak"
  fi
  rm -rf "$tmp"
  # Flatpak fallback
  flatpak install -y --noninteractive flathub us.zoom.Zoom 2>/dev/null \
    || log "  WARNING: Zoom Flatpak also failed"
}
remove_zoom() {
  sudo apt-get purge -y zoom 2>/dev/null || true
  flatpak uninstall -y --noninteractive us.zoom.Zoom 2>/dev/null || true
  sudo apt-get autoremove -y
  log "  Zoom removed."
}

install_obsidian() {
  # Native .deb from GitHub releases (Obsidian publishes official .deb packages)
  local url
  url=$(github_latest "obsidianmd/obsidian-releases" "_amd64.deb")
  if [[ -n "$url" ]]; then
    local tmp; tmp=$(mktemp -d)
    wget -q --tries=1 --connect-timeout=15 -O "$tmp/obsidian.deb" "$url" \
      && sudo apt-get install -y "$tmp/obsidian.deb" \
      && { rm -rf "$tmp"; return 0; } \
      || log "  WARNING: Obsidian native .deb failed — trying Flatpak"
    rm -rf "$tmp"
  fi
  # Flatpak fallback
  flatpak install -y --noninteractive flathub md.obsidian.Obsidian 2>/dev/null \
    || log "  WARNING: Obsidian Flatpak also failed"
}
remove_obsidian() {
  sudo apt-get purge -y obsidian 2>/dev/null || true
  flatpak uninstall -y --noninteractive md.obsidian.Obsidian 2>/dev/null || true
  sudo apt-get autoremove -y
  log "  Obsidian removed."
}

# ── Dev Tools ──────────────────────────────────────────────────────────────────
install_flatpak_base() {
  # Sets up Flatpak + Flathub; individual apps are installed via their own items
  sudo apt-get install -y flatpak gnome-software-plugin-flatpak
  flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo
}
remove_flatpak_base() {
  sudo apt-get purge -y flatpak gnome-software-plugin-flatpak || true
  sudo apt-get autoremove -y; log "  Flatpak removed."
}

# =============================================================================
# TREE UI — fully button-free, ANSI bold/reverse only
# =============================================================================
# Navigation:
#   ↑↓  /  j k    = move cursor
#   ← → / h l     = collapse / expand category
#   Space          = toggle item (or all children if on a category row)
#   a / n          = select all / deselect all
#   Enter          = confirm selection
#   q              = quit without doing anything
#
# Category row shows: [x] all children ticked / [-] some / [ ] none
# Uses tput smcup/rmcup to save and restore the terminal screen.
# =============================================================================

_is_cat_row() { [[ "$1" == cat:* ]]; }

run_tree_ui() {
  local mode="$1"

  # ── Build row list and initial state ───────────────────────────────────────
  local -a all_rows=()      # "cat:KEY" or "ITEMKEY"
  local -A expanded=()      # cat key → 1
  local -A checked=()       # item key → 1 or 0

  local cat_entry
  for cat_entry in "${CATEGORIES[@]}"; do
    local cat_key="${cat_entry%%:*}"
    expanded["$cat_key"]=1
    all_rows+=("cat:${cat_key}")
    local key
    for key in "${_REG_KEYS[@]}"; do
      [[ "${_REG_CAT[$key]}" != "$cat_key" ]] && continue
      all_rows+=("$key")
      if [[ "$mode" == "install" ]]; then
        [[ "${_REG_DEFAULT[$key]}" == "ON" ]] && checked["$key"]=1 || checked["$key"]=0
      else
        eval "${_REG_DETECT[$key]}" 2>/dev/null \
          && checked["$key"]=1 || checked["$key"]=0
      fi
    done
  done

  # ── Compute visible rows (respects collapse state) ─────────────────────────
  _vis() {
    local -a v=()
    local r
    for r in "${all_rows[@]}"; do
      if _is_cat_row "$r"; then
        v+=("$r")
      else
        local c="${_REG_CAT[$r]}"
        [[ "${expanded[$c]:-0}" == "1" ]] && v+=("$r")
      fi
    done
    printf '%s\n' "${v[@]}"
  }

  # ── ANSI / terminal setup ──────────────────────────────────────────────────
  local B='\033[1m' RV='\033[7m' BRV='\033[1;7m' RST='\033[0m' CLR='\033[2K'
  local term_h; term_h=$(tput lines 2>/dev/null || echo 30)
  local term_w; term_w=$(tput cols  2>/dev/null || echo 80)
  local viewport=$(( term_h - 6 ))
  (( viewport < 4 )) && viewport=4

  local cursor=0 scroll=0

  printf '\033[?25l'
  tput smcup 2>/dev/null || true
  trap 'tput rmcup 2>/dev/null; printf "\033[?25h"' EXIT INT TERM
  clear

  # ── Draw frame ─────────────────────────────────────────────────────────────
  _draw() {
    local -a vis
    mapfile -t vis < <(_vis)
    local total=${#vis[@]}
    (( cursor >= total )) && cursor=$(( total - 1 ))
    (( cursor < 0 )) && cursor=0
    (( cursor < scroll )) && scroll=$cursor
    (( cursor >= scroll + viewport )) && scroll=$(( cursor - viewport + 1 ))

    tput cup 0 0

    # Header
    local mode_label
    case "$mode" in
      install)   mode_label="INSTALL"   ;;
      uninstall) mode_label="UNINSTALL" ;;
      update)    mode_label="UPDATE"    ;;
    esac
    printf "${CLR}${B}  Ubuntu Setup — %s  ·  %s (%s)${RST}\n" \
      "$mode_label" "$VERSION_ID" "$CODENAME"
    printf "${CLR}${B}  ─────────────────────────────────────────────────────────${RST}\n"

    # Rows
    local i
    for (( i = scroll; i < scroll + viewport && i < total; i++ )); do
      local row="${vis[$i]}"
      local line

      if _is_cat_row "$row"; then
        local ck="${row#cat:}"
        local clabel=""
        local ce; for ce in "${CATEGORIES[@]}"; do
          [[ "${ce%%:*}" == "$ck" ]] && clabel="${ce#*:}" && break
        done
        local nc=0 nt=0 k
        for k in "${_REG_KEYS[@]}"; do
          [[ "${_REG_CAT[$k]}" != "$ck" ]] && continue
          nt=$(( nt + 1 ))
          [[ "${checked[$k]:-0}" == "1" ]] && nc=$(( nc + 1 ))
        done
        local box; (( nc == 0 )) && box="[ ]" || (( nc == nt )) && box="[x]" || box="[-]"
        local arr; [[ "${expanded[$ck]:-0}" == "1" ]] && arr="▼" || arr="▶"
        line="  ${box} ${arr} ${clabel}  (${nc}/${nt})"
      else
        local chk; [[ "${checked[$row]:-0}" == "1" ]] && chk="[x]" || chk="[ ]"
        line="      ${chk} ${_REG_LABEL[$row]}"
      fi

      printf "${CLR}"
      if (( i == cursor )); then
        printf "${BRV}%-${term_w}s${RST}\n" "$line"
      else
        printf "%-${term_w}s\n" "$line"
      fi
    done

    # Clear leftover lines
    local ci
    for (( ci = total - scroll; ci < viewport; ci++ )); do
      printf "${CLR}\n"
    done

    # Footer
    printf "${CLR}\n"
    printf "${CLR}${B}  Space${RST}=toggle  ${B}↑↓/jk${RST}=move  ${B}←→/hl${RST}=collapse/expand  ${B}a${RST}=all  ${B}n${RST}=none  ${B}Enter${RST}=confirm  ${B}q${RST}=quit\n"
  }

  # ── Event loop ─────────────────────────────────────────────────────────────
  _draw
  while true; do
    local -a vis; mapfile -t vis < <(_vis)
    local total=${#vis[@]}
    local cur_row="${vis[$cursor]:-}"

    local key esc
    IFS= read -rsn1 key
    if [[ $key == $'\033' ]]; then
      IFS= read -rsn2 -t 0.05 esc
      key="${key}${esc}"
    fi

    case "$key" in
      # Movement
      $'\033[A'|k) (( cursor > 0 )) && (( cursor-- )) ;;
      $'\033[B'|j) (( cursor < total - 1 )) && (( cursor++ )) ;;

      # Expand / collapse
      $'\033[C'|l)
        _is_cat_row "$cur_row" && expanded["${cur_row#cat:}"]=1 ;;
      $'\033[D'|h)
        if _is_cat_row "$cur_row"; then
          expanded["${cur_row#cat:}"]=0
        else
          local parent="${_REG_CAT[$cur_row]}"
          expanded["$parent"]=0
          local ri
          for ri in "${!vis[@]}"; do
            [[ "${vis[$ri]}" == "cat:$parent" ]] && cursor=$ri && break
          done
        fi ;;

      # Toggle
      ' ')
        if _is_cat_row "$cur_row"; then
          local ck="${cur_row#cat:}" all1=1 k
          for k in "${_REG_KEYS[@]}"; do
            [[ "${_REG_CAT[$k]}" != "$ck" ]] && continue
            [[ "${checked[$k]:-0}" != "1" ]] && all1=0 && break
          done
          local ns=$(( 1 - all1 ))
          for k in "${_REG_KEYS[@]}"; do
            [[ "${_REG_CAT[$k]}" == "$ck" ]] && checked["$k"]=$ns
          done
        else
          [[ "${checked[$cur_row]:-0}" == "1" ]] && checked["$cur_row"]=0 || checked["$cur_row"]=1
        fi ;;

      # Select all / none
      a|A) local k; for k in "${_REG_KEYS[@]}"; do checked["$k"]=1; done ;;
      n|N) local k; for k in "${_REG_KEYS[@]}"; do checked["$k"]=0; done ;;

      # Confirm
      ''|$'\n') break ;;

      # Quit
      q|Q)
        tput rmcup 2>/dev/null || true
        printf '\033[?25h\n'
        echo "Cancelled."; exit 0 ;;
    esac

    _draw
  done

  # Restore terminal
  tput rmcup 2>/dev/null || true
  printf '\033[?25h'
  trap - EXIT INT TERM

  # Populate SELECTED_ITEMS
  SELECTED_ITEMS=()
  local k
  for k in "${_REG_KEYS[@]}"; do
    [[ "${checked[$k]:-0}" == "1" ]] && SELECTED_ITEMS+=("$k")
  done
}

# =============================================================================
# DISPATCH — reads SELECTED_ITEMS[] and registry, no hardcoded case tables
# =============================================================================
dispatch() {
  local mode="$1"
  local item
  for item in "${SELECTED_ITEMS[@]}"; do
    local fn label fg

    label="${_REG_LABEL[$item]:-$item}"
    fg="${_REG_FG[$item]:-0}"

    if [[ "$mode" == "uninstall" ]]; then
      fn="${_REG_REMOVE[$item]:-}"
      label="Remove: $label"
    else
      fn="${_REG_INSTALL[$item]:-}"
    fi

    [[ -z "$fn" ]] && { log "  WARNING: No function for $item in $mode mode"; continue; }

    # Per-item timeout overrides for steps known to be slow or hang-prone.
    # The default STEP_TIMEOUT_SECS=300 (5 min) applies to everything else.
    local timeout="${STEP_TIMEOUT_SECS:-300}"
    case "$item" in
      edge)          timeout=180  ;;  # Edge postinstall phones home; kill at 3 min
      gaming_stack)  timeout=600  ;;  # Steam + deps is a large download
      wine_stack)    timeout=600  ;;  # WineHQ + 32-bit libs is large
      gaming_extras) timeout=600  ;;  # Waydroid image download is large
      base)          timeout=600  ;;  # apt upgrade on fresh install can be slow
      lmstudio)      timeout=300  ;;  # 650MB .deb download
    esac

    if [[ "$fg" == "1" ]]; then
      STEP_TIMEOUT_SECS="$timeout" run_step_fg "$label" "$fn"
    else
      STEP_TIMEOUT_SECS="$timeout" run_step    "$label" "$fn"
    fi
  done
}

# =============================================================================
# choose_mode — arrow-key terminal mode selector
# Sets global MODE variable directly (must not run in a $() subshell)
# =============================================================================
MODE=""
SELECTED_ITEMS=()

choose_mode() {
  local options=("install" "uninstall" "update")
  local labels=(
    "  Install    — add selected items to this machine      "
    "  Uninstall  — remove selected items                   "
    "  Update     — re-run installs to get latest versions  "
  )
  local selected=0
  local B='\033[1m' BRV='\033[1;7m' RST='\033[0m' CLR='\033[2K'

  printf '\033[?25l'
  tput smcup 2>/dev/null || true
  clear

  _draw_mode() {
    tput cup 0 0
    printf "${CLR}\n"
    printf "${CLR}  Ubuntu Setup — %s (%s)\n" "$VERSION_ID" "$CODENAME"
    printf "${CLR}  ─────────────────────────────────────────────────────────\n"
    local i
    for i in "${!options[@]}"; do
      printf "${CLR}"
      if (( i == selected )); then
        printf "  ${BRV}▶ %s${RST}\n" "${labels[$i]}"
      else
        printf "    %s\n" "${labels[$i]}"
      fi
    done
    printf "${CLR}\n"
    printf "${CLR}  ↑↓ / j/k = move  |  Enter = confirm  |  q = quit\n"
  }

  _draw_mode
  while true; do
    local key esc
    IFS= read -rsn1 key
    if [[ $key == $'\033' ]]; then
      IFS= read -rsn2 -t 0.05 esc
      key="${key}${esc}"
    fi
    case "$key" in
      $'\033[A'|k) (( selected > 0 )) && (( selected-- )); _draw_mode ;;
      $'\033[B'|j) (( selected < ${#options[@]} - 1 )) && (( selected++ )); _draw_mode ;;
      ''|$'\n')    break ;;
      q|Q)
        tput rmcup 2>/dev/null || true
        printf '\033[?25h\n'
        echo "Cancelled."; exit 0 ;;
    esac
  done

  tput rmcup 2>/dev/null || true
  printf '\033[?25h'
  MODE="${options[$selected]}"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo ""                                                           >> "$LOG_FILE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$LOG_FILE"
  echo "  RUN STARTED: $(date '+%Y-%m-%d %H:%M:%S')"               >> "$LOG_FILE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$LOG_FILE"

  trap 'stop_spinner; tput rmcup 2>/dev/null; printf "\033[?25h"' EXIT INT TERM

  preflight

  # Step 1: mode (sets global $MODE)
  choose_mode
  echo "  MODE: $MODE" >> "$LOG_FILE"

  # Step 2: tree UI (sets global SELECTED_ITEMS[])
  run_tree_ui "$MODE"

  if [[ ${#SELECTED_ITEMS[@]} -eq 0 ]]; then
    logecho "No items selected — nothing to do."
    exit 0
  fi

  trap 'stop_spinner' EXIT INT TERM
  logecho "Starting ${MODE} of ${#SELECTED_ITEMS[@]} item(s)..."

  # Step 3: dispatch
  dispatch "$MODE"

  trap - EXIT INT TERM

  # Summary
  local action
  case "$MODE" in install) action="installed";; uninstall) action="removed";; *) action="updated";; esac

  echo ""
  if [[ ${#ERRORS[@]} -eq 0 ]]; then
    logecho "━━━ All selected items ${action} successfully ━━━"
  else
    logecho "━━━ Finished with ${#ERRORS[@]} warning(s) ━━━"
    for e in "${ERRORS[@]}"; do logecho "  • $e"; done
  fi
  logecho "Log: $LOG_FILE"

  local msg
  if [[ ${#ERRORS[@]} -eq 0 ]]; then
    msg="All selected items ${action} successfully."
  else
    msg="Finished with ${#ERRORS[@]} warning(s):\n"
    for e in "${ERRORS[@]}"; do msg+="  • $e\n"; done
  fi
  whiptail --title "Done — Ubuntu Setup" \
    --msgbox "${msg}\n\nLog: $LOG_FILE\n\nReminder: log out and back in if shell or docker group changed." \
    20 70
}

main "$@"
