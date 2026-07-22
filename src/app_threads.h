#ifndef APP_THREADS_H
#define APP_THREADS_H

#include <zephyr/kernel.h>
#include <stdint.h>
#include <stdbool.h>

enum telemetry_msg_type {
    MSG_TYPE_SPO2 = 1,
    MSG_TYPE_TEMP,
    MSG_TYPE_NURSE_CALL_ALERT,
    MSG_TYPE_NURSE_CALL_CANCEL,
    MSG_TYPE_HEARTBEAT
};

struct telemetry_msg {
    enum telemetry_msg_type type;
    union {
        struct {
            int16_t spo2;
            int16_t heart_rate;
        } spo2;
        struct {
            int16_t temp_c_x100; /* Temperature in Celsius * 100 */
        } temp;
        struct {
            uint8_t alert_id;
            uint8_t alert_state; /* 1 = active, 0 = cancelled */
        } alert;
    } data;
    int64_t timestamp;
};

extern struct k_msgq telemetry_msgq;
extern struct k_msgq alert_msgq;

void app_threads_init(void);
void app_post_telemetry(const struct telemetry_msg *msg);

bool is_spo2_sampling_active(void);
bool is_nurse_call_active(void);

void app_notify_alert_ack_received(uint8_t alert_id, bool is_active, int64_t timestamp);
void app_notify_alert_ack_failed(void);

#endif /* APP_THREADS_H */
