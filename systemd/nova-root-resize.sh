#!/bin/bash
# Grows the root partition + btrfs filesystem to fill the eMMC.
# The official Indiedroid Nova image ships with a fixed ~3.5GB root partition
# that does NOT auto-expand on first boot, leaving most of the eMMC unused
# and the root filesystem chronically near-full. Idempotent: safe to run
# every boot, no-ops once already at full size.
set -e

ROOT_SRC=$(findmnt -no SOURCE /)
PART_NUM=$(echo "$ROOT_SRC" | grep -oE '[0-9]+$')
DISK="/dev/$(lsblk -no pkname "$ROOT_SRC")"

echo "Root device: $ROOT_SRC (disk=$DISK, partition=$PART_NUM)"

echo "Growing partition $PART_NUM on $DISK to fill the disk..."
parted -s "$DISK" resizepart "$PART_NUM" 100% || echo "resizepart: no-op (already at max, or nothing to grow)"
partprobe "$DISK" 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 1

echo "Growing btrfs filesystem on / to fill the partition..."
btrfs filesystem resize max / || echo "btrfs resize: no-op (already at max)"

df -h /
