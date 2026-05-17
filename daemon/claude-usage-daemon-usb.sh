#!/bin/bash
# Claude Usage Tracker Daemon (USB serial)
# Reads Claude Code OAuth token, polls Anthropic API for usage, writes a JSON
# line to the SC01 Plus over its USB-CDC port. Drop-in alternative to the BLE
# daemon — same payload schema, much simpler transport.
# Dependencies: curl, awk, stty

DEVICE_PORT="${DEVICE_PORT:-}"     # e.g. /dev/ttyACM0; auto-detected if empty
BAUD=115200
POLL_INTERVAL=60

# Flag file the background reader touches when firmware asks for an immediate
# poll (it emits {"req":"poll"} on boot until gauges arrive). The main loop
# checks this each tick and forces LAST_API_POLL=0 to skip the 60s wait.
REQ_FLAG="${XDG_RUNTIME_DIR:-/tmp}/claude-usb-poll-req"
READER_PID=""

log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

read_token() {
    grep -o '"accessToken":"[^"]*"' "$HOME/.claude/.credentials.json" | cut -d'"' -f4
}

# Pull the active model alias out of Claude Code's settings.json and normalize
# it to a short label (opus/sonnet/haiku) for the SC01 display. Falls back to
# "default" if the file is missing or no model is configured.
read_model() {
    local raw
    raw=$(grep -oE '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$HOME/.claude/settings.json" 2>/dev/null \
          | head -1 | sed -E 's/.*"([^"]*)"[^"]*$/\1/')
    case "$raw" in
        *opus*)   echo "opus" ;;
        *sonnet*) echo "sonnet" ;;
        *haiku*)  echo "haiku" ;;
        "")       echo "default" ;;
        *)        echo "$raw" ;;
    esac
}

