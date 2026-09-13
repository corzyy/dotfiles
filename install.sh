#!/usr/bin/env bash
# dotfiles + jhqs installer — Fedora (Everything minimal) + Arch/CachyOS
# Repo:   https://github.com/corzyy/dotfiles
# Shell:  https://github.com/corzyy/jhqs -> ~/.config/quickshell/jhqs
#
# What it does (Fedora Everything minimal install):
#   0. Installs bootstrap tools missing on minimal (git/curl/rsync,
#      dnf-plugins-core for `dnf copr`, xdg-user-dirs, accountsservice)
#   1. Enables Terra third-party repo (documented Fedora source for mangowm)
#   2. Enables extra COPRs listed in packages.conf (empty by default —
#      mangowm needs none, it lives in Terra)
#   3. Installs packages from packages.conf (FEDORA_PACKAGES via dnf/dnf5,
#      with COPR/cargo fallbacks for quickshell/matugen)
#   4. Copies .config/* from this repo to ~/.config (with backup, skips wallpapers)
#   5. Copies wallpapers/ to "$(xdg-user-dir PICTURES)/wallpapers" (language-independent,
#      works for Pictures/Bilder/whatever xdg says)
#   6. Clones/updates jhqs quickshell config to ~/.config/quickshell/jhqs
#   7. Installs + enables SDDM (systemd), sets graphical.target default,
#      then prompts to reboot to finish
#
# On Arch/CachyOS the legacy path is kept: CachyOS repos -> pacman + paru
# for AUR (incl. mangowm + sddm) -> same config/wallpaper/jhqs/sddm steps.
#
# Usage:
#   ./install.sh [options]
#   ./install.sh --dry-run        # show what would happen
#   ./install.sh -y               # no confirm prompt
#   ./install.sh --os=fedora      # force Fedora path (default: auto-detect)
#   ./install.sh --os=arch        # force Arch/CachyOS path
#   ./install.sh --only-base      # (Fedora) only bootstrap tools
#   ./install.sh --only-terra     # (Fedora) only enable Terra repo
#   ./install.sh --only-copr      # (Fedora) only enable extra COPR repos
#   ./install.sh --only-cachyos   # (Arch) only ensure CachyOS repos
#   ./install.sh --only-packages  # only package install step
#   ./install.sh --only-configs   # only step 4
#   ./install.sh --only-wallpapers
#   ./install.sh --only-jhqs
#   ./install.sh --only-sddm      # only enable/start SDDM
#   ./install.sh --no-base        # (Fedora) skip bootstrap tools
#   ./install.sh --no-terra       # (Fedora) skip Terra repo setup
#   ./install.sh --no-copr        # (Fedora) skip extra COPR setup
#   ./install.sh --no-cachyos     # (Arch) skip CachyOS repo setup
#   ./install.sh --no-packages    # skip package install
#   ./install.sh --no-configs     # skip .config copy
#   ./install.sh --no-wallpapers  # skip wallpaper install
#   ./install.sh --no-jhqs        # skip jhqs clone/update
#   ./install.sh --no-sddm        # skip SDDM enable/start
#   ./install.sh --no-reboot      # skip reboot prompt at the end
#   ./install.sh --reboot         # reboot automatically at the end (no prompt)
#   ./install.sh --no-backup      # skip backups (not recommended)
#   ./install.sh --link           # symlink instead of copy (default is --copy)

set -euo pipefail

DOTFILES_REPO="https://github.com/corzyy/dotfiles.git"
JHQS_REPO="https://github.com/corzyy/jhqs.git"
DOTFILES_FALLBACK_DIR="$HOME/Documents/dotfiles"
JHQS_TARGET="$HOME/.config/quickshell/jhqs"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# packages.conf lives in Installer/ when install.sh is in the repo root,
# or next to install.sh in the legacy Installer/ layout.
if [[ -f "$SCRIPT_DIR/Installer/packages.conf" ]]; then
  PACKAGES_FILE="$SCRIPT_DIR/Installer/packages.conf"
else
  PACKAGES_FILE="$SCRIPT_DIR/packages.conf"
fi

# --- options (defaults: copy mode, backup on, OS auto-detected) ---
ASSUME_YES=false
DRY_RUN=false
OS_OVERRIDE="auto"
DO_BASE=true
DO_TERRA=true
DO_COPR=true
DO_CACHYOS=true
DO_PACKAGES=true
DO_CONFIGS=true
DO_WALLPAPERS=true
DO_JHQS=true
DO_SDDM=true
DO_BACKUP=true
LINK_MODE=false
AUTO_REBOOT=false
NO_REBOOT=false

# --- colors (disabled when not a tty) ---
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_BLUE=$'\e[34m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi

log_info() { printf '%s[info]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_err()  { printf '%s[err ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  echo "Options:"
  echo "  -y, --yes            skip confirm prompt"
  echo "  --dry-run            print actions without changing anything"
  echo "  --os=fedora|arch|auto"
  echo "                       force OS path (default: auto-detect via /etc/os-release)"
  echo "  --only-base          (Fedora) only install bootstrap tools"
  echo "  --only-terra         (Fedora) only enable Terra repo"
  echo "  --only-copr          (Fedora) only enable extra COPR repos"
  echo "  --only-cachyos       (Arch) only ensure CachyOS repos are enabled"
  echo "  --only-packages      only install packages"
  echo "  --only-configs       only copy .config files"
  echo "  --only-wallpapers    only install wallpapers"
  echo "  --only-jhqs          only clone/update jhqs"
  echo "  --only-sddm          only enable/start SDDM"
  echo "  --no-base            (Fedora) skip bootstrap tools"
  echo "  --no-terra           (Fedora) skip Terra repo setup"
  echo "  --no-copr            (Fedora) skip extra COPR setup"
  echo "  --no-cachyos         (Arch) skip CachyOS repo setup"
  echo "  --no-packages        skip package install"
  echo "  --no-configs         skip .config copy"
  echo "  --no-wallpapers      skip wallpaper install"
  echo "  --no-jhqs            skip jhqs clone/update"
  echo "  --no-sddm            skip SDDM enable/start"
  echo "  --no-reboot          skip reboot prompt at the end"
  echo "  --reboot             reboot automatically at the end (no prompt)"
  echo "  --no-backup          do not backup existing configs"
  echo "  --copy               copy files (default)"
  echo "  --link               symlink ~/.config entries to repo instead of copying"
  echo "  -h, --help           show this help"
}

run() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    # shellcheck disable=SC2294 # intentional: callers pass a pre-quoted shell string
    eval "$@"
  fi
}

