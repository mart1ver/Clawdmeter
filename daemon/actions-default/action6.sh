#!/bin/bash
# Action 6: Mute / Unmute son

pactl set-sink-mute @DEFAULT_SINK@ toggle 2>/dev/null || \
amixer set Master toggle 2>/dev/null
