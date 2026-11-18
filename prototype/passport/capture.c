#include "passvoice_screen.h"
#include <stdio.h>
#include <string.h>

static uint16_t strips[PV_SCREEN_W * 20];
static uint16_t pixels[PV_SCREEN_H][PV_SCREEN_W];

static void flush(lv_display_t *display, const lv_area_t *area, uint8_t *data)
{
    int width = lv_area_get_width(area);
    for (int y = area->y1; y <= area->y2; ++y) {
        memcpy(&pixels[y][area->x1], data, (size_t)width * 2);
        data += width * 2;
    }
    lv_display_flush_ready(display);
}

int main(int argc, char **argv)
{
    if (argc != 2) return 1;
    lv_init();
    lv_display_t *disp = lv_display_create(PV_SCREEN_W, PV_SCREEN_H);
    lv_display_set_color_format(disp, LV_COLOR_FORMAT_RGB565);
    lv_display_set_buffers(disp, strips, NULL, sizeof(strips), LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(disp, flush);

    for (int variant = 0; variant < PV_VARIANTS; ++variant) {
        for (pv_state_t state = PV_READY; state < PV_STATES; ++state) {
            pv_draw(lv_display_get_screen_active(disp), variant, state, 78);
            lv_refr_now(disp);
            char path[4096];
            snprintf(path, sizeof(path), "%s/%c-%d.rgb565", argv[1], 'A' + variant, (int)state);
            FILE *out = fopen(path, "wb");
            if (!out) { perror(path); return 1; }
            size_t bytes = fwrite(pixels, 1, sizeof(pixels), out);
            fclose(out);
            if (bytes != sizeof(pixels)) return 1;
        }
    }
    return 0;
}
