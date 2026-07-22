# BLE Notification Producer Audit — Threaded_NC_SP
Timestamp: 23-07-26 02:44

## Methodology

Enumerated every call to `ble_utils_send_best_effort()`, `ble_utils_send_critical()`, `ble_utils_send()`, and `bt_nus_send()` across **only the files compiled into the Threaded_NC_SP target**, as determined by `CMakeLists.txt` and `tt_common.cmake`.

### Compiled File Set

From the build system (`TT_DEVICE_TYPE = NURSE_CALL_SPO2` -> `DEVICE_DIR = nurse_call_spo2`):

| Source | File |
|--------|------|
| TT_common | `tt_main.c`, `tt_ot_client.c`, `tt_ot_server.c`, `config_parameter.c`, `common_nvs.c`, `schema_common.c`, `config_engine.c`, `config_parser.c`, `common_button.c`, `tt_ble.c` |
| TT_common/devices/nurse_call_spo2 | `tt_ble_handler.c`, `schema_spo2.c` |
| Threaded_NC_SP/src | `app_threads.c`, `spo2_sensor.c`, `temp_sensor.c`, `nurse_call_app.c` |
| TT_common | `adc_utils.c` |

---

## The BLE Notification Pipeline

All BLE notifications flow through a **single pipeline**:

```
                          ┌──────────────────────────┐
Entry points:             │    ble_send_msgq          │
                          │    (k_msgq, 32 slots)     │
  ble_utils_send_         │                           │
    best_effort() ──→ k_msgq_put(K_NO_WAIT)    ──→   │
                          │                           │
  ble_utils_send_         │                           │
    critical()   ──→ k_msgq_put(K_MSEC(500))   ──→   │
                          │                           │
  ble_utils_send() ──→ calls best_effort()            │
                          └──────────┬────────────────┘
                                     │
                          k_work_submit(&ble_send_work)
                                     │
                                     ▼
                          ble_send_work_handler()   [sysworkq]
                                     │
                                     ▼
                          bt_nus_send()   ← SOLE CALL SITE
```

`bt_nus_send()` has exactly ONE call site in the entire codebase: `tt_ble.c:144`, inside `ble_send_work_handler()`. There is no other path to generate a BLE NUS notification.

---

## Complete Call Site Inventory

### `ble_utils_send_critical()` — 1 call site

| # | File | Line | Code | Classification |
|---|------|------|------|---------------|
| 1 | `tt_ble_handler.c` | 36 | `ble_utils_send_critical((const uint8_t *)msg, strlen(msg), K_MSEC(500))` | **CONFIGURATOR** |

Called from: `ble_send()` -> used by all configurator response handlers (`handle_config_request`, `handle_password`, `handle_config_read`, `handle_schema_request`, `handle_config_write`, `handle_config_verify`, `handle_save_dynamic`, `handle_factory_reset`, `handle_reboot`, `handle_measure_start`, `handle_measure_stop`).

### `ble_utils_send_best_effort()` — 1 direct call site

| # | File | Line | Code | Classification |
|---|------|------|------|---------------|
| 2 | `tt_ot_client.c` | 230 | `ble_utils_send_best_effort((const uint8_t *)ble_raw_buf, len)` | **ALL NON-CONFIGURATOR BLE TRAFFIC** |

This is inside `send_data_to_OTBR()`. Every non-configurator BLE notification flows through this single line.

### `ble_utils_send()` (wrapper -> calls `ble_utils_send_best_effort`) — 1 call site

| # | File | Line | Code | Classification |
|---|------|------|------|---------------|
| 3 | `tt_ble.c` | 98 | `ble_utils_send((const uint8_t *)"BLE_TIMEOUT\n", 12)` | **BLE TIMEOUT** |

Called from `ble_adv_timeout_handler()`. Cannot fire during configurator — advertising timer is cancelled on connection.

---

## Callers of `send_data_to_OTBR()`

| # | File | Line | Caller Function | Payload | Classification |
|---|------|------|----------------|---------|---------------|
| 4 | `app_threads.c` | 216 | `process_telemetry_msg()` | SpO2 JSON | ROUTINE TELEMETRY |
| 5 | `app_threads.c` | 231 | `process_telemetry_msg()` | Temp JSON | ROUTINE TELEMETRY |
| 6 | `app_threads.c` | 240 | `process_telemetry_msg()` | Nurse Call ACTIVE JSON | NURSE-CALL |
| 7 | `app_threads.c` | 248 | `process_telemetry_msg()` | Nurse Call CANCEL JSON | NURSE-CALL |
| 8 | `tt_ot_client.c` | 534 | `send_mesh_eid()` | MeshEID JSON | HEARTBEAT / OT-EVENT |
| 9 | `tt_ot_client.c` | 382 | `send_config_data()` | Common config JSON | OT CONFIG DUMP |
| 10 | `tt_ot_client.c` | 438 | `send_extaddr()` | FactoryEUI64 JSON | OT CONFIG DUMP |
| 11 | `tt_ot_client.c` | 476 | `send_mac_address()` | MAC JSON | OT CONFIG DUMP |
| 12 | `tt_ot_client.c` | 500 | `send_rloc_data()` | RLOC16 JSON | OT CONFIG DUMP |
| 13 | `common_button.c` | 178 | `handle_btn_action()` | Button event JSON | BUTTON EVENT |

---

## Conclusion

Gating `ble_utils_send_best_effort()` blocks all 7 competing routine BLE producers. Configurator traffic uses `ble_utils_send_critical()` exclusively and is unaffected.
