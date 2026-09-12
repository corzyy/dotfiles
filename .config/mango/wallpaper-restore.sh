#!/bin/bash
# Restores wallpaper on mango startup (mirrors hypr autostart.lua).
# jhqs also re-spawns swaybg itself if it dies, so this is just first-paint.
WALL=$(cat ~/.config/quickshell/jhqs/config/current_wallpaper.txt 2>/dev/null | tr -d "\r\n")
[ -f "$WALL" ] || WALL=$(cat ~/.cache/swaybg/current 2>/dev/null | tr -d "\r\n")
if [ ! -f "$WALL" ]; then
  for d in "$HOME/Pictures/wallpapers" "$HOME/Bilder/wallpapers" "$HOME/Wallpapers" "$HOME/wallpapers"; do
    if [ -d "$d" ]; then
      WALL=$(find "$d" -mindepth 1 -maxdepth 2 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" \) 2>/dev/null | sort | head -1)
      [ -f "$WALL" ] && break
    fi
  done
fi
[ -f "$WALL" ] || exit 0
MODE=$(jq -r '.mode // "fill"' ~/.config/quickshell/jhqs/config/wallpaper_settings.json 2>/dev/null)
case "$MODE" in
  stretch|fit|fill|center|tile) ;;
  *) MODE=fill ;;
esac
pkill -x swaybg 2>/dev/null
exec setsid nohup swaybg -i "$WALL" -m "$MODE" >/dev/null 2>&1 </dev/null &
