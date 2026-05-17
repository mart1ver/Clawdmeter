#include "clawd_thumb.h"
#include "splash.h"
#include <Arduino.h>
#include <esp_heap_caps.h>

#define GRID 20

static int      g_cell = 2;
static int      g_size = GRID * 2;
static uint16_t g_bg = 0x0000;
static uint16_t *g_buf = nullptr;
static lv_obj_t *g_canvas = nullptr;
static int      g_anim = 0;
static int      g_frame = 0;
static uint32_t g_frame_started = 0;

static void render(void) {
    if (!g_buf) return;
    splash_render_thumb(g_buf, g_cell, g_anim, g_frame, g_bg);
    if (g_canvas) lv_obj_invalidate(g_canvas);
}

void clawd_thumb_create(lv_obj_t *parent, int cell, uint16_t bg) {
    g_cell = cell;
    g_size = GRID * cell;
    g_bg = bg;

    g_buf = (uint16_t*)heap_caps_malloc(g_size * g_size * 2, MALLOC_CAP_SPIRAM);
    if (!g_buf) {
        Serial.println("clawd_thumb: PSRAM alloc failed");
        return;
    }

    g_canvas = lv_canvas_create(parent);
    lv_canvas_set_buffer(g_canvas, g_buf, g_size, g_size, LV_COLOR_FORMAT_RGB565);

    // Pick "idle breathe" by default — friendly, slow, low-distraction.
    int idx = splash_find_anim_by_name("idle breathe");
    g_anim = (idx >= 0) ? idx : 0;
    g_frame = 0;
    g_frame_started = millis();
    render();
}

void clawd_thumb_set_bg(uint16_t bg) {
    if (g_bg == bg) return;
    g_bg = bg;
    render();
}

void clawd_thumb_set_animation(const char *name) {
    int idx = splash_find_anim_by_name(name);
    if (idx < 0) return;
    g_anim = idx;
    g_frame = 0;
    g_frame_started = millis();
    render();
}

void clawd_thumb_tick(void) {
    if (!g_canvas) return;
    int nframes = splash_anim_frame_count(g_anim);
    if (nframes <= 0) return;
    uint16_t hold = splash_anim_hold(g_anim, g_frame);
    if (millis() - g_frame_started >= hold) {
        g_frame = (g_frame + 1) % nframes;
        g_frame_started = millis();
        render();
    }
}

lv_obj_t* clawd_thumb_canvas(void) { return g_canvas; }
