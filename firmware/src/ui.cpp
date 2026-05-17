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
#define COL_NAV_ACTIVE THEME_PASTEL_BLUE

// ---- Layout constants for 480x320 landscape (Panlee SC01 Plus) ----
#define SCR_W         480
#define SCR_H         320
#define MARGIN        12
#define TITLE_Y       8
#define CONTENT_Y     60
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

static lv_obj_t* make_pill(lv_obj_t* parent, const char* text) {
    lv_obj_t* lbl = lv_label_create(parent);
    lv_label_set_text(lbl, text);
    lv_obj_set_style_text_font(lbl, &font_styrene_20, 0);
    lv_obj_set_style_text_color(lbl, COL_TEXT, 0);
    lv_obj_set_style_bg_color(lbl, COL_BAR_BG, 0);
    lv_obj_set_style_bg_opa(lbl, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(lbl, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_pad_left(lbl, 12, 0);
    lv_obj_set_style_pad_right(lbl, 12, 0);
    lv_obj_set_style_pad_top(lbl, 4, 0);
    lv_obj_set_style_pad_bottom(lbl, 4, 0);
    return lbl;
}

// Empty nav-button shell (icon is added by the caller — usually an
// lv_image, but the Usage button hosts the animated Claude canvas).
static lv_obj_t* make_nav_button_shell(lv_obj_t* parent, int x, int y) {
    lv_obj_t* btn = lv_obj_create(parent);
    lv_obj_set_pos(btn, x, y);
    lv_obj_set_size(btn, NAV_BTN_W, NAV_BTN_H);
    lv_obj_set_style_bg_color(btn, COL_BAR_BG, 0);
    lv_obj_set_style_bg_opa(btn, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(btn, 10, 0);
    lv_obj_set_style_border_width(btn, 0, 0);
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

// One Session/Hebdo panel: pill label at top, big %, bar, reset row.
static void make_usage_panel(lv_obj_t* parent, int x, int y, const char* pill_text,
                             lv_obj_t** out_pct, lv_obj_t** out_pill,
                             lv_obj_t** out_bar, lv_obj_t** out_reset) {
    lv_obj_t* panel = make_panel(parent, x, y, PANEL_W, PANEL_H);

    *out_pill = make_pill(panel, pill_text);
    lv_obj_align(*out_pill, LV_ALIGN_TOP_LEFT, 0, 0);

    *out_pct = lv_label_create(panel);
    lv_label_set_text(*out_pct, "---%");
    lv_obj_set_style_text_font(*out_pct, &font_styrene_48, 0);
    lv_obj_set_style_text_color(*out_pct, COL_TEXT, 0);
    lv_obj_align(*out_pct, LV_ALIGN_LEFT_MID, 0, 0);

    *out_bar = make_bar(panel, 0, PANEL_H - 64, PANEL_W - 24, 18);
    lv_obj_align(*out_bar, LV_ALIGN_BOTTOM_LEFT, 0, -28);

    *out_reset = lv_label_create(panel);
    lv_label_set_text(*out_reset, "---");
    lv_obj_set_style_text_font(*out_reset, &font_styrene_20, 0);
    lv_obj_set_style_text_color(*out_reset, COL_DIM, 0);
    lv_obj_align(*out_reset, LV_ALIGN_BOTTOM_LEFT, 0, 0);
}

static void init_page_usage(lv_obj_t* scr) {
    page_usage = make_page(scr);
    // Panels live at (CONTENT_Y=60) globally, but inside the page they're
    // at (0,0); the page container itself is offset by CONTENT_Y.
    make_usage_panel(page_usage, PANEL_X_LEFT, 0, "Session",
                     &lbl_session_pct, &lbl_session_label,
                     &bar_session, &lbl_session_reset);
    make_usage_panel(page_usage, PANEL_X_RIGHT, 0, "Hebdo",
                     &lbl_weekly_pct, &lbl_weekly_label,
                     &bar_weekly, &lbl_weekly_reset);
}

// Shared placeholder helper for system / bitcoin / actions pages.
static void init_placeholder_page(lv_obj_t** out_page, lv_obj_t* scr, const char* text) {
    *out_page = make_page(scr);
    lv_obj_t* lbl = lv_label_create(*out_page);
    lv_label_set_text(lbl, text);
    lv_obj_set_style_text_font(lbl, &font_styrene_28, 0);
    lv_obj_set_style_text_color(lbl, COL_DIM, 0);
    lv_obj_center(lbl);
}

// ======== Chrome ========

static void init_chrome(lv_obj_t* scr) {
    lbl_title = lv_label_create(scr);
    lv_label_set_text(lbl_title, "Claude usage");
    lv_obj_set_style_text_font(lbl_title, &font_tiempos_34, 0);
    lv_obj_set_style_text_color(lbl_title, COL_TEXT, 0);
    lv_obj_align(lbl_title, LV_ALIGN_TOP_MID, 0, TITLE_Y);

    lbl_model = make_pill(scr, "");
    lv_obj_align(lbl_model, LV_ALIGN_TOP_RIGHT, -MARGIN, TITLE_Y + 4);
    lv_obj_add_flag(lbl_model, LV_OBJ_FLAG_HIDDEN);

    // Button 0 (Usage) hosts the animated Claude thumbnail instead of a
    // static icon. The other three get their Lucide icons normally.
    for (int i = 0; i < 4; i++) {
        int x = MARGIN + i * (NAV_BTN_W + NAV_GAP);
        if (i == 0) {
            nav_btns[i] = make_nav_button_shell(scr, x, NAV_Y);
            // SCREEN_USAGE is the default boot screen → starts active.
            clawd_thumb_create(nav_btns[i], 2, lv_color_to_u16(COL_NAV_ACTIVE));
            lv_obj_t* thumb = clawd_thumb_canvas();
            if (thumb) lv_obj_center(thumb);
        } else {
            nav_btns[i] = make_nav_button(scr, x, NAV_Y, &nav_icon_dscs[i]);
        }
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
    init_placeholder_page(&page_system,  scr, "\xC3\x80 venir");
    init_placeholder_page(&page_bitcoin, scr, "\xC3\x80 venir");
    init_placeholder_page(&page_actions, scr, "\xC3\x80 venir");

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
        lv_color_t bg = (i == active_idx) ? COL_NAV_ACTIVE : COL_BAR_BG;
        lv_obj_set_style_bg_color(nav_btns[i], bg, 0);
    }
    // Keep the Clawd thumbnail's background colour in sync so palette[0]
    // (the animation's own background) blends into the active/inactive
    // button colour instead of showing a black 40x40 square.
    clawd_thumb_set_bg(lv_color_to_u16(
        (active_idx == 0) ? COL_NAV_ACTIVE : COL_BAR_BG));
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
        lv_obj_clear_flag(lbl_title, LV_OBJ_FLAG_HIDDEN);
        for (int i = 0; i < 4; i++) lv_obj_clear_flag(nav_btns[i], LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(lbl_title, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(lbl_model, LV_OBJ_FLAG_HIDDEN);
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

    // Model pill only visible on Usage page and only after we have a model.
    if (s == SCREEN_USAGE && last_model[0]) {
        lv_label_set_text(lbl_model, last_model);
        lv_obj_clear_flag(lbl_model, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(lbl_model, LV_OBJ_FLAG_HIDDEN);
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
