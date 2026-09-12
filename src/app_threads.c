#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/device.h>
#include <stdio.h>
#include <string.h>
// #include <app_version.h>

#include "app_threads.h"
#include "spo2_sensor.h"
#include "temp_sensor.h"
#include "config_parameter.h"
#include "common_nvs.h"
#include "tt_main.h"
#include "common_button.h"

LOG_MODULE_REGISTER(app_threads, LOG_LEVEL_INF);
#ifndef BLE_TYPE_BUT
#define BLE_TYPE_BUT 0x08
#endif

void send_typed_value_to_mobile(uint8_t type, int16_t value);

/* Message queues for inter-thread telemetry & high-priority alert dispatch */
K_MSGQ_DEFINE(telemetry_msgq, sizeof(struct telemetry_msg), 16, 4);
K_MSGQ_DEFINE(alert_msgq, sizeof(struct telemetry_msg), 4, 4);

/* Stack definitions for dedicated Zephyr threads */
#define SPO2_THREAD_STACK_SIZE       2048
#define TEMP_THREAD_STACK_SIZE       2048
#define NURSE_CALL_THREAD_STACK_SIZE 2048
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

static atomic_t spo2_sampling_active = ATOMIC_INIT(0);
static atomic_t measuring_enabled = ATOMIC_INIT(1);

static K_MUTEX_DEFINE(alert_state_mutex);
static bool pending_alert_active = false;
static uint8_t pending_alert_id = 0;
static uint8_t pending_alert_state = 0; /* 1 = ACTIVE, 0 = CANCELLED, 2 = BLUE */
static int64_t pending_alert_timestamp = 0;

extern int ble_utils_send(const uint8_t *data, uint16_t len);
extern int send_data_to_OTBR(uint8_t *buf, uint8_t ble_type, int16_t ble_value);
extern void enter_hibernation(void);
extern void update_activity_timestamp(void);
extern int64_t last_activity_time;
void send_typed_value_to_mobile(uint8_t type, int16_t value);

void app_set_pending_alert(uint8_t alert_id, uint8_t alert_state, int64_t timestamp)
{
    k_mutex_lock(&alert_state_mutex, K_FOREVER);
    if (timestamp >= pending_alert_timestamp) {
        pending_alert_active = true;
        pending_alert_id = alert_id;
        pending_alert_state = alert_state;
        pending_alert_timestamp = timestamp;
    }
    k_mutex_unlock(&alert_state_mutex);
}

void app_set_pending_alert_on_failure(uint8_t alert_id, uint8_t alert_state, int64_t timestamp)
{
    k_mutex_lock(&alert_state_mutex, K_FOREVER);
    if (timestamp >= pending_alert_timestamp) {
        pending_alert_active = true;
        pending_alert_id = alert_id;
        pending_alert_state = alert_state;
        pending_alert_timestamp = timestamp;
    } else {
        LOG_WRN("Discarded stale failure state (ts %lld < pending ts %lld)",
                (long long)timestamp, (long long)pending_alert_timestamp);
    }
    k_mutex_unlock(&alert_state_mutex);
}

bool app_get_pending_alert(uint8_t *out_alert_id, uint8_t *out_alert_state, int64_t *out_timestamp)
{
    k_mutex_lock(&alert_state_mutex, K_FOREVER);
    bool active = pending_alert_active;
    if (active) {
        if (out_alert_id) *out_alert_id = pending_alert_id;
        if (out_alert_state) *out_alert_state = pending_alert_state;
        if (out_timestamp) *out_timestamp = pending_alert_timestamp;
    }
    k_mutex_unlock(&alert_state_mutex);
    return active;
}

void app_clear_pending_alert_if_matched(uint8_t alert_id, uint8_t alert_state, int64_t timestamp)
{
    k_mutex_lock(&alert_state_mutex, K_FOREVER);
    if (pending_alert_active && pending_alert_id == alert_id &&
        pending_alert_state == alert_state && timestamp >= pending_alert_timestamp) {
        pending_alert_active = false;
    }
    k_mutex_unlock(&alert_state_mutex);
}

bool is_spo2_sampling_active(void)
{
    return atomic_get(&spo2_sampling_active) != 0;
}

