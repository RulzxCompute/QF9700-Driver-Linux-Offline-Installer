# QF9700 Ubuntu 22.04 Offline Installer

A lightweight, offline-friendly installer and management toolkit for **QF9700 / QF9700-based USB 2.0 10/100M Ethernet adapters** on Ubuntu 22.04.

This project packages the Linux QF9700 driver together with an automated installation workflow, USB device detection, network configuration, diagnostics, and boot persistence -- designed for systems that **may not have an internet connection during installation**.

> Built for old and offline Ubuntu systems where "just `apt install` it" is not exactly an option.

Copy this entire directory to the offline machine with a USB stick, then run `sudo ./install.sh` and the adapter works as Ethernet with permanent network configuration.

> Driver based on upstream <https://github.com/pgquiles/qf9700> (GPLv2, attribution retained, see `driver/qf9700/README.source`). This installer only wraps and patches it so it builds on modern kernels.

---

## Features

* **Offline-first installation**
* Automatic QF9700 USB device detection
* Local driver source and package bundle
* Automatic kernel module build and installation
* Automatic module loading
* Persistent driver loading after reboot
* DHCP configuration
* Static IP configuration
* Persistent network configuration
* Driver and adapter diagnostics
* Installation verification
* Clean uninstall support
* Configuration backup before modification
* Installation and diagnostic logs
* Support for USB unplug/replug detection

---

## What This Project Does

The goal is to turn the QF9700 Linux driver into something that is easier to deploy on an Ubuntu 22.04 machine.

Instead of manually performing multiple steps such as compiling the driver, loading the kernel module, identifying the new network interface, and configuring the network, the installer handles the process automatically.

Typical workflow:

```text
USB Adapter
     |
     v
QF9700 Detection
     |
     v
Driver Installation
     |
     v
Kernel Module Loading
     |
     v
Network Interface Detection
     |
     +-- DHCP
     |
     +-- Static IP
     |
     v
Persistent Configuration
     |
     v
Ready to Use
```

---

## Target Environment

Primary target:

* **Ubuntu 22.04 LTS (jammy)**
* Linux kernel with matching kernel headers (GA `5.15.x-generic`, HWE `6.x-generic`)
* x86_64 and other architectures supported by the bundled driver/build environment (commonly `amd64`, `arm64` works if the bundled `.deb` files match)

The same driver source builds on both 5.15 and 6.x via `LINUX_VERSION_CODE` conditionals.

The installer checks the running kernel before attempting to build the module.

Check your kernel with:

```bash
uname -r
dpkg --print-architecture
ls /lib/modules/$(uname -r)/build
```

---

## Supported Hardware

This project targets **QF9700 / QF9700-compatible USB Ethernet adapters**.

| VID  | PID  | Description |
|------|------|-------------|
| 0fe6 | 9700 | QF9700 USB Ethernet (single function) |
| 0fe6 | 9702 | QF9700 variant, composite device: If#0 = fake CD-ROM (usb-storage), If#1 = Ethernet (qf9700) |

The installer does **not** blindly assume a single USB ID. It checks the connected USB devices and reports the detected VID/PID before proceeding.

Check manually with:

```bash
lsusb | grep 0fe6
```

Example:

```text
Bus 001 Device 004: ID 0fe6:9702 ICS Advent USB 2.0 10/100M Ethernet Adaptor
```

Note for 9702: a quirk is required so `usb-storage` does not claim the Ethernet function:

```text
options usb-storage quirks=0fe6:9702:i
```

This file is installed automatically to `/etc/modprobe.d/qf9700.conf`.

---

## Project Structure

This repository root **is** the installer. Copy the whole directory to USB.

```text
./
├── install.sh
├── uninstall.sh
├── detect.sh
├── configure.sh
├── prepare-offline.sh
├── README.md
├── LICENSE
├── VERSION
├── driver/
│   └── qf9700/          # qf9700.c, qf9700.h, Makefile, dkms.conf
├── packages/            # *.deb offline bundle + MANIFEST.txt + SOURCES.txt
├── config/
│   └── backup/
├── scripts/             # common.sh, install-deps.sh, build-driver.sh, verify.sh, net-config.sh
└── logs/                # install.log
```

