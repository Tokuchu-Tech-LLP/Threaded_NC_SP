# Threaded_NC_SP Firmware — Changes & Remediation Master Log

**Timestamp:** 23-07-26 02:44  
**Author:** Firmware Engineering Team  
**Target Architecture:** Zephyr RTOS / nRF52840DK (`nurse_call_spo2`)  
**Reference Firmware:** `SpO2_probe`  
**Mobile Application:** `MobileApplicationV2`  

---

## 1. Executive Summary

This document details all engineering investigations, architectural reviews, code modifications, and verification results completed for the `Threaded_NC_SP` firmware fleet target.

The primary objective of this work was to resolve mobile application configurator communication failures, command drops, parser warnings, and BLE advertising issues while strictly observing the senior engineer's feedback:

> *"during configurator part u must wait for response after sending command and also when sending configurator command stop everything extra. DO NOT modify any working sensor algorithms, medical calculations, ADC scaling, SpO2 logic, temperature formulas, calibration values, or hardware constants unless they differ from the original SP firmware."*

---

## 2. Senior Directives & Constraints

1. **Reference Firmware Authority:** The single-threaded `SpO2_probe` firmware is the production reference implementation.
2. **Medical Algorithm Integrity:** SpO2 calculation, thermistor Beta equations, ADC scaling factors, and calibration formulas MUST remain 100% untouched.
3. **No Over-Engineering:** Avoid unrequested thread suspensions, semaphores, queue redesigns, or custom BLE stack callbacks.
4. **Safety-Critical Operations:** Emergency Nurse Call alerts over OpenThread CoAP must continue functioning without interference.

---

## 3. Detailed Summary of Issues & Resolutions

### Issue 1: BLE Advertising Name Truncation / Discovery Failures
- **Symptom:** BLE advertising packets failed discovery or showed corrupted/truncated device names on mobile scanners.
- **Root Cause:** `BT_LE_ADV_OPT_USE_NAME` was used in `bt_le_adv_start()` parameters, causing the Zephyr BLE stack to attempt automatic name packing into the limited 31-byte primary advertising payload, resulting in packet overflow when combined with service UUIDs.
- **Resolution:** Removed `BT_LE_ADV_OPT_USE_NAME` option and explicitly formatted `BT_DATA_NAME_COMPLETE` with the dynamic profile name string in the advertising dataset (`ad[]`).

### Issue 2: Configurator Response Dropping / BLE Queue Contention
- **Symptom:** During mobile app configurator sessions (e.g. schema reads `m`, parameter reads `r`, parameter writes `c`), responses were dropped or hit `bt_att: No ATT channel` / `-ENOMEM` errors.
- **Root Cause:** In `Threaded_NC_SP`, sensor loops run on independent threads (`spo2_thread`, `temp_thread`). They continuously posted measurement notifications to `telemetry_tx_thread`, which called `send_data_to_OTBR()` -> `ble_utils_send_best_effort()`. This asynchronously flooded `ble_send_msgq` (depth 32) while the configurator handler tried to send multi-line responses via `ble_utils_send_critical()`.
- **Resolution:** Introduced an atomic session flag `configurator_active` inside `tt_ble.c`. When `configurator_active == true`, `ble_utils_send_best_effort()` immediately returns `0`, suppressing routine telemetry BLE queue insertion and reserving 100% of send queue slots and BLE stack buffers for configurator responses.

### Issue 3: Misleading Parser Fragment Timeout Warnings
- **Symptom:** Log emitted `<wrn> ble_cmd: BLE command fragment timeout (>3000ms) — resetting RX buffer` when user paused between configurator commands.
- **Root Cause:** An experimental 3000ms stateful fragment assembly buffer (`parser_cmd`, `parser_cmd_len`) was introduced into `nurse_call_spo2/tt_ble_handler.c`. Because all mobile configurator commands (1 to 35 bytes) fit inside a single BLE write packet (80-byte ATT MTU payload cap), fragment assembly was unnecessary. When users paused for >3 seconds between commands, the timer fired falsely.
- **Resolution:** Reverted to the production-proven stateless SP parser from `SpO2_probe` (`memcpy` -> null terminate -> strip trailing `\r`/`\n` -> dispatch).

