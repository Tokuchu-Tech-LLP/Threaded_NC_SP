#include "spo2_sensor.h"
#include "app_threads.h"
#include "adc_utils.h"
#include "tt_main.h"

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <dk_buttons_and_leds.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include "common_nvs.h"

LOG_MODULE_REGISTER(spo2_sensor, LOG_LEVEL_INF);

/* ADC Configuration */
#define SPO2_ADC_PORT SAADC_CH_PSELP_PSELP_AnalogInput0

#define SAMPLE_RATE_HZ          50
#define SAMPLE_WINDOW_SECONDS   2
#define TOTAL_SAMPLES           (SAMPLE_RATE_HZ * SAMPLE_WINDOW_SECONDS)

#define LED_SETTLE_MS           2
#define SAMPLE_SPACING_MS       5
#define AMBIENT_WEIGHT          0.5f

#define SPO2_FILTER_DEPTH       5
#define HR_FILTER_DEPTH         3

#define SPO2_MIN_LIMIT          7000
#define SPO2_MAX_LIMIT          10000

#define MIN_PEAK_DISTANCE       (SAMPLE_RATE_HZ / 2)

extern struct k_mutex adc_lock;
extern const struct device *adc_dev;

static int16_t red_buf[TOTAL_SAMPLES];
static int16_t ir_buf[TOTAL_SAMPLES];

static int spo2_hist[SPO2_FILTER_DEPTH];
static int spo2_hist_idx = 0;
static int spo2_hist_cnt = 0;

static int hr_hist[HR_FILTER_DEPTH];
static int hr_hist_idx = 0;
static int hr_hist_cnt = 0;

static int16_t local_sample_buffer[1];

static int16_t read_adc_once_fast(uint8_t channel_id)
{
    struct adc_sequence sequence = {
        .channels    = BIT(channel_id),
        .buffer      = local_sample_buffer,
        .buffer_size = sizeof(local_sample_buffer),
        .resolution  = 14,
    };

    if (adc_read(adc_dev, &sequence) == 0)
        return local_sample_buffer[0];

    return 0;
}

static int16_t read_adc_avg(uint8_t samples)
{
    int32_t sum = 0;

    for (int i = 0; i < samples; i++) {
        sum += read_adc_once_fast(0);
    }

    return (int16_t)(sum / samples);
}

static int16_t read_led_hybrid(uint8_t led_id)
{
    int16_t ambient = 0;
    int16_t signal  = 0;

    dk_set_led_off(DK_LED2);
    dk_set_led_off(DK_LED3);
    k_sleep(K_MSEC(LED_SETTLE_MS));

    ambient = read_adc_avg(3);

    if (led_id == 0)
        dk_set_led_on(DK_LED3);   // RED
    else
        dk_set_led_on(DK_LED2);   // IR

    k_sleep(K_MSEC(LED_SETTLE_MS));

    signal = read_adc_avg(3);

    if (led_id == 0)
        dk_set_led_off(DK_LED3);
    else
        dk_set_led_off(DK_LED2);

    float corrected = signal - (ambient * AMBIENT_WEIGHT);
    return (int16_t)corrected;
}

static int smooth_value(int *hist, int depth, int *idx, int *cnt, int val)
{
    hist[*idx] = val;
    *idx = (*idx + 1) % depth;
    if (*cnt < depth) (*cnt)++;

    int temp[SPO2_FILTER_DEPTH];
    for (int i = 0; i < *cnt; i++) {
        temp[i] = hist[i];
    }

    for (int i = 0; i < *cnt - 1; i++) {
        for (int j = i + 1; j < *cnt; j++) {
            if (temp[i] > temp[j]) {
                int t = temp[i];
                temp[i] = temp[j];
                temp[j] = t;
            }
        }
    }

    return temp[*cnt / 2];
}

static void compute_dc_ac(const int16_t *buf, float *dc, float *ac)
{
    int32_t sum = 0;
    int16_t min_v = 32767;
    int16_t max_v = -32768;

    for (int i = 0; i < TOTAL_SAMPLES; i++) {
        sum += buf[i];
        if (buf[i] < min_v) min_v = buf[i];
        if (buf[i] > max_v) max_v = buf[i];
    }

    *dc = (float)sum / TOTAL_SAMPLES;
    *ac = (float)(max_v - min_v);
}