---

## Installation

Copy the entire project directory to the offline Ubuntu machine.

On the target, make scripts executable first (USB FAT32/exFAT strips the exec bit; a git clone on Linux preserves it):

```bash
chmod +x install.sh uninstall.sh detect.sh configure.sh prepare-offline.sh scripts/*.sh
```

Run:

```bash
sudo ./install.sh
```

The installer will:

1. Check the operating system
2. Check the running kernel
3. Auto-install gcc/make offline from `packages/toolchain-*/` when missing
4. Verify kernel headers
5. Install bundled local packages when available (`dpkg -i ./packages/*.deb`, never online)
6. Build the QF9700 kernel module
7. Install the module
8. Load the driver (`depmod`, `modprobe qf9700`)
9. Detect the QF9700 adapter (`lsusb` for 0fe6:9700/9702)
10. Detect the resulting network interface (sysfs walk, never hard-coded `eth0`)
11. Configure the network
12. Enable boot persistence
13. Run verification tests
14. Generate an installation report

No internet connection should be required during normal offline installation.

Offline contract (`install.sh`):

* NEVER `git clone`, NEVER `curl`/`wget`, NEVER online `apt install`.
* ONLY `dpkg -i ./packages/*.deb ./packages/toolchain-*/*.deb` plus local source in `driver/`.
* gcc/make are pre-bundled in `packages/toolchain-amd64/` (~31 MB, 8 debs: make + gcc/cpp + gcc-11/cpp-11 + gcc-11-base/libisl23/libmpc3) and auto-installed when the functional compile test fails:
  `sudo ./scripts/install-toolchain.sh` (also runs automatically via `install.sh`).
* Kernel headers are kernel-specific and come from top-level `packages/*.deb` via `prepare-offline.sh`.
* If something is missing, it fails with a clear message and tells you to re-run `prepare-offline.sh --kernel <version>` on an online host.

Example report:

```text
====================================
QF9700 INSTALLATION REPORT
====================================
Driver       : PASS
Kernel       : PASS
USB Device   : PASS
Network      : PASS
Persistence  : PASS
Configuration: DHCP
Interface    : enx001122334455
MAC Address  : 00:11:22:33:44:55
====================================
Installation completed successfully
====================================
```

Logs: `logs/install.log`.

### Non-interactive options

```bash
sudo ./install.sh --dry-run        # checks only, changes nothing
sudo ./install.sh --status         # driver + interface status
sudo ./install.sh --uninstall      # same as ./uninstall.sh
sudo ./install.sh --no-config      # driver only, skip network
sudo ./install.sh --dhcp [IFACE]   # install + DHCP directly
sudo ./install.sh --static IFACE IP PREFIX GW DNS1 [DNS2]
# example:
sudo ./install.sh --static enx001122334455 192.168.1.50 24 192.168.1.1 1.1.1.1 8.8.8.8
```

---

## Network Configuration

After the driver is installed, the installer can configure the QF9700 network interface.

Run the interactive menu:

```bash
sudo ./configure.sh
```

```text
====================================
QF9700 Network Configuration
====================================
1. DHCP
2. Static IP
3. Show current configuration
4. Test connection
5. Exit
```

### DHCP

Choose DHCP to let the system obtain an address automatically. Configuration is permanent via NetworkManager (when active) or netplan, so it survives reboot. It never relies only on temporary `ip addr add`.

Example:

```text
Configuration: DHCP
Interface: enx001122334455
Status: configured
```

Non-interactive:

```bash
sudo ./configure.sh --dhcp enx001122334455
```

### Static IP

For static networking, provide:

```text
IP Address
Subnet Prefix
Gateway
DNS Server
```

Example:

```text
IP Address : 192.168.1.50
Prefix     : 24
Gateway    : 192.168.1.1
DNS        : 1.1.1.1
DNS 2      : 8.8.8.8
```

The installer creates persistent configuration rather than relying on temporary `ip` commands. It only writes files named `qf9700-<iface>.*` and never touches Wi-Fi or other Ethernet connections. Only files tagged with `# Generated by qf9700-offline-installer` are ever removed.

