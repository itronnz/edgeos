#!/usr/bin/env bash
# Build a minimal Debian arm64 rootfs and provision it for isentinal edge.
#
# Host-side script: runs debootstrap, mounts the pseudo-filesystems the
# chroot needs, bind-mounts this repo in so provision.sh can read the
# shipped config (quadlet, nftables rules), runs it inside the chroot,
# then unmounts and leaves a rootfs directory ready for make-image.sh.
#
#   sudo scripts/make-rootfs.sh <rootfs-dir>
#
# On an arm64 host the chroot runs natively. On x86 the same script works
# through qemu-aarch64-static (binfmt_misc) — just slower. Everything that
# differs between hosts is a variable below.

set -euo pipefail

ROOTFS=${1:?usage: make-rootfs.sh <rootfs-dir>}
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SUITE=${SUITE:-trixie}
ARCH=${ARCH:-arm64}
MIRROR=${MIRROR:-https://deb.debian.org/debian}

if [[ $EUID -ne 0 ]]; then
    echo "needs root (debootstrap + chroot mounts)" >&2
    exit 1
fi

mkdir -p "$ROOTFS" "$ROOTFS/mnt/edgeos"
debootstrap --arch="$ARCH" --variant=minbase "$SUITE" "$ROOTFS" "$MIRROR"

# If the chroot can't execute on this host, copy qemu-aarch64-static in so
# provision.sh still runs (x86 CI fallback path).
if [[ "$(uname -m)" != aarch64* ]] && [[ "$ARCH" == arm64 ]]; then
    install -D "$(command -v qemu-aarch64-static)" "$ROOTFS/usr/bin/qemu-aarch64-static"
fi

mount --bind "$REPO_DIR" "$ROOTFS/mnt/edgeos"
for fs in proc sys dev dev/pts run; do
    mount --bind "/$fs" "$ROOTFS/$fs"
done
trap 'umount -R "$ROOTFS/mnt/edgeos" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev/pts" "$ROOTFS/dev" "$ROOTFS/run" 2>/dev/null || true' EXIT

env \
    HAILORT_VERSION="${HAILORT_VERSION:-4.23.0}" \
    TAPPAS_VERSION="${TAPPAS_VERSION:-5.1.0}" \
    HAILO_APT_REPO="${HAILO_APT_REPO:-http://archive.raspberrypi.com/debian}" \
    HAILO_APT_SUITE="${HAILO_APT_SUITE:-trixie}" \
    chroot "$ROOTFS" /bin/bash /mnt/edgeos/scripts/provision.sh
