#!/usr/bin/env bash
# =============================================================================
# setup.sh — Interactive setup for Ubuntu and Fedora
# Usage:     bash setup.sh
#
# Developer guide (adding apps, repos, debugging): see CONTRIBUTING.md
#
# NOTES:
#   - Dotfiles (.tmux.conf, alacritty.toml, .my.zsh) must sit beside this script
#   - Log file: ~/setup.log
#   - Re-running is safe — all installs are idempotent
#   - Failures are non-fatal: collected and shown in a summary at the end
#   - Arch Linux support: planned, not yet implemented
#
# DEBUGGING:
#   Last run failures:
#     awk '/RUN STARTED/{buf=""} {buf=buf"\n"$0} END{print buf}' ~/setup.log \
#       | grep -E "FAILED|TIMEOUT|WARNING"
#   Watch live:
#     tail -f ~/setup.log
#   Test a single function:
#     source setup.sh && install_brave
# =============================================================================
set -uo pipefail   # intentionally no -e; errors handled per-step via run_step()


# ─────────────────────────────────────────────────────────────────────────────
# Globals
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Export so subshells used by run_step() inherit the correct value
export SCRIPT_DIR
LOG_FILE="$HOME/setup.log"
ERRORS=()

# Distro detection — populated by detect_distro()
DISTRO=""     # "ubuntu" | "fedora"
PKG_MGR=""    # "apt"    | "dnf"
CODENAME=""   # Ubuntu codename (e.g. "noble", "resolute")
VERSION_ID="" # e.g. "26.04" or "42"
FEDORA_VER="" # Fedora version number (e.g. "42")

# ─────────────────────────────────────────────────────────────────────────────
# Distro detection
# ─────────────────────────────────────────────────────────────────────────────
detect_distro() {
  # shellcheck disable=SC1091
  . /etc/os-release

  VERSION_ID="${VERSION_ID:-}"

  case "$ID" in
    ubuntu|debian|linuxmint|pop)
      DISTRO="ubuntu"; PKG_MGR="apt"
      CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
      ;;
    fedora)
      DISTRO="fedora"; PKG_MGR="dnf"
      FEDORA_VER="$(rpm -E %fedora 2>/dev/null || echo "$VERSION_ID")"
      ;;
    *)
      case "${ID_LIKE:-}" in
        *debian*|*ubuntu*) DISTRO="ubuntu"; PKG_MGR="apt"
          CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" ;;
        *fedora*|*rhel*)   DISTRO="fedora"; PKG_MGR="dnf"
          FEDORA_VER="$(rpm -E %fedora 2>/dev/null || echo "$VERSION_ID")" ;;
        *)
          echo "Unsupported distro: $ID (ID_LIKE=${ID_LIKE:-none})"
          echo "Supported: Ubuntu/Debian, Fedora"
          exit 1
          ;;
      esac
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

# Timestamped log line — written to log file only (no stdout during spinner)
log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }

# Timestamped log + stdout — used outside run_step() where no spinner is active
logecho() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# version_gte A B → true if A >= B
version_gte() { [ "$(printf '%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

# ── Package manager abstraction ───────────────────────────────────────────────

pkg_update() {
  case "$PKG_MGR" in
    apt) sudo apt-get update -y ;;
    dnf) sudo dnf check-update -y || true ;;  # exits 100 when updates available
  esac
}

pkg_install() {
  case "$PKG_MGR" in
    apt) DEBIAN_FRONTEND=noninteractive sudo -E apt-get install -y \
           -o DPkg::Options::="--force-confnew" "$@" \
           || log "  WARNING: Some apt packages failed: $*" ;;
    dnf) sudo dnf install -y "$@" \
           || log "  WARNING: Some dnf packages failed: $*" ;;
  esac
}

pkg_remove() {
  case "$PKG_MGR" in
    apt) sudo apt-get purge -y "$@" || true; sudo apt-get autoremove -y ;;
    dnf) sudo dnf remove -y "$@" || true ;;
  esac
}

# Setup RPM Fusion (Fedora only) — required for NVIDIA, codecs, gaming
setup_rpmfusion() {
  [[ "$DISTRO" != "fedora" ]] && return 0
  if ! rpm -q rpmfusion-free-release &>/dev/null; then
    sudo dnf install -y \
      "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VER}.noarch.rpm" \
      "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VER}.noarch.rpm" \
      || log "  WARNING: RPM Fusion install failed"
  fi
}

# ── Spinner ───────────────────────────────────────────────────────────────────
SPINNER_PID=""
SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

start_spinner() {
  local label="$1"
  local start_ts=$SECONDS
  (
    local i=0
    while true; do
      local elapsed=$(( SECONDS - start_ts ))
      printf "\r  %s  %-50s  %02d:%02d" \
        "${SPINNER_FRAMES[$(( i % ${#SPINNER_FRAMES[@]} ))]}" \
        "$label" "$(( elapsed/60 ))" "$(( elapsed%60 ))"
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
# run_step_fg → foreground; required for functions that modify current shell env
#               (mise exports PATH; zsh writes .zshrc; claude_code modifies PATH)
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
    # No stdout/stderr redirection — interactive programs (z4h, whiptail, etc.)
    # need real TTYs for both. Output goes to terminal only, not the log.
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

ask() { whiptail "$@" 3>&1 1>&2 2>&3 </dev/tty >/dev/tty; }

# ── Repo helpers ──────────────────────────────────────────────────────────────

# apt_add_repo — guarded 4-step: key fetch → non-empty check → repo write → apt update → install
# Aborts cleanly at any failure so apt-get install never runs on a broken setup.
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

  # Download key to temp file first — piping curl into gpg means gpg blocks
  # waiting for stdin even after curl's --max-time fires on a stalled connection.
  log "  [$name] Fetching GPG key..."
  # Remove stale keyring from previous failed runs — gpg refuses to overwrite
  sudo rm -f "$keyring"
  local tmp_key; tmp_key=$(mktemp /tmp/setup-key-XXXXXX)
  chmod 644 "$tmp_key"
  if ! curl -fsSL --connect-timeout 15 --max-time 30 "$key_url" -o "$tmp_key"; then
    log "  WARNING: [$name] GPG key fetch failed or timed out — aborting"
    rm -f "$tmp_key"; sudo rm -f "$keyring"; return 1
  fi
  if [[ ! -s "$tmp_key" ]]; then
    log "  WARNING: [$name] Downloaded key is empty — aborting"
    rm -f "$tmp_key"; sudo rm -f "$keyring"; return 1
  fi
  if ! sudo gpg --batch --no-tty --dearmor -o "$keyring" < "$tmp_key"; then
    log "  WARNING: [$name] GPG dearmor failed — aborting"
    rm -f "$tmp_key"; sudo rm -f "$keyring"; return 1
  fi
  rm -f "$tmp_key"
  if [[ ! -s "$keyring" ]]; then
    log "  WARNING: [$name] Keyring empty after dearmor — aborting"
    sudo rm -f "$keyring"; return 1
  fi
  if ! echo "$repo_line" | sudo tee "$repo_file" > /dev/null; then
    log "  WARNING: [$name] Could not write repo file — aborting"; sudo rm -f "$keyring"; return 1
  fi
  # Update only the newly added repo — ignore errors from other repos in sources.list.d
  # that may have broken signatures or 404s from earlier install steps
  sudo apt-get update \
    -o Dir::Etc::sourcelist="$repo_file" \
    -o Dir::Etc::sourcelistd="" \
    -o APT::Get::List-Cleanup="0" \
    -o APT::Update::Error-Mode="any" \
    -y 2>/dev/null || sudo apt-get update -y 2>/dev/null || {
    log "  WARNING: [$name] apt update failed — cleaning up and aborting"
    sudo rm -f "$repo_file"
    return 1
  }
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive sudo -E apt-get install -y \
    -o DPkg::Options::="--force-confnew" \
    -o DPkg::Lock::Timeout=60 \
    $packages \
    || { log "  WARNING: [$name] Package install failed"; return 1; }
  log "  [$name] Install complete."
}

# _fetch_key <url> <dest>
# Downloads a GPG key to dest, dearmoring if needed.
# Uses a temp file — avoids curl|gpg pipe hangs where gpg blocks on stdin
# even after curl's --max-time fires on a stalled network connection.
_fetch_key() {
  local url="$1" dest="$2"
  # Remove stale file — gpg refuses to overwrite existing files
  sudo rm -f "$dest"
  local tmp; tmp=$(mktemp /tmp/setup-key-XXXXXX)
  chmod 644 "$tmp"
  if ! curl -fsSL --connect-timeout 15 --max-time 30 "$url" -o "$tmp"; then
    log "  WARNING: Key fetch failed: $url"; rm -f "$tmp"; return 1
  fi
  if [[ ! -s "$tmp" ]]; then
    log "  WARNING: Downloaded key is empty: $url"; rm -f "$tmp"; return 1
  fi
  # Always dearmor — gpg handles both ASCII-armored and binary input correctly.
  # Never use cp directly: ASCII-armored keys written to trusted.gpg.d/ are
  # silently ignored by apt with "unsupported filetype" errors.
  sudo gpg --batch --no-tty --dearmor -o "$dest" < "$tmp" \
    || { log "  WARNING: GPG dearmor failed for $url"; rm -f "$tmp"; sudo rm -f "$dest"; return 1; }
  rm -f "$tmp"
  [[ -s "$dest" ]] || { sudo rm -f "$dest"; return 1; }
  return 0
}

# Add an openSUSE Build Service repo for Ubuntu with version fallback
add_obs_repo() {
  local obs_project="$1" package_name="$2"
  local base_url="https://download.opensuse.org/repositories/${obs_project}"
  local try_url="${base_url}/xUbuntu_${VERSION_ID}/"

  if ! curl -fsSL --head "${try_url}Release" &>/dev/null; then
    local prev_ver
    prev_ver=$(curl -fsSL "${base_url}/" 2>/dev/null \
      | grep -oP "xUbuntu_\K[0-9]+\.[0-9]+" | sort -V \
      | awk -v cur="$VERSION_ID" '$0 <= cur' | tail -1)
    if [[ -n "$prev_ver" ]]; then
      log "  OBS: Ubuntu $VERSION_ID not available for $package_name — using $prev_ver"
      try_url="${base_url}/xUbuntu_${prev_ver}/"
    else
      log "  WARNING: No OBS repo found for $package_name"; return 1
    fi
  fi
  _fetch_key "${try_url}Release.key" \
    "/etc/apt/trusted.gpg.d/${obs_project//:/--}.gpg" || return 1
  echo "deb ${try_url} /" \
    | sudo tee "/etc/apt/sources.list.d/${package_name}.list" > /dev/null
}

# ── Misc helpers ──────────────────────────────────────────────────────────────

install_font() {
  local font_name="$1" url="$2" ext="$3"
  fc-list | grep -qi "$font_name" && { log "  Font already installed: $font_name"; return 0; }
  local tmp; tmp=$(mktemp -d)
  if wget -q --tries=1 --connect-timeout=15 -O "$tmp/font.zip" "$url" \
      && unzip -q "$tmp/font.zip" -d "$tmp/font"; then
    find "$tmp/font" -name "*.$ext" -exec cp {} ~/.local/share/fonts/ \;
  else
    log "  WARNING: Could not download font: $font_name"
  fi
  rm -rf "$tmp"
}

github_latest() {
  local repo="$1" glob="$2"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | grep -Po '"browser_download_url": "\K[^"]+'"$glob"'[^"]*(?=")' | head -1
}

has_nvidia() {
  command -v lspci &>/dev/null && lspci | grep -qi "NVIDIA" && return 0
  grep -rqi "0x10de" /sys/bus/pci/devices/*/vendor 2>/dev/null && return 0
  return 1
}

# ── Idempotency helpers ───────────────────────────────────────────────────────
pkg_installed() {
  case "$PKG_MGR" in
    apt) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "^install ok" ;;
    dnf) rpm -q "$1" &>/dev/null ;;
  esac
}
cmd_exists()       { command -v "$1" &>/dev/null; }
flatpak_installed(){ flatpak info "$1" &>/dev/null 2>&1; }
snap_installed()   { snap list "$1" &>/dev/null 2>&1; }

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight
# ─────────────────────────────────────────────────────────────────────────────
preflight() {
  logecho "$DISTRO $VERSION_ID — setup starting"
  logecho "Log: $LOG_FILE"

  # Ensure whiptail is available
  if ! command -v whiptail &>/dev/null; then
    case "$PKG_MGR" in
      apt) sudo apt-get install -y whiptail ;;
      dnf) sudo dnf install -y newt ;;
    esac
  fi

  # Ubuntu: pre-seed mscorefonts EULA
  if [[ "$DISTRO" == "ubuntu" ]]; then
    echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" \
      | sudo debconf-set-selections 2>/dev/null || true
  fi

  # Fedora: ensure RPM Fusion is set up (needed for NVIDIA, Steam, codecs)
  [[ "$DISTRO" == "fedora" ]] && setup_rpmfusion

  # Whiptail colour theme — palette-independent (black/white only)
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
}

# =============================================================================
# INSTALL FUNCTIONS
# =============================================================================

install_base() {
  pkg_update
  case "$PKG_MGR" in
    apt)
      pkg_install curl gpg wget git unzip ca-certificates
      pkg_install ubuntu-restricted-extras
      # Ruby build deps (mise compiles Ruby from source)
      pkg_install autoconf patch build-essential rustc \
        libssl-dev libyaml-dev libreadline-dev \
        zlib1g-dev libgmp-dev libncurses5-dev \
        libffi-dev libgdbm6 libgdbm-dev libdb-dev uuid-dev \
        pkg-config bison clang libjemalloc2
      pkg_install libvips imagemagick libmagickwand-dev mupdf mupdf-tools
      pkg_install redis-tools sqlite3 libsqlite3-0 libpq-dev postgresql-client \
        gir1.2-gtop-2.0
      if version_gte "$VERSION_ID" "25.04"; then
        pkg_install default-libmysqlclient-dev || true
      else
        pkg_install libmysqlclient-dev || true
      fi
      pkg_install wl-clipboard xdg-utils
      ;;
    dnf)
      pkg_install curl wget git unzip ca-certificates
      # Multimedia codecs via RPM Fusion
      sudo dnf group install -y multimedia || true
      # Ruby build deps — exact list from https://github.com/rbenv/ruby-build/wiki#fedora
      # Install individually so one bad package name doesn't fail the whole group
      local ruby_deps=(autoconf gcc rust patch make bzip2
        openssl-devel libyaml-devel libffi-devel
        readline-devel gdbm-devel ncurses-devel perl-FindBin)
      for p in "${ruby_deps[@]}"; do
        sudo dnf install -y "$p" 2>/dev/null \
          || log "  NOTE: $p not available — skipping"
      done
      # Fedora 40+ uses zlib-ng-compat-devel; <= 39 uses zlib-devel
      if version_gte "$FEDORA_VER" "40"; then
        sudo dnf install -y zlib-ng-compat-devel 2>/dev/null \
          || sudo dnf install -y zlib-devel 2>/dev/null || true
      else
        sudo dnf install -y zlib-devel 2>/dev/null || true
      fi
      # Image processing — correct Fedora package names
      sudo dnf install -y vips-devel ImageMagick 2>/dev/null || true
      # mupdf not in Fedora repos — skip silently
      # Database clients
      sudo dnf install -y redis sqlite libpq postgresql 2>/dev/null || true
      # sqlite-devel for native gem compilation
      sudo dnf install -y sqlite-devel libpq-devel 2>/dev/null || true
      # MySQL — community-mysql-devel is not a real package; use mysql-devel
      sudo dnf install -y mysql-devel 2>/dev/null \
        || sudo dnf install -y mariadb-devel 2>/dev/null || true
      pkg_install wl-clipboard xdg-utils
      ;;
  esac
}

install_fedora_tweaks() {
  # Present each tweak individually so the user can pick what they want
  local choices
  choices=$(whiptail --title "Fedora Tweaks" --checklist \
    "Select tweaks to apply:" 22 72 10 \
    "dnf"       "DNF: fastestmirror + 10 parallel downloads"  ON \
    "flathub"   "Flathub: remove content filter"              ON \
    "openh264"  "Enable Cisco OpenH264 codec (Firefox H.264)" ON \
    "ffmpeg"    "Swap ffmpeg-free → full FFmpeg (RPM Fusion)"  ON \
    "fstrim"    "Enable weekly fstrim timer (SSD health)"      ON \
    "zram"      "zRAM: switch compression to zstd"            ON \
    "firmware"  "Check + apply firmware updates (fwupdmgr)"   ON \
    "systemd"   "Reduce systemd stop timeout: 90s → 15s"      ON \
    3>&1 1>&2 2>&3 </dev/tty >/dev/tty) || return 0

  [[ "$choices" == *'"dnf"'* ]] && {
    sudo dnf config-manager setopt fastestmirror=True max_parallel_downloads=10
    log "  DNF: fastestmirror and parallel downloads enabled."
  }

  [[ "$choices" == *'"flathub"'* ]] && {
    flatpak remote-modify --no-filter --enable flathub 2>/dev/null || true
    log "  Flathub: content filter removed."
  }

  [[ "$choices" == *'"openh264"'* ]] && {
    sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1
    sudo dnf install -y openh264 gstreamer1-plugin-openh264 mozilla-openh264 2>/dev/null || true
    log "  Cisco OpenH264 enabled."
  }

  [[ "$choices" == *'"ffmpeg"'* ]] && {
    sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing 2>/dev/null || true
    sudo dnf groupupdate -y multimedia \
      --setop="install_weak_deps=False" \
      --exclude=PackageKit-gstreamer-plugin 2>/dev/null || true
    sudo dnf groupupdate -y sound-and-video 2>/dev/null || true
    log "  Full FFmpeg installed."
  }

  [[ "$choices" == *'"fstrim"'* ]] && {
    sudo systemctl enable --now fstrim.timer
    log "  fstrim timer enabled (weekly SSD TRIM)."
  }

  [[ "$choices" == *'"zram"'* ]] && {
    local zram_conf="/usr/lib/systemd/zram-generator.conf"
    if [[ -f "$zram_conf" ]]; then
      sudo sed -i '/^compression-algorithm/d' "$zram_conf"
      echo "compression-algorithm = zstd" | sudo tee -a "$zram_conf" > /dev/null
      log "  zRAM compression switched to zstd."
    else
      log "  WARNING: zram-generator.conf not found — skipping zRAM tweak."
    fi
  }

  [[ "$choices" == *'"firmware"'* ]] && {
    sudo fwupdmgr refresh --force 2>/dev/null || true
    sudo fwupdmgr get-updates 2>/dev/null || true
    sudo timeout 600 fwupdmgr update --no-reboot-check 2>/dev/null || true
    log "  Firmware update check complete."
  }

  [[ "$choices" == *'"systemd"'* ]] && {
    sudo sed -i 's/^#*DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=15s/' \
      /etc/systemd/system.conf
    sudo systemctl daemon-reexec 2>/dev/null || true
    log "  systemd stop timeout reduced to 15s."
  }
}

remove_fedora_tweaks() {
  # Restore DNF defaults
  sudo dnf config-manager setopt fastestmirror=False max_parallel_downloads=3 2>/dev/null || true
  # Restore systemd timeout
  sudo sed -i 's/^DefaultTimeoutStopSec=.*/# DefaultTimeoutStopSec=90s/' \
    /etc/systemd/system.conf 2>/dev/null || true
  sudo systemctl daemon-reexec 2>/dev/null || true
  log "  Fedora tweaks removed."
}

install_ubuntu_tweaks() {
  local choices
  choices=$(whiptail --title "Ubuntu Tweaks" --checklist \
    "Select tweaks to apply:" 18 72 6 \
    "firmware"  "Check + apply firmware updates (fwupdmgr)"   ON \
    "systemd"   "Reduce systemd stop timeout: 90s → 15s"      ON \
    "apport"    "Disable apport crash reporting to Canonical"  ON \
    "repos"     "Enable universe + multiverse repositories"    ON \
    3>&1 1>&2 2>&3 </dev/tty >/dev/tty) || return 0

  [[ "$choices" == *'"firmware"'* ]] && {
    sudo fwupdmgr refresh --force 2>/dev/null || true
    sudo fwupdmgr get-updates 2>/dev/null || true
    sudo timeout 600 fwupdmgr update --no-reboot-check 2>/dev/null || true
    log "  Firmware update check complete."
  }

  [[ "$choices" == *'"systemd"'* ]] && {
    sudo sed -i 's/^#*DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=15s/' \
      /etc/systemd/system.conf
    sudo systemctl daemon-reexec 2>/dev/null || true
    log "  systemd stop timeout reduced to 15s."
  }

  [[ "$choices" == *'"apport"'* ]] && {
    sudo sed -i 's/^enabled=1/enabled=0/' /etc/default/apport 2>/dev/null || true
    sudo systemctl disable --now apport 2>/dev/null || true
    log "  apport crash reporting disabled."
  }

  [[ "$choices" == *'"repos"'* ]] && {
    sudo add-apt-repository -y universe 2>/dev/null || true
    sudo add-apt-repository -y multiverse 2>/dev/null || true
    sudo apt-get update -y
    log "  universe + multiverse repositories enabled."
  }
}

remove_ubuntu_tweaks() {
  sudo sed -i 's/^DefaultTimeoutStopSec=.*/# DefaultTimeoutStopSec=90s/' \
    /etc/systemd/system.conf 2>/dev/null || true
  sudo systemctl daemon-reexec 2>/dev/null || true
  sudo sed -i 's/^enabled=0/enabled=1/' /etc/default/apport 2>/dev/null || true
  log "  Ubuntu tweaks removed."
}


install_flatpak_base() {
  case "$PKG_MGR" in
    apt) pkg_install flatpak gnome-software-plugin-flatpak ;;
    dnf) pkg_install flatpak ;;
  esac
  flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo
}

