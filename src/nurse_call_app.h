#ifndef NURSE_CALL_APP_H
#define NURSE_CALL_APP_H

#include <zephyr/kernel.h>
#include <stdbool.h>
#include <stdint.h>

void nurse_call_init(void);
void nurse_call_process_loop(void);
void trigger_nurse_call_alert_local(uint8_t alert_id);
void cancel_nurse_call_alert_local(uint8_t alert_id);
bool is_nurse_call_active(void);

#endif /* NURSE_CALL_APP_H */
