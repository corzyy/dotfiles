# Installer — dotfiles + jhqs (Fedora)

Installs [corzyy/dotfiles](https://github.com/corzyy/dotfiles) and
[corzyy/jhqs](https://github.com/corzyy/jhqs) (Quickshell config) on **Fedora**,
including the Everything netinstall with the Minimal profile.

The installer lives at the repo root: `~/Documents/dotfiles/install.sh`, with
its package list in `~/Documents/dotfiles/Installer/packages.conf`.

## Quick start — Fedora Everything minimal

In the netinstaller pick **Minimal Install**, reboot, log in, then:

```bash
sudo dnf install -y git
git clone https://github.com/corzyy/dotfiles.git ~/Documents/dotfiles
cd ~/Documents/dotfiles
./install.sh --dry-run   # preview, changes nothing
./install.sh             # real install (asks for confirmation)
./install.sh -y          # no confirmation prompt
```

Fresh-machine one-liner:

```bash
sudo dnf install -y git && git clone https://github.com/corzyy/dotfiles.git ~/Documents/dotfiles && ~/Documents/dotfiles/install.sh
```

## What it does

1. **base** — installs the tools a Minimal install lacks (`git`, `curl`,
   `rsync`, `xdg-user-dirs`, `accountsservice`). From `BASE_PACKAGES`.
2. **terra** — enables the Terra third-party repository, which provides
   `mangowm` and `jetbrainsmono-nerd-fonts`. Skipped if
   `/etc/yum.repos.d/terra.repo` already exists, or when
   `ENABLE_TERRA="false"`.
3. **packages** — installs `PACKAGES` from `Installer/packages.conf`. Packages
   already present are skipped, packages that no repository provides are
   reported and skipped, and `mangowm`, `quickshell` and `sddm` are verified as
   required.
4. **configs** — copies `.config/*` from the repo into `~/.config`. Existing
   entries are backed up to `~/.config_backup_<date>` first (unless identical).
   `wallpapers` is handled separately. Use `--link` for symlinks instead.
5. **wallpapers** — copies `wallpapers/` to your Pictures folder, resolved via
   `xdg-user-dir PICTURES` (so `~/Pictures`, `~/Bilder`, … all work).
6. **jhqs** — clones/updates `corzyy/jhqs` to `~/.config/quickshell/jhqs`,
   makes `scripts/*.sh` executable, and creates
   `~/.local/bin/jhqs -> /usr/bin/quickshell` for the Mango autostart.
7. **sddm** — enables and starts SDDM, sets `graphical.target` as the default
   boot target (Minimal boots to `multi-user.target` otherwise), enables
   `NetworkManager` if needed, and checks for the `mango.desktop` session.

At the end it prompts to reboot.

## Add programs later

Edit `Installer/packages.conf` — one name per line, no commas:

```bash
PACKAGES+=(
  neovim
  ghostty
)

BASE_PACKAGES+=(
  wget
)
```

Then re-run only the package step:

```bash
./install.sh --only-packages -y
```

## Useful flags

| Flag | Effect |
|---|---|
| `--dry-run` | print actions, change nothing |
| `-y`, `--yes` | skip the confirmation prompt |
| `--copy` / `--link` | copy configs (default) or symlink them to the repo |
| `--no-backup` | overwrite existing configs without backing them up |
| `--only-<step>` | run only the given step(s); can be combined |
| `--no-<step>` | skip the given step |
| `--no-reboot` | do not ask to reboot at the end |
| `--reboot` | reboot automatically when finished |
| `-h`, `--help` | show help |

Steps are `base`, `terra`, `packages`, `configs`, `wallpapers`, `jhqs`, `sddm`.
For example `./install.sh --only-terra --only-packages -y`, or
`./install.sh --no-sddm` to install everything but leave the display manager
alone.

## Layout

```text
~/Documents/dotfiles/
  install.sh
  .config/btop, fastfetch, fish, kitty, mango, matugen, …
  wallpapers/catppuccin, everforest, gruvbox, …
  Installer/packages.conf
  Installer/README.md
```

Anything you add under `.config/` is picked up automatically on the next
`./install.sh` (or `--only-configs`) run.

## Notes

- The installer uses `dnf5` when present, otherwise `dnf`.
- MangoWM comes from Terra — no COPR is needed.
- The shipped matugen templates use portable `~/…` paths, so theming works for
  any username.
- Mango autostart expects the `jhqs` launcher and `wallpaper-restore.sh`; both
  are handled by the installer.
