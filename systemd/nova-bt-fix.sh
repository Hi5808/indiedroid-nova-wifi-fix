#!/bin/bash
# Attaches the RTL8821CS Bluetooth controller over its UART using Realtek's
# vendor rtk_hciattach tool. Generic bluez hciattach/btattach cannot bring up
# this chip: it lacks the extra low-level handshake Realtek's tool performs
# before the standard H5 (three-wire) sync, so the chip never responds and
# hci0 never appears. Runs in the foreground attached to the UART, so this
# script itself IS the long-running process (systemd unit uses Type=simple).
set -e

TOOL=/usr/local/sbin/rtk_hciattach
TTY=/dev/ttyS9

exec "$TOOL" -n -s 115200 "$TTY" rtk_h5
