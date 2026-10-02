# QF9700 Ubuntu 22.04 Offline Installer

A lightweight, offline-friendly installer and management toolkit for **QF9700 / QF9700-based USB 2.0 10/100M Ethernet adapters** on Ubuntu 22.04.

This project packages the Linux QF9700 driver together with an automated installation workflow, USB device detection, network configuration, diagnostics, and boot persistence — designed for systems that **may not have an internet connection during installation**.

> Built for old and offline Ubuntu systems where "just `apt install` it" is not exactly an option. 🗿

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
     │
     ▼
QF9700 Detection
     │
     ▼
Driver Installation
     │
     ▼
Kernel Module Loading
     │
     ▼
Network Interface Detection
     │
     ├── DHCP
     │
     └── Static IP
     │
     ▼
Persistent Configuration
     │
     ▼
Ready to Use 
```

---

## Target Environment

Primary target:

* **Ubuntu 22.04 LTS**
* Linux kernel with matching kernel headers
* x86_64 and other architectures supported by the bundled driver/build environment

The installer checks the running kernel before attempting to build the module.

Check your kernel with:

```bash
uname -r
```

---

## Supported Adapter

This project targets **QF9700 / QF9700-compatible USB Ethernet adapters**.

Common USB identifiers may include:

```text
0fe6:9700
0fe6:9702
```

The installer does **not** blindly assume a single USB ID. It checks the connected USB devices and reports the detected VID/PID before proceeding.

Check manually with:

```bash
lsusb
```

Example:

```text
Bus 001 Device 004: ID 0fe6:9702
```

---

## Installation

Copy the entire project directory to the offline Ubuntu machine.

Example:

```bash
cd qf9700-offline-installer
```

Run:

```bash
sudo ./install.sh
```

The installer will:

1. Check the operating system
2. Check the running kernel
3. Verify kernel headers
4. Check required build dependencies
5. Install bundled local packages when available
6. Build the QF9700 kernel module
7. Install the module
8. Load the driver
9. Detect the QF9700 adapter
10. Detect the resulting network interface
11. Configure the network
12. Enable boot persistence
13. Run verification tests
14. Generate an installation report

No internet connection should be required during normal offline installation.

---

## Network Configuration

After the driver is installed, the installer can configure the QF9700 network interface.

### DHCP

Choose DHCP to let the system obtain an address automatically.

Example:

```text
Configuration: DHCP
Interface: enx001122334455
Status: configured
```

The configuration is stored persistently so it remains active after reboot.

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

The installer creates persistent configuration rather than relying on temporary `ip` commands.

---

## Detection

Run:

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

When no compatible adapter is connected, the utility reports that clearly instead of treating it as a driver installation failure.

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
```

The uninstall process is designed to remove only configuration and files created by this project.

Existing system network configurations and unrelated kernel drivers should remain untouched.

---

## Project Structure

```text
qf9700-offline-installer/
├── install.sh
├── uninstall.sh
├── detect.sh
├── configure.sh
├── prepare-offline.sh
├── README.md
├── LICENSE
│
├── driver/
│   └── qf9700/
│
├── packages/
│   └── *.deb
│
├── config/
│   └── backup/
│
├── scripts/
│
└── logs/
```

The exact structure may change as the project evolves.

---

## Building an Offline Bundle

The repository can also contain a preparation utility for creating a self-contained installation package.

On a machine with internet access:

```bash
./prepare-offline.sh
```

The preparation process can collect:

* QF9700 driver source
* Required `.deb` packages
* Build dependencies
* DKMS packages when used
* Kernel headers for the target kernel
* Installation scripts
* Supporting files

The resulting directory can then be copied to the target Ubuntu machine using removable storage.

Example:

```text
dist/
└── qf9700-offline-installer/
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

If the running kernel does not match the bundled headers, the installer should stop rather than attempting an unsafe or incomplete build.

In that situation, recreate the offline bundle for the correct target kernel.

---

## Troubleshooting

### Adapter is not detected

Check:

```bash
lsusb
```

Look for a QF9700-compatible USB ID.

Then check:

```bash
dmesg | tail -50
```

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

### Network interface does not appear

Check:

```bash
ip link
```

and:

```bash
dmesg | tail -100
```

Also verify that the QF9700 USB device is actually detected by the kernel.

### Offline dependency is missing

The installer should report which package is unavailable.

The offline bundle must be recreated with the required `.deb` package and, when applicable, the matching kernel headers.

---

## Original Project

This project is based on the Linux QF9700 driver from:

**Original repository:**
https://github.com/pgquiles/qf9700

Please refer to the original project for the upstream driver source and history.

The original driver code and copyright notices remain attributed to their respective authors.

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

It adds packaging, installation automation, detection, configuration, persistence, and offline deployment tooling around the original driver.

---

## 👤 Project Maintainer

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
        ↓
dependency hunting
        ↓
kernel header nonsense
        ↓
network config nonsense
        ↓
"why isn't eth0 here" 
```

into:

```bash
sudo ./install.sh
```

and done. 