remove_flatpak_base() {
  pkg_remove flatpak gnome-software-plugin-flatpak 2>/dev/null || true
  log "  Flatpak removed."
}

remove_base() {
  # Removing base build tools is risky — other software may silently depend on them.
  # We deliberately do not automate this.
  log "  SKIPPED: Base packages are shared system dependencies."
  log "           Removing them could break other software."
  log "           If you need to clean up, run: sudo apt autoremove   (Ubuntu)"
  log "                                     or: sudo dnf autoremove   (Fedora)"
}

# Ensure ~/.my.zsh is sourced from ~/.zshrc via z4h. Called by install_zsh
# AFTER the wizard completes — never from install_dotfiles, which runs before
# zsh in dispatch order (when z4h doesn't exist yet). Note z4h is a zsh
# function, not a binary, so presence is checked via ~/.local/share/z4h —
# `command -v z4h` in bash would always fail, even when z4h is installed.
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

install_zsh() {
  case "$PKG_MGR" in
    apt) pkg_install zsh fonts-font-awesome ;;
    dnf) pkg_install zsh fontawesome-fonts ;;
  esac

  # Change default shell to zsh
  if [[ "$(getent passwd "$USER" | cut -d: -f7)" != "$(which zsh)" ]]; then
    sudo chsh -s "$(which zsh)" "$USER" \
      || log "  WARNING: Could not change shell — run: chsh -s \$(which zsh)"
  fi

  # Pre-flight: z4h clones from GitHub, and p10k wants MesloLGS NF present
  # before the wizard runs (font-blind wizard picks degraded glyphs).
  if ! command -v git &>/dev/null; then
    log "  WARNING: git not found — z4h needs it to clone. Install git first."
    return 1
  fi
  if ! fc-list 2>/dev/null | grep -qi "MesloLGS"; then
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

  # z4h installs itself and then EXECS a new zsh session, which would replace
  # our script's shell and prevent the rest of the install from running.
  # Fix: run it in a new terminal window so it can take over that shell
  # without affecting ours.
  echo ""
  echo "  A new terminal window will open for the zsh4humans wizard."
  echo "  Complete the wizard in that window, then return here."
  echo ""

  local z4h_cmd='sh -c "$(curl -fsSL https://raw.githubusercontent.com/romkatv/zsh4humans/v5/install)"'

  # Try common terminal emulators in order
  if command -v ghostty &>/dev/null; then
    ghostty -e bash -c "$z4h_cmd; echo 'z4h setup complete — close this window'; exec bash" &
  elif command -v alacritty &>/dev/null; then
    alacritty -e bash -c "$z4h_cmd; echo 'z4h setup complete — close this window'; exec bash" &
  elif command -v gnome-terminal &>/dev/null; then
    gnome-terminal -- bash -c "$z4h_cmd; echo 'z4h setup complete — close this window'; exec bash" &
  elif command -v xterm &>/dev/null; then
    xterm -e bash -c "$z4h_cmd; echo 'z4h setup complete — close this window'; exec bash" &
  else
    # No terminal emulator found — run inline but warn user.
    # Safe only because zsh is the LAST registry item: even if z4h replaces
    # this shell, nothing else is left to run.
    echo "  WARNING: No terminal emulator found. Running z4h inline."
    echo "  The script will resume automatically when z4h is done."
    bash -c "$z4h_cmd" || true
    ensure_myzsh_sourced
    return 0
  fi

  local term_pid=$!
  echo "  Waiting for z4h wizard to complete..."
  echo "  (Complete the wizard in the new window, then close it)"
  # Bounded wait (30 min): fg steps have no run_step watchdog, so an
  # abandoned window must not hang the script forever. We never kill the
  # terminal — just stop waiting and continue.
  local waited=0
  while kill -0 "$term_pid" 2>/dev/null && [[ $waited -lt 1800 ]]; do
    sleep 5
    waited=$(( waited + 5 ))
  done
  if kill -0 "$term_pid" 2>/dev/null; then
    log "  WARNING: timed out waiting for z4h wizard (30 min) — continuing."
    log "  Close the wizard window yourself when done."
  else
    wait "$term_pid" 2>/dev/null || true
  fi
  ensure_myzsh_sourced
}

remove_zsh() {
  sudo chsh -s "$(which bash)" "$USER"
  pkg_remove zsh
  rm -rf ~/.config/zsh ~/.zshrc ~/.p10k.zsh ~/.zsh_history \
    ~/.local/share/z4h ~/.cache/zsh 2>/dev/null || true
  log "  Zsh removed. Shell restored to bash."
}

