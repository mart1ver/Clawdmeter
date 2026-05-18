#pragma once
#include <stdint.h>
#include <lvgl.h>

// Tiny animated Claude widget for the bottom-nav buttons. Renders one of
// the splash animations into a small RGB565 canvas (cell_size px per 20x20
// grid cell). cell=2 → 40x40, cell=3 → 60x60.
//
// Multi-instance via slot index [0..CLAWD_THUMB_SLOTS-1]. Each nav button
// gets its own slot with an independent animation playing at its own pace.
//
// Background-aware: palette index 0 (the animation's own black background)
// is replaced by the caller-provided bg colour, so the canvas blends into
// the surrounding button when it's selected (active) or not (inactive).

#define CLAWD_THUMB_SLOTS  4

void clawd_thumb_create(int slot, lv_obj_t *parent, int cell_size, uint16_t initial_bg);

// Re-render with a new background colour (call when the button's active
// state flips and its bg changes).
void clawd_thumb_set_bg(int slot, uint16_t bg);

// Pick a specific animation by name. If not found or never called, the
// thumbnail defaults to the first available animation.
void clawd_thumb_set_animation(int slot, const char *name);

// Advance to the next frame if the current frame's hold time has elapsed.
// Call from the main UI tick — ticks all slots.
void clawd_thumb_tick(void);

lv_obj_t* clawd_thumb_canvas(int slot);
