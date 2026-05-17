#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="claude-usage-daemon-usb"
SERVICE_FILE="$SCRIPT_DIR/daemon/$SERVICE_NAME.service"
USER_SERVICE_DIR="$HOME/.config/systemd/user"

echo "=== Clawdmeter SC01 Plus / USB - Install ==="
echo ""

echo "[1/3] Checking dependencies..."
for cmd in curl awk stty; do
    command -v "$cmd" >/dev/null || { echo "Error: $cmd is required but not installed"; exit 1; }
done
echo "  All dependencies found"
echo ""

echo "[2/3] Installing systemd user service..."
mkdir -p "$USER_SERVICE_DIR"
DAEMON_BIN="$SCRIPT_DIR/daemon/$SERVICE_NAME.sh"
sed "s|DAEMON_PATH|${DAEMON_BIN}|g" "$SERVICE_FILE" > "$USER_SERVICE_DIR/$SERVICE_NAME.service"
systemctl --user daemon-reload

echo "[3/3] Enabling service..."
systemctl --user enable "$SERVICE_NAME"

echo ""
echo "=== Done! ==="
echo ""
echo "Plug the SC01 Plus in, then start the daemon:"
echo "  systemctl --user start $SERVICE_NAME"
echo ""
echo "Useful commands:"
echo "  systemctl --user status $SERVICE_NAME"
echo "  journalctl --user -u $SERVICE_NAME -f"
echo "  systemctl --user restart $SERVICE_NAME"
echo "  systemctl --user stop $SERVICE_NAME"
echo ""
