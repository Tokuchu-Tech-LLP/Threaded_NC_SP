#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/device.h>
#include <stdio.h>
#include <string.h>

#include "app_threads.h"
#include "spo2_sensor.h"
#include "temp_sensor.h"
#include "nurse_call_app.h"
#include "config_parameter.h"
#include "common_nvs.h"

LOG_MODULE_REGISTER(app_threads, LOG_LEVEL_INF);

/* Message queue for inter-thread telemetry dispatch */
K_MSGQ_DEFINE(telemetry_msgq, sizeof(struct telemetry_msg), 16, 4);

/* Stack definitions for dedicated Zephyr threads */
#define SPO2_THREAD_STACK_SIZE       2048
#define TEMP_THREAD_STACK_SIZE       1024
#define NURSE_CALL_THREAD_STACK_SIZE 1024
#define TELEMETRY_THREAD_STACK_SIZE  2048

#define NURSE_CALL_THREAD_PRIO  4
#define SPO2_THREAD_PRIO        5
#define TEMP_THREAD_PRIO        6
#define TELEMETRY_THREAD_PRIO   7

K_THREAD_STACK_DEFINE(spo2_stack_area, SPO2_THREAD_STACK_SIZE);
K_THREAD_STACK_DEFINE(temp_stack_area, TEMP_THREAD_STACK_SIZE);
K_THREAD_STACK_DEFINE(nurse_call_stack_area, NURSE_CALL_THREAD_STACK_SIZE);
K_THREAD_STACK_DEFINE(telemetry_stack_area, TELEMETRY_THREAD_STACK_SIZE);

static struct k_thread spo2_thread_data;
static struct k_thread temp_thread_data;
static struct k_thread nurse_call_thread_data;
static struct k_thread telemetry_thread_data;

static bool spo2_sampling_active = false;
static bool measuring_enabled = true;

extern int ble_utils_send(const uint8_t *data, uint16_t len);
extern void send_data_to_OTBR_internal(uint8_t *buf);
extern void enter_hibernation(void);
extern void update_activity_timestamp(void);
extern int64_t last_activity_time;

bool is_spo2_sampling_active(void)
{
    return spo2_sampling_active;
}

void app_set_measuring_enabled(bool enable)
{
    measuring_enabled = enable;
}

void app_post_telemetry(const struct telemetry_msg *msg)
{
    int ret = k_msgq_put(&telemetry_msgq, msg, K_NO_WAIT);
    if (ret != 0) {
        LOG_WRN("Telemetry msgq full, dropping message type %d", msg->type);
    }
}

/* =========================================================
 * Thread 1: SpO2 Sampling & Calculation Thread
 * ========================================================= */
static void spo2_thread_entry(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    LOG_INF("SpO2 sampling thread started");

    spo2_init();

    while (1) {
        if (measuring_enabled) {
            spo2_sampling_active = true;
            update_activity_timestamp();

            LOG_INF("Executing SpO2 sampling loop...");
            spo2_start();

            spo2_sampling_active = false;
        }

        uint32_t scan_rate = spo2_cfg.spo2_scan_rate_s > 0 ? spo2_cfg.spo2_scan_rate_s : 60;
        k_sleep(K_SECONDS(scan_rate));
    }
}

/* =========================================================
 * Thread 2: Temperature Sampling Thread
 * ========================================================= */
static void temp_thread_entry(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    LOG_INF("Temperature sampling thread started");

    temp_init();

    while (1) {
        if (measuring_enabled) {
            update_activity_timestamp();
            LOG_INF("Executing Temperature sampling loop...");
            temp_start();
        }

        uint32_t scan_rate = spo2_cfg.body_temp_scan_rate_s > 0 ? spo2_cfg.body_temp_scan_rate_s : 90;
        k_sleep(K_SECONDS(scan_rate));
    }
}

/* =========================================================
 * Thread 3: Nurse Call Event & Alert Processing Thread
 * ========================================================= */
static void nurse_call_thread_entry(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    LOG_INF("Nurse Call event thread started");

    nurse_call_init();

    while (1) {
        nurse_call_process_loop();
        k_msleep(100);
    }
}

/* =========================================================
 * Thread 4: Telemetry Dispatch Thread (BLE & OpenThread CoAP)
 * ========================================================= */
