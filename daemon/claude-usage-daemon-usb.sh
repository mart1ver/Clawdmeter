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

# ============================================================================
# Tickers — generic financial-instrument quotes (forex, crypto, metals)
# ============================================================================
# Tap on the Bitcoin tab's chart cycles through TICKER_IDS (see start_reader
# below for the "ticker_next" message). Each ticker has a cache file at
# ~/.cache/clawdmeter-ticker-<id>.json (one scaled-integer price per line).

TICKER_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
TICKER_CACHE_TTL=86400      # seconds (24h)
TICKER_SWITCH_FLAG="${XDG_RUNTIME_DIR:-/tmp}/clawd-ticker-next"

# Cycle order. Append more IDs here to add tickers.
TICKER_IDS=(btc_usd btc_eur btc_rub eur_usd usd_eur eur_rub rub_eur usd_rub rub_usd xau_eur xag_eur)

# Per-ticker metadata (name shown in header / price decimal scale).
# Symbol = ASCII prefix on the price; empty when the pair name already
# communicates the currency unambiguously.
declare -A TICKER_NAME=(
    [btc_usd]="BTC/USD" [btc_eur]="BTC/EUR" [btc_rub]="BTC/RUB"
    [eur_usd]="EUR/USD" [usd_eur]="USD/EUR" [eur_rub]="EUR/RUB" [rub_eur]="RUB/EUR"
    [usd_rub]="USD/RUB" [rub_usd]="RUB/USD"
    [xau_eur]="GOLD/EUR" [xag_eur]="SILVER/EUR"
)
declare -A TICKER_SYMBOL=(
    [btc_usd]="\$"  [btc_eur]=""   [btc_rub]=""
    [eur_usd]="\$"  [usd_eur]=""   [eur_rub]=""   [rub_eur]=""
    [usd_rub]=""   [rub_usd]="\$"
    [xau_eur]=""   [xag_eur]=""
)
# Decimal scale: digits after the point. Price is sent as integer * 10^scale.
declare -A TICKER_SCALE=(
    [btc_usd]=0 [btc_eur]=0 [btc_rub]=0
    [eur_usd]=4 [usd_eur]=4 [eur_rub]=2 [rub_eur]=4
    [usd_rub]=2 [rub_usd]=4
    [xau_eur]=0 [xag_eur]=2
)

ACTIVE_TICKER="btc_usd"
ACTIVE_TICKER_IDX=0
declare -a TICKER_HISTORY    # ring buffer of up to 180 scaled prices
TICKER_HISTORY_IDX=0
TICKER_CURRENT=0
TICKER_MIN=0
TICKER_MAX=0
TICKER_CHANGE_BPS=0
LAST_TICKER_PUSH_DAY=""

ticker_cache_file() { echo "$TICKER_CACHE_DIR/clawdmeter-ticker-$1.json"; }

# Fetch 180 days of BTC prices in `vs_currency`, scaled by 10^scale.
# Echos one price per line (oldest first).
fetch_coingecko_btc_history() {
    local vs="$1" scale="$2" json
    json=$(curl -s "https://api.coingecko.com/api/v3/coins/bitcoin/market_chart?vs_currency=${vs}&days=180&interval=daily" 2>/dev/null) || return 1
    echo "$json" | sed 's/"prices":\[\[//' | sed 's/\]\],"market_caps".*//' | \
        grep -o '\[[0-9]*,[0-9.]*\]' | \
        awk -v s="$scale" '
            BEGIN { mul = 1; for (i=0; i<s; i++) mul *= 10 }
            { gsub(/[\[\]]/, "")
              split($0, p, ",")
              printf "%.0f\n", p[2] * mul }'
}

# Fetch a Yahoo Finance daily history (6mo). Echos scaled integer prices.
fetch_yahoo_history() {
    local sym="$1" scale="$2"
    curl -sL -A "Mozilla/5.0" \
        "https://query1.finance.yahoo.com/v8/finance/chart/${sym}?interval=1d&range=6mo" \
        2>/dev/null | \
    python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    r = d['chart']['result'][0]
    closes = r['indicators']['quote'][0]['close']
    mul = 10 ** int(sys.argv[1])
    for c in closes:
        if c is not None:
            print(int(round(c * mul)))
except Exception:
    sys.exit(1)
" "$scale" 2>/dev/null
}

# Fetch XAU or XAG priced in EUR by combining Yahoo's USD price with EUR/USD.
fetch_yahoo_metal_in_eur() {
    local metal_sym="$1" scale="$2"
    # USD prices at scale 4 for accuracy during the EUR conversion
    local usd_prices eur_per_usd
    usd_prices=$(fetch_yahoo_history "$metal_sym" 4) || return 1
    eur_per_usd=$(curl -sL -A "Mozilla/5.0" \
        "https://query1.finance.yahoo.com/v8/finance/chart/EURUSD=X?interval=1d&range=1d" 2>/dev/null | \
        python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['chart']['result'][0]['meta']['regularMarketPrice'])
except:
    sys.exit(1)
" 2>/dev/null)
    [ -z "$eur_per_usd" ] && return 1
    # eur_price = usd_price / eur_per_usd, rescaled to requested `scale`
    echo "$usd_prices" | awk -v rate="$eur_per_usd" -v s="$scale" '
        BEGIN { out_mul = 1; for (i=0; i<s; i++) out_mul *= 10 }
        { printf "%.0f\n", ($1 / 10000) / rate * out_mul }'
}

