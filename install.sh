#!/usr/bin/env bash
#
# Fedora installer for the corzyy dotfiles and the solstice Quickshell config.
#
# Installs this repository's configuration on a fresh Fedora system (for
# example the "Everything" netinstall with the Minimal profile) and brings up
# a working Umbriel + Quickshell (solstice) session:
#
#   1. base       bootstrap tools missing on a minimal install
#   2. terra      enable the Terra repository (umbriel, nerd fonts)
#   3. packages   install the set defined in Installer/packages.conf and
#                 verify every required package after installation
#   4. configs    copy .config/* into ~/.config (with backup)
#   5. gtk        apply adw-gtk3 to GTK applications
#   6. cursor     install + apply the bundled MacOS-Tahoe cursor
#   7. fisher     install/update the fish plugins listed in fish_plugins
#   8. wallpapers copy wallpapers/ into the XDG Pictures directory
#   9. m3shapes   build the M3Shapes QML module solstice imports (from source)
#  10. solstice   install/update the Quickshell config and the CLI launcher
#  11. sddm       enable SDDM + set graphical.target (started on reboot)
#
# Optional applications (APP_PACKAGES) are offered interactively by the
# packages step; --no-apps skips them.
#
# Usage: ./install.sh [options]     (see --help)

set -euo pipefail

DOTFILES_REPO="https://github.com/corzyy/dotfiles.git"
SOLSTICE_REPO="https://github.com/corzyy/solstice.git"
M3SHAPES_REPO="https://github.com/soramanew/m3shapes.git"
DOTFILES_DEFAULT_DIR="$HOME/Documents/dotfiles"
SOLSTICE_TARGET="$HOME/.config/quickshell/solstice"
M3SHAPES_SRC="$HOME/.local/share/m3shapes"
M3SHAPES_BUILD_DIR="$HOME/.cache/m3shapes-build"
BACKUP_DIR="$HOME/.config_backup_$(date +%Y%m%d_%H%M%S)"

# Desktop appearance defaults applied by the gtk/cursor steps.
GTK_THEME="adw-gtk3-dark"
CURSOR_THEME="MacOS-Tahoe-Cursor"
CURSOR_SIZE="24"

# When run as `curl … | bash` there is no script path. SCRIPT_DIR stays empty
# and the repository is cloned on demand in main().
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
DO_BASE=true
DO_TERRA=true
DO_PACKAGES=true
DO_APPS=true
DO_CONFIGS=true
DO_WALLPAPERS=true
DO_M3SHAPES=true
DO_SOLSTICE=true
DO_SDDM=true
DO_FISHER=true
DO_GTK=true
DO_CURSOR=true
DO_BACKUP=true
LINK_MODE=false
AUTO_REBOOT=false
NO_REBOOT_PROMPT=false
ONLY_MODE=false
NO_TERRA=false
APPS_DECIDED=false

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
Fedora installer for corzyy/dotfiles + corzyy/solstice

Usage: ./install.sh [options]

One-line install (clones the repo to ~/Documents/dotfiles if needed):

  curl -fsSL https://github.com/corzyy/dotfiles/raw/main/install.sh | bash

Pass options after `bash -s --`, e.g. `... | bash -s -- --dry-run`.

General:
  -y, --yes           skip the confirmation prompt
      --dry-run       print what would be done and change nothing
  -h, --help          show this help

Packages:
      --no-apps       do not install the optional APP_PACKAGES
      --apps          install the optional APP_PACKAGES without asking
                      (the packages step asks unless -y/--apps is given)

File handling:
      --copy          copy configs into ~/.config (default)
      --link          symlink ~/.config entries to this repository
      --no-backup     overwrite existing configs without backing them up

Steps (skip with --no-<step>, run only these with --only-<step>):
  base, terra, packages, configs, gtk, cursor, fisher, wallpapers, m3shapes,
  solstice, sddm

Reboot:
      --no-reboot     do not ask to reboot at the end
      --reboot        reboot automatically when finished

Environment:
  SOLSTICE_REPO   git remote to install solstice from (default: corzyy/solstice)
  SOLSTICE_REF    branch/tag to install (default: main)
  SOLSTICE_LOCAL  install from a local solstice checkout instead of cloning
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

# Locate packages.conf. The repo ships it in Installer/, but tolerate a flat
# layout and a `curl … | bash` run where only the clone dir is known.
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
  # Nothing found yet — return the canonical location for the error message.
  printf '%s' "${REPO_ROOT:-$DOTFILES_DEFAULT_DIR}/Installer/packages.conf"
}

