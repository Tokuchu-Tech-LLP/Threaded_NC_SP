#ifndef TEMP_SENSOR_H
#define TEMP_SENSOR_H

#include <zephyr/kernel.h>
#include <stdint.h>

void temp_init(void);
void temp_start(void);
void temp_stop(void);

#endif /* TEMP_SENSOR_H */
