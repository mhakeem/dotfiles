# install.sh — Developer Guide

## Quick Start

```bash
bash install.sh
```

- Dotfiles (`.tmux.conf`, `alacritty.toml`, `.my.zsh`) must sit beside this script
- Log file: `~/setup.log`
- Re-running is safe — all installs are idempotent

---

## Debugging

**View last run summary:**
```bash
awk '/RUN STARTED/{buf=""} {buf=buf"\n"$0} END{print buf}' ~/setup.log
```

**View only failures/warnings from last run:**
```bash
awk '/RUN STARTED/{buf=""} {buf=buf"\n"$0} END{print buf}' ~/setup.log \
  | grep -E "FAILED|TIMEOUT|WARNING"
```

**Watch live during a run:**
```bash
tail -f ~/setup.log
```

**Test a single function manually:**
```bash
source install.sh          # loads all functions into your shell
install_brave            # call any install_* function directly
```

**Override step timeout (default 300s):**
```bash
STEP_TIMEOUT_SECS=600 bash install.sh
```

---

## Adding a New App — The Registry Pattern

Every app follows the same three-step pattern. The tree UI, mode dispatch,
detection, logging, and timeouts are all derived automatically — you never touch them.

### Step 1 — Write `install_myapp()`

```bash
install_myapp() {
  # Ubuntu: .deb from GitHub releases
  # Fedora: .rpm from GitHub releases
  # Fallback: Flatpak for both if GitHub API is rate-limited
  case "$PKG_MGR" in
    apt)
      local url; url=$(github_latest "owner/myapp" "_amd64.deb")
      if [[ -n "$url" ]]; then
        local tmp; tmp=$(mktemp -d /tmp/setup-XXXXXX)
        wget -q --tries=1 --connect-timeout=15 -O "$tmp/myapp.deb" "$url" \
          && pkg_install "$tmp/myapp.deb" && rm -rf "$tmp" && return 0
        rm -rf "$tmp"
      fi
      ;;
    dnf)
      local url; url=$(github_latest "owner/myapp" "x86_64.rpm")
      if [[ -n "$url" ]]; then
        local tmp; tmp=$(mktemp -d /tmp/setup-XXXXXX)
        wget -q --tries=1 --connect-timeout=15 -O "$tmp/myapp.rpm" "$url" \
          && sudo dnf install -y "$tmp/myapp.rpm" && rm -rf "$tmp" && return 0
        rm -rf "$tmp"
      fi
      ;;
  esac
  # Flatpak fallback
  flatpak install -y --noninteractive flathub com.example.MyApp 2>/dev/null \
    || log "  WARNING: MyApp Flatpak fallback failed"
}
```

### Step 2 — Write `remove_myapp()`

```bash
remove_myapp() {
  pkg_remove myapp 2>/dev/null || true
  flatpak uninstall -y --noninteractive com.example.MyApp 2>/dev/null || true
  # User data (~/.config/myapp) is NEVER deleted — only binaries and packages
  log "  MyApp removed."
}
```

### Step 3 — Register it in the ITEM REGISTRY section

```bash
register_item --key myapp --cat apps \
  --label "MyApp (short description)" --default ON \
  --detect 'cmd_exists myapp || flatpak_installed com.example.MyApp' \
  --install install_myapp --remove remove_myapp
```

---

## `register_item` Flags

| Flag | Description |
|------|-------------|
| `--key` | Unique identifier (no spaces). Used internally and in logs. |
| `--cat` | Category: `system` \| `terminal` \| `editors` \| `browsers` \| `devtools` \| `launchers` \| `apps` \| `ai` \| `gaming` \| `gnome` |
| `--label` | Display name shown in the tree UI. |
| `--default` | `ON` = ticked by default in install mode. `OFF` = unticked. |
| `--detect` | Bash expression. Returns 0 = already installed (auto-untick in install mode, auto-tick in uninstall mode). |
| `--install` | Function to call in install/update mode. |
| `--remove` | Function to call in uninstall mode. |
| `--fg` | Run in foreground with real terminal. Required for `whiptail`, `curl\|gpg` pipes, or anything reading from `/dev/tty`. Without `--fg` the function runs in a background subshell. |

---

## Rules for `install_*`