void app_set_measuring_enabled(bool enable)
{
    atomic_set(&measuring_enabled, enable ? 1 : 0);
}

void app_post_telemetry(const struct telemetry_msg *msg)
{
    if (msg->type == MSG_TYPE_NURSE_CALL_ALERT ||
        msg->type == MSG_TYPE_NURSE_CALL_CANCEL ||
        msg->type == MSG_TYPE_NURSE_CALL_BLUE) {
        uint8_t alert_state = msg->data.alert.alert_state;
        int64_t ts = msg->timestamp > 0 ? msg->timestamp : k_uptime_get();
        app_set_pending_alert(msg->data.alert.alert_id, alert_state, ts);

        int ret = k_msgq_put(&alert_msgq, msg, K_MSEC(200));
        if (ret != 0) {
            LOG_ERR("Alert msgq full, alert state retained for persistent retry (type %d)", msg->type);
        }
    } else {
        int ret = k_msgq_put(&telemetry_msgq, msg, K_NO_WAIT);
        if (ret != 0) {
            LOG_WRN("Telemetry msgq full, dropping message type %d", msg->type);
        }
    }
}

/* =========================================================
 * Thread 1: SpO2 Sampling & Calculation Thread
 * ========================================================= */
static void spo2_thread_entry(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    printk("[SPO2_THREAD] SpO2 sampling thread started\n");

    spo2_init();

    while (1) {
        uint32_t raw_scan = common_config_get_spo2_scan_rate();
        bool enabled = (atomic_get(&measuring_enabled) != 0) && (raw_scan < 9999);

        if (enabled) {
            atomic_set(&spo2_sampling_active, 1);
            update_activity_timestamp();

            printk("[SPO2_THREAD] Executing SpO2 sampling loop...\n");
            spo2_start();

            atomic_set(&spo2_sampling_active, 0);

            uint32_t scan_rate = raw_scan > 0 ? raw_scan : 60;
            k_sleep(K_SECONDS(scan_rate));
        } else {
            /* Sensor disabled: sleep without running sampling or resetting activity timestamp */
            k_sleep(K_SECONDS(5));
        }
    }
}

/* =========================================================
 * Thread 2: Temperature Sampling Thread
 * ========================================================= */
static void temp_thread_entry(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    printk("[TEMP_THREAD] Temperature sampling thread started\n");

    temp_init();

    while (1) {
        uint32_t raw_scan = common_config_get_body_temp_scan_rate();
        bool enabled = (atomic_get(&measuring_enabled) != 0) && (raw_scan < 9999);

        if (enabled) {
            update_activity_timestamp();
            printk("[TEMP_THREAD] Executing Temperature sampling loop...\n");
            temp_start();

            uint32_t scan_rate = raw_scan > 0 ? raw_scan : 90;
            k_sleep(K_SECONDS(scan_rate));
        } else {
            /* Sensor disabled: sleep without running sampling or resetting activity timestamp */
            k_sleep(K_SECONDS(5));
        }
    }
}

/* =========================================================
 * Thread 3: Nurse Call Event Processing Thread (Idle / Workqueue driven)
 * ========================================================= */
static void nurse_call_thread_entry(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    printk("[NC_THREAD] Nurse Call event thread started\n");

    while (1) {
        k_msleep(1000);
    }
}

/* =========================================================
 * Thread 4: Telemetry Dispatch Thread (BLE & OpenThread CoAP)
 * ========================================================= */
