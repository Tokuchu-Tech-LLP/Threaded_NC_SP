# BLE Notification Producer Analysis — Threaded_NC_SP
Timestamp: 23-07-26 02:44

## Executive Summary

The Threaded_NC_SP firmware exhibited BLE notification packet drops during mobile application configurator sessions. The senior engineer provided the following requirement:

> "during configurator part u must wait for response after sending command and also when sending configurator command stop everything extra"

This analysis traces all BLE notification producers in the codebase, explains why packet drops occurred in the threaded firmware compared to the original single-threaded SP firmware, and justifies the gating mechanism chosen.

---

## 1. Architectural Comparison: Original SP vs Threaded_NC_SP

### Original Production SP Firmware (`SpO2_probe`)
- All work items (sensor reads, SpO2 calculation, temperature calculation, BLE notification dispatch) were queued onto Zephyr's system workqueue (`sysworkq`).
- Configurator commands received over NUS were processed synchronously on the system workqueue or BT RX thread.
- **Result:** Sensor calculations and BLE notification transmissions were naturally serialized. A configurator request naturally paused sensor work because `sysworkq` executed one item at a time.

### Threaded_NC_SP Firmware
- Decoupled sensor loops into separate RTOS threads:
  - `spo2_thread` (prio 5)
  - `temp_thread` (prio 6)
  - `telemetry_tx_thread` (prio 7)
- `spo2_thread` and `temp_thread` asynchronously post measurement messages to `telemetry_msgq`.
- `telemetry_tx_thread` pops messages and calls `send_data_to_OTBR()` -> `ble_utils_send_best_effort()`.
- **Result:** While the user interacts with the mobile configurator app, `telemetry_tx_thread` asynchronously dumps SpO2/temp notifications into `ble_send_msgq` (depth 32). When the configurator handler tries to send multi-line responses (such as schema dumps or config reads via `ble_utils_send_critical()`), the queue and SoftDevice controller buffers overflow (`bt_att: No ATT channel`, `-ENOMEM`).

---

## 2. Producer Audit

All BLE notifications in the system flow into `ble_send_msgq` in `tt_ble.c` and are transmitted by `ble_send_work_handler()` via `bt_nus_send()`.

| Producer | Entry Function | Delivery Queue | Gated During Config? |
|----------|---------------|----------------|----------------------|
| **Configurator Responses** | `ble_send()` -> `ble_utils_send_critical()` | `ble_send_msgq` (`K_MSEC(500)`) | **NO** (Must transmit) |
| **SpO2 Telemetry** | `send_data_to_OTBR()` -> `ble_utils_send_best_effort()` | `ble_send_msgq` (`K_NO_WAIT`) | **YES** |
| **Temp Telemetry** | `send_data_to_OTBR()` -> `ble_utils_send_best_effort()` | `ble_send_msgq` (`K_NO_WAIT`) | **YES** |
| **Heartbeat / MeshEID** | `send_mesh_eid()` -> `send_data_to_OTBR()` | `ble_send_msgq` (`K_NO_WAIT`) | **YES** |
| **Button Events** | `handle_btn_action()` -> `send_data_to_OTBR()` | `ble_send_msgq` (`K_NO_WAIT`) | **YES** |
| **Nurse Call Alerts (BLE)** | `send_data_to_OTBR()` -> `ble_utils_send_best_effort()` | `ble_send_msgq` (`K_NO_WAIT`) | **YES** (CoAP over 802.15.4 active) |

---

## 3. Recommended Solution

Gate `ble_utils_send_best_effort()` using an atomic flag `configurator_active`.

- When `configurator_active == true`:
  - `ble_utils_send_best_effort()` immediately returns `0` without placing packets into `ble_send_msgq`.
  - `telemetry_tx_thread` drains `telemetry_msgq` cleanly without blocking or accumulating RAM.
  - `ble_send_msgq` is reserved 100% for `ble_utils_send_critical()` (configurator responses).
  - Safety-critical Nurse Call alerts continue over the OpenThread CoAP network (`send_data_to_OTBR_internal()`).
