#!/usr/bin/env bash
# Provision the isentinal edge rootfs — runs INSIDE the chroot created by
# make-rootfs.sh. This is the entire recipe for "what the OS is": every
# deviation from a minimal Debian install lives here and nowhere else.
#
#   chroot <rootfs> /mnt/edgeos/scripts/provision.sh
#
# Inputs come in as environment variables (see make-rootfs.sh).

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

HAILORT_VERSION=${HAILORT_VERSION:-4.23.0}
TAPPAS_VERSION=${TAPPAS_VERSION:-5.1.0}
HAILO_APT_REPO=${HAILO_APT_REPO:-http://archive.raspberrypi.com/debian}
HAILO_APT_SUITE=${HAILO_APT_SUITE:-trixie}
MENDER_DEB_URL=${MENDER_DEB_URL:-}
CONFIG_TXT=${CONFIG_TXT:-/boot/firmware/config.txt}

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg gpgv

# --- Hailo package source ---------------------------------------------------
# The Raspberry Pi archive key still carries SHA1 self-signatures, which
# trixie's default sqv verifier rejects (SHA1 cutoff). Point apt's verifier
# at gpgv instead — signatures are still checked, only the deprecation
# policy differs. Remove this when archive.raspberrypi.com re-signs.
printf 'APT::Key::gpgvcommand "/usr/bin/gpgv";\n' > /etc/apt/apt.conf.d/99gpgv-verifier
# hailo-all for Debian 13 is distributed through the Raspberry Pi apt repo
# (that's what the R2145's shipped install pulls). Signed by the RPi archive
# key; if a different Hailo feed is used, set HAILO_APT_REPO/HAILO_APT_SUITE
# and drop in the matching keyring instead.
install -d /usr/share/keyrings
# apt's signed-by wants an OpenPGP keyring — raspberrypi.gpg.key may be
# armored or a keybox, so normalize through gpg import/export.
# GNUPGHOME is scoped to /tmp: callers like `sudo -E` can leak a HOME that
# doesn't exist inside the chroot.
export GNUPGHOME=$(mktemp -d)
curl -fsSL https://archive.raspberrypi.com/debian/raspberrypi.gpg.key \
    -o /tmp/rpi-archive.key
gpg --no-default-keyring --keyring /tmp/rpi-import.gpg --import /tmp/rpi-archive.key
gpg --no-default-keyring --keyring /tmp/rpi-import.gpg --export \
    -o /usr/share/keyrings/raspberrypi-archive-keyring.gpg
rm -rf /tmp/rpi-archive.key /tmp/rpi-import.gpg* "$GNUPGHOME"
cat > /etc/apt/sources.list.d/hailo.list <<EOF
deb [signed-by=/usr/share/keyrings/raspberrypi-archive-keyring.gpg] $HAILO_APT_REPO $HAILO_APT_SUITE main
EOF
apt-get update

# --- kernel + firmware ------------------------------------------------------
# The R2145's shipped install runs the Raspberry Pi vendor kernel — the
# hailort-pcie-driver postinst looks for raspberrypi-kernel-headers
# specifically, and rpivid's stateless HEVC decoder is in that tree anyway.
apt-get install -y --no-install-recommends \
    raspi-firmware \
    linux-image-rpi-2712 linux-headers-rpi-2712

# --- Hailo: host side -------------------------------------------------------
# Kernel module stays on the host (hailo_pci.ko is built against the image's
# kernel by DKMS — needs the headers above plus a compiler). hailort userspace
# is also installed so the host can talk to the device for diagnostics, and so
# the container image can pin to the same version tag.
#
# The driver postinst builds against $(uname -r) — inside a build chroot
# that's the *host's* kernel (CI runner, workstation), not the image's. Two
# shims make it work: point that name at the target kernel's headers so its
# make/dkms resolve correctly, and no-op modprobe for the install (loading
# the just-built module can't succeed in a chroot — a vermagic-mismatched
# insert at best — and `set -e` makes that fatal). dpkg-divert rather than a
# PATH stub, because dpkg sanitizes the maintainer-script environment.
BUILD_KVER=$(uname -r)
RPI_KVER=$(ls /lib/modules | grep 'rpi-2712' | head -1)
mkdir -p "/lib/modules/$BUILD_KVER"
ln -sfn "/lib/modules/$RPI_KVER/build" "/lib/modules/$BUILD_KVER/build"
dpkg-divert --local --rename --divert /usr/sbin/modprobe.dpkg-real /usr/sbin/modprobe
printf '#!/bin/sh\nexit 0\n' > /usr/sbin/modprobe
chmod +x /usr/sbin/modprobe

apt-get install -y --no-install-recommends \
    dkms gcc make \
    "hailort-pcie-driver=$HAILORT_VERSION" "hailort=$HAILORT_VERSION" \
    || { cat /var/log/hailort-pcie-driver.deb.log 2>/dev/null; false; }

# Cleanup: the module the postinst built landed under the build host's
# module dir — drop it and install properly for the image's kernel, then
# put the real modprobe back.
rm -rf "/lib/modules/$BUILD_KVER"
rm -f /usr/sbin/modprobe
dpkg-divert --local --rename --remove /usr/sbin/modprobe
dkms autoinstall -k "$RPI_KVER"

dkms status | tee /root/dkms-status.txt
grep -q hailo /root/dkms-status.txt || {
    echo "hailo PCIe module did not build against the image kernel" >&2
    exit 1
}

# --- runtime + services -----------------------------------------------------
apt-get install -y --no-install-recommends \
    podman fuse-overlayfs \
    chrony nftables \
    sudo

# Mender client — the Debian package name and repo suite for trixie aren't
# settled in Mender's feeds; install the standalone deb, or point
# MENDER_DEB_URL at the current artifact. Absent means the image ships
# without OTA until this is pinned — flagged loudly, not silently.
if [[ -n $MENDER_DEB_URL ]]; then
    curl -fsSL "$MENDER_DEB_URL" -o /tmp/mender-client.deb
    apt-get install -y /tmp/mender-client.deb
    rm /tmp/mender-client.deb
else
    echo "WARN: MENDER_DEB_URL unset — image has no Mender client" >&2
fi

# --- edge service -----------------------------------------------------------
install -D -m644 /mnt/edgeos/systemd/isentinal-edge.container \
    /etc/containers/systemd/isentinal-edge.container

# Recordings live on the USB-bridged M.2 (sda1) — a mount unit keyed to the
# device path; Seeed's carrier exposes it as a generic USB mass-storage node.
mkdir -p /var/recordings
grep -q '/var/recordings' /etc/fstab || cat >> /etc/fstab <<'EOF'
/dev/sda1   /var/recordings   ext4   defaults,noatime   0 2
EOF

# --- PCIe Gen 3 for the Hailo link ------------------------------------------
# CM5 negotiates Gen 2 by default; the card links Gen 3 only when firmware
# says so. x1 width is the board's wiring, not a config failure.
mkdir -p "$(dirname "$CONFIG_TXT")"
touch "$CONFIG_TXT"
sed -i '/^dtparam=pciex1_gen=3/d' "$CONFIG_TXT"
printf 'dtparam=pciex1_gen=3\n' >> "$CONFIG_TXT"

# --- hardening --------------------------------------------------------------
# No sshd by default — console enrolment happens at first boot; a jump host
# over the tower VPN can re-enable it if a site needs hands-on.
systemctl disable ssh.service 2>/dev/null || true
apt-get purge -y unattended-upgrades 2>/dev/null || true

install -D -m644 /mnt/edgeos/config/firewall.nft /etc/nftables.conf
systemctl enable nftables.service

# Appliances should never run anything but UTC; camera footage timestamps
# depend on it.
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo edge > /etc/hostname

# --- cleanliness ------------------------------------------------------------
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/*
# /mnt/edgeos stays — it's a bind mount of the build repo, removed by the
# outer script's unmount trap. Never rm it from in here.
