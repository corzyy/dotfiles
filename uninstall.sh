#!/usr/bin/env bash
#
# Uninstaller for the corzyy dotfiles and the solstice Quickshell config.
#
# Reverses the changes made by install.sh:
#
#   1. solstice   stop the shell, remove ~/.config/quickshell/solstice, the
#                 ~/.local/bin/solstice CLI and the fonts solstice installed
#   2. sddm       disable sddm.service and boot to multi-user.target again
#   3. configs    remove the ~/.config entries copied from this repository
#                 (local changes inside them are removed as well)
#   4. gtk        remove the generated GTK settings/css, reset gsettings
#   5. cursor     remove the bundled MacOS-Tahoe cursor, reset gsettings
#   6. fisher     remove the fisher plugin manager and the installed plugins
#   7. wallpapers remove the wallpapers copied into the Pictures directory;
#                 files that did not come from this repository are kept
#   8. m3shapes   remove the system-wide M3Shapes QML module, the source and
#                 build directories and the build dependencies
#   9. packages   dnf remove the required and optional packages
#  10. terra      remove the Terra repository
#  11. base       dnf remove the bootstrap tools (git, curl, rsync,
#                 xdg-user-dirs)
#
# Packages are removed by default; --keep-packages leaves every dnf package
# untouched. The ~/.config_backup_* directories created by install.sh are
# never deleted — their location is printed at the end.
#
# Usage: ./uninstall.sh [options]     (see --help)

set -euo pipefail

DOTFILES_DEFAULT_DIR="$HOME/Documents/dotfiles"
SOLSTICE_TARGET="$HOME/.config/quickshell/solstice"
M3SHAPES_SRC="$HOME/.local/share/m3shapes"
M3SHAPES_BUILD_DIR="$HOME/.cache/m3shapes-build"

CURSOR_THEME="MacOS-Tahoe-Cursor"

# When run as `curl … | bash` there is no script path. SCRIPT_DIR stays empty
# and the default dotfiles location is used.
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_PATH" ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
else
  SCRIPT_DIR=""
fi
PACKAGES_FILE=""
REPO_ROOT=""

# --------------------------------------------------------------- options ---
ASSUME_YES=false
DRY_RUN=false
KEEP_PACKAGES=false
DO_BASE=true
DO_TERRA=true
DO_PACKAGES=true
DO_CONFIGS=true
DO_GTK=true
DO_CURSOR=true
DO_FISHER=true
DO_WALLPAPERS=true
DO_M3SHAPES=true
DO_SOLSTICE=true
DO_SDDM=true
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
Fedora uninstaller for corzyy/dotfiles + corzyy/solstice

Usage: ./uninstall.sh [options]

General:
  -y, --yes           skip the confirmation prompt
      --dry-run       print what would be done and change nothing
  -h, --help          show this help

Packages:
      --keep-packages do not remove any dnf packages (skips the base, terra
                      and packages steps and the m3shapes build dependencies)

Steps (skip with --no-<step>, run only these with --only-<step>):
  base, terra, packages, configs, gtk, cursor, fisher, wallpapers, m3shapes,
  solstice, sddm

Reboot:
      --no-reboot     do not ask to reboot at the end
      --reboot        reboot automatically when finished

System packages are removed by default. Config backups in ~/.config_backup_*
are left untouched.
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
# is piped in, where stdin is the script, not the keyboard.
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

# Repo root: uninstall.sh lives in the repo root, but tolerate the legacy
# layout where it sat inside Installer/, and fall back to the default path.
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

