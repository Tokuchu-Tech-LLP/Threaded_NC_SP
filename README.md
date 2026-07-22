# Threaded_NC_SP Firmware

Unified, multithreaded Zephyr RTOS firmware combining **Nurse Call Emergency Alerting** and **SpO2 / Temperature Vital Signs Monitoring** for Nordic Semiconductor nRF52840 (`nrf52840dk/nrf52840`).

---

## 📚 Technical Documentation & Remediation Logs

All architectural reviews, audit reports, and remediation change logs are maintained in the [`docs/`](docs/) directory, labeled by their exact creation timestamps (`DD_MM_YY_HHMM`):

- 📋 [**Master Changes & Remediation Log**](docs/23_07_26_0243_FIRMWARE_CHANGES_AND_REMEDIATION.md) *(Created: 23-07-26 02:43)* — Complete file-by-file change log, issues resolved, how, and why.
- 🏗️ [**Implementation Plan**](docs/22_07_26_2044_implementation_plan.md) *(Created: 22-07-26 20:44)* — Firmware touchlist and gating architecture strategy.
- 📜 [**Parser Protocol Audit**](docs/22_07_26_2030_parser_analysis.md) *(Created: 22-07-26 20:30)* — Mobile app BLE write payload audit and stateless parser justification.
- 🔍 [**BLE Notification Producer Audit**](docs/22_07_26_2022_ble_callsite_audit.md) *(Created: 22-07-26 20:22)* — Complete trace of all 9 BLE notification call sites in compiled sources.
- ⚡ [**BLE Producer Analysis**](docs/22_07_26_2014_ble_producer_analysis.md) *(Created: 22-07-26 20:14)* — Architectural evaluation of thread-decoupled telemetry vs reference queueing.
- 🛡️ [**Architectural Hardening Summary**](docs/22_07_26_0529_REMEDIATION_SUMMARY.md) *(Created: 22-07-26 05:29)* — Summary of CoAP ACK locks, NVS flash-first persistence, and alert queues.
- 📖 [**Architectural Readme**](docs/22_07_26_0529_ARCHITECTURAL_README.md) *(Created: 22-07-26 05:29)* — Scope and thread dispatch architecture breakdown for Nurse Call + SpO2.

---

## 📌 Project Overview

This repository represents the merged, production-grade firmware uniting two distinct medical device applications:
1. **Nurse Call Alert System**: Instant emergency button handling, alert state machine, rapid LED status indication, and low-latency OpenThread CoAP / BLE NUS alert propagation.
2. **SpO2 & Temperature Sensor Probe**: Continuous/periodic optical Red & IR hybrid photodiode ADC sampling, heart rate calculation, median smoothing, and thermistor temperature measurement.

By refactoring sequential delayable workqueues into **dedicated Zephyr RTOS threads**, the device achieves deterministic task scheduling, non-blocking BLE responsiveness, zero cross-sensor ADC interference, and low power consumption.

---

## ⚙️ Key Technical Features & Configurations

### 1. Unified Device Identifiers & Profile
- **`TT_DEVICE_TYPE`**: `"NURSE_CALL_SPO2"`
- **`CONFIG_DEVICE_PREFIX`**: `"NC_SP"`
- **`CONFIG_DEVICE_DEFAULT_PROFILE`**: `"E4A_%.8s"` (Generates profile with MAC address suffix)
- **`CONFIG_BT_DEVICE_NAME`**: `"NC_SpO2_Device"`
- **CoAP Telemetry Endpoint**: `/telemetry`

---

## 🧵 Multithreading Engine & Architecture

The firmware spawns **4 dedicated Zephyr kernel threads** managed by RTOS priority scheduling, communicating asynchronously via a Zephyr Message Queue (`k_msgq`), and protected against hardware resource contention via an ADC Mutex (`adc_lock`).

```
+-------------------+       +-------------------+       +-----------------------+
|  nurse_call_thread|       |    spo2_thread    |       |      temp_thread      |
|   (Priority 4)    |       |   (Priority 5)    |       |     (Priority 6)      |
+---------+---------+       +---------+---------+       +-----------+-----------+
          |                           |                             |
          | Button/Alert              | SpO2 & Pulse                | Temperature
          +-------------------+       | Data                        | Data
                              |       |                             |
                              v       v                             v
                     +------------------------------------------------+
                     |         telemetry_msgq (Zephyr k_msgq)         |
                     +-----------------------+------------------------+
                                             |
                                             v
                                 +-----------------------+
                                 |  telemetry_tx_thread  |
                                 |     (Priority 7)      |
                                 +-----------+-----------+
                                             |
                                             v
                                  [ BLE NUS & CoAP Dispatch ]
```

### Thread Specifications

| Thread Name | Priority | Stack Size | Role & Functionality |
| :--- | :---: | :---: | :--- |
| **`nurse_call_thread`** | `Prio 4` (Highest) | 2048 B | Instant GPIO button debouncing, alert state machine execution, emergency LED flashing, and remote trigger processing. |
| **`spo2_thread`** | `Prio 5` | 4096 B | Synchronous Red/IR hybrid LED multiplexing, 100Hz ADC sampling, median noise filtering, FFT heart rate calculation, and SpO2 computation. |
| **`temp_thread`** | `Prio 6` | 2048 B | Periodic thermistor voltage divider sampling, Steinhart-Hart / Beta equation temperature calculation, and calibration adjustment. |
| **`telemetry_tx_thread`** | `Prio 7` | 3072 B | Blocks on `telemetry_msgq`. Assembles unified JSON telemetry payloads and dispatches them over BLE NUS notifications and OpenThread CoAP. |

