# Threaded_NC_SP Firmware Remediation Summary

This document records the firmware architecture and remediation work completed for the `Threaded_NC_SP` target and the shared `TT_common` modules it depends on.

The main goal was to make Nurse Call + SpO2 firmware safer under real device conditions: emergency alerts must not be lost, BLE configuration commands must survive fragmented mobile writes, runtime configuration must be read consistently across threads, and sensor/transport edge cases must fail safely instead of silently corrupting behavior.

## Scope

Primary target files:

- `Firmware/Threaded_NC_SP/src/app_threads.c`
- `Firmware/Threaded_NC_SP/src/spo2_sensor.c`
- `Firmware/Threaded_NC_SP/src/temp_sensor.c`
- `Firmware/Threaded_NC_SP/src/nurse_call_app.c`

Shared modules updated for this target:

- `Firmware/TT_common/tt_ot_client.c`
- `Firmware/TT_common/tt_ble.c`
- `Firmware/TT_common/common_nvs.c`
- `Firmware/TT_common/common_nvs.h`
- `Firmware/TT_common/tt_main.c`
- `Firmware/TT_common/common_button.c`
- `Firmware/TT_common/devices/nurse_call_spo2/tt_ble_handler.c`

## Firmware Architecture

`Threaded_NC_SP` runs the Nurse Call + SpO2 application as multiple Zephyr threads:

- SpO2 thread: periodically samples and computes SpO2 and heart-rate telemetry.
- Temperature thread: periodically samples body/room temperature telemetry.
- Nurse Call thread: monitors Nurse Call state and posts alert/cancel events.
- Telemetry TX thread: prioritizes emergency alert delivery before routine telemetry.

Two message queues are used:

- `alert_msgq`: high-priority Nurse Call alert/cancel events.
- `telemetry_msgq`: routine SpO2 and temperature telemetry.

The dispatch model intentionally gives Nurse Call alerts priority over routine telemetry. The telemetry thread drains alert work before it processes normal telemetry so an emergency cannot sit behind lower-priority sensor updates.

## 1. Emergency Alert Persistence and Priority

### Original issue

Nurse Call alerts could be lost in several situations:

- `alert_msgq` could fill and reject a new emergency alert.
- A network or CoAP send failure could happen after the alert left the local queue.
- Routine telemetry could run before all queued emergency alerts were drained.
- A newer cancel/alert state could be overwritten by an older failed alert retry.

For Nurse Call behavior this is high risk: an emergency alert must persist until it is delivered or superseded by a newer alert state.

### Implementation

`app_threads.c` now maintains protected pending alert state:

- `pending_alert_active`
- `pending_alert_id`
- `pending_alert_state`
- `pending_alert_timestamp`

These fields are protected by `alert_state_mutex` and accessed through helper functions:

- `app_set_pending_alert()`
- `app_set_pending_alert_on_failure()`
- `app_get_pending_alert()`
- `app_clear_pending_alert_if_matched()`
- `app_notify_alert_ack_received()`
- `app_notify_alert_ack_failed()`

The telemetry thread now drains all queued alert messages before routine telemetry. It also preserves the latest pending alert state when enqueue fails or transport delivery has not yet been acknowledged.

For stale-state protection, each alert/cancel carries a timestamp. A failed older alert is not allowed to overwrite a newer pending state. This prevents a sequence like `ALERT -> CANCEL -> old ALERT retry failure` from reverting the pending state back to active incorrectly.

### Why this helps

The firmware now treats Nurse Call state as persistent application state, not just a best-effort queue item. If a queue operation or network transmission fails, the latest alert state remains available for retry. The timestamp and match checks prevent older messages from clearing or overwriting newer emergency state.

## 2. CoAP Transport Status and ACK Handling

### Original issue

The original transport path did not return meaningful delivery status to the application. `send_data_to_OTBR()` was effectively fire-and-forget from the alert state machine's point of view. A local call into the CoAP stack could be treated as success even when real delivery had not happened.

### Implementation

`tt_ot_client.c` now returns integer status from:

- `send_data_to_OTBR_internal()`
- `send_data_to_OTBR()`

Alert/cancel payloads are sent with a CoAP reply callback path. The callback passes alert identity back to `app_threads.c` using:

- `app_notify_alert_ack_received(alert_id, is_active, timestamp)`
- `app_notify_alert_ack_failed()`

The ACK notification clears pending state only through `app_clear_pending_alert_if_matched()`, which verifies alert ID, active/cancel state, and timestamp before clearing.

### Why this helps

The application no longer clears emergency state simply because it attempted a send. In Hospital CoAP mode, pending alert state remains active until the response path confirms it should be cleared. Matching by alert identity and timestamp avoids clearing a newer pending alert from an older response.

## 3. Alert Retry Backoff

### Original issue