install_fonts() {
  mkdir -p ~/.local/share/fonts
  install_font "FiraMono Nerd Font" \
    "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FiraMono.zip" "otf"
  install_font "JetBrainsMono Nerd Font" \
    "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip" "ttf"
  install_font "MesloLGS Nerd Font" \
    "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip" "ttf"
  install_font "CaskaydiaMono Nerd Font" \
    "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/CascadiaMono.zip" "ttf"
  install_font "0xProto Nerd Font" \
    "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/0xProto.zip" "ttf"
  local tmp; tmp=$(mktemp -d)
  wget -q --tries=1 --connect-timeout=15 \
    -O "$tmp/ia.zip" "https://github.com/iaolo/iA-Fonts/archive/refs/heads/master.zip" \
    && unzip -q "$tmp/ia.zip" -d "$tmp/ia" \
    && find "$tmp/ia" -name "iAWriterMonoS-*.ttf" -exec cp {} ~/.local/share/fonts/ \; || true
  rm -rf "$tmp"
  local p10k_base="https://github.com/romkatv/powerlevel10k-media/raw/master"
  for f in "MesloLGS NF Regular" "MesloLGS NF Bold" "MesloLGS NF Italic" "MesloLGS NF Bold Italic"; do
    wget -q --tries=1 --connect-timeout=15 \
      -O ~/.local/share/fonts/"${f}.ttf" "${p10k_base}/${f// /%20}.ttf" || true
  done
  local tmp2; tmp2=$(mktemp -d)
  git clone --depth=1 https://github.com/githubnext/monaspace.git "$tmp2/monaspace"
  mkdir -p ~/.local/share/fonts/Monaspace
  find "$tmp2/monaspace/fonts" \( -name "*.otf" -o -name "*.ttf" \) \
    -exec cp {} ~/.local/share/fonts/Monaspace/ \;
  rm -rf "$tmp2"
  fc-cache -f
}

remove_fonts() {
  rm -rf ~/.local/share/fonts/Monaspace 2>/dev/null || true
  find ~/.local/share/fonts \( -name "MesloLGS*" -o -name "iAWriterMono*" \
    -o -name "FiraMono*" -o -name "JetBrainsMono*" -o -name "CaskaydiaMono*" \
    -o -name "0xProto*" \) \
    -delete 2>/dev/null || true
  fc-cache -f
  log "  Fonts removed."
}

install_fastfetch() {
  case "$PKG_MGR" in
    apt)
      if version_gte "$VERSION_ID" "24.04"; then
        pkg_install fastfetch 2>/dev/null || {
          sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
          sudo apt-get update -y && pkg_install fastfetch
        }
      else
        sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
        sudo apt-get update -y && pkg_install fastfetch
      fi
      ;;
    dnf) pkg_install fastfetch || true ;;
  esac
}

remove_fastfetch() {
  pkg_remove fastfetch || true
  [[ "$PKG_MGR" == "apt" ]] && \
    sudo add-apt-repository -r -y ppa:zhangsongcui3371/fastfetch 2>/dev/null || true
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

# ── Terminal tools ────────────────────────────────────────────────────────────
install_terminal_tools() {
  # CLI productivity tools only — fzf, ripgrep, bat, eza, zoxide, btop, fd, tldr
  # Each installed individually so a renamed/missing package doesn't fail the rest.
  case "$PKG_MGR" in
    apt)
      local pkgs=(fzf ripgrep bat eza zoxide plocate btop)
      for p in "${pkgs[@]}"; do
        sudo apt-get install -y "$p" 2>/dev/null \
          || log "  NOTE: $p not available in this release — skipping"
      done
      # fd packaged as fd-find on Ubuntu due to name conflict
      sudo apt-get install -y fd-find 2>/dev/null \
        || sudo apt-get install -y fd 2>/dev/null || true
      if command -v fdfind &>/dev/null && ! command -v fd &>/dev/null; then
        mkdir -p ~/.local/bin && ln -sf "$(which fdfind)" ~/.local/bin/fd
      fi
      # tldr renamed to tealdeer in Ubuntu 26.04
      sudo apt-get install -y tldr 2>/dev/null \
        || sudo apt-get install -y tealdeer 2>/dev/null || true
      ;;
    dnf)
      local pkgs=(fzf ripgrep bat eza zoxide mlocate btop fd-find)
      for p in "${pkgs[@]}"; do
        sudo dnf install -y "$p" 2>/dev/null \
          || log "  NOTE: $p not available — skipping"
      done
      sudo dnf install -y tldr 2>/dev/null || sudo dnf install -y tealdeer 2>/dev/null || true
      ;;
  esac
}

remove_terminal_tools() {
  case "$PKG_MGR" in
    apt) pkg_remove fzf ripgrep bat eza zoxide plocate btop fd-find tldr tealdeer 2>/dev/null || true ;;
    dnf) pkg_remove fzf ripgrep bat eza zoxide mlocate btop fd-find tldr tealdeer 2>/dev/null || true ;;
  esac
  log "  Terminal tools removed."
}

install_alacritty() {
  # Alacritty — GPU-accelerated terminal emulator
  # Config file: ~/.config/alacritty/alacritty.toml
  case "$PKG_MGR" in
    apt)
      sudo apt-get install -y alacritty \
        || log "  WARNING: alacritty not available — try: flatpak install flathub org.alacritty.Alacritty"
      ;;
    dnf)
      # Official Fedora COPR for Alacritty — prebuilt, no cargo compile needed
      # pschyska/alacritty is the community-standard COPR referenced in Alacritty's own README
      if sudo dnf install -y alacritty 2>/dev/null; then
        log "  Alacritty installed via dnf."
      else
        sudo dnf copr enable -y pschyska/alacritty 2>/dev/null || true
        sudo dnf install -y alacritty \
          || log "  WARNING: Alacritty COPR install failed"
      fi
      ;;
  esac
  # Theme collection
  mkdir -p ~/.config/alacritty/themes
  git clone --depth=1 https://github.com/alacritty/alacritty-theme \
    ~/.config/alacritty/themes 2>/dev/null \
    || git -C ~/.config/alacritty/themes pull 2>/dev/null || true
  [[ -f "$SCRIPT_DIR/alacritty.toml" ]] && \
    cp "$SCRIPT_DIR/alacritty.toml" ~/.config/alacritty/
}

remove_alacritty() {
  case "$PKG_MGR" in
    apt) pkg_remove alacritty || true ;;
    dnf) flatpak uninstall -y --noninteractive org.alacritty.Alacritty 2>/dev/null || true ;;
  esac
  rm -rf ~/.config/alacritty 2>/dev/null || true
  log "  Alacritty removed."
}

install_zellij() {
  case "$PKG_MGR" in
    apt)
      sudo snap install zellij --classic \
        || log "  WARNING: Zellij snap install failed"
      ;;
    dnf)
      # Use prebuilt binary from GitHub releases — compiling from source takes
      # 20-30 min and frequently fails on missing deps
      local url; url=$(github_latest "zellij-org/zellij" "zellij-x86_64-unknown-linux-musl.tar.gz")
      if [[ -n "$url" ]]; then
        local tmp; tmp=$(mktemp -d /tmp/setup-XXXXXX)
        curl -fsSL --connect-timeout 15 --max-time 120 --location \
          -o "$tmp/zellij.tar.gz" "$url" \
          && tar -xf "$tmp/zellij.tar.gz" -C "$tmp" \
          && sudo install "$tmp/zellij" /usr/local/bin/zellij \
          || log "  WARNING: Zellij binary install failed"
        rm -rf "$tmp"
      else
        log "  WARNING: Could not resolve Zellij download URL (GitHub rate limit?)"
      fi
      ;;
  esac
}

remove_zellij() {
  sudo snap remove zellij 2>/dev/null || true
  sudo rm -f /usr/local/bin/zellij 2>/dev/null || true
  rm -rf ~/.config/zellij 2>/dev/null || true
  log "  Zellij removed."
}


install_ghostty() {
  case "$PKG_MGR" in
    apt)
      if version_gte "$VERSION_ID" "26.04"; then
        sudo add-apt-repository -y universe
        sudo apt-get update -y
        pkg_install ghostty 2>/dev/null || {
          log "  ghostty not in universe on $VERSION_ID — falling back to PPA"
          curl -fsSL --connect-timeout 15 --max-time 60 \
            https://raw.githubusercontent.com/mkasberg/ghostty-ubuntu/HEAD/install.sh | bash || true
        }
      else
        curl -fsSL --connect-timeout 15 --max-time 60 \
          https://raw.githubusercontent.com/mkasberg/ghostty-ubuntu/HEAD/install.sh | bash || true
      fi
      ;;
    dnf)
      # Try official Fedora repos first (available from F41+)
      # Fall back to COPR for versions where it's not in official repos yet
      if ! sudo dnf install -y ghostty 2>/dev/null; then
        log "  ghostty not in official repos — trying COPR scottames/ghostty"
        sudo dnf copr enable -y scottames/ghostty 2>/dev/null || true
        sudo dnf install -y ghostty \
          || log "  WARNING: Ghostty install failed — install manually: dnf copr enable scottames/ghostty && dnf install ghostty"
      fi
      ;;
  esac
  # Shared ghostty config (same file install.mac.sh uses; XDG path works there too)
  mkdir -p ~/.config/ghostty
  [[ -f "$SCRIPT_DIR/config.ghostty" ]] && \
    cp "$SCRIPT_DIR/config.ghostty" ~/.config/ghostty/config.ghostty
}

remove_ghostty() {
  pkg_remove ghostty || true
  [[ "$PKG_MGR" == "apt" ]] && \
    sudo add-apt-repository -r -y ppa:mkasberg/ghostty-ubuntu 2>/dev/null || true
  rm -rf ~/.config/ghostty 2>/dev/null || true
  log "  Ghostty removed."
}

install_tmux() {
  case "$PKG_MGR" in
    apt) sudo apt-get install -y tmux || log "  WARNING: tmux install failed"
         sudo apt-get install -y yq 2>/dev/null || true ;;
    dnf) pkg_install tmux; pkg_install yq 2>/dev/null || true ;;
  esac
  if [[ ! -d ~/.tmux/plugins/tpm ]]; then
    git clone --depth=1 https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
  fi
  [[ -f "$SCRIPT_DIR/.tmux.conf" ]] && cp "$SCRIPT_DIR/.tmux.conf" ~/
}

remove_tmux() {
  pkg_remove tmux || true
  rm -rf ~/.tmux ~/.tmux.conf 2>/dev/null || true
  log "  tmux and TPM removed."
}

install_lazygit() {
  case "$PKG_MGR" in
    dnf)
      # Official Fedora method: COPR repo from https://github.com/jesseduffield/lazygit
      sudo dnf copr enable -y dejan/lazygit 2>/dev/null || true
      sudo dnf install -y lazygit \
        || log "  WARNING: LazyGit COPR install failed"
      ;;
    apt)
      # Ubuntu 25.10+ / Debian Trixie+: lazygit is in the official repos
      # Earlier releases: download binary from GitHub releases
      if version_gte "$VERSION_ID" "25.10"; then
        sudo apt-get install -y lazygit \
          || log "  WARNING: lazygit apt install failed"
      else
        local version arch
        version=$(curl -fsSL --connect-timeout 15 \
          "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" \
          | grep -Po '"tag_name": *"v\K[^"]*') || true
        if [[ -z "$version" ]]; then
          log "  WARNING: Could not resolve LazyGit version (GitHub API rate limit?)"
          return 1
        fi
        arch=$(uname -m | sed -e 's/aarch64/arm64/' -e 's/x86_64/x86_64/')
        local tmp; tmp=$(mktemp -d /tmp/setup-XXXXXX)
        curl -fsSL --connect-timeout 15 --max-time 60 \
          -o "$tmp/lazygit.tar.gz" \
          "https://github.com/jesseduffield/lazygit/releases/download/v${version}/lazygit_${version}_Linux_${arch}.tar.gz"
        tar -xf "$tmp/lazygit.tar.gz" -C "$tmp" lazygit
        sudo install "$tmp/lazygit" -D -t /usr/local/bin/
        rm -rf "$tmp"
      fi
      ;;
  esac
  mkdir -p ~/.config/lazygit && touch ~/.config/lazygit/config.yml
}

remove_lazygit() {
  case "$PKG_MGR" in
    dnf) sudo dnf remove -y lazygit 2>/dev/null || true ;;
    apt) sudo rm -f /usr/local/bin/lazygit ;;
  esac
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
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "  WARNING: Dotfiles not found beside script: ${missing[*]}"
    log "  Expected: $script_dir/{.my.zsh,.tmux.conf,alacritty.toml}"
    return 1
  fi
}

remove_dotfiles() {
  rm -f ~/.my.zsh ~/.tmux.conf ~/.config/alacritty/alacritty.toml 2>/dev/null || true
  [[ -f ~/.zshrc ]] && sed -i '/z4h source ~\/.my.zsh/d' ~/.zshrc || true
  log "  Dotfiles removed."
}

# ── Editors ───────────────────────────────────────────────────────────────────
install_neovim() {
  case "$PKG_MGR" in
    apt)
      sudo snap install nvim --classic
      pkg_install luarocks
      ;;
    dnf)
      pkg_install neovim luarocks
      ;;
  esac
  if command -v npm &>/dev/null; then
    npm install -g tree-sitter-cli || true
  else
    log "  NOTE: Install tree-sitter-cli after Node: npm install -g tree-sitter-cli"
  fi
  if [[ ! -d ~/.config/nvim ]]; then
    git clone https://github.com/LazyVim/starter ~/.config/nvim
    rm -rf ~/.config/nvim/.git
  fi
}

