#!/bin/bash
# Installed to /usr/local/sbin/nova-wifi-fix.sh by install.sh, run by nova-wifi-fix.service at boot.
# Retries the rtw88 driver reload until wlan0 comes up, since the RTL8821CS SDIO
# probe can race the bus at boot and time out (-110).
MODULES="rtw88_8821cs rtw88_8821c rtw88_sdio rtw88_core"
MAX_TRIES=5

for i in $(seq 1 "$MAX_TRIES"); do
    if ip link show wlan0 >/dev/null 2>&1; then
        echo "wlan0 already present after $((i - 1)) reload(s)"
        break
    fi

    echo "Attempt $i/$MAX_TRIES: reloading $MODULES"
    modprobe -r $MODULES 2>/dev/null
    sleep 1
    modprobe rtw88_8821cs
    sleep 3
done

IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | head -1)
if [ -n "$IFACE" ]; then
    echo "Disabling power_save on $IFACE"
    iw dev "$IFACE" set power_save off
else
    echo "WARN: no wireless interface found after $MAX_TRIES reload attempts"
fi
