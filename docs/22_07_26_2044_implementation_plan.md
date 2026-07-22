# Threaded_NC_SP Firmware — Final Engineering Review & Implementation Plan
Timestamp: 23-07-26 02:44

## Executive Summary

This plan outlines the minimal, production-safe remediation of the `Threaded_NC_SP` firmware to satisfy senior feedback while preserving original reference algorithms (`SpO2_probe`).

---

## 1. Architectural Strategy

- **Gating Routine BLE Traffic:** Define an atomic flag `configurator_active` inside `tt_ble.c`. When `configurator_active == true`, `ble_utils_send_best_effort()` returns `0` immediately.
- **Configurator Response Isolation:** Configurator handlers use `ble_utils_send_critical()`. Gating `best_effort` reserves 100% of `ble_send_msgq` slots and BLE controller buffers for configurator responses.
- **Session Lifecycle:** Configurator mode enters immediately on `'c'` (before `PASSWORD?\n`) and exits on `SAVE`, `FACTORY RESET`, `REBOOT`, or `BLE disconnect`.
- **Stateless Parser:** Reverted to original SP parser (`memcpy` -> strip `\r`/`\n` -> dispatch).
- **Priority Elevation Removed:** Stripped dynamic `k_thread_priority_set()` calls from command handler execution.

---

## 2. File Touchlist

### Modified Files:
1. `TT_common/tt_ble.h`
2. `TT_common/tt_ble.c`
3. `TT_common/devices/nurse_call_spo2/tt_ble_handler.c`

### Untouched Files:
1. `Threaded_NC_SP/src/spo2_sensor.c` (SpO2 algorithm & math)
2. `Threaded_NC_SP/src/temp_sensor.c` (Temperature NTC formula & scaling)
3. `Threaded_NC_SP/src/nurse_call_app.c` (Nurse call state machine & button logic)
4. `TT_common/adc_utils.c` (ADC hardware configuration)
5. `TT_common/tt_ot_client.c` (OpenThread & CoAP messaging)
