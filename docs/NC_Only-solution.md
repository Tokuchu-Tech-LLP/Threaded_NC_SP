# Standalone Nurse Call Solution (`NC_Only` Variant from Single Codebase)

**Repository:** `Threaded_NC_SP`  
**Goal:** Generate both `SPNC_FOTA` (Full SpO2 + Temp + NC) and `NC_ONLY` (Pure Nurse Call, SpO2/Temp disabled at 9999) from the **same single repository** without duplicating folders and without modifying `TT_common`.  
**Status:** Reserved for future implementation.

---

## 1. Background & Context

In `Threaded_NC_SP`, the SpO2 and Body Temperature threads are dynamically controlled based on their configured scan rates:
* If `spo2_scan_rate_s == 9999`, the SpO2 sensor thread is **never spawned**.
* If `body_temp_scan_rate_s == 9999`, the Body Temperature sensor thread is **never spawned**.
* When both are `9999`, the device operates purely as a **Nurse Call (NC) unit**, saving RAM, CPU overhead, and battery.

The default values for these scan rates are set in `Threaded_NC_SP/src/schema_spo2.c` (locally within the device repo, not in `TT_common`).

---

## 2. Implementation Steps (To be executed when ready)

### Step 1: Add Kconfig Switch in `Threaded_NC_SP/Kconfig`
Add the following block to `Threaded_NC_SP/Kconfig`:
```kconfig
config APP_NURSE_CALL_ONLY
    bool "Build as Nurse Call Only (disable SpO2 and Temp)"
    default n
    help
      Sets default SpO2 and Temp scan rates to 9999 so sensor threads
      are never spawned, operating purely as a standalone Nurse Call device.
```

---

### Step 2: Update Local Defaults in `Threaded_NC_SP/src/schema_spo2.c`
In `Threaded_NC_SP/src/schema_spo2.c`, update `spo2_defaults`:
```c
static const struct spo2_config spo2_defaults = {
    .sensor_no = 1,
    .version = "1.0",
#if defined(CONFIG_APP_NURSE_CALL_ONLY)
    .spo2_scan_rate_s = 9999,        /* 9999 = Disabled */
    .body_temp_scan_rate_s = 9999,   /* 9999 = Disabled */
#else
    .spo2_scan_rate_s = 60,          /* Normal SpO2 scan (seconds) */
    .body_temp_scan_rate_s = 90,     /* Normal Temp scan (seconds) */
#endif
    .no_finger_threshold = 1000
};
```
*(Zero changes to `TT_common` required).*

---

### Step 3: Create Variant Kconfig File `nc_only.conf`
Create `Threaded_NC_SP/nc_only.conf` with:
```ini
CONFIG_APP_NURSE_CALL_ONLY=y
CONFIG_DEVICE_PREFIX="NC"
CONFIG_BT_DEVICE_NAME="Nurse_Call"
```

---

## 3. Build Commands

### Variant 1: Full Combo (`SPNC_FOTA`)
```cmd
west build -d build_spnc -b nrf52840dk/nrf52840
```
* **Output Deliverables**: `build_spnc/merged.hex`, `build_spnc/dfu_application.zip`
* **Device Name**: `NC_SpO2_Device` (Prefix: `NC_SP`)
* **Sensors**: SpO2 and Temp active.

### Variant 2: Nurse Call Only (`NC_ONLY`)
```cmd
west build -d build_nc -b nrf52840dk/nrf52840 -- -DEXTRA_CONF_FILE=nc_only.conf
```
* **Output Deliverables**: `build_nc/merged.hex`, `build_nc/dfu_application.zip`
* **Device Name**: `Nurse_Call` (Prefix: `NC`)
* **Sensors**: SpO2 and Temp threads **never created** (scan rates = 9999).

---

## 4. GitHub Release & Tooling Integration

When running `E4A-Version-Upgrade-Tool.bat`, the tool inspects all build folders and packages both variants into the release commit and GitHub Release assets:
* `Threaded_NC_SP-SPNC_FOTA-v1.xx-merged.hex` & `.zip`
* `Threaded_NC_SP-NC_ONLY-v1.xx-merged.hex` & `.zip`
