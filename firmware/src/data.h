#pragma once
#include <Arduino.h>

struct UsageData {
    float session_pct;       // 5-hour window utilization (0-100)
    int session_reset_mins;  // minutes until session resets
    float weekly_pct;        // 7-day window utilization (0-100)
    int weekly_reset_mins;   // minutes until weekly resets
    char status[16];         // "allowed" or "limited"
    char model[16];          // "opus" / "sonnet" / "haiku" / "default"
    bool ok;                 // data parse succeeded
    bool valid;              // false until first successful parse
};

// Host system telemetry pushed every ~2s by the daemon over USB.
// All percentages are 0-100; -1 means "not available".
struct SystemStats {
    int cpu;        // %
    int ram;        // %
    int disk;       // % of root filesystem
    int temp;       // CPU temperature in °C
    int gpu;        // %, -1 if no GPU driver detected
    int net;        // combined RX+TX in KB/s
    bool valid;     // false until first push received
};

// Bitcoin price data pushed by the daemon over USB.
// price_history is downsampled to 20 points (1 per ~9 days over 6 months)
// to keep the JSON payload under the ESP32 default UART RX buffer (256 bytes).
struct BitcoinData {
    int price;      // current price in USD (integer)
    int price_24h_min;   // 24h low
    int price_24h_max;   // 24h high
    int price_24h_change_bps; // 24h change in basis points (0.01% units, e.g., 19 = 0.19%)
    int price_history[20];  // downsampled samples (oldest first), -1 means no data
    int history_count;   // how many samples are valid (0-20)
    bool valid;     // false until first push received
};