remove_neovim() {
  [[ "$PKG_MGR" == "apt" ]] && sudo snap remove nvim 2>/dev/null || true
  pkg_remove neovim luarocks 2>/dev/null || true
  rm -rf ~/.config/nvim ~/.local/share/nvim ~/.cache/nvim 2>/dev/null || true
  log "  Neovim removed."
}

install_zed() {
  # Official install script — works on all distros, installs to ~/.local/bin/zed
  curl -fsSL --connect-timeout 15 --max-time 120 https://zed.dev/install.sh | sh \
    || log "  WARNING: Zed install failed"
}

remove_zed() {
  rm -f ~/.local/bin/zed ~/.local/share/applications/zed.desktop \
    ~/.local/share/icons/zed.png 2>/dev/null || true
  rm -rf ~/.local/lib/zed 2>/dev/null || true
  log "  Zed removed. Config preserved at ~/.config/zed/"
}

install_vscode() {
  case "$PKG_MGR" in
    apt)
      apt_add_repo \
        --name "vscode" \
        --key-url "https://packages.microsoft.com/keys/microsoft.asc" \
        --keyring "/etc/apt/keyrings/packages.microsoft.gpg" \
        --repo-line "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
        --repo-file "/etc/apt/sources.list.d/vscode.list" \
        --packages "code"
      ;;
    dnf)
      sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
      printf "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc\n" \
        | sudo tee /etc/yum.repos.d/vscode.repo > /dev/null
      pkg_install code
      ;;
  esac
}

remove_vscode() {
  pkg_remove code || true
  sudo rm -f /etc/apt/sources.list.d/vscode.list /etc/apt/keyrings/packages.microsoft.gpg \
    /etc/yum.repos.d/vscode.repo 2>/dev/null || true
  log "  VS Code removed."
}

install_vscodium() {
  case "$PKG_MGR" in
    apt)
      apt_add_repo \
        --name "vscodium" \
        --key-url "https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg" \
        --keyring "/usr/share/keyrings/vscodium-archive-keyring.gpg" \
        --repo-line "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/vscodium-archive-keyring.gpg] https://download.vscodium.com/debs vscodium main" \
        --repo-file "/etc/apt/sources.list.d/vscodium.list" \
        --packages "codium"
      ;;
    dnf)
      # VSCodium provides an official RPM repo
      if ! curl -fsSL --connect-timeout 15 --max-time 30 \
          https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg \
          | sudo tee /etc/pki/rpm-gpg/RPM-GPG-KEY-vscodium > /dev/null; then
        log "  WARNING: VSCodium GPG key fetch failed"; return 1
      fi
      printf "[vscodium]\nname=VSCodium\nbaseurl=https://download.vscodium.com/rpms/\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-vscodium\n" \
        | sudo tee /etc/yum.repos.d/vscodium.repo > /dev/null
      pkg_install codium
      ;;
  esac
}

remove_vscodium() {
  pkg_remove codium || true
  sudo rm -f /etc/apt/sources.list.d/vscodium.list \
    /usr/share/keyrings/vscodium-archive-keyring.gpg \
    /etc/yum.repos.d/vscodium.repo 2>/dev/null || true
  log "  VSCodium removed."
}

install_sublime() {
  case "$PKG_MGR" in
    apt)
      if ! wget -q --tries=1 --connect-timeout=15 --timeout=30 \
          -O - https://download.sublimetext.com/sublimehq-pub.gpg \
          | sudo tee /etc/apt/keyrings/sublimehq-pub.asc > /dev/null; then
        log "  WARNING: Sublime GPG key fetch failed"; return 1
      fi
      [[ ! -s /etc/apt/keyrings/sublimehq-pub.asc ]] && {
        log "  WARNING: Sublime key empty"; return 1; }
      printf 'Types: deb\nURIs: https://download.sublimetext.com/\nSuites: apt/stable/\nSigned-By: /etc/apt/keyrings/sublimehq-pub.asc\n' \
        | sudo tee /etc/apt/sources.list.d/sublime-text.sources > /dev/null
      sudo apt-get update -y && pkg_install sublime-text sublime-merge
      ;;
    dnf)
      sudo rpm -v --import https://download.sublimetext.com/sublimehq-rpm-pub.gpg
      sudo dnf config-manager addrepo \
        --from-repofile=https://download.sublimetext.com/rpm/stable/x86_64/sublime-text.repo \
        2>/dev/null || true
      pkg_install sublime-text sublime-merge
      ;;
  esac
}

remove_sublime() {
  pkg_remove sublime-text sublime-merge || true
  sudo rm -f /etc/apt/sources.list.d/sublime-text.sources \
    /etc/apt/keyrings/sublimehq-pub.asc 2>/dev/null || true
  log "  Sublime removed."
}

# ── Browsers ──────────────────────────────────────────────────────────────────
install_brave() {
  case "$PKG_MGR" in
    apt)
      apt_add_repo \
        --name "brave" \
        --key-url "https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg" \
        --keyring "/usr/share/keyrings/brave-browser-archive-keyring.gpg" \
        --repo-line "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" \
        --repo-file "/etc/apt/sources.list.d/brave-browser-release.list" \
        --packages "brave-browser"
      ;;
    dnf)
      sudo dnf config-manager addrepo \
        --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo \
        2>/dev/null || true
      pkg_install brave-browser
      ;;
  esac
}

remove_brave() {
  pkg_remove brave-browser || true
  sudo rm -f /etc/apt/sources.list.d/brave-browser-release.list \
    /usr/share/keyrings/brave-browser-archive-keyring.gpg 2>/dev/null || true
  log "  Brave removed."
}

install_chrome() {
  local tmp; tmp=$(mktemp -d)
  case "$PKG_MGR" in
    apt)
      wget -q --tries=1 --connect-timeout=15 \
        -O "$tmp/chrome.deb" \
        https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
      pkg_install "$tmp/chrome.deb" || log "  WARNING: Chrome install failed"
      ;;
    dnf)
      wget -q --tries=1 --connect-timeout=15 \
        -O "$tmp/chrome.rpm" \
        https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm
      sudo dnf install -y "$tmp/chrome.rpm" || log "  WARNING: Chrome install failed"
      ;;
  esac
  rm -rf "$tmp"
}

remove_chrome() {
  pkg_remove google-chrome-stable || true
  log "  Chrome removed."
}

install_firefox_dev() {
  # Tarball from Mozilla — distro-agnostic, always latest
  local tmp; tmp=$(mktemp -d)
  wget -q --tries=1 --connect-timeout=15 \
    -O "$tmp/firefox-dev.tar.xz" \
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
  case "$PKG_MGR" in
    apt)
      apt_add_repo \
        --name "microsoft-edge" \
        --key-url "https://packages.microsoft.com/keys/microsoft.asc" \
        --keyring "/usr/share/keyrings/microsoft-edge.gpg" \
        --repo-line "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-edge.gpg] https://packages.microsoft.com/repos/edge stable main" \
        --repo-file "/etc/apt/sources.list.d/microsoft-edge.list" \
        --packages "microsoft-edge-stable"
      ;;
    dnf)
      sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
      printf "[microsoft-edge]\nname=Microsoft Edge\nbaseurl=https://packages.microsoft.com/yumrepos/edge\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc\n" \
        | sudo tee /etc/yum.repos.d/microsoft-edge.repo > /dev/null
      pkg_install microsoft-edge-stable
      ;;
  esac
}

remove_edge() {
  pkg_remove microsoft-edge-stable || true
  sudo rm -f /etc/apt/sources.list.d/microsoft-edge.list \
    /usr/share/keyrings/microsoft-edge.gpg \
    /etc/yum.repos.d/microsoft-edge.repo 2>/dev/null || true
  log "  Edge removed."
}

# ── Dev Tools ─────────────────────────────────────────────────────────────────
install_docker() {
  case "$PKG_MGR" in
    apt)
      # Official install method from docs.docker.com/engine/install/ubuntu/
      # Key is already in binary (non-armored) format — download directly with sudo curl,
      # no gpg dearmoring needed. This is exactly what the official docs prescribe.
      sudo apt-get install -y ca-certificates curl
      sudo install -m 0755 -d /etc/apt/keyrings
      sudo rm -f /etc/apt/keyrings/docker.asc
      log "  [docker] Fetching GPG key..."
      if ! sudo curl -fsSL --connect-timeout 15 --max-time 30 \
          https://download.docker.com/linux/ubuntu/gpg \
          -o /etc/apt/keyrings/docker.asc; then
        log "  WARNING: [docker] GPG key fetch failed — aborting"; return 1
      fi
      sudo chmod a+r /etc/apt/keyrings/docker.asc

      # DEB822 .sources format using official codename detection
      sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null << EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

      if ! sudo apt-get update \
          -o Dir::Etc::sourcelist="/etc/apt/sources.list.d/docker.sources" \
          -o Dir::Etc::sourcelistd="" \
          -o APT::Get::List-Cleanup="0" -y 2>/dev/null; then
        log "  WARNING: [docker] apt update failed — aborting"
        sudo rm -f /etc/apt/sources.list.d/docker.sources
        return 1
      fi

      DEBIAN_FRONTEND=noninteractive sudo -E apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin \
        || { log "  WARNING: [docker] Package install failed"; return 1; }
      ;;
    dnf)
      sudo dnf config-manager addrepo \
        --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo \
        2>/dev/null || true
      pkg_install docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
      sudo systemctl enable --now docker
      ;;
  esac
  sudo usermod -aG docker "$USER"
  echo '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"5"}}' \
    | sudo tee /etc/docker/daemon.json > /dev/null
  # LazyDocker
  local url; url=$(github_latest "jesseduffield/lazydocker" "Linux_x86_64.tar.gz")
  if [[ -n "$url" ]]; then
    local tmp; tmp=$(mktemp -d /tmp/setup-XXXXXX)
    wget -q --tries=1 --connect-timeout=15 -O "$tmp/ld.tar.gz" "$url"
    tar -xf "$tmp/ld.tar.gz" -C "$tmp" lazydocker
    sudo install "$tmp/lazydocker" /usr/local/bin/lazydocker
    rm -rf "$tmp"
  fi
  log "  Docker installed. Log out and back in to use docker without sudo."
}

remove_docker() {
  log "  WARNING: This will remove Docker AND ALL containers, images, volumes."
  if whiptail --title "Remove Docker" \
    --yesno "Remove Docker and ALL containers/images/volumes?\n\nThis CANNOT be undone." \
    10 62 </dev/tty >/dev/tty; then
    sudo systemctl stop docker 2>/dev/null || true
    pkg_remove docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || true
    sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker
    sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc \
      /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true
    sudo gpasswd -d "$USER" docker 2>/dev/null || true
    sudo rm -f /usr/local/bin/lazydocker
    log "  Docker removed."
  else
    log "  Docker removal cancelled."
  fi
}

install_mise() {
  curl -fsSL https://mise.run | sh
  local mise_bin="$HOME/.local/bin/mise"
  [[ ! -x "$mise_bin" ]] && { log "  WARNING: mise not found after install"; return 1; }
  export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
  "$mise_bin" use --global python@latest
  "$mise_bin" use --global node@lts
  "$mise_bin" use --global ruby@latest
  "$mise_bin" settings add idiomatic_version_file_enable_tools ruby,node
  for rc in ~/.zshrc ~/.bashrc; do
    [[ -f "$rc" ]] && ! grep -q 'mise activate' "$rc" && \
      echo 'eval "$(~/.local/bin/mise activate $(basename $SHELL))"' >> "$rc"
  done
  "$mise_bin" exec -- npm install -g tree-sitter-cli 2>/dev/null || true
  log "  mise installed. Python, Node, and Ruby available."
}

remove_mise() {
  rm -rf ~/.local/share/mise ~/.local/bin/mise ~/.config/mise ~/.cache/mise 2>/dev/null || true
  for rc in ~/.zshrc ~/.bashrc; do
    [[ -f "$rc" ]] && sed -i '/mise activate/d' "$rc" || true
  done
  log "  mise removed."
}

# ── Launchers ─────────────────────────────────────────────────────────────────
install_albert() {
  case "$PKG_MGR" in
    apt)
      add_obs_repo "home:manuelschneid3r" "albert" && \
        sudo apt-get update -y && pkg_install albert || \
        log "  WARNING: albert not available for Ubuntu $VERSION_ID yet"
      ;;
    dnf)
      local obs_url="https://download.opensuse.org/repositories/home:manuelschneid3r/Fedora_${FEDORA_VER}/"
      if curl -fsSL --head "${obs_url}Release" &>/dev/null; then
        sudo dnf config-manager --add-repo "${obs_url}home:manuelschneid3r.repo" 2>/dev/null || true
        pkg_install albert
      else
        log "  WARNING: Albert OBS repo not available for Fedora $FEDORA_VER"
      fi
      ;;
  esac
}

remove_albert() {
  pkg_remove albert || true
  sudo rm -f /etc/apt/sources.list.d/albert.list \
    /etc/apt/trusted.gpg.d/home--manuelschneid3r.gpg 2>/dev/null || true
  log "  Albert removed."
}

install_ulauncher() {
  case "$PKG_MGR" in
    apt)
      sudo add-apt-repository -y universe
      sudo add-apt-repository -y ppa:agornostal/ulauncher
      sudo apt-get update -y && pkg_install ulauncher || \
        log "  WARNING: ulauncher PPA may not support $VERSION_ID yet"
      ;;
    dnf)
      # ULauncher is in Fedora's main repos from F38+
      pkg_install ulauncher || log "  WARNING: ulauncher not available for Fedora $FEDORA_VER"
      ;;
  esac
}

