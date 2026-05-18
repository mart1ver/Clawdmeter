#pragma once
#include <stdint.h>
#include <lvgl.h>

// Small animated widget for the bottom-nav buttons. Renders a 20x20
// indexed-palette frame into an RGB565 canvas (cell_size px per grid cell).
//
// Multi-instance via slot index [0..CLAWD_THUMB_SLOTS-1]. Each slot has its
// own canvas + animation state.
//
// Two animation sources are supported per slot:
//   1. splash_anims   — the 13 claudepix character animations
//   2. nav_pictograms — informative icons (system EQ, BTC coin, lightning…)
//
// Use clawd_thumb_set_animation() for splash anims (Claude characters), and
// clawd_thumb_set_pictogram() for nav icons.
//
// Background-aware: palette index 0 (the source's transparent bg) is
// replaced by the caller-provided bg colour, so the canvas blends into the
// surrounding button when it's active vs. inactive.

#define CLAWD_THUMB_SLOTS  4

void clawd_thumb_create(int slot, lv_obj_t *parent, int cell_size, uint16_t initial_bg);

void clawd_thumb_set_bg(int slot, uint16_t bg);

// Bind slot to a splash (Claude character) animation, looked up by name.
void clawd_thumb_set_animation(int slot, const char *name);

// Bind slot to a nav pictogram (icon-style animation), looked up by name.
void clawd_thumb_set_pictogram(int slot, const char *name);

// Advance frames if hold elapsed. Ticks ALL slots — call once per UI tick.
void clawd_thumb_tick(void);

lv_obj_t* clawd_thumb_canvas(int slot);
