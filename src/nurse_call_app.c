#include "nurse_call_app.h"
#include "app_threads.h"

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <dk_buttons_and_leds.h>

LOG_MODULE_REGISTER(nurse_call_app, LOG_LEVEL_INF);

static bool nurse_call_alert_active = false;
static uint8_t active_alert_id = 0;
static uint32_t led_flash_counter = 0;

bool is_nurse_call_active(void)
{
    return nurse_call_alert_active;
}

void trigger_nurse_call_alert_local(uint8_t alert_id)
{
    nurse_call_alert_active = true;
    active_alert_id = alert_id;
    LOG_INF("Nurse Call Alert TRIGGERED (ID: %d)", alert_id);

    struct telemetry_msg msg = {
        .type = MSG_TYPE_NURSE_CALL_ALERT,
        .timestamp = k_uptime_get()
    };
    msg.data.alert.alert_id = alert_id;
    msg.data.alert.alert_state = 1;

    app_post_telemetry(&msg);
}

void cancel_nurse_call_alert_local(uint8_t alert_id)
{
    nurse_call_alert_active = false;
    dk_set_led_off(DK_LED1);
    LOG_INF("Nurse Call Alert CANCELLED (ID: %d)", alert_id);

    struct telemetry_msg msg = {
        .type = MSG_TYPE_NURSE_CALL_CANCEL,
        .timestamp = k_uptime_get()
    };
    msg.data.alert.alert_id = alert_id;
    msg.data.alert.alert_state = 0;

    app_post_telemetry(&msg);
}

/* External BLE hook overrides */
void app_trigger_nurse_call_alert(void)
{
    trigger_nurse_call_alert_local(1);
}

void app_trigger_nurse_call_cancel(void)
{
    cancel_nurse_call_alert_local(1);
}

void nurse_call_process_loop(void)
{
    if (nurse_call_alert_active) {
        /* Flash LED1 rapidly (every 200ms) to indicate nurse call alert state */
        if ((led_flash_counter % 2) == 0) {
            dk_set_led_on(DK_LED1);
        } else {
            dk_set_led_off(DK_LED1);
        }
        led_flash_counter++;
    }
}

void nurse_call_init(void)
{
    nurse_call_alert_active = false;
    active_alert_id = 0;
    led_flash_counter = 0;
    LOG_INF("Nurse Call app initialized");
}
