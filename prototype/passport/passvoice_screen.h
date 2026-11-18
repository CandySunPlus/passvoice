#pragma once

#include "lvgl.h"

enum { PV_SCREEN_W = 240, PV_SCREEN_H = 320, PV_VARIANTS = 3 };

typedef enum {
    PV_READY,
    PV_LISTENING,
    PV_FINISHING,
    PV_OFFLINE,
    PV_LINK_ERROR,
    PV_STATES
} pv_state_t;

void pv_draw(lv_obj_t *screen, int variant, pv_state_t state, int battery);
