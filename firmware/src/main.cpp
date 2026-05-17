#include <Arduino.h>
#include <lvgl.h>
#include <ArduinoJson.h>
#include "display_cfg.h"
#include "data.h"
#include "ui.h"
#include "power.h"
#include "imu.h"
#include "splash.h"
#include "usage_rate.h"

// Panlee SC01 Plus: no physical buttons, full-touch UI. Usage data arrives
// over USB serial (see process_usb_json below) — no BLE on this build.

// ---- Hardware objects ----
Arduino_DataBus *bus = new Arduino_ESP32LCD8(
    LCD_DC, LCD_CS, LCD_WR, LCD_RD,
    LCD_D0, LCD_D1, LCD_D2, LCD_D3,
    LCD_D4, LCD_D5, LCD_D6, LCD_D7);
Arduino_ST7796 *gfx = new Arduino_ST7796(
    bus, LCD_RST, 3 /* rotation = landscape 480x320, flipped 180° */,
    true /* IPS */);
FT6X36 touch(&Wire, TP_INT);

static UsageData usage = {};

// Flipped to true as soon as the daemon sends at least one gauge value (the
// "s" field). Used to drive the boot-time poll-request retry loop in loop().
static bool gauges_received = false;

// ---- Touch shared state ----
// FT6X36 driver registers a callback; we just latch the latest point and
// release-state into shared variables that LVGL's indev read polls.
static volatile bool     touch_pressed = false;
static volatile uint16_t touch_x = 0;
static volatile uint16_t touch_y = 0;

// FT6336 reports raw coords in the panel's native portrait orientation
// (320 wide × 480 tall). We render landscape (480 × 320, gfx rotation = 3,
// flipped 180° from rotation=1). Touch transform mirrors the display flip.
static inline void map_touch(int16_t raw_x, int16_t raw_y) {
    touch_x = (uint16_t)(LCD_WIDTH  - 1 - raw_y);
    touch_y = (uint16_t)raw_x;
}

static void touch_event_cb(TPoint p, TEvent e) {
    switch (e) {
    case TEvent::Tap:
    case TEvent::TouchStart:
    case TEvent::TouchMove:
    case TEvent::DragStart:
    case TEvent::DragMove:
        map_touch(p.x, p.y);
        touch_pressed = true;
        break;
    case TEvent::TouchEnd:
    case TEvent::DragEnd:
        touch_pressed = false;
        break;
    default:
        break;
    }
}

// ---- LVGL draw buffers (PSRAM-backed, partial render) ----
#define BUF_LINES 40
static uint16_t *buf1 = nullptr;
static uint16_t *buf2 = nullptr;

// LVGL tick callback
static uint32_t my_tick(void) {
    return millis();
}

// LVGL flush callback — straight blit, ST7796 handles rotation in hardware
static void my_flush_cb(lv_display_t* disp, const lv_area_t* area, uint8_t* px_map) {
    int32_t w = area->x2 - area->x1 + 1;
    int32_t h = area->y2 - area->y1 + 1;
    gfx->draw16bitRGBBitmap(area->x1, area->y1, (uint16_t*)px_map, w, h);
    lv_display_flush_ready(disp);
}

// LVGL touch callback
static void my_touch_cb(lv_indev_t* indev, lv_indev_data_t* data) {
    if (touch_pressed) {
        data->point.x = touch_x;
        data->point.y = touch_y;
        data->state = LV_INDEV_STATE_PRESSED;
    } else {
        data->state = LV_INDEV_STATE_RELEASED;
    }
}

// Parse a JSON line into UsageData
static bool parse_json(const char* json, UsageData* out) {
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, json);
    if (err) {
        Serial.printf("JSON parse error: %s\n", err.c_str());
        return false;
    }

    // Only overwrite fields actually present in the JSON. This lets the
    // daemon send a partial payload like {"m":"haiku"} for an instant model
    // refresh without zeroing the gauges between API polls.
    if (!doc["s"].isNull()) {
        out->session_pct = doc["s"].as<float>();
        gauges_received = true;
    }
    if (!doc["sr"].isNull()) out->session_reset_mins = doc["sr"].as<int>();
    if (!doc["w"].isNull())  out->weekly_pct         = doc["w"].as<float>();
    if (!doc["wr"].isNull()) out->weekly_reset_mins  = doc["wr"].as<int>();
    if (!doc["st"].isNull()) strlcpy(out->status, doc["st"], sizeof(out->status));
    if (!doc["m"].isNull())  strlcpy(out->model,  doc["m"],  sizeof(out->model));
    if (!doc["ok"].isNull()) out->ok                 = doc["ok"].as<bool>();
    out->valid = true;
    return true;
}

// Serial command buffer — big enough for the full JSON usage payload
// (worst case ~70 bytes) plus a safety margin.
#define CMD_BUF_SIZE 256
static char cmd_buf[CMD_BUF_SIZE];
static int cmd_pos = 0;