remove_ulauncher() {
  pkg_remove ulauncher || true
  [[ "$PKG_MGR" == "apt" ]] && \
    sudo add-apt-repository -r -y ppa:agornostal/ulauncher 2>/dev/null || true
  log "  ULauncher removed."
}

# ── Apps ──────────────────────────────────────────────────────────────────────
install_slack() {
  case "$PKG_MGR" in
    apt)
      local tmp; tmp=$(mktemp -d)
      wget -q --tries=1 --connect-timeout=15 \
        -O "$tmp/slack.deb" \
        "https://downloads.slack-edge.com/desktop-releases/linux/x64/latest/slack-desktop-latest-amd64.deb" \
        && pkg_install "$tmp/slack.deb" && rm -rf "$tmp" && return 0
      rm -rf "$tmp"
      sudo snap install slack 2>/dev/null && return 0 || true
      flatpak install -y --noninteractive flathub com.slack.Slack 2>/dev/null || \
        log "  WARNING: All Slack install methods failed"
      ;;
    dnf)
      # Snap not available on Fedora — use Flatpak
      flatpak install -y --noninteractive flathub com.slack.Slack 2>/dev/null || \
        log "  WARNING: Slack Flatpak failed on Fedora"
      ;;
  esac
}

remove_slack() {
  pkg_remove slack-desktop 2>/dev/null || true
  sudo snap remove slack 2>/dev/null || true
  flatpak uninstall -y --noninteractive com.slack.Slack 2>/dev/null || true
  log "  Slack removed."
}

install_spotify() {
  case "$PKG_MGR" in
    apt)
      # Official method from https://www.spotify.com/download/linux/
      # Uses --yes on gpg (non-blocking) and trusted.gpg.d/ as the key destination
      # This function is --fg so curl|gpg pipe has a real stdin
      curl -sS https://download.spotify.com/debian/pubkey_5384CE82BA52C83A.asc \
        | sudo gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/spotify.gpg \
        || { log "  Spotify GPG key failed — trying snap fallback"; \
             sudo snap install spotify 2>/dev/null && return 0 || true
             log "  WARNING: All Spotify install methods failed"; return 1; }
      echo "deb https://repository.spotify.com stable non-free" \
        | sudo tee /etc/apt/sources.list.d/spotify.list > /dev/null
      sudo apt-get update \
        -o Dir::Etc::sourcelist="/etc/apt/sources.list.d/spotify.list" \
        -o Dir::Etc::sourcelistd="" \
        -o APT::Get::List-Cleanup="0" -y 2>/dev/null || true
      pkg_install spotify-client \
        || { sudo rm -f /etc/apt/trusted.gpg.d/spotify.gpg \
                        /etc/apt/sources.list.d/spotify.list
             log "  Spotify apt failed — trying snap"
             sudo snap install spotify 2>/dev/null \
               || log "  WARNING: All Spotify install methods failed"; }
      ;;
    dnf)
      flatpak install -y --noninteractive flathub com.spotify.Client 2>/dev/null \
        || log "  WARNING: Spotify Flatpak failed on Fedora"
      ;;
  esac
}

remove_spotify() {
  pkg_remove spotify-client 2>/dev/null || true
  sudo rm -f /etc/apt/trusted.gpg.d/spotify.gpg \
             /usr/share/keyrings/spotify.gpg \
             /etc/apt/sources.list.d/spotify.list 2>/dev/null || true
  sudo snap remove spotify 2>/dev/null || true
  flatpak uninstall -y --noninteractive com.spotify.Client 2>/dev/null || true
  log "  Spotify removed."
}

install_zoom() {
  local tmp; tmp=$(mktemp -d)
  case "$PKG_MGR" in
    apt)
      wget -q --tries=1 --connect-timeout=15 \
        -O "$tmp/zoom.deb" "https://zoom.us/client/latest/zoom_amd64.deb" \
        && pkg_install "$tmp/zoom.deb" && rm -rf "$tmp" && return 0
      rm -rf "$tmp"
      ;;
    dnf)
      wget -q --tries=1 --connect-timeout=15 \
        -O "$tmp/zoom.rpm" "https://zoom.us/client/latest/zoom_x86_64.rpm" \
        && sudo dnf install -y "$tmp/zoom.rpm" && rm -rf "$tmp" && return 0
      rm -rf "$tmp"
      ;;
  esac
  flatpak install -y --noninteractive flathub us.zoom.Zoom 2>/dev/null || \
    log "  WARNING: Zoom Flatpak fallback failed"
}

remove_zoom() {
  pkg_remove zoom 2>/dev/null || true
  flatpak uninstall -y --noninteractive us.zoom.Zoom 2>/dev/null || true
  log "  Zoom removed."
}

install_obsidian() {
  # Native .deb or .rpm from GitHub releases
  case "$PKG_MGR" in
    apt)
      local url; url=$(github_latest "obsidianmd/obsidian-releases" "_amd64.deb")
      if [[ -n "$url" ]]; then
        local tmp; tmp=$(mktemp -d)
        wget -q --tries=1 --connect-timeout=15 -O "$tmp/obsidian.deb" "$url" \
          && pkg_install "$tmp/obsidian.deb" && rm -rf "$tmp" && return 0
        rm -rf "$tmp"
      fi
      ;;
    dnf)
      local url; url=$(github_latest "obsidianmd/obsidian-releases" "x86_64.rpm")
      if [[ -n "$url" ]]; then
        local tmp; tmp=$(mktemp -d)
        wget -q --tries=1 --connect-timeout=15 -O "$tmp/obsidian.rpm" "$url" \
          && sudo dnf install -y "$tmp/obsidian.rpm" && rm -rf "$tmp" && return 0
        rm -rf "$tmp"
      fi
      ;;
  esac
  flatpak install -y --noninteractive flathub md.obsidian.Obsidian 2>/dev/null || \
    log "  WARNING: Obsidian Flatpak fallback failed"
}

remove_obsidian() {
  pkg_remove obsidian 2>/dev/null || true
  flatpak uninstall -y --noninteractive md.obsidian.Obsidian 2>/dev/null || true
  log "  Obsidian removed."
}

install_dropbox() {
  case "$PKG_MGR" in
    apt)
      # Ubuntu: scrape latest .deb from linux.dropbox.com
      sudo apt-get install -y python3-gpg 2>/dev/null || true
      local latest_deb
      latest_deb=$(curl -fsSL --connect-timeout 15 --max-time 15 \
        "https://linux.dropbox.com/packages/ubuntu/" \
        | grep -oP 'dropbox_[\d.]+_amd64\.deb' | sort -V | tail -1)
      if [[ -n "$latest_deb" ]]; then
        local tmp; tmp=$(mktemp -d /tmp/setup-XXXXXX)
        wget -q --tries=1 --connect-timeout=15 \
          -O "$tmp/dropbox.deb" \
          "https://linux.dropbox.com/packages/ubuntu/${latest_deb}" \
          && pkg_install "$tmp/dropbox.deb" && rm -rf "$tmp" && return 0
        rm -rf "$tmp"
      fi
      pkg_install nautilus-dropbox \
        || log "  WARNING: Dropbox apt install failed"
      ;;
    dnf)
      # Fedora: no official RPM — use Flatpak
      flatpak remote-modify --no-filter --enable flathub 2>/dev/null || true
      flatpak install -y --noninteractive flathub com.dropbox.Client 2>/dev/null \
        || log "  WARNING: Dropbox Flatpak failed — install manually from dropbox.com/install-linux"
      ;;
  esac
  log "  Dropbox installed. Launch from the app menu to sign in."
}

remove_dropbox() {
  dropbox stop 2>/dev/null || true
  pkg_remove dropbox nautilus-dropbox 2>/dev/null || true
  rm -rf ~/.dropbox-dist 2>/dev/null || true
  log "  Dropbox removed. ~/Dropbox and ~/.dropbox preserved."
}

install_1password() {
  case "$PKG_MGR" in
    apt)
      local tmp; tmp=$(mktemp -d)
      wget -q --tries=1 --connect-timeout=15 \
        -O "$tmp/1password.deb" \
        https://downloads.1password.com/linux/debian/amd64/stable/1password-latest.deb
      pkg_install "$tmp/1password.deb" || log "  WARNING: 1Password install failed"
      rm -rf "$tmp"
      ;;
    dnf)
      sudo rpm --import https://downloads.1password.com/linux/keys/1password.asc
      printf "[1password]\nname=1Password Stable\nbaseurl=https://downloads.1password.com/linux/rpm/stable/\$basearch\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=https://downloads.1password.com/linux/keys/1password.asc\n" \
        | sudo tee /etc/yum.repos.d/1password.repo > /dev/null
      pkg_install 1password
      ;;
  esac
}

remove_1password() {
  pkg_remove 1password || true
  sudo rm -f /etc/yum.repos.d/1password.repo 2>/dev/null || true
  log "  1Password removed."
}

install_localsend() {
  case "$PKG_MGR" in
    apt)
      local url; url=$(github_latest "localsend/localsend" "linux-x86-64.deb")
      if [[ -n "$url" ]]; then
        local tmp; tmp=$(mktemp -d /tmp/setup-XXXXXX)
        wget -q --tries=1 --connect-timeout=15 -O "$tmp/localsend.deb" "$url" \
          && pkg_install "$tmp/localsend.deb" \
          || log "  WARNING: LocalSend install failed"
        rm -rf "$tmp"
      else
        log "  WARNING: Could not resolve LocalSend download URL (GitHub rate limit?)"
      fi
      ;;
    dnf)
      # Flatpak is the recommended method on Fedora
      flatpak remote-modify --no-filter --enable flathub 2>/dev/null || true
      flatpak install -y --noninteractive flathub org.localsend.localsend_app \
        || log "  WARNING: LocalSend Flatpak install failed"
      ;;
  esac
}

remove_localsend() {
  pkg_remove localsend 2>/dev/null || true
  flatpak uninstall -y --noninteractive org.localsend.localsend_app 2>/dev/null || true
  log "  LocalSend removed."
}

install_pomodoro() {
  case "$PKG_MGR" in
    apt)
      local url; url=$(github_latest "roldanjr/pomatez" "linux-amd64.deb")
      [[ -n "$url" ]] && { local tmp; tmp=$(mktemp -d)
        wget -q --tries=1 --connect-timeout=15 -O "$tmp/pomatez.deb" "$url"
        pkg_install "$tmp/pomatez.deb"; rm -rf "$tmp"; }
      ;;
    dnf)
      local url; url=$(github_latest "roldanjr/pomatez" "x86_64.rpm")
      [[ -n "$url" ]] && { local tmp; tmp=$(mktemp -d)
        wget -q --tries=1 --connect-timeout=15 -O "$tmp/pomatez.rpm" "$url"
        sudo dnf install -y "$tmp/pomatez.rpm"; rm -rf "$tmp"; }
      ;;
  esac
}

remove_pomodoro() {
  pkg_remove pomatez || true; log "  Pomatez removed."
}

# ── AI apps ───────────────────────────────────────────────────────────────────
install_claude_code() {
  # The official install script downloads a binary and runs 'claude install'
  # which sets up shell integration. It needs stdout/stderr for user prompts.
  # We restore them here so the interactive portion works correctly even
  # when run_step_fg redirects output to the log.
  local tmp; tmp=$(mktemp --suffix=.sh)
  if ! curl -fsSL --connect-timeout 15 --max-time 60 \
      https://claude.ai/install.sh -o "$tmp"; then
    log "  WARNING: Could not download Claude Code install script"
    rm -f "$tmp"; return 1
  fi
  chmod +x "$tmp"
  # Restore terminal I/O so the 'claude install' sub-step can interact with the user
  bash "$tmp" </dev/tty >/dev/tty 2>/dev/tty \
    || log "  WARNING: Claude Code install failed"
  rm -f "$tmp"
}

remove_claude_code() {
  npm uninstall -g @anthropic-ai/claude-code 2>/dev/null \
    || rm -f "$(command -v claude 2>/dev/null)" || true
  log "  Claude Code removed."
}

install_claude_desktop() {
  case "$PKG_MGR" in
    apt)
      # Official install method from pkg.claude-desktop-debian.dev
      # Runs in foreground (--fg in registry) so curl|gpg pipe has a real stdin
      curl -fsSL --connect-timeout 15 --max-time 30 \
        https://pkg.claude-desktop-debian.dev/KEY.gpg \
        | sudo gpg --dearmor -o /usr/share/keyrings/claude-desktop.gpg \
        || { log "  WARNING: [claude-desktop] GPG key fetch failed"; return 1; }
      echo "deb [signed-by=/usr/share/keyrings/claude-desktop.gpg arch=amd64,arm64] https://pkg.claude-desktop-debian.dev stable main" \
        | sudo tee /etc/apt/sources.list.d/claude-desktop.list > /dev/null
      sudo apt-get update \
        -o Dir::Etc::sourcelist="/etc/apt/sources.list.d/claude-desktop.list" \
        -o Dir::Etc::sourcelistd="" \
        -o APT::Get::List-Cleanup="0" -y 2>/dev/null || sudo apt-get update -y || true
      DEBIAN_FRONTEND=noninteractive sudo -E apt-get install -y \
        -o DPkg::Lock::Timeout=60 claude-desktop \
        || { log "  WARNING: claude-desktop install failed"; return 1; }
      ;;
    dnf)
      sudo curl -fsSL --connect-timeout 15 --max-time 30 \
        https://pkg.claude-desktop-debian.dev/rpm/claude-desktop.repo \
        -o /etc/yum.repos.d/claude-desktop.repo \
        || { log "  WARNING: [claude-desktop] Could not fetch RPM repo file"; return 1; }
      sudo dnf install -y claude-desktop \
        || { log "  WARNING: claude-desktop dnf install failed"; return 1; }
      ;;
  esac
  log "  Claude Desktop installed."
  log "  MCP config: ~/.config/Claude/claude_desktop_config.json"
}