static int process_telemetry_msg(const struct telemetry_msg *msg)
{
    char json_buf[256];
    int rc = 0;

    switch (msg->type) {
    case MSG_TYPE_SPO2:
    {
        char prof_buf[32] = {0};
        common_config_get_profile(prof_buf, sizeof(prof_buf));

        snprintf(json_buf, sizeof(json_buf),
            "{\"unique_id\":\"%s\",\"profile\":\"%s\",\"type\":11,\"SpO2\":%d,\"HeartRate\":%d}",
            unique_id, prof_buf, msg->data.spo2.spo2, msg->data.spo2.heart_rate);
        printk("TX SpO2 Telemetry: %s\n", json_buf);
        rc = send_data_to_OTBR((uint8_t *)json_buf, BLE_TYPE_SPO2, msg->data.spo2.spo2);

        /* Send Heart Rate over BLE in Home mode */
        if (!common_is_hospital()) {
            k_msleep(20);
            send_typed_value_to_mobile(BLE_TYPE_HR, msg->data.spo2.heart_rate);
        }
        break;
    }

    case MSG_TYPE_TEMP:
    {
        char prof_buf[32] = {0};
        common_config_get_profile(prof_buf, sizeof(prof_buf));

        int16_t temp_x100 = msg->data.temp.temp_f_x100;
        int32_t whole = temp_x100 / 100;
        int32_t frac = temp_x100 % 100;
        if (frac < 0) {
            frac = -frac;
        }
        snprintf(json_buf, sizeof(json_buf),
            "{\"unique_id\":\"%s\",\"profile\":\"%s\",\"type\":11,\"Temp_F\":%ld.%02ld}",
            unique_id, prof_buf, (long)whole, (long)frac);
        printk("TX Temp Telemetry: %s\n", json_buf);
        rc = send_data_to_OTBR((uint8_t *)json_buf, BLE_TYPE_TEMP, temp_x100);
        break;
    }

    case MSG_TYPE_NURSE_CALL_ALERT:
        LOG_INF("TX Nurse Call Alert via common_nurse_call_send");
        common_nurse_call_send(true, msg->data.alert.alert_id);
        rc = 0;
        break;

    case MSG_TYPE_NURSE_CALL_CANCEL:
        LOG_INF("TX Nurse Call Cancel via common_nurse_call_send");
        common_nurse_call_send(false, msg->data.alert.alert_id);
        rc = 0;
        break;

    case MSG_TYPE_NURSE_CALL_BLUE:
        LOG_INF("TX Nurse Call Blue via common_nurse_call_blue_send");
        common_nurse_call_blue_send(msg->data.alert.alert_id);
        rc = 0;
        break;

    default:
        LOG_ERR("Unhandled telemetry message type: %d", msg->type);
        rc = -EINVAL;
        break;
    }

    return rc;
}

void app_notify_alert_ack_received(uint8_t alert_id, uint8_t alert_state, int64_t timestamp)
{
    printk("End-to-End CoAP ACK received for alert_id %d (state=%d, ts=%lld) — evaluating match",
            alert_id, alert_state, (long long)timestamp);
    app_clear_pending_alert_if_matched(alert_id, alert_state, timestamp);
}

void app_notify_alert_ack_failed(void)
{
    k_mutex_lock(&alert_state_mutex, K_FOREVER);
    LOG_WRN("CoAP ACK timeout/failure — retaining pending Nurse Call alert state for retry");
    k_mutex_unlock(&alert_state_mutex);
}

