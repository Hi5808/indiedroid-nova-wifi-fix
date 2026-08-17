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

**Not working — Bluetooth.** Traced through several layers; documenting the full evidence
chain here since it's a real starting point for whoever picks this up next.

### Layer 1: Armbian's own bundled fix is broken (two bugs)

Armbian's board config already includes a Bluetooth fix (clones `stvhay/rkwifibt`, builds
`rtk_hciattach`, wires up `bluetooth-rtl8821cs.service`) — but as shipped:

1. **The bundled `rtk_hciattach` binary is compiled for the build host's architecture
   (x86-64), not the ARM target** — a real bug in Armbian's board config, which runs
   `make -C realtek/rtk_hciattach` without cross-compiling. Confirmed via `file
   /usr/bin/rtk_hciattach` showing `x86-64` on the actual board.
2. The stock `bluetooth-rtl8821cs.service` wrapper backgrounds `rtk_hciattach` with `&`
   inside a `Type=oneshot` unit — when the wrapper script exits, systemd tears down the
   whole cgroup and kills the still-initializing backgrounded process before it finishes.
   `nova-bt-fix.sh`/`.service` here fix both: swap in the known-good 32-bit **armhf**
   `rtk_hciattach` binary (`../tools/rtk_hciattach`, needs `dpkg --add-architecture armhf`
   + a matching `libc6:armhf` — **must match this system's actual libc version**; Ubuntu
   26.04 ships glibc 2.43, not Debian's 2.36, and glibc requires identical versions across
   architectures via multiarch, so grab the armhf build from `ports.ubuntu.com` for
   *this* release, not a bundled Debian `.deb`), and use `Type=simple` with a retry loop
   so the process stays the tracked main PID instead of getting torn down.

### Layer 2: the userspace tool "succeeds" but hci0 never appears

With both bugs fixed, `rtk_hciattach`'s own H5 handshake completes every time
(`Init Process finished`, `Device setup complete`) — but **`hci0` never gets created**.
`/sys/class/bluetooth/` stays empty and no `Bluetooth: hci0: ...` line ever appears in
`dmesg`, even though `hci_uart`/`btrtl`/H5-protocol are all loaded and the `TIOCSETD`
ioctl itself returns success (confirmed via `strace`).

Root cause, found by reading `drivers/bluetooth/hci_ldisc.c`:

```c
if (test_bit(HCI_UART_INIT_PENDING, &hu->hdev_flags))
    return 0;   // returns "success" WITHOUT ever calling hci_register_dev()
```

Modern kernels' `hci_uart` H5/RTL driver expects to load Realtek firmware **itself**,
in-kernel, via `btrtl.ko` requesting firmware from `/lib/firmware/rtl_bt/`. When that
in-kernel path activates, registration is deferred (`HCI_UART_INIT_PENDING`) until the
kernel's own firmware handshake completes. `rtk_hciattach` is a **legacy external tool**
that pushes firmware itself over raw H5 packets, entirely bypassing that kernel
mechanism — so the kernel sits waiting forever for a handshake that already happened a
different way, and `hci_register_dev()` never fires. No error, just a silent permanent
stall.

**Also found while chasing this**: don't ever send `rtk_hciattach` a `SIGTERM` while it's
attached — it has a clean-shutdown handler that explicitly reverts `TIOCSETD` back to
`N_TTY` (confirmed via `strace`: `ioctl(3, TIOCSETD, [15])` on attach,
`ioctl(3, TIOCSETD, [0])` right before exit on `SIGTERM`). Any `pkill -f rtk_hciattach`
run against a *working* instance — including as a "cleanup" step at the top of a retry
script — tears the working attach right back down. Costly to learn live over a
flaky SSH link; call this out explicitly for whoever debugs this next.

### Layer 3: switching to the kernel's native path (`btattach`) exposes two more issues