remove_claude_desktop() {
  pkg_remove claude-desktop || true
  sudo rm -f /usr/share/keyrings/claude-desktop.gpg \
    /etc/apt/sources.list.d/claude-desktop.list \
    /etc/yum.repos.d/claude-desktop.repo 2>/dev/null || true
  log "  Claude Desktop removed."
}

install_lmstudio() {
  # .deb on Ubuntu, AppImage on Fedora
  case "$PKG_MGR" in
    apt)
      local tmp; tmp=$(mktemp -d)
      wget -q --tries=1 --connect-timeout=15 \
        -O "$tmp/lmstudio.deb" \
        "https://lmstudio.ai/download/latest/linux/x64?format=deb" \
        && pkg_install "$tmp/lmstudio.deb" || log "  WARNING: LM Studio .deb install failed"
      rm -rf "$tmp"
      ;;
    dnf)
      local tmp; tmp=$(mktemp -d)
      pkg_install fuse fuse-libs || true
      wget -q --tries=1 --connect-timeout=15 \
        -O "$tmp/LMStudio.AppImage" \
        "https://lmstudio.ai/download/latest/linux/x64?format=AppImage" \
        && sudo mkdir -p /opt/LMStudio \
        && sudo install "$tmp/LMStudio.AppImage" /opt/LMStudio/LM-Studio.AppImage \
        && mkdir -p ~/.local/share/applications \
        && cat > ~/.local/share/applications/lmstudio.desktop << 'EOF'
[Desktop Entry]
Name=LM Studio
Exec=/opt/LMStudio/LM-Studio.AppImage --no-sandbox
Icon=lmstudio
Type=Application
Terminal=false
Categories=Development;ArtificialIntelligence;
EOF
      rm -rf "$tmp"
      ;;
  esac
}

remove_lmstudio() {
  pkg_remove lmstudio 2>/dev/null || true
  sudo rm -f /opt/LMStudio/LM-Studio.AppImage \
    ~/.local/share/applications/lmstudio.desktop 2>/dev/null || true
  log "  LM Studio removed."
}

install_chatbox() {
  # libfuse for AppImage support
  case "$PKG_MGR" in
    apt)
      version_gte "$VERSION_ID" "24.04" \
        && pkg_install libfuse2t64 2>/dev/null \
        || pkg_install libfuse2 2>/dev/null || true
      sudo add-apt-repository -y universe && sudo apt-get update -y
      ;;
    dnf) pkg_install fuse fuse-libs || true ;;
  esac
  local tmp; tmp=$(mktemp -d)
  if wget -q --tries=1 --connect-timeout=15 \
      -O "$tmp/Chatbox.AppImage" "https://chatboxai.app/install_chatbox/linux"; then
    sudo mkdir -p /opt/ChatboxAi
    sudo install "$tmp/Chatbox.AppImage" /opt/ChatboxAi/ChatboxAi.AppImage
    sudo wget -q --timeout=15 -O /usr/share/icons/chatboxai.png \
      https://chatboxai.app/icon.png || true
    mkdir -p ~/.local/share/applications
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

remove_chatbox() {
  sudo rm -f /opt/ChatboxAi/ChatboxAi.AppImage \
    ~/.local/share/applications/chatboxai.desktop \
    /usr/share/icons/chatboxai.png
  sudo rmdir /opt/ChatboxAi 2>/dev/null || true
  log "  Chatbox removed."
}

# ── Gaming ─────────────────────────────────────────────────────────────────────
install_nvidia_drivers() {
  if ! has_nvidia; then
    log "  No NVIDIA GPU detected — skipping."; return 0
  fi
  log "  NVIDIA GPU detected."
  case "$PKG_MGR" in
    apt)
      pkg_install ubuntu-drivers-common pciutils
      ubuntu-drivers devices 2>&1 | tee -a "$LOG_FILE" || true
      sudo ubuntu-drivers install \
        || log "  WARNING: ubuntu-drivers failed — try: sudo ubuntu-drivers install nvidia:580"
      sudo dpkg --add-architecture i386
      sudo apt-get update -y
      pkg_install vulkan-tools libvulkan1 libvulkan1:i386 \
        nvidia-vaapi-driver || true
      ;;
    dnf)
      # RPM Fusion (set up in preflight) provides akmod-nvidia
      # akmod builds the kernel module in the background after install (2-5 min)
      pkg_install akmod-nvidia xorg-x11-drv-nvidia-cuda \
        || log "  WARNING: akmod-nvidia install failed"
      pkg_install vulkan-tools vulkan-loader vulkan-loader.i686 \
        libva-nvidia-driver || true
      # Enable Wayland modesetting
      echo "options nvidia-drm modeset=1" \
        | sudo tee /etc/modprobe.d/nvidia-drm.conf > /dev/null
      sudo dracut --force 2>/dev/null || true
      log "  IMPORTANT: akmod is building the NVIDIA kernel module in the background."
      log "             Wait until 'modinfo -F version nvidia' shows a version number"
      log "             (takes 2-5 min) BEFORE rebooting. Rebooting too early = black screen."
      ;;
  esac
  log "  NOTE: A reboot is required before the NVIDIA driver takes effect."
}

remove_nvidia() {
  log "  WARNING: NVIDIA driver removal cannot be automated safely from a live session."
  log "  Manual steps:"
  log "    Ubuntu: sudo apt purge ~nnvidia && sudo apt autoremove"
  log "    Fedora: sudo dnf remove akmod-nvidia xorg-x11-drv-nvidia* && sudo dracut --force"
  log "    Then reboot."
  whiptail --title "NVIDIA — Manual Removal Required" \
    --msgbox "NVIDIA driver removal cannot be automated safely.\n\nSee $LOG_FILE for instructions.\n\nUbuntu: sudo apt purge ~nnvidia && sudo apt autoremove\nFedora: sudo dnf remove akmod-nvidia xorg-x11-drv-nvidia*\n\nThen reboot." \
    16 66 </dev/tty >/dev/tty
}

install_gaming_stack() {
  case "$PKG_MGR" in
    apt)
      sudo dpkg --add-architecture i386
      sudo apt-get update -y
      # Remove stale steam.list if present — Steam's .deb writes steam-stable.list
      sudo rm -f /etc/apt/sources.list.d/steam.list
      local tmp_steam; tmp_steam=$(mktemp -d)
      wget -q --tries=1 --connect-timeout=15 \
        -O "$tmp_steam/steam.deb" \
        "https://cdn.akamai.steamstatic.com/client/installer/steam.deb" \
        && pkg_install "$tmp_steam/steam.deb" \
        || pkg_install steam-installer || true
      rm -rf "$tmp_steam"
      pkg_install vulkan-tools libvulkan1 libvulkan1:i386 \
        gamemode libgamemode0 libgamemodeauto0 mangohud || true
      ;;
    dnf)
      # Steam via RPM Fusion
      pkg_install steam || log "  WARNING: Steam install failed"
      pkg_install gamemode mangohud vulkan-tools vulkan-loader vulkan-loader.i686 || true
      ;;
  esac
  # Flatpak gaming apps — distro-agnostic
  flatpak install -y --noninteractive flathub \
    com.vysp3r.ProtonPlus net.lutris.Lutris com.heroicgameslauncher.hgl || true
  # vm.swappiness tweak
  if ! grep -q 'vm.swappiness' /etc/sysctl.d/99-gaming.conf 2>/dev/null; then
    echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-gaming.conf > /dev/null
    sudo sysctl --system > /dev/null
  fi
  log "  Gaming stack installed."
  log "  Steam launch options: gamemoderun mangohud %command%"
  log "  RTX cards add: PROTON_ENABLE_NVAPI=1 DXVK_ENABLE_NVAPI=1"
}

remove_gaming() {
  case "$PKG_MGR" in
    apt)
      pkg_remove gamemode libgamemode0 libgamemodeauto0 mangohud || true
      pkg_remove steam steam-launcher 2>/dev/null || true
      sudo rm -f /etc/apt/sources.list.d/steam*.list /usr/share/keyrings/steam.gpg
      ;;
    dnf)
      pkg_remove steam gamemode mangohud || true
      ;;
  esac
  flatpak uninstall -y --noninteractive \
    com.vysp3r.ProtonPlus net.lutris.Lutris com.heroicgameslauncher.hgl 2>/dev/null || true
  sudo rm -f /etc/sysctl.d/99-gaming.conf
  sudo sysctl -w vm.swappiness=60 >/dev/null 2>&1 || true
  log "  Gaming stack removed. Steam library data preserved."
}

install_wine_stack() {
  case "$PKG_MGR" in
    apt)
      sudo dpkg --add-architecture i386
      sudo apt-get update -y
      sudo mkdir -p /etc/apt/keyrings
      log "  [wine] Fetching WineHQ GPG key..."
      if ! _fetch_key "https://dl.winehq.org/wine-builds/winehq.key" \
          /etc/apt/keyrings/winehq-archive.key; then
        log "  WARNING: [wine] GPG key fetch failed — aborting Wine install"; return 1
      fi
      printf 'Types: deb\nURIs: https://dl.winehq.org/wine-builds/ubuntu/\nSuites: %s\nComponents: main\nSigned-By: /etc/apt/keyrings/winehq-archive.key\n' \
        "$CODENAME" | sudo tee /etc/apt/sources.list.d/winehq.sources > /dev/null
      sudo apt-get update -y
      DEBIAN_FRONTEND=noninteractive sudo -E apt-get install -y \
        --install-recommends winehq-stable \
        || log "  WARNING: winehq-stable failed — falling back to Ubuntu wine"
      command -v wine &>/dev/null || pkg_install wine wine32:i386 wine64 || true
      ;;
    dnf)
      # Wine is in RPM Fusion
      pkg_install wine wine-core wine-common || log "  WARNING: Wine install failed"
      ;;
  esac
  # Winetricks — latest from GitHub
  local wt_latest; wt_latest=$(github_latest "Winetricks/winetricks" "winetricks$")
  if [[ -n "$wt_latest" ]]; then
    wget -q --tries=1 --connect-timeout=15 -O /tmp/winetricks "$wt_latest"
    chmod +x /tmp/winetricks && sudo mv /tmp/winetricks /usr/local/bin/winetricks
  else
    pkg_install winetricks || true
  fi
  # Bottles — Flatpak only
  flatpak install -y --noninteractive flathub com.usebottles.bottles || true
  log "  Wine stack installed."
}

remove_wine_stack() {
  case "$PKG_MGR" in
    apt)
      pkg_remove winehq-stable wine wine32 wine64 winetricks || true
      sudo rm -f /usr/local/bin/winetricks \
        /etc/apt/sources.list.d/winehq.sources \
        /etc/apt/keyrings/winehq-archive.key
      ;;
    dnf)
      pkg_remove wine wine-core wine-common || true
      sudo rm -f /usr/local/bin/winetricks
      ;;
  esac
  flatpak uninstall -y --noninteractive com.usebottles.bottles 2>/dev/null || true
  log "  Wine stack removed. ~/.wine preserved."
}

