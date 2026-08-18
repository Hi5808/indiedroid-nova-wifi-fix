#!/bin/bash
# Dumps the Indiedroid Nova's entire eMMC to a compressed, directly-flashable
# backup image. Run on the HOST laptop (needs rkdeveloptool), with the board
# in maskrom mode and connected via USB-C.
#
# Usage:
#   sudo bash backup-emmc.sh [output-name]
#
# Restore later with the same maskrom + rkdeveloptool flow used to flash any
# other image in this repo:
#   sudo rkdeveloptool db rk3588_spl_loader_v1.16.113.bin
#   sudo rkdeveloptool wl 0 <output-name>.img
#   sudo rkdeveloptool rd
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root (sudo bash backup-emmc.sh)" >&2
    exit 1
fi

OUT="${1:-nova-backup-$(date +%Y%m%d%H%M%S)}"
IMG="${OUT}.img"

echo "--- Checking device is in maskrom/loader mode ---"
rkdeveloptool ld

echo
echo "--- Reading eMMC size ---"
RFI_OUT=$(rkdeveloptool rfi)
echo "$RFI_OUT"
SECTORS=$(echo "$RFI_OUT" | grep -oP 'Flash Size:\s*\K[0-9]+(?=\s*Sectors)')
if [ -z "$SECTORS" ]; then
    echo "Could not parse sector count from 'rkdeveloptool rfi' output above." >&2
    echo "Pass the byte count manually: rkdeveloptool read 0 <bytes> $IMG" >&2
    exit 1
fi
BYTES=$((SECTORS * 512))
echo "eMMC size: $SECTORS sectors = $BYTES bytes ($((BYTES / 1024 / 1024 / 1024)) GB)"

echo
echo "--- Reading full eMMC to $IMG (this takes a while) ---"
rkdeveloptool read 0 "$BYTES" "$IMG"

echo
echo "--- Verifying read size ---"
ACTUAL=$(stat -c%s "$IMG")
if [ "$ACTUAL" != "$BYTES" ]; then
    echo "WARNING: expected $BYTES bytes, got $ACTUAL bytes — read may be incomplete." >&2
fi

echo
echo "--- Compressing (this also takes a while; empty space compresses very well) ---"
xz -T0 -6 -v "$IMG"

echo
echo "--- Checksumming ---"
sha256sum "${IMG}.xz" | tee "${IMG}.xz.sha256"

echo
echo "Done: ${IMG}.xz"
echo "Restore with:"
echo "  xz -d ${IMG}.xz"
echo "  sudo rkdeveloptool db rk3588_spl_loader_v1.16.113.bin"
echo "  sudo rkdeveloptool wl 0 ${IMG}"
echo "  sudo rkdeveloptool rd"
