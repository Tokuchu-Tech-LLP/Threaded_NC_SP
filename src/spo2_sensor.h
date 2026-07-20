#ifndef SPO2_SENSOR_H
#define SPO2_SENSOR_H

#include <zephyr/kernel.h>
#include <stdint.h>

void spo2_init(void);
void spo2_start(void);
void spo2_stop(void);

#endif /* SPO2_SENSOR_H */
