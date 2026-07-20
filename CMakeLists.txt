cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})

project(nurse_call_spo2)

# NORDIC SDK APP START
set(TT_DEVICE_TYPE "NURSE_CALL_SPO2")
include(../TT_common/tt_common.cmake)

target_sources(app PRIVATE
    src/app_threads.c
    src/spo2_sensor.c
    src/temp_sensor.c
    src/nurse_call_app.c
    ../TT_common/adc_utils.c
)
# NORDIC SDK APP END