# `curl … | bash`: clone or update the repository when needed. A local copy
# counts as usable only when it also contains a packages file, so a stale or
# half-finished checkout is refreshed instead of used.
bootstrap_repo() {
  local root="$1"
  if [[ ( -d "$root/.config" || -d "$root/wallpapers" ) \
    && ( -f "$root/Installer/packages.conf" || -f "$root/packages.conf" ) ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    if [[ -d "$root/.git" ]]; then
      printf '[dry-run] git -C %s pull --ff-only\n' "$root"
    else
      printf '[dry-run] git clone %s %s\n' "$DOTFILES_REPO" "$root"
    fi
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    log_info "git not found — installing it first"
    run_root "$DNF" install -y git
  fi
  if [[ -d "$root/.git" ]]; then
    log_info "updating existing checkout in $root"
    run git -C "$root" pull --ff-only || log_warn "could not update $root — continuing"
    return 0
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

# Create/refresh the localized XDG user directories (Pictures, Documents, …)
# and ~/.config/user-dirs.dirs. Without this a Minimal install has no Pictures
# dir, so wallpapers would land in the fallback ~/Pictures even on a localized
# system.
ensure_xdg_dirs() {
  if ! command -v xdg-user-dirs-update >/dev/null 2>&1; then
    log_info "xdg-user-dirs-update not available — skipping"
    return 0
  fi
  log_info "creating/updating XDG user directories"
  run xdg-user-dirs-update
  log_ok "XDG user directories ready (Pictures: $(pictures_dir))"
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

pkg_installed() { rpm -q --quiet "$1"; }
pkg_available() { "$DNF" list --available --quiet "$1" >/dev/null 2>&1; }

# Display managers other than SDDM. When one of these is installed, SDDM is
# neither installed nor enabled: the existing manager keeps launching the
# Umbriel session, because /usr/share/wayland-sessions is shared.
OTHER_DMS=(gdm lightdm lxdm ly greetd xdm)

# Sets DISPLAY_MANAGER to the first installed display manager ("" if none).
# Preferred over sddm, so a system with several DMs keeps its current one.
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

# Bail out of the run when any of these are missing afterwards: without them
# neither the Umbriel session nor the solstice shell can start.
CRITICAL_PACKAGES=(umbriel-nightly quickshell sddm)

# Print the packages from the given list that are not installed, one per line.
missing_from() {
  local p
  for p in "$@"; do
    pkg_installed "$p" || printf '%s\n' "$p"
  done
}

ensure_base() {
  load_packages
  local pkgs=() missing=() still=() p
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
  if [[ "$DRY_RUN" == true ]]; then
    log_ok "base tools (dry-run)"
    return 0
  fi

  mapfile -t still < <(missing_from "${pkgs[@]}")
  if ((${#still[@]} > 0)); then
    log_err "base tools still missing after install: ${still[*]}"
    return 1
  fi
  log_ok "base tools done (verified ${#pkgs[@]})"
}

# Ask before installing the optional APP_PACKAGES. Skipped when the caller
# already decided (--apps/--no-apps) or asked for a non-interactive run.
ask_apps() {
  local list="$1"
  if [[ "$APPS_DECIDED" == true ]]; then return 0; fi
  APPS_DECIDED=true
  if [[ "$ASSUME_YES" == true ]]; then
    log_info "installing optional apps (-y): $list"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] prompt: install optional applications? [Y/n] (%s)\n' "$list"
    return 0
  fi
  log_info "optional applications: $list"
  local reply
  reply="$(ask "Install these optional applications? [Y/n] ")"
  [[ -z "$reply" || "$reply" =~ ^[YyJj]$ ]]
}

# Make dnf assume "yes" by default so any interactive invocation (and steps
# not passing -y) do not stop on the "Is this ok?" prompt.
configure_dnf() {
  log_info "configuring dnf: defaultyes=True"
  run_root "$DNF" config-manager setopt defaultyes=True \
    || log_warn "could not set dnf defaultyes — continuing"
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
  log_info "enabling the Terra repository (provides umbriel-nightly and nerd fonts)…"
  run_root "$DNF" install -y --nogpgcheck \
    --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
    terra-release terra-gpg-keys
  if [[ "$DRY_RUN" == false && ! -f /etc/yum.repos.d/terra.repo ]]; then
    log_err "Terra repo file was not created — required packages may be unavailable"
    return 1
  fi
  log_ok "Terra repository enabled"
}

# Partition a package list into already-installed / installable / unavailable
# and install what is missing. Sets REPLY_MISSING to the unavailable names so a
# single unknown package (e.g. an older Fedora release) cannot abort the run.
REPLY_MISSING=()
install_pkg_list() {
  local label="$1"; shift
  local pkgs=("$@")
  REPLY_MISSING=()
  if ((${#pkgs[@]} == 0)); then
    return 0
  fi

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
    log_info "installing ${#to_install[@]} $label: ${to_install[*]}"
    run_root "$DNF" install -y "${to_install[@]}"
  fi
  REPLY_MISSING=(${missing[@]+"${missing[@]}"})
}

install_packages() {
  load_packages
  # umbriel-nightly and the nerd fonts come from Terra, so make sure it is
  # enabled before resolving/installing the package set (covers --only-packages).
  if [[ "$NO_TERRA" == false ]]; then
    ensure_terra
  fi

  # Terra was just added: refresh metadata as root so the availability checks
  # below (which may run unprivileged) actually see packages like umbriel-nightly.
  log_info "refreshing package metadata…"
  run_root "$DNF" makecache || log_warn "could not refresh metadata — continuing"

  local required=() apps=() skip_sddm=false
  dedupe_into required ${PACKAGES[@]+"${PACKAGES[@]}"}
  if ((${#required[@]} == 0)); then
    log_info "no packages configured"
    return 0
  fi

  if sddm_skipped; then
    log_info "display manager already installed: $DISPLAY_MANAGER — skipping sddm"
    skip_sddm=true
    remove_pkg_from required sddm
  fi

  if [[ "$DO_APPS" == true ]]; then
    dedupe_into apps ${APP_PACKAGES[@]+"${APP_PACKAGES[@]}"}
    if ((${#apps[@]} > 0)) && ! ask_apps "${apps[*]}"; then
      log_info "optional applications skipped"
      apps=()
    fi
  else
    log_info "optional applications skipped (--no-apps)"
  fi

  install_pkg_list "required packages" "${required[@]}"
  if ((${#REPLY_MISSING[@]} > 0)); then
    log_warn "required packages not available in the enabled repositories: ${REPLY_MISSING[*]}"
  fi

  if ((${#apps[@]} > 0)); then
    install_pkg_list "optional apps" "${apps[@]}"
    if ((${#REPLY_MISSING[@]} > 0)); then
      log_warn "optional apps not available in the enabled repositories: ${REPLY_MISSING[*]}"
    fi
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log_ok "packages (dry-run)"
    return 0
  fi

  # Critical packages must be present even if the metadata was stale — retry a
  # direct install before giving up. sddm is not critical when another DM runs.
  local critical=() c item
  for c in "${CRITICAL_PACKAGES[@]}"; do
    [[ "$skip_sddm" == true && "$c" == "sddm" ]] && continue
    critical+=("$c")
  done
  for item in "${critical[@]}"; do
    if ! pkg_installed "$item"; then
      log_warn "required package not resolved from metadata — retrying directly: $item"
      if ! run_root "$DNF" install -y "$item"; then
        log_err "required package is missing: $item"
        log_err "check the Terra repo, then re-run: ./install.sh --only-packages -y"
        return 1
      fi
    fi
  done

  # Verify every required package actually landed; do not trust dnf alone.
  local still=() summary="packages done (verified ${#required[@]} required"
  mapfile -t still < <(missing_from "${required[@]}")
  if ((${#still[@]} > 0)); then
    log_err "required packages missing after install: ${still[*]}"
    log_err "re-run after fixing the repositories: ./install.sh --only-packages -y"
    return 1
  fi
  if ((${#apps[@]} > 0)); then
    mapfile -t still < <(missing_from "${apps[@]}")
    if ((${#still[@]} > 0)); then
      log_warn "optional apps missing after install: ${still[*]}"
    fi
    summary+=", ${#apps[@]} optional"
  fi
  log_ok "$summary)"
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
  for f in "$HOME/.config/umbriel/wallpaper-restore.sh" "$HOME/.config/matugen/post-hook-scripts"/*.sh; do
    if [[ -f "$f" ]]; then
      run chmod +x "$f"
    fi
  done
}

# Files the session/shell actually reads; a configs step that fails to install
# one of these leaves solstice without colors, wallpapers or a terminal theme.
verify_configs() {
  local missing=() f
  local required=(
    ".config/umbriel/config.toml"
    ".config/umbriel/wallpaper-restore.sh"
    ".config/matugen/config.toml"
    ".config/matugen/templates/quickshell-colors.json"
    ".config/matugen/templates/umbriel-colors.toml"
    ".config/matugen/templates/helium-theme.json"
    ".config/kitty/kitty.conf"
    ".config/fish/config.fish"
  )
  for f in "${required[@]}"; do
    [[ -e "$HOME/$f" ]] || missing+=("$f")
  done
  if ((${#missing[@]} > 0)); then
    log_err "configs missing after install: ${missing[*]}"
    return 1
  fi
  log_ok "configs verified (${#required[@]} files)"
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
  if [[ "$DRY_RUN" == false ]]; then
    verify_configs || return 1
  fi
  log_ok "configs done"
}

# ------------------------------------------------------------------ gtk ---
# Write a file only when its content differs, so re-running stays quiet.
write_if_changed() {
  local path="$1" content="$2"
  if [[ -f "$path" && "$(cat "$path")" == "$content" ]]; then
    log_ok "already up to date: ${path/#$HOME/\~}"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] write %s\n' "$path"
    return 0
  fi
  run mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  log_ok "wrote ${path/#$HOME/\~}"
}

# Write the GTK settings (theme + cursor) for GTK3 and GTK4 apps, and hook in
# the matugen palette so GTK follows the wallpaper theme.
write_gtk_settings() {
  write_if_changed "$HOME/.config/gtk-3.0/settings.ini" "[Settings]
gtk-theme-name=$GTK_THEME
gtk-application-prefer-dark-theme=1
gtk-cursor-theme-name=$CURSOR_THEME
gtk-cursor-theme-size=$CURSOR_SIZE"
  write_if_changed "$HOME/.config/gtk-4.0/settings.ini" "[Settings]
gtk-application-prefer-dark-theme=1
gtk-cursor-theme-name=$CURSOR_THEME
gtk-cursor-theme-size=$CURSOR_SIZE"
  write_gtk_css
}

# gtk.css imports the matugen-generated colors.css, which is what actually
# applies the wallpaper palette to GTK apps. Seed an empty colors.css so the
# import resolves before matugen has run for the first time.
write_gtk_css() {
  local dir css
  write_if_changed "$HOME/.config/gtk-3.0/gtk.css" '@import url("colors.css");'
  write_if_changed "$HOME/.config/gtk-4.0/gtk.css" '@import url("colors.css");'
  for dir in gtk-3.0 gtk-4.0; do
    css="$HOME/.config/$dir/colors.css"
    if [[ ! -f "$css" ]]; then
      run mkdir -p "$(dirname "$css")"
      run touch "$css"
      log_ok "seeded ${css/#$HOME/\~} (matugen overwrites it)"
    fi
  done
}

# Apply adw-gtk3 to GTK3 apps. On wlroots/umbriel there is no XSettings daemon,
# so the theme must be set in gtk-3.0/settings.ini; gsettings alone only
# reaches apps that go through a settings portal.
apply_gtk_theme() {
  if [[ "$DRY_RUN" == false ]] && ! rpm -q adw-gtk3-theme >/dev/null 2>&1; then
    log_warn "adw-gtk3-theme is not installed — skipping GTK theme setup"
    return 0
  fi
  log_info "applying $GTK_THEME to GTK applications"
  write_gtk_settings
  if command -v gsettings >/dev/null 2>&1; then
    run gsettings set org.gnome.desktop.interface gtk-theme "$GTK_THEME" \
      || log_warn "could not set gtk-theme via gsettings — continuing"
    run gsettings set org.gnome.desktop.interface color-scheme prefer-dark \
      || log_warn "could not set color-scheme via gsettings — continuing"
  fi
  if [[ "$DRY_RUN" == false && ! -f "$HOME/.config/gtk-3.0/settings.ini" ]]; then
    log_err "GTK settings.ini was not written"
    return 1
  fi
  log_ok "GTK theme applied"
}

# Install the bundled cursor theme and make it the session default. solstice
# reads the theme from theming_settings.json; gsettings, settings.ini and the
# environment.d file cover GTK/Qt apps and the rest of the session.
apply_cursor_theme() {
  local src="$REPO_ROOT/.local/share/icons/$CURSOR_THEME"
  local dest="$HOME/.local/share/icons/$CURSOR_THEME"
  local installed=false
  if [[ -d "$src" ]]; then
    log_info "installing cursor theme: $CURSOR_THEME"
    run mkdir -p "$HOME/.local/share/icons"
    if command -v rsync >/dev/null 2>&1; then
      run rsync -a "$src/" "$dest/"
    else
      run cp -a "$src" "$HOME/.local/share/icons/"
    fi
    installed=true
  else
    log_warn "cursor theme not found in the repository: $src (skipping files)"
  fi

  if command -v gsettings >/dev/null 2>&1; then
    run gsettings set org.gnome.desktop.interface cursor-theme "$CURSOR_THEME" \
      || log_warn "could not set cursor-theme via gsettings — continuing"
    run gsettings set org.gnome.desktop.interface cursor-size "$CURSOR_SIZE" \
      || log_warn "could not set cursor-size via gsettings — continuing"
  fi

  write_gtk_settings
  write_if_changed "$HOME/.config/environment.d/cursor.conf" \
    "XCURSOR_THEME=$CURSOR_THEME
XCURSOR_SIZE=$CURSOR_SIZE"
  if [[ "$DRY_RUN" == false && "$installed" == true && ! -f "$dest/index.theme" ]]; then
    log_err "cursor theme not installed: $dest/index.theme missing"
    return 1
  fi
  log_ok "cursor theme applied"
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
  if [[ "$DRY_RUN" == false ]]; then
    local count=0
    count="$(find "$dest" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | wc -l)"
    if ((count == 0)); then
      log_warn "no wallpapers found in $dest after copy — the shell will show a black background"
    else
      log_ok "wallpapers verified ($count files)"
    fi
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
  if ! run fish -c 'fisher update'; then
    log_warn "some fish plugins could not be installed/updated — continuing"
    return 0
  fi
  if [[ "$DRY_RUN" == false && ! -f "$HOME/.config/fish/functions/fisher.fish" ]]; then
    log_err "fisher is missing after install"
    return 1
  fi
  log_ok "fish plugins done"
}

# ------------------------------------------------------------- m3shapes ---
# solstice's bar widgets import the M3Shapes QML module
# (github.com/soramanew/m3shapes), which no repository packages — build it
# from source and install it system-wide so the QML engine finds it under
# <libdir>/qt6/qml. Build dependencies come from M3SHAPES_PACKAGES.
M3SHAPES_QML_DIR=""
m3shapes_qml_dir() {
  if [[ -z "$M3SHAPES_QML_DIR" ]]; then
    M3SHAPES_QML_DIR="$(rpm --eval '%{_libdir}')/qt6/qml/M3Shapes"
  fi
  printf '%s' "$M3SHAPES_QML_DIR"
}

verify_m3shapes() {
  local qml_dir lib_dir missing=() f
  qml_dir="$(m3shapes_qml_dir)"
  lib_dir="$(rpm --eval '%{_libdir}')"
  local required=("$qml_dir/libm3shapesplugin.so" "$qml_dir/qmldir" "$lib_dir/libm3shapes.so")
  for f in "${required[@]}"; do
    [[ -e "$f" ]] || missing+=("$f")
  done
  if ((${#missing[@]} > 0)); then
    log_err "m3shapes install incomplete — missing: ${missing[*]}"
    return 1
  fi
  log_ok "m3shapes verified: $qml_dir"
}

# Fedora package that ships a CMake package config, so a failed configure can
# name the package to install instead of only CMake's "Missing: X_DIR".
cmake_dir_package() {
  case "$1" in
    Qt6Core_DIR | Qt6Gui_DIR) printf 'qt6-qtbase-devel' ;;
    Qt6Qml_DIR | Qt6Quick_DIR) printf 'qt6-qtdeclarative-devel' ;;
    Qt6ShaderTools_DIR) printf 'qt6-qtshadertools-devel' ;;
    *) printf '' ;;
  esac
}

# Extract the CMake package dirs a failed configure could not find, across the
# error shapes CMake/Qt use: "(missing: Qt6ShaderTools_DIR)", "Failed to find
# Qt component "ShaderTools"" and ".../Qt6ShaderToolsConfig.cmake does not
# exist".
m3shapes_missing_dirs() {
  local log="$1"
  {
    grep -oiE 'missing: [A-Za-z0-9_]+_DIR' "$log" 2>/dev/null | cut -d' ' -f2
    grep -oE 'Qt component "[A-Za-z0-9]+"' "$log" 2>/dev/null \
      | sed -E 's/Qt component "([A-Za-z0-9]+)"/Qt6\1_DIR/'
    grep -oE 'Qt6[A-Za-z0-9]+Config\.cmake' "$log" 2>/dev/null | sed 's/Config\.cmake/_DIR/'
  } | sort -u
}

# Configure the m3shapes build, mapping a missing CMake package to its Fedora
# package. Output goes to a log so the error path can point at the cause.
configure_m3shapes() {
  local log="$M3SHAPES_BUILD_DIR/configure.log"
  if [[ "$DRY_RUN" == true ]]; then
    run cmake -S "$M3SHAPES_SRC" -B "$M3SHAPES_BUILD_DIR" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
    return 0
  fi
  run mkdir -p "$M3SHAPES_BUILD_DIR"
  if cmake -S "$M3SHAPES_SRC" -B "$M3SHAPES_BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr >"$log" 2>&1; then
    return 0
  fi

  log_err "m3shapes cmake configure failed (log: $log)"
  local dir pkg found=false
  while IFS= read -r dir; do
    pkg="$(cmake_dir_package "$dir")"
    if [[ -n "$pkg" ]]; then
      log_err "missing $dir — Fedora package: $pkg"
      log_err "install it and re-run: ./install.sh --only-m3shapes -y"
      found=true
      break
    fi
  done < <(m3shapes_missing_dirs "$log")
  if [[ "$found" == false ]]; then
    grep -iE 'CMake Error|missing:' "$log" 2>/dev/null | head -5 >&2 || true
    log_err "see the full log: $log"
  fi
  return 1
}

ensure_m3shapes_deps() {
  load_packages
  local pkgs=() still=()
  dedupe_into pkgs ${M3SHAPES_PACKAGES[@]+"${M3SHAPES_PACKAGES[@]}"}
  if ((${#pkgs[@]} == 0)); then
    log_warn "no M3SHAPES_PACKAGES configured — build may fail"
    return 0
  fi
  install_pkg_list "m3shapes build dependencies" "${pkgs[@]}"
  if ((${#REPLY_MISSING[@]} > 0)); then
    log_warn "m3shapes build dependencies not available: ${REPLY_MISSING[*]}"
  fi
  if [[ "$DRY_RUN" == false ]]; then
    mapfile -t still < <(missing_from "${pkgs[@]}")
    if ((${#still[@]} > 0)); then
      log_err "m3shapes build dependencies missing: ${still[*]}"
      return 1
    fi
  fi
}

install_m3shapes() {
  ensure_m3shapes_deps || return 1

  if [[ "$DRY_RUN" == true ]]; then
    run git clone --depth 1 "$M3SHAPES_REPO" "$M3SHAPES_SRC"
    configure_m3shapes
    run cmake --build "$M3SHAPES_BUILD_DIR"
    run_root cmake --install "$M3SHAPES_BUILD_DIR"
    return 0
  fi

  if ! command -v git >/dev/null 2>&1 \
    || ! command -v cmake >/dev/null 2>&1 \
    || ! command -v ninja >/dev/null 2>&1; then
    log_err "git, cmake and ninja are required to build m3shapes"
    return 1
  fi

  # User-owned checkout for updates; build out-of-tree in the cache dir.
  if [[ -d "$M3SHAPES_SRC/.git" ]]; then
    if [[ -n "$(git -C "$M3SHAPES_SRC" status --porcelain 2>/dev/null)" ]]; then
      log_warn "m3shapes checkout has local changes — not pulling automatically"
    else
      run git -C "$M3SHAPES_SRC" pull --ff-only \
        || log_warn "could not update m3shapes — using the existing checkout"
    fi
  elif [[ -e "$M3SHAPES_SRC" ]]; then
    log_err "$M3SHAPES_SRC exists but is not a git checkout — remove it and re-run"
    return 1
  else
    run git clone --depth 1 "$M3SHAPES_REPO" "$M3SHAPES_SRC"
  fi

  local head stamp qml_dir lib_dir
  head="$(git -C "$M3SHAPES_SRC" rev-parse HEAD 2>/dev/null || true)"
  stamp="$M3SHAPES_BUILD_DIR/.built-revision"
  qml_dir="$(m3shapes_qml_dir)"
  lib_dir="$(rpm --eval '%{_libdir}')"
  if [[ -n "$head" && -f "$stamp" && "$(cat "$stamp")" == "$head" \
    && -e "$qml_dir/libm3shapesplugin.so" && -e "$lib_dir/libm3shapes.so" ]]; then
    log_ok "m3shapes already built at ${head:0:12}"
    return 0
  fi

  log_info "building m3shapes ($head)…"
  configure_m3shapes || return 1
  run cmake --build "$M3SHAPES_BUILD_DIR"
  log_info "installing m3shapes system-wide (sudo)…"
  run_root cmake --install "$M3SHAPES_BUILD_DIR"
  mkdir -p "$M3SHAPES_BUILD_DIR"
  printf '%s\n' "$head" > "$stamp"

  verify_m3shapes
}

# ------------------------------------------------------------- solstice ---
# solstice ships its own installer (clone, keep backend/config + snapshots,
# atomic swap, ~/.local/bin/solstice CLI). Use it instead of a plain git
# checkout so updates keep the user's settings.
#
# The current dotfiles configs target the backend/shell/style layout. The
# GitHub repo is cloned by default; point SOLSTICE_LOCAL at a local checkout
# (or push it) when the repository is behind.
verify_solstice() {
  local missing=() f
  local required=(
    "shell.qml"
    "backend/scripts/solstice"
    "backend/services/InstanceGuard.qml"
    "style/themes/Theme.qml"
  )
  for f in "${required[@]}"; do
    [[ -e "$SOLSTICE_TARGET/$f" ]] || missing+=("$f")
  done
  if ((${#missing[@]} > 0)); then
    log_err "installed solstice does not have the backend/shell/style layout (missing: ${missing[*]})"
    log_err "the GitHub repo may be older than this dotfiles checkout — push solstice,"
    log_err "or re-run with SOLSTICE_LOCAL=/path/to/solstice"
    return 1
  fi
  if [[ ! -L "$HOME/.local/bin/solstice" && ! -x "$HOME/.local/bin/solstice" ]]; then
    log_err "solstice CLI missing: ~/.local/bin/solstice (keybinds/autostart use it)"
    return 1
  fi
  if ! command -v quickshell >/dev/null 2>&1 && [[ ! -x /usr/bin/quickshell ]]; then
    log_err "quickshell not found — install the packages step first"
    return 1
  fi
  if [[ ! -e "$(m3shapes_qml_dir)/libm3shapesplugin.so" ]]; then
    log_warn "M3Shapes QML module not found in $(m3shapes_qml_dir) — the solstice bar needs it"
    log_warn "run: ./install.sh --only-m3shapes -y"
  fi
  log_ok "solstice verified: $SOLSTICE_TARGET (shell.qml + solstice CLI)"
}

# Keybinds and the Umbriel autostart call `solstice` through ~/.local/bin, so
# refresh that symlink after both the git-checkout and installer paths.
ensure_solstice_cli() {
  local cli="$SOLSTICE_TARGET/backend/scripts/solstice"
  [[ -x "$cli" ]] || return 0
  run mkdir -p "$HOME/.local/bin"
  if [[ -L "$HOME/.local/bin/solstice" ]]; then
    run ln -sfn "$cli" "$HOME/.local/bin/solstice"
  elif [[ -e "$HOME/.local/bin/solstice" ]]; then
    log_warn "~/.local/bin/solstice exists and is not a symlink — leaving it"
  else
    run ln -s "$cli" "$HOME/.local/bin/solstice"
    log_ok "created ~/.local/bin/solstice -> $cli"
  fi
}

install_solstice() {
  local dest="$SOLSTICE_TARGET"

  # A git checkout is the user's source of truth (possibly with local changes)
  # and must keep its .git, so update it in place instead of swapping it out.
  if [[ -d "$dest/.git" && -f "$dest/install.sh" ]]; then
    log_info "existing solstice checkout: $dest"
    if [[ -n "$(git -C "$dest" status --porcelain 2>/dev/null)" ]]; then
      log_warn "solstice has local changes — not pulling automatically"
    else
      run git -C "$dest" pull --ff-only \
        || log_warn "could not update solstice — keeping the existing checkout"
    fi
    ensure_solstice_cli
    if [[ "$DRY_RUN" == false ]]; then
      verify_solstice || return 1
    fi
    return 0
  fi

  if ! command -v git >/dev/null 2>&1; then
    log_err "git is required to install solstice"
    return 1
  fi

  # Staging source, cleaned up on script exit.
  SOLSTICE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/solstice-src.XXXXXX")"
  trap 'rm -rf "${SOLSTICE_TMP:-}"' EXIT
  local src="$SOLSTICE_TMP"

  if [[ -n "${SOLSTICE_LOCAL:-}" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      printf '[dry-run] copy %s (without .git) and run: bash <tmp>/install.sh -y --no-start\n' "$SOLSTICE_LOCAL"
      return 0
    fi
    if [[ ! -f "$SOLSTICE_LOCAL/shell.qml" || ! -f "$SOLSTICE_LOCAL/install.sh" ]]; then
      log_err "SOLSTICE_LOCAL=$SOLSTICE_LOCAL is not a solstice checkout"
      return 1
    fi
    log_info "installing solstice from local checkout: $SOLSTICE_LOCAL"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --exclude .git "$SOLSTICE_LOCAL/" "$src/" || return 1
    else
      cp -a "$SOLSTICE_LOCAL/." "$src/" && rm -rf "$src/.git"
    fi
  else
    local ref="${SOLSTICE_REF:-main}"
    if [[ "$DRY_RUN" == true ]]; then
      printf '[dry-run] git clone --depth 1 --branch %s %s <tmp> && bash <tmp>/install.sh -y --no-start\n' "$ref" "$SOLSTICE_REPO"
      return 0
    fi
    log_info "cloning $SOLSTICE_REPO ($ref)"
    if ! git clone --depth 1 --branch "$ref" "$SOLSTICE_REPO" "$src" >/dev/null 2>&1; then
      log_err "could not clone solstice — check the network and $SOLSTICE_REPO"
      return 1
    fi
    if [[ ! -f "$src/shell.qml" || ! -f "$src/install.sh" ]]; then
      log_err "solstice checkout looks invalid (shell.qml/install.sh missing)"
      return 1
    fi
  fi

  log_info "installing solstice (keeping backend/config and theme snapshots)…"
  if ! SOLSTICE_SRC="$src" bash "$src/install.sh" -y --no-start; then
    log_err "solstice installer failed"
    return 1
  fi
  ensure_solstice_cli
  verify_solstice
}

# ----------------------------------------------------------------- sddm ---
verify_umbriel_session() {
  local sessions=(/usr/share/wayland-sessions/*umbriel*.desktop)
  if [[ -e "${sessions[0]}" ]]; then
    log_ok "umbriel session found: $(basename "${sessions[0]}")"
  else
    log_warn "no umbriel session in /usr/share/wayland-sessions — install umbriel-nightly first"
  fi
}

ensure_sddm() {
  if sddm_skipped; then
    log_info "display manager already installed: $DISPLAY_MANAGER — not touching SDDM"
    verify_umbriel_session
    return 0
  fi
  if ! pkg_installed sddm; then
    log_err "sddm is not installed — run the packages step first"
    return 1
  fi
  if ! pkg_installed umbriel-nightly; then
    log_warn "umbriel-nightly is not installed — SDDM will have no Umbriel session yet"
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

  # Deliberately not started here — the installer asks to reboot at the end
  # and SDDM comes up then.
  verify_umbriel_session
  log_ok "sddm enabled and set as the default (starts on reboot)"
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
    log_info "reboot skipped — reboot manually to reach the Umbriel session"
  fi
}

disable_all_steps() {
  DO_BASE=false; DO_TERRA=false; DO_PACKAGES=false; DO_CONFIGS=false
  DO_WALLPAPERS=false; DO_SOLSTICE=false; DO_SDDM=false; DO_FISHER=false
  DO_GTK=false; DO_CURSOR=false; DO_M3SHAPES=false
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
      --apps) DO_APPS=true; APPS_DECIDED=true ;;
      --no-apps) DO_APPS=false; APPS_DECIDED=true ;;
      --only-base) only_step DO_BASE ;;
      --only-terra) only_step DO_TERRA ;;
      --only-packages) only_step DO_PACKAGES ;;
      --only-configs) only_step DO_CONFIGS ;;
      --only-fisher) only_step DO_FISHER ;;
      --only-gtk) only_step DO_GTK ;;
      --only-cursor) only_step DO_CURSOR ;;
      --only-wallpapers) only_step DO_WALLPAPERS ;;
      --only-m3shapes) only_step DO_M3SHAPES ;;
      --only-solstice) only_step DO_SOLSTICE ;;
      --only-sddm) only_step DO_SDDM ;;
      --no-base) DO_BASE=false ;;
      --no-terra) DO_TERRA=false; NO_TERRA=true ;;
      --no-packages) DO_PACKAGES=false ;;
      --no-configs) DO_CONFIGS=false ;;
      --no-fisher) DO_FISHER=false ;;
      --no-gtk) DO_GTK=false ;;
      --no-cursor) DO_CURSOR=false ;;
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

  require_fedora
  DNF="$(detect_dnf)"
  detect_display_manager

  if [[ "$EUID" -eq 0 ]]; then
    log_warn "running as root — user configs go to $HOME; prefer running as your normal user"
  fi

  local root
  root="$(resolve_root)"
  REPO_ROOT="$root"
  PACKAGES_FILE="$(resolve_packages_file)"

  local mode backup_state
  [[ "$LINK_MODE" == true ]] && mode="symlink" || mode="copy"
  [[ "$DO_BACKUP" == true ]] && backup_state="yes" || backup_state="no"

  echo "${C_BOLD}Fedora dotfiles installer${C_RESET}"
  echo "  dotfiles : $root"
  echo "  packages : $PACKAGES_FILE"
  echo "  dnf      : $DNF"
  if sddm_skipped; then
    echo "  display  : $DISPLAY_MANAGER (sddm skipped)"
  elif [[ -n "$DISPLAY_MANAGER" ]]; then
    echo "  display  : $DISPLAY_MANAGER"
  fi
  echo "  mode     : $mode (backup: $backup_state)"
  echo "  steps    : base=$DO_BASE terra=$DO_TERRA packages=$DO_PACKAGES apps=$DO_APPS configs=$DO_CONFIGS fisher=$DO_FISHER gtk=$DO_GTK cursor=$DO_CURSOR wallpapers=$DO_WALLPAPERS m3shapes=$DO_M3SHAPES solstice=$DO_SOLSTICE sddm=$DO_SDDM"
  echo ""

  confirm || { log_info "aborted"; exit 0; }

  if [[ "$DRY_RUN" == false && "$EUID" -ne 0 \
    && ("$DO_BASE" == true || "$DO_TERRA" == true || "$DO_PACKAGES" == true \
      || "$DO_M3SHAPES" == true || "$DO_SDDM" == true) ]]; then
    log_info "requesting sudo for the system steps…"
    if ! sudo -v; then
      log_err "sudo authentication failed"
      log_err "skip the system steps with: --no-base --no-terra --no-packages --no-m3shapes --no-sddm"
      exit 1
    fi
  fi

  if [[ "$DO_BASE" == true || "$DO_TERRA" == true || "$DO_PACKAGES" == true ]]; then
    configure_dnf
  fi

  bootstrap_repo "$root"
  # Re-resolve now that the repository may have just been cloned.
  PACKAGES_FILE="$(resolve_packages_file)"
  if [[ "$DRY_RUN" == true ]] && { [[ ! -d "$root/.config" && ! -d "$root/wallpapers" ]] || [[ ! -f "$PACKAGES_FILE" ]]; }; then
    log_warn "preview: repository/packages.conf not available — showing the clone/update step only"
    DO_BASE=false; DO_TERRA=false; DO_PACKAGES=false
    DO_CONFIGS=false; DO_FISHER=false; DO_WALLPAPERS=false
  fi

  if [[ "$DO_BASE" == true ]]; then ensure_base; fi
  if [[ "$DO_CONFIGS" == true || "$DO_WALLPAPERS" == true ]]; then ensure_xdg_dirs; fi
  # When the package step runs it enables Terra itself (see install_packages),
  # so only run the standalone Terra step if packages are skipped.
  if [[ "$DO_TERRA" == true && "$DO_PACKAGES" == false ]]; then ensure_terra; fi
  if [[ "$DO_PACKAGES" == true ]]; then install_packages; fi
  if [[ "$DO_CONFIGS" == true ]]; then install_configs "$root"; fi
  if [[ "$DO_GTK" == true ]]; then apply_gtk_theme; fi
  if [[ "$DO_CURSOR" == true ]]; then apply_cursor_theme; fi
  if [[ "$DO_FISHER" == true ]]; then install_fish_plugins; fi
  if [[ "$DO_WALLPAPERS" == true ]]; then install_wallpapers "$root"; fi
  if [[ "$DO_M3SHAPES" == true ]]; then install_m3shapes; fi
  if [[ "$DO_SOLSTICE" == true ]]; then install_solstice; fi
  if [[ "$DO_SDDM" == true ]]; then ensure_sddm; fi

  echo ""
  log_ok "all done — reboot, log in to the Umbriel session; solstice starts automatically"
  log_info "manage the shell with: solstice start | solstice reload | solstice lock"
  if [[ "$DO_BACKUP" == true && -d "$BACKUP_DIR" ]]; then
    log_info "backups (if any) are in: $BACKUP_DIR"
  fi
  prompt_reboot
}

main "$@"