# Locate packages.conf (same candidate order as install.sh).
resolve_packages_file() {
  local candidates=() c
  if [[ -n "${REPO_ROOT:-}" ]]; then
    candidates+=("$REPO_ROOT/Installer/packages.conf" "$REPO_ROOT/packages.conf")
  fi
  if [[ -n "$SCRIPT_DIR" ]]; then
    candidates+=("$SCRIPT_DIR/Installer/packages.conf" "$SCRIPT_DIR/packages.conf")
  fi
  candidates+=(
    "$DOTFILES_DEFAULT_DIR/Installer/packages.conf"
    "$DOTFILES_DEFAULT_DIR/packages.conf"
  )
  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      printf '%s' "$c"
      return 0
    fi
  done
  printf '%s' "${REPO_ROOT:-$DOTFILES_DEFAULT_DIR}/Installer/packages.conf"
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
  PACKAGES_FILE="$(resolve_packages_file)"
  if [[ ! -f "$PACKAGES_FILE" ]]; then
    log_err "package config not found (looked for Installer/packages.conf and packages.conf)"
    log_err "expected it under: ${REPO_ROOT:-$DOTFILES_DEFAULT_DIR}"
    return 1
  fi
  BASE_PACKAGES=()
  PACKAGES=()
  APP_PACKAGES=()
  M3SHAPES_PACKAGES=()
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

pkg_installed() { rpm -q --quiet "$1" 2>/dev/null; }

# Display managers other than SDDM. install.sh leaves SDDM alone when one of
# these is installed, so the uninstaller does the same.
OTHER_DMS=(gdm lightdm lxdm ly greetd xdm)
DISPLAY_MANAGER=""
detect_display_manager() {
  local dm
  DISPLAY_MANAGER=""
  for dm in "${OTHER_DMS[@]}" sddm; do
    if pkg_installed "$dm"; then
      DISPLAY_MANAGER="$dm"
      return 0
    fi
  done
}

# True when SDDM must be left alone because another DM is already installed.
sddm_skipped() {
  [[ -n "$DISPLAY_MANAGER" && "$DISPLAY_MANAGER" != "sddm" ]]
}

# Remove one package name from the array referenced by name.
remove_pkg_from() {
  local -n _arr="$1"
  local exclude="$2" item
  local out=()
  for item in "${_arr[@]}"; do
    [[ "$item" == "$exclude" ]] || out+=("$item")
  done
  _arr=(${out[@]+"${out[@]}"})
}

# ------------------------------------------------------------ removal ---
FAILURES=()
fail_step() {
  FAILURES+=("$1")
  log_warn "$1"
}

# rmdir only when the directory ended up empty (keeps user files like
# gtk-3.0/bookmarks and gtk-4.0/assets).
maybe_rmdir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] rmdir %s (if empty)\n' "$dir"
    return 0
  fi
  rmdir --ignore-fail-on-non-empty -- "$dir" 2>/dev/null || true
}

remove_path() {
  local path="$1"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    log_ok "not present: ${path/#$HOME/\~}"
    return 0
  fi
  log_info "removing ${path/#$HOME/\~}"
  run rm -rf -- "$path"
}

remove_root_path() {
  local path="$1"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return 0
  fi
  log_info "removing $path"
  run_root rm -rf -- "$path"
}

