#include "temp_sensor.h"
#include "app_threads.h"
#include "adc_utils.h"
#include "tt_main.h"

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "common_nvs.h"

LOG_MODULE_REGISTER(temp_sensor, LOG_LEVEL_INF);

#define TEMP_ADC_PORT SAADC_CH_PSELP_PSELP_AnalogInput1

#define SAMPLE_COUNT 20
#define VALID_MIN    0
#define VALID_MAX    4095

#define ADC_MAX_COUNTS     4095.0f
#define ADC_FULL_SCALE_V   4.95f     // Derived from gain/ref
#define SUPPLY_VOLTAGE     3.3f      // Divider supply
#define R_FIXED            5500.0f   // 5.5k to GND

/* Thermistor parameters (to refine later) */
#define R0           1227.0f     // 2.11k at 25°C earlier 2110
#define T0_KELVIN    298.15f     // 25°C
#define BETA         2065.0f     // Temporary guess earlier 3950

extern struct k_mutex adc_lock;

static int get_temp_adc(uint8_t adc_port, uint8_t channel_id)
{
    int32_t sum = 0;
    int valid = 0;

    adc_setup(adc_port, channel_id);

    for (int i = 0; i < SAMPLE_COUNT; i++) {
        int16_t adc_value;
        if (adc_read_channel(adc_port, channel_id, 12, &adc_value) == 0) {
            if (adc_value >= VALID_MIN && adc_value <= VALID_MAX) {
                sum += adc_value;
                valid++;
            }
        }
        k_msleep(5);
    }

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

    /* ===== Divider equation =====
       Top: Thermistor
       Bottom: 5.5k to GND
       Vadc = Vs * (R_fixed / (R_therm + R_fixed))
       Solve for R_therm:
       R_therm = R_fixed * (Vs / Vadc - 1)
    */
    float r_therm = R_FIXED * ((SUPPLY_VOLTAGE / v_adc) - 1.0f);

    if (r_therm <= 0.0f) {
        LOG_ERR("Invalid resistance computed for temperature");
        return;
    }

    float temp_kelvin = 1.0f / ((1.0f / T0_KELVIN) + (1.0f / BETA) * logf(r_therm / R0));
    float temp_c = temp_kelvin - 273.15f;
    float temp_f = (temp_c * 9.0f / 5.0f) + 32.0f + 2.0f; // +2°F calibration offset (to refine later)

    int32_t temperature_x100 = (int32_t)(temp_f * 100.0f);

    /* ===== Detailed Logging (for calibration) ===== */
            /* ===== Calibration Logging ===== */
        int32_t v_mv         = (int32_t)(v_adc * 1000.0f);
        int32_t r_therm_x10  = (int32_t)(r_therm * 10.0f);
        int32_t temp_c_x100  = (int32_t)(temp_c * 100.0f);
        int32_t temp_f_x100  = (int32_t)(temp_f * 100.0f);

        printk("\n========== TEMP SAMPLE ==========\n");
        printk("ADC Raw      : %d\n", adc_value);
        printk("ADC Voltage  : %ld.%03ld V\n",
            (long)(v_mv / 1000),
            (long)abs(v_mv % 1000));
        printk("Thermistor R : %ld.%01ld Ohm\n",
            (long)(r_therm_x10 / 10),
            (long)abs(r_therm_x10 % 10));
        printk("Temperature  : %ld.%02ld C\n",
            (long)(temp_c_x100 / 100),
            (long)abs(temp_c_x100 % 100));
        printk("Temperature  : %ld.%02ld F\n",
            (long)(temp_f_x100 / 100),
            (long)abs(temp_f_x100 % 100));

        /* CSV line for Excel/Python calibration */
        printk("TEMP_CSV,%d,%ld.%03ld,%ld.%01ld,%ld.%02ld,%ld.%02ld\n",
            adc_value,
            (long)(v_mv / 1000),
            (long)abs(v_mv % 1000),
            (long)(r_therm_x10 / 10),
            (long)abs(r_therm_x10 % 10),
            (long)(temp_c_x100 / 100),
            (long)abs(temp_c_x100 % 100),
            (long)(temp_f_x100 / 100),
            (long)abs(temp_f_x100 % 100));

        printk("=================================\n");

    /* Optional sanity check for human range */
   // if (temp_f < 80.0f || temp_f > 115.0f) {
   //     LOG_WRN("Temp out of normal human range");
   // }

    if (temperature_x100 < 8000 || temperature_x100 > 11000) {
        LOG_WRN("Temperature out of hardware sanity range (80 to 110 F) discarding");
        return;
    }

    // LOG_INF("Temperature sampled: ADC=%d, Vadc=%ld.%03ldV, Temp=%ld.%02ld F",
    //         adc_value,
    //         (long)(v_mv / 1000),
    //         (long)(v_mv % 1000),
    //         (long)temperature_x100 / 100,
    //         (long)temperature_x100 % 100);

    struct telemetry_msg msg = {
        .type = MSG_TYPE_TEMP,
        .timestamp = k_uptime_get()
    };
    msg.data.temp.temp_c_x100 = (int16_t)temperature_x100;

    app_post_telemetry(&msg);
}

void temp_stop(void)
{
}

void temp_init(void)
{
}
