#!/usr/bin/env bash
# Matugen -> Papirus folder theming
# Generated from {{image}} | mode={{mode}} | color={{colors.primary.default.hex}}
# This script creates a user-local Papirus-Matugen overlay with exact matugen color.

set -euo pipefail

COLOR="{{colors.primary.default.hex}}"
MODE="{{mode}}"

# Use primary as folder base; source_color is also available as fallback
# COLOR is e.g. #8ab4f8

# Compute darker shade (for folder back) by darkening ~18% in HLS
DARK="$(python3 <<'PYEOF'
import colorsys
c = "{{colors.primary.default.hex}}".lstrip('#')
r, g, b = int(c[0:2],16)/255, int(c[2:4],16)/255, int(c[4:6],16)/255
h,l,s = colorsys.rgb_to_hls(r,g,b)
l = max(0.08, l * 0.82)
r2,g2,b2 = colorsys.hls_to_rgb(h,l,s)
print(f'#{int(round(r2*255)):02x}{int(round(g2*255)):02x}{int(round(b2*255)):02x}')
PYEOF
)"

LIGHT="$COLOR"

echo "[papirus-matugen] Primary $LIGHT -> Dark $DARK (mode $MODE)"

# Determine base theme to inherit
CURRENT_THEME="$(gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null | tr -d "'" || echo Papirus)"
BASE_SRC="/usr/share/icons/Papirus"
if [[ "$CURRENT_THEME" == *"-Dark"* ]]; then
    BASE_SRC="/usr/share/icons/Papirus-Dark"
    [[ -d "$BASE_SRC" ]] || BASE_SRC="/usr/share/icons/Papirus"
elif [[ "$CURRENT_THEME" == *"-Light"* ]]; then
    BASE_SRC="/usr/share/icons/Papirus-Light"
    [[ -d "$BASE_SRC" ]] || BASE_SRC="/usr/share/icons/Papirus"
fi

# Also check local override first for index
[[ -f "$HOME/.local/share/icons/Papirus/index.theme" ]] || true

DST="$HOME/.local/share/icons/Papirus-Matugen"
SRC_FALLBACK="/usr/share/icons/Papirus"

mkdir -p "$DST"

# Create index.theme for the overlay theme
cat > "$DST/index.theme" <<EOF
[Icon Theme]
Name=Papirus-Matugen
Comment=Papirus with matugen folder color $LIGHT
Inherits=Papirus,breeze,hicolor
FollowsColorScheme=true
Example=folder
EOF
# Copy Directories list from base theme for cache compatibility
if [[ -f "$SRC_FALLBACK/index.theme" ]]; then
    # Append Directories keys if not already present
    awk '/^Directories=/ {print; found=1} END{ if(found==0) print ""}' "$SRC_FALLBACK/index.theme" >> "$DST/index.theme" 2>/dev/null || true
    # If still minimal, at least include places dirs
    if ! grep -q "Directories=" "$DST/index.theme"; then
        echo "Directories=48x48/places,32x32/places,24x24/places,22x22/places,16x16/places" >> "$DST/index.theme"
    fi
fi

# Sizes and color mapping
# Papirus stores folder colors as e.g. #5294e2 (light) + #4877b1 (dark) for blue
# Other colors have two similar hexes; we replace both variants with LIGHT/DARK
SIZES=(16x16 16x16@2x 22x22 22x22@2x 24x24 24x24@2x 32x32 32x32@2x 48x48 48x48@2x 64x64)

# Build map of all known papirus light/dark pairs to replace
# We fetch one sample of each color to discover its hex pair, or just replace generically:
# Strategy: for each folder.svg template, replace any hex that is NOT #e4e4e4/#ffffff (paper/ highlight)
# But simpler: replace the two hexes found in folder-blue.svg generically with LIGHT/DARK

# We use folder-blue.svg as template source (always exists) for generic folder.svg
for size in "${SIZES[@]}"; do
    SRC_FILE="$SRC_FALLBACK/$size/places/folder-blue.svg"
    [[ -f "$SRC_FILE" ]] || SRC_FILE="$SRC_FALLBACK/48x48/places/folder-blue.svg"
    [[ -f "$SRC_FILE" ]] || continue
    DST_DIR="$DST/$size/places"
    mkdir -p "$DST_DIR"

    # Generate recolored generic folder
    # Replace both blue shades with new color shades
    # Use python for reliable replacement to avoid partial matches
    python3 <<PY