### Hardware Mutex Synchronization (`adc_lock`)
Because both `spo2_thread` (photodiode ADC) and `temp_thread` (thermistor ADC) share the single underlying nRF52840 ADC hardware controller (`SAADC`), all ADC channel reconfigurations and `adc_read()` calls are strictly wrapped with `k_mutex_lock(&adc_lock, K_FOREVER)`. This guarantees zero channel-switching race conditions.

---

## 📲 Mobile App V2 Compatibility & Stability Engineering

This repository incorporates 3 critical stability fixes engineered to ensure seamless interoperability with **Mobile Application V2**:

1. **Handshake Disconnection Fix (`snprintf` Buffer Protection)**:
   - *Problem*: Standard `snprintf` returns the un-truncated length rather than bytes written, causing integer underflow in remaining capacity tracking during `v|common` configuration verification.
   - *Fix*: Strict bounds checks stop buffer formatting before overflow, preventing ARM `HardFault` crashes and unexpected Bluetooth disconnects.
2. **Schema Field Alignment (`strsep` Parsing)**:
   - *Problem*: `strtok()` skips empty fields (`||`), shifting subsequent parameters out of alignment in NVS.
   - *Fix*: Uses `strsep()` to retain positional mapping for optional empty fields sent by the mobile app.
3. **Stack Exhaustion Prevention (Static Memory Allocation)**:
   - *Problem*: Local parsing buffers inside BLE handlers exceeded the 1024-byte Bluetooth RX workqueue stack.
   - *Fix*: Moved large formatting buffers to `static` RAM, saving >850 bytes of thread stack memory.

---

## 📊 Flash & RAM Optimization Scorecard

The firmware is aggressively optimized for size to fit comfortably alongside **MCUboot** and dual-bank DFU partitions:

| Memory Region | Used Space | Total Capacity | Usage Percentage | Status |
| :--- | :---: | :---: | :---: | :---: |
| **Flash (ROM)** | 253,908 B | 1,024,000 B | **24.79%** | 🟢 Extremely Clean (< 25%) |
| **RAM (SRAM)** | 83,216 B | 262,144 B | **31.74%** | 🟢 Optimal Margin |

### Key Optimization Kconfig Flags in `prj.conf`:
- `CONFIG_SIZE_OPTIMIZATIONS=y` (Enables `-Os` compiler optimizations)
- `CONFIG_CBPRINTF_NANO=y` (Uses lightweight nano-printf formatter)
- `CONFIG_LOG=n` (Disables verbose logging subsystem to save ~1.5 KB critical flash)

---

## 📂 Repository File Structure

```text
Threaded_NC_SP/
├── CMakeLists.txt          # Zephyr build system file & TT_common integration
├── prj.conf                # Optimized Kconfig parameters & device settings
├── sysbuild.conf           # System build configuration (MCUboot enabled)
├── pm_static.yml           # Static memory partition manager layout
├── run_with_ncs.sh         # nRF Connect SDK environment runner script
├── Kconfig                 # Application-specific Kconfig definitions
├── sample.yaml             # Twister test configuration harness
├── README.md               # Detailed technical documentation
└── src/
    ├── app_threads.h       # Thread handles, telemetry message structs, & msgq declarations
    ├── app_threads.c       # Main thread spawners, message queue, & background process
    ├── nurse_call_app.h    # Nurse Call alert state machine headers
    ├── nurse_call_app.c    # Button interrupt handler & alert logic
    ├── spo2_sensor.h       # SpO2 sensor driver headers
    ├── spo2_sensor.c       # Red/IR LED sampling, FFT, & SpO2 algorithm
    ├── temp_sensor.h       # Temperature sensor driver headers
    └── temp_sensor.c       # Thermistor ADC sampling & Beta equation calculation
```

---

## 🛠️ Build & Flash Instructions

### Prerequisites
- **nRF Connect SDK**: `v2.x.x`
- **Toolchain**: GNU Arm Embedded Toolchain
- **Build Tool**: `west` with `sysbuild`

### Building the Firmware
Run the provided environment wrapper script:
```bash
./run_with_ncs.sh west build -p always -b nrf52840dk/nrf52840 --sysbuild
```

### Flashing to Target Board
Connect your nRF52840 Development Kit (`nrf52840dk`) via USB and run:
```bash
./run_with_ncs.sh west flash
```

The output build binary `build/zephyr/merged.hex` contains both **MCUboot Bootloader** and the **Threaded_NC_SP Application**.

---

## 📡 BLE Command Protocol Reference

The device supports Nordic UART Service (NUS) commands for Mobile App control:

| Command | Function | Description |
| :---: | :--- | :--- |
| `m` | Schema Exploration | Returns NVS schema block descriptors for dynamic mobile UI generation. |
| `v\|common` | Verify Configuration | Returns active device parameters formatted as pipe-delimited string. |
| `c\|common\|...` | Commit Configuration | Writes updated device parameters into persistent NVS storage. |
| `s` | Start Measurement | Activates SpO2 optical sampling & temperature polling. |
| `S` | Stop Measurement | Suspends sensor sampling and enters idle state. |
| `A` | Nurse Call Alert | Triggers emergency Nurse Call alert manually over BLE. |
| `C` | Nurse Call Cancel | Resets active Nurse Call alert status. |
| `HIBERNATE` | Low Power Mode | Puts device into deep hibernation mode. |

---

## 🔗 Related Repositories
- **TT_common Repository**: [Tokuchu-Tech-LLP/TT_common](https://github.com/Tokuchu-Tech-LLP/TT_common.git)
- **Mobile Application V2**: [Tokuchu-Tech-LLP/DocuHealth-MobileApp](https://github.com/Tokuchu-Tech-LLP/DocuHealth-MobileApp.git)

---
*Maintained by Anubhav Tripathi for Tokuchu Tech LLP.*