confirm() {
  [[ "$ASSUME_YES" == true || "$DRY_RUN" == true ]] && return 0
  local reply
  read -rp "Continue? [Y/n] " reply || true
  [[ -z "$reply" || "$reply" =~ ^[YyJj]$ ]]
}

# --- OS / package-manager detection ---------------------------------------
# Returns "fedora" for Fedora/RHEL-likes (incl. Nobara/Ultramarine), "arch"
# for Arch-likes (arch/cachyos/endeavouros/manjaro), else "unknown".
detect_os() {
  if [[ "$OS_OVERRIDE" != "auto" ]]; then
    printf '%s' "$OS_OVERRIDE"
    return 0
  fi
  local id="" id_like=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    id="${ID:-}"
    id_like="${ID_LIKE:-}"
  fi
  case "$id $id_like" in
    *fedora*|*rhel*|*centos*|*nobara*|*ultramarine*)
      printf 'fedora' ;;
    *arch*|*cachyos*|*endeavour*|*manjaro*)
      printf 'arch' ;;
    *)
      printf 'unknown' ;;
  esac
}

# Prefer dnf5 (default on Fedora 41+), fall back to dnf.
detect_dnf() {
  if command -v dnf5 >/dev/null 2>&1; then
    command -v dnf5
  elif command -v dnf >/dev/null 2>&1; then
    command -v dnf
  else
    echo ""
  fi
}

# Language-independent Pictures dir: xdg-user-dir handles Pictures/Bilder/etc.
get_pictures_dir() {
  local dir=""
  if command -v xdg-user-dir >/dev/null 2>&1; then
    dir="$(xdg-user-dir PICTURES 2>/dev/null || true)"
  fi
  if [[ -z "$dir" || "$dir" == "$HOME" ]]; then
    # Fallback: parse ~/.config/user-dirs.dirs
    local ud="$HOME/.config/user-dirs.dirs"
    if [[ -f "$ud" ]]; then
      dir="$(grep -E '^XDG_PICTURES_DIR=' "$ud" 2>/dev/null | cut -d= -f2- | tr -d '"' | sed "s#\$HOME#$HOME#" || true)"
    fi
  fi
  if [[ -z "$dir" || "$dir" == "$HOME" ]]; then
    dir="$HOME/Pictures"
  fi
  printf '%s' "$dir"
}

resolve_dotfiles_root() {
  # New layout: install.sh sits in the repo root itself.
  if [[ -d "$SCRIPT_DIR/.config" || -d "$SCRIPT_DIR/wallpapers" || -d "$SCRIPT_DIR/.git" ]]; then
    printf '%s' "$SCRIPT_DIR"
    return 0
  fi
  # Legacy layout: install.sh inside Installer/, repo root is the parent.
  local candidate
  candidate="$(dirname "$SCRIPT_DIR")"
  if [[ -d "$candidate/.config" || -d "$candidate/wallpapers" || -d "$candidate/.git" ]]; then
    printf '%s' "$candidate"
    return 0
  fi
  if [[ -d "$DOTFILES_FALLBACK_DIR/.config" || -d "$DOTFILES_FALLBACK_DIR/wallpapers" ]]; then
    printf '%s' "$DOTFILES_FALLBACK_DIR"
    return 0
  fi
  printf '%s' "$SCRIPT_DIR"
}

