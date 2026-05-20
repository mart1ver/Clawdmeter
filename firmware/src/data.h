#pragma once
#include <Arduino.h>

struct UsageData {
    float session_pct;       // 5-hour window utilization (0-100)
    int session_reset_mins;  // minutes until session resets
    float weekly_pct;        // 7-day window utilization (0-100)
    int weekly_reset_mins;   // minutes until weekly resets
    char status[16];         // "allowed" or "limited"
    char model[16];          // "opus" / "sonnet" / "haiku" / "default"
    char effort[16];         // "low" / "medium" / "high" / "max" / "default"
    bool ok;                 // data parse succeeded
    bool valid;              // false until first successful parse
};

// Host system telemetry pushed every ~2s by the daemon over USB.
// All percentages are 0-100; -1 means "not available".
#define MAX_CPU_CORES 16
#define MAX_GPUS      4
struct SystemStats {
    int cpu;                       // aggregate %
    int cpu_cores[MAX_CPU_CORES];  // per-core %, [0..cpu_core_count-1] valid
    int cpu_core_count;            // number of cores reported (capped at MAX)
    int ram;                       // %
    int disk;                      // % of root filesystem
    int temp;                      // CPU temperature in °C
    int gpu;                       // %, -1 if no GPU driver detected
    int vram;                      // %, -1 if no GPU; first GPU only
    int gpu_util[MAX_GPUS];        // per-GPU utilization %, [0..gpu_count-1]
    int gpu_vram[MAX_GPUS];        // per-GPU VRAM used %
    int gpu_count;                 // number of GPUs reported
    int net;                       // combined RX+TX in KB/s
    bool valid;                    // false until first push received
};

// Generic ticker (financial instrument) data pushed by the daemon.
// Used by the "Bitcoin" tab — now a generic price chart that can show any
// of: BTC/USD, BTC/EUR, BTC/RUB, EUR/USD, USD/EUR, EUR/RUB, RUB/EUR,
// USD/RUB, RUB/USD, XAU/EUR, XAG/EUR.
//
// All prices are sent as INTEGERS multiplied by 10^scale. The firmware
// divides by 10^scale at display time. This avoids float juggling in
// bash JSON construction and keeps the wire format compact.
//   scale=0: integer prices (BTC, gold/oz)
//   scale=2: 2-decimal (USD/RUB ≈ 71.49)
//   scale=4: 4-decimal (EUR/USD ≈ 1.1629)
struct BitcoinData {
    char name[12];          // display label, e.g. "BTC/USD", "EUR/USD", "XAU/EUR"
    char symbol[4];         // currency suffix, e.g. "$", "€", "₽"
    int  scale;             // decimal places for display (0..4)
    int  price;             // current price * 10^scale
    int  price_24h_min;     // period low * 10^scale
    int  price_24h_max;     // period high * 10^scale
    int  price_24h_change_bps; // change in basis points (0.01% units)
    int  price_history[20]; // downsampled history (oldest..newest), each * 10^scale
    int  history_count;     // how many samples are valid (0-20)
    bool valid;             // false until first push received
};
