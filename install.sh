#!/usr/bin/env bash
# dotfiles + jhqs installer
# Repo:   https://github.com/corzyy/dotfiles
# Shell:  https://github.com/corzyy/jhqs -> ~/.config/quickshell/jhqs
#
# What it does:
#   0. Ensures CachyOS repos are enabled (official cachyos-repo.sh, skipped if present)
#   1. Installs packages from packages.conf (pacman + paru for AUR, incl. mangowm + sddm)
#   2. Copies .config/* from this repo to ~/.config (with backup, skips wallpapers)
#   3. Copies wallpapers/ to "$(xdg-user-dir PICTURES)/wallpapers" (language-independent,
#      works for Pictures/Bilder/whatever xdg says)
#   4. Clones/updates jhqs quickshell config to ~/.config/quickshell/jhqs
#   5. Enables + starts SDDM (systemd), then prompts to reboot to finish
#
# Usage:
#   ./install.sh [options]
#   ./install.sh --dry-run        # show what would happen
#   ./install.sh -y               # no confirm prompt
#   ./install.sh --only-cachyos   # only ensure CachyOS repos
#   ./install.sh --only-packages  # only step 1
#   ./install.sh --only-configs   # only step 2
#   ./install.sh --only-wallpapers
#   ./install.sh --only-jhqs
#   ./install.sh --only-sddm      # only enable/start SDDM
#   ./install.sh --no-cachyos     # skip CachyOS repo setup
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

# --- options (defaults: copy mode, paru for AUR, backup on) ---
ASSUME_YES=false
DRY_RUN=false
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
log_warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
log_err()  { printf '%s[err ]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  echo "Options:"
  echo "  -y, --yes            skip confirm prompt"
  echo "  --dry-run            print actions without changing anything"
  echo "  --only-cachyos       only ensure CachyOS repos are enabled"
  echo "  --only-packages      only install packages"
  echo "  --only-configs       only copy .config files"
  echo "  --only-wallpapers    only install wallpapers"
  echo "  --only-jhqs          only clone/update jhqs"
  echo "  --only-sddm          only enable/start SDDM"
  echo "  --no-cachyos         skip CachyOS repo setup"
  echo "  --no-packages        skip package install"
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
  (cd /tmp/paru && makepkg -si --noconfirm)
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
  (cd /tmp/cachyos-repo && sudo ./cachyos-repo.sh --install)
  log_ok "CachyOS repos enabled"
}

install_packages() {
  if [[ ! -f "$PACKAGES_FILE" ]]; then
    log_err "packages.conf not found: $PACKAGES_FILE"
    return 1
  fi
  # shellcheck source=packages.conf
  PACMAN_PACKAGES=()
  AUR_PACKAGES=()
  # shellcheck disable=SC1090
  source "$PACKAGES_FILE"

  if ! command -v pacman >/dev/null 2>&1; then
    log_err "pacman not found — this installer targets Arch/CachyOS."
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
  run "sudo pacman -Sy"

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
      run "sudo pacman -S --needed --noconfirm ${to_install[*]}"
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
      run "paru -S --needed --noconfirm ${aur_missing[*]}"
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
    log_info "existing jhqs checkout found — pulling latest…"
    run "git -C \"$JHQS_TARGET\" pull --ff-only"
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
  if command -v quickshell >/dev/null 2>&1; then
    run "mkdir -p \"$HOME/.local/bin\""
    if [[ ! -e "$HOME/.local/bin/jhqs" ]]; then
      run "ln -sf \"$(command -v quickshell)\" \"$HOME/.local/bin/jhqs\""
      log_ok "created ~/.local/bin/jhqs launcher"
    else
      log_ok "launcher already exists: ~/.local/bin/jhqs"
    fi
  else
    log_warn "quickshell binary not found — launcher skipped (install packages first)"
  fi
  log_ok "jhqs done"
}

