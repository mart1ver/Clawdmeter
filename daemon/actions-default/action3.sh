#!/bin/bash
# Action 3: Ouvrir un terminal

# Use x-terminal-emulator (Debian/Ubuntu alternative) which on this system
# resolves to ptyxis (the new GNOME terminal). Fall back to common ones.
for t in x-terminal-emulator ptyxis gnome-terminal xfce4-terminal konsole xterm; do
    if command -v "$t" >/dev/null 2>&1; then
        setsid "$t" >/dev/null 2>&1 &
        exit 0
    fi
done
notify-send "Action 3" "Aucun terminal trouvé"