# Pick the first ESP32 USB-CDC port (303a:1001 enumerates as ttyACM*).
detect_port() {
    for p in /dev/ttyACM0 /dev/ttyACM1 /dev/ttyACM2 /dev/ttyUSB0 /dev/ttyUSB1; do
        [ -c "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

# Open the port in raw mode at the right baud, then pin it open on FD 3 for
# the daemon's lifetime. -hupcl tells the kernel not to hangup on close, but
# we *also* avoid close-per-write entirely: every `printf > $DEVICE_PORT`
# would re-open the CDC endpoint and the ESP32-S3 resets on (some) opens,
# bouncing through boot every poll.
configure_port() {
    # clocal: ignore modem control lines. Without it the kernel sends SIGHUP
    # to every process holding the TTY open the moment the cable is pulled,
    # which (combined with bash's default SIGHUP behaviour) kills the daemon.
    stty -F "$DEVICE_PORT" "$BAUD" raw clocal -echo -echoe -echok -echoctl -echoke -hupcl 2>/dev/null
    # Read+write on one FD: opening twice would pulse DTR a second time and
    # reset the ESP32. The background reader inherits FD 3 with <&3 instead
    # of reopening the device.
    exec 3<>"$DEVICE_PORT" || return 1
    # First open still pulses DTR/RTS — let the board finish booting before
    # the first poll so the JSON isn't sent into the ROM loader.
    sleep 2
}

# Spawn a child shell that reads firmware → host lines on FD 3 (inherited)
# and touches the flag file when the firmware asks for an immediate poll.
# Substring match on '"req":"poll"' is enough — no other firmware message
# carries that key.
start_reader() {
    rm -f "$REQ_FLAG"
    bash -c "while IFS= read -r l; do case \"\$l\" in *'\"req\":\"poll\"'*) touch '$REQ_FLAG' ;; esac; done <&3" &
    READER_PID=$!
}

stop_reader() {
    if [ -n "$READER_PID" ]; then
        kill "$READER_PID" 2>/dev/null
        wait "$READER_PID" 2>/dev/null
        READER_PID=""
    fi
}

close_port() {
    stop_reader
    exec 3>&- 2>/dev/null
}

send_line() {
    # Trailing newline is mandatory: firmware reads char-by-char and dispatches
    # on '\n'. Writing to fd 3 keeps the CDC endpoint open across polls.
    printf '%s\n' "$1" >&3
}

# Return codes:
#   0 — sent successfully
#   1 — serial write failed (port likely gone; caller should reopen)
#   2 — API/token transient issue (port still OK, skip + retry next tick)
poll() {
    local token
    token=$(read_token) || { log "Error: could not read token"; return 2; }
    local now
    now=$(date +%s)

    local headers
    headers=$(curl -s -D - -o /dev/null \
        "https://api.anthropic.com/v1/messages" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" \
        -H "User-Agent: claude-code/2.1.5" \
        -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
        2>/dev/null) || { log "Error: API call failed"; return 2; }

    local s5h_util s5h_reset s7d_util s7d_reset status
    s5h_util=$(echo "$headers" | grep -i "anthropic-ratelimit-unified-5h-utilization" | tr -d '\r' | awk '{print $2}')
    s5h_reset=$(echo "$headers" | grep -i "anthropic-ratelimit-unified-5h-reset" | tr -d '\r' | awk '{print $2}')
    s7d_util=$(echo "$headers" | grep -i "anthropic-ratelimit-unified-7d-utilization" | tr -d '\r' | awk '{print $2}')
    s7d_reset=$(echo "$headers" | grep -i "anthropic-ratelimit-unified-7d-reset" | tr -d '\r' | awk '{print $2}')
    status=$(echo "$headers" | grep -i "anthropic-ratelimit-unified-5h-status" | tr -d '\r' | awk '{print $2}')

    # If the rate-limit headers are missing the response was malformed
    # (transient network glitch after machine wake, throttled, non-200, …).
    # Don't overwrite the display with zeros — leave the last good values.
    if [ -z "$s5h_util" ] || [ -z "$status" ]; then
        log "API response missing rate-limit headers, skipping update"
        return 2
    fi

    s5h_reset=${s5h_reset:-0}
    s7d_util=${s7d_util:-0}
    s7d_reset=${s7d_reset:-0}

    local model
    model=$(read_model)

    local payload
    payload=$(awk -v u5="$s5h_util" -v r5="$s5h_reset" -v u7="$s7d_util" -v r7="$s7d_reset" -v st="$status" -v m="$model" -v now="$now" \
        'BEGIN {
            sp = sprintf("%.0f", u5 * 100);
            sr = (r5 - now) / 60; sr = sr > 0 ? sprintf("%.0f", sr) : 0;
            wp = sprintf("%.0f", u7 * 100);
            wr = (r7 - now) / 60; wr = wr > 0 ? sprintf("%.0f", wr) : 0;
            printf "{\"s\":%s,\"sr\":%s,\"w\":%s,\"wr\":%s,\"st\":\"%s\",\"m\":\"%s\",\"ok\":true}", sp, sr, wp, wr, st, m;
        }')

    log "Sending: $payload"
    if ! send_line "$payload"; then
        log "Write failed (device unplugged?)"
        return 1
    fi
    return 0
}

cleanup() {
    close_port
    log "Daemon stopped"
    exit 0
}

# Belt-and-suspenders: clocal in configure_port should prevent SIGHUP from
# ever being delivered, but ignore it explicitly in case stty doesn't take
# effect (e.g. on the very first iteration before the port has been opened).
trap '' HUP
trap cleanup INT TERM

log "=== Claude Usage Tracker Daemon (USB) ==="
log "Poll interval: ${POLL_INTERVAL}s (API), 2s (model watcher)"

SETTINGS_FILE="$HOME/.claude/settings.json"
TICK=2                  # inner-loop cadence for model watcher
LAST_API_POLL=0
LAST_MODEL_MTIME=0
LAST_MODEL=""

# Push a tiny partial JSON when the user runs /model in Claude Code. The
# firmware treats missing fields as "keep previous value" so this leaves the
# gauges untouched.
push_model_if_changed() {
    [ -f "$SETTINGS_FILE" ] || return 0
    local mtime
    mtime=$(stat -c %Y "$SETTINGS_FILE" 2>/dev/null) || return 0
    [ "$mtime" = "$LAST_MODEL_MTIME" ] && return 0
    LAST_MODEL_MTIME="$mtime"

    local m
    m=$(read_model)
    [ "$m" = "$LAST_MODEL" ] && return 0
    log "Model changed: ${LAST_MODEL:-?} → $m"
    LAST_MODEL="$m"
    send_line "{\"m\":\"$m\"}" || return 1
}

while true; do
    if [ -z "$DEVICE_PORT" ] || [ ! -c "$DEVICE_PORT" ]; then
        close_port
        DEVICE_PORT=$(detect_port) || {
            log "No USB serial port found, retrying in 10s..."
            sleep 10
            continue
        }
        log "Using port: $DEVICE_PORT"
        configure_port || {
            log "Failed to open $DEVICE_PORT, retrying in 5s..."
            DEVICE_PORT=""
            sleep 5
            continue
        }
        start_reader
        # Force re-push of model on reconnect.
        LAST_MODEL_MTIME=0
        LAST_MODEL=""
    fi

    # Reader process is what relays firmware → host requests; if it died
    # (USB re-enumeration after flash, etc.) the port FDs are stale too.
    if [ -n "$READER_PID" ] && ! kill -0 "$READER_PID" 2>/dev/null; then
        log "Reader died, reopening port"
        READER_PID=""
        close_port; DEVICE_PORT=""; sleep 1; continue
    fi

    push_model_if_changed || {
        close_port; DEVICE_PORT=""; sleep 5; continue
    }

    # Firmware asked for an immediate poll (gauges still "---" on its end).
    if [ -f "$REQ_FLAG" ]; then
        rm -f "$REQ_FLAG"
        log "Firmware requested immediate poll"
        LAST_API_POLL=0
    fi

    now=$(date +%s)
    if (( now - LAST_API_POLL >= POLL_INTERVAL )); then
        LAST_API_POLL=$now
        poll
        rc=$?
        case $rc in
            0) ;;  # ok
            1) # serial write failed → port may have vanished
               close_port; DEVICE_PORT=""; sleep 5; continue
               ;;
            2) # API/network issue → keep port, retry on next API tick
               ;;
        esac
    fi

    sleep "$TICK"
done
