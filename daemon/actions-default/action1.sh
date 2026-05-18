#!/bin/bash
# Action 1: Verrouiller la session
# Personnalisez ce script pour faire ce que vous voulez quand vous tapez
# le bouton 1 sur l'onglet Actions du Clawdmeter.

xdg-screensaver lock 2>/dev/null || \
loginctl lock-session 2>/dev/null || \
notify-send "Action 1" "Aucune commande de verrouillage trouvée"