# mangowm + sddm are installed via packages.conf; this enables/starts the
# SDDM display manager so the mango session is reachable after reboot.
ensure_sddm() {
  if ! pacman -Q sddm >/dev/null 2>&1; then
    log_err "sddm is not installed (expected via packages.conf). Run with packages step first."
    return 1
  fi
  if ! pacman -Q mangowm >/dev/null 2>&1; then
    log_warn "mangowm is not installed — SDDM will have no mango session until packages are installed."
  fi
  log_info "Enabling SDDM display manager…"
  # -f disables any competing display manager (gdm, lightdm, …)
  run "sudo systemctl enable sddm.service -f"
  if systemctl is-active --quiet sddm 2>/dev/null; then
    log_ok "SDDM already running"
  else
    log_info "Starting SDDM… (a reboot still finishes the install)"
    run "sudo systemctl start sddm.service"
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

main() {
  while (($# > 0)); do
    case "$1" in
      -y|--yes) ASSUME_YES=true ;;
      --dry-run) DRY_RUN=true ;;
      --only-cachyos) DO_PACKAGES=false; DO_CONFIGS=false; DO_WALLPAPERS=false; DO_JHQS=false; DO_SDDM=false; DO_CACHYOS=true ;;
      --only-packages) DO_CACHYOS=false; DO_CONFIGS=false; DO_WALLPAPERS=false; DO_JHQS=false; DO_SDDM=false; DO_PACKAGES=true ;;
      --only-configs) DO_CACHYOS=false; DO_PACKAGES=false; DO_WALLPAPERS=false; DO_JHQS=false; DO_SDDM=false; DO_CONFIGS=true ;;
      --only-wallpapers) DO_CACHYOS=false; DO_PACKAGES=false; DO_CONFIGS=false; DO_JHQS=false; DO_SDDM=false; DO_WALLPAPERS=true ;;
      --only-jhqs) DO_CACHYOS=false; DO_PACKAGES=false; DO_CONFIGS=false; DO_WALLPAPERS=false; DO_SDDM=false; DO_JHQS=true ;;
      --only-sddm) DO_CACHYOS=false; DO_PACKAGES=false; DO_CONFIGS=false; DO_WALLPAPERS=false; DO_JHQS=false; DO_SDDM=true ;;
      --no-cachyos) DO_CACHYOS=false ;;
      --no-packages) DO_PACKAGES=false ;;
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

  local root backup_root
  root="$(resolve_dotfiles_root)"
  backup_root="$HOME/.config_backup_$(date +%Y%m%d_%H%M%S)"

  echo "${C_BOLD}dotfiles installer${C_RESET}"
  echo "  dotfiles root : $root"
  echo "  jhqs target   : $JHQS_TARGET"
  echo "  pictures dir  : $(get_pictures_dir)/wallpapers"
  echo "  mode          : $([[ "$LINK_MODE" == true ]] && echo "symlink" || echo "copy") / backup $([[ "$DO_BACKUP" == true ]] && echo "on ($backup_root)" || echo "off")"
  echo "  steps         : cachyos=$DO_CACHYOS packages=$DO_PACKAGES configs=$DO_CONFIGS wallpapers=$DO_WALLPAPERS jhqs=$DO_JHQS sddm=$DO_SDDM"
  echo ""

  if [[ ! -d "$root/.config" && ! -d "$root/wallpapers" ]]; then
    log_err "dotfiles root has neither .config nor wallpapers: $root"
    log_info "fresh machine? run: git clone $DOTFILES_REPO $DOTFILES_FALLBACK_DIR"
    exit 1
  fi

  confirm || { log_info "aborted."; exit 0; }

  if [[ "$DO_CACHYOS" == true ]]; then
    ensure_cachyos_repos
  fi
  if [[ "$DO_PACKAGES" == true ]]; then
    install_packages
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
    ensure_sddm
  fi

  echo ""
  log_ok "All done. Relogin to mango, then: qs -c jhqs ipc call jhqs reload"
  if [[ "$DO_BACKUP" == true && -d "$backup_root" ]]; then
    log_info "backups (if any) are in: $backup_root"
  fi
  prompt_reboot
}

main "$@"
