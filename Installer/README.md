# Installer — dotfiles + jhqs

Installs [corzyy/dotfiles](https://github.com/corzyy/dotfiles) and
[corzyy/jhqs](https://github.com/corzyy/jhqs) (quickshell config) on Arch/CachyOS.

Location in repo: `~/Documents/dotfiles/install.sh` (config: `~/Documents/dotfiles/Installer/packages.conf`)

## Quick start

```bash
cd ~/Documents/dotfiles
chmod +x install.sh
./install.sh --dry-run   # preview
./install.sh             # real install (asks for confirmation)
./install.sh -y          # no prompt
```

Fresh machine:

```bash
sudo pacman -Sy git
git clone https://github.com/corzyy/dotfiles.git ~/Documents/dotfiles
~/Documents/dotfiles/install.sh
```

## What it does

0. **CachyOS repos** — official bootstrap (`https://mirror.cachyos.org/cachyos-repo.tar.xz`
   + `cachyos-repo.sh --install`, CPU auto-detects v3/v4/znver4). Skipped automatically
   if `[cachyos]` is already in `/etc/pacman.conf`. Skip manually with `--no-cachyos`.
1. **Packages** (`packages.conf`) — `pacman` for official repos, `paru` for AUR.
   Unknown-to-pacman entries (e.g. `mangowm` on vanilla Arch) auto-fall-back to `paru`.
   Always includes `mangowm` + `sddm`.
2. **Configs** — copies `.config/*` from the repo root to `~/.config`
   (existing dirs are backed up to `~/.config_backup_<date>`, `wallpapers` excluded).
3. **Wallpapers** — copies `wallpapers/` to your Pictures folder, resolved via
   `xdg-user-dir PICTURES`, so it works regardless of system language
   (`~/Pictures`, `~/Bilder`, …). Result: `<Pictures>/wallpapers`.
   Legacy source `.config/wallpapers` is still accepted.
4. **jhqs** — clones/updates `https://github.com/corzyy/jhqs.git` to
   `~/.config/quickshell/jhqs`, makes `scripts/*.sh` executable and creates
   `~/.local/bin/jhqs -> /usr/bin/quickshell` (expected by mango autostart).
5. **SDDM** — `sudo systemctl enable sddm.service -f` + `sudo systemctl start sddm.service`
   (skipped if already running). Then prompts to reboot to finish the installation.

## Add programs later (dynamic)

Edit `packages.conf` — one name per line, no commas:

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

Then re-run `./install.sh --only-packages -y`.

## Useful flags

| Flag | Effect |
|---|---|
| `--dry-run` | print actions, change nothing |
| `--only-cachyos` / `--only-packages` / `--only-configs` / `--only-wallpapers` / `--only-jhqs` / `--only-sddm` | run one step |
| `--no-cachyos` | skip CachyOS repo setup |
| `--no-packages` | skip package install |
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

- Targets Arch/CachyOS (`pacman`). CachyOS repos auto-enabled on vanilla Arch,
  AUR installs use `paru` — auto-installed if missing.
- `matugen` templates in `~/.config/matugen` are **not** in this repo yet; if you add
  `.config/matugen` to the repo it will be installed like the rest.
- Mango autostart expects the `jhqs` launcher + `wallpaper-restore.sh`
  (both handled by the installer).