If the kernel wants to own firmware loading, the fix should be to let it — use
`btattach -B /dev/ttyS9 -P 3wire` (bluez's tool, kernel-native H5) instead of the legacy
external tool. This surfaced two further problems:

- **`btattach` itself has a known early-exit bug** (confirmed via
  [a linux-bluetooth mailing list report](https://www.spinics.net/lists/linux-bluetooth/msg72050.html)):
  it checks for the device immediately after attaching, and if that check fails (which it
  does, because registration is async) it closes the fd and exits — aborting the very
  registration it's waiting on. Confirmed here too: `ps aux | grep btattach` shows the
  process already gone moments after "No controller attached" prints. The older
  `hciattach -n` tool doesn't have this bug (`-n` keeps it resident/foreground) — switch
  to that instead.
- **Firmware filename mismatch.** The Realtek `RTL8821CS`-support patch for
  `drivers/bluetooth/btrtl.c` ([spinics.net thread](https://www.spinics.net/lists/linux-bluetooth/msg103381.html))
  adds an `ic_id_table` entry expecting firmware at exactly
  `rtl_bt/rtl8821cs_fw.bin` / `rtl_bt/rtl8821cs_config` (note the **`s`** for the CS
  variant, and the **`.bin`** extension on the firmware file). What Armbian's board hook
  actually installs is `rtl8821cs_fw` / `rtl8821cs_config` (right chip-variant name,
  **no** `.bin` extension) — a naming-convention mismatch between Armbian's
  vendor-tool-oriented install script and what the mainline kernel's chip-ID table
  expects. Fixed by copying to the exact expected names:
  ```bash
  cp /lib/firmware/rtl_bt/rtl8821cs_fw     /lib/firmware/rtl_bt/rtl8821cs_fw.bin
  cp /lib/firmware/rtl_bt/rtl8821cs_config /lib/firmware/rtl_bt/rtl8821cs_config.bin
  ```

### Layer 4: with all of the above fixed, still no response — genuine UART-level issue

Even with `hciattach -n -s 115200 /dev/ttyS9 3wire`, the correct firmware naming, and a
process that stays alive and never gets signaled, the kernel's H5 sync never completes.
Enabled dynamic debug (`echo "module hci_uart +p" > /sys/kernel/debug/dynamic_debug/control`,
same for `btrtl`/`bluetooth`) and watched it retransmit the sync packet every ~100ms
indefinitely (matches `H5_SYNC_TIMEOUT` in `hci_h5.c`) with **zero received response ever
logged**.

Checked the actual UART hardware counters to settle whether this is a driver logging gap
or a real transmission problem:

```bash
cat /proc/tty/driver/serial | grep '^9:'
# 9: uart:16550A mmio:0xFEBC0000 irq:42 tx:23812 rx:271 RTS|CTS|DTR
# ...5 seconds later, mid-attempt...
# 9: uart:16550A mmio:0xFEBC0000 irq:42 tx:24196 rx:271 RTS|CTS|DTR
```

**`tx` climbs continuously (hundreds of bytes per retry cycle) while `rx` stays frozen.**
That `rx:271` is a cumulative total since boot — it came entirely from the earlier
*userspace* `rtk_hciattach` runs (which do get chip responses reliably, in 1-2 sync
resends). Across every single kernel-driven attach attempt tonight, not one additional
byte was ever received. The chip demonstrably can and does respond to *something* — just
never to what the kernel's own `hci_h5` driver transmits.

Since both implementations nominally send the same `{0x01, 0x7e}` H5 sync bytes, the
remaining suspect is a **UART line-configuration difference** the kernel driver sets up
differently from what `rtk_hciattach` configures via `termios` before its first byte goes
out (flow control, parity, or exact timing) — something the chip needs to even recognize
the kernel's transmission as valid framing. This needs either real UART packet-sniffing
hardware, or reading/patching `hci_uart_setup()`/`h5_open()`'s termios configuration in
kernel source and rebuilding to test further. Out of scope for what's achievable through
remote SSH-only debugging.

**Not resolved as of this writing.** Whoever picks this up next: start at Layer 4 (the
earlier three layers are solved and documented above) — the smoking gun is the frozen
`rx` counter despite continuous `tx`.

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