# Dispatch table: fetch the 180-day history for any ticker.
fetch_ticker_history() {
    local id="$1" scale="${TICKER_SCALE[$id]:-0}"
    case "$id" in
        btc_usd) fetch_coingecko_btc_history usd "$scale" ;;
        btc_eur) fetch_coingecko_btc_history eur "$scale" ;;
        btc_rub) fetch_coingecko_btc_history rub "$scale" ;;
        eur_usd) fetch_yahoo_history "EURUSD=X" "$scale" ;;
        usd_eur) fetch_yahoo_history "USDEUR=X" "$scale" ;;
        eur_rub) fetch_yahoo_history "EURRUB=X" "$scale" ;;
        rub_eur) fetch_yahoo_history "EURRUB=X" "$scale" \
                   | awk -v s="$scale" 'BEGIN { mul = 1; for (i=0; i<s; i++) mul *= 10 }
                                        { if ($1 > 0) printf "%.0f\n", (mul * mul) / $1 }' ;;
        usd_rub) fetch_yahoo_history "USDRUB=X" "$scale" ;;
        rub_usd) fetch_yahoo_history "RUBUSD=X" "$scale" ;;
        xau_eur) fetch_yahoo_metal_in_eur "GC=F" "$scale" ;;
        xag_eur) fetch_yahoo_metal_in_eur "SI=F" "$scale" ;;
        *) return 1 ;;
    esac
}

# Load ticker prices from its cache file into TICKER_HISTORY[].
ticker_load_from_cache() {
    local id="$1" cache; cache=$(ticker_cache_file "$id")
    [ -f "$cache" ] || return 1
    TICKER_HISTORY=()
    TICKER_MIN=0; TICKER_MAX=0
    local count=0 price
    while IFS= read -r price; do
        [ -z "$price" ] || [ "$price" -le 0 ] 2>/dev/null && continue
        TICKER_HISTORY[$count]=$price
        if [ $TICKER_MIN -eq 0 ] || [ $price -lt $TICKER_MIN ]; then TICKER_MIN=$price; fi
        if [ $price -gt $TICKER_MAX ]; then TICKER_MAX=$price; fi
        (( count++ ))
        [ $count -ge 180 ] && break
    done < "$cache"
    [ $count -eq 0 ] && return 1
    TICKER_HISTORY_IDX=$count
    TICKER_CURRENT=${TICKER_HISTORY[$((count-1))]}
    return 0
}

# Fetch fresh data via the dispatch table, write to cache, populate globals.
ticker_fetch_from_api() {
    local id="$1" cache; cache=$(ticker_cache_file "$id")
    log "Ticker $id: fetching from network..."
    local prices
    prices=$(fetch_ticker_history "$id") || { log "Ticker $id: fetch failed"; return 1; }
    local tmp="$cache.tmp"
    : > "$tmp"
    TICKER_HISTORY=()
    TICKER_MIN=0; TICKER_MAX=0
    local count=0 price
    while IFS= read -r price; do
        [ -z "$price" ] || [ "$price" -le 0 ] 2>/dev/null && continue
        TICKER_HISTORY[$count]=$price
        echo "$price" >> "$tmp"
        if [ $TICKER_MIN -eq 0 ] || [ $price -lt $TICKER_MIN ]; then TICKER_MIN=$price; fi
        if [ $price -gt $TICKER_MAX ]; then TICKER_MAX=$price; fi
        (( count++ ))
        [ $count -ge 180 ] && break
    done <<< "$prices"
    if [ $count -lt 10 ]; then
        log "Ticker $id: only $count prices — keeping old cache"
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$cache"
    TICKER_HISTORY_IDX=$count
    TICKER_CURRENT=${TICKER_HISTORY[$((count-1))]}
    log "Ticker $id: $count days loaded, current=$TICKER_CURRENT (min=$TICKER_MIN, max=$TICKER_MAX)"
    return 0
}

# Prefer fresh API data once per 24h; fall back to cache when API down.
load_ticker() {
    local id="$1" cache; cache=$(ticker_cache_file "$id")
    local cache_age=$TICKER_CACHE_TTL now; now=$(date +%s)
    if [ -f "$cache" ]; then
        local mt; mt=$(stat -c %Y "$cache" 2>/dev/null) || mt=0
        cache_age=$(( now - mt ))
    fi
    if (( cache_age < TICKER_CACHE_TTL )); then
        ticker_load_from_cache "$id" && return 0
    fi
    ticker_fetch_from_api "$id" && return 0
    log "Ticker $id: API unreachable, falling back to stale cache"
    ticker_load_from_cache "$id"
}

