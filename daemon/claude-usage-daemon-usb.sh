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

CPU_PCT=0
# Delta-based — sets global CPU_PCT (NOT echoed) so PREV_CPU_* persist
# across calls. Calling via cpu=$(read_cpu_pct) would run in a subshell
# where PREV updates are lost, making every call return the since-boot
# average instead of the real-time %.
read_cpu_pct() {
    local f1 f2 f3 f4 f5 f6 f7 f8 total idle d_total d_idle
    read -r _ f1 f2 f3 f4 f5 f6 f7 f8 _ < /proc/stat
    idle=$(( f4 + f5 ))               # idle + iowait
    total=$(( f1 + f2 + f3 + f4 + f5 + f6 + f7 + f8 ))
    d_total=$(( total - PREV_CPU_TOTAL ))
    d_idle=$(( idle  - PREV_CPU_IDLE  ))
    PREV_CPU_TOTAL=$total
    PREV_CPU_IDLE=$idle
    if (( d_total <= 0 )); then CPU_PCT=0; return; fi
    CPU_PCT=$(( ( (d_total - d_idle) * 100 ) / d_total ))
    (( CPU_PCT < 0 )) && CPU_PCT=0
    (( CPU_PCT > 100 )) && CPU_PCT=100
}

# Per-core CPU percentages. Reads cpu0..cpuN lines from /proc/stat and
# computes per-core deltas. Populates global arrays CPU_CORE_PCT[0..N-1]
# and CPU_CORE_COUNT. Same subshell-avoidance pattern as read_cpu_pct.
declare -a PREV_CORE_TOTAL
declare -a PREV_CORE_IDLE
declare -a CPU_CORE_PCT
CPU_CORE_COUNT=0
read_cpu_per_core() {
    local cpu_name f1 f2 f3 f4 f5 f6 f7 f8 total idle d_total d_idle pct i=0
    while read -r cpu_name f1 f2 f3 f4 f5 f6 f7 f8 _; do
        # Match "cpu0", "cpu1", etc. (skip the aggregate "cpu" line)
        [[ "$cpu_name" =~ ^cpu[0-9]+$ ]] || continue
        idle=$(( f4 + f5 ))
        total=$(( f1 + f2 + f3 + f4 + f5 + f6 + f7 + f8 ))
        d_total=$(( total - ${PREV_CORE_TOTAL[$i]:-0} ))
        d_idle=$((  idle - ${PREV_CORE_IDLE[$i]:-0}  ))
        PREV_CORE_TOTAL[$i]=$total
        PREV_CORE_IDLE[$i]=$idle
        if (( d_total <= 0 )); then
            CPU_CORE_PCT[$i]=0
        else
            pct=$(( ( (d_total - d_idle) * 100 ) / d_total ))
            (( pct < 0 )) && pct=0
            (( pct > 100 )) && pct=100
            CPU_CORE_PCT[$i]=$pct
        fi
        (( i++ ))
    done < /proc/stat
    CPU_CORE_COUNT=$i
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

# Disk I/O throughput (read + write) across all whole-disk devices, in KB/s.
# Reads sectors_read + sectors_written from /sys/block/<dev>/stat (same
# fields as /proc/diskstats but easier to enumerate). Skips loopback,
# ramdisks, device-mapper, optical, zram. Uses globals (PREV_DISK_*) so
# the delta calculation survives the subshell pattern — same as CPU/NET.
PREV_DISK_SECTORS=0
PREV_DISK_TIME_MS=0
DISK_KBPS=0
read_disk_kbps() {
    local total=0 sysblk name r w now_ms d_t d_sec
    for sysblk in /sys/block/*; do
        name=$(basename "$sysblk")
        case "$name" in loop*|ram*|dm-*|sr*|zram*) continue ;; esac
        [ -r "$sysblk/stat" ] || continue
        # /sys/block/<dev>/stat layout (man iostat):
        #   field 0 = reads completed       1 = reads merged
        #   field 2 = sectors read          3 = time reading (ms)
        #   field 4 = writes completed      5 = writes merged
        #   field 6 = sectors written       ...
        read -r _ _ r _ _ _ w _ < "$sysblk/stat"
        total=$(( total + r + w ))
    done
    now_ms=$(date +%s%3N)
    if (( PREV_DISK_TIME_MS == 0 )); then
        PREV_DISK_SECTORS=$total
        PREV_DISK_TIME_MS=$now_ms
        DISK_KBPS=0
        return
    fi
    d_t=$(( now_ms - PREV_DISK_TIME_MS ))
    (( d_t <= 0 )) && { DISK_KBPS=0; return; }
    d_sec=$(( total - PREV_DISK_SECTORS ))
    PREV_DISK_SECTORS=$total
    PREV_DISK_TIME_MS=$now_ms
    # 1 sector = 512 bytes (Linux kernel convention, NOT hw sector size).
    # KB/s = (sectors * 512 / 1024) * (1000 / d_t_ms) = sectors * 500 / d_t
    DISK_KBPS=$(( (d_sec * 500) / d_t ))
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

# Per-GPU utilization + VRAM. Populates GPU_UTIL[] and GPU_VRAM[] (% of
# total VRAM) and GPU_COUNT. nvtop-style snapshot. Uses globals (NOT
# echoed) so multi-GPU systems get all values populated.
declare -a GPU_UTIL
declare -a GPU_VRAM
GPU_COUNT=0
read_gpu_info() {
    GPU_COUNT=0
    if command -v nvidia-smi >/dev/null 2>&1; then
        local line util mem_used mem_total vram_pct i=0
        while IFS=$', \t' read -r util mem_used mem_total; do
            [ -z "$util" ] && continue
            vram_pct=0
            [ -n "$mem_total" ] && [ "$mem_total" -gt 0 ] && \
                vram_pct=$(( mem_used * 100 / mem_total ))
            GPU_UTIL[$i]=$util
            GPU_VRAM[$i]=$vram_pct
            (( i++ ))
        done < <(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null)
        GPU_COUNT=$i
        return 0
    fi
    # Fallback (no VRAM info): scan sysfs
    local c
    for c in /sys/class/drm/card*/device/gpu_busy_percent; do
        [ -r "$c" ] || continue
        GPU_UTIL[$GPU_COUNT]=$(cat "$c" 2>/dev/null)
        GPU_VRAM[$GPU_COUNT]=-1
        (( GPU_COUNT++ ))
    done
}

NET_KBPS=0
# Delta-based — sets global NET_KBPS (NOT echoed) for the same subshell
# reason as read_cpu_pct above. Calling via net=$(read_net_kbps) would
# wipe PREV_NET_* each call and the function would always return 0.
read_net_kbps() {
    local rx tx now_ms d_t d_rx d_tx
    read -r rx tx < <(awk -F'[: ]+' '
        /^[[:space:]]*lo:/ { next }
        /:/ { sum_rx += $3; sum_tx += $11 }
        END { print sum_rx+0, sum_tx+0 }
    ' /proc/net/dev)
    now_ms=$(date +%s%3N)
    if (( PREV_NET_TIME_MS == 0 )); then
        PREV_NET_RX=$rx; PREV_NET_TX=$tx; PREV_NET_TIME_MS=$now_ms
        NET_KBPS=0; return
    fi
    d_t=$(( now_ms - PREV_NET_TIME_MS ))
    (( d_t <= 0 )) && { NET_KBPS=0; return; }
    d_rx=$(( rx - PREV_NET_RX ))
    d_tx=$(( tx - PREV_NET_TX ))
    PREV_NET_RX=$rx; PREV_NET_TX=$tx; PREV_NET_TIME_MS=$now_ms
    # KB/s = (bytes / 1024) * (1000 / ms)
    NET_KBPS=$(( ( (d_rx + d_tx) * 1000 ) / (1024 * d_t) ))
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

# Try fetching fresh 180-day history from CoinGecko API. Populates the ring
# buffer + writes a fresh cache file. Returns 0 on success, 1 on API failure.
btc_fetch_from_api() {
    log "Bitcoin: fetching 180 days of history from CoinGecko API..."
    local prices
    prices=$(read_bitcoin_history) || { log "Bitcoin history fetch failed (rate limit?)"; return 1; }

    # Atomically replace the cache file
    local tmp="$BTC_CACHE_FILE.tmp"
    : > "$tmp"
    local count=0
    BTC_24H_MIN=0
    BTC_24H_MAX=0
    while IFS= read -r price; do
        [ -z "$price" ] || [ "$price" -eq 0 ] && continue
        BTC_HISTORY[$count]=$price
        echo "$price" >> "$tmp"
        if [ $BTC_24H_MIN -eq 0 ] || [ $price -lt $BTC_24H_MIN ]; then BTC_24H_MIN=$price; fi
        if [ $price -gt $BTC_24H_MAX ]; then BTC_24H_MAX=$price; fi
        (( count++ ))
        [ $count -ge 180 ] && break
    done <<< "$prices"

    if [ $count -lt 30 ]; then
        log "Bitcoin: API returned too few prices ($count) — keeping old cache"
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$BTC_CACHE_FILE"
    BTC_HISTORY_IDX=$count
    [ -n "${BTC_HISTORY[$((count-1))]}" ] && BTC_CURRENT_PRICE=${BTC_HISTORY[$((count-1))]}
    log "Bitcoin: loaded $count days from API (min: \$$BTC_24H_MIN, max: \$$BTC_24H_MAX, current: \$$BTC_CURRENT_PRICE)"
    return 0
}

btc_load_from_cache() {
    [ -f "$BTC_CACHE_FILE" ] || return 1
    log "Bitcoin: loading history from cache..."
    local count=0
    BTC_24H_MIN=0
    BTC_24H_MAX=0
    while IFS= read -r price; do
        [ -z "$price" ] || [ "$price" -eq 0 ] && continue
        BTC_HISTORY[$count]=$price
        if [ $BTC_24H_MIN -eq 0 ] || [ $price -lt $BTC_24H_MIN ]; then BTC_24H_MIN=$price; fi
        if [ $price -gt $BTC_24H_MAX ]; then BTC_24H_MAX=$price; fi
        (( count++ ))
        [ $count -ge 180 ] && break
    done < "$BTC_CACHE_FILE"

    [ $count -eq 0 ] && return 1
    BTC_HISTORY_IDX=$count
    [ -n "${BTC_HISTORY[$((count-1))]}" ] && BTC_CURRENT_PRICE=${BTC_HISTORY[$((count-1))]}
    log "Bitcoin: loaded $count days from cache (min: \$$BTC_24H_MIN, max: \$$BTC_24H_MAX, current: \$$BTC_CURRENT_PRICE)"
    return 0
}

# One-time initialization: prefer fresh API data; fall back to cache if API
# fails or cache is still fresh (< 24h old). Avoids hammering CoinGecko on
# every daemon restart while keeping data current.
BTC_CACHE_TTL=86400   # seconds — re-fetch when cache is older than this
init_bitcoin_history() {
    local now=$(date +%s)
    local cache_age=$BTC_CACHE_TTL
    if [ -f "$BTC_CACHE_FILE" ]; then
        local cache_mtime
        cache_mtime=$(stat -c %Y "$BTC_CACHE_FILE" 2>/dev/null) || cache_mtime=0
        cache_age=$(( now - cache_mtime ))
    fi

    if (( cache_age < BTC_CACHE_TTL )); then
        log "Bitcoin: cache is $((cache_age/3600))h old, using it (< 24h TTL)"
        btc_load_from_cache && return 0
    fi

    # Cache is stale OR missing OR couldn't be loaded → try API
    btc_fetch_from_api && return 0

    # API failed → fall back to whatever cache we have, even if stale
    log "Bitcoin: API unreachable, falling back to cache"
    btc_load_from_cache
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

    # Build downsampled history: 180 → 20 points, evenly spaced from oldest
    # to NEWEST. The previous version used stride=9 which capped at index
    # 171 and never included the current price → chart looked frozen and
    # didn't match the displayed "$X" headline.
    # Formula: i * 179 / 19 (integer math) gives 0, 9, 18, ..., 169, 179
    # — last sample is index 179 = newest = today's price.
    local hist_json="["
    local count=0
    for i in {0..19}; do
        local src_offset=$(( i * 179 / 19 ))
        local idx=$(( (BTC_HISTORY_IDX + src_offset) % 180 ))
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

    local ram temp
    # CPU + NET + DISK use globals (CPU_PCT, NET_KBPS, DISK_KBPS) to keep
    # PREV_* alive across calls — see read_cpu_pct for why.
    read_cpu_pct
    read_cpu_per_core
    read_net_kbps
    read_disk_kbps
    read_gpu_info
    ram=$(read_ram_pct)
    temp=$(read_temp_c)

    # Build per-core CPU JSON array: [c0,c1,...,cN]
    local cpus_json="["
    local i
    for (( i=0; i<CPU_CORE_COUNT; i++ )); do
        [ $i -gt 0 ] && cpus_json="$cpus_json,"
        cpus_json="$cpus_json${CPU_CORE_PCT[$i]:-0}"
    done
    cpus_json="$cpus_json]"

    # Aggregate GPU util + VRAM (first GPU; firmware shows per-GPU bars
    # when an array is sent — see "gpus" array below for that)
    local gpu_main=-1 vram_main=-1
    if (( GPU_COUNT > 0 )); then
        gpu_main=${GPU_UTIL[0]}
        vram_main=${GPU_VRAM[0]}
    fi

    # Per-GPU array (util + vram pairs): [[u0,v0],[u1,v1],...]
    local gpus_json="["
    for (( i=0; i<GPU_COUNT; i++ )); do
        [ $i -gt 0 ] && gpus_json="$gpus_json,"
        gpus_json="$gpus_json[${GPU_UTIL[$i]:-0},${GPU_VRAM[$i]:-0}]"
    done
    gpus_json="$gpus_json]"

    # "disk" now means KB/s of disk I/O (read+write), no longer % full.
    # Firmware formats it like NET (KB/s under 1 MB/s, MB/s above).
    send_line "{\"sys\":{\"cpu\":$CPU_PCT,\"cpus\":$cpus_json,\"ram\":$ram,\"disk\":$DISK_KBPS,\"temp\":$temp,\"gpu\":$gpu_main,\"vram\":$vram_main,\"gpus\":$gpus_json,\"net\":$NET_KBPS}}" || return 1
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

# Find the most recently active Claude Code session log (one jsonl per
# session under ~/.claude/projects/). Echos the path, or empty if none.
active_session_jsonl() {
    find "$HOME/.claude/projects" -maxdepth 2 -name "*.jsonl" -printf "%T@ %p\n" 2>/dev/null \
        | sort -n | tail -1 | awk '{print $2}'
}

# Read the current effort level. Strategy:
#   1. Tail the active session jsonl for the LAST "Set effort level to X"
#      local-command-stdout marker. Catches every /effort change including
#      "this session only" levels (max) that don't touch settings.json.
#   2. If no session log found, fall back to settings.json:effortLevel
#      (the persistent baseline).
read_effort() {
    local jsonl from_session
    jsonl=$(active_session_jsonl)
    if [ -n "$jsonl" ] && [ -r "$jsonl" ]; then
        # Scan last ~500KB of the log only (the file can be many MB)
        from_session=$(tail -c 500000 "$jsonl" 2>/dev/null \
            | grep -oE "Set effort level to [a-z]+" \
            | tail -1 | awk '{print $5}')
        if [ -n "$from_session" ]; then
            echo "$from_session"
            return
        fi
    fi

    # Fallback: persistent baseline from settings.json
    local raw
    raw=$(grep -oE '"effortLevel"[[:space:]]*:[[:space:]]*"[^"]*"' "$HOME/.claude/settings.json" 2>/dev/null \
          | head -1 | sed -E 's/.*"([^"]*)"[^"]*$/\1/')
    [ -z "$raw" ] && raw="default"
    echo "$raw"
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

    local model effort
    model=$(read_model)
    effort=$(read_effort)

    local payload
    payload=$(awk -v u5="$s5h_util" -v r5="$s5h_reset" -v u7="$s7d_util" -v r7="$s7d_reset" -v st="$status" -v m="$model" -v e="$effort" -v now="$now" \
        'BEGIN {
            sp = sprintf("%.0f", u5 * 100);
            sr = (r5 - now) / 60; sr = sr > 0 ? sprintf("%.0f", sr) : 0;
            wp = sprintf("%.0f", u7 * 100);
            wr = (r7 - now) / 60; wr = wr > 0 ? sprintf("%.0f", wr) : 0;
            printf "{\"s\":%s,\"sr\":%s,\"w\":%s,\"wr\":%s,\"st\":\"%s\",\"m\":\"%s\",\"e\":\"%s\",\"ok\":true}", sp, sr, wp, wr, st, m, e;
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
TICK=2                  # inner-loop cadence for model + effort watcher
LAST_API_POLL=0
LAST_SETTINGS_MTIME=0   # mtime of settings.json — shared by model+effort watch
LAST_MODEL=""
LAST_EFFORT=""
BTC_HISTORY_INIT=0      # Flag: have we fetched 180 days of Bitcoin history?

# Push partial JSON when model or effort changes. Two different cadences:
#   • Model lives in settings.json → watched via mtime (cheap, instant)
#   • Effort can come from session jsonl (for "this session only" /effort
#     levels like max) → re-checked every TICK regardless of file changes,
#     since the session log can update without modifying settings.json
# Firmware treats missing JSON fields as "keep previous value" so this
# leaves the gauges untouched.
push_settings_if_changed() {
    [ -f "$SETTINGS_FILE" ] || return 0

    # Model: only re-read when settings.json mtime changes
    local mtime m
    mtime=$(stat -c %Y "$SETTINGS_FILE" 2>/dev/null) || mtime=0
    if [ "$mtime" != "$LAST_SETTINGS_MTIME" ]; then
        LAST_SETTINGS_MTIME="$mtime"
        m=$(read_model)
        if [ "$m" != "$LAST_MODEL" ]; then
            log "Model changed: ${LAST_MODEL:-?} → $m"
            LAST_MODEL="$m"
            send_line "{\"m\":\"$m\"}" || return 1
        fi
    fi

    # Effort: re-read every tick (the session jsonl updates without
    # touching settings.json when /effort is session-only)
    local e
    e=$(read_effort)
    if [ "$e" != "$LAST_EFFORT" ]; then
        log "Effort changed: ${LAST_EFFORT:-?} → $e"
        LAST_EFFORT="$e"
        send_line "{\"e\":\"$e\"}" || return 1
    fi
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
        # Force re-push of model + effort on reconnect.
        LAST_SETTINGS_MTIME=0
        LAST_MODEL=""
        LAST_EFFORT=""
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

    push_settings_if_changed || {
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