import pathlib, re
src = pathlib.Path("$SRC_FILE")
dst = pathlib.Path("$DST_DIR/folder.svg")
text = src.read_text()
# Papirus blue pair
text = text.replace("#5294e2", "$LIGHT")
text = text.replace("#5294E2", "$LIGHT")
text = text.replace("#4877b1", "$DARK")
text = text.replace("#4877B1", "$DARK")
# Also handle uppercase/lower variations for other potential hexes if template was not blue
# For safety, also replace generic pattern where first path fill + rect fill are folder colors:
# We already covered blue; for other templates we would need their colors, but we only use blue template
dst.write_text(text)
print(f"Generated {dst}")
PY

    # Also create folder-blue.svg as alias to folder.svg (for completeness)
    cp -f "$DST_DIR/folder.svg" "$DST_DIR/folder-blue.svg" 2>/dev/null || true

    # Now generate all other folder variants in a single python pass (faster)
    python3 <<PY2
import re, pathlib, glob, os
light = "$LIGHT"
dark = "$DARK"
src_base = pathlib.Path("$SRC_FALLBACK/$size/places")
dst_base = pathlib.Path("$DST_DIR")
for orig_str in glob.glob(str(src_base / "folder*.svg")):
    orig = pathlib.Path(orig_str)
    fname = orig.name
    if fname in ("folder.svg", "folder-blue.svg"):
        continue
    dst = dst_base / fname
    try:
        text = orig.read_text()
    except:
        continue
    hexes = re.findall(r'#[0-9a-fA-F]{6}', text)
    filtered = [h for h in hexes if h.lower() not in ("#e4e4e4", "#ffffff")]
    uniq = []
    for h in filtered:
        if h.lower() not in [x.lower() for x in uniq]:
            uniq.append(h)
    if len(uniq) == 2:
        text = text.replace(uniq[0], dark)
        text = text.replace(uniq[1], light)
        text = text.replace(uniq[0].upper(), dark)
        text = text.replace(uniq[1].upper(), light)
    elif len(uniq) == 1:
        text = text.replace(uniq[0], light)
        text = text.replace(uniq[0].upper(), light)
    else:
        text = text.replace("#5294e2", light).replace("#4877b1", dark)
    dst.write_text(text)
PY2
done

# Update icon caches
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q "$DST" 2>/dev/null || true
    gtk-update-icon-cache -q "$HOME/.local/share/icons/Papirus" 2>/dev/null || true
fi

# Clear KDE cache
rm -f "$HOME/.cache/icon-cache.kcache" 2>/dev/null || true
rm -f "/var/tmp/kdecache-$USER/icon-cache.kcache" 2>/dev/null || true

# Set icon theme to Papirus-Matugen if not already
CURRENT="$(gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null | tr -d "'" || echo Papirus)"
if [[ "$CURRENT" != "Papirus-Matugen" ]]; then
    echo "[papirus-matugen] Switching icon-theme $CURRENT -> Papirus-Matugen"
    gsettings set org.gnome.desktop.interface icon-theme 'Papirus-Matugen' 2>/dev/null || true
else
    # Touch to trigger reload: toggle theme
    gsettings set org.gnome.desktop.interface icon-theme 'Papirus' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface icon-theme 'Papirus-Matugen' 2>/dev/null || true
fi

# Also ensure Papirus-Dark-Matugen variant exists for apps that request Dark explicitly
# (we just symlink it)
if [[ ! -d "$HOME/.local/share/icons/Papirus-Dark-Matugen" ]]; then
    mkdir -p "$HOME/.local/share/icons/Papirus-Dark-Matugen"
    ln -sf "$DST/index.theme" "$HOME/.local/share/icons/Papirus-Dark-Matugen/index.theme" 2>/dev/null || cp "$DST/index.theme" "$HOME/.local/share/icons/Papirus-Dark-Matugen/index.theme"
fi

echo "[papirus-matugen] Done. Folder color $LIGHT / $DARK"