# Remove the installed packages from one list, skipping names that are not
# installed. A failed dnf run is recorded and does not abort the uninstall.
remove_pkg_list() {
  local label="$1"; shift
  local pkgs=("$@") installed=() p
  if [[ -z "$DNF" ]]; then
    log_warn "dnf/dnf5 not found — skipping removal of $label"
    return 0
  fi
  for p in "${pkgs[@]}"; do
    if pkg_installed "$p"; then
      installed+=("$p")
    fi
  done
  if ((${#installed[@]} == 0)); then
    log_ok "no $label installed"
    return 0
  fi
  log_info "removing ${#installed[@]} $label: ${installed[*]}"
  if ! run_root "$DNF" remove -y "${installed[@]}"; then
    fail_step "could not remove $label"
    return 0
  fi
  log_ok "$label removed"
}

# --------------------------------------------------------------- steps ---
uninstall_solstice() {
  local cli="$HOME/.local/bin/solstice"
  if [[ -x "$cli" ]]; then
    log_info "stopping the solstice shell (if running)…"
    run "$cli" stop || log_warn "could not stop solstice — continuing"
  elif command -v quickshell >/dev/null 2>&1; then
    run quickshell kill -c solstice || true
  fi

  if [[ -L "$cli" ]]; then
    local target
    target="$(readlink "$cli" 2>/dev/null || true)"
    if [[ "$target" == *quickshell/solstice* ]]; then
      remove_path "$cli"
    else
      log_warn "$cli points to $target — not removing it"
    fi
  elif [[ -e "$cli" ]]; then
    log_warn "$cli is not a symlink — leaving it"
  fi

  if [[ -d "$SOLSTICE_TARGET/.git" && "$DRY_RUN" == false ]] \
    && command -v git >/dev/null 2>&1 \
    && [[ -n "$(git -C "$SOLSTICE_TARGET" status --porcelain 2>/dev/null)" ]]; then
    log_warn "solstice checkout has local changes — removing them anyway"
  fi
  remove_path "$SOLSTICE_TARGET"

  # Fonts installed by solstice's own installer (ensure-*-font.sh).
  local font_dir="${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
  remove_path "$font_dir/NotoColorEmoji.ttf"
  remove_path "$font_dir/MaterialSymbolsRounded[FILL,GRAD,opsz,wght].ttf"
  if [[ "$DRY_RUN" == false ]] && command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "$font_dir" >/dev/null 2>&1 || true
  fi
  log_ok "solstice removed"
}

uninstall_sddm() {
  if sddm_skipped; then
    log_info "display manager already installed: $DISPLAY_MANAGER — not touching SDDM"
    return 0
  fi
  if ! pkg_installed sddm; then
    log_ok "sddm not installed — nothing to disable"
    return 0
  fi
  log_info "disabling SDDM…"
  run_root systemctl disable sddm.service \
    || log_warn "could not disable sddm.service — continuing"
  log_info "setting multi-user.target as the default boot target…"
  run_root systemctl set-default multi-user.target \
    || log_warn "could not set multi-user.target — continuing"
  log_ok "sddm disabled (the package is removed by the packages step)"
}

uninstall_configs() {
  local root="$1"
  local src="$root/.config"
  if [[ ! -d "$src" ]]; then
    log_warn "no .config directory in $root — skipping"
    return 0
  fi
  log_info "removing installed configs from $HOME/.config"
  local entry name dest
  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    [[ "$name" == "wallpapers" ]] && continue
    dest="$HOME/.config/$name"
    if [[ -L "$dest" ]]; then
      remove_path "$dest"
      continue
    fi
    if [[ ! -e "$dest" ]]; then
      log_ok "not installed: ~/.config/$name"
      continue
    fi
    if [[ -d "$dest" ]] && ! diff -qr "$entry" "$dest" >/dev/null 2>&1; then
      log_warn "~/.config/$name has local changes — removing it anyway"
    fi
    log_info "removing ~/.config/$name"
    run rm -rf -- "$dest"
  done < <(find "$src" -mindepth 1 -maxdepth 1 -print0 | sort -z)
  log_ok "configs removed"
}

uninstall_gtk() {
  local dirs=(gtk-3.0 gtk-4.0) dir f
  for dir in "${dirs[@]}"; do
    for f in settings.ini gtk.css colors.css; do
      remove_path "$HOME/.config/$dir/$f"
    done
    maybe_rmdir "$HOME/.config/$dir"
  done
  if command -v gsettings >/dev/null 2>&1; then
    run gsettings reset org.gnome.desktop.interface gtk-theme \
      || log_warn "could not reset gtk-theme via gsettings — continuing"
    run gsettings reset org.gnome.desktop.interface color-scheme \
      || log_warn "could not reset color-scheme via gsettings — continuing"
  fi
  log_ok "GTK theme reverted"
}

uninstall_cursor() {
  remove_path "$HOME/.local/share/icons/$CURSOR_THEME"
  if command -v gsettings >/dev/null 2>&1; then
    run gsettings reset org.gnome.desktop.interface cursor-theme \
      || log_warn "could not reset cursor-theme via gsettings — continuing"
    run gsettings reset org.gnome.desktop.interface cursor-size \
      || log_warn "could not reset cursor-size via gsettings — continuing"
  fi
  remove_path "$HOME/.config/environment.d/cursor.conf"
  maybe_rmdir "$HOME/.config/environment.d"
  log_ok "cursor theme removed"
}

uninstall_fisher() {
  local fisher_bin="$HOME/.config/fish/functions/fisher.fish"
  local plugins_file="$HOME/.config/fish/fish_plugins"
  if ! command -v fish >/dev/null 2>&1 || [[ ! -f "$fisher_bin" ]]; then
    log_ok "fisher not installed"
    return 0
  fi
  if [[ -f "$plugins_file" ]]; then
    local plugins=() line
    while IFS= read -r line; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      [[ "$line" == "jorgebucaran/fisher" ]] && continue
      plugins+=("$line")
    done < "$plugins_file"
    if ((${#plugins[@]} > 0)); then
      log_info "removing fish plugins: ${plugins[*]}"
      run fish -c 'for p in $argv; fisher remove $p; end' "${plugins[@]}" \
        || log_warn "could not remove some fish plugins — continuing"
    fi
  fi
  remove_path "$HOME/.config/fish/functions/fisher.fish"
  remove_path "$HOME/.config/fish/completions/fisher.fish"
  remove_path "$HOME/.config/fish/conf.d/fisher.fish"
  log_ok "fisher removed"
}

uninstall_wallpapers() {
  local root="$1" src="" c dest
  for c in "$root/wallpapers" "$root/.config/wallpapers"; do
    if [[ -d "$c" ]]; then
      src="$c"
      break
    fi
  done
  dest="$(pictures_dir)/wallpapers"
  if [[ -z "$src" ]]; then
    log_warn "no wallpapers directory in $root — removing ${dest/#$HOME/\~} entirely"
    remove_path "$dest"
    return 0
  fi
  if [[ ! -d "$dest" ]]; then
    log_ok "not present: ${dest/#$HOME/\~}"
    return 0
  fi
  log_info "removing wallpapers copied to ${dest/#$HOME/\~}"
  local f rel target removed=0
  while IFS= read -r -d '' f; do
    rel="${f#"$src"/}"
    target="$dest/$rel"
    if [[ -f "$target" ]] && cmp -s "$f" "$target"; then
      run rm -f -- "$target"
      removed=$((removed + 1))
    fi
  done < <(find "$src" -type f -print0)
  if [[ "$DRY_RUN" == false ]]; then
    find "$dest" -depth -type d -empty -delete 2>/dev/null || true
  else
    printf '[dry-run] prune empty directories under %s\n' "$dest"
  fi
  log_ok "removed $removed installed wallpaper(s); user-added files are kept"
}

uninstall_m3shapes() {
  local lib_dir=""
  if command -v rpm >/dev/null 2>&1; then
    lib_dir="$(rpm --eval '%{_libdir}')"
  fi
  if [[ -n "$lib_dir" ]]; then
    remove_root_path "$lib_dir/qt6/qml/M3Shapes"
    remove_root_path "$lib_dir/libm3shapes.so"
    remove_root_path "$lib_dir/cmake/M3Shapes"
    remove_root_path "/usr/include/m3shapes"
  else
    log_warn "rpm not found — cannot locate the system-wide M3Shapes files"
  fi
  remove_path "$M3SHAPES_SRC"
  remove_path "$M3SHAPES_BUILD_DIR"

  if [[ "$KEEP_PACKAGES" == true ]]; then
    log_info "keeping m3shapes build dependencies (--keep-packages)"
    return 0
  fi
  load_packages
  local pkgs=()
  dedupe_into pkgs ${M3SHAPES_PACKAGES[@]+"${M3SHAPES_PACKAGES[@]}"}
  remove_pkg_list "m3shapes build dependencies" ${pkgs[@]+"${pkgs[@]}"}
  log_ok "m3shapes removed"
}

uninstall_packages() {
  load_packages
  local pkgs=()
  dedupe_into pkgs ${PACKAGES[@]+"${PACKAGES[@]}"} ${APP_PACKAGES[@]+"${APP_PACKAGES[@]}"}
  if ((${#pkgs[@]} == 0)); then
    log_info "no packages configured"
    return 0
  fi
  if sddm_skipped; then
    log_info "another display manager is installed: $DISPLAY_MANAGER — keeping sddm"
    remove_pkg_from pkgs sddm
  fi
  remove_pkg_list "required and optional packages" "${pkgs[@]}"
}

uninstall_terra() {
  remove_pkg_list "Terra repository packages" terra-release terra-gpg-keys
  local f
  for f in /etc/yum.repos.d/terra*.repo; do
    if [[ -e "$f" ]]; then
      log_info "removing $f"
      run_root rm -f -- "$f"
    fi
  done
  log_ok "Terra repository removed"
}

uninstall_base() {
  load_packages
  local pkgs=()
  dedupe_into pkgs ${BASE_PACKAGES[@]+"${BASE_PACKAGES[@]}"}
  remove_pkg_list "base tools" ${pkgs[@]+"${pkgs[@]}"}
}

# install.sh set it so interactive dnf runs do not stop on "Is this ok?".
unconfigure_dnf() {
  [[ -n "$DNF" ]] || return 0
  log_info "reverting dnf config: defaultyes"
  run_root "$DNF" config-manager unsetopt defaultyes \
    || log_warn "could not unset dnf defaultyes — continuing"
}

# --------------------------------------------------------------- reboot ---
prompt_reboot() {
  if [[ "$NO_REBOOT_PROMPT" == true ]]; then
    log_info "reboot prompt skipped (--no-reboot)"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] prompt: reboot now to finish the uninstall? [y/N]\n'
    return 0
  fi
  if [[ "$AUTO_REBOOT" == true ]]; then
    log_warn "rebooting now (--reboot)…"
    run_root reboot
    return 0
  fi
  local reply
  reply="$(ask "Reboot now to finish the uninstall? [y/N] ")"
  if [[ "$reply" =~ ^[YyJj]$ ]]; then
    log_warn "rebooting now…"
    run_root reboot
  else
    log_info "reboot skipped"
  fi
}

disable_all_steps() {
  DO_BASE=false; DO_TERRA=false; DO_PACKAGES=false; DO_CONFIGS=false
  DO_GTK=false; DO_CURSOR=false; DO_FISHER=false; DO_WALLPAPERS=false
  DO_M3SHAPES=false; DO_SOLSTICE=false; DO_SDDM=false
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
      --keep-packages) KEEP_PACKAGES=true ;;
      --no-reboot) NO_REBOOT_PROMPT=true ;;
      --reboot) AUTO_REBOOT=true; NO_REBOOT_PROMPT=false ;;
      --only-base) only_step DO_BASE ;;
      --only-terra) only_step DO_TERRA ;;
      --only-packages) only_step DO_PACKAGES ;;
      --only-configs) only_step DO_CONFIGS ;;
      --only-gtk) only_step DO_GTK ;;
      --only-cursor) only_step DO_CURSOR ;;
      --only-fisher) only_step DO_FISHER ;;
      --only-wallpapers) only_step DO_WALLPAPERS ;;
      --only-m3shapes) only_step DO_M3SHAPES ;;
      --only-solstice) only_step DO_SOLSTICE ;;
      --only-sddm) only_step DO_SDDM ;;
      --no-base) DO_BASE=false ;;
      --no-terra) DO_TERRA=false ;;
      --no-packages) DO_PACKAGES=false ;;
      --no-configs) DO_CONFIGS=false ;;
      --no-gtk) DO_GTK=false ;;
      --no-cursor) DO_CURSOR=false ;;
      --no-fisher) DO_FISHER=false ;;
      --no-wallpapers) DO_WALLPAPERS=false ;;
      --no-m3shapes) DO_M3SHAPES=false ;;
      --no-solstice) DO_SOLSTICE=false ;;
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

  if [[ "$KEEP_PACKAGES" == true ]]; then
    DO_BASE=false; DO_TERRA=false; DO_PACKAGES=false
  fi

  DNF="$(detect_dnf || true)"
  detect_display_manager
  if [[ -z "$DNF" && ( "$DO_BASE" == true || "$DO_TERRA" == true || "$DO_PACKAGES" == true ) ]]; then
    log_warn "dnf/dnf5 not found — package steps are skipped"
    DO_BASE=false; DO_TERRA=false; DO_PACKAGES=false
  fi

  if [[ "$EUID" -eq 0 ]]; then
    log_warn "running as root — user files are removed from $HOME; prefer running as your normal user"
  fi

  local root
  root="$(resolve_root)"
  REPO_ROOT="$root"
  PACKAGES_FILE="$(resolve_packages_file)"

  local mode
  [[ "$DRY_RUN" == true ]] && mode="dry-run (nothing is changed)" || mode="remove"

  echo "${C_BOLD}Fedora dotfiles uninstaller${C_RESET}"
  echo "  dotfiles : $root"
  echo "  packages : $PACKAGES_FILE"
  echo "  dnf      : ${DNF:-not found}"
  if sddm_skipped; then
    echo "  display  : $DISPLAY_MANAGER (sddm kept)"
  elif [[ -n "$DISPLAY_MANAGER" ]]; then
    echo "  display  : $DISPLAY_MANAGER"
  fi
  echo "  mode     : $mode"
  echo "  steps    : base=$DO_BASE terra=$DO_TERRA packages=$DO_PACKAGES configs=$DO_CONFIGS gtk=$DO_GTK cursor=$DO_CURSOR fisher=$DO_FISHER wallpapers=$DO_WALLPAPERS m3shapes=$DO_M3SHAPES solstice=$DO_SOLSTICE sddm=$DO_SDDM"
  echo ""

  if [[ "$DRY_RUN" == false ]]; then
    log_warn "user configs installed by install.sh are deleted (local changes included)"
    log_warn "config backups in ~/.config_backup_* stay untouched"
  fi
  confirm || { log_info "aborted"; exit 0; }

  if [[ "$DRY_RUN" == false && "$EUID" -ne 0 \
    && ( "$DO_BASE" == true || "$DO_TERRA" == true || "$DO_PACKAGES" == true \
      || "$DO_M3SHAPES" == true || "$DO_SDDM" == true ) ]]; then
    log_info "requesting sudo for the system steps…"
    if ! sudo -v; then
      log_err "sudo authentication failed"
      log_err "skip the system steps with: --keep-packages --no-m3shapes --no-sddm"
      exit 1
    fi
  fi

  if [[ "$DO_BASE" == true || "$DO_TERRA" == true || "$DO_PACKAGES" == true ]]; then
    unconfigure_dnf
  fi

  # Reverse order of install.sh: session first, packages last.
  if [[ "$DO_SOLSTICE" == true ]]; then uninstall_solstice; fi
  if [[ "$DO_SDDM" == true ]]; then uninstall_sddm; fi
  if [[ "$DO_CONFIGS" == true ]]; then uninstall_configs "$root"; fi
  if [[ "$DO_GTK" == true ]]; then uninstall_gtk; fi
  if [[ "$DO_CURSOR" == true ]]; then uninstall_cursor; fi
  if [[ "$DO_FISHER" == true ]]; then uninstall_fisher; fi
  if [[ "$DO_WALLPAPERS" == true ]]; then uninstall_wallpapers "$root"; fi
  if [[ "$DO_M3SHAPES" == true ]]; then uninstall_m3shapes; fi
  if [[ "$DO_PACKAGES" == true ]]; then uninstall_packages; fi
  if [[ "$DO_TERRA" == true ]]; then uninstall_terra; fi
  if [[ "$DO_BASE" == true ]]; then uninstall_base; fi

  echo ""
  if ((${#FAILURES[@]} > 0)); then
    log_err "some steps failed: ${FAILURES[*]}"
    exit 1
  fi
  log_ok "all done — the session, configs and packages were removed"
  local b
  for b in "$HOME"/.config_backup_*; do
    if [[ -e "$b" ]]; then
      log_info "backup left untouched: $b"
    fi
  done
  prompt_reboot
}

main "$@"