static void telemetry_tx_thread_entry(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);
    struct telemetry_msg msg;
    uint32_t retry_backoff_ms = 200;

    printk("Telemetry dispatch thread started");

    while (1) {
        bool alert_processed = false;

        /* 1. Fully drain all pending alert queue items */
        struct telemetry_msg alert_msg;
        while (k_msgq_get(&alert_msgq, &alert_msg, K_NO_WAIT) == 0) {
            update_activity_timestamp();
            int rc = process_telemetry_msg(&alert_msg);
            alert_processed = true;

            uint8_t state = alert_msg.data.alert.alert_state;
            if (rc == 0) {
                app_clear_pending_alert_if_matched(alert_msg.data.alert.alert_id, state, alert_msg.timestamp);
                retry_backoff_ms = 200;
            } else {
                app_set_pending_alert_on_failure(alert_msg.data.alert.alert_id, state, alert_msg.timestamp);
                LOG_ERR("Alert dispatch failed (err %d) — backing off %u ms", rc, retry_backoff_ms);
                k_msleep(retry_backoff_ms);
                retry_backoff_ms = MIN(retry_backoff_ms * 2, 3200);
            }
        }

        /* 2. If alert queue was empty or failed previously, retry pending alert state */
        uint8_t pending_id;
        uint8_t pending_state;
        int64_t pending_ts;
        if (app_get_pending_alert(&pending_id, &pending_state, &pending_ts)) {
            enum telemetry_msg_type retry_type;
            if (pending_state == 1) {
                retry_type = MSG_TYPE_NURSE_CALL_ALERT;
            } else if (pending_state == 2) {
                retry_type = MSG_TYPE_NURSE_CALL_BLUE;
            } else {
                retry_type = MSG_TYPE_NURSE_CALL_CANCEL;
            }
            struct telemetry_msg retry_msg = {
                .type = retry_type,
                .timestamp = pending_ts
            };
            retry_msg.data.alert.alert_id = pending_id;
            retry_msg.data.alert.alert_state = pending_state;

            update_activity_timestamp();
            int rc = process_telemetry_msg(&retry_msg);
            alert_processed = true;

            if (rc == 0) {
                app_clear_pending_alert_if_matched(pending_id, pending_state, pending_ts);
                retry_backoff_ms = 200;
            } else {
                LOG_ERR("Alert retry dispatch failed (err %d) — backing off %u ms", rc, retry_backoff_ms);
                k_msleep(retry_backoff_ms);
                retry_backoff_ms = MIN(retry_backoff_ms * 2, 3200);
            }
        }

        if (alert_processed) {
            continue;
        }

        /* 3. Wait for periodic telemetry data if alert queue is empty and no pending alert */
        if (k_msgq_get(&telemetry_msgq, &msg, K_MSEC(100)) == 0) {
            /* Re-drain alert queue before processing routine message */
            while (k_msgq_get(&alert_msgq, &alert_msg, K_NO_WAIT) == 0) {
                update_activity_timestamp();
                int rc = process_telemetry_msg(&alert_msg);
                uint8_t state = alert_msg.data.alert.alert_state;
                if (rc == 0) {
                    app_clear_pending_alert_if_matched(alert_msg.data.alert.alert_id, state, alert_msg.timestamp);
                    retry_backoff_ms = 200;
                } else {
                    app_set_pending_alert_on_failure(alert_msg.data.alert.alert_id, state, alert_msg.timestamp);
                }
            }
            update_activity_timestamp();
            process_telemetry_msg(&msg);
        }
    }
}

/* =========================================================
 * Application Lifecycle Initialization & Background Monitor
 * ========================================================= */
#define SENSOR_DISABLED_SCAN_RATE 9999

void device_app_init(void)
{
    printk("[APP_INIT] Initializing Nurse Call + SpO2 Application Multithreading\n");

    /* Read configured sensor scan rates */
    uint32_t spo2_scan_rate = common_config_get_spo2_scan_rate();
    uint32_t temp_scan_rate = common_config_get_body_temp_scan_rate();

    bool spo2_enabled = (spo2_scan_rate > 0 && spo2_scan_rate != SENSOR_DISABLED_SCAN_RATE);
    bool temp_enabled = (temp_scan_rate > 0 && temp_scan_rate != SENSOR_DISABLED_SCAN_RATE);

    printk("[APP_INIT] Configuration: SpO2 scan=%u s (%s), Temp scan=%u s (%s)\n",
           spo2_scan_rate, spo2_enabled ? "ENABLED" : "DISABLED",
           temp_scan_rate, temp_enabled ? "ENABLED" : "DISABLED");

    /* Create SpO2 Thread only when enabled */
    if (spo2_enabled) {
        k_thread_create(&spo2_thread_data, spo2_stack_area,
                        K_THREAD_STACK_SIZEOF(spo2_stack_area),
                        spo2_thread_entry, NULL, NULL, NULL,
                        SPO2_THREAD_PRIO, 0, K_NO_WAIT);
        k_thread_name_set(&spo2_thread_data, "spo2_thread");
        printk("[APP_INIT] SpO2 thread CREATED\n");
    } else {
        printk("[APP_INIT] SpO2 thread NOT created (disabled by scan_rate=%u)\n", spo2_scan_rate);
    }

    /* Create Temperature Thread only when enabled */
    if (temp_enabled) {
        k_thread_create(&temp_thread_data, temp_stack_area,
                        K_THREAD_STACK_SIZEOF(temp_stack_area),
                        temp_thread_entry, NULL, NULL, NULL,
                        TEMP_THREAD_PRIO, 0, K_NO_WAIT);
        k_thread_name_set(&temp_thread_data, "temp_thread");
        printk("[APP_INIT] Temperature thread CREATED\n");
    } else {
        printk("[APP_INIT] Temperature thread NOT created (disabled by scan_rate=%u)\n", temp_scan_rate);
    }

    /* Create Nurse Call Thread - ALWAYS required */
    k_thread_create(&nurse_call_thread_data, nurse_call_stack_area,
                    K_THREAD_STACK_SIZEOF(nurse_call_stack_area),
                    nurse_call_thread_entry, NULL, NULL, NULL,
                    NURSE_CALL_THREAD_PRIO, 0, K_NO_WAIT);
    k_thread_name_set(&nurse_call_thread_data, "nurse_call_thread");
    printk("[APP_INIT] Nurse Call thread CREATED\n");

    /* Create Telemetry TX Thread - ALWAYS required */
    k_thread_create(&telemetry_thread_data, telemetry_stack_area,
                    K_THREAD_STACK_SIZEOF(telemetry_stack_area),
                    telemetry_tx_thread_entry, NULL, NULL, NULL,
                    TELEMETRY_THREAD_PRIO, 0, K_NO_WAIT);
    k_thread_name_set(&telemetry_thread_data, "telemetry_tx_thread");
    printk("[APP_INIT] Telemetry TX thread CREATED\n");

    printk("[APP_INIT] Application threads initialization complete\n");
}

