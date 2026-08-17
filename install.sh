#!/bin/bash
# Complete WiFi/Bluetooth fix for the Indiedroid Nova (RTL8821CS SDIO -110 errors).
# Run ON THE NOVA as root: sudo bash install.sh
#
# What this does:
#   1. Installs RTL8821CS WiFi + Bluetooth firmware to /lib/firmware (backs up existing files first)
#   2. Installs firmware-realtek, wpasupplicant, wireless-regdb from bundled .deb files (offline)
#   3. Installs a systemd service that reloads the rtw88 driver stack at boot and disables
#      WiFi power-save, working around a driver init race against the SDIO bus (see README.md)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FW_DIR="/lib/firmware"
BACKUP_DIR="/lib/firmware/nova-wifi-fix-backup-$(date +%Y%m%d%H%M%S)"
LOG="$SCRIPT_DIR/install.log"

exec > >(tee -a "$LOG") 2>&1
echo "===== install.sh run: $(date -Is) ====="
trap 'echo "FAILED at line $LINENO (exit $?) - see $LOG" >&2' ERR

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must be run as root (sudo bash install.sh)" >&2
    exit 1
fi

echo "Kernel: $(uname -a)"
cat /proc/device-tree/model 2>/dev/null || true
echo

echo "--- Step 1: Firmware ---"
mkdir -p "$BACKUP_DIR/rtw88" "$BACKUP_DIR/rtl_bt"
for f in rtw88/rtw8821c_fw.bin rtl_bt/rtl8821c_fw.bin rtl_bt/rtl8821c_config.bin; do
    if [ -f "$FW_DIR/$f" ]; then
        echo "Backing up existing $FW_DIR/$f -> $BACKUP_DIR/$f"
        cp -a "$FW_DIR/$f" "$BACKUP_DIR/$f"
    fi
done
mkdir -p "$FW_DIR/rtw88" "$FW_DIR/rtl_bt"
install -m 0644 "$SCRIPT_DIR/firmware/rtw88/rtw8821c_fw.bin"      "$FW_DIR/rtw88/rtw8821c_fw.bin"
install -m 0644 "$SCRIPT_DIR/firmware/rtl_bt/rtl8821c_fw.bin"     "$FW_DIR/rtl_bt/rtl8821c_fw.bin"
install -m 0644 "$SCRIPT_DIR/firmware/rtl_bt/rtl8821c_config.bin" "$FW_DIR/rtl_bt/rtl8821c_config.bin"

echo
echo "--- Step 2: Packages (offline install from bundled debs) ---"
dpkg -i "$SCRIPT_DIR"/debs/*.deb || {
    echo "dpkg reported missing deps, attempting apt --fix-broken (needs internet)..."
    apt-get install -f -y || echo "WARN: could not auto-fix deps."
}

echo
echo "--- Step 3: systemd boot-time driver reload service ---"
install -m 0755 "$SCRIPT_DIR/systemd/nova-wifi-fix.sh" /usr/local/sbin/nova-wifi-fix.sh
install -m 0644 "$SCRIPT_DIR/systemd/nova-wifi-fix.service" /etc/systemd/system/nova-wifi-fix.service

if [ -d /run/systemd/system ]; then
    # Running on a live, booted system: use systemctl normally.
    systemctl daemon-reload
    systemctl enable --now nova-wifi-fix.service
else
    # Running inside a chroot (e.g. baking this into an image) with no systemd PID 1:
    # enable the unit by hand instead of calling systemctl.
    echo "No running systemd detected (chroot build) - enabling unit via symlink instead of systemctl."
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/nova-wifi-fix.service /etc/systemd/system/multi-user.target.wants/nova-wifi-fix.service
fi

echo
echo "--- Result ---"
systemctl status nova-wifi-fix.service --no-pager 2>/dev/null || echo "(systemctl unavailable here - unit is installed and enabled, will run on next real boot)"
echo
timeout 3 nmcli device 2>&1 || echo "(nmcli unavailable/no live NetworkManager here - expected in a chroot build)"

echo
echo "Done. Previous firmware (if any) backed up to: $BACKUP_DIR"
echo "The fix now runs automatically on every boot via nova-wifi-fix.service."
echo "Full log: $LOG"
echo "===== end run: $(date -Is) ====="
