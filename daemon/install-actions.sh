#!/bin/bash
# Install default action scripts to ~/.config/clawdmeter/
# These are triggered by the 6 buttons on the Actions tab of the Clawdmeter.
# Re-running this script will NOT overwrite scripts that already exist.

TARGET="$HOME/.config/clawdmeter"
SOURCE="$(dirname "$(readlink -f "$0")")/actions-default"

mkdir -p "$TARGET"

for f in "$SOURCE"/action*.sh; do
    name=$(basename "$f")
    dest="$TARGET/$name"
    if [ -e "$dest" ]; then
        echo "↷ $name (existe déjà, conservé)"
    else
        cp "$f" "$dest"
        chmod +x "$dest"
        echo "✓ $name installé"
    fi
done

echo ""
echo "Scripts dans $TARGET :"
ls -1 "$TARGET"/action*.sh 2>/dev/null
echo ""
echo "Personnalisez-les librement — le daemon les rechargera au prochain tap."
