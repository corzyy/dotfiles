#!/usr/bin/env bash
#
# Fedora installer for the corzyy dotfiles and the jhqs Quickshell config.
#
# Installs this repository's configuration on a fresh Fedora system (for
# example the "Everything" netinstall with the Minimal profile) and brings up
# a working MangoWM + Quickshell (jhqs) session:
#
#   1. base       bootstrap tools missing on a minimal install
#   2. terra      enable the Terra repository (mangowm, nerd fonts)
#   3. packages   install the set defined in Installer/packages.conf
#   4. configs    copy .config/* into ~/.config (with backup)
#   5. fisher     install/update the fish plugins listed in fish_plugins
#   6. wallpapers copy wallpapers/ into the XDG Pictures directory
#   7. jhqs       clone/update the Quickshell config and the launcher
#   8. sddm       enable + start SDDM and default to graphical.target
#
# Usage: ./install.sh [options]     (see --help)

set -euo pipefail

DOTFILES_REPO="https://github.com/corzyy/dotfiles.git"
JHQS_REPO="https://github.com/corzyy/jhqs.git"
DOTFILES_DEFAULT_DIR="$HOME/Documents/dotfiles"
JHQS_TARGET="$HOME/.config/quickshell/jhqs"
BACKUP_DIR="$HOME/.config_backup_$(date +%Y%m%d_%H%M%S)"

# When run as `curl … | bash` there is no script path. SCRIPT_DIR stays empty
# and the repository is cloned on demand in main().
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_PATH" ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
else
  SCRIPT_DIR=""
fi
PACKAGES_FILE=""

# --------------------------------------------------------------- options ---
ASSUME_YES=false
DRY_RUN=false
DO_BASE=true
DO_TERRA=true
DO_PACKAGES=true
DO_CONFIGS=true
DO_WALLPAPERS=true
DO_JHQS=true
DO_SDDM=true
DO_FISHER=true
DO_BACKUP=true
LINK_MODE=false
AUTO_REBOOT=false
NO_REBOOT_PROMPT=false
ONLY_MODE=false