static int compute_heart_rate(float red_dc, float red_ac)
{
    if (red_ac < 15.0f || red_dc < 100.0f)
        return 0;

    int peaks[10];
    int peak_count = 0;

    for (int i = 1; i < TOTAL_SAMPLES - 1; i++) {
        if (red_buf[i] > red_buf[i - 1] &&
            red_buf[i] > red_buf[i + 1] &&
            red_buf[i] > (int16_t)(red_dc + red_ac * 0.2f))
        {
            if (peak_count == 0 ||
                (i - peaks[peak_count - 1]) >= MIN_PEAK_DISTANCE)
            {
                peaks[peak_count++] = i;
                if (peak_count >= 10) break;
            }
        }
    }

    if (peak_count < 2) return 0;

    int total_interval = 0;
    for (int i = 1; i < peak_count; i++) {
        total_interval += (peaks[i] - peaks[i - 1]);
    }

    float avg_interval_samples = (float)total_interval / (peak_count - 1);
    float hr = (60.0f * SAMPLE_RATE_HZ) / avg_interval_samples;

    return (int)hr;
}

static void collect_samples(void)
{
    k_mutex_lock(&adc_lock, K_FOREVER);
    adc_setup(SPO2_ADC_PORT, 0);

    for (int i = 0; i < TOTAL_SAMPLES; i++) {
        red_buf[i] = read_led_hybrid(0);
        ir_buf[i]  = read_led_hybrid(1);
        k_sleep(K_MSEC(SAMPLE_SPACING_MS));
    }

    k_mutex_unlock(&adc_lock);
}

void spo2_start(void)
{
    collect_samples();

    float red_dc, red_ac;
    float ir_dc,  ir_ac;

    compute_dc_ac(red_buf, &red_dc, &red_ac);
    compute_dc_ac(ir_buf,  &ir_dc,  &ir_ac);

    LOG_INF("RED DC=%.1f AC=%.1f | IR DC=%.1f AC=%.1f",
            (double)red_dc, (double)red_ac,
            (double)ir_dc,  (double)ir_ac);

    if (red_ac > red_dc * 0.6f) {
        LOG_WRN("Signal unstable (AC too high), skipping");
        return;
    }

    struct telemetry_msg msg = {
        .type = MSG_TYPE_SPO2,
        .timestamp = k_uptime_get()
    };

    if (red_dc > 1000) {
        LOG_INF("No finger detected (RED DC=%.1f)", (double)red_dc);
        msg.data.spo2.spo2 = 1000; /* 10.00 % */
        msg.data.spo2.heart_rate = 0;
        app_post_telemetry(&msg);
        return;
    }

    float red_ratio = red_ac / red_dc;
    float ir_ratio  = ir_ac  / ir_dc;
    float R = red_ratio / (ir_ratio > 0.0001f ? ir_ratio : 0.0001f);
    float SpO2 = 103.54f - 4.605f * R;

    int intSpO2 = (int)(SpO2 * 100);
    if (intSpO2 > SPO2_MAX_LIMIT) intSpO2 = SPO2_MAX_LIMIT;
    if (intSpO2 < SPO2_MIN_LIMIT) intSpO2 = SPO2_MIN_LIMIT;

    intSpO2 = smooth_value(spo2_hist, SPO2_FILTER_DEPTH, &spo2_hist_idx, &spo2_hist_cnt, intSpO2);
    int hr = compute_heart_rate(red_dc, red_ac);

    if (hr > 40 && hr < 200) {
        hr = smooth_value(hr_hist, HR_FILTER_DEPTH, &hr_hist_idx, &hr_hist_cnt, hr);
    } else {
        hr = 0;
    }

    LOG_INF("SpO2 calculated: R=%.4f SpO2=%d HR=%d", (double)R, intSpO2, hr);

    msg.data.spo2.spo2 = intSpO2;
    msg.data.spo2.heart_rate = hr;
    app_post_telemetry(&msg);
}

void spo2_stop(void)
{
    dk_set_led_off(DK_LED2);
    dk_set_led_off(DK_LED3);
}

void spo2_init(void)
{
    spo2_hist_idx = 0;
    spo2_hist_cnt = 0;
    hr_hist_idx = 0;
    hr_hist_cnt = 0;
}
