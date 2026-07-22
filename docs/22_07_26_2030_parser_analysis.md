# Parser Fragment Assembly — Root Cause Analysis & Protocol Audit
Timestamp: 23-07-26 02:44

## 1. Mobile App Protocol Analysis

From `ble_admin_service.dart` in `MobileApplicationV2`, the mobile app sends commands via two distinct paths:

### Path A: `_sendForSingleResponse()` — Appends `\n`

At line 800 of `ble_admin_service.dart`:
```dart
final toSend = command.endsWith('\n') ? command : '$command\n';
```

Guarantees a `\n` terminator. Used by:
- Config request (`c\n`)
- Password (`p|e4a\n`)
- Config read (`r|common\n`)
- Config write (`c|common|heartbeat_time=600\n`)
- Save (`s|common\n`)
- Factory reset (`f\n`)
- Reboot (`R\n`)

### Path B: Direct `writeData()` — NO `\n` Appended

Direct calls without newline termination:
- Verify (`v|spo2`)
- Schema request (`m|common`)
- Measure stop (`X`)
- Measure start (`S`)
- Diagnostic toggle (`DIAG_ON` / `DIAG_OFF`)

---

## 2. Firmware Parser Evaluation

### Original SP Parser (`SpO2_probe/src/tt_ble_handler.c`)
- **Stateless**: Copies incoming BLE write payload to buffer, null terminates, strips trailing `\r`/`\n` if present, and dispatches directly on `cmd[0]`.
- Handles both `\n` terminated and raw non-`\n` single-packet commands cleanly.
- Simple (25 lines of logic), zero timeout state machines.

### Threaded Parser (Experimental)
- Maintained a 3000ms stateful fragment buffer (`parser_cmd`, `parser_cmd_len`).
- When a user paused for >3 seconds between commands in the mobile app, the timer fired falsely, emitting:
  `<wrn> ble_cmd: BLE command fragment timeout (>3000ms) — resetting RX buffer`
- Unnecessary because all mobile configurator commands (1 to 35 bytes) fit inside a single BLE write packet (80-byte MTU payload cap).

---

## 3. Decision

Reverted to the original SP stateless parser. This matches production fleet behavior (`spo2`, `nurse_lamp`, `nurse_call`, `bp_cuff`, `ir_blaster`), eliminates misleading timeout warnings, and handles all mobile app commands cleanly.
