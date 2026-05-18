#include "clawd_thumb.h"
#include "splash.h"
#include "nav_pictograms.h"
#include <Arduino.h>
#include <esp_heap_caps.h>
#include <string.h>

#define GRID 20

// Each slot can render from one of two animation registries.
typedef enum { SRC_SPLASH, SRC_PICTOGRAM } source_t;

typedef struct {
    source_t source;
    int      index;        // anim_idx (splash) or pict_idx (pictogram)
    int      cell;
    int      size;
    uint16_t bg;
    uint16_t *buf;
    lv_obj_t *canvas;
    int      frame;
    uint32_t frame_started;
} thumb_slot_t;

static thumb_slot_t g_slots[CLAWD_THUMB_SLOTS] = {};

static thumb_slot_t* get_slot(int idx) {
    if (idx < 0 || idx >= CLAWD_THUMB_SLOTS) return nullptr;
    return &g_slots[idx];
}

// ---- Pictogram helpers (live here so nav_pictograms.h stays pure data) ----

static int pict_find_by_name(const char *name) {
    if (!name) return -1;
    for (int i = 0; i < NAV_PICT_COUNT; i++) {
        if (strcmp(nav_pictograms[i].name, name) == 0) return i;
    }
    return -1;
}

static int pict_frame_count(int idx) {
    if (idx < 0 || idx >= NAV_PICT_COUNT) return 0;
    return nav_pictograms[idx].frame_count;
}

static uint16_t pict_hold(int idx, int frame) {
    if (idx < 0 || idx >= NAV_PICT_COUNT) return 0;
    if (frame < 0 || frame >= nav_pictograms[idx].frame_count) return 0;
    return nav_pictograms[idx].holds[frame];
}

// Mirror of splash_render_thumb but for pictograms.
static void pict_render(uint16_t *dst, int cell, int idx, int frame, uint16_t bg) {
    if (!dst) return;
    if (idx < 0 || idx >= NAV_PICT_COUNT) return;
    const nav_pict_def_t *p = &nav_pictograms[idx];
    if (frame < 0 || frame >= p->frame_count) return;

    const int W = NAV_PICT_GRID * cell;
    const uint8_t *cells = p->frames[frame];
    for (int gy = 0; gy < NAV_PICT_GRID; gy++) {
        for (int gx = 0; gx < NAV_PICT_GRID; gx++) {
            uint8_t code = cells[gy * NAV_PICT_GRID + gx];
            uint16_t color = (code == 0 || code >= NAV_PICT_PALETTE_SIZE)
                                 ? bg
                                 : p->palette[code];
            for (int dy = 0; dy < cell; dy++) {
                uint16_t *row = &dst[(gy * cell + dy) * W + gx * cell];
                for (int dx = 0; dx < cell; dx++) row[dx] = color;
            }
        }
    }
}

// ---- Dispatch render to the right source --------------------------------

static void render(thumb_slot_t *s) {
    if (!s->buf) return;
    if (s->source == SRC_SPLASH) {
        splash_render_thumb(s->buf, s->cell, s->index, s->frame, s->bg);
    } else {
        pict_render(s->buf, s->cell, s->index, s->frame, s->bg);
    }
    if (s->canvas) lv_obj_invalidate(s->canvas);
}

static int slot_frame_count(thumb_slot_t *s) {
    return (s->source == SRC_SPLASH)
         ? splash_anim_frame_count(s->index)
         : pict_frame_count(s->index);
}

static uint16_t slot_hold(thumb_slot_t *s, int frame) {
    return (s->source == SRC_SPLASH)
         ? splash_anim_hold(s->index, frame)
         : pict_hold(s->index, frame);
}

// ---- Public API ----------------------------------------------------------

void clawd_thumb_create(int slot, lv_obj_t *parent, int cell, uint16_t bg) {
    thumb_slot_t *s = get_slot(slot);
    if (!s) return;

    s->cell = cell;
    s->size = GRID * cell;
    s->bg = bg;
    s->source = SRC_SPLASH;

    s->buf = (uint16_t*)heap_caps_malloc(s->size * s->size * 2, MALLOC_CAP_SPIRAM);
    if (!s->buf) {
        Serial.printf("clawd_thumb[%d]: PSRAM alloc failed\n", slot);
        return;
    }

    s->canvas = lv_canvas_create(parent);
    lv_canvas_set_buffer(s->canvas, s->buf, s->size, s->size, LV_COLOR_FORMAT_RGB565);

    // Default to splash "idle breathe"; caller overrides via set_animation
    // or set_pictogram immediately after create.
    int idx = splash_find_anim_by_name("idle breathe");
    s->index = (idx >= 0) ? idx : 0;
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
    s->source = SRC_SPLASH;
    s->index = idx;
    s->frame = 0;
    s->frame_started = millis();
    render(s);
}

void clawd_thumb_set_pictogram(int slot, const char *name) {
    thumb_slot_t *s = get_slot(slot);
    if (!s) return;
    int idx = pict_find_by_name(name);
    if (idx < 0) return;
    s->source = SRC_PICTOGRAM;
    s->index = idx;
    s->frame = 0;
    s->frame_started = millis();
    render(s);
}

void clawd_thumb_tick(void) {
    uint32_t now = millis();
    for (int i = 0; i < CLAWD_THUMB_SLOTS; i++) {
        thumb_slot_t *s = &g_slots[i];
        if (!s->canvas) continue;
        int nframes = slot_frame_count(s);
        if (nframes <= 0) continue;
        uint16_t hold = slot_hold(s, s->frame);
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
