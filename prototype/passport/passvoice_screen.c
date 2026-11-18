// Throwaway display prototype. Also compiled by capture.c on macOS.
#include "passvoice_screen.h"
#include <stdio.h>

#define INK 0x081522
#define NAVY 0x0D1B2F
#define PANEL 0x1C3451
#define WHITE 0xF3FFFB
#define MUTED 0xB2C7D6
#define MINT 0x73E9C9
#define ICE 0xDFF7EF

typedef struct {
    const char *title;
    const char *detail;
    const char *key;
    const char *hint;
    uint32_t color;
} state_style_t;

static const state_style_t styles[] = {
    [PV_READY] = {"Ready", "Mac connected", "TALK", "Start recording", MINT},
    [PV_LISTENING] = {"Listening", "Sending audio to Mac", "STOP", "Stop recording", 0xFF9189},
    [PV_FINISHING] = {"Finishing", "Sending final audio", NULL, "Please wait", 0x99CCFF},
    [PV_OFFLINE] = {"Offline", "Waiting for Mac", NULL, "Open PassVoice on Mac", MUTED},
    [PV_LINK_ERROR] = {"Link slow", "Audio did not start", "RETRY", "Try recording again", 0xFFC788},
};

static lv_obj_t *box(lv_obj_t *parent, int x, int y, int w, int h, int radius, uint32_t color)
{
    lv_obj_t *obj = lv_obj_create(parent);
    lv_obj_remove_style_all(obj);
    lv_obj_remove_flag(obj, LV_OBJ_FLAG_SCROLLABLE | LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_pos(obj, x, y);
    lv_obj_set_size(obj, w, h);
    lv_obj_set_style_bg_color(obj, lv_color_hex(color), 0);
    lv_obj_set_style_bg_opa(obj, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(obj, radius, 0);
    return obj;
}

static void label(lv_obj_t *parent, const char *text, int x, int y, int w,
                  const lv_font_t *font, uint32_t color, lv_text_align_t alignment)
{
    lv_obj_t *obj = lv_label_create(parent);
    lv_obj_set_pos(obj, x, y);
    lv_obj_set_width(obj, w);
    lv_obj_set_style_text_font(obj, font, 0);
    lv_obj_set_style_text_color(obj, lv_color_hex(color), 0);
    lv_obj_set_style_text_align(obj, alignment, 0);
    lv_label_set_text(obj, text);
}

// The four bars and I-beam keep the geometry of app/PassVoice.svg.
// Scale in integer units so the same shapes are readable in all three layouts.
static void waveform(lv_obj_t *parent, int x, int y, int scale, uint32_t color)
{
    const int heights[] = {5, 13, 9, 5};
    for (int i = 0; i < 4; ++i) {
        box(parent, x + scale * 4 * i, y + (13 - heights[i]) * scale / 2,
            2 * scale, heights[i] * scale, scale, color);
    }
}

static void cursor(lv_obj_t *parent, int x, int y, int scale, uint32_t color)
{
    box(parent, x + 2 * scale, y + scale, 2 * scale, 11 * scale, scale, color);
    box(parent, x, y + scale, 6 * scale, 2 * scale, scale, color);
    box(parent, x, y + 10 * scale, 6 * scale, 2 * scale, scale, color);
}

static void mark(lv_obj_t *parent, int x, int y, int scale, uint32_t wave_color, uint32_t cursor_color)
{
    waveform(parent, x, y, scale, wave_color);
    cursor(parent, x + 17 * scale, y, scale, cursor_color);
}

static void battery_text(lv_obj_t *root, int x, int y, int battery, uint32_t color, uint32_t bg)
{
    char value[8];
    if (battery < 0 || battery > 100) {
        snprintf(value, sizeof(value), "--%%");
    } else {
        snprintf(value, sizeof(value), "%d%%", battery);
    }
    box(root, x, y + 4, 19, 9, 2, color);
    box(root, x + 19, y + 6, 2, 5, 1, color);
    box(root, x + 1, y + 5, 17, 7, 1, bg);
    if (battery > 0 && battery <= 100) {
        box(root, x + 3, y + 7, (13 * battery + 99) / 100, 3, 1, color);
    }
    label(root, value, x + 25, y + 1, 30, &lv_font_montserrat_12, color, LV_TEXT_ALIGN_RIGHT);
}

static void cover(lv_obj_t *root, const state_style_t *style, int battery)
{
    label(root, "PassVoice", 19, 22, 100, &lv_font_montserrat_14, WHITE, LV_TEXT_ALIGN_LEFT);
    battery_text(root, 166, 22, battery, MUTED, NAVY);

    box(root, 63, 70, 114, 93, 23, PANEL);
    mark(root, 85, 97, 3, style->color, WHITE);

    label(root, style->title, 14, 181, 212, &lv_font_montserrat_30, WHITE, LV_TEXT_ALIGN_CENTER);
    label(root, style->detail, 14, 225, 212, &lv_font_montserrat_14, MUTED, LV_TEXT_ALIGN_CENTER);

    box(root, 19, 263, 202, 34, 9, PANEL);
    if (style->key) {
        box(root, 30, 272, 25, 16, 3, style->color);
        label(root, "UP", 30, 274, 25, &lv_font_montserrat_10, INK, LV_TEXT_ALIGN_CENTER);
        label(root, style->hint, 64, 272, 147, &lv_font_montserrat_14, WHITE, LV_TEXT_ALIGN_LEFT);
    } else {
        label(root, style->hint, 22, 272, 196, &lv_font_montserrat_14, WHITE, LV_TEXT_ALIGN_CENTER);
    }
}

static void signal(lv_obj_t *root, const state_style_t *style, pv_state_t state, int battery)
{
    label(root, "PassVoice", 19, 22, 110, &lv_font_montserrat_14, INK, LV_TEXT_ALIGN_LEFT);
    battery_text(root, 166, 22, battery, 0x3E6867, ICE);

    const bool voice_active = state == PV_LISTENING;
    const bool cursor_active = state == PV_FINISHING;
    box(root, 19, 63, 202, 107, 12, 0xC7EBE2);
    box(root, 28, 72, 110, 89, 8, voice_active ? 0x204D51 : 0xEAFBF5);
    box(root, 145, 72, 67, 89, 8, cursor_active ? 0x204D51 : 0xEAFBF5);
    waveform(root, 55, 85, 4, voice_active ? WHITE : 0x225E56);
    cursor(root, 167, 85, 4, cursor_active ? WHITE : 0x225E56);
    label(root, "VOICE", 28, 145, 110, &lv_font_montserrat_10,
          voice_active ? WHITE : 0x3E6867, LV_TEXT_ALIGN_CENTER);
    label(root, "TEXT", 145, 145, 67, &lv_font_montserrat_10,
          cursor_active ? WHITE : 0x3E6867, LV_TEXT_ALIGN_CENTER);

    box(root, 0, 189, 240, 131, 0, INK);
    box(root, 19, 215, 8, 8, 4, style->color);
    label(root, style->title, 38, 205, 185, &lv_font_montserrat_30, WHITE, LV_TEXT_ALIGN_LEFT);
    label(root, style->detail, 19, 250, 202, &lv_font_montserrat_14, MUTED, LV_TEXT_ALIGN_LEFT);
    if (style->key) {
        box(root, 19, 277, 25, 16, 3, style->color);
        label(root, "UP", 19, 279, 25, &lv_font_montserrat_10, INK, LV_TEXT_ALIGN_CENTER);
    }
    label(root, style->hint, style->key ? 52 : 19, 277, style->key ? 170 : 202,
          &lv_font_montserrat_14, WHITE, LV_TEXT_ALIGN_LEFT);
}

static void rail(lv_obj_t *root, const state_style_t *style, pv_state_t state, int battery)
{
    battery_text(root, 166, 20, battery, MUTED, INK);
    mark(root, 20, 21, 2, MINT, WHITE);
    label(root, "PassVoice", 20, 62, 121, &lv_font_montserrat_14, MUTED, LV_TEXT_ALIGN_LEFT);

    box(root, 20, 116, 22, 4, 2, style->color);
    label(root, style->title, 20, 131, 127, &lv_font_montserrat_20, WHITE, LV_TEXT_ALIGN_LEFT);
    label(root, style->detail, 20, 168, 118, &lv_font_montserrat_14, MUTED, LV_TEXT_ALIGN_LEFT);
    box(root, 146, 45, 1, 247, 0, PANEL);

    const char *codes[] = {"UP", "DOWN", "OK"};
    const char *actions[] = {style->key ? style->key : "WAIT", "EDIT", "EDIT"};
    const bool can_edit = state == PV_READY;
    for (int i = 0; i < 3; ++i) {
        const int y[] = {49, 151, 253};
        bool active = i == 0 && style->key;
        uint32_t text = (active || (i > 0 && can_edit)) ? WHITE : 0x8AA0B3;
        box(root, 160, y[i], 61, 43, 8, active ? 0x24473F : 0x14263A);
        box(root, 226, y[i] + 6, 13, 2, 1, active ? style->color : 0x3A5267);
        label(root, codes[i], 165, y[i] + 5, 51, &lv_font_montserrat_12,
              active ? style->color : MUTED, LV_TEXT_ALIGN_CENTER);
        label(root, actions[i], 165, y[i] + 23, 51, &lv_font_montserrat_10, text, LV_TEXT_ALIGN_CENTER);
    }
}

void pv_draw(lv_obj_t *screen, int variant, pv_state_t state, int battery)
{
    lv_obj_clean(screen);
    lv_obj_remove_style_all(screen);
    lv_obj_remove_flag(screen, LV_OBJ_FLAG_SCROLLABLE);
    const uint32_t backgrounds[] = {NAVY, ICE, INK};
    lv_obj_set_style_bg_color(screen, lv_color_hex(backgrounds[variant]), 0);
    lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);

    const state_style_t *style = &styles[state];
    switch (variant) {
        case 0: cover(screen, style, battery); break;
        case 1: signal(screen, style, state, battery); break;
        case 2: rail(screen, style, state, battery); break;
    }
}
