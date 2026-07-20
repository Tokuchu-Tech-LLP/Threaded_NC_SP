#!/bin/bash
TC_ROOT="/home/anubhavtripathi/ncs/toolchains/7cbc0036f4"

export PATH="$TC_ROOT/bin:$TC_ROOT/usr/bin:$TC_ROOT/usr/local/bin:$TC_ROOT/opt/bin:$TC_ROOT/opt/nanopb/generator-bin:$TC_ROOT/opt/zephyr-sdk/arm-zephyr-eabi/bin:$TC_ROOT/opt/zephyr-sdk/riscv64-zephyr-elf/bin:$PATH"
export LD_LIBRARY_PATH="$TC_ROOT/lib:$TC_ROOT/lib/x86_64-linux-gnu:$TC_ROOT/usr/local/lib:$LD_LIBRARY_PATH"
export GIT_EXEC_PATH="$TC_ROOT/usr/local/libexec/git-core"
export GIT_TEMPLATE_DIR="$TC_ROOT/usr/local/share/git-core/templates"
export PYTHONHOME="$TC_ROOT/usr/local"
export PYTHONPATH="$TC_ROOT/usr/local/lib/python3.12:$TC_ROOT/usr/local/lib/python3.12/site-packages"
export ZEPHYR_TOOLCHAIN_VARIANT="zephyr"
export ZEPHYR_SDK_INSTALL_DIR="$TC_ROOT/opt/zephyr-sdk"
export ZEPHYR_BASE="/home/anubhavtripathi/ncs/v3.0.2/zephyr"

exec "$@"
