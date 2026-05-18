#!/bin/bash
# Quickly switch the firmware to a specific screen via USB serial.
# Usage: ./screen.sh <usage|system|bitcoin|actions|splash> [port]
#
# Useful for screenshots without reflashing. Stop the daemon first or it
# will fight for the port: `systemctl --user stop claude-usage-daemon-usb`.

SCREEN="${1:-usage}"
PORT="${2:-/dev/ttyACM0}"

case "$SCREEN" in
    usage|system|bitcoin|actions|splash) ;;
    *) echo "Unknown screen: $SCREEN"; echo "Choices: usage system bitcoin actions splash"; exit 1 ;;
esac

stty -F "$PORT" 115200 raw clocal -echo 2>/dev/null || { echo "Cannot open $PORT"; exit 1; }
printf 'screen %s\n' "$SCREEN" > "$PORT"
echo "→ $SCREEN"
