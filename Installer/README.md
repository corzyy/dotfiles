# Installer

`../install.sh` is the entry point; this directory only holds
`packages.conf`.

## packages.conf

| Array           | Purpose                                                        |
| --------------- | -------------------------------------------------------------- |
| `BASE_PACKAGES` | Bootstrap tools for a minimal Fedora install.                  |
| `PACKAGES`      | Required for the Umbriel session + solstice shell. Verified    |
|                 | after installation; the run fails if any are missing.          |
| `APP_PACKAGES`  | Optional applications (`btop`, `fastfetch`, `nautilus`, ...).  |
|                 | The installer asks before installing them (`--no-apps` skips). |
| `ENABLE_TERRA`  | `"true"` enables Terra (umbriel-nightly, nerd fonts, helium).  |

Entries are one package per line; comments and duplicates are ignored.
After editing, re-run only the affected step:

```bash
./install.sh --only-packages -y
```