void device_background_process(void)
{
    /* Power management: Hibernation is strictly active ONLY on Battery Mode (1) */
    if (common_config_get_battery_mode() != 1) {
        update_activity_timestamp();
        return;
    }

    /* Check whether sensors are enabled / actively scanning:
     * Sensors are considered measuring only if measuring_enabled is true
     * AND their scan rate is not set to disabled (>= 9999).
     */
    bool is_spo2_measuring = (atomic_get(&measuring_enabled) != 0) &&
                             (common_config_get_spo2_scan_rate() < 9999);
    bool is_temp_measuring = (atomic_get(&measuring_enabled) != 0) &&
                             (common_config_get_body_temp_scan_rate() < 9999);

    /* Check idle timeout for hibernation when sensors are disabled and no alerts active */
    if (!is_spo2_measuring && !is_temp_measuring &&
        !is_spo2_sampling_active() && !is_nurse_call_active()) {
        uint32_t idle_s = common_config_get_idle_time_hibernate();
        if (k_uptime_get() - last_activity_time > (int64_t)idle_s * 1000) {
            printk("[APP] Inactivity timeout reached on Battery Mode (%u s), powering down to System OFF...\n",
                   (unsigned int)idle_s);
            enter_hibernation();
        }
    } else {
        update_activity_timestamp();
    }
}

void send_typed_value_to_mobile(uint8_t type, int16_t value)
{
    uint8_t buf[4];

    buf[0] = type;
    buf[1] = 0x00;                 // reserved
    buf[2] = value & 0xFF;         // LSB
    buf[3] = (value >> 8) & 0xFF;  // MSB

    int err = ble_utils_send(buf, sizeof(buf));
    if (err) {
        LOG_ERR("BLE binary send failed: %d", err);
    } else {
        printk("BLE binary sent: type=%d value=%d\n", type, value);
    }
}

void coap_send_device_specific_config(void)
{
    char config_json[256];
    extern int send_data_to_OTBR_internal(uint8_t *buf);

    snprintf(config_json, sizeof(config_json),
        "{"
        "\"Type\":\"SPO2\","
        "\"SensorNo\":%u,"
        "\"SpO2 Scan\":%u,"
        "\"Temp Scan rate\":%u,"
        "\"No Finger Threshold\":%d"
        "}",
        spo2_cfg.sensor_no,
        spo2_cfg.spo2_scan_rate_s,
        spo2_cfg.body_temp_scan_rate_s,
        spo2_cfg.no_finger_threshold);

    printk("Device Specific CFG=%s\n", config_json);
    send_data_to_OTBR_internal((uint8_t *)config_json);
    k_msleep(50);
}