install_gaming_extras() {
  # scx-scheds — Ubuntu 25.04+ via PPA; Fedora via COPR
  case "$PKG_MGR" in
    apt)
      if version_gte "$VERSION_ID" "25.04"; then
        # Try apt-cache first — on 26.04 scx ships in the main repos directly
        if apt-cache show scx &>/dev/null 2>&1; then
          pkg_install scx || log "  WARNING: scx install failed"
        else
          # Fall back to PPA — but verify it supports this release before keeping it
          sudo add-apt-repository -y ppa:arighi/sched-ext 2>/dev/null || true
          sudo apt-get update -y 2>/dev/null || true
          if apt-cache show scx &>/dev/null 2>&1; then
            pkg_install scx || log "  WARNING: scx-scheds PPA install failed"
          else
            log "  NOTE: scx PPA has no packages for $VERSION_ID yet — removing PPA"
            sudo add-apt-repository -r -y ppa:arighi/sched-ext 2>/dev/null || true
            # Remove any list files left behind
            sudo rm -f /etc/apt/sources.list.d/arighi-ubuntu-sched-ext-*.list
          fi
        fi
        if command -v scx &>/dev/null && systemctl list-unit-files scx.service &>/dev/null; then
          sudo sed -i 's/SCX_SCHEDULER=.*/SCX_SCHEDULER=scx_lavd/' \
            /etc/default/scx 2>/dev/null || true
          sudo systemctl enable --now scx 2>/dev/null || true
          log "  scx_lavd scheduler enabled."
        fi
      else
        log "  NOTE: scx-scheds requires Ubuntu 25.04+ — skipping on $VERSION_ID"
      fi
      ;;
    dnf)
      sudo dnf copr enable -y bieszczaders/kernel-cachyos-addons 2>/dev/null || true
      pkg_install scx-scheds || log "  WARNING: scx-scheds install failed on Fedora"
      ;;
  esac
  # vkBasalt, MangoHud — pin to current 25.08 runtime to avoid end-of-life warnings
  flatpak install -y --noninteractive flathub \
    runtime/org.freedesktop.Platform.VulkanLayer.vkBasalt/x86_64/25.08 2>/dev/null \
    || flatpak install -y --noninteractive flathub \
       org.freedesktop.Platform.VulkanLayer.vkBasalt 2>/dev/null || true
  flatpak install -y --noninteractive flathub \
    runtime/org.freedesktop.Platform.VulkanLayer.MangoHud/x86_64/25.08 2>/dev/null \
    || flatpak install -y --noninteractive flathub \
       org.freedesktop.Platform.VulkanLayer.MangoHud 2>/dev/null || true
  # GOverlay, OpenRGB, AntiMicroX — these don't have the runtime picker issue
  flatpak install -y --noninteractive flathub \
    io.github.benjamimgois.goverlay \
    org.openrgb.OpenRGB \
    io.github.antimicrox.antimicrox || true
  # jstest-gtk
  case "$PKG_MGR" in
    apt) pkg_install jstest-gtk || true ;;
    dnf) pkg_install jstest-gtk || true ;;
  esac
  # Input Remapper — .deb only for now; Fedora gets note
  case "$PKG_MGR" in
    apt)
      local ir_url; ir_url=$(github_latest "sezanzeb/input-remapper" "_amd64.deb")
      if [[ -n "$ir_url" ]]; then
        local tmp; tmp=$(mktemp -d)
        wget -q --tries=1 --connect-timeout=15 -O "$tmp/input-remapper.deb" "$ir_url"
        pkg_install "$tmp/input-remapper.deb" \
          && sudo systemctl enable --now input-remapper || true
        rm -rf "$tmp"
      fi
      ;;
    dnf)
      log "  NOTE: Input Remapper has no official RPM — install manually from GitHub."
      ;;
  esac
  # nvidia-vaapi-driver
  has_nvidia && pkg_install nvidia-vaapi-driver 2>/dev/null \
    libva-nvidia-driver 2>/dev/null || true
}

remove_gaming_extras() {
  sudo systemctl stop scx input-remapper 2>/dev/null || true
  sudo systemctl disable scx input-remapper 2>/dev/null || true
  case "$PKG_MGR" in
    apt)
      pkg_remove scx input-remapper jstest-gtk || true
      sudo add-apt-repository -r -y ppa:arighi/sched-ext 2>/dev/null || true
      ;;
    dnf) pkg_remove scx-scheds jstest-gtk || true ;;
  esac
  flatpak uninstall -y --noninteractive \
    org.freedesktop.Platform.VulkanLayer.vkBasalt \
    org.freedesktop.Platform.VulkanLayer.MangoHud \
    io.github.benjamimgois.goverlay org.openrgb.OpenRGB \
    io.github.antimicrox.antimicrox 2>/dev/null || true
  log "  Gaming extras removed."
}

install_xbox_controller() {
  # Install each dependency separately — a single missing package shouldn't block the rest
  sudo apt-get install -y dkms 2>/dev/null \
    || sudo dnf install -y dkms 2>/dev/null \
    || log "  WARNING: dkms install failed — DKMS modules may not build"
  sudo apt-get install -y "linux-headers-$(uname -r)" 2>/dev/null \
    || sudo apt-get install -y linux-headers-generic 2>/dev/null \
    || sudo dnf install -y "kernel-devel-$(uname -r)" 2>/dev/null \
    || sudo dnf install -y kernel-devel 2>/dev/null \
    || log "  WARNING: kernel headers install failed"
  sudo apt-get install -y bluez evtest 2>/dev/null \
    || sudo dnf install -y bluez evtest 2>/dev/null || true
  # Load uhid for Xbox Bluetooth firmware 5.x support
  if ! lsmod | grep -q "^uhid"; then
    sudo modprobe uhid 2>/dev/null || true
  fi
  grep -q "^uhid" /etc/modules 2>/dev/null \
    || echo "uhid" | sudo tee -a /etc/modules > /dev/null
  # xpadneo — full clone (no --depth=1) so git describe works
  if ! dkms status 2>/dev/null | grep -q xpadneo; then
    local tmp; tmp=$(mktemp -d)
    git clone https://github.com/atar-axis/xpadneo.git "$tmp/xpadneo"
    sudo git config --global --add safe.directory "$tmp/xpadneo"
    (cd "$tmp/xpadneo" && sudo ./install.sh) || log "  WARNING: xpadneo install failed"
    sudo git config --global --unset safe.directory "$tmp/xpadneo" 2>/dev/null || true
    rm -rf "$tmp"
  else
    log "  xpadneo already installed."
  fi
  # xone — USB dongle driver
  if ! dkms status 2>/dev/null | grep -q xone; then
    local tmp2; tmp2=$(mktemp -d)
    git clone https://github.com/dlundqvist/xone.git "$tmp2/xone"
    sudo git config --global --add safe.directory "$tmp2/xone"
    (cd "$tmp2/xone" && sudo ./install.sh --skip-disclaimer) || log "  WARNING: xone install failed"
    sudo git config --global --unset safe.directory "$tmp2/xone" 2>/dev/null || true
    rm -rf "$tmp2"
  else
    log "  xone already installed."
  fi
  log "  Controller setup complete. USB wired: plug in. Bluetooth: pair via Settings."
}

remove_controller() {
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
  if dkms status 2>/dev/null | grep -q xone; then
    local tmp2; tmp2=$(mktemp -d)
    git clone https://github.com/dlundqvist/xone.git "$tmp2/xone"
    sudo git config --global --add safe.directory "$tmp2/xone"
    (cd "$tmp2/xone" && sudo ./uninstall.sh --skip-disclaimer) || true
    sudo git config --global --unset safe.directory "$tmp2/xone" 2>/dev/null || true
    rm -rf "$tmp2"
  fi
  log "  Controller drivers removed."
}

# ── GNOME ─────────────────────────────────────────────────────────────────────
install_gnome() {
  local current_de="${XDG_CURRENT_DESKTOP:-}"
  if [[ "$current_de" != *"GNOME"* ]]; then
    log "  WARNING: Not a GNOME session ('${current_de:-unknown}') — skipping extensions."
    log "           Log into GNOME and re-run to apply."
    return 0
  fi

  case "$PKG_MGR" in
    apt)
      sudo apt-get install -y gnome-tweaks \
        || log "  WARNING: gnome-tweaks install failed"
      sudo apt-get install -y gnome-shell-extension-manager 2>/dev/null || true
      sudo apt-get install -y gnome-sushi 2>/dev/null || true
      sudo apt-get install -y pipx 2>/dev/null \
        || sudo apt-get install -y python3-pip 2>/dev/null || true
      ;;
    dnf)
      pkg_install gnome-tweaks gnome-extensions-app
      sudo dnf install -y pipx 2>/dev/null \
        || sudo dnf install -y python3-pip 2>/dev/null || true
      ;;
  esac

  if ! command -v gext &>/dev/null; then
    # Use system Python explicitly — mise may have shadowed python3/pip3 with its
    # own shim, causing version conflicts with pipx's environment detection.
    local sys_py
    sys_py=$(command -v python3.12 || command -v python3.11 || \
             command -v python3.10 || echo "/usr/bin/python3")
    if command -v pipx &>/dev/null; then
      pipx install gnome-extensions-cli \
        --python "$sys_py" \
        --system-site-packages 2>/dev/null || \
      pipx install gnome-extensions-cli \
        --system-site-packages || true
    elif command -v pip3 &>/dev/null; then
      "$sys_py" -m pip install --user gnome-extensions-cli 2>/dev/null || true
    fi
    export PATH="$HOME/.local/bin:$PATH"
  fi

  # On Fedora, dash-to-dock is in the official repos — install natively.
  # On Ubuntu, Ubuntu ships its own fork (ubuntu-dock) baked into the shell,
  # so dash-to-dock is only added on non-Ubuntu distros.
  local extensions=(
    "tactile@lundal.io"
    "blur-my-shell@aunetx"
    "space-bar@luchrioh"
    "tophat@fflewddur.github.io"
    "AlphabeticalAppGrid@stuarthayhurst"
    "caffeine@patapon.info"
  )

  if [[ "$DISTRO" != "ubuntu" ]]; then
    # Fedora GNOME doesn't have a dock by default — install dash-to-dock
    case "$PKG_MGR" in
      dnf)
        pkg_install gnome-shell-extension-dash-to-dock \
          && log "  dash-to-dock installed via dnf." \
          || extensions+=("dash-to-dock@micxgx.gmail.com")
        ;;
      *) extensions+=("dash-to-dock@micxgx.gmail.com") ;;
    esac
  fi

  for ext in "${extensions[@]}"; do
    gext install "$ext" 2>/dev/null || log "  WARNING: Could not install extension: $ext"
  done

  # Compile Tactile schema before setting gsettings
  local tactile_schema="$HOME/.local/share/gnome-shell/extensions/tactile@lundal.io/schemas/org.gnome.shell.extensions.tactile.gschema.xml"
  if [[ -f "$tactile_schema" ]]; then
    sudo cp "$tactile_schema" /usr/share/glib-2.0/schemas/
    sudo glib-compile-schemas /usr/share/glib-2.0/schemas/
    gsettings set org.gnome.shell.extensions.tactile col-0 1
    gsettings set org.gnome.shell.extensions.tactile col-1 2
    gsettings set org.gnome.shell.extensions.tactile col-2 1
    gsettings set org.gnome.shell.extensions.tactile col-3 0
    gsettings set org.gnome.shell.extensions.tactile row-0 1
    gsettings set org.gnome.shell.extensions.tactile row-1 1
    gsettings set org.gnome.shell.extensions.tactile gap-size 32
  fi

  # Click dock icon to minimise/restore — Ubuntu only (Fedora uses dash-to-dock settings)
  [[ "$DISTRO" == "ubuntu" ]] && \
    gsettings set org.gnome.shell.extensions.dash-to-dock click-action 'minimize' \
      2>/dev/null || true
}

remove_gnome() {
  case "$PKG_MGR" in
    apt) pkg_remove gnome-tweaks gnome-shell-extension-manager gnome-sushi || true ;;
    dnf) pkg_remove gnome-tweaks gnome-extensions-app \
           gnome-shell-extension-dash-to-dock || true ;;
  esac
  if command -v gext &>/dev/null; then
    local extensions=(
      "tactile@lundal.io" "blur-my-shell@aunetx" "space-bar@luchrioh"
      "tophat@fflewddur.github.io" "AlphabeticalAppGrid@stuarthayhurst"
      "caffeine@patapon.info" "dash-to-dock@micxgx.gmail.com"
    )
    for ext in "${extensions[@]}"; do gext uninstall "$ext" 2>/dev/null || true; done
  fi
  log "  GNOME extras removed. Core GNOME shell unaffected."
}

# =============================================================================
# ITEM REGISTRY
# =============================================================================
# Add/remove/move apps here. Everything else (UI, dispatch, detection) is
# derived automatically. See setup-ubuntu.sh for full documentation.
# =============================================================================

declare -a _REG_KEYS=()
declare -A _REG_CAT=() _REG_LABEL=() _REG_DEFAULT=()
declare -A _REG_DETECT=() _REG_INSTALL=() _REG_REMOVE=() _REG_FG=()

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

# Category display order — GNOME intentionally last (extensions need manual approval)
CATEGORIES=(
  "system:System"
  "terminal:Terminal"
  "editors:Editors"
  "browsers:Browsers"
  "devtools:Dev Tools"
  "launchers:Launchers"
  "apps:Apps"
  "ai:AI & Local LLMs"
  "gaming:Gaming"
  "gnome:GNOME"
)

# ── System ─────────────────────────────────────────────────────────────────────
register_item --key base --cat system \
  --label "Base packages + build tools + Ruby deps" --default ON \
  --detect 'pkg_installed build-essential || pkg_installed gcc' \
  --install install_base --remove remove_base

register_item --key mise --cat system --fg \
  --label "Mise + Python / Node LTS / Ruby" --default ON \
  --detect 'cmd_exists mise || [[ -x ~/.local/bin/mise ]]' \
  --install install_mise --remove remove_mise

register_item --key flatpak --cat system \
  --label "Flatpak + Flathub (required for app fallbacks)" --default ON \
  --detect 'cmd_exists flatpak && flatpak remotes 2>/dev/null | grep -q flathub' \
  --install install_flatpak_base --remove remove_flatpak_base

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

register_item --key fedora_tweaks --cat system --fg \
  --label "Fedora tweaks: DNF / FFmpeg / OpenH264 / fstrim / zRAM / firmware" --default ON \
  --detect '[[ "$DISTRO" != "fedora" ]] || sudo dnf config-manager --info 2>/dev/null | grep -q "fastestmirror = True"' \
  --install install_fedora_tweaks --remove remove_fedora_tweaks

register_item --key ubuntu_tweaks --cat system --fg \
  --label "Ubuntu tweaks: firmware / systemd timeout / apport / repos" --default ON \
  --detect '[[ "$DISTRO" != "ubuntu" ]] || [[ "$(grep -c DefaultTimeoutStopSec=15s /etc/systemd/system.conf 2>/dev/null)" -gt 0 ]]' \
  --install install_ubuntu_tweaks --remove remove_ubuntu_tweaks

