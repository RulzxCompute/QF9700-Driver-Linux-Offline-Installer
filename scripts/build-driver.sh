#!/bin/bash
# QF9700 — build + install kernel module (offline).
# Usage: ./scripts/build-driver.sh [--dry-run] [--kver <v>]
# Steps: make -> check .ko -> copy to updates -> depmod -> modprobe -> verify
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

DRY_RUN="${DRY_RUN:-0}"
KVER="$(get_kernel)"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift;;
        --kver) KVER="$2"; shift 2;;
        *) shift;;
    esac
done

DRIVER_SRC="$PROJECT_ROOT/driver/qf9700"
KO_SRC="$DRIVER_SRC/qf9700.ko"
DEST_DIR="/lib/modules/$KVER/kernel/drivers/net/usb"
DEST_KO="$DEST_DIR/qf9700.ko"
DKMS_SRC="/usr/src/qf9700-1.0"

step "Build QF9700 driver (kver=$KVER)"
[ -f "$DRIVER_SRC/qf9700.c" ] || die "Driver source missing: $DRIVER_SRC/qf9700.c"
[ -f "$DRIVER_SRC/Makefile" ] || die "Driver Makefile missing: $DRIVER_SRC/Makefile"

if [ "$DRY_RUN" = "1" ]; then
    info "[dry-run] would run: make -C $DRIVER_SRC KVER=$KVER"
    info "[dry-run] would install to: $DEST_KO + depmod + modprobe"
    exit 0
fi

# --- build ---
info "Building in $DRIVER_SRC ..."
if ! make -C "$DRIVER_SRC" KVER="$KVER" 2>&1 | tee -a "$LOG_FILE"; then
    err "Build failed. Common causes:"
    err "  - kernel headers mismatch (uname -r vs bundled headers)"
    err "  - gcc version skew (Ubuntu 22.04 needs gcc-11/12)"
    err "Diagnostics: uname -r ; ls /lib/modules/$KVER/build ; gcc --version ; dmesg | tail -30"
    err "Full log: $LOG_FILE"
    exit 1
fi
[ -f "$KO_SRC" ] || die "Build finished but $KO_SRC not found. Check log: $LOG_FILE"
ok "Built: $KO_SRC ($(stat -c%s "$KO_SRC" 2>/dev/null || stat -f%z "$KO_SRC" 2>/dev/null || echo ?) bytes)"
# --- smoke test (.ko sanity, no behavior change to the proven build) ---
info "Smoke-testing $KO_SRC ..."
KO_VERMAGIC="$(modinfo -F vermagic "$KO_SRC" 2>/dev/null | awk '{print $1}' || true)"
if [ -n "$KO_VERMAGIC" ] && [ "$KO_VERMAGIC" != "$KVER" ]; then
    warn "vermagic $KO_VERMAGIC != running kernel $KVER (module may not load; rebuild with --kver $KVER if needed)"
else
    ok "vermagic OK (${KO_VERMAGIC:-$KVER})"
fi
modinfo -F license "$KO_SRC" 2>/dev/null | grep -qi "GPL" && ok "license OK ($(modinfo -F license "$KO_SRC" 2>/dev/null))" || warn "license field unexpected"
[ -s "$KO_SRC" ] || die "Smoke test failed: $KO_SRC is empty"
modinfo "$KO_SRC" 2>&1 | tee -a "$LOG_FILE" | head -n 20 || true
ok "Smoke test passed: $KO_SRC"

# --- usb-storage quirk for 9702 (composite CD-ROM) ---
QUIRK_FILE="/etc/modprobe.d/qf9700.conf"
QUIRK_LINE="options usb-storage quirks=0fe6:9702:i"
step "USB-storage quirk (0fe6:9702 composite device)"
if [ -f "$QUIRK_FILE" ] && grep -q "0fe6:9702" "$QUIRK_FILE"; then
    ok "Quirk already present: $QUIRK_FILE"
else
    [ -f "$QUIRK_FILE" ] && backup_file "$QUIRK_FILE"
    {
        marker_comment
        echo "$QUIRK_LINE"
    } > "$QUIRK_FILE"
    ok "Wrote $QUIRK_FILE"
    if command -v update-initramfs >/dev/null 2>&1; then
        info "Refreshing initramfs (so quirk applies at early boot)..."
        update-initramfs -u 2>&1 | tee -a "$LOG_FILE" || warn "update-initramfs failed (non-fatal)"
    fi
fi