static void send_screenshot() {
    const uint32_t w = LCD_WIDTH, h = LCD_HEIGHT;
    const uint32_t row_bytes = w * 2;
    const uint32_t buf_size = row_bytes * h;
    uint8_t* sbuf = (uint8_t*)heap_caps_malloc(buf_size, MALLOC_CAP_SPIRAM);
    if (!sbuf) {
        Serial.println("SCREENSHOT_ERR");
        return;
    }

    lv_draw_buf_t draw_buf;
    lv_draw_buf_init(&draw_buf, w, h, LV_COLOR_FORMAT_RGB565, row_bytes, sbuf, buf_size);

    lv_result_t res = lv_snapshot_take_to_draw_buf(lv_screen_active(), LV_COLOR_FORMAT_RGB565, &draw_buf);
    if (res != LV_RESULT_OK) {
        heap_caps_free(sbuf);
        Serial.println("SCREENSHOT_ERR");
        return;
    }

    Serial.printf("SCREENSHOT_START %lu %lu %lu\n", (unsigned long)w, (unsigned long)h, (unsigned long)buf_size);
    Serial.flush();
    Serial.write(sbuf, buf_size);
    Serial.flush();
    Serial.println();
    Serial.println("SCREENSHOT_END");

    heap_caps_free(sbuf);
}

// Lines starting with '{' are JSON usage payloads from the USB daemon —
// same schema as the BLE RX characteristic. We feed them through the same
// pipeline so the UI behaves identically across transports.
static void process_usb_json(const char* line) {
    if (parse_json(line, &usage)) {
        int g_before = usage_rate_group();
        usage_rate_sample(usage.session_pct);
        int g_after = usage_rate_group();
        if (g_after != g_before && splash_is_active()) splash_pick_for_current_rate();
        ui_update(&usage);
        Serial.println("{\"ack\":true}");
    } else {
        Serial.println("{\"err\":true}");
    }
}

static void check_serial_cmd() {
    while (Serial.available()) {
        char c = Serial.read();
        if (c == '\n' || c == '\r') {
            cmd_buf[cmd_pos] = '\0';
            if (cmd_pos > 0) {
                if (cmd_buf[0] == '{')                       process_usb_json(cmd_buf);
                else if (strcmp(cmd_buf, "screenshot") == 0) send_screenshot();
            }
            cmd_pos = 0;
        } else if (cmd_pos < CMD_BUF_SIZE - 1) {
            cmd_buf[cmd_pos++] = c;
        }
    }
}

void setup() {
    Serial.begin(115200);
    delay(300);
    Serial.println("{\"ready\":true}");

    // Backlight on (active high on SC01 Plus)
    pinMode(LCD_BL, OUTPUT);
    digitalWrite(LCD_BL, HIGH);

    // Init I2C (shared by touch)
    Wire.begin(IIC_SDA, IIC_SCL);

    // Init display
    gfx->begin();
    gfx->fillScreen(0x0000);

    // Init touch (FT6336U)
    touch.begin();
    touch.registerTouchHandler(touch_event_cb);

    // Init LVGL
    lv_init();
    lv_tick_set_cb(my_tick);

    // PSRAM-backed partial render buffers
    buf1 = (uint16_t*)heap_caps_malloc(LCD_WIDTH * BUF_LINES * 2, MALLOC_CAP_SPIRAM);
    buf2 = (uint16_t*)heap_caps_malloc(LCD_WIDTH * BUF_LINES * 2, MALLOC_CAP_SPIRAM);

    lv_display_t* disp = lv_display_create(LCD_WIDTH, LCD_HEIGHT);
    lv_display_set_color_format(disp, LV_COLOR_FORMAT_RGB565);
    lv_display_set_flush_cb(disp, my_flush_cb);
    lv_display_set_buffers(disp, buf1, buf2, LCD_WIDTH * BUF_LINES * 2,
                           LV_DISPLAY_RENDER_MODE_PARTIAL);

    lv_indev_t* indev = lv_indev_create();
    lv_indev_set_type(indev, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(indev, my_touch_cb);

    // Stubbed on SC01 Plus (no PMU, no IMU) but still called for symmetry.
    power_init();
    imu_init();

    // Build dashboard
    ui_init();

    // Battery hidden by ui_update_battery when percent < 0
    ui_update_battery(power_battery_pct(), power_is_charging());

    ui_show_screen(SCREEN_SPLASH);

    Serial.println("Dashboard ready, waiting for USB JSON...");
}

void loop() {
    touch.loop();
    lv_timer_handler();
    ui_tick_anim();
    splash_tick();

    // USB serial commands: 'screenshot' and {...} JSON usage payloads.
    check_serial_cmd();

    // Ask the daemon for an immediate poll while the gauges are still "---".
    // Default daemon poll cadence is 60s — without this kick a fresh boot or
    // reflash would sit with empty gauges for up to a minute. Send right
    // away, retry every 3s, give up after ~1 minute to avoid spamming if no
    // one is listening.
    static uint32_t last_req_ms = 0;
    static int req_count = 0;
    static bool initial_req = true;
    if (!gauges_received && req_count < 20) {
        uint32_t now = millis();
        if (initial_req || (now - last_req_ms) >= 3000) {
            Serial.println("{\"req\":\"poll\"}");
            last_req_ms = now;
            req_count++;
            initial_req = false;
        }
    }

    delay(5);
}