# --- Fedora: bootstrap ------------------------------------------------------
# Everything-minimal ships without git/curl/rsync and without the COPR
# plugin. Install those first so every later step can assume they exist.
ensure_base_fedora() {
  local dnf_bin="$1"
  if [[ ! -f "$PACKAGES_FILE" ]]; then
    log_err "packages.conf not found: $PACKAGES_FILE"
    return 1
  fi
  FEDORA_BASE_PACKAGES=()
  FEDORA_PACKAGES=()
  COPR_REPOS=()
  QUICKSHELL_COPR=""
  MATUGEN_COPR=""
  ENABLE_TERRA="true"
  # shellcheck disable=SC1090
  source "$PACKAGES_FILE"

  if ((${#FEDORA_BASE_PACKAGES[@]} == 0)); then
    log_info "no Fedora base packages defined — skipping"
    return 0
  fi
  local missing=() p
  for p in "${FEDORA_BASE_PACKAGES[@]}"; do
    [[ -z "$p" || "$p" == \#* ]] && continue
    if rpm -q "$p" >/dev/null 2>&1; then
      log_ok "already installed: $p"
    else
      missing+=("$p")
    fi
  done
  if ((${#missing[@]} == 0)); then
    log_ok "base tools done (nothing to do)"
    return 0
  fi
  log_info "Installing Fedora base tools (${#missing[@]}): ${missing[*]}"
  if ! run "sudo $dnf_bin install -y ${missing[*]}"; then
    log_err "base tool install failed (network? mirrors?). Fix that and re-run."
    return 1
  fi
  log_ok "base tools done"
}

# --- Fedora: Terra repo -----------------------------------------------------
# Upstream-documented Fedora source for mangowm (+ nerd-fonts):
# https://developer.fyralabs.com/terra/installing
ensure_terra() {
  local dnf_bin="$1"
  if [[ -f /etc/yum.repos.d/terra.repo ]]; then
    log_ok "Terra repo already enabled — skipping"
    return 0
  fi
  log_info "Enabling Terra repository (third-party Fedora repo, hosts mangowm)…"
  if ! run "sudo $dnf_bin install -y --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra\$releasever' terra-release terra-gpg-keys"; then
    log_err "Terra setup failed. Retry manually:"
    log_err "  sudo $dnf_bin install -y --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra\$releasever' terra-release terra-gpg-keys"
    return 1
  fi
  log_ok "Terra repo enabled"
}

copr_repo_file_exists() {
  local repo="$1" # owner/project
  local owner="${repo%%/*}" project="${repo##*/}"
  local f
  for f in /etc/yum.repos.d/*copr*.repo; do
    [[ -f "$f" ]] || continue
    if grep -Eq "^\\[copr:.*:${owner}:${project}(:|$|\\])" "$f" 2>/dev/null \
      || grep -Eq "${owner}.*${project}|${project}.*${owner}" "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# --- Fedora: COPR repos -----------------------------------------------------
# Enables every entry in COPR_REPOS (empty by default; mangowm needs none).
# Skips repos whose .repo file already exists.
ensure_copr() {
  local dnf_bin="$1"
  FEDORA_BASE_PACKAGES=()
  FEDORA_PACKAGES=()
  COPR_REPOS=()
  QUICKSHELL_COPR=""
  MATUGEN_COPR=""
  ENABLE_TERRA="true"
  # shellcheck disable=SC1090
  source "$PACKAGES_FILE"

  if ((${#COPR_REPOS[@]} == 0)); then
    log_info "no COPR repos defined — skipping"
    return 0
  fi
  local repo
  for repo in "${COPR_REPOS[@]}"; do
    [[ -z "$repo" || "$repo" == \#* ]] && continue
    if copr_repo_file_exists "$repo"; then
      log_ok "COPR already enabled: $repo — skipping"
      continue
    fi
    log_info "Enabling COPR: $repo…"
    if ! run "sudo $dnf_bin copr enable -y \"$repo\""; then
      log_err "could not enable COPR $repo (see error above)."
      log_err "Retry manually: sudo $dnf_bin copr enable $repo"
      return 1
    fi
    log_ok "COPR enabled: $repo"
  done
}

# Enable one fallback COPR on demand (quickshell/matugen when missing).
ensure_one_copr() {
  local dnf_bin="$1" repo="$2"
  if [[ -z "$repo" ]]; then
    return 1
  fi
  if copr_repo_file_exists "$repo"; then
    log_ok "COPR already enabled: $repo"
    return 0
  fi
  log_warn "'$repo' needed for a missing package — enabling COPR $repo…"
  run "sudo $dnf_bin copr enable -y \"$repo\""
}

dnf_package_available() {
  local dnf_bin="$1" pkg="$2"
  # In dry-run (e.g. previewing the Fedora path from Arch) assume packages
  # are available so the preview shows the real install command.
  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi
  "$dnf_bin" list --available "$pkg" >/dev/null 2>&1
}

# --- Fedora: packages -------------------------------------------------------
install_packages_fedora() {
  local dnf_bin="$1"
  if [[ -z "$dnf_bin" ]]; then
    log_err "neither dnf5 nor dnf found — this path targets Fedora."
    return 1
  fi
  if [[ ! -f "$PACKAGES_FILE" ]]; then
    log_err "packages.conf not found: $PACKAGES_FILE"
    return 1
  fi
  FEDORA_BASE_PACKAGES=()
  FEDORA_PACKAGES=()
  COPR_REPOS=()
  QUICKSHELL_COPR=""
  MATUGEN_COPR=""
  ENABLE_TERRA="true"
  # shellcheck disable=SC1090
  source "$PACKAGES_FILE"

  # de-dupe while preserving order
  local -A seen=()
  local fedora_unique=() p
  for p in ${FEDORA_PACKAGES[@]+"${FEDORA_PACKAGES[@]}"}; do
    [[ -z "$p" || "$p" == \#* ]] && continue
    [[ -n "${seen["pkg:$p"]:-}" ]] && continue
    seen["pkg:$p"]=1
    fedora_unique+=("$p")
  done

  log_info "Refreshing package metadata…"
  if ! run "sudo $dnf_bin makecache"; then
    log_warn "makecache failed (offline?) — trying to continue with cached metadata…"
  fi

  # Split into installed / installable / missing without failing the whole
  # transaction on one unknown name (minimal spins + version skew).
  local to_install=() missing=()
  for p in "${fedora_unique[@]}"; do
    if rpm -q "$p" >/dev/null 2>&1; then
      log_ok "already installed: $p"
    elif dnf_package_available "$dnf_bin" "$p"; then
      to_install+=("$p")
    else
      missing+=("$p")
    fi
  done

  # Fallback COPRs for the two known movers: quickshell (official on new
  # Fedora, COPR errornointernet/quickshell otherwise) and matugen
  # (official on new Fedora, COPR solopasha/hyprland otherwise).
  local m
  for m in "${missing[@]}"; do
    case "$m" in
      quickshell)
        if [[ -n "$QUICKSHELL_COPR" ]] && ensure_one_copr "$dnf_bin" "$QUICKSHELL_COPR"; then
          if dnf_package_available "$dnf_bin" "$m"; then
            log_ok "found $m after enabling $QUICKSHELL_COPR"
            to_install+=("$m")
            local tmp=() x
            for x in "${missing[@]}"; do [[ "$x" != "$m" ]] || continue; tmp+=("$x"); done
            missing=("${tmp[@]}")
          fi
        fi
        ;;
      matugen)
        if [[ -n "$MATUGEN_COPR" ]] && ensure_one_copr "$dnf_bin" "$MATUGEN_COPR"; then
          if dnf_package_available "$dnf_bin" "$m"; then
            log_ok "found $m after enabling $MATUGEN_COPR"
            to_install+=("$m")
            local tmp2=() x2
            for x2 in "${missing[@]}"; do [[ "$x2" != "$m" ]] || continue; tmp2+=("$x2"); done
            missing=("${tmp2[@]}")
          fi
        fi
        ;;
    esac
  done

  if ((${#to_install[@]} > 0)); then
    log_info "Installing Fedora packages (${#to_install[@]}): ${to_install[*]}"
    if ! run "sudo $dnf_bin install -y ${to_install[*]}"; then
      log_err "dnf install failed (see error above). Re-run with --only-packages once fixed."
      return 1
    fi
  fi

  # Graceful fallbacks for packages that legitimately may not exist per
  # Fedora version (never fail the whole install on them).
  local still_missing=() q
  for q in ${missing[@]+"${missing[@]}"}; do
    if rpm -q "$q" >/dev/null 2>&1 || dnf_package_available "$dnf_bin" "$q"; then
      # Became available (fallback COPR above); install it now.
      log_info "Installing late-resolved package: $q"
      run "sudo $dnf_bin install -y \"$q\"" || log_warn "could not install $q — continuing…"
    else
      still_missing+=("$q")
    fi
  done

  local s
  for s in ${still_missing[@]+"${still_missing[@]}"}; do
    case "$s" in
      matugen)
        if command -v cargo >/dev/null 2>&1; then
          log_warn "matugen not in repos — installing via cargo…"
          run "cargo install matugen" || log_warn "cargo install matugen failed — theming will be limited."
        else
          log_warn "matugen not in repos and cargo missing. Install Rust (rustup) then: cargo install matugen"
        fi
        ;;
      nwg-look)
        log_warn "nwg-look not in enabled repos — skipping (optional GTK theming tool)."
        log_warn "  To build manually: sudo $dnf_bin install -y go gtk3-devel xcur2png && git clone https://github.com/nwg-piotr/nwg-look.git /tmp/nwg-look && (cd /tmp/nwg-look && make build && sudo make install)"
        ;;
      mangowm)
        log_err "'mangowm' still missing after Terra setup. Check:"
        log_err "  1. sudo $dnf_bin repolist | grep -Ei 'copr|terra'"
        log_err "  2. sudo $dnf_bin repoquery mangowm"
        return 1
        ;;
      quickshell)
        log_err "'quickshell' still missing. Try: sudo $dnf_bin copr enable -y errornointernet/quickshell && sudo $dnf_bin install -y quickshell"
        return 1
        ;;
      *)
        log_warn "package not in enabled repos, skipping: $s"
        ;;
    esac
  done
  log_ok "packages done"
}

# --- Fedora: SDDM -----------------------------------------------------------
# mangowm is installed via Terra above; this makes SDDM the display
# manager and graphical.target the default so the mango session is
# reachable after reboot (minimal installs boot to multi-user.target).
ensure_sddm_fedora() {
  if ! rpm -q sddm >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == true ]]; then
      log_info "[dry-run] assuming sddm installed for preview…"
    else
      log_err "sddm is not installed (expected via packages step). Run with packages step first."
      return 1
    fi
  fi
  if ! rpm -q mangowm >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == true ]]; then
      log_info "[dry-run] assuming mangowm installed for preview…"
    else
      log_warn "mangowm is not installed — SDDM will have no mango session until packages are installed."
    fi
  fi
  # The compositor package must ship a Wayland session entry for SDDM.
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] verify /usr/share/wayland-sessions/mango*.desktop exists\n'
  else
    local session_files=(/usr/share/wayland-sessions/*.desktop)
    if [[ -e "${session_files[0]}" ]]; then
      local mango_sessions=()
      local sf
      for sf in "${session_files[@]}"; do
        [[ "$(basename "$sf")" == *mango* ]] && mango_sessions+=("$(basename "$sf")")
      done
      if ((${#mango_sessions[@]} > 0)); then
        log_ok "mango Wayland session found: ${mango_sessions[*]}"
      else
        log_warn "no mango .desktop in /usr/share/wayland-sessions (found: $(basename -a "${session_files[@]}" | tr '\n' ' ')). SDDM may not list mango until mangowm is (re)installed."
      fi
    else
      log_warn "/usr/share/wayland-sessions is empty — mango session entry missing (reinstall mangowm?)."
    fi
  fi
  log_info "Enabling SDDM display manager…"
  # -f disables any competing display manager (gdm, lightdm, …)
  if ! run "sudo systemctl enable sddm.service -f"; then
    log_err "could not enable sddm (see sudo/systemctl error above)."
    return 1
  fi
  log_info "Setting graphical.target as default (minimal installs default to multi-user)…"
  if ! run "sudo systemctl set-default graphical.target"; then
    log_warn "could not set graphical default — continuing (enable step already done)…"
  fi
  # Minimal spins sometimes leave NetworkManager disabled; the desktop needs it.
  if systemctl list-unit-files NetworkManager.service 2>/dev/null | grep -q .; then
    if ! systemctl is-enabled --quiet NetworkManager 2>/dev/null; then
      log_info "Enabling NetworkManager…"
      run "sudo systemctl enable NetworkManager.service" || log_warn "could not enable NetworkManager — continuing…"
    fi
  fi
  if systemctl is-active --quiet sddm 2>/dev/null; then
    log_ok "SDDM already running"
  else
    log_info "Starting SDDM… (a reboot still finishes the install)"
    if ! run "sudo systemctl start sddm.service"; then
      log_warn "could not start sddm right now — a reboot will start it. Continuing…"
    fi
  fi
  log_ok "sddm done"
}

# --- Arch: paru ---------------------------------------------------------------
ensure_paru() {
  if command -v paru >/dev/null 2>&1; then
    log_ok "paru found: $(command -v paru)"
    return 0
  fi
  log_warn "paru not found — installing paru (needed for AUR packages)…"
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] sudo pacman -S --needed --noconfirm base-devel git && git clone https://aur.archlinux.org/paru.git /tmp/paru && makepkg -si\n'
    return 0
  fi
  sudo pacman -S --needed --noconfirm base-devel git
  rm -rf /tmp/paru
  git clone https://aur.archlinux.org/paru.git /tmp/paru
  if ! (cd /tmp/paru && makepkg -si --noconfirm); then
    log_err "building paru failed (see makepkg error above). Install paru manually, then re-run."
    return 1
  fi
  log_ok "paru installed"
}

# Official CachyOS repo bootstrap for vanilla Arch:
# https://wiki.cachyos.org/features/optimized_repos
# Skipped automatically when [cachyos] is already enabled in pacman.conf.
ensure_cachyos_repos() {
  if grep -Eq '^\[(cachyos|cachyos-v3|cachyos-core-v3|cachyos-extra-v3|cachyos-v4|cachyos-core-v4|cachyos-extra-v4)\]' /etc/pacman.conf 2>/dev/null \
    && [[ -f /etc/pacman.d/cachyos-mirrorlist ]]; then
    log_ok "CachyOS repos already enabled — skipping"
    return 0
  fi
  log_info "Enabling CachyOS repos (official cachyos-repo.sh)…"
  log_info "This adds optimized repos (auto-detects x86-64-v3/v4/znver4) + keyring. Backup: /etc/pacman.conf.bak"
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] curl -o /tmp/cachyos-repo.tar.xz https://mirror.cachyos.org/cachyos-repo.tar.xz\n'
    printf '[dry-run] tar xvf /tmp/cachyos-repo.tar.xz -C /tmp && sudo bash /tmp/cachyos-repo/cachyos-repo.sh --install\n'
    return 0
  fi
  for cmd in curl tar gawk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_info "installing missing helper: $cmd"
      sudo pacman -S --needed --noconfirm "$cmd"
    fi
  done
  rm -rf /tmp/cachyos-repo /tmp/cachyos-repo.tar.xz
  curl -L -o /tmp/cachyos-repo.tar.xz https://mirror.cachyos.org/cachyos-repo.tar.xz
  tar xvf /tmp/cachyos-repo.tar.xz -C /tmp
  # cachyos-repo.sh must run as root from inside its own dir (uses ./install-*.awk + ./pacman.conf)
  if ! (cd /tmp/cachyos-repo && sudo ./cachyos-repo.sh --install); then
    log_err "cachyos-repo.sh failed (see error above). Re-run with --only-cachyos once fixed."
    return 1
  fi
  log_ok "CachyOS repos enabled"
}

# --- Arch: packages -----------------------------------------------------------
install_packages_arch() {
  if [[ ! -f "$PACKAGES_FILE" ]]; then
    log_err "packages.conf not found: $PACKAGES_FILE"
    return 1
  fi
  # shellcheck source=packages.conf
  PACMAN_PACKAGES=()
  AUR_PACKAGES=()
  FEDORA_BASE_PACKAGES=()
  FEDORA_PACKAGES=()
  COPR_REPOS=()
  QUICKSHELL_COPR=""
  MATUGEN_COPR=""
  ENABLE_TERRA="true"
  # shellcheck disable=SC1090
  source "$PACKAGES_FILE"

  if ! command -v pacman >/dev/null 2>&1; then
    log_err "pacman not found — use --os=fedora on Fedora systems."
    return 1
  fi

  # de-dupe while preserving order
  local -A seen=()
  local pacman_unique=() aur_unique=() p
  for p in ${PACMAN_PACKAGES[@]+"${PACMAN_PACKAGES[@]}"}; do
    [[ -z "$p" || "$p" == \#* ]] && continue
    [[ -n "${seen["pkg:$p"]:-}" ]] && continue
    seen["pkg:$p"]=1
    pacman_unique+=("$p")
  done
  for p in ${AUR_PACKAGES[@]+"${AUR_PACKAGES[@]}"}; do
    [[ -z "$p" || "$p" == \#* ]] && continue
    [[ -n "${seen["pkg:$p"]:-}" ]] && continue
    seen["pkg:$p"]=1
    aur_unique+=("$p")
  done

  log_info "Syncing package databases…"
  if ! run "sudo pacman -Sy"; then
    log_err "pacman database sync failed (network? mirrors? keyring?). Fix that and re-run."
    return 1
  fi

  # Official packages; fall back to paru if pacman doesn't know them
  # (e.g. mangowm is official on CachyOS but AUR on vanilla Arch).
  local missing_for_aur=()
  if ((${#pacman_unique[@]} > 0)); then
    log_info "Installing official packages (${#pacman_unique[@]}): ${pacman_unique[*]}"
    local to_install=()
    for p in "${pacman_unique[@]}"; do
      if pacman -Q "$p" >/dev/null 2>&1; then
        log_ok "already installed: $p"
      elif pacman -Si "$p" >/dev/null 2>&1; then
        to_install+=("$p")
      else
        log_warn "'$p' not in pacman repos — will try paru (AUR)."
        missing_for_aur+=("$p")
      fi
    done
    if ((${#to_install[@]} > 0)); then
      if ! run "sudo pacman -S --needed --noconfirm ${to_install[*]}"; then
        log_err "pacman install failed for: ${to_install[*]} (see pacman's error above)."
        return 1
      fi
    fi
  fi

  local aur_all=("${aur_unique[@]}" "${missing_for_aur[@]}")
  if ((${#aur_all[@]} > 0)); then
    ensure_paru
    log_info "Installing AUR packages (${#aur_all[@]}): ${aur_all[*]}"
    local aur_missing=()
    local q
    for q in "${aur_all[@]}"; do
      if pacman -Q "$q" >/dev/null 2>&1; then
        log_ok "already installed: $q"
      else
        aur_missing+=("$q")
      fi
    done
    if ((${#aur_missing[@]} > 0)); then
      if ! run "paru -S --needed --noconfirm ${aur_missing[*]}"; then
        log_err "paru install failed for: ${aur_missing[*]} (see the error above)."
        return 1
      fi
    fi
  fi
  log_ok "packages done"
}

backup_path() {
  local src="$1" backup_root="$2"
  local base
  base="$(basename "$src")"
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] backup %s -> %s/\n' "$src" "$backup_root"
    return 0
  fi
  mkdir -p "$backup_root"
  local dest="$backup_root/$base"
  if [[ -e "$dest" ]]; then
    dest="$backup_root/${base}.$(date +%H%M%S)"
  fi
  mv "$src" "$dest"
  log_warn "backed up $src -> $dest"
}

install_dotfiles() {
  local root="$1" backup_root="$2"
  local src_config="$root/.config"
  if [[ ! -d "$src_config" ]]; then
    log_err "no .config dir in dotfiles root: $root"
    log_info "expected clone: $DOTFILES_REPO -> $DOTFILES_FALLBACK_DIR"
    return 1
  fi
  log_info "Installing configs from $src_config -> $HOME/.config"
  local entry name dest
  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    # wallpapers are handled separately -> Pictures, never ~/.config
    if [[ "$name" == "wallpapers" ]]; then
      continue
    fi
    dest="$HOME/.config/$name"
    if [[ -e "$dest" && ! -L "$dest" && "$DO_BACKUP" == true ]]; then
      # only backup if content actually differs
      if ! diff -qr "$entry" "$dest" >/dev/null 2>&1; then
        backup_path "$dest" "$backup_root"
      else
        log_ok "identical, skipping backup: $dest"
      fi
    elif [[ -L "$dest" || -e "$dest" ]]; then
      log_warn "replacing existing $dest"
      run "rm -rf \"$dest\""
    fi
    run "mkdir -p \"$(dirname "$dest")\""
    if [[ "$LINK_MODE" == true ]]; then
      run "ln -sfn \"$entry\" \"$dest\""
    else
      run "mkdir -p \"$dest\""
      run "cp -a \"$entry/.\" \"$dest/\""
    fi
    log_ok "installed ~/.config/$name"
  done < <(find "$src_config" -mindepth 1 -maxdepth 1 -print0 | sort -z)

  # make helper scripts executable
  if [[ -f "$HOME/.config/mango/wallpaper-restore.sh" ]]; then
    run "chmod +x \"$HOME/.config/mango/wallpaper-restore.sh\""
  fi
  log_ok "configs done"
}

install_wallpapers() {
  local root="$1"
  local candidates=(
    "$root/wallpapers"
    "$root/.config/wallpapers"
    "$root/dotfiles/.config/wallpapers"
  )
  local src=""
  local c
  for c in "${candidates[@]}"; do
    if [[ -d "$c" ]]; then
      src="$c"
      break
    fi
  done
  if [[ -z "$src" ]]; then
    log_warn "no wallpapers dir found in $root (checked: ${candidates[*]}) — skipping"
    return 0
  fi
  local pics dest
  pics="$(get_pictures_dir)"
  dest="$pics/wallpapers"
  log_info "Installing wallpapers: $src -> $dest (Pictures resolved via xdg-user-dir)"
  run "mkdir -p \"$dest\""
  if command -v rsync >/dev/null 2>&1; then
    run "rsync -a \"$src/\" \"$dest/\""
  else
    run "cp -a \"$src/.\" \"$dest/\""
  fi
  log_ok "wallpapers done -> $dest"
}

install_jhqs() {
  local backup_root="$1"
  log_info "Installing jhqs: $JHQS_REPO -> $JHQS_TARGET"
  if [[ -d "$JHQS_TARGET/.git" ]]; then
    if [[ -n "$(git -C "$JHQS_TARGET" status --porcelain 2>/dev/null)" ]]; then
      log_warn "jhqs has local changes — skipping auto-pull so nothing gets overwritten."
      log_warn "  to update manually: git -C \"$JHQS_TARGET\" stash && git -C \"$JHQS_TARGET\" pull --ff-only && git -C \"$JHQS_TARGET\" stash pop"
      log_warn "  continuing with your existing checkout…"
    else
      log_info "existing jhqs checkout found — pulling latest…"
      if ! run "git -C \"$JHQS_TARGET\" pull --ff-only"; then
        log_warn "could not update jhqs (offline? diverged branch?) — continuing with existing checkout."
      fi
    fi
  else
    if [[ -e "$JHQS_TARGET" ]]; then
      if [[ "$DO_BACKUP" == true ]]; then
        backup_path "$JHQS_TARGET" "$backup_root/jhqs-parent"
        # backup_path moved it to <backup>/jhqs; move back structure:
        # keep it simple: it now lives under backup_root, fresh clone follows
      else
        run "rm -rf \"$JHQS_TARGET\""
      fi
    fi
    run "mkdir -p \"$(dirname "$JHQS_TARGET")\""
    run "git clone \"$JHQS_REPO\" \"$JHQS_TARGET\""
  fi
  # helper scripts executable
  if [[ -d "$JHQS_TARGET/scripts" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      printf '[dry-run] chmod +x %s/scripts/*.sh\n' "$JHQS_TARGET"
    else
      # shellcheck disable=SC2086
      chmod +x "$JHQS_TARGET"/scripts/*.sh 2>/dev/null || true
    fi
  fi
  # launcher expected by mango autostart.conf: ~/.local/bin/jhqs -> quickshell
  local qs_bin=""
  if command -v quickshell >/dev/null 2>&1; then
    qs_bin="$(command -v quickshell)"
  elif [[ -x /usr/bin/quickshell ]]; then
    qs_bin="/usr/bin/quickshell"
  fi
  if [[ -n "$qs_bin" ]]; then
    run "mkdir -p \"$HOME/.local/bin\""
    if [[ ! -e "$HOME/.local/bin/jhqs" ]]; then
      run "ln -sf \"$qs_bin\" \"$HOME/.local/bin/jhqs\""
      log_ok "created ~/.local/bin/jhqs launcher"
    else
      log_ok "launcher already exists: ~/.local/bin/jhqs"
    fi
    # binds call `qs -c jhqs …`; quickshell ships `qs` on most distros, but
    # guarantee it on minimal installs where only `quickshell` exists.
    if ! command -v qs >/dev/null 2>&1 && [[ ! -e "$HOME/.local/bin/qs" ]]; then
      run "ln -sf \"$qs_bin\" \"$HOME/.local/bin/qs\""
      log_ok "created ~/.local/bin/qs launcher"
    fi
  else
    log_warn "quickshell binary not found — launcher skipped (install packages first)"
  fi
  log_ok "jhqs done"
}

# mangowm + sddm are installed via packages.conf; this enables/starts the
# SDDM display manager so the mango session is reachable after reboot.
ensure_sddm_arch() {
  if ! pacman -Q sddm >/dev/null 2>&1; then
    log_err "sddm is not installed (expected via packages.conf). Run with packages step first."
    return 1
  fi
  if ! pacman -Q mangowm >/dev/null 2>&1; then
    log_warn "mangowm is not installed — SDDM will have no mango session until packages are installed."
  fi
  log_info "Enabling SDDM display manager…"
  # -f disables any competing display manager (gdm, lightdm, …)
  if ! run "sudo systemctl enable sddm.service -f"; then
    log_err "could not enable sddm (see sudo/systemctl error above)."
    return 1
  fi
  if systemctl is-active --quiet sddm 2>/dev/null; then
    log_ok "SDDM already running"
  else
    log_info "Starting SDDM… (a reboot still finishes the install)"
    if ! run "sudo systemctl start sddm.service"; then
      log_warn "could not start sddm right now — a reboot will start it. Continuing…"
    fi
  fi
  log_ok "sddm done"
}

prompt_reboot() {
  if [[ "$NO_REBOOT" == true ]]; then
    log_info "reboot prompt skipped (--no-reboot)"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] prompt: Reboot now to finish installation? [y/N]\n'
    return 0
  fi
  if [[ "$AUTO_REBOOT" == true ]]; then
    log_warn "Rebooting now (--reboot)…"
    sudo reboot
    return 0
  fi
  local reply=""
  read -rp "Reboot now to finish installation? [y/N] " reply || true
  if [[ "$reply" =~ ^[YyJj]$ ]]; then
    log_warn "Rebooting now…"
    sudo reboot
  else
    log_info "Reboot skipped — please reboot manually to finish (sddm + mango)."
  fi
}

disable_all_steps() {
  DO_BASE=false; DO_TERRA=false; DO_COPR=false; DO_CACHYOS=false
  DO_PACKAGES=false; DO_CONFIGS=false; DO_WALLPAPERS=false
  DO_JHQS=false; DO_SDDM=false
}

main() {
  while (($# > 0)); do
    case "$1" in
      -y|--yes) ASSUME_YES=true ;;
      --dry-run) DRY_RUN=true ;;
      --os=*) OS_OVERRIDE="${1#--os=}";;
      --os) OS_OVERRIDE="$2"; shift ;;
      --only-base) disable_all_steps; DO_BASE=true ;;
      --only-terra) disable_all_steps; DO_TERRA=true ;;
      --only-copr) disable_all_steps; DO_COPR=true ;;
      --only-cachyos) disable_all_steps; DO_CACHYOS=true ;;
      --only-packages) disable_all_steps; DO_PACKAGES=true ;;
      --only-configs) disable_all_steps; DO_CONFIGS=true ;;
      --only-wallpapers) disable_all_steps; DO_WALLPAPERS=true ;;
      --only-jhqs) disable_all_steps; DO_JHQS=true ;;
      --only-sddm) disable_all_steps; DO_SDDM=true ;;
      --no-base) DO_BASE=false ;;
      --no-terra) DO_TERRA=false ;;
      --no-copr) DO_COPR=false ;;
      --no-cachyos) DO_CACHYOS=false ;;
      --no-packages) DO_PACKAGES=false ;;
      --no-configs) DO_CONFIGS=false ;;
      --no-wallpapers) DO_WALLPAPERS=false ;;
      --no-jhqs) DO_JHQS=false ;;
      --no-sddm) DO_SDDM=false ;;
      --no-reboot) NO_REBOOT=true ;;
      --reboot) AUTO_REBOOT=true; NO_REBOOT=false ;;
      --no-backup) DO_BACKUP=false ;;
      --copy) LINK_MODE=false ;;
      --link) LINK_MODE=true ;;
      -h|--help) usage; exit 0 ;;
      *) log_err "unknown flag: $1"; usage; exit 1 ;;
    esac
    shift
  done

  case "$OS_OVERRIDE" in
    auto|fedora|arch) ;;
    *) log_err "invalid --os value: $OS_OVERRIDE (want fedora|arch|auto)"; exit 1 ;;
  esac

  local os dnf_bin
  os="$(detect_os)"
  dnf_bin=""
  if [[ "$os" == "fedora" ]]; then
    dnf_bin="$(detect_dnf)"
    if [[ -z "$dnf_bin" && "$DRY_RUN" == true ]]; then
      # Previewing Fedora path from a non-Fedora host (e.g. Arch build box):
      # use a placeholder so --dry-run still shows the real commands.
      log_warn "dnf/dnf5 not found on this host — using placeholder 'dnf' for dry-run preview"
      dnf_bin="dnf"
    fi
  fi

  # Default step selection per OS: Fedora uses base/terra/copr, Arch uses cachyos.
  if [[ "$os" == "fedora" ]]; then
    DO_CACHYOS=false
  elif [[ "$os" == "arch" ]]; then
    DO_BASE=false; DO_TERRA=false; DO_COPR=false
  else
    log_err "unsupported OS (could not detect fedora/arch from /etc/os-release)."
    log_err "Re-run with --os=fedora or --os=arch to force a path."
    exit 1
  fi

  local root backup_root
  root="$(resolve_dotfiles_root)"
  backup_root="$HOME/.config_backup_$(date +%Y%m%d_%H%M%S)"

  echo "${C_BOLD}dotfiles installer${C_RESET}"
  echo "  os            : $os"
  echo "  dotfiles root : $root"
  echo "  jhqs target   : $JHQS_TARGET"
  echo "  pictures dir  : $(get_pictures_dir)/wallpapers"
  if [[ "$os" == "fedora" ]]; then
    echo "  dnf           : ${dnf_bin:-"(not found)"}"
  fi
  echo "  mode          : $([[ "$LINK_MODE" == true ]] && echo "symlink" || echo "copy") / backup $([[ "$DO_BACKUP" == true ]] && echo "on ($backup_root)" || echo "off")"
  if [[ "$os" == "fedora" ]]; then
    echo "  steps         : base=$DO_BASE terra=$DO_TERRA copr=$DO_COPR packages=$DO_PACKAGES configs=$DO_CONFIGS wallpapers=$DO_WALLPAPERS jhqs=$DO_JHQS sddm=$DO_SDDM"
  else
    echo "  steps         : cachyos=$DO_CACHYOS packages=$DO_PACKAGES configs=$DO_CONFIGS wallpapers=$DO_WALLPAPERS jhqs=$DO_JHQS sddm=$DO_SDDM"
  fi
  echo ""

  if [[ ! -d "$root/.config" && ! -d "$root/wallpapers" ]]; then
    log_err "dotfiles root has neither .config nor wallpapers: $root"
    log_info "fresh machine? run: git clone $DOTFILES_REPO $DOTFILES_FALLBACK_DIR"
    exit 1
  fi

  confirm || { log_info "aborted."; exit 0; }

  # Ask for sudo once, upfront, so system steps can't die midway on a password prompt.
  if [[ "$DRY_RUN" == false && ("$DO_BASE" == true || "$DO_TERRA" == true || "$DO_COPR" == true || "$DO_CACHYOS" == true || "$DO_PACKAGES" == true || "$DO_SDDM" == true) ]]; then
    log_info "Requesting sudo upfront (needed for system steps)…"
    if ! sudo -v; then
      log_err "sudo authentication failed — cannot run system steps."
      log_err "Re-run with --no-base --no-terra --no-copr --no-cachyos --no-packages --no-sddm to skip them."
      exit 1
    fi
  fi

  if [[ "$os" == "fedora" ]]; then
    if [[ -z "$dnf_bin" && ("$DO_BASE" == true || "$DO_TERRA" == true || "$DO_COPR" == true || "$DO_PACKAGES" == true) ]]; then
      log_err "dnf/dnf5 not found but system steps requested. Are you on Fedora?"
      exit 1
    fi
    if [[ "$DO_BASE" == true ]]; then
      ensure_base_fedora "$dnf_bin"
    fi
    if [[ "$DO_TERRA" == true ]]; then
      # shellcheck disable=SC1090
      source "$PACKAGES_FILE"
      if [[ "${ENABLE_TERRA:-true}" == "true" ]]; then
        ensure_terra "$dnf_bin"
      else
        log_info "Terra disabled via packages.conf (ENABLE_TERRA != true) — skipping"
      fi
    fi
    if [[ "$DO_COPR" == true ]]; then
      ensure_copr "$dnf_bin"
    fi
    if [[ "$DO_PACKAGES" == true ]]; then
      install_packages_fedora "$dnf_bin"
    fi
  else
    if [[ "$DO_CACHYOS" == true ]]; then
      ensure_cachyos_repos
    fi
    if [[ "$DO_PACKAGES" == true ]]; then
      install_packages_arch
    fi
  fi
  if [[ "$DO_CONFIGS" == true ]]; then
    install_dotfiles "$root" "$backup_root"
  fi
  if [[ "$DO_WALLPAPERS" == true ]]; then
    install_wallpapers "$root"
  fi
  if [[ "$DO_JHQS" == true ]]; then
    install_jhqs "$backup_root"
  fi
  if [[ "$DO_SDDM" == true ]]; then
    if [[ "$os" == "fedora" ]]; then
      ensure_sddm_fedora
    else
      ensure_sddm_arch
    fi
  fi

  echo ""
  log_ok "All done. Relogin to mango, then: qs -c jhqs ipc call jhqs reload"
  if [[ "$DO_BACKUP" == true && -d "$backup_root" ]]; then
    log_info "backups (if any) are in: $backup_root"
  fi
  prompt_reboot
}

main "$@"
