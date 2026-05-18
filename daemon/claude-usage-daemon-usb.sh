#!/bin/bash
# Claude Usage Tracker Daemon (USB serial)
# Reads Claude Code OAuth token, polls Anthropic API for usage, writes a JSON
# line to the SC01 Plus over its USB-CDC port. Drop-in alternative to the BLE
# daemon — same payload schema, much simpler transport.
# Dependencies: curl, awk, stty

DEVICE_PORT="${DEVICE_PORT:-}"     # e.g. /dev/ttyACM0; auto-detected if empty
BAUD=115200
POLL_INTERVAL=60
SYS_PUSH_INTERVAL=2        # seconds between system-stats payloads
BTC_POLL_INTERVAL=86400    # seconds between Bitcoin price fetches (daily)

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

# ---- Host system telemetry --------------------------------------------
# Collects cpu / ram / disk / temp / gpu / net every SYS_PUSH_INTERVAL
# seconds and ships them to the firmware as a "sys" sub-object. Most calls
# use deltas, so the first reading after boot returns 0 and the second is
# the first useful sample.

PREV_CPU_TOTAL=0
PREV_CPU_IDLE=0
PREV_NET_RX=0
PREV_NET_TX=0
PREV_NET_TIME_MS=0
LAST_SYS_PUSH=0

# Bitcoin price history: 180 daily samples (ring buffer, 6 months of data)
declare -a BTC_HISTORY
BTC_HISTORY_IDX=0
BTC_CURRENT_PRICE=0
BTC_24H_MIN=0
BTC_24H_MAX=0
BTC_24H_CHANGE=0
LAST_BTC_POLL=0
LAST_BTC_DAY=0
BTC_CACHE_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-btc-history.json"

read_cpu_pct() {
    # /proc/stat first line: cpu user nice system idle iowait irq softirq steal ...
    local f1 f2 f3 f4 f5 f6 f7 f8 total idle d_total d_idle pct
    read -r _ f1 f2 f3 f4 f5 f6 f7 f8 _ < /proc/stat
    idle=$(( f4 + f5 ))               # idle + iowait
    total=$(( f1 + f2 + f3 + f4 + f5 + f6 + f7 + f8 ))
    d_total=$(( total - PREV_CPU_TOTAL ))
    d_idle=$(( idle  - PREV_CPU_IDLE  ))
    PREV_CPU_TOTAL=$total
    PREV_CPU_IDLE=$idle
    if (( d_total <= 0 )); then echo 0; return; fi
    pct=$(( ( (d_total - d_idle) * 100 ) / d_total ))
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100
    echo "$pct"
}

read_ram_pct() {
    local total avail
    total=$(awk '/^MemTotal:/  {print $2; exit}' /proc/meminfo)
    avail=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)
    [ -z "$total" ] || [ "$total" -le 0 ] && { echo 0; return; }
    echo $(( ( (total - avail) * 100 ) / total ))
}

read_disk_pct() {
    df --output=pcent / 2>/dev/null | awk 'NR==2 {gsub(/[ %]/,""); print}'
}

read_temp_c() {
    # Prefer a thermal zone whose type matches a CPU package sensor;
    # fall back to thermal_zone0 which is typically the ACPI CPU zone.
    local zone type t
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -r "$zone/type" ] || continue
        type=$(cat "$zone/type" 2>/dev/null)
        case "$type" in
            *x86_pkg_temp*|*coretemp*|*cpu*|*k10temp*)
                t=$(cat "$zone/temp" 2>/dev/null)
                [ -n "$t" ] && { echo $(( t / 1000 )); return; }
                ;;
        esac
    done
    t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    if [ -n "$t" ]; then echo $(( t / 1000 )); else echo 0; fi
}

read_gpu_pct() {
    if command -v nvidia-smi >/dev/null 2>&1; then
        local v
        v=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        [ -n "$v" ] && { echo "$v"; return; }
    fi
    local c
    for c in /sys/class/drm/card*/device/gpu_busy_percent; do
        [ -r "$c" ] || continue
        cat "$c" 2>/dev/null && return
    done
    echo -1
}

