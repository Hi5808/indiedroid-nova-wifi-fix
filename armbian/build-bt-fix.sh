#!/bin/bash
# Builds and installs rtk_hciattach natively on the target board (Armbian only —
# this image has a full build toolchain by default since it's a desktop build).
#
# Armbian's own board config bundles a prebuilt rtk_hciattach, but it's compiled
# on the x86_64 build host without cross-compiling, so it ships as an x86-64
# binary that can't run on the ARM board at all ("Exec format error"). Building
# it natively here, on the actual target architecture, is the fix — no
# architecture/libc-multiarch workarounds needed, and it turned out to be the
# ONLY thing actually broken; a 32-bit armhf prebuilt binary (the same one used
# by the main OEM-image fix) attaches and reports success at every step but the
# kernel never registers hci0 — a subtle 32-bit/64-bit compat-ioctl mismatch,
# not a real protocol failure. The native aarch64 build has none of that.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR=$(mktemp -d)

echo "Cloning stvhay/rkwifibt..."
git clone https://github.com/stvhay/rkwifibt "$BUILD_DIR/rkwifibt"

echo "Building rtk_hciattach natively for $(uname -m)..."
make -C "$BUILD_DIR/rkwifibt/realtek/rtk_hciattach" clean
make -C "$BUILD_DIR/rkwifibt/realtek/rtk_hciattach"
file "$BUILD_DIR/rkwifibt/realtek/rtk_hciattach/rtk_hciattach"

echo "Installing..."
install -m 0755 "$BUILD_DIR/rkwifibt/realtek/rtk_hciattach/rtk_hciattach" /usr/local/sbin/rtk_hciattach

install -m 0755 "$SCRIPT_DIR/nova-bt-fix.sh" /usr/local/sbin/nova-bt-fix.sh
install -m 0644 "$SCRIPT_DIR/nova-bt-fix.service" /etc/systemd/system/nova-bt-fix.service
systemctl daemon-reload
systemctl enable --now nova-bt-fix.service

rm -rf "$BUILD_DIR"

sleep 8
echo "--- Result ---"
systemctl status nova-bt-fix.service --no-pager || true
echo
hciconfig -a 2>&1 || true
echo
echo "Done. Bluetooth should show 'UP RUNNING' above. If it shows DOWN, run:"
echo "  sudo hciconfig hci0 up"
echo "  bluetoothctl power on"
