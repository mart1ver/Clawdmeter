#!/bin/bash
# Action 5: Volume -5%

pactl set-sink-volume @DEFAULT_SINK@ -5% 2>/dev/null || \
amixer set Master 5%- 2>/dev/null