# ── Terminal ───────────────────────────────────────────────────────────────────
register_item --key terminal --cat terminal \
  --label "CLI tools: fzf + ripgrep + bat + eza + zoxide + btop + fd" \
  --default ON \
  --detect 'cmd_exists fzf && cmd_exists bat' \
  --install install_terminal_tools --remove remove_terminal_tools

register_item --key alacritty --cat terminal \
  --label "Alacritty (GPU-accelerated terminal)" \
  --default ON \
  --detect 'cmd_exists alacritty || flatpak_installed org.alacritty.Alacritty' \
  --install install_alacritty --remove remove_alacritty

register_item --key zellij --cat terminal \
  --label "Zellij (terminal multiplexer)" \
  --default ON \
  --detect 'cmd_exists zellij' \
  --install install_zellij --remove remove_zellij

register_item --key ghostty --cat terminal \
  --label "Ghostty (GPU-accelerated GTK4 terminal)" --default ON \
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

register_item --key spotify --cat apps --fg \
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

register_item --key dropbox --cat apps \
  --label "Dropbox (cloud storage)" --default ON \
  --detect 'cmd_exists dropbox || pkg_installed nautilus-dropbox' \
  --install install_dropbox --remove remove_dropbox

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

# ── AI & Local LLMs ────────────────────────────────────────────────────────────
register_item --key claude_code --cat ai --fg \
  --label "Claude Code (CLI)" --default OFF \
  --detect 'cmd_exists claude' \
  --install install_claude_code --remove remove_claude_code

register_item --key claude_desktop --cat ai --fg \
  --label "Claude Desktop (apt on Ubuntu / dnf on Fedora)" --default OFF \
  --detect 'pkg_installed claude-desktop' \
  --install install_claude_desktop --remove remove_claude_desktop

register_item --key lmstudio --cat ai \
  --label "LM Studio (local AI GUI)" --default OFF \
  --detect 'pkg_installed lmstudio || [[ -x /opt/LMStudio/LM-Studio.AppImage ]]' \
  --install install_lmstudio --remove remove_lmstudio

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
  --detect 'cmd_exists steam || flatpak_installed com.valvesoftware.Steam' \
  --install install_gaming_stack --remove remove_gaming

register_item --key wine_stack --cat gaming \
  --label "Wine + Winetricks + Bottles" --default OFF \
  --detect 'cmd_exists wine && cmd_exists winetricks' \
  --install install_wine_stack --remove remove_wine_stack

register_item --key gaming_extras --cat gaming \
  --label "scx schedulers + vkBasalt + OpenRGB + AntiMicroX + Input Remapper" --default OFF \
  --detect 'flatpak_installed io.github.antimicrox.antimicrox' \
  --install install_gaming_extras --remove remove_gaming_extras

register_item --key controller --cat gaming \
  --label "Xbox controller (Bluetooth xpadneo + dongle xone)" --default OFF \
  --detect 'dkms status 2>/dev/null | grep -q xpadneo' \
  --install install_xbox_controller --remove remove_controller

# ── GNOME (last — extensions need manual browser approval) ─────────────────────
register_item --key gnome_setup --cat gnome \
  --label "GNOME tweaks + extensions + gsettings" --default ON \
  --detect 'pkg_installed gnome-tweaks' \
  --install install_gnome --remove remove_gnome

# ORDER CONSTRAINT — do not reorder without reading install_zsh:
# zsh stays LAST (wizard needs a terminal window + fonts installed, and its
# installer execs a shell that would kill the script mid-run), while fonts and
# dotfiles stay BEFORE it. Sourcing of ~/.my.zsh is owned by install_zsh
# (ensure_myzsh_sourced, post-wizard) — never by install_dotfiles.
# zsh runs last — z4h opens a new terminal window which requires a terminal
# emulator (Alacritty/Ghostty/gnome-terminal) to already be installed
register_item --key zsh --cat system --fg \
  --label "Zsh + zsh4humans + Powerlevel10k" --default ON \
  --detect 'pkg_installed zsh && [[ "$(getent passwd "$USER"|cut -d: -f7)" == */zsh ]]' \
  --install install_zsh --remove remove_zsh

# =============================================================================
# TREE UI — identical to setup-ubuntu.sh (button-free, ANSI bold/reverse)
# =============================================================================

_is_cat_row() { [[ "$1" == cat:* ]]; }

run_tree_ui() {
  local mode="$1"
  local -a all_rows=()
  local -A expanded=() checked=()

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
        eval "${_REG_DETECT[$key]}" 2>/dev/null && checked["$key"]=1 || checked["$key"]=0
      fi
    done
  done

  _vis() {
    local -a v=(); local r
    for r in "${all_rows[@]}"; do
      if _is_cat_row "$r"; then v+=("$r")
      else
        local c="${_REG_CAT[$r]}"
        [[ "${expanded[$c]:-0}" == "1" ]] && v+=("$r")
      fi
    done
    printf '%s\n' "${v[@]}"
  }

  local B='\033[1m' BRV='\033[1;7m' RST='\033[0m' CLR='\033[2K'
  local term_h; term_h=$(tput lines 2>/dev/null || echo 30)
  local term_w; term_w=$(tput cols  2>/dev/null || echo 80)
  local viewport=$(( term_h - 6 )); (( viewport < 4 )) && viewport=4
  local cursor=0 scroll=0

  printf '\033[?25l'
  tput smcup 2>/dev/null || true
  trap 'tput rmcup 2>/dev/null; printf "\033[?25h"' EXIT INT TERM
  clear

  _draw() {
    local -a vis; mapfile -t vis < <(_vis)
    local total=${#vis[@]}
    (( cursor >= total )) && cursor=$(( total - 1 ))
    (( cursor < 0 )) && cursor=0
    (( cursor < scroll )) && scroll=$cursor
    (( cursor >= scroll + viewport )) && scroll=$(( cursor - viewport + 1 ))
    tput cup 0 0

    local mode_label
    case "$mode" in install) mode_label="INSTALL";; uninstall) mode_label="UNINSTALL";; *) mode_label="UPDATE";; esac
    printf "${CLR}${B}  Setup — %s  ·  %s  ·  %s${RST}\n" \
      "${DISTRO^}" "$VERSION_ID" "$mode_label"
    printf "${CLR}${B}  ─────────────────────────────────────────────────────────${RST}\n"

    local i
    for (( i = scroll; i < scroll + viewport && i < total; i++ )); do
      local row="${vis[$i]}" line
      if _is_cat_row "$row"; then
        local ck="${row#cat:}" clabel="" ce
        for ce in "${CATEGORIES[@]}"; do
          [[ "${ce%%:*}" == "$ck" ]] && clabel="${ce#*:}" && break
        done
        local nc=0 nt=0 k
        for k in "${_REG_KEYS[@]}"; do
          [[ "${_REG_CAT[$k]}" != "$ck" ]] && continue
          nt=$(( nt+1 )); [[ "${checked[$k]:-0}" == "1" ]] && nc=$(( nc+1 ))
        done
        local box arr
        (( nc == 0 )) && box="[ ]" || (( nc == nt )) && box="[x]" || box="[-]"
        [[ "${expanded[$ck]:-0}" == "1" ]] && arr="▼" || arr="▶"
        line="  ${box} ${arr} ${clabel}  (${nc}/${nt})"
      else
        local chk; [[ "${checked[$row]:-0}" == "1" ]] && chk="[x]" || chk="[ ]"
        line="      ${chk} ${_REG_LABEL[$row]}"
      fi
      printf "${CLR}"
      (( i == cursor )) && printf "${BRV}%-${term_w}s${RST}\n" "$line" \
                         || printf "%-${term_w}s\n" "$line"
    done

    local ci; for (( ci = total-scroll; ci < viewport; ci++ )); do printf "${CLR}\n"; done
    printf "${CLR}\n"
    printf "${CLR}${B}  Space${RST}=toggle  ${B}↑↓/jk${RST}=move  ${B}←→/hl${RST}=collapse/expand  ${B}a${RST}=all  ${B}n${RST}=none  ${B}Enter${RST}=confirm  ${B}q${RST}=quit\n"
  }

  _draw
  while true; do
    local -a vis; mapfile -t vis < <(_vis)
    local total=${#vis[@]} cur_row="${vis[$cursor]:-}"
    local key esc
    IFS= read -rsn1 key
    if [[ $key == $'\033' ]]; then IFS= read -rsn2 -t 0.05 esc; key="${key}${esc}"; fi

    case "$key" in
      $'\033[A'|k) (( cursor > 0 )) && (( cursor-- )) ;;
      $'\033[B'|j) (( cursor < total-1 )) && (( cursor++ )) ;;
      $'\033[C'|l) _is_cat_row "$cur_row" && expanded["${cur_row#cat:}"]=1 ;;
      $'\033[D'|h)
        if _is_cat_row "$cur_row"; then expanded["${cur_row#cat:}"]=0
        else
          local parent="${_REG_CAT[$cur_row]}"; expanded["$parent"]=0
          local ri; for ri in "${!vis[@]}"; do
            [[ "${vis[$ri]}" == "cat:$parent" ]] && cursor=$ri && break; done
        fi ;;
      ' ')
        if _is_cat_row "$cur_row"; then
          local ck="${cur_row#cat:}" all1=1 k
          for k in "${_REG_KEYS[@]}"; do
            [[ "${_REG_CAT[$k]}" != "$ck" ]] && continue
            [[ "${checked[$k]:-0}" != "1" ]] && all1=0 && break; done
          local ns=$(( 1 - all1 ))
          for k in "${_REG_KEYS[@]}"; do [[ "${_REG_CAT[$k]}" == "$ck" ]] && checked["$k"]=$ns; done
        else
          [[ "${checked[$cur_row]:-0}" == "1" ]] && checked["$cur_row"]=0 || checked["$cur_row"]=1
        fi ;;
      a|A) local k; for k in "${_REG_KEYS[@]}"; do checked["$k"]=1; done ;;
      n|N) local k; for k in "${_REG_KEYS[@]}"; do checked["$k"]=0; done ;;
      ''|$'\n') break ;;
      q|Q) tput rmcup 2>/dev/null; printf '\033[?25h\n'; echo "Cancelled."; exit 0 ;;
    esac
    _draw
  done

  tput rmcup 2>/dev/null; printf '\033[?25h'
  trap - EXIT INT TERM
  SELECTED_ITEMS=()
  local k; for k in "${_REG_KEYS[@]}"; do
    [[ "${checked[$k]:-0}" == "1" ]] && SELECTED_ITEMS+=("$k"); done
}

# =============================================================================
# DISPATCH
# =============================================================================
dispatch() {
  local mode="$1" item
  for item in "${SELECTED_ITEMS[@]}"; do
    local fn label fg
    label="${_REG_LABEL[$item]:-$item}"
    fg="${_REG_FG[$item]:-0}"
    if [[ "$mode" == "uninstall" ]]; then
      fn="${_REG_REMOVE[$item]:-}"; label="Remove: $label"
    else
      fn="${_REG_INSTALL[$item]:-}"
    fi
    [[ -z "$fn" ]] && { log "  WARNING: No function for $item in $mode mode"; continue; }

    # Per-item timeouts for known slow steps
    local timeout="${STEP_TIMEOUT_SECS:-300}"
    case "$item" in
      edge)           timeout=180 ;;
      claude_desktop) timeout=180 ;;
      gaming_stack)   timeout=600 ;;
      wine_stack)     timeout=600 ;;
      gaming_extras)  timeout=600 ;;
      base)           timeout=600 ;;
      mise)           timeout=600 ;;
      lmstudio)       timeout=300 ;;
    esac

    if [[ "$fg" == "1" ]]; then STEP_TIMEOUT_SECS="$timeout" run_step_fg "$label" "$fn"
    else                        STEP_TIMEOUT_SECS="$timeout" run_step    "$label" "$fn"
    fi
  done
}

# =============================================================================
# MODE CHOOSER — arrow-key selector, no buttons
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

  printf '\033[?25l'; tput smcup 2>/dev/null || true; clear

  _draw_mode() {
    tput cup 0 0
    printf "${CLR}\n"
    printf "${CLR}  Setup — %s  %s\n" "${DISTRO^}" "$VERSION_ID"
    printf "${CLR}  ─────────────────────────────────────────────────────────\n"
    local i; for i in "${!options[@]}"; do
      printf "${CLR}"
      (( i == selected )) && printf "  ${BRV}▶ %s${RST}\n" "${labels[$i]}" \
                           || printf "    %s\n" "${labels[$i]}"
    done
    printf "${CLR}\n"
    printf "${CLR}  ↑↓ / j/k = move  |  Enter = confirm  |  q = quit\n"
  }

  _draw_mode
  while true; do
    local key esc
    IFS= read -rsn1 key
    if [[ $key == $'\033' ]]; then IFS= read -rsn2 -t 0.05 esc; key="${key}${esc}"; fi
    case "$key" in
      $'\033[A'|k) (( selected > 0 )) && (( selected-- )); _draw_mode ;;
      $'\033[B'|j) (( selected < ${#options[@]}-1 )) && (( selected++ )); _draw_mode ;;
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

  detect_distro
  preflight

  logecho "$DISTRO $VERSION_ID — distro detected, starting setup"

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
  whiptail --title "Done — ${DISTRO^} Setup" \
    --msgbox "${msg}\n\nLog: $LOG_FILE\n\nReminder: log out and back in if shell or docker group changed." \
       20 70 </dev/tty >/dev/tty
}

main "$@"