static void telemetry_tx_thread_entry(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    struct telemetry_msg msg;
    char json_buf[256];

    LOG_INF("Telemetry dispatch thread started");

    while (1) {
        if (k_msgq_get(&telemetry_msgq, &msg, K_FOREVER) == 0) {
            update_activity_timestamp();

            switch (msg.type) {
            case MSG_TYPE_SPO2:
                snprintf(json_buf, sizeof(json_buf),
                    "{\"unique_id\":\"%s\",\"type\":\"NURSE_CALL_SPO2\",\"SpO2\":%d,\"HeartRate\":%d}",
                    unique_id, msg.data.spo2.spo2, msg.data.spo2.heart_rate);
                LOG_INF("TX SpO2 Telemetry: %s", json_buf);
                send_data_to_OTBR_internal((uint8_t *)json_buf);
                break;

            case MSG_TYPE_TEMP:
                snprintf(json_buf, sizeof(json_buf),
                    "{\"unique_id\":\"%s\",\"type\":\"NURSE_CALL_SPO2\",\"Temp_C\":%.2f}",
                    unique_id, (double)msg.data.temp.temp_c_x100 / 100.0);
                LOG_INF("TX Temp Telemetry: %s", json_buf);
                send_data_to_OTBR_internal((uint8_t *)json_buf);
                break;

            case MSG_TYPE_NURSE_CALL_ALERT:
                snprintf(json_buf, sizeof(json_buf),
                    "{\"unique_id\":\"%s\",\"type\":\"NURSE_CALL_ALERT\",\"alert_id\":%d,\"state\":\"ACTIVE\"}",
                    unique_id, msg.data.alert.alert_id);
                LOG_INF("TX Nurse Call Alert: %s", json_buf);
                send_data_to_OTBR_internal((uint8_t *)json_buf);
                ble_utils_send((const uint8_t *)json_buf, strlen(json_buf));
                break;

            case MSG_TYPE_NURSE_CALL_CANCEL:
                snprintf(json_buf, sizeof(json_buf),
                    "{\"unique_id\":\"%s\",\"type\":\"NURSE_CALL_ALERT\",\"alert_id\":%d,\"state\":\"CANCELLED\"}",
                    unique_id, msg.data.alert.alert_id);
                LOG_INF("TX Nurse Call Cancel: %s", json_buf);
                send_data_to_OTBR_internal((uint8_t *)json_buf);
                ble_utils_send((const uint8_t *)json_buf, strlen(json_buf));
                break;

            default:
                break;
            }
        }
    }
}

/* =========================================================
 * Application Lifecycle Initialization & Background Monitor
 * ========================================================= */
void device_app_init(void)
{
    LOG_INF("Initializing Nurse Call + SpO2 Application Multithreading");

    /* Create SpO2 Thread */
    k_thread_create(&spo2_thread_data, spo2_stack_area,
                    K_THREAD_STACK_SIZEOF(spo2_stack_area),
                    spo2_thread_entry, NULL, NULL, NULL,
                    SPO2_THREAD_PRIO, 0, K_NO_WAIT);
    k_thread_name_set(&spo2_thread_data, "spo2_thread");

    /* Create Temperature Thread */
    k_thread_create(&temp_thread_data, temp_stack_area,
                    K_THREAD_STACK_SIZEOF(temp_stack_area),
                    temp_thread_entry, NULL, NULL, NULL,
                    TEMP_THREAD_PRIO, 0, K_NO_WAIT);
    k_thread_name_set(&temp_thread_data, "temp_thread");

    /* Create Nurse Call Thread */
    k_thread_create(&nurse_call_thread_data, nurse_call_stack_area,
                    K_THREAD_STACK_SIZEOF(nurse_call_stack_area),
                    nurse_call_thread_entry, NULL, NULL, NULL,
                    NURSE_CALL_THREAD_PRIO, 0, K_NO_WAIT);
    k_thread_name_set(&nurse_call_thread_data, "nurse_call_thread");

    /* Create Telemetry TX Thread */
    k_thread_create(&telemetry_thread_data, telemetry_stack_area,
                    K_THREAD_STACK_SIZEOF(telemetry_stack_area),
                    telemetry_tx_thread_entry, NULL, NULL, NULL,
                    TELEMETRY_THREAD_PRIO, 0, K_NO_WAIT);
    k_thread_name_set(&telemetry_thread_data, "telemetry_tx_thread");

    LOG_INF("All Nurse Call + SpO2 application threads spawned successfully");
}

void device_background_process(void)
{
    /* Power management: Check idle timeout for hibernation */
    if (!measuring_enabled && !is_spo2_sampling_active() && !is_nurse_call_active()) {
        if (k_uptime_get() - last_activity_time > (int64_t)common_cfg.idle_time_hibernate_s * 1000) {
            LOG_INF("Inactivity timeout reached, powering down to System OFF...");
            enter_hibernation();
        }
    } else {
        update_activity_timestamp();
    }
}
