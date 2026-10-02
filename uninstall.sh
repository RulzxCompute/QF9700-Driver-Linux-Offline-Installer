#!/bin/bash
# QF9700 — uninstall (removes ONLY what the installer created).
# Usage: sudo ./uninstall.sh [--yes]
# Never removes: builtin kernel drivers, foreign NM/netplan files, system packages.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/common.sh"

YES=0
[ "${1:-}" = "--yes" ] && YES=1

require_root
header "QF9700 Uninstall"
log "Log: $LOG_FILE"

confirm() {
    if [ "$YES" = "1" ]; then return 0; fi
    echo -n "Remove QF9700 driver + installer configs? [y/N]: "
    read -r a
    [[ "$a" =~ ^[Yy]$ ]]
}

confirm || { log "Aborted."; exit 0; }

KVER="$(get_kernel)"
fail=0

# 1. Unload module
if lsmod | grep -q "^qf9700"; then
    info "Unloading qf9700 ..."
    modprobe -r qf9700 2>&1 | tee -a "$LOG_FILE" || rmmod qf9700 2>&1 | tee -a "$LOG_FILE" || warn "unload failed (in use?)"
fi

# 2. DKMS entry (only ours)
if command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -q "qf9700"; then
    info "Removing DKMS qf9700/1.0 ..."
    dkms remove -m qf9700 -v 1.0 --all 2>&1 | tee -a "$LOG_FILE" || warn "dkms remove issue"
    rm -rf /usr/src/qf9700-1.0
    ok "DKMS entry removed"
else
    info "No DKMS entry for qf9700"
fi

# 3. Module file (only the one we installed; never touch foreign drivers)
for p in "/lib/modules/$KVER/kernel/drivers/net/usb/qf9700.ko" \
         "/lib/modules/$KVER/updates/dkms/qf9700.ko"; do
    if [ -f "$p" ]; then
        info "Removing $p ..."
        rm -f "$p"
        ok "Removed $p"
    fi
done
# Also clean other kernels' copies created by this installer? List them.
for f in /lib/modules/*/kernel/drivers/net/usb/qf9700.ko; do
    [ -f "$f" ] || continue
    if [ "$f" != "/lib/modules/$KVER/kernel/drivers/net/usb/qf9700.ko" ]; then
        warn "Found other-kernel copy: $f (leaving it; use --clean-all to remove)"
    fi
done
depmod -a 2>&1 | tee -a "$LOG_FILE" || true

# 4. modules-load (only if ours)
if [ -f /etc/modules-load.d/qf9700.conf ]; then
    if is_ours /etc/modules-load.d/qf9700.conf || grep -qx "qf9700" /etc/modules-load.d/qf9700.conf; then
        backup_file /etc/modules-load.d/qf9700.conf || true
        rm -f /etc/modules-load.d/qf9700.conf
        ok "Removed /etc/modules-load.d/qf9700.conf"
    else
        warn "Keeping foreign /etc/modules-load.d/qf9700.conf (no installer marker)"
    fi
fi

# 5. modprobe quirk (only if ours)
if [ -f /etc/modprobe.d/qf9700.conf ]; then
    if is_ours /etc/modprobe.d/qf9700.conf; then
        backup_file /etc/modprobe.d/qf9700.conf || true
        rm -f /etc/modprobe.d/qf9700.conf
        ok "Removed /etc/modprobe.d/qf9700.conf"
        command -v update-initramfs >/dev/null 2>&1 && update-initramfs -u 2>&1 | tee -a "$LOG_FILE" || true
    else
        warn "Keeping foreign /etc/modprobe.d/qf9700.conf"
    fi
fi

# 6. udev rule (only if ours)
if [ -f /etc/udev/rules.d/99-qf9700.rules ]; then
    if is_ours /etc/udev/rules.d/99-qf9700.rules; then
        backup_file /etc/udev/rules.d/99-qf9700.rules || true
        rm -f /etc/udev/rules.d/99-qf9700.rules
        ok "Removed /etc/udev/rules.d/99-qf9700.rules"
        udevadm control --reload-rules 2>&1 | tee -a "$LOG_FILE" || true
    else
        warn "Keeping foreign /etc/udev/rules.d/99-qf9700.rules"
    fi
fi

# 7. Network configs (only ours — marker check is mandatory)
removed_net=0
for f in /etc/NetworkManager/system-connections/qf9700-*.nmconnection; do
    [ -f "$f" ] || continue
    if is_ours "$f"; then
        backup_file "$f" || true
        name=$(basename "$f" .nmconnection)
        nmcli connection delete "$name" 2>&1 | tee -a "$LOG_FILE" || rm -f "$f"
        ok "Removed NM connection $name"
        removed_net=1
    else
        warn "Keeping foreign NM file $f"
    fi
done
for f in /etc/netplan/99-qf9700-*.yaml; do
    [ -f "$f" ] || continue
    if is_ours "$f"; then
        backup_file "$f" || true
        rm -f "$f"
        ok "Removed $f"
        removed_net=1
    else
        warn "Keeping foreign netplan file $f"
    fi
done
if [ "$removed_net" = "1" ]; then
    if command -v nmcli >/dev/null 2>&1; then nmcli connection reload 2>&1 | tee -a "$LOG_FILE" || true; fi
    if command -v netplan >/dev/null 2>&1 && ls /etc/netplan/*.yaml >/dev/null 2>&1; then
        netplan apply 2>&1 | tee -a "$LOG_FILE" || warn "netplan apply issue (check remaining yamls)"
    fi
else
    info "No installer network configs found"
fi

# 8. System backup record dir stays (audit trail) — nothing else to delete.
# Explicitly DO NOT apt remove anything the installer did not install.

header "Uninstall complete"
ok "QF9700 artefacts removed. Other network interfaces untouched."
log "If interface still shows, replug adapter or reboot. Log: $LOG_FILE"