Non-interactive:

```bash
sudo ./configure.sh --static enx001122334455 192.168.1.50 24 192.168.1.1 1.1.1.1 8.8.8.8
sudo ./configure.sh --show
sudo ./configure.sh --test enx001122334455
```

The stack (`NetworkManager` vs `netplan` vs `systemd-networkd`) is auto-detected via `nmcli` / `systemctl` / `/etc/netplan/*.yaml`.

Backups are made automatically to `config/backup/<timestamp>/` plus `/etc/qf9700-installer/backups/<timestamp>/` before any network file is modified.

---

## Detection

Run anytime (no reboot needed, supports unplug/replug):

```bash
sudo ./detect.sh
```

The detection utility reports information such as:

```text
QF9700 Detection
================

Detected       : YES
USB ID         : 0fe6:9702
Driver         : qf9700
Network        : enx001122334455
MAC Address    : 00:11:22:33:44:55
Link State     : UP
```

It explains USB VID:PID, bus/device, per-interface USB driver binding, kernel module, network interface, MAC, link and IP. When no compatible adapter is connected, the utility reports that clearly instead of treating it as a driver installation failure.

---

## Status

Check the installed driver and network state:

```bash
sudo ./install.sh --status
```

Useful diagnostics include:

```bash
lsmod | grep qf9700
```

```bash
modinfo qf9700
```

```bash
ip link
```

```bash
dmesg | tail -50
```

---

## Dry Run

To check the system without modifying it:

```bash
sudo ./install.sh --dry-run
```

This checks the environment, kernel, headers, dependencies, and adapter detection without performing the actual installation.

---

## Uninstall

To remove the components installed by this project:

```bash
sudo ./uninstall.sh
# or:
sudo ./install.sh --uninstall
```

It removes: the `.ko`, the DKMS entry if any, `modules-load.d`, the `modprobe` quirk, the `udev` rule, and installer-tagged NM/netplan connections, then runs `depmod`.

The uninstall process is designed to remove only configuration and files created by this project. Existing system network configurations, unrelated kernel drivers, and system packages remain untouched. Network files are only deleted after verifying the installer marker.

---

## Building an Offline Bundle

On a machine with internet access (Ubuntu 22.04 recommended):

```bash
# find the target kernel name (ask the offline machine owner for `uname -r`)
apt-cache search linux-headers-5.15 | grep generic

./prepare-offline.sh --kernel 5.15.0-91-generic --arch amd64
# or for the current host kernel:
./prepare-offline.sh
```

The preparation process collects:

* QF9700 driver source (already vendored, see `driver/qf9700/README.source`)
* Required `.deb` packages (`linux-headers-*`, `build-essential`, `gcc`, `make`, `dkms`, deps)
* Build dependencies
* DKMS packages when used
* Kernel headers for the target kernel
* Installation scripts and supporting files
* `packages/MANIFEST.txt` + `packages/SOURCES.txt`

The resulting directory can then be copied to the target Ubuntu machine using removable storage.

Example:

```text
dist/
└── qf9700-offline-installer/
```

Copy to USB:

```bash
cp -a dist/qf9700-offline-installer /media/$USER/FLASHDISK/
```

The target system should not need to download anything during installation.

---

## Kernel Compatibility

Linux kernel modules are kernel-version dependent.

Before creating an offline bundle, determine the target kernel:

```bash
uname -r
```

The corresponding kernel headers must be available in the offline package bundle.

For example:

```text
Running kernel:
5.15.0-XXX-generic

Required headers:
linux-headers-5.15.0-XXX-generic
```

If the running kernel does not match the bundled headers, the installer stops rather than attempting an unsafe or incomplete build:

```text
ERROR: Kernel headers for 5.15.0-XXX-generic are not available in offline package bundle.
Available headers: ...
Please prepare this bundle for the target kernel.
```

In that situation, recreate the offline bundle for the correct target kernel:

```bash
./prepare-offline.sh --kernel <target-uname-r> --arch <target-arch>
```

---

