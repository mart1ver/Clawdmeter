#include "ui.h"
#include "splash.h"
#include "clawd_thumb.h"
#include <lvgl.h>
#include "logo.h"
#include "icons.h"
#include "display_cfg.h"

// Fonts available in this build. SC01 Plus is 165 PPI so the smaller
// pre-compiled sizes are right; the 1.9x-scaled set used on the 2.16"
// AMOLED is too large for 480x320.
LV_FONT_DECLARE(font_tiempos_28);
LV_FONT_DECLARE(font_tiempos_34);
LV_FONT_DECLARE(font_tiempos_56);
LV_FONT_DECLARE(font_styrene_48);
LV_FONT_DECLARE(font_styrene_28);
LV_FONT_DECLARE(font_styrene_24);
LV_FONT_DECLARE(font_styrene_20);
LV_FONT_DECLARE(font_styrene_16);
LV_FONT_DECLARE(font_styrene_14);
LV_FONT_DECLARE(font_styrene_12);
LV_FONT_DECLARE(font_mono_18);

#include "theme.h"
#define COL_BG        THEME_BG
#define COL_PANEL     THEME_PANEL
#define COL_TEXT      THEME_TEXT
#define COL_DIM       THEME_DIM
#define COL_ACCENT    THEME_ACCENT
#define COL_GREEN     THEME_GREEN
#define COL_AMBER     THEME_AMBER
#define COL_RED       THEME_RED
#define COL_BAR_BG    THEME_BAR_BG

// ---- Futuristic neon palette (shared across all pages) ----
#define NEON_DEEP    lv_color_hex(0x0a0a14)  // very dark blue-black panel
#define NEON_CYAN    lv_color_hex(0x00D9FF)  // neon cyan accent
#define NEON_BORDER  lv_color_hex(0x1a3a4a)  // subtle cyan-tinted border
#define COL_NAV_ACTIVE THEME_PASTEL_BLUE

// ---- Layout constants for 480x320 landscape (Panlee SC01 Plus) ----
#define SCR_W         480
#define SCR_H         320
#define MARGIN        12
#define TITLE_Y       8
#define CONTENT_Y     12  // Moved up to use title space; title is now hidden
#define CONTENT_W     (SCR_W - 2 * MARGIN)   // 456

// Two panels side by side under the title.
#define PANEL_W       222
#define PANEL_H       175
#define PANEL_GAP     12
#define PANEL_X_LEFT  MARGIN
#define PANEL_X_RIGHT (MARGIN + PANEL_W + PANEL_GAP)

// Row of 4 nav buttons at the bottom, visible on every non-splash screen.
#define NAV_GAP       12
#define NAV_BTN_W     ((CONTENT_W - 3 * NAV_GAP) / 4)   // 105
#define NAV_BTN_H     61
#define NAV_Y         (SCR_H - NAV_BTN_H - MARGIN)      // 247

// ---- Chrome (always on top of pages, hidden on splash) ----
static lv_obj_t* lbl_title;
static lv_obj_t* lbl_model;         // model pill top-right (Usage page only)
static lv_obj_t* lbl_effort;        // effort pill top-left  (Usage page only)
static char last_effort[16] = {0};
static lv_obj_t* nav_btns[4];
static lv_image_dsc_t nav_icon_dscs[4];

// ---- Pages (only one visible at a time) ----
static lv_obj_t* page_usage;
static lv_obj_t* page_system;
static lv_obj_t* page_bitcoin;
static lv_obj_t* page_actions;

// ---- Usage page widgets ----
static lv_obj_t* bar_session;
static lv_obj_t* lbl_session_pct;
static lv_obj_t* lbl_session_label;
static lv_obj_t* lbl_session_reset;
static lv_obj_t* bar_weekly;
static lv_obj_t* lbl_weekly_pct;
static lv_obj_t* lbl_weekly_label;
static lv_obj_t* lbl_weekly_reset;

// ---- System page widgets (3 cols x 2 rows) ----
// Two rendering modes per cell:
//   SPARKLINE: rolling history line chart (RAM/DISK/TEMP/NET)
//   BARS:     snapshot of N current values as side-by-side bars
//             (CPU=12 per-core, GPU=2 util+vram)
#define SYS_SPARK_POINTS  24
#define SYS_MAX_BARS      16    // enough for 12 CPU cores
typedef struct {
    lv_obj_t* value;
    lv_obj_t* chart;
    lv_chart_series_t* series;     // primary series (sparkline / first bar set)
    lv_chart_series_t* series2;    // secondary series (GPU VRAM bar), nullable
    int bar_count;                 // 0 = sparkline mode, >0 = bars mode
} sys_cell_t;
static sys_cell_t sc_cpu, sc_ram, sc_disk, sc_temp, sc_gpu, sc_net;

// ---- Bitcoin page widgets ----
static lv_obj_t* btc_price_label;
static lv_obj_t* btc_change_label;
static lv_obj_t* btc_arrow_label;       // ▲ or ▼ trend indicator
static lv_obj_t* btc_chart;
static lv_chart_series_t* btc_series;
static lv_obj_t* btc_high_value;        // 6M high
static lv_obj_t* btc_low_value;         // 6M low
static lv_obj_t* btc_range_value;       // current position in 6M range (%)

// ---- Battery indicator + logo (kept for API symmetry; PMU is stubbed) ----
static lv_obj_t* battery_img;
static lv_obj_t* logo_img;
static lv_image_dsc_t battery_dscs[5];

// ---- Shared ----
static lv_image_dsc_t logo_dsc;
static screen_t current_screen = SCREEN_USAGE;
static char last_model[16] = {0};

static lv_color_t pct_color(float pct) {
    if (pct >= 80.0f) return COL_RED;
    if (pct >= 50.0f) return COL_AMBER;
    return COL_GREEN;
}

static void format_reset_time(int mins, char* buf, size_t len) {
    if (mins < 0) {
        snprintf(buf, len, "---");
    } else if (mins < 60) {
        snprintf(buf, len, "Reset dans %dm", mins);
    } else if (mins < 1440) {
        snprintf(buf, len, "Reset dans %dh %dm", mins / 60, mins % 60);
    } else {
        snprintf(buf, len, "Reset dans %dd %dh", mins / 1440, (mins % 1440) / 60);
    }
}

// Forward decls
static void splash_toggle_cb(lv_event_t* e);
static void nav_click_cb(lv_event_t* e);
static void update_nav_active(screen_t s);
static void update_chrome_for_screen(screen_t s);

// RGB565A8: planar — w*h RGB565 pixels followed by w*h alpha bytes.
static void init_icon_dsc_rgb565a8(lv_image_dsc_t* dsc, int w, int h, const uint8_t* data) {
    dsc->header.w = w;
    dsc->header.h = h;
    dsc->header.cf = LV_COLOR_FORMAT_RGB565A8;
    dsc->header.stride = w * 2;
    dsc->data = data;
    dsc->data_size = w * h * 3;
}

