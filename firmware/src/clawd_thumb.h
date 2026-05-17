#pragma once
#include <stdint.h>
#include <lvgl.h>

// Tiny animated Claude widget for the bottom-nav Usage button. Renders one
// of the splash animations into a small RGB565 canvas (cell_size px per
// 20x20 grid cell). cell=2 → 40x40, cell=3 → 60x60.
//
// Background-aware: palette index 0 (the animation's own black background)
// is replaced by the caller-provided bg colour, so the canvas blends into
// the surrounding button when it's selected (pastel blue) or not (dim grey).

void clawd_thumb_create(lv_obj_t *parent, int cell_size, uint16_t initial_bg);

// Re-render with a new background colour (call when the button's active
// state flips and its bg changes).
void clawd_thumb_set_bg(uint16_t bg);

// Pick a specific animation by name. If not found or never called, the
// thumbnail defaults to the first available animation.
void clawd_thumb_set_animation(const char *name);

// Advance to the next frame if the current frame's hold time has elapsed.
// Call from the main UI tick.
void clawd_thumb_tick(void);

lv_obj_t* clawd_thumb_canvas(void);