- Use `pkg_install` / `pkg_remove` instead of calling `apt-get` / `dnf` directly
- Always declare variables with `local`
- Use `mktemp /tmp/setup-XXXXXX` — plain `mktemp` uses `$TMPDIR` which is unset in background subshells, causing curl error 23 (write failed)
- Clean up temp files on every exit path: `local tmp; tmp=$(mktemp -d /tmp/setup-XXXXXX)` then `rm -rf "$tmp"` in all branches
- Return 1 on hard failure so `run_step` marks the step as `FAILED`
- Use `|| true` or `|| log "WARNING..."` for soft/optional failures
- Never call `exit` inside a function — it kills the whole script
- User data (`~/.config/myapp`, `~/MyAppData`) is **never** deleted in `remove_*`

---

## Rules for `remove_*`

- Always use `|| true` — removal should never hard-fail
- Clean up everything the install added:

| What | How |
|------|-----|
| apt/dnf package | `pkg_remove mypackage` |
| snap | `sudo snap remove myapp` |
| Flatpak | `flatpak uninstall -y --noninteractive com.app.Name` |
| APT keyring | `sudo rm -f /usr/share/keyrings/myapp.gpg` |
| APT repo file | `sudo rm -f /etc/apt/sources.list.d/myapp.list` |
| DNF repo file | `sudo rm -f /etc/yum.repos.d/myapp.repo` |
| Binary | `sudo rm -f /usr/local/bin/myapp` |
| AppImage | `sudo rm -f /opt/MyApp/MyApp.AppImage` |
| .desktop entry | `rm -f ~/.local/share/applications/myapp.desktop` |

- Always end with `log "  MyApp removed."`

---

## Rules for `--detect`

The detect expression runs before the tree UI renders — keep it fast (no network calls, < 100ms).

| Mode | detect returns 0 | detect returns 1 |
|------|-----------------|-----------------|
| Install | auto-untick (already installed) | auto-tick (needs installing) |
| Uninstall | auto-tick (can be removed) | auto-untick (not present) |
| Update | all items ticked regardless | all items ticked regardless |

**Multi-method install:**
```bash
--detect 'pkg_installed obsidian || flatpak_installed md.obsidian.Obsidian'
```

**Auto-skip on wrong distro** (return "detected" when not applicable):
```bash
--detect '[[ "$DISTRO" != "fedora" ]] || some_fedora_check'
```

**Good detect expressions:**
```bash
'cmd_exists brave-browser'
'pkg_installed docker-ce'
'flatpak_installed com.spotify.Client'
'[[ -x /opt/MyApp/MyApp.AppImage ]]'
'[[ -d ~/.config/myapp ]]'
```

---

## Available Variables

| Variable | Value | Notes |
|----------|-------|-------|
| `$DISTRO` | `"ubuntu"` or `"fedora"` | |
| `$PKG_MGR` | `"apt"` or `"dnf"` | |
| `$VERSION_ID` | e.g. `"26.04"` or `"42"` | |
| `$CODENAME` | e.g. `"resolute"` | Ubuntu only |
| `$FEDORA_VER` | e.g. `"42"` | Fedora only |
| `$SCRIPT_DIR` | Directory containing `install.sh` | Where dotfiles live |
| `$LOG_FILE` | `~/setup.log` | |

---

## Helper Functions

**Logging:**
```bash
log "  message"        # log file only — use inside run_step functions
logecho "  message"    # log file + stdout — use outside run_step
```

**Idempotency:**
```bash
cmd_exists myapp                   # true if binary is on PATH
pkg_installed mypackage            # true if apt/rpm package installed
flatpak_installed com.app.Name     # true if Flatpak installed
snap_installed myapp               # true if snap installed
version_gte "26.04" "25.04"        # true if first arg >= second arg
```

**GitHub latest release URL:**
```bash
url=$(github_latest "owner/repo" "linux_x86_64.tar.gz")
# Returns the browser_download_url matching the glob from the latest release
```

---

## Adding an APT Repository (Ubuntu)

### Standard method — `apt_add_repo`

Use for repos with a GPG key that needs dearmoring:

```bash
apt_add_repo \
  --name      "myrepo" \
  --key-url   "https://example.com/key.gpg" \
  --keyring   "/usr/share/keyrings/myrepo.gpg" \
  --repo-line "deb [signed-by=/usr/share/keyrings/myrepo.gpg] https://example.com/apt stable main" \
  --repo-file "/etc/apt/sources.list.d/myrepo.list" \
  --packages  "mypackage" || return 1
```