Retried alert sends could loop too aggressively during repeated network failures. A tight retry loop wastes power and can crowd out other system work.

### Implementation

The telemetry thread now uses retry backoff for failed alert delivery attempts:

- Starts at 200 ms.
- Doubles on repeated failure.
- Caps at 3200 ms.
- Resets to 200 ms after a successful dispatch/clear path.

### Why this helps

The device keeps retrying emergency alerts, but does so in a controlled way. This reduces repeated network pressure and power use while still maintaining persistence of the latest Nurse Call state.

## 4. Atomic Measurement State

### Original issue

`spo2_sampling_active` and `measuring_enabled` were shared across threads. Plain boolean access could race between BLE command handling, background hibernation checks, and sampling threads.

### Implementation

Both flags were converted to Zephyr `atomic_t` primitives. Access now uses:

- `atomic_get()`
- `atomic_set()`

The hibernation check in `device_background_process()` now correctly uses `atomic_get(&measuring_enabled)`.

### Why this helps

The measurement control path is now safe for concurrent thread access. BLE start/stop commands, sampling loops, and power-management checks all see consistent state.

## 5. BLE Command Parser Robustness

### Original issue

BLE writes from mobile apps can arrive fragmented or batched. The old parser could lose partial commands, execute only one command from a multi-command packet, or prematurely interpret a fragmented config command such as `c|common|device_type=12` as a single-character `c` command.

### Implementation

`Firmware/TT_common/devices/nurse_call_spo2/tt_ble_handler.c` now uses a line-scanning parser:

- Accumulates incoming BLE bytes into a parser buffer.
- Executes every complete `\n` or `\r` terminated command.
- Preserves incomplete trailing fragments with `memmove()`.
- Resets stale fragments after a timeout.
- Rejects overlong commands with `CMD_TOO_LONG`.

The single-byte auto-completion behavior was adjusted so fragmented `c|...` config writes are not mistaken for a password prompt request.

Named configuration writes now accept both `field=value` and `field:value` separators.

### Why this helps

BLE command handling now matches real BLE transport behavior. Configuration writes are not lost or misinterpreted when mobile clients split commands across multiple BLE packets.

## 6. Critical BLE Admin Responses

### Original issue

BLE admin/config responses used best-effort send behavior. During configuration workflows, dropped admin responses can confuse the mobile app and user.

### Implementation

Admin protocol responses in `tt_ble_handler.c` now call `ble_utils_send_critical()` with a timeout. The BLE send buffer size in `tt_ble.c` was increased from 256 bytes to 512 bytes to handle longer schema/config lines.

### Why this helps

Configuration responses now have a better chance of being delivered under queue pressure, and long schema responses are less likely to be rejected due to buffer size.

## 7. BLE Disconnect Cleanup

### Original issue

Queued BLE notifications could survive disconnect and leak into a later BLE session. Parser state could also survive across sessions.

### Implementation

`tt_ble.c` now provides `ble_purge_send_queue()` and calls it on disconnect. `ble_cmd_reset_parser()` is weakly defined in the BLE utility layer and overridden by device handlers that maintain parser state.

### Why this helps

Each BLE connection starts clean. A new mobile session will not receive stale notifications intended for the previous connection, and partial parser state does not cross session boundaries.

## 8. Advertising Behavior

### Original issue

BLE advertising options were not aligned with the intended connectable named-device behavior.

### Implementation

Advertising flags were updated to:

- `BT_LE_ADV_OPT_CONNECTABLE`
- `BT_LE_ADV_OPT_USE_NAME`

### Why this helps

The device advertises as a connectable BLE peripheral using its configured name, improving discoverability and mobile connection behavior.

## 9. Config Mutex and Thread-Safe Accessors

### Original issue

Runtime configuration structs such as `common_cfg` and `spo2_cfg` were read directly from multiple threads while BLE config saves could update them. This could produce mixed old/new values, especially for multi-byte fields such as IPv6 suffixes and profile strings.

### Implementation

`common_nvs.c` now provides synchronized getters, including:

- `common_config_get_device_type()`
- `common_config_get_profile()`
- `common_config_get_lamp_profile()`
- `common_config_get_otbr_ipv6_suffix()`
- `common_config_get_mesh_prefix()`
- `common_config_get_lamp_ipv6_suffix()`
- `common_config_get_network_ipv6_suffix()`
- `common_config_get_heartbeat_time_s()`
- `common_config_get_ble_timeout_s()`
- `common_config_get_battery_mode()`
- `common_config_get_idle_time_hibernate()`
- `common_config_get_spo2_scan_rate()`
- `common_config_get_body_temp_scan_rate()`
- `spo2_config_get_no_finger_threshold()`

Active target-path reads in `Threaded_NC_SP` and the relevant `TT_common` modules were migrated to these accessors.

### Why this helps

Readers now copy configuration under `config_mutex`, so runtime code does not observe partially updated struct fields. This is especially important for CoAP addressing and BLE naming.