# --- install module file ---
step "Install kernel module"
mkdir -p "$DEST_DIR"
if [ -f "$DEST_KO" ]; then
    backup_file "$DEST_KO" || true
    warn "Overwriting existing $DEST_KO (backed up)"
fi
cp -v "$KO_SRC" "$DEST_KO" 2>&1 | tee -a "$LOG_FILE"
ok "Copied to $DEST_KO"

# --- optional DKMS registration (only if dkms exists offline) ---
if command -v dkms >/dev/null 2>&1 && [ -f "$DRIVER_SRC/dkms.conf" ]; then
    info "dkms found — registering for kernel-upgrade survival (offline, local source)..."
    rm -rf "$DKMS_SRC"
    mkdir -p "$DKMS_SRC"
    cp -a "$DRIVER_SRC/qf9700.c" "$DRIVER_SRC/qf9700.h" "$DRIVER_SRC/Makefile" "$DRIVER_SRC/dkms.conf" "$DKMS_SRC"/
    # dkms add/build/install must not hit network; they only use local tree.
    dkms add -m qf9700 -v 1.0 2>&1 | tee -a "$LOG_FILE" || warn "dkms add failed (continuing with manual install)"
    dkms build -m qf9700 -v 1.0 -k "$KVER" 2>&1 | tee -a "$LOG_FILE" || warn "dkms build failed (continuing)"
    dkms install -m qf9700 -v 1.0 -k "$KVER" 2>&1 | tee -a "$LOG_FILE" || warn "dkms install failed (continuing)"
else
    info "dkms not used (not installed or not bundled) — manual install is sufficient offline."
fi

# --- depmod + load ---
info "depmod -a ..."
depmod -a 2>&1 | tee -a "$LOG_FILE"
ok "depmod done"

# Reload usb-storage so quirk takes effect without reboot (best effort).
if lsmod | grep -q "^usb_storage"; then
    info "Reloading usb-storage for quirk (best effort)..."
    modprobe -r usb_storage 2>>"$LOG_FILE" || warn "usb-storage in use; quirk applies after replug/reboot."
    modprobe usb_storage 2>&1 | tee -a "$LOG_FILE" || true
fi

# Unload old qf9700 if present, then load new one.
if lsmod | grep -q "^qf9700"; then
    info "Unloading old qf9700 ..."
    modprobe -r qf9700 2>&1 | tee -a "$LOG_FILE" || rmmod qf9700 2>&1 | tee -a "$LOG_FILE" || true
fi
info "modprobe qf9700 ..."
if ! modprobe qf9700 2>&1 | tee -a "$LOG_FILE"; then
    err "modprobe qf9700 failed."
    err "Diagnostics: dmesg | tail -50 ; modinfo qf9700 ; lsmod | grep qf9700"
    exit 1
fi
sleep 2
lsmod | grep -E "^qf9700" | tee -a "$LOG_FILE" || die "qf9700 not in lsmod after modprobe."
modinfo qf9700 2>&1 | tee -a "$LOG_FILE" | head -n 15 || true
ok "Module qf9700 loaded"

# --- persistence: load at boot ---
MODULES_LOAD="/etc/modules-load.d/qf9700.conf"
if [ -f "$MODULES_LOAD" ] && grep -qx "qf9700" "$MODULES_LOAD"; then
    ok "Boot persistence already: $MODULES_LOAD"
else
    [ -f "$MODULES_LOAD" ] && backup_file "$MODULES_LOAD"
    { marker_comment; echo "qf9700"; } > "$MODULES_LOAD"
    ok "Boot persistence: $MODULES_LOAD"
fi

# --- udev rule: auto-modprobe on hotplug, no reboot needed ---
UDEV_RULE="/etc/udev/rules.d/99-qf9700.rules"
if [ -f "$UDEV_RULE" ] && grep -q "qf9700-offline-installer" "$UDEV_RULE"; then
    ok "udev rule already: $UDEV_RULE"
else
    [ -f "$UDEV_RULE" ] && backup_file "$UDEV_RULE"
    {
        marker_comment
        echo 'ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0fe6", ATTR{idProduct}=="9700", RUN+="/sbin/modprobe qf9700"'
        echo 'ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0fe6", ATTR{idProduct}=="9702", RUN+="/sbin/modprobe qf9700"'
    } > "$UDEV_RULE"
    ok "udev rule: $UDEV_RULE"
    udevadm control --reload-rules 2>&1 | tee -a "$LOG_FILE" || true
    udevadm trigger --subsystem-match=usb --action=add 2>>"$LOG_FILE" || true
fi

ok "Driver install complete"