read_net_kbps() {
    # Sum bytes RX (col 2) + TX (col 10) across every iface except lo.
    local rx tx now_ms d_t d_rx d_tx
    read -r rx tx < <(awk -F'[: ]+' '
        /^[[:space:]]*lo:/ { next }
        /:/ { sum_rx += $3; sum_tx += $11 }
        END { print sum_rx+0, sum_tx+0 }
    ' /proc/net/dev)
    now_ms=$(date +%s%3N)
    if (( PREV_NET_TIME_MS == 0 )); then
        PREV_NET_RX=$rx; PREV_NET_TX=$tx; PREV_NET_TIME_MS=$now_ms
        echo 0; return
    fi
    d_t=$(( now_ms - PREV_NET_TIME_MS ))
    (( d_t <= 0 )) && { echo 0; return; }
    d_rx=$(( rx - PREV_NET_RX ))
    d_tx=$(( tx - PREV_NET_TX ))
    PREV_NET_RX=$rx; PREV_NET_TX=$tx; PREV_NET_TIME_MS=$now_ms
    # KB/s = (bytes / 1024) * (1000 / ms)
    echo $(( ( (d_rx + d_tx) * 1000 ) / (1024 * d_t) ))
}

read_bitcoin_price() {
    # Fetch Bitcoin current price from CoinGecko API (free, no auth required).
    # Returns: price change24_bps (price in USD; change24_bps as basis points, e.g., 19 for 0.19%)
    local json
    json=$(curl -s "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd&include_market_cap=false&include_24hr_vol=false&include_24hr_change=true&include_market_cap_change_24h=false" 2>/dev/null) || return 1

    local price change24_pct
    price=$(echo "$json" | grep -o '"usd":[^,}]*' | head -1 | cut -d':' -f2)
    change24_pct=$(echo "$json" | grep -o '"usd_24h_change":[^,}]*' | cut -d':' -f2)

    # Parse price as integer.
    price=$(echo "$price" | awk '{printf "%.0f", $1}')

    # Parse change24 in basis points (multiply % by 100, so 0.19% becomes 19 bps).
    change24_pct=$(echo "$change24_pct" | awk '{printf "%.0f", $1 * 100}')

    [ -z "$price" ] && return 1
    [ -z "$change24_pct" ] && change24_pct=0

    echo "$price" "$change24_pct"
}

read_bitcoin_history() {
    # Fetch Bitcoin daily prices for the last 180 days.
    # Returns one price per line (oldest first).
    local json
    json=$(curl -s "https://api.coingecko.com/api/v3/coins/bitcoin/market_chart?vs_currency=usd&days=180&interval=daily" 2>/dev/null) || return 1

    # Extract from "prices":[ array using sed, then parse [timestamp,price] pairs
    # Each pair looks like: [1234567890000,95000.123]
    # We want just the price (second number)
    echo "$json" | sed 's/"prices":\[\[//' | sed 's/\]\],"market_caps".*//' | \
    grep -o '\[[0-9]*,[0-9]*\.[0-9]*\]' | \
    sed 's/\[[0-9]*,\([0-9]*\)\.[0-9]*\]/\1/'
}

init_bitcoin_history() {
    # One-time initialization: load 180 days of history from cache or API.

    # Try loading from cache first
    if [ -f "$BTC_CACHE_FILE" ]; then
        log "Bitcoin: loading history from cache..."
        local count=0
        while IFS= read -r price; do
            if [ -z "$price" ] || [ "$price" -eq 0 ]; then
                continue
            fi
            BTC_HISTORY[$count]=$price

            # Track min/max.
            if [ $BTC_24H_MIN -eq 0 ] || [ $price -lt $BTC_24H_MIN ]; then
                BTC_24H_MIN=$price
            fi
            if [ $price -gt $BTC_24H_MAX ]; then
                BTC_24H_MAX=$price
            fi

            (( count++ ))
            if [ $count -ge 180 ]; then
                break
            fi
        done < "$BTC_CACHE_FILE"

        BTC_HISTORY_IDX=$count
        if [ $count -gt 0 ]; then
            # Set current price as the last (most recent) price in the history
            if [ -n "${BTC_HISTORY[$((count-1))]}" ]; then
                BTC_CURRENT_PRICE=${BTC_HISTORY[$((count-1))]}
            fi
            log "Bitcoin: loaded $count days from cache (min: \$$BTC_24H_MIN, max: \$$BTC_24H_MAX, current: \$$BTC_CURRENT_PRICE)"
            return 0
        fi
    fi

    # Cache miss or empty: fetch from API
    log "Bitcoin: fetching 180 days of history from API..."
    local prices
    prices=$(read_bitcoin_history) || { log "Bitcoin history fetch failed"; return 1; }

    local count=0
    {
        while IFS= read -r price; do
            if [ -z "$price" ] || [ "$price" -eq 0 ]; then
                continue
            fi
            BTC_HISTORY[$count]=$price
            echo "$price" >> "$BTC_CACHE_FILE"

            # Track min/max.
            if [ $BTC_24H_MIN -eq 0 ] || [ $price -lt $BTC_24H_MIN ]; then
                BTC_24H_MIN=$price
            fi
            if [ $price -gt $BTC_24H_MAX ]; then
                BTC_24H_MAX=$price
            fi

            (( count++ ))
            if [ $count -ge 180 ]; then
                break
            fi
        done <<< "$prices"
    }

    BTC_HISTORY_IDX=$count
    # Set current price as the last (most recent) price
    if [ $count -gt 0 ] && [ -n "${BTC_HISTORY[$((count-1))]}" ]; then
        BTC_CURRENT_PRICE=${BTC_HISTORY[$((count-1))]}
    fi
    log "Bitcoin: loaded $count days from API (min: \$$BTC_24H_MIN, max: \$$BTC_24H_MAX, current: \$$BTC_CURRENT_PRICE)"
    return 0
}

push_bitcoin_if_due() {
    local now=$(date +%s)
    local today=$(date +%Y%m%d)

    # Only update daily (once per day at most)
    if [ "$LAST_BTC_DAY" = "$today" ]; then
        return 0
    fi
    LAST_BTC_DAY="$today"

    # On first run, use current price from cache initialization
    # On subsequent days, try to fetch new price (but don't fail if API is rate-limited)
    if [ $BTC_CURRENT_PRICE -eq 0 ]; then
        # First run: use price 0 as signal to just send history
        log "Bitcoin: sending initial history data"
    else
        # Daily update: try to fetch new price
        local price_change
        price_change=$(read_bitcoin_price) 2>/dev/null
        if [ -n "$price_change" ]; then
            local price change24
            read -r price change24 <<< "$price_change"
            if [ -n "$price" ] && [ "$price" -gt 0 ]; then
                BTC_CURRENT_PRICE=$price
                BTC_24H_CHANGE=$change24
            fi
        fi
    fi

    # Update ring buffer with today's price if we have a new one
    if [ $BTC_CURRENT_PRICE -gt 0 ]; then
        BTC_HISTORY[$BTC_HISTORY_IDX]=$BTC_CURRENT_PRICE
        BTC_HISTORY_IDX=$(( (BTC_HISTORY_IDX + 1) % 180 ))

        # Track min/max over all collected samples.
        if [ $BTC_24H_MIN -eq 0 ] || [ $BTC_CURRENT_PRICE -lt $BTC_24H_MIN ]; then
            BTC_24H_MIN=$BTC_CURRENT_PRICE
        fi
        if [ $BTC_CURRENT_PRICE -gt $BTC_24H_MAX ]; then
            BTC_24H_MAX=$BTC_CURRENT_PRICE
        fi
    fi

    # Build the history array as JSON: downsample 180 → 20 points (1 every 9 days)
    # to keep payload well under ESP32 UART buffer limit (256 bytes default).
    local hist_json="["
    local count=0
    for i in {0..19}; do
        local src_idx=$(( i * 9 ))
        local idx=$(( (BTC_HISTORY_IDX + src_idx) % 180 ))
        if [ -n "${BTC_HISTORY[$idx]}" ] && [ "${BTC_HISTORY[$idx]}" -gt 0 ]; then
            [ $count -gt 0 ] && hist_json="$hist_json,"
            hist_json="$hist_json${BTC_HISTORY[$idx]}"
            (( count++ ))
        fi
    done
    hist_json="$hist_json]"

    local payload
    payload=$(printf '{"btc":{"price":%d,"min24":%d,"max24":%d,"change24":%d,"history":%s}}' \
        "$BTC_CURRENT_PRICE" "$BTC_24H_MIN" "$BTC_24H_MAX" "$BTC_24H_CHANGE" "$hist_json")

    log "Bitcoin: \$$BTC_CURRENT_PRICE (24h: $BTC_24H_CHANGE), history: $count days"
    send_line "$payload" || return 1
}

push_system_stats_if_due() {
    local now=$(date +%s)
    (( now - LAST_SYS_PUSH < SYS_PUSH_INTERVAL )) && return 0
    LAST_SYS_PUSH=$now

    local cpu ram disk temp gpu net
    cpu=$(read_cpu_pct)
    ram=$(read_ram_pct)
    disk=$(read_disk_pct)
    temp=$(read_temp_c)
    gpu=$(read_gpu_pct)
    net=$(read_net_kbps)

    send_line "{\"sys\":{\"cpu\":$cpu,\"ram\":$ram,\"disk\":$disk,\"temp\":$temp,\"gpu\":$gpu,\"net\":$net}}" || return 1
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

ACTIONS_DIR="$HOME/.config/clawdmeter"

# Spawn a child shell that reads firmware → host lines on FD 3 (inherited).
# Two firmware → host message types:
#   {"req":"poll"}   → touch $REQ_FLAG (main loop forces an API poll)
#   {"action":N}     → fork-and-run $ACTIONS_DIR/actionN.sh in background
start_reader() {
    rm -f "$REQ_FLAG"
    bash -c "
        while IFS= read -r l; do
            case \"\$l\" in
                *'\"req\":\"poll\"'*)
                    touch '$REQ_FLAG'
                    ;;
                *'\"action\":'*)
                    n=\$(echo \"\$l\" | grep -oE '\"action\":[0-9]+' | grep -oE '[0-9]+')
                    if [ -n \"\$n\" ]; then
                        script=\"$ACTIONS_DIR/action\$n.sh\"
                        if [ -x \"\$script\" ]; then
                            echo \"[\$(date '+%H:%M:%S')] Action \$n: launching \$script\"
                            bash \"\$script\" &
                        else
                            echo \"[\$(date '+%H:%M:%S')] Action \$n: \$script not found or not executable\"
                        fi
                    fi
                    ;;
            esac
        done <&3
    " &
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
BTC_HISTORY_INIT=0      # Flag: have we fetched 180 days of Bitcoin history?

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
        # Force re-push of Bitcoin data on reconnect (firmware may have rebooted).
        LAST_BTC_DAY=0
        # Initialize Bitcoin history once at startup.
        if [ $BTC_HISTORY_INIT -eq 0 ]; then
            init_bitcoin_history
            BTC_HISTORY_INIT=1
        fi
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

    push_system_stats_if_due || {
        close_port; DEVICE_PORT=""; sleep 5; continue
    }

    push_bitcoin_if_due || {
        close_port; DEVICE_PORT=""; sleep 5; continue
    }

    # Firmware asked for an immediate poll (gauges still "---" on its end).
    if [ -f "$REQ_FLAG" ]; then
        rm -f "$REQ_FLAG"
        log "Firmware requested immediate poll"
        LAST_API_POLL=0
        # Also re-push Bitcoin data — firmware likely just booted
        LAST_BTC_DAY=0
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
