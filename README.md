# Installer — dotfiles + jhqs

Installs [corzyy/dotfiles](https://github.com/corzyy/dotfiles) and
[corzyy/jhqs](https://github.com/corzyy/jhqs) (quickshell config) on
**Fedora** (Everything minimal install) and Arch/CachyOS (legacy path).
The OS is auto-detected via `/etc/os-release`, override with `--os=`.

Location in repo: `~/Documents/dotfiles/install.sh` (config: `~/Documents/dotfiles/Installer/packages.conf`)

## Quick start — Fedora Everything minimal

In the netinstaller pick **Minimal Install**, reboot, log in as root/user,
then:

```bash
sudo dnf install -y git
git clone https://github.com/corzyy/dotfiles.git ~/Documents/dotfiles
cd ~/Documents/dotfiles
chmod +x install.sh
./install.sh --dry-run   # preview
./install.sh             # real install (asks for confirmation)
./install.sh -y          # no prompt
```

Fresh-machine one-liner (same steps):

```bash
sudo dnf install -y git && git clone https://github.com/corzyy/dotfiles.git ~/Documents/dotfiles && ~/Documents/dotfiles/install.sh
```

## Quick start — Arch/CachyOS

```bash
sudo pacman -Sy git
git clone https://github.com/corzyy/dotfiles.git ~/Documents/dotfiles
~/Documents/dotfiles/install.sh --os=arch
```

## What it does (Fedora)

0. **Base tools** — installs what Everything-minimal lacks (`git`, `curl`,
   `rsync`, `dnf-plugins-core` for `dnf copr`, `xdg-user-dirs`,
   `accountsservice`). Skip with `--no-base`.
1. **Terra repo** — enables the third-party Terra repository, the
   upstream-documented Fedora source for `mangowm`
   (`dnf install --nogpgcheck --repofrompath 'terra,…' terra-release`).
   Skipped if `/etc/yum.repos.d/terra.repo` exists. Skip with `--no-terra`,
   disable permanently via `ENABLE_TERRA="false"` in `packages.conf`.
2. **Extra COPRs** — enables any repos listed in `COPR_REPOS`
   (`packages.conf`). Empty by default: `mangowm` needs no COPR, it lives
   in Terra. The `quickshell`/`matugen` COPRs are fallbacks and are only
   enabled on demand by the package step. Skip with `--no-copr`.
3. **Packages** (`FEDORA_PACKAGES` in `packages.conf`) — one `dnf install -y`
   transaction via `dnf5` (or `dnf`). Packages missing from every enabled
   repo never abort the install:
   - `quickshell` → auto-enables `errornointernet/quickshell` COPR and retries
   - `matugen` → auto-enables `solopasha/hyprland` COPR, then `cargo install matugen`
   - `nwg-look` → skipped with a manual-build hint (optional theming tool)
   - `mangowm`/`quickshell` still missing → hard error with a fix hint
4. **Configs** — copies `.config/*` from the repo root to `~/.config`
   (existing dirs are backed up to `~/.config_backup_<date>`, `wallpapers` excluded).
5. **Wallpapers** — copies `wallpapers/` to your Pictures folder, resolved via
   `xdg-user-dir PICTURES`, so it works regardless of system language
   (`~/Pictures`, `~/Bilder`, …). Result: `<Pictures>/wallpapers`.
   Legacy source `.config/wallpapers` is still accepted.
6. **jhqs** — clones/updates `https://github.com/corzyy/jhqs.git` to
   `~/.config/quickshell/jhqs`, makes `scripts/*.sh` executable and creates
   `~/.local/bin/jhqs -> /usr/bin/quickshell` (expected by mango autostart)
   plus `~/.local/bin/qs` if the package only ships `quickshell`.
7. **SDDM** — `sudo systemctl enable sddm.service -f` +
   `sudo systemctl set-default graphical.target` (minimal boots to
   multi-user otherwise) + `sudo systemctl start sddm.service`
   (skipped if already running). Verifies a `mango*.desktop` session entry
   exists in `/usr/share/wayland-sessions`. Then prompts to reboot.

On Arch the legacy path runs instead: CachyOS repos → `pacman` for official
repos, `paru` for AUR (unknown-to-pacman entries auto-fall-back to `paru`) →
same configs/wallpapers/jhqs/SDDM steps.

## Add programs later (dynamic)

Edit `packages.conf` — one name per line, no commas:

```bash
FEDORA_PACKAGES+=(
  neovim
  ghostty
)
```

```bash
PACMAN_PACKAGES+=(
  neovim
  ghostty
)
```

or for AUR-only stuff:

```bash
AUR_PACKAGES+=(
  my-aur-package
)
```

Extra COPRs (Fedora):

```bash
COPR_REPOS+=(
  owner/project
)
```

Then re-run `./install.sh --only-packages -y`.

## Useful flags

| Flag | Effect |
|---|---|
| `--dry-run` | print actions, change nothing |
| `--os=fedora\|arch\|auto` | force OS path (default: auto-detect) |
| `--only-base` / `--only-terra` / `--only-copr` | (Fedora) run one setup step |
| `--only-cachyos` / `--only-packages` / `--only-configs` / `--only-wallpapers` / `--only-jhqs` / `--only-sddm` | run one step |
| `--no-base` | (Fedora) skip bootstrap tools |
| `--no-terra` | (Fedora) skip Terra repo setup |
| `--no-copr` | (Fedora) skip extra COPR setup |
| `--no-cachyos` | (Arch) skip CachyOS repo setup |
| `--no-packages` | skip package install |
| `--no-configs` | skip .config copy |
| `--no-wallpapers` | skip wallpaper install |
| `--no-jhqs` | skip jhqs clone/update |
| `--no-sddm` | skip SDDM enable/start |
| `--no-reboot` | skip reboot prompt at the end |
| `--reboot` | reboot automatically at the end (no prompt) |
| `--no-backup` | overwrite without backup |
| `--link` | symlink `~/.config/*` to repo instead of copying (default `--copy`) |
| `-y` / `--yes` | skip confirm prompt |

## Layout expectations

```text
~/Documents/dotfiles/
  install.sh
  .config/btop, fastfetch, kitty, mango, …
  wallpapers/catppuccin, everforest, gruvbox, …
  Installer/packages.conf
  Installer/README.md
```

Anything you add under `.config/` is picked up automatically on the next
`./install.sh` (or `--only-configs`) run.

## Notes

- Fedora path uses `dnf5` when present, else `dnf`. `dnf-plugins-core` is
  installed as part of the base step so `dnf copr` works everywhere.
- MangoWM comes straight from Terra — no COPR needed (there is no
  official Fedora `mangowm` package).
- `matugen` templates in `~/.config/matugen` are installed like the rest.
- Mango autostart expects the `jhqs` launcher + `wallpaper-restore.sh`
  (both handled by the installer). The autostart entry uses `~`, so it
  works for any username on fresh installs.
- Minimal installs boot to `multi-user.target`; the installer switches the
  default to `graphical.target` and enables `NetworkManager` if needed.
