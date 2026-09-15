# edgeos

Base OS image for the isentinal edge appliance (Seeed reComputer AI
Industrial R2145-12 / CM5-class). Minimal Debian 13 (trixie), hardened, with
a Hailo-8 PCIe driver and a Podman quadlet that runs `isentinal-edge` — plus
Mender client plumbing for A/B rootfs updates.

This repo builds **the OS**, not the application: the edge container image
lives in `itronnz/isentinal`; this repo produces the eMMC `.img` it boots
from and the `.mender` artifact that updates it. Public because nothing
secret or site-specific ever belongs in the image — enrolment tokens,
registry credentials, and the Mender server URL all enter at first boot or
via CI secrets, never the tree. The public repo is also what gives CI a free
native arm64 runner.

## What the image carries

- `hailort-pcie-driver` + `hailort` 4.23.0 — the kernel module must live on
  the host and match the userspace in the container (`...-hailort4.23` tag).
- `podman` + `systemd/isentinal-edge.container` quadlet (host networking —
  ONVIF WS-Discovery is multicast and WebRTC uses UDP port ranges —
  `/dev/hailo0` and the rpivid `/dev/video*` nodes passed through).
- `dtparam=pciex1_gen=3` in `/boot/firmware/config.txt` so the Hailo link
  negotiates Gen 3 (`LnkSta: Speed 8GT/s, Width x1 (downgraded)` — the x1 is
  the board's wiring, not a failure).
- `/var/recordings` on the USB-bridged M.2 SSD (`/dev/sda1`, ext4) — the
  PCIe Gen 3 setting only concerns the Hailo link; the SSD's ceiling is USB.
- chrony (UTC only), nftables firewall (API + go2rtc in, everything else
  out), no sshd, no unattended-upgrades — updates arrive as Mender
  artifacts, not apt.

## Layout

```
scripts/make-rootfs.sh   debootstrap + chroot provision (host side)
scripts/provision.sh     everything the OS is, inside the chroot
scripts/make-image.sh    rootfs -> partitioned .img (boot vfat + rootfs ext4)
systemd/                 the quadlet
config/                  nftables ruleset
.github/workflows/       CI: rootfs -> image -> mender-convert -> artifacts
```

## Build

CI (`build-image.yml`): `ubuntu-24.04-arm` → make-rootfs → make-image →
`mender-convert` → `.img` + `.mender` as artifacts; `publish_mender` pushes
the artifact to the self-hosted Mender server (`MENDER_SERVER_URL` /
`MENDER_JWT` secrets).

Locally, on an arm64 host or with `qemu-aarch64-static` + binfmt:

```sh
sudo scripts/make-rootfs.sh build/rootfs
sudo scripts/make-image.sh build/rootfs build/edgeos-trixie-arm64.img
# then mender-convert for the A/B layout (configs/mender/cm5_config is ours):
docker run --rm --privileged \
    -e MENDER_ARTIFACT_NAME="edgeos-local" \
    -v $PWD/build:/build \
    -v $PWD/out:/mender-convert/output \
    -v $PWD/configs/mender:/mender-convert/configs/edgeos \
    mendersoftware/mender-convert:latest \
    --disk-image /build/edgeos-trixie-arm64.img \
    --config configs/edgeos/cm5_config
```

## Flash

CM5: `sudo rpiboot`, then `dd` the converted image to the eMMC block device.
Per-unit identity (hostname suffix, Mender device keypair) is generated at
first boot — one generic image flashes every tower.

## Verify a fresh unit

```sh
lspci -vv -s 0001:01:00.0 | grep LnkSta   # Speed 8GT/s
ls /dev/hailo0 /dev/video*
lsblk                                     # sda1 mounted on /var/recordings
systemctl status isentinal-edge
curl localhost:8080/api/resources
mender-device show-provides               # once enrolled
```

## Still to prove on hardware

- The U-Boot A/B failover on a real CM5 — mender-convert now runs
  end-to-end (`configs/mender/cm5_config`, an rpi64 U-Boot bundle, and
  the Pi firmware booting `kernel8.img` = u-boot.bin), but whether that
  U-Boot build loads our vmlinux + rolls back correctly on this exact
  image is only proven by flashing one.
- Whether `bcm2712-rpi-cm5-cm5io.dtb` (or another of the shipped 2712
  dtbs) describes the R2145's carrier exactly — Seeed's own image may
  carry a carrier-specific overlay we don't know about yet.
- The `+rpt1` package variants the RPi repo substitutes for Debian's
  (glibc among them) — expected on RPi OS, worth a glance that nothing
  else needs pinning.
