#!/bin/bash
# Attaches RTL8821CS Bluetooth via rtk_hciattach, retrying until hci0 comes up
# (the tool can exit right after setup on some boots without leaving hci0
# registered — retry rather than relying on a single fixed-delay attempt).
TTY=/dev/ttyS9
MAX_TRIES=5

echo 0 > /sys/class/rfkill/rfkill0/state 2>/dev/null || true
sleep 1
echo 1 > /sys/class/rfkill/rfkill0/state 2>/dev/null || true
sleep 2

for i in $(seq 1 "$MAX_TRIES"); do
    if hciconfig hci0 >/dev/null 2>&1; then
        echo "hci0 already present after $((i - 1)) attempt(s)"
        break
    fi
    echo "Attempt $i/$MAX_TRIES: attaching via rtk_hciattach"
    pkill -f rtk_hciattach 2>/dev/null || true
    sleep 1
    /usr/bin/rtk_hciattach -n -s 115200 "$TTY" rtk_h5 &
    sleep 6
done

hciconfig hci0 up 2>&1 || echo "WARN: hciconfig hci0 up failed after $MAX_TRIES attempts"
wait
