#include "temp_sensor.h"
#include "app_threads.h"
#include "adc_utils.h"
#include "tt_main.h"

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <stdio.h>
#include <math.h>
#include "common_nvs.h"

LOG_MODULE_REGISTER(temp_sensor, LOG_LEVEL_INF);

#define TEMP_ADC_PORT SAADC_CH_PSELP_PSELP_AnalogInput1

#define SAMPLE_COUNT 20
#define VALID_MIN    0
#define VALID_MAX    4095

#define ADC_MAX_COUNTS     4095.0f
#define ADC_FULL_SCALE_V   4.95f
#define SUPPLY_VOLTAGE     3.3f
#define R_FIXED            5500.0f

#define R0           2110.0f
#define T0_KELVIN    298.15f
#define BETA         3950.0f

extern struct k_mutex adc_lock;

static int get_temp_adc(uint8_t adc_port, uint8_t channel_id)
{
    int32_t sum = 0;
    int valid = 0;

    k_mutex_lock(&adc_lock, K_FOREVER);
    adc_setup(adc_port, channel_id);

    for (int i = 0; i < SAMPLE_COUNT; i++) {
        int16_t adc_value;
        if (adc_read_channel(adc_port, channel_id, 12, &adc_value) == 0) {
            if (adc_value >= VALID_MIN && adc_value <= VALID_MAX) {
                sum += adc_value;
                valid++;
            }
        }
        k_msleep(2);
    }

    k_mutex_unlock(&adc_lock);
    return (valid == 0) ? 0 : (sum / valid);
}

void temp_start(void)
{
    int adc_value = get_temp_adc(TEMP_ADC_PORT, 1);

    if (adc_value <= 0 || adc_value >= 4095) {
        LOG_ERR("Invalid Temperature ADC reading: %d", adc_value);
        return;
    }

    float v_adc = adc_value * (ADC_FULL_SCALE_V / ADC_MAX_COUNTS);
    float r_therm = R_FIXED * ((SUPPLY_VOLTAGE / v_adc) - 1.0f);

    if (r_therm <= 0.0f) {
        LOG_ERR("Invalid resistance computed for temperature");
        return;
    }

    float temp_kelvin = 1.0f / ((1.0f / T0_KELVIN) + (1.0f / BETA) * logf(r_therm / R0));
    float temp_c = temp_kelvin - 273.15f;

    int32_t v_mv = (int32_t)(v_adc * 1000.0f);
    int32_t temp_c_x100 = (int32_t)(temp_c * 100.0f);
    int32_t temp_whole = temp_c_x100 / 100;
    int32_t temp_frac = temp_c_x100 % 100;
    if (temp_frac < 0) {
        temp_frac = -temp_frac;
    }

    if (temp_c < -10.0f || temp_c > 60.0f) {
        LOG_WRN("Temperature out of hardware sanity range (-10 to 60 C): %ld.%02ld C — discarding",
                (long)temp_whole, (long)temp_frac);
        return;
    }

    LOG_INF("Temperature sampled: ADC=%d, Vadc=%ld.%03ldV, Temp=%ld.%02ld C",
            adc_value,
            (long)(v_mv / 1000),
            (long)(v_mv % 1000),
            (long)temp_whole,
            (long)temp_frac);

    struct telemetry_msg msg = {
        .type = MSG_TYPE_TEMP,
        .timestamp = k_uptime_get()
    };
    msg.data.temp.temp_c_x100 = (int16_t)temp_c_x100;

    app_post_telemetry(&msg);
}

void temp_stop(void)
{
}

void temp_init(void)
{
}