# 24h change = relative delta between the two most recent samples, in basis
# points (1 bp = 0.01%).
compute_change_bps() {
    local n=$TICKER_HISTORY_IDX
    (( n < 2 )) && { TICKER_CHANGE_BPS=0; return; }
    local newest=${TICKER_HISTORY[$((n-1))]}
    local prev=${TICKER_HISTORY[$((n-2))]}
    [ -z "$newest" ] || [ -z "$prev" ] || (( prev <= 0 )) && { TICKER_CHANGE_BPS=0; return; }
    TICKER_CHANGE_BPS=$(( ( (newest - prev) * 10000 ) / prev ))
}

# Build downsampled-20 history and push to firmware.
push_ticker() {
    local id="$ACTIVE_TICKER"
    [ -z "${TICKER_NAME[$id]}" ] && return 1
    compute_change_bps

    # Downsample N history entries to 20 evenly-spaced points (oldest first).
    # Entries are at ring[0..N-1] with N = TICKER_HISTORY_IDX (partial-fill,
    # no wraparound yet; daemon would need 180 days uptime to wrap).
    local hist_json="[" count=0 i idx total=$TICKER_HISTORY_IDX
    (( total > 180 )) && total=180
    if (( total < 2 )); then
        hist_json="[$TICKER_CURRENT]"
    else
        for i in {0..19}; do
            idx=$(( i * (total - 1) / 19 ))
            if [ -n "${TICKER_HISTORY[$idx]}" ] && [ "${TICKER_HISTORY[$idx]}" -gt 0 ]; then
                [ $count -gt 0 ] && hist_json="$hist_json,"
                hist_json="$hist_json${TICKER_HISTORY[$idx]}"
                (( count++ ))
            fi
        done
        hist_json="$hist_json]"
    fi

    local name="${TICKER_NAME[$id]}"
    local sym="${TICKER_SYMBOL[$id]}"
    local scl="${TICKER_SCALE[$id]:-0}"
    local payload
    payload=$(printf '{"btc":{"name":"%s","sym":"%s","scl":%d,"price":%d,"min24":%d,"max24":%d,"change24":%d,"history":%s}}' \
        "$name" "$sym" "$scl" "$TICKER_CURRENT" "$TICKER_MIN" "$TICKER_MAX" "$TICKER_CHANGE_BPS" "$hist_json")

    log "Ticker $id [$name]: $TICKER_CURRENT (24h: $TICKER_CHANGE_BPS bps, history: $count pts)"
    send_line "$payload" || return 1
}

# Advance ACTIVE_TICKER → next in TICKER_IDS, load, push.
switch_to_next_ticker() {
    ACTIVE_TICKER_IDX=$(( (ACTIVE_TICKER_IDX + 1) % ${#TICKER_IDS[@]} ))
    ACTIVE_TICKER="${TICKER_IDS[$ACTIVE_TICKER_IDX]}"
    log "→ Switching ticker to $ACTIVE_TICKER"
    load_ticker "$ACTIVE_TICKER" || { log "Failed to load $ACTIVE_TICKER"; return 1; }
    push_ticker
}

# Daily refresh of the active ticker.
push_ticker_if_due() {
    local today; today=$(date +%Y%m%d)
    [ "$LAST_TICKER_PUSH_DAY" = "$today" ] && return 0
    LAST_TICKER_PUSH_DAY="$today"
    push_ticker
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
#   {"req":"poll"}        → touch $REQ_FLAG (main loop forces an API poll)
#   {"req":"ticker_next"} → touch $TICKER_SWITCH_FLAG (main loop cycles ticker)
#   {"action":N}          → fork-and-run $ACTIONS_DIR/actionN.sh in background
start_reader() {
    rm -f "$REQ_FLAG" "$TICKER_SWITCH_FLAG"
    bash -c "
        while IFS= read -r l; do
            case \"\$l\" in
                *'\"req\":\"poll\"'*)
                    touch '$REQ_FLAG'
                    ;;
                *'\"req\":\"ticker_next\"'*)
                    touch '$TICKER_SWITCH_FLAG'
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
TICKER_INIT=0           # Flag: have we loaded the active ticker yet?

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
        # Force re-push of active ticker on reconnect (firmware may have rebooted).
        LAST_TICKER_PUSH_DAY=""
        # Initialize the active ticker once at startup.
        if [ $TICKER_INIT -eq 0 ]; then
            load_ticker "$ACTIVE_TICKER" && TICKER_INIT=1
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

    push_ticker_if_due || {
        close_port; DEVICE_PORT=""; sleep 5; continue
    }

    # Firmware asked for an immediate poll (gauges still "---" on its end).
    if [ -f "$REQ_FLAG" ]; then
        rm -f "$REQ_FLAG"
        log "Firmware requested immediate poll"
        LAST_API_POLL=0
        # Also re-push ticker data — firmware likely just booted
        LAST_TICKER_PUSH_DAY=""
    fi

    # Firmware tapped on the chart → cycle to the next ticker
    if [ -f "$TICKER_SWITCH_FLAG" ]; then
        rm -f "$TICKER_SWITCH_FLAG"
        switch_to_next_ticker || true
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
