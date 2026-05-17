#pragma once
#include <stdint.h>
#include <lvgl.h>

// Initialize splash module. Creates the canvas widget inside `parent` and
// allocates the 480x480 pixel buffer (PSRAM).
void splash_init(lv_obj_t *parent);

// Advance animation frame if hold time elapsed. Call from main loop.
void splash_tick(void);

// Cycle to the next animation in the catalog.
void splash_next(void);

// Show/hide the splash container.
void splash_show(void);
void splash_hide(void);

// Pick the next animation matching the current usage-rate group.
// Called automatically by splash_show(); also exposed so other modules can
// trigger a re-pick when the rate group changes mid-display.
void splash_pick_for_current_rate(void);

// True when splash is currently rendering (used to gate re-picks).
bool splash_is_active(void);

// Root container (so ui.cpp can attach a click event).
lv_obj_t* splash_get_root(void);

// ---- Animation-data accessors -----------------------------------------
// Used by the bottom-nav Claude thumbnail so we don't have to include the
// 180 KB splash_animations.h in a second translation unit. The static const
// data lives only in splash.cpp.

int splash_anim_count(void);
int splash_anim_frame_count(int anim_idx);
uint16_t splash_anim_hold(int anim_idx, int frame_idx);
int splash_find_anim_by_name(const char *name);

// Render one frame into a pre-allocated RGB565 buffer at cell_size scale.
// dst is (20 * cell_size) px wide and tall; bg replaces palette index 0
// (the animation's transparent background).
void splash_render_thumb(uint16_t *dst, int cell_size,
                         int anim_idx, int frame_idx, uint16_t bg);
