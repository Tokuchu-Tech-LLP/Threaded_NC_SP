# TokuchuTech Fleet — Standard LED Operation Specification

**Date:** September 9, 2026  
**Applicability:** All devices utilizing `TT_common` (`Threaded_NC_SP`, `Nurse_Call`, `Nurse_Lamp`, `BP_Cuff`, etc.)

---

## 1. Hardware Pin Assignment

| LED Identifier | Logical Role in Code | Typical Hardware Pin | Physical Location | User / Context |
| :--- | :--- | :--- | :--- | :--- |
| **`LIGHT_LED`** | External Panel / Status LED | **`P1.02`** (via board overlay) | **Outside the Mounting Box** | Visible to patient, nurse, and room occupants |
| **`OT_CONNECTION_LED`** | PCB Internal Diagnostic LED | **`P0.05`** | **Inside the Mounting Box** | Visible to technician during lab testing / installation |

---

## 2. LED Behavior & Operational Table

| Operational State | `LIGHT_LED` (Outside Box - P1.02) | `OT_CONNECTION_LED` (Inside Box - P0.05) | Timing & Pattern | User Meaning / Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **1. Bootup / Power-On** | **2 Short Blinks** | **2 Short Blinks** | 200ms ON / 200ms OFF /<br>200ms ON / 200ms OFF | Hardware self-test passed, power applied successfully. |
| **2. Thread Joining / Disconnected** | **Slow Blink** | **Slow Blink** | **Mains Mode:** 1s ON / 1s OFF<br>**Battery Mode:** 40ms flash / 3s OFF | **Warning: Network lost** or attempting to join OpenThread network. |
| **3. BLE Commissioning Window** | **Slow Blink** | **Slow Blink** | **Mains Mode:** 1s ON / 1s OFF<br>**Battery Mode:** 40ms flash / 3s OFF | Device is in BLE setup/configuration mode and advertising. |
| **4. Normal Thread Connected** | **OFF** | **OFF** | Steady OFF | **Quiet bedside operation**: LEDs remain dark so patient sleep is not disturbed. |
| **5. Periodic Heartbeat** | **Single 40ms Pulse** | **OFF** | 40ms ON flash every 30 seconds | Visual confirmation of healthy telemetry transmission to OTBR. |
| **6. Nurse Call Button Pressed** | **Solid ON (1000ms)** | **OFF** | 1000ms ON, then turns OFF | Immediate physical feedback to patient that call has been registered. |
| **7. Cancel Button Pressed** | **Solid ON (1000ms)** | **OFF** | 1000ms ON, then turns OFF | Immediate physical feedback that call has been cleared. |

---

## 3. Button Pulse & Background Blink Coordination

When the Call or Cancel button is pressed while the device is in BLE mode or Thread disconnected state (slow blinking active):

```
Time --------------------------------------------------------->
Background Blink: [ ON ] [ OFF ] |==== PAUSED ====| [ ON ] [ OFF ]
LIGHT_LED:                        |--- 1000ms ON --|  OFF
OT_CONNECTION_LED:                |--- FORCED OFF -|  OFF
                                  0ms            1200ms
```

1. **`LIGHT_LED`** turns ON for **1000ms**.
2. **`OT_CONNECTION_LED`** is explicitly turned **OFF** to avoid freezing ON.
3. The background blinking workqueue is **paused** during the pulse.
4. After **1200ms** (pulse + 200ms buffer), background blinking automatically resumes without freezing or locking up.
