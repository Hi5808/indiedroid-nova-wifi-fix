# Armbian build for Indiedroid Nova (DDR/DMC DVFS fix)

The stock OEM/ameriDroid image ships a bootloader with no DDR/DMC frequency scaling —
`/sys/class/devfreq/dmc` doesn't exist, `dmesg` shows no relevant error, DDR just runs
at whatever fixed frequency U-Boot/TF-A set at boot and never adjusts. This matters a lot
for anything memory-bandwidth-bound (NPU inference, heavy compute) since the NPU core
can already be maxed out while DDR bandwidth is the actual bottleneck.

Armbian's own `indiedroid-nova` board config (`armbian/build` →
`config/boards/indiedroid-nova.csc`) already carries a validated fix: a specific
`BL31`/DDR-training-blob pair (`rk3588_bl31_v1.38.elf` +
`rk3588_ddr_lp4_2112MHz_lp5_2736MHz_v1.11.bin`) that enables real DDR DVFS.

## Building

```bash
git clone https://github.com/armbian/build.git
cd build
unset DOCKER_HOST   # if docker CLI is misdirected to a podman/other socket
./compile.sh build BOARD=indiedroid-nova BRANCH=vendor RELEASE=resolute \
  BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=gnome DESKTOP_ENVIRONMENT_CONFIG_NAME=config_base \
  DESKTOP_TIER=mid COMPRESS_OUTPUTIMAGE=sha,xz KERNEL_CONFIGURE=no
```

Notes on flags that aren't obvious from Armbian's docs:
- Do **not** pass `docker` as a positional argument (`./compile.sh docker ...`) — modern
  Armbian auto-detects Docker; passing it explicitly causes a "asking for docker...
  inside docker" error once it relaunches itself in the container.
- `KERNEL_CONFIGURE=no` and `DESKTOP_TIER=<minimal|mid|full>` are both required for a
  non-interactive/background build — without them the build blocks on a dialog menu that
  can't render (`stdin is not a terminal`) and silently hangs/fails.
- **Use `BRANCH=vendor`, not `BRANCH=current`.** The mainline-ish `current` kernel
  (6.18.x at time of writing) built and flashed fine but produced **zero display output**
  on both the DisplayPort and HDMI outputs — this board's display driver support on that
  kernel branch just isn't there yet (Nova is CSC/community-tier in Armbian, less vetted
  than official boards). `BRANCH=vendor` (6.1.115) has working display and is what
  actually got used.

## What works vs. what's still broken on this Armbian build

**Working:**
- DDR/DMC DVFS — the whole point. Confirmed: `/sys/class/devfreq/dmc` exists,
  `governor: dmc_ondemand`, `available_frequencies: 528000000 1068000000 1560000000
  2112000000`, no `trusted firmware unsupported` error anywhere in `dmesg`.
- WiFi — same `-110` SDIO boot-race as the OEM image (Armbian doesn't have a fix for
  this either); `nova-wifi-fix.sh`/`.service` in this directory is the same driver-reload
  workaround from the main fix, just re-deployed here.
- Root partition — already grows to fill the eMMC on first boot via Armbian's own
  mechanism (ext4, not btrfs like the OEM image), no separate resize fix needed.
- SSH — enabled by default (socket-activated `ssh.socket`), no separate fix needed.
- GPU, audio (3 sound cards), NPU/VPU device nodes, USB HID, thermal — all confirmed
  working with no regressions vs. the OEM image.

**Not working — Bluetooth:**
Armbian's own board config already includes a Bluetooth fix (clones
`stvhay/rkwifibt`, builds `rtk_hciattach`, wires up `bluetooth-rtl8821cs.service`) — but
as shipped it's broken two ways:
1. **The bundled `rtk_hciattach` binary is compiled for the build host's architecture
   (x86-64), not the ARM target** — a real bug in Armbian's board config, which runs
   `make -C realtek/rtk_hciattach` without cross-compiling. Confirmed via `file
   /usr/bin/rtk_hciattach` showing `x86-64` on the actual board.
2. Swapping in the same known-good 32-bit **armhf** `rtk_hciattach` binary used by the
   main OEM-image fix (see `../tools/rtk_hciattach`) gets past that, and the tool's own
   H5 handshake completes successfully every time (`Init Process finished`) — but **the
   kernel never registers an `hci0` device**, even though `hci_uart`/`btrtl`/H5-protocol
   are all loaded. This is a deeper kernel-build difference from the OEM image (Armbian's
   vendor kernel is `6.1.115-vendor-rk35xx`, a different build than the OEM's
   `6.1.0-1023-rockchip`) — most likely a 32-bit-compat-ioctl handling difference for the
   `TIOCSETD` line-discipline attach, not something fixable by retrying or adjusting the
   userspace tool/script. `nova-bt-fix.sh`/`.service` here reflect the retry-loop attempt
   that was tried and didn't resolve it — kept for reference, not because they work.
   **Not resolved as of this writing; needs actual kernel-level investigation.**

**Not investigated:** locale showed briefly garbled `journalctl` output (Cherokee
`chr_US.utf8` locale, not actual data corruption) in one `systemctl status` call — did
not reproduce on retry, root cause unconfirmed. `chrony` (this image's NTP client — no
`systemd-timesyncd` unit exists here) ships disabled by default; enable with
`systemctl enable --now chrony`.

## Files here

```
nova-wifi-fix.sh / .service   Same WiFi driver-reload fix as the main repo, re-deployed
nova-bt-fix.sh / .service     Attempted BT fix; does NOT currently work (see above)
```