if [[ "$EUID" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

# ---------------------------------------------------------- pretty output ---
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
  cat <<'EOF'
Fedora installer for corzyy/dotfiles + corzyy/jhqs

Usage: ./install.sh [options]

One-line install (clones the repo to ~/Documents/dotfiles if needed):

  curl -fsSL https://raw.githubusercontent.com/corzyy/dotfiles/main/install.sh | bash

Pass options after `bash -s --`, e.g. `... | bash -s -- --dry-run`.

General:
  -y, --yes           skip the confirmation prompt
      --dry-run       print what would be done and change nothing
  -h, --help          show this help

File handling:
      --copy          copy configs into ~/.config (default)
      --link          symlink ~/.config entries to this repository
      --no-backup     overwrite existing configs without backing them up

Steps (skip with --no-<step>, run only these with --only-<step>):
  base, terra, packages, configs, fisher, wallpapers, jhqs, sddm

Reboot:
      --no-reboot     do not ask to reboot at the end
      --reboot        reboot automatically when finished
EOF
}

# run: execute a command, or print it in dry-run mode. Arguments are passed
# as a real argv (no eval), so package names and paths are never re-parsed.
run() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

run_root() { run ${SUDO[@]+"${SUDO[@]}"} "$@"; }

# Read a line from the terminal so prompts still work when the script itself
# is piped in (`curl … | bash`), where stdin is the script, not the keyboard.
ask() {
  local prompt="$1" reply=""
  if [[ -r /dev/tty ]]; then
    read -rp "$prompt" reply < /dev/tty || true
  else
    read -rp "$prompt" reply || true
  fi
  printf '%s' "$reply"
}

confirm() {
  [[ "$ASSUME_YES" == true || "$DRY_RUN" == true ]] && return 0
  local reply
  reply="$(ask "Continue? [Y/n] ")"
  [[ -z "$reply" || "$reply" =~ ^[YyJj]$ ]]
}

# ------------------------------------------------------------- discovery ---
detect_dnf() {
  if command -v dnf5 >/dev/null 2>&1; then
    command -v dnf5
  elif command -v dnf >/dev/null 2>&1; then
    command -v dnf
  fi
}

require_fedora() {
  if [[ -z "$(detect_dnf)" ]]; then
    log_err "dnf/dnf5 not found — this installer targets Fedora."
    exit 1
  fi
  if ! grep -qi '^ID=fedora' /etc/os-release 2>/dev/null; then
    log_warn "this does not look like Fedora; continuing because dnf is present."
  fi
}

# Repo root: install.sh lives in the repo root, but tolerate the legacy
# layout where it sat inside Installer/, and fall back to the clone path.
resolve_root() {
  if [[ -n "$SCRIPT_DIR" ]]; then
    if [[ -d "$SCRIPT_DIR/.config" || -d "$SCRIPT_DIR/wallpapers" ]]; then
      printf '%s' "$SCRIPT_DIR"
      return 0
    fi
    local parent
    parent="$(dirname "$SCRIPT_DIR")"
    if [[ -d "$parent/.config" || -d "$parent/wallpapers" ]]; then
      printf '%s' "$parent"
      return 0
    fi
  fi
  printf '%s' "$DOTFILES_DEFAULT_DIR"
}

packages_file_for_root() {
  if [[ -f "$1/Installer/packages.conf" || ! -f "$1/packages.conf" ]]; then
    printf '%s' "$1/Installer/packages.conf"
  else
    printf '%s' "$1/packages.conf"
  fi
}

# `curl … | bash`: clone the repository when no local copy is present.
bootstrap_repo() {
  local root="$1"
  if [[ -d "$root/.config" || -d "$root/wallpapers" ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] git clone %s %s\n' "$DOTFILES_REPO" "$root"
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    log_info "git not found — installing it first"
    run_root "$DNF" install -y git
  fi
  log_info "cloning $DOTFILES_REPO into $root"
  run mkdir -p "$(dirname "$root")"
  run git clone "$DOTFILES_REPO" "$root"
}

# Pictures directory in the user's language (Pictures / Bilder / ...).
pictures_dir() {
  local dir=""
  if command -v xdg-user-dir >/dev/null 2>&1; then
    dir="$(xdg-user-dir PICTURES 2>/dev/null || true)"
  fi
  if [[ -z "$dir" || "$dir" == "$HOME" ]]; then
    dir="$HOME/Pictures"
  fi
  printf '%s' "$dir"
}

# ------------------------------------------------------------- packages ---
load_packages() {
  if [[ ! -f "$PACKAGES_FILE" ]]; then
    log_err "package config not found: $PACKAGES_FILE"
    return 1
  fi
  BASE_PACKAGES=()
  PACKAGES=()
  ENABLE_TERRA="true"
  # shellcheck source=/dev/null
  source "$PACKAGES_FILE"
}

# Fill the named array with the unique, non-comment arguments, in order.
dedupe_into() {
  local -n _out="$1"
  shift
  local -A seen=()
  local item
  _out=()
  for item in "$@"; do
    [[ -z "$item" || "$item" == \#* ]] && continue
    [[ -n "${seen[$item]:-}" ]] && continue
    seen[$item]=1
    _out+=("$item")
  done
}

pkg_installed() { rpm -q --quiet "$1"; }
pkg_available() { "$DNF" list --available --quiet "$1" >/dev/null 2>&1; }

ensure_base() {
  load_packages
  local pkgs=() missing=() p
  dedupe_into pkgs ${BASE_PACKAGES[@]+"${BASE_PACKAGES[@]}"}
  for p in ${pkgs[@]+"${pkgs[@]}"}; do
    if pkg_installed "$p"; then
      log_ok "already installed: $p"
    else
      missing+=("$p")
    fi
  done
  if ((${#missing[@]} == 0)); then
    log_ok "base tools already present"
    return 0
  fi
  log_info "installing base tools: ${missing[*]}"
  run_root "$DNF" install -y "${missing[@]}"
  log_ok "base tools done"
}

ensure_terra() {
  load_packages
  if [[ "${ENABLE_TERRA:-true}" != "true" ]]; then
    log_info "Terra disabled in packages.conf — skipping"
    return 0
  fi
  if [[ -f /etc/yum.repos.d/terra.repo ]]; then
    log_ok "Terra repository already enabled"
    return 0
  fi
  log_info "enabling the Terra repository (provides mangowm and nerd fonts)…"
  run_root "$DNF" install -y --nogpgcheck \
    --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
    terra-release terra-gpg-keys
  log_ok "Terra repository enabled"
}

install_packages() {
  load_packages
  local pkgs=()
  dedupe_into pkgs ${PACKAGES[@]+"${PACKAGES[@]}"}
  if ((${#pkgs[@]} == 0)); then
    log_info "no packages configured"
    return 0
  fi

  # Partition into already-installed, installable and unavailable so a single
  # unknown name (e.g. an older Fedora release) cannot abort the whole run.
  local to_install=() missing=() p
  for p in "${pkgs[@]}"; do
    if pkg_installed "$p"; then
      log_ok "already installed: $p"
    elif pkg_available "$p"; then
      to_install+=("$p")
    else
      missing+=("$p")
    fi
  done

  if ((${#to_install[@]} > 0)); then
    log_info "installing ${#to_install[@]} packages: ${to_install[*]}"
    run_root "$DNF" install -y "${to_install[@]}"
  fi

  if ((${#missing[@]} > 0)); then
    log_warn "not available in the enabled repositories: ${missing[*]}"
  fi

  # Without these the Mango session cannot come up at all.
  local critical
  for critical in mangowm quickshell sddm; do
    if ! pkg_installed "$critical"; then
      log_err "required package is missing: $critical"
      log_err "make sure Terra is enabled, then re-run: ./install.sh --only-packages -y"
      return 1
    fi
  done
  log_ok "packages done"
}

# -------------------------------------------------------------- configs ---
backup_path() {
  local src="$1"
  local base dest
  base="$(basename "$src")"
  dest="$BACKUP_DIR/$base"
  if [[ -e "$dest" ]]; then
    dest="$BACKUP_DIR/$base.$(date +%H%M%S)"
  fi
  log_warn "backing up $src -> $dest"
  run mkdir -p "$BACKUP_DIR"
  run mv "$src" "$dest"
}

install_config_entry() {
  local src="$1" dest="$2" name="$3"
  if [[ -L "$dest" ]]; then
    log_info "replacing symlink: $dest"
    run rm -f "$dest"
  elif [[ -e "$dest" ]]; then
    if diff -qr "$src" "$dest" >/dev/null 2>&1; then
      log_ok "unchanged: ~/.config/$name"
    elif [[ "$DO_BACKUP" == true ]]; then
      backup_path "$dest"
    else
      log_warn "overwriting existing ~/.config/$name (backup disabled)"
    fi
  fi

  if [[ "$LINK_MODE" == true ]]; then
    run mkdir -p "$(dirname "$dest")"
    run ln -sfn "$src" "$dest"
  else
    run mkdir -p "$dest"
    run cp -a "$src/." "$dest/"
  fi
  log_ok "installed ~/.config/$name"
}

make_scripts_executable() {
  local f
  for f in "$HOME/.config/mango/wallpaper-restore.sh" "$HOME/.config/matugen/post-hook-scripts"/*.sh; do
    if [[ -f "$f" ]]; then
      run chmod +x "$f"
    fi
  done
}

install_configs() {
  local root="$1"
  local src="$root/.config"
  if [[ ! -d "$src" ]]; then
    log_err "no .config directory found in $root"
    return 1
  fi
  log_info "installing configs: $src -> $HOME/.config"
  local entry name dest
  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    [[ "$name" == "wallpapers" ]] && continue
    dest="$HOME/.config/$name"
    install_config_entry "$entry" "$dest" "$name"
  done < <(find "$src" -mindepth 1 -maxdepth 1 -print0 | sort -z)
  make_scripts_executable
  log_ok "configs done"
}

# ----------------------------------------------------------- wallpapers ---
install_wallpapers() {
  local root="$1" src="" c
  for c in "$root/wallpapers" "$root/.config/wallpapers"; do
    if [[ -d "$c" ]]; then
      src="$c"
      break
    fi
  done
  if [[ -z "$src" ]]; then
    log_warn "no wallpapers directory found — skipping"
    return 0
  fi
  local dest
  dest="$(pictures_dir)/wallpapers"
  log_info "installing wallpapers: $src -> $dest"
  run mkdir -p "$dest"
  if command -v rsync >/dev/null 2>&1; then
    run rsync -a "$src/" "$dest/"
  else
    run cp -a "$src/." "$dest/"
  fi
  log_ok "wallpapers done"
}

# ---------------------------------------------------------- fish plugins ---
# Fisher (shipped with the fish config) reads ~/.config/fish/fish_plugins and
# installs/updates every plugin listed there.
install_fish_plugins() {
  if ! command -v fish >/dev/null 2>&1; then
    log_warn "fish is not installed — skipping fisher"
    return 0
  fi
  if [[ ! -f "$HOME/.config/fish/functions/fisher.fish" ]]; then
    log_info "fisher not found — installing it"
    run fish -c 'curl -fsSL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher' \
      || log_warn "could not install fisher — continuing"
  fi
  local plugins_file="$HOME/.config/fish/fish_plugins"
  if [[ ! -f "$plugins_file" ]]; then
    log_info "no $plugins_file — nothing to install"
    return 0
  fi
  log_info "installing/updating fish plugins: $(tr '\n' ' ' < "$plugins_file")"
  if run fish -c 'fisher update'; then
    log_ok "fish plugins done"
  else
    log_warn "some fish plugins could not be installed/updated — continuing"
  fi
}

# ----------------------------------------------------------------- jhqs ---
install_jhqs() {
  log_info "installing jhqs: $JHQS_REPO -> $JHQS_TARGET"
  if [[ -d "$JHQS_TARGET/.git" ]]; then
    if [[ -n "$(git -C "$JHQS_TARGET" status --porcelain 2>/dev/null)" ]]; then
      log_warn "jhqs has local changes — not pulling automatically"
    else
      run git -C "$JHQS_TARGET" pull --ff-only \
        || log_warn "could not update jhqs — using the existing checkout"
    fi
  else
    if [[ -e "$JHQS_TARGET" ]]; then
      if [[ "$DO_BACKUP" == true ]]; then
        backup_path "$JHQS_TARGET"
      else
        run rm -rf "$JHQS_TARGET"
      fi
    fi
    run mkdir -p "$(dirname "$JHQS_TARGET")"
    run git clone "$JHQS_REPO" "$JHQS_TARGET"
  fi

  local script
  for script in "$JHQS_TARGET"/scripts/*.sh; do
    if [[ -f "$script" ]]; then
      run chmod +x "$script"
    fi
  done

  # Mango autostart runs ~/.local/bin/jhqs, so provide that launcher.
  local qs_bin
  qs_bin="$(command -v quickshell || true)"
  if [[ -z "$qs_bin" && -x /usr/bin/quickshell ]]; then
    qs_bin="/usr/bin/quickshell"
  fi
  if [[ -z "$qs_bin" ]]; then
    log_warn "quickshell not found — install packages first; launcher skipped"
    return 0
  fi
  run mkdir -p "$HOME/.local/bin"
  if [[ -e "$HOME/.local/bin/jhqs" || -L "$HOME/.local/bin/jhqs" ]]; then
    log_ok "launcher already present: ~/.local/bin/jhqs"
  else
    run ln -s "$qs_bin" "$HOME/.local/bin/jhqs"
    log_ok "created ~/.local/bin/jhqs -> $qs_bin"
  fi
  log_ok "jhqs done"
}

# ----------------------------------------------------------------- sddm ---
verify_mango_session() {
  local sessions=(/usr/share/wayland-sessions/*mango*.desktop)
  if [[ -e "${sessions[0]}" ]]; then
    log_ok "mango session found: $(basename "${sessions[0]}")"
  else
    log_warn "no mango session in /usr/share/wayland-sessions — install mangowm first"
  fi
}

ensure_sddm() {
  if ! pkg_installed sddm; then
    log_err "sddm is not installed — run the packages step first"
    return 1
  fi
  if ! pkg_installed mangowm; then
    log_warn "mangowm is not installed — SDDM will have no mango session yet"
  fi

  log_info "enabling SDDM…"
  if ! run_root systemctl enable sddm.service -f; then
    log_err "could not enable sddm.service"
    return 1
  fi

  log_info "setting graphical.target as the default boot target…"
  run_root systemctl set-default graphical.target \
    || log_warn "could not set graphical.target — continuing"

  if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
    if ! systemctl is-enabled --quiet NetworkManager.service 2>/dev/null; then
      run_root systemctl enable NetworkManager.service \
        || log_warn "could not enable NetworkManager — continuing"
    fi
  fi

  if systemctl is-active --quiet sddm 2>/dev/null; then
    log_ok "SDDM already running"
  else
    run_root systemctl start sddm.service \
      || log_warn "could not start SDDM now — it will start on reboot"
  fi

  verify_mango_session
  log_ok "sddm done"
}

# --------------------------------------------------------------- reboot ---
prompt_reboot() {
  if [[ "$NO_REBOOT_PROMPT" == true ]]; then
    log_info "reboot prompt skipped (--no-reboot)"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] prompt: reboot now to finish the installation? [y/N]\n'
    return 0
  fi
  if [[ "$AUTO_REBOOT" == true ]]; then
    log_warn "rebooting now (--reboot)…"
    run_root reboot
    return 0
  fi
  local reply
  reply="$(ask "Reboot now to finish the installation? [y/N] ")"
  if [[ "$reply" =~ ^[YyJj]$ ]]; then
    log_warn "rebooting now…"
    run_root reboot
  else
    log_info "reboot skipped — reboot manually to reach the Mango session"
  fi
}

disable_all_steps() {
  DO_BASE=false; DO_TERRA=false; DO_PACKAGES=false; DO_CONFIGS=false
  DO_WALLPAPERS=false; DO_JHQS=false; DO_SDDM=false; DO_FISHER=false
}

# --only-<step>: on first use select just the requested step(s); additional
# --only flags combine instead of overriding each other.
only_step() {
  if [[ "$ONLY_MODE" == false ]]; then
    disable_all_steps
    ONLY_MODE=true
  fi
  local -n step_var="$1"
  step_var=true
}

# ----------------------------------------------------------------- main ---
main() {
  while (($# > 0)); do
    case "$1" in
      -y|--yes) ASSUME_YES=true ;;
      --dry-run) DRY_RUN=true ;;
      --copy) LINK_MODE=false ;;
      --link) LINK_MODE=true ;;
      --no-backup) DO_BACKUP=false ;;
      --no-reboot) NO_REBOOT_PROMPT=true ;;
      --reboot) AUTO_REBOOT=true; NO_REBOOT_PROMPT=false ;;
      --only-base) only_step DO_BASE ;;
      --only-terra) only_step DO_TERRA ;;
      --only-packages) only_step DO_PACKAGES ;;
      --only-configs) only_step DO_CONFIGS ;;
      --only-fisher) only_step DO_FISHER ;;
      --only-wallpapers) only_step DO_WALLPAPERS ;;
      --only-jhqs) only_step DO_JHQS ;;
      --only-sddm) only_step DO_SDDM ;;
      --no-base) DO_BASE=false ;;
      --no-terra) DO_TERRA=false ;;
      --no-packages) DO_PACKAGES=false ;;
      --no-configs) DO_CONFIGS=false ;;
      --no-fisher) DO_FISHER=false ;;
      --no-wallpapers) DO_WALLPAPERS=false ;;
      --no-jhqs) DO_JHQS=false ;;
      --no-sddm) DO_SDDM=false ;;
      -h|--help) usage; exit 0 ;;
      *)
        log_err "unknown option: $1"
        echo
        usage
        exit 1
        ;;
    esac
    shift
  done

  require_fedora
  DNF="$(detect_dnf)"

  if [[ "$EUID" -eq 0 ]]; then
    log_warn "running as root — user configs go to $HOME; prefer running as your normal user"
  fi

  local root
  root="$(resolve_root)"
  PACKAGES_FILE="$(packages_file_for_root "$root")"

  local mode backup_state
  [[ "$LINK_MODE" == true ]] && mode="symlink" || mode="copy"
  [[ "$DO_BACKUP" == true ]] && backup_state="yes" || backup_state="no"

  echo "${C_BOLD}Fedora dotfiles installer${C_RESET}"
  echo "  dotfiles : $root"
  echo "  packages : $PACKAGES_FILE"
  echo "  dnf      : $DNF"
  echo "  mode     : $mode (backup: $backup_state)"
  echo "  steps    : base=$DO_BASE terra=$DO_TERRA packages=$DO_PACKAGES configs=$DO_CONFIGS fisher=$DO_FISHER wallpapers=$DO_WALLPAPERS jhqs=$DO_JHQS sddm=$DO_SDDM"
  echo ""

  confirm || { log_info "aborted"; exit 0; }

  if [[ "$DRY_RUN" == false && "$EUID" -ne 0 \
    && ("$DO_BASE" == true || "$DO_TERRA" == true || "$DO_PACKAGES" == true || "$DO_SDDM" == true) ]]; then
    log_info "requesting sudo for the system steps…"
    if ! sudo -v; then
      log_err "sudo authentication failed"
      log_err "skip the system steps with: --no-base --no-terra --no-packages --no-sddm"
      exit 1
    fi
  fi

  bootstrap_repo "$root"
  # Re-resolve now that the repository may have just been cloned.
  PACKAGES_FILE="$(packages_file_for_root "$root")"
  if [[ "$DRY_RUN" == true && ! -d "$root/.config" && ! -d "$root/wallpapers" ]]; then
    log_warn "preview without a local repository — showing the clone step only"
    DO_BASE=false; DO_TERRA=false; DO_PACKAGES=false
    DO_CONFIGS=false; DO_FISHER=false; DO_WALLPAPERS=false
  fi

  if [[ "$DO_BASE" == true ]]; then ensure_base; fi
  if [[ "$DO_TERRA" == true ]]; then ensure_terra; fi
  if [[ "$DO_PACKAGES" == true ]]; then install_packages; fi
  if [[ "$DO_CONFIGS" == true ]]; then install_configs "$root"; fi
  if [[ "$DO_FISHER" == true ]]; then install_fish_plugins; fi
  if [[ "$DO_WALLPAPERS" == true ]]; then install_wallpapers "$root"; fi
  if [[ "$DO_JHQS" == true ]]; then install_jhqs; fi
  if [[ "$DO_SDDM" == true ]]; then ensure_sddm; fi

  echo ""
  log_ok "all done — log in to the Mango session, then run: qs -c jhqs ipc call jhqs reload"
  if [[ "$DO_BACKUP" == true && -d "$BACKUP_DIR" ]]; then
    log_info "backups (if any) are in: $BACKUP_DIR"
  fi
  prompt_reboot
}

main "$@"
