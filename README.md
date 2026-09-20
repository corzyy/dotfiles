# Installer — dotfiles + solstice (Fedora)

Installs [corzyy/dotfiles](https://github.com/corzyy/dotfiles) and
[corzyy/solstice](https://github.com/corzyy/solstice) (Quickshell config) on
**Fedora**, setting up an Umbriel + Quickshell session.

The packages step verifies every required package after installation and asks
before installing the optional applications (`--no-apps` skips them).

## Quick start — Fedora Everything minimal
```bash
curl -fsSL https://github.com/corzyy/dotfiles/raw/main/install.sh | bash
```

## Uninstall

`uninstall.sh` reverses every step: the solstice shell/CLI, the copied
configs, GTK/cursor settings, fisher, wallpapers, the M3Shapes module and the
installed packages. Backups in `~/.config_backup_*` are kept.

```bash
curl -fsSL https://github.com/corzyy/dotfiles/raw/main/uninstall.sh | bash
```

Use `--keep-packages` to leave all dnf packages alone, `--dry-run` to preview,
or `--only-<step>`/`--no-<step>` to pick steps. Options go after `bash -s --`:

```bash
curl -fsSL https://github.com/corzyy/dotfiles/raw/main/uninstall.sh | bash -s -- --keep-packages
```
