# Indiedroid Nova WiFi/Bluetooth Fix

Fixes the RTL8821CS WiFi/Bluetooth chip failing to initialize on the
[Indiedroid Nova](https://indiedroid.us/) (RK3588S), which shows up in `dmesg` as:

```
rtw_8821cs mmc2:0001:1: sdio read32 failed (0x11080): -110
rtw_8821cs mmc2:0001:1: sdio write32 failed (0x11080): -110
...
rtw_8821cs mmc2:0001:1: failed to download firmware
rtw_8821cs: probe of mmc2:0001:1 failed with error -110
```

Confirmed on the official Indiedroid/ameriDroid Debian 12 (Bookworm/GNOME) image
and on Ubuntu-Rockchip 24.04, both on kernel `6.1.0-1023-rockchip`.

## Root cause

Two independent, compounding issues:

1. **Marginal power supply.** The RK3588S can brown out downstream USB/SDIO rails
   under load on an underpowered or low-quality supply, causing SDIO bus timeouts
   (`-110` = `ETIMEDOUT`) exactly like the ones above. A proper **5V/3A+** supply
   (e.g. a Raspberry Pi 5 official PSU) resolves this component of the issue.
2. **A driver init race.** Even on good power, the `rtw88_8821cs` kernel driver can
   probe before the SDIO bus is fully ready, causing a one-time failed probe at
   boot. Unloading and reloading the driver stack after boot reliably recovers it.

This was independently confirmed and debugged in
[ameriDroid/images#2](https://github.com/ameriDroid/images/issues/2).

## What this fix does

`install.sh` (run on the Nova, as root):

1. Installs the correct RTL8821CS WiFi + Bluetooth firmware to `/lib/firmware`
   (backs up any existing files first).
2. Installs `firmware-realtek`, `wpasupplicant`, `wireless-regdb`, and `parted`
   from the bundled `.deb` files in `debs/` — works fully offline, no network
   required.
3. Installs and enables `nova-wifi-fix.service`, a systemd oneshot service that
   runs at every boot, reloads the `rtw88` driver stack (retrying up to 5 times
   until `wlan0` comes up) to clear the init race, and disables WiFi power-saving
   to avoid a secondary "failed to ack driver for entering Deep Power mode" crash
   some users hit under NetworkManager.
4. Installs and enables `nova-root-resize.service`, a systemd oneshot service that
   grows the root partition and btrfs filesystem to fill the eMMC. **The stock
   image ships a fixed ~3.5GB root partition that never auto-expands**, so on a
   58GB eMMC the root filesystem stays chronically near-full — a single
   `apt upgrade` (which can easily pull several hundred MB of packages plus a
   kernel/initramfs regen) is enough to fill it and corrupt the boot chain,
   producing a completely blank display on next boot with no obvious cause.
   This service is idempotent and safe to run on every boot.
5. Installs and enables `openssh-server`. The stock image has no SSH access out
   of the box, which is a pain when the board has no display/keyboard handy or
   you're debugging over a USB-sneakernet workflow before WiFi is even up.

## Usage

Get this whole directory onto the Nova (network, or sneakernet via USB drive if
the Nova has no working network yet), then:

```bash
sudo bash install.sh
```

Everything logs to `install.log` next to the script.

## You should still fix your power supply

The systemd service works around the driver race on every boot, but it can't fix
a genuinely marginal power supply. If you still see WiFi drop out intermittently
(especially under load, e.g. large transfers or resuming from idle), swap to a
proper 5V/3A+ supply before assuming it's a driver/software problem — that was the
deciding factor in the reference report linked above.

## Contents

```
install.sh                          top-level installer
firmware/rtw88/rtw8821c_fw.bin      WiFi firmware
firmware/rtl_bt/rtl8821c_fw.bin     Bluetooth firmware
firmware/rtl_bt/rtl8821c_config.bin Bluetooth config
debs/*.deb                          offline packages (arm64/all, Debian 12 bookworm)
systemd/nova-wifi-fix.service       WiFi boot-time systemd unit
systemd/nova-wifi-fix.sh            the reload/power-save script it runs
systemd/nova-root-resize.service    root-grow boot-time systemd unit
systemd/nova-root-resize.sh         the partition/filesystem grow script it runs
```

## Uninstall

```bash
sudo systemctl disable --now nova-wifi-fix.service
sudo rm /etc/systemd/system/nova-wifi-fix.service /usr/local/sbin/nova-wifi-fix.sh
sudo systemctl daemon-reload
```

Firmware files installed to `/lib/firmware` are left in place (harmless if unused);
restore your originals from the `nova-wifi-fix-backup-*` directory under
`/lib/firmware` created by `install.sh` if needed.
