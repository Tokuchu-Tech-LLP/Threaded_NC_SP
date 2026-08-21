#include "common_nvs.h"

struct spo2_config spo2_cfg;
struct spo2_config spo2_candidate_cfg;

static const struct spo2_config spo2_defaults = {
    .sensor_no = 1,
    .version = "1.0",
    .spo2_scan_rate_s = 60,
    .body_temp_scan_rate_s = 90,
    .no_finger_threshold = 1000
};

static const config_field_t spo2_fields[] = {
    {
        .name = "sensor_no",
        .label = "Sensor Number",
        .type = PARAM_TYPE_UINT,
        .struct_offset = offsetof(struct spo2_config, sensor_no),
        .field_size = sizeof(((struct spo2_config *)0)->sensor_no),
        .min_val = 0,
        .max_val = 99,
        .unit = NULL,
        .select_options = NULL,
        .description = "Two digit sensor id",
        .custom_validate = NULL
    },
    {
        .name = "version",
        .label = "Version",
        .type = PARAM_TYPE_STRING,
        .struct_offset = offsetof(struct spo2_config, version),
        .field_size = sizeof(((struct spo2_config *)0)->version),
        .min_val = 0,
        .max_val = 0,
        .unit = NULL,
        .select_options = NULL,
        .description = "Firmware config version",
        .custom_validate = NULL
    },
    {
        .name = "no_finger",
        .label = "No Finger Threshold",
        .type = PARAM_TYPE_INT,
        .struct_offset = offsetof(struct spo2_config, no_finger_threshold),
        .field_size = sizeof(((struct spo2_config *)0)->no_finger_threshold),
        .min_val = 100,
        .max_val = 20000,
        .unit = NULL,
        .select_options = NULL,
        .description = "ADC threshold for finger detection",
        .custom_validate = NULL
    },
    {
        .name = "spo2_scan_rate",
        .label = "SpO2 Scan Rate",
        .type = PARAM_TYPE_UINT,
        .struct_offset = offsetof(struct spo2_config, spo2_scan_rate_s),
        .field_size = sizeof(((struct spo2_config *)0)->spo2_scan_rate_s),
        .min_val = 1,
        .max_val = 3600,
        .unit = "sec",
        .select_options = NULL,
        .description = "Sampling interval in seconds",
        .custom_validate = NULL
    },
    {
        .name = "temp_scan_rate",
        .label = "Temperature Scan Rate",
        .type = PARAM_TYPE_UINT,
        .struct_offset = offsetof(struct spo2_config, body_temp_scan_rate_s),
        .field_size = sizeof(((struct spo2_config *)0)->body_temp_scan_rate_s),
        .min_val = 1,
        .max_val = 3600,
        .unit = "sec",
        .select_options = NULL,
        .description = "Sampling interval in seconds",
        .custom_validate = NULL
    }
};

static const config_alias_t spo2_aliases[] = {
    {"RATE", &spo2_fields[3]},
    {"TEMP", &spo2_fields[4]},
    {"TH", &spo2_fields[2]}
};

const config_block_t spo2_config_block = {
    .nvs_id = NVS_ID_SPO2_CONFIG,
    .struct_size = sizeof(struct spo2_config),
    .active_ptr = &spo2_cfg,
    .candidate_ptr = &spo2_candidate_cfg,
    .default_ptr = &spo2_defaults,
    .fields = spo2_fields,
    .field_count = ARRAY_SIZE(spo2_fields),
    .schema_id = "device",
    .schema_name = "SpO2 Config",
    .schema_desc = "Editable BLE NVS parameters",
    .aliases = spo2_aliases,
    .alias_count = ARRAY_SIZE(spo2_aliases)
};