## 10. Safer NVS Save Ordering

### Original issue

The active RAM config could be updated before the NVS flash write succeeded. If flash write failed, the device would run with unsaved settings while reporting `SAVE_FAIL`, then revert after reboot.

### Implementation

`common_nvs_save_block()` now:

1. Copies candidate config into a local save buffer under `config_mutex`.
2. Writes that snapshot to NVS outside the mutex.
3. Updates active RAM under `config_mutex` only after `nvs_write()` succeeds.

### Why this helps

Runtime RAM state now matches persisted state after a successful save. If flash persistence fails, active RAM remains unchanged and the BLE admin response accurately reports failure.

## 11. Dynamic SpO2 No-Finger Threshold

### Original issue

SpO2 no-finger detection used a hardcoded threshold. That made calibration difficult across devices, sensor assemblies, and deployment conditions.

### Implementation

`spo2_start()` now reads the threshold from configuration through `spo2_config_get_no_finger_threshold()`. If the configured value is invalid or zero, it falls back to the previous default threshold of `1000`.

### Why this helps

No-finger detection can now be tuned through configuration without rebuilding firmware, while still preserving a safe default.

## 12. SpO2 Ratio Math Guard

### Original issue

SpO2 calculation divided by RED and IR DC values. Very low or noisy DC values could cause unstable ratios or invalid math.

### Implementation

Before computing AC/DC ratios, `spo2_start()` now checks:

- `red_dc < 50.0f`
- `ir_dc < 50.0f`

If either DC level is too low, the sample is skipped.

### Why this helps

The algorithm avoids division by near-zero or noise-dominated signal levels, reducing invalid SpO2 output.

## 13. Temperature Sanity Range

### Original issue

The temperature sanity filter was too narrow for startup and room-temperature readings. Valid readings could be discarded while the sensor stabilized.

### Implementation

The valid temperature range in `temp_sensor.c` was widened to:

- Minimum: `-10.0 C`
- Maximum: `60.0 C`

### Why this helps

The firmware accepts realistic ambient/startup readings while still filtering obvious ADC short/open faults and impossible sensor values.

## 14. OpenThread Cleanup

### Original issue

Legacy callback setup code remained in `tt_ot_client.c`, increasing confusion around which Thread state monitoring path was active.

### Implementation

Unused legacy Thread state monitoring code was removed, leaving the active OpenThread callback registration path.

### Why this helps

The OpenThread client code is clearer and has less dead behavior to audit or accidentally re-enable.

## 15. Target-Path Config Accessor Coverage

### Original issue

Some active target-path code still read `common_cfg` directly after synchronized accessors were introduced.

### Implementation

Direct runtime reads were replaced in active `Threaded_NC_SP` paths, including:

- `tt_main.c`
- `common_button.c`
- `tt_ot_client.c`
- `tt_ble.c`
- `devices/nurse_call_spo2/tt_ble_handler.c`
- `common_nvs.c` callers

### Why this helps

The active target now consistently uses synchronized access patterns for runtime configuration, reducing race conditions during BLE config updates.

## Known Review Note

The latest ACK identity implementation stores one in-flight CoAP alert context in `tt_ot_client.c`. This is a major improvement over unconditional ACK clearing because the ACK callback now passes alert ID, state, and timestamp into a matched clear path.

However, if the firmware allows more than one confirmable alert request to be outstanding at the same time, a single global in-flight slot can still be overwritten by a later request before an older response arrives. The robust long-term design is either:

1. Enforce only one outstanding alert CoAP request at a time.
2. Store per-request context keyed by CoAP token/message identity.

This note is included so future work does not mistake the current single-slot implementation for a general multi-flight ACK correlation system.

## Verification

The final reported build command was:

```sh
./run_with_ncs.sh west build -d build_threaded_nc_sp -b nrf52840dk/nrf52840
```

Final reported build result:

```text
Memory region         Used Size  Region Size  %age Used
           FLASH:      457440 B     486912 B     93.95%
             RAM:      172932 B       256 KB     65.97%
Generating ../dfu_application.zip
Generating ../merged.hex
Build completed successfully with ZERO errors!
```

## Result

The remediation work significantly improves the reliability and safety of the `Threaded_NC_SP` firmware:

- Nurse Call alerts are prioritized over routine telemetry.
- Latest alert/cancel state persists across queue and transport failures.
- Alert state updates are mutex-protected and timestamp-aware.
- BLE command parsing handles fragmented and batched commands correctly.
- Runtime config reads are synchronized.
- NVS save behavior is consistent with reported save status.
- SpO2 and temperature calculations reject unsafe sensor edge cases.
- BLE disconnects and admin responses are handled more predictably.

The remaining architectural caution is ACK correlation for multiple simultaneous confirmable alert requests, documented above for future hardening.
