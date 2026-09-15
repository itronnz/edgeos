#!/usr/bin/env bash
# Turn a provisioned rootfs into a partitioned disk image: FAT32 boot +
# ext4 rootfs — the layout mender-convert expects as input.
#
#   sudo scripts/make-image.sh <rootfs-dir> <output.img>
#
# The image is deliberately boot+root only; mender-convert re-partitions it
# into boot + rootfs-A + rootfs-B + data on output.

set -euo pipefail

ROOTFS=${1:?usage: make-image.sh <rootfs-dir> <output.img>}
IMG=${2:?usage: make-image.sh <rootfs-dir> <output.img>}
BOOT_MB=${BOOT_MB:-256}
ROOTFS_MB=${ROOTFS_MB:-2048}   # must exceed the provisioned rootfs by ~20%

if [[ $EUID -ne 0 ]]; then
    echo "needs root (loop devices + mounts)" >&2
    exit 1
fi

IMG_MB=$((BOOT_MB + ROOTFS_MB + 16))
dd if=/dev/zero of="$IMG" bs=1M count="$IMG_MB" status=none

parted -s "$IMG" -- \
    mklabel msdos \
    mkpart primary fat32 1MiB $((1 + BOOT_MB))MiB \
    mkpart primary ext4 $((1 + BOOT_MB))MiB $((IMG_MB - 1))MiB

LOOP=$(losetup --show -fP "$IMG")
trap 'losetup -d "$LOOP" 2>/dev/null || true' EXIT

mkfs.vfat -n BOOT "${LOOP}p1"
mkfs.ext4 -L rootfs "${LOOP}p2"

MNT=$(mktemp -d)
trap 'umount -R "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true' EXIT

mount "${LOOP}p2" "$MNT"
mkdir -p "$MNT/boot/firmware"
mount "${LOOP}p1" "$MNT/boot/firmware"

cp -a "$ROOTFS"/. "$MNT"/

sync
umount -R "$MNT"
losetup -d "$LOOP"
trap - EXIT

echo "built $IMG (${IMG_MB}MiB): boot=fat32 ${BOOT_MB}MiB, rootfs=ext4 ${ROOTFS_MB}MiB"
