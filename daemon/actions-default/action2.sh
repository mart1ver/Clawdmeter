#!/bin/bash
# Action 2: Capture d'écran

out="$HOME/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png"
if command -v gnome-screenshot >/dev/null; then
    gnome-screenshot -f "$out"
elif command -v scrot >/dev/null; then
    scrot "$out"
fi
notify-send "Capture d'écran" "Sauvée dans $out" 2>/dev/null
