# Clawdmeter — Panlee SC01 Plus / USB fork

Fork of [HermannBjorgvin/Clawdmeter](https://github.com/HermannBjorgvin/Clawdmeter) ported to the **Panlee SC01 Plus** (480×320 IPS) and switched from BLE to **USB CDC serial**.

A small ESP32-S3 dashboard for your desk that keeps an eye on Claude Code usage. The splash plays pixel-art Clawd animations that get busier when your usage rate climbs; the usage screen shows your 5-hour and 7-day rate-limit windows.

## What changed vs. the original

- **Display**: Waveshare ESP32-S3-Touch-AMOLED-2.16 (480×480 AMOLED, CO5300 QSPI) → **Panlee SC01 Plus** (480×320 IPS, ST7796 8-bit parallel)
- **Touch**: CST9220 → **FT6336U**
- **Transport**: BLE GATT → **USB CDC serial** (much simpler, no pairing, no bluez)
- **No hardware buttons, no PMU, no IMU, no battery** — full-touch UI
- **Two screens**: Splash ↔ Usage (the Bluetooth screen is gone)
- **Instant boot data**: firmware actively requests a poll on boot so the gauges populate in ~1 s instead of waiting up to 60 s
- **Instant model refresh**: daemon watches `~/.claude/settings.json` and pushes the model name within 2 s of a `/model` command
- **UI in French**: "Claude usage", "Session", "Hebdo", "Reset dans …"

## Hardware

- **[Panlee SC01 Plus](https://www.panlee.net/sc01-plus)** — ESP32-S3-WROOM-1, 3.5" 480×320 IPS (ST7796 8-bit parallel), FT6336U capacitive touch, USB-C
- USB-C cable

## Prerequisites

- Linux (tested on Ubuntu)
- [PlatformIO CLI](https://docs.platformio.org/en/latest/core/installation/index.html)
- `curl`, `awk`, `stty`
- Claude Code with an active subscription

## Install

### Flash the firmware

```bash
cd firmware
pio run -t upload --upload-port /dev/ttyACM0
```

The SC01 Plus enumerates as `/dev/ttyACMx` over its native USB JTAG — no boot-mode buttons needed.

### Install the daemon

```bash
./install.sh
systemctl --user start claude-usage-daemon-usb
```

The daemon auto-detects the serial port (`/dev/ttyACM*` / `/dev/ttyUSB*`), reads your OAuth token from `~/.claude/.credentials.json`, polls the Anthropic API every 60 s, and pushes a JSON line to the device.

```bash
systemctl --user status claude-usage-daemon-usb
journalctl --user -u claude-usage-daemon-usb -f
```

## How it works

1. The daemon reads the Claude Code OAuth token from `~/.claude/.credentials.json`.
2. It makes a minimal API call to `api.anthropic.com/v1/messages` (one Haiku token — basically free).
3. Rate-limit headers (`anthropic-ratelimit-unified-5h-utilization` & friends) become the gauge values.
4. The daemon writes a JSON line to `/dev/ttyACMx`; the firmware parses it and updates the LVGL UI.
5. The daemon also watches `~/.claude/settings.json` for `/model` changes and pushes a partial `{"m":"opus"}` payload within 2 s.
6. On boot the firmware emits `{"req":"poll"}` until gauge data arrives, so the screen fills in ~1 s instead of up to a minute.
7. Splash animations are picked from a mood group keyed off the rate of change of session %.

## USB protocol

The firmware reads newline-delimited JSON from its USB CDC endpoint. All fields are optional — missing fields keep the previous value, so the daemon can push partial updates (`{"m":"haiku"}`) without zeroing the gauges.

```json
{ "s": 45, "sr": 120, "w": 28, "wr": 7200, "st": "allowed", "m": "opus", "ok": true }
```

| Field | Meaning |
| --- | --- |
| `s`   | session (5 h) utilization %    |
| `sr`  | minutes until session reset    |
| `w`   | weekly (7 d) utilization %     |
| `wr`  | minutes until weekly reset     |
| `st`  | status (`allowed` / `limited`) |
| `m`   | model alias (`opus`, `sonnet`, `haiku`, `default`, …) |
| `ok`  | parse-success flag             |

The firmware emits a few short lines back:

| Line | When |
| --- | --- |
| `{"ready":true}` | boot |
| `{"ack":true}` / `{"err":true}` | after parsing a payload |
| `{"req":"poll"}` | boot, until gauges populate |
| `SCREENSHOT_START W H N` … `SCREENSHOT_END` | response to a `screenshot\n` command |

## Screenshots

The firmware ships a `screenshot` serial command that dumps the LVGL framebuffer. `./screenshot.sh out.png /dev/ttyACM0` captures a 480×320 PNG. Stop the daemon first (it owns the serial port).

## Recompiling fonts / icons / splash animations

Same tooling as upstream — see the [original README](https://github.com/HermannBjorgvin/Clawdmeter#recompiling-fonts) for `lv_font_conv` patching, Lucide PNG conversion, and the claudepix scraping pipeline.

## Credits

- Original Clawdmeter by [Hermann Björgvin](https://github.com/HermannBjorgvin).
- Pixel-art Clawd animation by [@amaanbuilds](https://x.com/amaanbuilds), sourced from [claudepix.vercel.app](https://claudepix.vercel.app).
- Lucide icon set ([lucide.dev](https://lucide.dev), MIT).
- Anthropic brand fonts (Tiempos Text, Styrene B) — see the licensing warning below.

## Licensing gray area warning

Inherited from upstream: this repo bundles Anthropic brand fonts and the copyrighted Clawd mascot. The code is non-proprietary but the assets are not redistributable under a copyleft license. **You have been warned!**
