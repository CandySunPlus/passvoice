// Device-only UI prototype. It simulates status and never starts BLE or audio.
#include "passvoice_screen.h"
#include "bsp_button.h"
#include "bsp_display.h"
#include "bsp_pins.h"
#include "esp_err.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

_Static_assert(PV_SCREEN_W == BSP_LCD_W && PV_SCREEN_H == BSP_LCD_H, "Unexpected display size");

static void on_key(bsp_btn_t button, bsp_btn_ev_t event, void *context)
{
    if (event == BSP_BTN_CLICK) {
        xQueueSend((QueueHandle_t)context, &button, 0);
    }
}

void app_main(void)
{
    ESP_ERROR_CHECK(bsp_display_init());
    lv_display_t *display = bsp_lvgl_init();
    ESP_ERROR_CHECK(display ? ESP_OK : ESP_FAIL);

    QueueHandle_t keys = xQueueCreate(8, sizeof(bsp_btn_t));
    ESP_ERROR_CHECK(keys ? ESP_OK : ESP_ERR_NO_MEM);
    ESP_ERROR_CHECK(bsp_button_init(on_key, keys));

    int variant = 0;
    pv_state_t state = PV_READY;
    for (;;) {
        if (bsp_lvgl_lock(100)) {
            pv_draw(lv_display_get_screen_active(display), variant, state, 78);
            bsp_lvgl_unlock();
        }
        bsp_display_backlight(65);

        bsp_btn_t button;
        TickType_t wait = state == PV_FINISHING ? pdMS_TO_TICKS(1500) : portMAX_DELAY;
        if (xQueueReceive(keys, &button, wait) != pdTRUE) {
            state = PV_READY;
            continue;
        }

        switch (button) {
            case BSP_BTN_DOWN:
                variant = (variant + 1) % PV_VARIANTS;
                break;
            case BSP_BTN_OK:
                state = (state + 1) % PV_STATES;
                break;
            case BSP_BTN_UP:
                if (state == PV_LISTENING) state = PV_FINISHING;
                else if (state == PV_READY || state == PV_LINK_ERROR) state = PV_LISTENING;
                break;
        }
    }
}
