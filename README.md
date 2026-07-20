# Nurse_Call_SpO2 Firmware (Multithreaded)

Unified Zephyr RTOS application for **Nurse Call** and **SpO2 / Temperature Monitoring Probe** running on Nordic Semiconductor nRF52840.

## Threading Architecture
This firmware replaces sequential delayable workqueues with dedicated Zephyr kernel threads (`k_thread`) communicating via message queues (`k_msgq`) and synchronized with ADC mutex locks:

- **`spo2_thread`**: Continuous/periodic Red & IR hybrid LED ADC sampling, FFT filtering, SpO2 & Heart Rate calculation.
- **`temp_thread`**: Periodic NTC thermistor temperature ADC sampling.
- **`nurse_call_thread`**: Event-driven button input handling, alert generation, debouncing, and LED alert status.
- **`telemetry_tx_thread`**: Asynchronous BLE and OpenThread CoAP JSON telemetry dispatch thread.

## Build Instructions
```bash
west build -b nrf52840dk_nrf52840 --sysbuild
```