## Troubleshooting

### Adapter is not detected

Check:

```bash
lsusb
lsusb -t
usb-devices | grep -A8 0fe6
```

Look for a QF9700-compatible USB ID (`0fe6:9700`, `0fe6:9702`).

Then check:

```bash
dmesg | tail -50
```

If the adapter was just plugged in, wait 3 seconds and run `sudo ./detect.sh` again. No reinstall is needed.

### Module is not loaded

Check:

```bash
lsmod | grep qf9700
```

Try loading it manually:

```bash
sudo modprobe qf9700
```

Then inspect:

```bash
dmesg | tail -50
```

Also try:

```bash
modinfo qf9700
```

### Network interface does not appear

Check:

```bash
ip link
```

and:

```bash
dmesg | tail -100
```

Also verify that the QF9700 USB device is actually detected by the kernel (`lsusb`, `sudo ./detect.sh`). For 9702, check that If#0 is not holding the device: `cat /etc/modprobe.d/qf9700.conf` should contain `quirks=0fe6:9702:i`.

`error -71 (EPROTO)` in `dmesg` usually means a USB 3.0 hub that dislikes this USB 1.1 device -- plug directly into a USB 2.0 port.

### DHCP fails

Check:

```bash
nmcli device show <iface>
cat /etc/netplan/99-qf9700-*.yaml
sudo dhclient -v <iface>
```

### Offline dependency is missing

The installer reports which package is unavailable. Check:

```bash
ls packages/*.deb
cat packages/MANIFEST.txt
dpkg -l | grep -E 'headers|build-essential|dkms'
uname -r
ls /lib/modules/
ls /usr/src/ | grep header
```

The offline bundle must be recreated with the required `.deb` package and, when applicable, the matching kernel headers.

---

## Boot Persistence

* Module: `/etc/modules-load.d/qf9700.conf` (`qf9700`) plus optional DKMS (`qf9700/1.0`) when `dkms` is bundled.
* Quirk for 9702: `/etc/modprobe.d/qf9700.conf` plus `update-initramfs -u`.
* Hotplug: `/etc/udev/rules.d/99-qf9700.rules` (`modprobe` on USB add, no reboot needed after replug).
* Network: NetworkManager `.nmconnection` (mode 600) or `99-qf9700-<iface>.yaml` for netplan.
* After reboot the adapter works without login and without running `install.sh` again.

---

## Original Project

This project is based on the Linux QF9700 driver from:

**Original repository:**
https://github.com/pgquiles/qf9700

Modern kernel fixes reference:
https://github.com/genocem/usb-2-10-100m-ethernet-adapter-rd9700-updated-linux-driver

Please refer to the original project for the upstream driver source and history.

The original driver code and copyright notices remain attributed to their respective authors. See `driver/qf9700/README.source`.

---

## Licensing

The QF9700 driver is distributed under the **GNU General Public License version 2**.

Because this project contains and/or distributes modified or derived portions of that GPLv2 driver, the corresponding driver-based work is distributed under the terms of **GPL-2.0**.

The original copyright and license notices are retained.

See:

```text
LICENSE
```

for the full license text.

### Attribution

This project is **not the original QF9700 driver**.

It adds packaging, installation automation, detection, configuration, persistence, and offline deployment tooling around the original driver. Original author: `jokeliujl <jokeliu@163.com>`.

---

## Project Maintainer

**RulZharif**

GitHub:
https://github.com/RulZharif

This repository maintains attribution to the original QF9700 driver authors and project.

---

## Disclaimer

This software is provided **without warranty**.

Kernel modules operate at the Linux kernel level. Use appropriate care when installing or modifying drivers and network configuration.

Always keep backups of important network configuration before making system-level changes.

---

## Why This Exists

Old USB Ethernet adapters are sometimes perfectly usable, but getting them working on an offline Linux machine can be a pain.

This project tries to make the process:

```text
manual driver hunting
        |
        v
dependency hunting
        |
        v
kernel header nonsense
        |
        v
network config nonsense
        |
        v
"why isn't eth0 here"
```

into:

```bash
sudo ./install.sh
```

and done.
