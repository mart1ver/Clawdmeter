#include "clawd_thumb.h"
#include "splash.h"
#include <Arduino.h>
#include <esp_heap_caps.h>

#define GRID 20

typedef struct {
    int      cell;
    int      size;
    uint16_t bg;
    uint16_t *buf;
    lv_obj_t *canvas;
    int      anim;
    int      frame;
    uint32_t frame_started;
} thumb_slot_t;

static thumb_slot_t g_slots[CLAWD_THUMB_SLOTS] = {};

static void render(thumb_slot_t *s) {
    if (!s->buf) return;
    splash_render_thumb(s->buf, s->cell, s->anim, s->frame, s->bg);
    if (s->canvas) lv_obj_invalidate(s->canvas);
}

static thumb_slot_t* get_slot(int idx) {
    if (idx < 0 || idx >= CLAWD_THUMB_SLOTS) return nullptr;
    return &g_slots[idx];
}

void clawd_thumb_create(int slot, lv_obj_t *parent, int cell, uint16_t bg) {
    thumb_slot_t *s = get_slot(slot);
    if (!s) return;

    s->cell = cell;
    s->size = GRID * cell;
    s->bg = bg;

    s->buf = (uint16_t*)heap_caps_malloc(s->size * s->size * 2, MALLOC_CAP_SPIRAM);
    if (!s->buf) {
        Serial.printf("clawd_thumb[%d]: PSRAM alloc failed\n", slot);
        return;
    }

    s->canvas = lv_canvas_create(parent);
    lv_canvas_set_buffer(s->canvas, s->buf, s->size, s->size, LV_COLOR_FORMAT_RGB565);

    // Default animation: "idle breathe". Caller can override via set_animation.
    int idx = splash_find_anim_by_name("idle breathe");
    s->anim = (idx >= 0) ? idx : 0;
    s->frame = 0;
    s->frame_started = millis();
    render(s);
}

void clawd_thumb_set_bg(int slot, uint16_t bg) {
    thumb_slot_t *s = get_slot(slot);
    if (!s || s->bg == bg) return;
    s->bg = bg;
    render(s);
}

void clawd_thumb_set_animation(int slot, const char *name) {
    thumb_slot_t *s = get_slot(slot);
    if (!s) return;
    int idx = splash_find_anim_by_name(name);
    if (idx < 0) return;
    s->anim = idx;
    s->frame = 0;
    s->frame_started = millis();
    render(s);
}

void clawd_thumb_tick(void) {
    uint32_t now = millis();
    for (int i = 0; i < CLAWD_THUMB_SLOTS; i++) {
        thumb_slot_t *s = &g_slots[i];
        if (!s->canvas) continue;
        int nframes = splash_anim_frame_count(s->anim);
        if (nframes <= 0) continue;
        uint16_t hold = splash_anim_hold(s->anim, s->frame);
        if (now - s->frame_started >= hold) {
            s->frame = (s->frame + 1) % nframes;
            s->frame_started = now;
            render(s);
        }
    }
}

lv_obj_t* clawd_thumb_canvas(int slot) {
    thumb_slot_t *s = get_slot(slot);
    return s ? s->canvas : nullptr;
}