`apt_add_repo` handles the full pipeline safely:
1. Downloads key to `/tmp` (no `curl|gpg` pipe hang)
2. Removes stale keyring before writing (prevents gpg "File exists")
3. Writes repo file
4. Runs targeted `apt-get update` on the new repo only — broken repos from other steps don't cause failures
5. Installs packages

### Binary key method (Docker-style)

Use when the key is already in binary format (not ASCII-armored):

```bash
sudo rm -f /etc/apt/keyrings/myrepo.asc
sudo curl -fsSL https://example.com/key.asc -o /etc/apt/keyrings/myrepo.asc
sudo chmod a+r /etc/apt/keyrings/myrepo.asc
```

### OBS repo with version fallback

For openSUSE Build Service repos — automatically finds closest supported Ubuntu version:

```bash
add_obs_repo "home:developer:project" "package-name"
```

---

## Adding a DNF Repository (Fedora)

**Repo file method (most common):**
```bash
sudo dnf config-manager addrepo \
  --from-repofile=https://example.com/myrepo.repo
pkg_install mypackage
```

**RPM key + inline repo:**
```bash
sudo rpm --import https://example.com/key.gpg
printf "[myrepo]\nname=My Repo\nbaseurl=https://example.com/rpm/\nenabled=1\ngpgcheck=1\ngpgkey=https://example.com/key.gpg\n" \
  | sudo tee /etc/yum.repos.d/myrepo.repo > /dev/null
pkg_install mypackage
```

**COPR (community repo, like Ubuntu PPAs):**
```bash
sudo dnf copr enable -y username/reponame
pkg_install mypackage
```

---

## ⚠️ The curl|gpg Pipe Warning

**Never do this in a background subshell:**
```bash
curl ... | sudo gpg --dearmor -o keyring   # HANGS — gpg blocks on stdin
```

When a function runs in the background (without `--fg`), stdin is redirected.
gpg blocks indefinitely waiting for input that never arrives.

**Safe alternatives:**
1. Use `apt_add_repo` — handles key fetch via `_fetch_key` internally
2. Use `_fetch_key url dest` — downloads to `/tmp` first, then dearmors separately
3. If the function truly needs `curl|gpg`, add `--fg` to the registry entry so it runs in the foreground with a real terminal

---

## Common Patterns

**Flatpak (distro-agnostic):**
```bash
flatpak install -y --noninteractive flathub com.example.App || true
```

**AppImage:**
```bash
pkg_install fuse fuse-libs 2>/dev/null || true
local tmp; tmp=$(mktemp -d /tmp/setup-XXXXXX)
wget -q -O "$tmp/MyApp.AppImage" https://example.com/latest.AppImage
sudo mkdir -p /opt/MyApp
sudo install "$tmp/MyApp.AppImage" /opt/MyApp/MyApp.AppImage
rm -rf "$tmp"
cat > ~/.local/share/applications/myapp.desktop << 'EOF'
[Desktop Entry]
Name=MyApp
Exec=/opt/MyApp/MyApp.AppImage --no-sandbox
Icon=myapp
Type=Application
Terminal=false
Categories=Utility;
EOF
```

**GitHub binary release:**
```bash
local url; url=$(github_latest "owner/repo" "linux_amd64.tar.gz")
local tmp; tmp=$(mktemp -d /tmp/setup-XXXXXX)
wget -q -O "$tmp/app.tar.gz" "$url"
tar -xf "$tmp/app.tar.gz" -C "$tmp" myapp
sudo install "$tmp/myapp" /usr/local/bin/myapp
rm -rf "$tmp"
```

**Snap (Ubuntu only):**
```bash
sudo snap install myapp --classic
```

---

## Step Timeouts

Default timeout is 300s (5 min). For slow steps, add a case in `dispatch()`:

```bash
case "$item" in
  myapp)         timeout=600 ;;   # 10 min for large downloads
  gaming_stack)  timeout=600 ;;
esac
```

---

## Distro Support

| Distro | Status | Package Manager |
|--------|--------|-----------------|
| Ubuntu 24.04+ | ✅ Supported | `apt` |
| Fedora 41+ | ✅ Supported | `dnf` |
| Linux Mint, Pop!_OS | ✅ Via `ID_LIKE` fallback | `apt` |
| Nobara | ✅ Via `ID_LIKE` fallback | `dnf` |
| Arch Linux | 🚧 Planned | `pacman` |

`detect_distro()` reads `/etc/os-release` and uses `ID_LIKE` for derivatives,
so distros based on Ubuntu or Fedora work automatically.