static lv_obj_t* make_panel(lv_obj_t* parent, int x, int y, int w, int h) {
    lv_obj_t* panel = lv_obj_create(parent);
    lv_obj_set_pos(panel, x, y);
    lv_obj_set_size(panel, w, h);
    lv_obj_set_style_bg_color(panel, COL_PANEL, 0);
    lv_obj_set_style_bg_opa(panel, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(panel, 8, 0);
    lv_obj_set_style_border_width(panel, 0, 0);
    lv_obj_set_style_pad_left(panel, 12, 0);
    lv_obj_set_style_pad_right(panel, 12, 0);
    lv_obj_set_style_pad_top(panel, 10, 0);
    lv_obj_set_style_pad_bottom(panel, 10, 0);
    lv_obj_clear_flag(panel, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(panel, LV_OBJ_FLAG_EVENT_BUBBLE);
    return panel;
}

static lv_obj_t* make_bar(lv_obj_t* parent, int x, int y, int w, int h) {
    lv_obj_t* bar = lv_bar_create(parent);
    lv_obj_set_pos(bar, x, y);
    lv_obj_set_size(bar, w, h);
    lv_bar_set_range(bar, 0, 100);
    lv_bar_set_value(bar, 0, LV_ANIM_OFF);
    lv_obj_set_style_bg_color(bar, COL_BAR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_radius(bar, 6, LV_PART_MAIN);
    lv_obj_set_style_bg_color(bar, COL_GREEN, LV_PART_INDICATOR);
    lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, LV_PART_INDICATOR);
    lv_obj_set_style_radius(bar, 6, LV_PART_INDICATOR);
    return bar;
}

// Model pill (top-right of Usage screen) — futuristic neon style:
// deep dark fill, cyan neon border, cyan text. Matches the rest of the UI.
static lv_obj_t* make_pill(lv_obj_t* parent, const char* text) {
    lv_obj_t* lbl = lv_label_create(parent);
    lv_label_set_text(lbl, text);
    lv_obj_set_style_text_font(lbl, &font_styrene_16, 0);
    lv_obj_set_style_text_color(lbl, NEON_CYAN, 0);
    lv_obj_set_style_bg_color(lbl, NEON_DEEP, 0);
    lv_obj_set_style_bg_opa(lbl, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(lbl, 4, 0);
    lv_obj_set_style_border_color(lbl, NEON_CYAN, 0);
    lv_obj_set_style_border_width(lbl, 1, 0);
    lv_obj_set_style_border_opa(lbl, LV_OPA_70, 0);
    lv_obj_set_style_pad_left(lbl, 10, 0);
    lv_obj_set_style_pad_right(lbl, 10, 0);
    lv_obj_set_style_pad_top(lbl, 4, 0);
    lv_obj_set_style_pad_bottom(lbl, 4, 0);
    return lbl;
}

// Empty nav-button shell (icon is added by the caller — usually an
// lv_image, but the Usage button hosts the animated Claude canvas).
// Styled to match the rest of the futuristic neon UI: deep dark bg
// with subtle cyan border. update_nav_active() bumps border opacity
// and tints the bg when the button represents the current screen.
static lv_obj_t* make_nav_button_shell(lv_obj_t* parent, int x, int y) {
    lv_obj_t* btn = lv_obj_create(parent);
    lv_obj_set_pos(btn, x, y);
    lv_obj_set_size(btn, NAV_BTN_W, NAV_BTN_H);
    lv_obj_set_style_bg_color(btn, NEON_DEEP, 0);
    lv_obj_set_style_bg_opa(btn, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(btn, 4, 0);
    lv_obj_set_style_border_color(btn, NEON_CYAN, 0);
    lv_obj_set_style_border_width(btn, 1, 0);
    lv_obj_set_style_border_opa(btn, LV_OPA_50, 0);
    lv_obj_set_style_pad_all(btn, 0, 0);
    lv_obj_clear_flag(btn, LV_OBJ_FLAG_SCROLLABLE);
    return btn;
}

static lv_obj_t* make_nav_button(lv_obj_t* parent, int x, int y,
                                 const lv_image_dsc_t* icon) {
    lv_obj_t* btn = make_nav_button_shell(parent, x, y);
    lv_obj_t* img = lv_image_create(btn);
    lv_image_set_src(img, icon);
    lv_obj_center(img);
    return btn;
}

static void init_battery_icons(void) {
    init_icon_dsc_rgb565a8(&battery_dscs[0], ICON_BATTERY_W, ICON_BATTERY_H, icon_battery_data);
    init_icon_dsc_rgb565a8(&battery_dscs[1], ICON_BATTERY_LOW_W, ICON_BATTERY_LOW_H, icon_battery_low_data);
    init_icon_dsc_rgb565a8(&battery_dscs[2], ICON_BATTERY_MEDIUM_W, ICON_BATTERY_MEDIUM_H, icon_battery_medium_data);
    init_icon_dsc_rgb565a8(&battery_dscs[3], ICON_BATTERY_FULL_W, ICON_BATTERY_FULL_H, icon_battery_full_data);
    init_icon_dsc_rgb565a8(&battery_dscs[4], ICON_BATTERY_CHARGING_W, ICON_BATTERY_CHARGING_H, icon_battery_charging_data);
}

static void init_nav_icons(void) {
    init_icon_dsc_rgb565a8(&nav_icon_dscs[0], ICON_NAV_USAGE_W,   ICON_NAV_USAGE_H,   icon_nav_usage_data);
    init_icon_dsc_rgb565a8(&nav_icon_dscs[1], ICON_NAV_SYSTEM_W,  ICON_NAV_SYSTEM_H,  icon_nav_system_data);
    init_icon_dsc_rgb565a8(&nav_icon_dscs[2], ICON_NAV_BITCOIN_W, ICON_NAV_BITCOIN_H, icon_nav_bitcoin_data);
    init_icon_dsc_rgb565a8(&nav_icon_dscs[3], ICON_NAV_ACTIONS_W, ICON_NAV_ACTIONS_H, icon_nav_actions_data);
}

// ======== Page containers ========

static lv_obj_t* make_page(lv_obj_t* scr) {
    lv_obj_t* p = lv_obj_create(scr);
    lv_obj_set_size(p, SCR_W, NAV_Y - CONTENT_Y - 12);
    lv_obj_set_pos(p, 0, CONTENT_Y);
    lv_obj_set_style_bg_opa(p, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(p, 0, 0);
    lv_obj_set_style_pad_all(p, 0, 0);
    lv_obj_clear_flag(p, LV_OBJ_FLAG_SCROLLABLE);
    // Tapping the page content (anywhere not on a child) toggles the splash.
    lv_obj_add_event_cb(p, splash_toggle_cb, LV_EVENT_CLICKED, NULL);
    return p;
}

// One Session/Hebdo panel — futuristic neon style with Claude orange accent.
static void make_usage_panel(lv_obj_t* parent, int x, int y, const char* pill_text,
                             lv_obj_t** out_pct, lv_obj_t** out_pill,
                             lv_obj_t** out_bar, lv_obj_t** out_reset) {
    // Deep dark panel with orange (Claude brand) neon border
    lv_obj_t* panel = lv_obj_create(parent);
    lv_obj_set_pos(panel, x, y);
    lv_obj_set_size(panel, PANEL_W, PANEL_H);
    lv_obj_set_style_bg_color(panel, NEON_DEEP, 0);
    lv_obj_set_style_bg_opa(panel, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(panel, 6, 0);
    lv_obj_set_style_border_color(panel, COL_ACCENT, 0);
    lv_obj_set_style_border_width(panel, 1, 0);
    lv_obj_set_style_border_opa(panel, LV_OPA_70, 0);
    lv_obj_set_style_pad_left(panel, 12, 0);
    lv_obj_set_style_pad_right(panel, 12, 0);
    lv_obj_set_style_pad_top(panel, 10, 0);
    lv_obj_set_style_pad_bottom(panel, 10, 0);
    lv_obj_clear_flag(panel, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(panel, LV_OBJ_FLAG_EVENT_BUBBLE);

    // Small uppercase label in orange (no pill background — cleaner neon look)
    *out_pill = lv_label_create(panel);
    lv_label_set_text(*out_pill, pill_text);
    lv_obj_set_style_text_font(*out_pill, &font_styrene_14, 0);
    lv_obj_set_style_text_color(*out_pill, COL_ACCENT, 0);
    lv_obj_align(*out_pill, LV_ALIGN_TOP_LEFT, 0, 0);

    // Big % in white
    *out_pct = lv_label_create(panel);
    lv_label_set_text(*out_pct, "---%");
    lv_obj_set_style_text_font(*out_pct, &font_styrene_48, 0);
    lv_obj_set_style_text_color(*out_pct, COL_TEXT, 0);
    lv_obj_align(*out_pct, LV_ALIGN_LEFT_MID, 0, 0);

    // Bar
    *out_bar = make_bar(panel, 0, PANEL_H - 64, PANEL_W - 24, 14);
    lv_obj_align(*out_bar, LV_ALIGN_BOTTOM_LEFT, 0, -28);

    // Reset time at bottom, small dim
    *out_reset = lv_label_create(panel);
    lv_label_set_text(*out_reset, "---");
    lv_obj_set_style_text_font(*out_reset, &font_styrene_14, 0);
    lv_obj_set_style_text_color(*out_reset, NEON_CYAN, 0);
    lv_obj_set_style_text_opa(*out_reset, LV_OPA_70, 0);
    lv_obj_align(*out_reset, LV_ALIGN_BOTTOM_LEFT, 0, 0);
}

static void init_page_usage(lv_obj_t* scr) {
    page_usage = make_page(scr);
    // Push panels down by ~30px so the model pill (top-right) doesn't overlap
    // the HEBDO panel border. The pill lives in chrome and the page starts at
    // CONTENT_Y=12 globally, same y as the pill.
    int top_offset = 45;
    make_usage_panel(page_usage, PANEL_X_LEFT, top_offset, "SESSION",
                     &lbl_session_pct, &lbl_session_label,
                     &bar_session, &lbl_session_reset);
    make_usage_panel(page_usage, PANEL_X_RIGHT, top_offset, "HEBDO",
                     &lbl_weekly_pct, &lbl_weekly_label,
                     &bar_weekly, &lbl_weekly_reset);
}

// ---- System page (live host telemetry pushed by the daemon) ----
// Layout: 3 cols × 2 rows of sparkline cards. Each card shows a live
// rolling chart of the metric's history — much more informative than
// a static bar and gives the page a "trading dashboard" feel.

#define SYS_GAP       8
#define SYS_COLS      3
#define SYS_ROWS      2
// Cell width: divide content width across 3 columns with 2 gaps.
#define SYS_CELL_W    ((CONTENT_W - (SYS_COLS - 1) * SYS_GAP) / SYS_COLS)   // ~146
#define SYS_CELL_H    105

static void make_sys_cell(lv_obj_t* parent, int x, int y,
                          const char* name, sys_cell_t* out,
                          lv_color_t accent) {
    // Deep dark card with subtle cyan neon border
    lv_obj_t* card = lv_obj_create(parent);
    lv_obj_set_pos(card, x, y);
    lv_obj_set_size(card, SYS_CELL_W, SYS_CELL_H);
    lv_obj_set_style_bg_color(card, NEON_DEEP, 0);
    lv_obj_set_style_bg_opa(card, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(card, 4, 0);
    lv_obj_set_style_border_color(card, NEON_CYAN, 0);
    lv_obj_set_style_border_width(card, 1, 0);
    lv_obj_set_style_border_opa(card, LV_OPA_60, 0);
    lv_obj_set_style_pad_left(card, 8, 0);
    lv_obj_set_style_pad_right(card, 8, 0);
    lv_obj_set_style_pad_top(card, 6, 0);
    lv_obj_set_style_pad_bottom(card, 6, 0);
    lv_obj_clear_flag(card, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(card, LV_OBJ_FLAG_EVENT_BUBBLE);

    // Label uppercase in cyan neon (top-left)
    lv_obj_t* lbl_name = lv_label_create(card);
    lv_label_set_text(lbl_name, name);
    lv_obj_set_style_text_font(lbl_name, &font_styrene_12, 0);
    lv_obj_set_style_text_color(lbl_name, NEON_CYAN, 0);
    lv_obj_align(lbl_name, LV_ALIGN_TOP_LEFT, 0, 0);

    // Value in white, prominent (top-right)
    out->value = lv_label_create(card);
    lv_label_set_text(out->value, "---");
    lv_obj_set_style_text_font(out->value, &font_styrene_16, 0);
    lv_obj_set_style_text_color(out->value, COL_TEXT, 0);
    lv_obj_align(out->value, LV_ALIGN_TOP_RIGHT, 0, 0);

    // Sparkline chart — takes the bottom 60% of the card
    out->chart = lv_chart_create(card);
    int chart_w = SYS_CELL_W - 16;       // minus left+right padding
    int chart_h = SYS_CELL_H - 36;       // leaves room for label/value at top
    lv_obj_set_size(out->chart, chart_w, chart_h);
    lv_obj_align(out->chart, LV_ALIGN_BOTTOM_MID, 0, 4);
    lv_chart_set_type(out->chart, LV_CHART_TYPE_LINE);
    lv_chart_set_point_count(out->chart, SYS_SPARK_POINTS);
    lv_chart_set_update_mode(out->chart, LV_CHART_UPDATE_MODE_SHIFT);
    lv_chart_set_range(out->chart, LV_CHART_AXIS_PRIMARY_Y, 0, 100);
    lv_chart_set_div_line_count(out->chart, 2, 4);

    // Transparent bg so the card background shows through
    lv_obj_set_style_bg_opa(out->chart, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(out->chart, 0, 0);
    lv_obj_set_style_pad_all(out->chart, 0, 0);

    // Faint cyan grid lines
    lv_obj_set_style_line_color(out->chart, NEON_BORDER, LV_PART_MAIN);
    lv_obj_set_style_line_width(out->chart, 1, LV_PART_MAIN);
    lv_obj_set_style_line_opa(out->chart, LV_OPA_50, LV_PART_MAIN);

    // Thick accent-colored line, no point markers
    lv_obj_set_style_line_width(out->chart, 2, LV_PART_ITEMS);
    lv_obj_set_style_size(out->chart, 0, 0, LV_PART_INDICATOR);

    out->series = lv_chart_add_series(out->chart, accent, LV_CHART_AXIS_PRIMARY_Y);

    // Pre-fill the chart with 0s so it doesn't show a flat line in
    // the middle until enough samples arrive.
    for (int i = 0; i < SYS_SPARK_POINTS; i++) {
        lv_chart_set_next_value(out->chart, out->series, 0);
    }
}

// Switch a cell from sparkline to bar-snapshot mode. Call after make_sys_cell.
// num_bars: how many bars (12 for per-core CPU). With 2 series (e.g. GPU
// util+vram), pass num_bars=1 + accent2 → 2 side-by-side bars per "slot".
static void make_cell_bars(sys_cell_t* c, int num_bars,
                           lv_color_t accent, lv_color_t accent2,
                           bool two_series) {
    c->bar_count = num_bars;
    lv_chart_set_type(c->chart, LV_CHART_TYPE_BAR);
    lv_chart_set_update_mode(c->chart, LV_CHART_UPDATE_MODE_CIRCULAR);
    lv_chart_set_point_count(c->chart, num_bars);

    // Drop the pre-existing sparkline series — it had different colour/data
    if (c->series) {
        lv_chart_remove_series(c->chart, c->series);
        c->series = nullptr;
    }
    c->series  = lv_chart_add_series(c->chart, accent,  LV_CHART_AXIS_PRIMARY_Y);
    c->series2 = two_series
                 ? lv_chart_add_series(c->chart, accent2, LV_CHART_AXIS_PRIMARY_Y)
                 : nullptr;

    // Hide grid (looks busy with many bars), shrink padding
    lv_chart_set_div_line_count(c->chart, 0, 0);
    lv_obj_set_style_pad_column(c->chart, 1, 0);  // 1px gap between bars
}

static void init_page_system(lv_obj_t* scr) {
    page_system = make_page(scr);
    int col_w = SYS_CELL_W + SYS_GAP;
    int row_h = SYS_CELL_H + SYS_GAP;

    // Row 0: CPU | RAM | TEMP
    make_sys_cell(page_system, MARGIN + 0 * col_w, 0 * row_h, "CPU",  &sc_cpu,  NEON_CYAN);
    make_sys_cell(page_system, MARGIN + 1 * col_w, 0 * row_h, "RAM",  &sc_ram,  NEON_CYAN);
    make_sys_cell(page_system, MARGIN + 2 * col_w, 0 * row_h, "TEMP", &sc_temp, COL_ACCENT);
    // Row 1: DISK | GPU | NET
    make_sys_cell(page_system, MARGIN + 0 * col_w, 1 * row_h, "DISK", &sc_disk, NEON_CYAN);
    make_sys_cell(page_system, MARGIN + 1 * col_w, 1 * row_h, "GPU",  &sc_gpu,  NEON_CYAN);
    make_sys_cell(page_system, MARGIN + 2 * col_w, 1 * row_h, "NET",  &sc_net,  COL_ACCENT);

    // Switch CPU (12 per-core bars) and GPU (util + VRAM) into bar mode.
    // The other 4 stay as sparklines (time-history is more useful there).
    make_cell_bars(&sc_cpu, 12, NEON_CYAN, NEON_CYAN, /*two_series=*/false);
    make_cell_bars(&sc_gpu, 1,  NEON_CYAN, COL_ACCENT, /*two_series=*/true);
}

// ---- Bitcoin page (futuristic neon style) ----

// Bitcoin brand color: official orange #F7931A
#define BTC_ORANGE  lv_color_hex(0xF7931A)
#define BTC_GRID    lv_color_hex(0x162028)   // chart grid line

// Build a small stat card with a label + value (used for HIGH/LOW/RANGE)
static lv_obj_t* make_btc_stat_card(lv_obj_t* parent, int x, int y, int w,
                                    const char* label_text, lv_obj_t** out_value,
                                    lv_color_t accent_color) {
    lv_obj_t* card = lv_obj_create(parent);
    lv_obj_set_pos(card, x, y);
    lv_obj_set_size(card, w, 46);
    lv_obj_set_style_bg_color(card, NEON_DEEP, 0);
    lv_obj_set_style_bg_opa(card, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(card, 4, 0);
    lv_obj_set_style_border_color(card, accent_color, 0);
    lv_obj_set_style_border_width(card, 1, 0);
    lv_obj_set_style_border_opa(card, LV_OPA_60, 0);
    lv_obj_set_style_pad_all(card, 6, 0);
    lv_obj_clear_flag(card, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(card, LV_OBJ_FLAG_EVENT_BUBBLE);

    lv_obj_t* lbl = lv_label_create(card);
    lv_label_set_text(lbl, label_text);
    lv_obj_set_style_text_font(lbl, &font_styrene_12, 0);
    lv_obj_set_style_text_color(lbl, accent_color, 0);
    lv_obj_align(lbl, LV_ALIGN_TOP_LEFT, 0, 0);

    *out_value = lv_label_create(card);
    lv_label_set_text(*out_value, "---");
    lv_obj_set_style_text_font(*out_value, &font_styrene_16, 0);
    lv_obj_set_style_text_color(*out_value, COL_TEXT, 0);
    lv_obj_align(*out_value, LV_ALIGN_BOTTOM_LEFT, 0, 0);

    return card;
}

static void init_page_bitcoin(lv_obj_t* scr) {
    page_bitcoin = make_page(scr);

    // ====== Header bar: ₿ logo + label + price + change ======
    lv_obj_t* header = lv_obj_create(page_bitcoin);
    lv_obj_set_pos(header, MARGIN, 0);
    lv_obj_set_size(header, CONTENT_W, 50);
    lv_obj_set_style_bg_color(header, NEON_DEEP, 0);
    lv_obj_set_style_bg_opa(header, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(header, 4, 0);
    lv_obj_set_style_border_color(header, BTC_ORANGE, 0);
    lv_obj_set_style_border_width(header, 1, 0);
    lv_obj_set_style_border_opa(header, LV_OPA_70, 0);
    lv_obj_set_style_pad_all(header, 6, 0);
    lv_obj_clear_flag(header, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(header, LV_OBJ_FLAG_EVENT_BUBBLE);

    // ₿ Bitcoin symbol — big orange B in a square badge
    lv_obj_t* btc_badge = lv_obj_create(header);
    lv_obj_set_size(btc_badge, 38, 38);
    lv_obj_align(btc_badge, LV_ALIGN_LEFT_MID, 0, 0);
    lv_obj_set_style_bg_color(btc_badge, BTC_ORANGE, 0);
    lv_obj_set_style_bg_opa(btc_badge, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(btc_badge, 6, 0);
    lv_obj_set_style_border_width(btc_badge, 0, 0);
    lv_obj_set_style_pad_all(btc_badge, 0, 0);
    lv_obj_clear_flag(btc_badge, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(btc_badge, LV_OBJ_FLAG_EVENT_BUBBLE);

    lv_obj_t* btc_symbol = lv_label_create(btc_badge);
    lv_label_set_text(btc_symbol, "B");   // Ascii B as bitcoin glyph (font safe)
    lv_obj_set_style_text_font(btc_symbol, &font_styrene_24, 0);
    lv_obj_set_style_text_color(btc_symbol, NEON_DEEP, 0);
    lv_obj_center(btc_symbol);

    // "BITCOIN / USD" label
    lv_obj_t* lbl_pair = lv_label_create(header);
    lv_label_set_text(lbl_pair, "BTC/USD");
    lv_obj_set_style_text_font(lbl_pair, &font_styrene_12, 0);
    lv_obj_set_style_text_color(lbl_pair, NEON_CYAN, 0);
    lv_obj_align(lbl_pair, LV_ALIGN_LEFT_MID, 50, -10);

    // Price
    btc_price_label = lv_label_create(header);
    lv_label_set_text(btc_price_label, "$-----");
    lv_obj_set_style_text_font(btc_price_label, &font_styrene_24, 0);
    lv_obj_set_style_text_color(btc_price_label, COL_TEXT, 0);
    lv_obj_align(btc_price_label, LV_ALIGN_LEFT_MID, 50, 8);

    // 24h change arrow + percentage (right side)
    btc_arrow_label = lv_label_create(header);
    lv_label_set_text(btc_arrow_label, "-");
    lv_obj_set_style_text_font(btc_arrow_label, &font_styrene_24, 0);
    lv_obj_set_style_text_color(btc_arrow_label, COL_DIM, 0);
    lv_obj_align(btc_arrow_label, LV_ALIGN_RIGHT_MID, -70, 0);

    btc_change_label = lv_label_create(header);
    lv_label_set_text(btc_change_label, "24h ---%");
    lv_obj_set_style_text_font(btc_change_label, &font_styrene_16, 0);
    lv_obj_set_style_text_color(btc_change_label, COL_DIM, 0);
    lv_obj_align(btc_change_label, LV_ALIGN_RIGHT_MID, -4, 0);

    // ====== Chart: 6-month history, neon orange line ======
    btc_chart = lv_chart_create(page_bitcoin);
    lv_obj_set_pos(btc_chart, MARGIN, 54);
    lv_obj_set_size(btc_chart, CONTENT_W, 116);
    lv_chart_set_type(btc_chart, LV_CHART_TYPE_LINE);
    lv_chart_set_point_count(btc_chart, 20);
    lv_chart_set_update_mode(btc_chart, LV_CHART_UPDATE_MODE_SHIFT);
    lv_chart_set_div_line_count(btc_chart, 4, 6);

    lv_obj_set_style_bg_color(btc_chart, NEON_DEEP, 0);
    lv_obj_set_style_bg_opa(btc_chart, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(btc_chart, 4, 0);
    lv_obj_set_style_border_color(btc_chart, NEON_BORDER, 0);
    lv_obj_set_style_border_width(btc_chart, 1, 0);
    lv_obj_set_style_pad_all(btc_chart, 6, 0);

    // Grid lines: subtle cyan-tinted dark
    lv_obj_set_style_line_color(btc_chart, BTC_GRID, LV_PART_MAIN);
    lv_obj_set_style_line_width(btc_chart, 1, LV_PART_MAIN);
    lv_obj_set_style_line_opa(btc_chart, LV_OPA_60, LV_PART_MAIN);

    // Chart line: bright orange, thick for visibility on AMOLED
    lv_obj_set_style_line_width(btc_chart, 3, LV_PART_ITEMS);
    lv_obj_set_style_line_color(btc_chart, BTC_ORANGE, LV_PART_ITEMS);
    // Hide point markers (we want a clean line look)
    lv_obj_set_style_size(btc_chart, 0, 0, LV_PART_INDICATOR);

    btc_series = lv_chart_add_series(btc_chart, BTC_ORANGE, LV_CHART_AXIS_PRIMARY_Y);

    // ====== Footer: 3 stat cards (HIGH / LOW / POSITION) ======
    int card_gap = 6;
    int card_w = (CONTENT_W - 2 * card_gap) / 3;
    int card_y = 174;

    make_btc_stat_card(page_bitcoin, MARGIN, card_y, card_w,
                       "6M HIGH", &btc_high_value, NEON_CYAN);
    make_btc_stat_card(page_bitcoin, MARGIN + card_w + card_gap, card_y, card_w,
                       "6M LOW", &btc_low_value, NEON_CYAN);
    make_btc_stat_card(page_bitcoin, MARGIN + 2 * (card_w + card_gap), card_y, card_w,
                       "POSITION", &btc_range_value, BTC_ORANGE);
}

// Shared placeholder helper for any future unbuilt page.
static void init_placeholder_page(lv_obj_t** out_page, lv_obj_t* scr, const char* text) {
    *out_page = make_page(scr);
    lv_obj_t* lbl = lv_label_create(*out_page);
    lv_label_set_text(lbl, text);
    lv_obj_set_style_text_font(lbl, &font_styrene_28, 0);
    lv_obj_set_style_text_color(lbl, COL_DIM, 0);
    lv_obj_center(lbl);
}

// ---- Actions page: 6 buttons that trigger user scripts on the host ----
// Each tap sends {"action":N} over USB serial. The daemon listens for this
// message and runs ~/.config/clawdmeter/action<N>.sh.

static void action_clicked_cb(lv_event_t* e) {
    int idx = (int)(intptr_t)lv_event_get_user_data(e);
    Serial.printf("{\"action\":%d}\n", idx + 1);
}

static void make_action_button(lv_obj_t* parent, int x, int y, int idx,
                               const char* label_text, lv_color_t accent) {
    lv_obj_t* btn = lv_obj_create(parent);
    lv_obj_set_pos(btn, x, y);
    lv_obj_set_size(btn, SYS_CELL_W, SYS_CELL_H);
    lv_obj_set_style_bg_color(btn, NEON_DEEP, 0);
    lv_obj_set_style_bg_opa(btn, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(btn, 4, 0);
    lv_obj_set_style_border_color(btn, accent, 0);
    lv_obj_set_style_border_width(btn, 1, 0);
    lv_obj_set_style_border_opa(btn, LV_OPA_60, 0);
    lv_obj_set_style_pad_all(btn, 0, 0);
    lv_obj_clear_flag(btn, LV_OBJ_FLAG_SCROLLABLE);

    // Pressed state: border lights up to full opacity + brighter fill
    lv_obj_set_style_border_opa(btn, LV_OPA_COVER, LV_STATE_PRESSED);
    lv_obj_set_style_bg_color(btn, NEON_BORDER, LV_STATE_PRESSED);

    // Big number in accent color (top)
    char num_str[4];
    snprintf(num_str, sizeof(num_str), "%d", idx + 1);
    lv_obj_t* num = lv_label_create(btn);
    lv_label_set_text(num, num_str);
    lv_obj_set_style_text_font(num, &font_styrene_48, 0);
    lv_obj_set_style_text_color(num, accent, 0);
    lv_obj_align(num, LV_ALIGN_CENTER, 0, -10);
    lv_obj_add_flag(num, LV_OBJ_FLAG_EVENT_BUBBLE);

    // Small label below
    lv_obj_t* lbl = lv_label_create(btn);
    lv_label_set_text(lbl, label_text);
    lv_obj_set_style_text_font(lbl, &font_styrene_12, 0);
    lv_obj_set_style_text_color(lbl, COL_DIM, 0);
    lv_obj_align(lbl, LV_ALIGN_BOTTOM_MID, 0, -6);
    lv_obj_add_flag(lbl, LV_OBJ_FLAG_EVENT_BUBBLE);

    lv_obj_add_event_cb(btn, action_clicked_cb, LV_EVENT_CLICKED,
                        (void*)(intptr_t)idx);
}

static void init_page_actions(lv_obj_t* scr) {
    page_actions = make_page(scr);
    int col_w = SYS_CELL_W + SYS_GAP;
    int row_h = SYS_CELL_H + SYS_GAP;

    // Alternate cyan/orange for visual rhythm
    const lv_color_t colors[6] = {
        NEON_CYAN, COL_ACCENT, NEON_CYAN,
        COL_ACCENT, NEON_CYAN, COL_ACCENT,
    };
    const char* labels[6] = {
        "LOCK",  "SCREEN", "TERMINAL",
        "VOL +", "VOL -",  "MUTE",
    };

    for (int i = 0; i < 6; i++) {
        int col = i % 3;
        int row = i / 3;
        make_action_button(page_actions,
                           MARGIN + col * col_w, row * row_h,
                           i, labels[i], colors[i]);
    }
}

// ======== Chrome ========

static void init_chrome(lv_obj_t* scr) {
    lbl_title = lv_label_create(scr);
    lv_label_set_text(lbl_title, "Claude usage");
    lv_obj_set_style_text_font(lbl_title, &font_tiempos_28, 0);
    lv_obj_set_style_text_color(lbl_title, COL_TEXT, 0);
    lv_obj_align(lbl_title, LV_ALIGN_TOP_MID, 0, TITLE_Y);

    lbl_model = make_pill(scr, "");
    lv_obj_align(lbl_model, LV_ALIGN_TOP_RIGHT, -MARGIN, TITLE_Y + 4);
    lv_obj_add_flag(lbl_model, LV_OBJ_FLAG_HIDDEN);

    // Effort pill (top-left, symmetric with model on right)
    lbl_effort = make_pill(scr, "");
    lv_obj_align(lbl_effort, LV_ALIGN_TOP_LEFT, MARGIN, TITLE_Y + 4);
    lv_obj_add_flag(lbl_effort, LV_OBJ_FLAG_HIDDEN);

    // Nav button content:
    //   0 Usage   → Claude pixel-art mascot (idle breathe)
    //   1 System  → equalizer bars pictogram (cyan)
    //   2 Bitcoin → pulsing ₿ glyph pictogram (orange)
    //   3 Actions → lightning bolt pictogram (cyan + orange flash)
    // Slot 0 stays a character; slots 1-3 are informative icons that
    // visually announce what each tab does.
    for (int i = 0; i < 4; i++) {
        int x = MARGIN + i * (NAV_BTN_W + NAV_GAP);
        nav_btns[i] = make_nav_button_shell(scr, x, NAV_Y);
        clawd_thumb_create(i, nav_btns[i], 2, lv_color_to_u16(NEON_DEEP));
        switch (i) {
            case 0: clawd_thumb_set_animation(i, "idle breathe"); break;
            case 1: clawd_thumb_set_pictogram(i, "system eq");    break;
            case 2: clawd_thumb_set_pictogram(i, "bitcoin coin"); break;
            case 3: clawd_thumb_set_pictogram(i, "actions bolt"); break;
        }
        lv_obj_t* thumb = clawd_thumb_canvas(i);
        if (thumb) lv_obj_center(thumb);
        lv_obj_add_event_cb(nav_btns[i], nav_click_cb, LV_EVENT_CLICKED,
                            (void*)(intptr_t)(SCREEN_USAGE + i));
    }
}

// ======== Public API ========

void ui_init(void) {
    lv_obj_t* scr = lv_screen_active();
    lv_obj_set_style_bg_color(scr, COL_BG, 0);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);

    init_icon_dsc_rgb565a8(&logo_dsc, LOGO_WIDTH, LOGO_HEIGHT, logo_data);
    init_battery_icons();
    init_nav_icons();

    init_page_usage(scr);
    init_page_system(scr);
    init_page_bitcoin(scr);
    init_page_actions(scr);

    splash_init(scr);

    // Chrome is created AFTER pages so it draws on top of the page area
    // (handy if a future page ever overflows into the title strip).
    init_chrome(scr);

    if (splash_get_root()) {
        lv_obj_add_event_cb(splash_get_root(), splash_toggle_cb, LV_EVENT_CLICKED, NULL);
    }

    // 80x80 logo doesn't fit the 50px header on 480x320 — keep it hidden.
    logo_img = lv_image_create(scr);
    lv_image_set_src(logo_img, &logo_dsc);
    lv_obj_set_pos(logo_img, MARGIN, TITLE_Y - 4);
    lv_obj_add_flag(logo_img, LV_OBJ_FLAG_HIDDEN);

    battery_img = lv_image_create(scr);
    lv_image_set_src(battery_img, &battery_dscs[0]);
    lv_obj_set_pos(battery_img, SCR_W - 48 - MARGIN, TITLE_Y + 4);
    lv_obj_add_flag(battery_img, LV_OBJ_FLAG_HIDDEN);
}

void ui_update(const UsageData* data) {
    if (!data->valid) return;

    int s_pct = (int)(data->session_pct + 0.5f);
    lv_label_set_text_fmt(lbl_session_pct, "%d%%", s_pct);
    lv_bar_set_value(bar_session, s_pct, LV_ANIM_ON);
    lv_obj_set_style_bg_color(bar_session, pct_color(data->session_pct), LV_PART_INDICATOR);

    char buf[48];
    format_reset_time(data->session_reset_mins, buf, sizeof(buf));
    lv_label_set_text(lbl_session_reset, buf);

    int w_pct = (int)(data->weekly_pct + 0.5f);
    lv_label_set_text_fmt(lbl_weekly_pct, "%d%%", w_pct);
    lv_bar_set_value(bar_weekly, w_pct, LV_ANIM_ON);
    lv_obj_set_style_bg_color(bar_weekly, pct_color(data->weekly_pct), LV_PART_INDICATOR);

    format_reset_time(data->weekly_reset_mins, buf, sizeof(buf));
    lv_label_set_text(lbl_weekly_reset, buf);

    if (data->model[0]) {
        lv_label_set_text(lbl_model, data->model);
        strncpy(last_model, data->model, sizeof(last_model) - 1);
        last_model[sizeof(last_model) - 1] = '\0';
        if (current_screen == SCREEN_USAGE) {
            lv_obj_clear_flag(lbl_model, LV_OBJ_FLAG_HIDDEN);
        }
    }

    if (data->effort[0]) {
        // Show as uppercase tech label (e.g. "HIGH", "MAX") and remember
        // it for re-display when the user navigates back to Usage.
        char up[16];
        size_t n = strlen(data->effort);
        if (n >= sizeof(up)) n = sizeof(up) - 1;
        for (size_t i = 0; i < n; i++) {
            up[i] = (data->effort[i] >= 'a' && data->effort[i] <= 'z')
                  ? data->effort[i] - 32
                  : data->effort[i];
        }
        up[n] = '\0';
        lv_label_set_text(lbl_effort, up);
        strncpy(last_effort, up, sizeof(last_effort) - 1);
        last_effort[sizeof(last_effort) - 1] = '\0';
        if (current_screen == SCREEN_USAGE) {
            lv_obj_clear_flag(lbl_effort, LV_OBJ_FLAG_HIDDEN);
        }
    }
}

static lv_color_t temp_color(int t) {
    if (t >= 80) return COL_RED;
    if (t >= 65) return COL_AMBER;
    return COL_GREEN;
}

// Push a new sample into the sparkline + update the headline value text.
// Color tint of the chart line follows the current sample (green/amber/red).
static void set_cell(sys_cell_t* c, const char* value_str, int bar_pct, lv_color_t color) {
    lv_label_set_text(c->value, value_str);
    if (bar_pct < 0) bar_pct = 0;
    if (bar_pct > 100) bar_pct = 100;
    if (c->bar_count == 0) {
        // Sparkline mode: shift in the new sample, tint the line
        lv_chart_set_next_value(c->chart, c->series, bar_pct);
        lv_obj_set_style_line_color(c->chart, color, LV_PART_ITEMS);
    }
    lv_obj_set_style_text_color(c->value, color, 0);
}

// Snapshot-bars update: overwrite all N bars with current per-element values.
static void set_cell_bars(sys_cell_t* c, const char* value_str,
                          const int* values, int n, lv_color_t color) {
    lv_label_set_text(c->value, value_str);
    if (c->bar_count <= 0 || !c->series) return;
    int limit = (n < c->bar_count) ? n : c->bar_count;
    for (int i = 0; i < limit; i++) {
        int v = values[i];
        if (v < 0) v = 0;
        if (v > 100) v = 100;
        lv_chart_set_value_by_id(c->chart, c->series, i, v);
    }
    // Tint headline + bar fill to the alert level
    lv_obj_set_style_text_color(c->value, color, 0);
}

// 2-bar variant for GPU: util on series, vram on series2 (different colors)
static void set_cell_two_bars(sys_cell_t* c, const char* value_str,
                              int v1, int v2, lv_color_t headline_color) {
    lv_label_set_text(c->value, value_str);
    if (!c->series || !c->series2) return;
    if (v1 < 0) v1 = 0; if (v1 > 100) v1 = 100;
    if (v2 < 0) v2 = 0; if (v2 > 100) v2 = 100;
    lv_chart_set_value_by_id(c->chart, c->series,  0, v1);
    lv_chart_set_value_by_id(c->chart, c->series2, 0, v2);
    lv_obj_set_style_text_color(c->value, headline_color, 0);
}

void ui_update_system_stats(const SystemStats* s) {
    if (!s || !s->valid) return;
    char buf[24];

    // ---- CPU: per-core bars (snapshot) + aggregate headline ----
    snprintf(buf, sizeof(buf), "%d%%", s->cpu);
    if (s->cpu_core_count > 0) {
        set_cell_bars(&sc_cpu, buf, s->cpu_cores, s->cpu_core_count,
                      pct_color(s->cpu));
    } else {
        // Daemon didn't send per-core data — fall back to sparkline behaviour
        set_cell(&sc_cpu, buf, s->cpu, pct_color(s->cpu));
    }

    snprintf(buf, sizeof(buf), "%d%%", s->ram);
    set_cell(&sc_ram, buf, s->ram, pct_color(s->ram));

    snprintf(buf, sizeof(buf), "%d%%", s->disk);
    set_cell(&sc_disk, buf, s->disk, pct_color(s->disk));

    snprintf(buf, sizeof(buf), "%d\xC2\xB0""C", s->temp);   // "<n>°C"
    set_cell(&sc_temp, buf, s->temp, temp_color(s->temp));

    // ---- GPU: util + VRAM as two bars ----
    if (s->gpu < 0 && s->gpu_count == 0) {
        // No GPU detected at all — clear the cell text
        set_cell_two_bars(&sc_gpu, "N/A", 0, 0, COL_DIM);
    } else {
        int util = (s->gpu_count > 0) ? s->gpu_util[0] : s->gpu;
        int vram = (s->gpu_count > 0) ? s->gpu_vram[0] : s->vram;
        if (util < 0) util = 0;
        if (vram < 0) vram = 0;
        snprintf(buf, sizeof(buf), "%d%% / %d%%", util, vram);
        set_cell_two_bars(&sc_gpu, buf, util, vram, pct_color(util));
    }

    // Net is in KB/s. Show as KB/s under 1 MB/s, else MB/s with one decimal.
    // Bar caps at 5 MB/s — past that we're saturating most home links anyway.
    if (s->net < 1024) {
        snprintf(buf, sizeof(buf), "%d KB/s", s->net);
    } else {
        snprintf(buf, sizeof(buf), "%d.%d MB/s", s->net / 1024, (s->net % 1024) / 102);
    }
    int net_pct = (int)((long)s->net * 100 / 5120);   // 5120 KB/s = 5 MB/s
    set_cell(&sc_net, buf, net_pct, COL_ACCENT);
}

// Format a price with thousand separators: 76560 -> "76,560"
static void format_price_with_commas(int price, char* buf, size_t buflen) {
    char raw[16];
    snprintf(raw, sizeof(raw), "%d", price);
    int len = strlen(raw);
    int out = 0;
    for (int i = 0; i < len && out < (int)buflen - 2; i++) {
        if (i > 0 && (len - i) % 3 == 0) {
            buf[out++] = ',';
        }
        buf[out++] = raw[i];
    }
    buf[out] = '\0';
}

void ui_update_bitcoin_data(const BitcoinData* data) {
    if (!data || !data->valid) return;

    char buf[48];
    char num_buf[24];

    // ----- Price with thousand separators -----
    format_price_with_commas(data->price, num_buf, sizeof(num_buf));
    snprintf(buf, sizeof(buf), "$%s", num_buf);
    lv_label_set_text(btc_price_label, buf);

    // ----- 24h change with arrow indicator -----
    lv_color_t change_color = COL_DIM;
    const char* arrow = "=";
    int change_bps = data->price_24h_change_bps;
    if (change_bps > 0) {
        change_color = COL_GREEN;
        arrow = "^";   // up triangle ASCII
        snprintf(buf, sizeof(buf), "+%d.%02d%%", change_bps / 100, change_bps % 100);
    } else if (change_bps < 0) {
        change_color = COL_RED;
        arrow = "v";   // down marker ASCII
        snprintf(buf, sizeof(buf), "%d.%02d%%", change_bps / 100, (-change_bps) % 100);
    } else {
        snprintf(buf, sizeof(buf), "0.00%%");
    }
    lv_label_set_text(btc_change_label, buf);
    lv_obj_set_style_text_color(btc_change_label, change_color, 0);
    lv_label_set_text(btc_arrow_label, arrow);
    lv_obj_set_style_text_color(btc_arrow_label, change_color, 0);

    // ----- Compute 6-month min/max from history -----
    int min_price = data->price;
    int max_price = data->price;
    for (int i = 0; i < data->history_count; i++) {
        if (data->price_history[i] > 0) {
            if (data->price_history[i] < min_price) min_price = data->price_history[i];
            if (data->price_history[i] > max_price) max_price = data->price_history[i];
        }
    }
    // Pull in 24h range if it extends beyond what we have
    if (data->price_24h_min > 0 && data->price_24h_min < min_price) min_price = data->price_24h_min;
    if (data->price_24h_max > max_price) max_price = data->price_24h_max;

    // ----- Update stat cards (HIGH / LOW / POSITION) -----
    format_price_with_commas(max_price, num_buf, sizeof(num_buf));
    snprintf(buf, sizeof(buf), "$%s", num_buf);
    lv_label_set_text(btc_high_value, buf);

    format_price_with_commas(min_price, num_buf, sizeof(num_buf));
    snprintf(buf, sizeof(buf), "$%s", num_buf);
    lv_label_set_text(btc_low_value, buf);

    // POSITION: where in the 6M range is the current price (0% = at low, 100% = at high)
    int range_full = max_price - min_price;
    int position_pct = 50;
    if (range_full > 0) {
        position_pct = ((data->price - min_price) * 100) / range_full;
        if (position_pct < 0) position_pct = 0;
        if (position_pct > 100) position_pct = 100;
    }
    snprintf(buf, sizeof(buf), "%d%%", position_pct);
    lv_label_set_text(btc_range_value, buf);
    // Color the position by where it is in the range (high = orange/red, low = cyan)
    lv_color_t pos_color = BTC_ORANGE;
    if (position_pct < 33) pos_color = NEON_CYAN;
    else if (position_pct < 66) pos_color = COL_AMBER;
    lv_obj_set_style_text_color(btc_range_value, pos_color, 0);

    // ----- Set chart Y range with 5% padding -----
    int range = max_price - min_price;
    if (range == 0) range = 1;
    int padding = range / 20;
    lv_chart_set_range(btc_chart, LV_CHART_AXIS_PRIMARY_Y,
                       min_price - padding, max_price + padding);

    // ----- Populate chart -----
    lv_chart_remove_series(btc_chart, btc_series);
    btc_series = lv_chart_add_series(btc_chart, BTC_ORANGE, LV_CHART_AXIS_PRIMARY_Y);

    for (int i = 0; i < data->history_count; i++) {
        if (data->price_history[i] > 0) {
            lv_chart_set_next_value(btc_chart, btc_series, data->price_history[i]);
        }
    }
    if (data->history_count < 20) {
        lv_chart_set_next_value(btc_chart, btc_series, data->price);
    }
}

void ui_tick_anim(void) {
    if (current_screen == SCREEN_SPLASH) return;

    // Claude thumbnail in the Usage nav button (visible on every non-splash
    // screen — it's part of the always-on bottom bar and doubles as the
    // "I'm alive" indicator the top-left spinner used to provide).
    clawd_thumb_tick();
}

static bool battery_known = false;

static void apply_battery_visibility(void) {
    if (!battery_img) return;
    if (!battery_known || current_screen == SCREEN_SPLASH) {
        lv_obj_add_flag(battery_img, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_clear_flag(battery_img, LV_OBJ_FLAG_HIDDEN);
    }
}

static void splash_toggle_cb(lv_event_t* e) {
    (void)e;
    ui_toggle_splash();
}

static void nav_click_cb(lv_event_t* e) {
    screen_t target = (screen_t)(intptr_t)lv_event_get_user_data(e);
    ui_show_screen(target);
}

static void update_nav_active(screen_t s) {
    int active_idx = (int)s - (int)SCREEN_USAGE;
    for (int i = 0; i < 4; i++) {
        // Active: cyan border at full opacity, slightly brighter fill.
        // Inactive: deep dark bg with half-opacity cyan border.
        bool active = (i == active_idx);
        lv_obj_set_style_bg_color(nav_btns[i], active ? NEON_BORDER : NEON_DEEP, 0);
        lv_obj_set_style_border_opa(nav_btns[i],
                                    active ? LV_OPA_COVER : LV_OPA_50, 0);
        // Keep each thumbnail's palette[0] (its own background) in sync with
        // its button so the 40x40 canvas doesn't show a stray black square.
        clawd_thumb_set_bg(i, lv_color_to_u16(active ? NEON_BORDER : NEON_DEEP));
    }
}

static const char* title_for_screen(screen_t s) {
    switch (s) {
    case SCREEN_USAGE:   return "Claude usage";
    case SCREEN_SYSTEM:  return "\xC3\x89tat syst\xC3\xA8me";   // "État système"
    case SCREEN_BITCOIN: return "Bitcoin";
    case SCREEN_ACTIONS: return "Actions syst\xC3\xA8me";       // "Actions système"
    default:             return "";
    }
}

static void apply_chrome_visibility(bool show) {
    if (show) {
        lv_obj_add_flag(lbl_title, LV_OBJ_FLAG_HIDDEN);  // Always hide title to save space
        for (int i = 0; i < 4; i++) lv_obj_clear_flag(nav_btns[i], LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(lbl_title, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(lbl_model, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(lbl_effort, LV_OBJ_FLAG_HIDDEN);
        for (int i = 0; i < 4; i++) lv_obj_add_flag(nav_btns[i], LV_OBJ_FLAG_HIDDEN);
    }
}

static void update_chrome_for_screen(screen_t s) {
    if (s == SCREEN_SPLASH) {
        apply_chrome_visibility(false);
        return;
    }
    apply_chrome_visibility(true);
    lv_label_set_text(lbl_title, title_for_screen(s));
    update_nav_active(s);

    // Model + effort pills only visible on Usage page (after first values).
    if (s == SCREEN_USAGE && last_model[0]) {
        lv_label_set_text(lbl_model, last_model);
        lv_obj_clear_flag(lbl_model, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(lbl_model, LV_OBJ_FLAG_HIDDEN);
    }
    if (s == SCREEN_USAGE && last_effort[0]) {
        lv_label_set_text(lbl_effort, last_effort);
        lv_obj_clear_flag(lbl_effort, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(lbl_effort, LV_OBJ_FLAG_HIDDEN);
    }
}

void ui_show_screen(screen_t screen) {
    lv_obj_add_flag(page_usage,   LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(page_system,  LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(page_bitcoin, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(page_actions, LV_OBJ_FLAG_HIDDEN);
    splash_hide();

    switch (screen) {
    case SCREEN_SPLASH:  splash_show(); break;
    case SCREEN_USAGE:   lv_obj_clear_flag(page_usage,   LV_OBJ_FLAG_HIDDEN); break;
    case SCREEN_SYSTEM:  lv_obj_clear_flag(page_system,  LV_OBJ_FLAG_HIDDEN); break;
    case SCREEN_BITCOIN: lv_obj_clear_flag(page_bitcoin, LV_OBJ_FLAG_HIDDEN); break;
    case SCREEN_ACTIONS: lv_obj_clear_flag(page_actions, LV_OBJ_FLAG_HIDDEN); break;
    default: break;
    }

    if (logo_img) lv_obj_add_flag(logo_img, LV_OBJ_FLAG_HIDDEN);

    current_screen = screen;
    update_chrome_for_screen(screen);
    apply_battery_visibility();
}

void ui_toggle_splash(void) {
    ui_show_screen(current_screen == SCREEN_SPLASH ? SCREEN_USAGE : SCREEN_SPLASH);
}

screen_t ui_get_current_screen(void) {
    return current_screen;
}

void ui_update_battery(int percent, bool charging) {
    if (percent < 0 && !charging) {
        battery_known = false;
        apply_battery_visibility();
        return;
    }
    battery_known = true;

    int idx;
    if (charging) {
        idx = 4;
    } else if (percent <= 10) {
        idx = 0;
    } else if (percent <= 35) {
        idx = 1;
    } else if (percent <= 75) {
        idx = 2;
    } else {
        idx = 3;
    }
    lv_image_set_src(battery_img, &battery_dscs[idx]);
    apply_battery_visibility();
}