### Issue 4: Dynamic Thread Priority Elevation Overhead
- **Symptom:** Unnecessary thread priority manipulation inside `execute_single_ble_command()`.
- **Root Cause:** Previous diagnostic code dynamically called `k_thread_priority_set(k_current_get(), K_PRIO_PREEMPT(1))` during command execution. This did not allocate BLE stack buffers or prevent queue flooding, but introduced thread scheduling preemption risks.
- **Resolution:** Stripped `k_thread_priority_set()` calls completely.

---

## 4. Detailed File-by-File Changes

### File 1: `Firmware/TT_common/tt_ble.h`

| Change | Function / Location | How | Why |
|--------|---------------------|-----|-----|
| Added Function Declarations | Lines 54–55 | Added `void ble_set_configurator_active(bool active);` and `bool ble_is_configurator_active(void);` | Exposes configurator session state API across common firmware modules. |

---

### File 2: `Firmware/TT_common/tt_ble.c`

| Change | Function / Location | How | Why |
|--------|---------------------|-----|-----|
| Defined Atomic Flag | Line 47 | Added `static atomic_t configurator_active = ATOMIC_INIT(0);` | Thread-safe atomic flag tracking configurator session state. |
| Getter & Setter | Lines 49–58 | Implemented `ble_set_configurator_active()` and `ble_is_configurator_active()` | Allows BLE command handlers and connection callbacks to set and query configurator state. |
| Disconnect Reset | `disconnected()` Line 268 | Added `ble_set_configurator_active(false);` | Guarantees configurator mode is cleared whenever BLE disconnects, preventing telemetry from remaining stuck off. |
| Best-Effort Gate Check | `ble_utils_send_best_effort()` Line 402 | Added `if (atomic_get(&configurator_active)) return 0;` | Gates 100% of non-configurator routine BLE traffic at the sole entry point into `ble_send_msgq`. |

---

### File 3: `Firmware/TT_common/devices/nurse_call_spo2/tt_ble_handler.c`

| Change | Function / Location | How | Why |
|--------|---------------------|-----|-----|
| Header Include | Line 16 | Added `#include "tt_ble.h"` | Connects configurator state API to command handlers. |
| Session Activation | `handle_config_request()` Line 106 | Added `ble_set_configurator_active(true);` before `ble_send("PASSWORD?\n")` | Activates configurator session immediately upon `'c'` command, isolating BLE before password exchange and schema reads. |
| Session Exit (Save) | `handle_save_dynamic()` Line 306 | Added `ble_set_configurator_active(false);` after `SAVE_OK` and `CFG` lines are enqueued | Restores routine BLE telemetry after configuration save completes. |
| Session Exit (Reset/Reboot) | `handle_factory_reset()`, `handle_reboot()` | Added `ble_set_configurator_active(false);` prior to `sys_reboot()` | Ensures clean state across resets. |
| Parser Reset | `ble_cmd_reset_parser()` Line 472 | Added `ble_set_configurator_active(false);` | Restores normal state on parser reset events. |
| Removed Priority Elevation | `execute_single_ble_command()` Lines 490+ | Removed `k_thread_priority_set()` call wrappers | Eliminates thread preemption risks. |
| Parser Restoration | `ble_command_parser()` Lines 593–616 | Reverted to 25-line stateless parser from `SpO2_probe` | Removes fragment state machine, eliminates false warnings, and processes both `\n` and non-`\n` single-write commands cleanly. |

---

## 5. Medical Algorithms & Untouched Components

The following files and components were verified and **left 100% untouched**:

1. `Threaded_NC_SP/src/spo2_sensor.c` — SpO2 calculation algorithm, R-curve math, AC/DC peak detection.
2. `Threaded_NC_SP/src/temp_sensor.c` — Temperature NTC Steinhart-Hart / Beta equations and ADC scaling.
3. `Threaded_NC_SP/src/nurse_call_app.c` — Physical button debouncing and Nurse Call state machine.
4. `TT_common/adc_utils.c` — Hardware SAADC configuration.
5. `TT_common/tt_ot_client.c` — OpenThread network stack and CoAP messaging.

---

## 6. Build & Verification Results

- **Compiler Toolchain:** Nordic nRF Connect SDK v3.0.2 / Zephyr West
- **Build Command:** `./run_with_ncs.sh west build -d build_threaded_nc_sp -b nrf52840dk/nrf52840`
- **Result:** **COMPILATION SUCCESSFUL** (0 Errors, 0 Warnings)
- **Flash Usage:** 94.08% (458,100 / 486,912 bytes)
- **RAM Usage:** 67.60% (177,214 / 262,144 bytes)
