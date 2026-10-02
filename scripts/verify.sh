#!/bin/bash
# QF9700 — verification suite (offline, read-only except log).
# Usage: ./scripts/verify.sh [--iface <name>]
# Exit 0 if critical checks pass, 1 otherwise. Prints PASS/FAIL report.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

IFACE_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --iface) IFACE_OVERRIDE="$2"; shift 2;;
        *) shift;;
    esac
done

PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); ok "PASS: $*"; }
fail(){ FAIL=$((FAIL+1)); err "FAIL: $*"; }

header "QF9700 VERIFICATION"
log "Kernel: $(get_kernel)  Arch: $(get_arch)"

# 1. Driver module file exists
KO_FILE=""
for p in "/lib/modules/$(get_kernel)/kernel/drivers/net/usb/qf9700.ko" \
         "/lib/modules/$(get_kernel)/updates/dkms/qf9700.ko"; do
    if [ -f "$p" ]; then KO_FILE="$p"; break; fi
done
if [ -n "$KO_FILE" ]; then pass "driver module exists ($KO_FILE)"; else fail "driver module file missing (expected /lib/modules/$(get_kernel)/kernel/drivers/net/usb/qf9700.ko)"; fi
if modinfo qf9700 >/dev/null 2>&1; then pass "modinfo qf9700"; else fail "modinfo qf9700 (depmod missing?)"; fi

# 2. Module can be loaded / is loaded
if lsmod | grep -q "^qf9700"; then pass "module loaded (lsmod)"; else
    if modprobe qf9700 2>>"$LOG_FILE"; then pass "module loadable (modprobe)"; sleep 1
    else fail "module cannot be loaded (try: dmesg | tail -50)"; fi
fi

# 3. Kernel headers sanity (for report, not fatal)
if [ -d "/lib/modules/$(get_kernel)/build" ]; then pass "kernel build tree present"; else fail "kernel build tree missing (/lib/modules/$(get_kernel)/build)"; fi

# 4. USB device
if detect_qf_usb; then pass "USB device $QF_VIDPID ($QF_LSUSB_LINE)"; else fail "QF9700 USB device not found (is adapter plugged in? check: lsusb)"; print_usb_devices || true; fi
if [ -n "${QF_VIDPID:-}" ] && [ "$QF_VIDPID" = "0fe6:9702" ]; then
    if [ -f /etc/modprobe.d/qf9700.conf ] && grep -q "quirks=0fe6:9702:i" /etc/modprobe.d/qf9700.conf; then
        pass "usb-storage quirk for 9702 present"
    else
        fail "usb-storage quirk missing (/etc/modprobe.d/qf9700.conf should contain quirks=0fe6:9702:i)"
    fi
fi

# 5. Network interface
IFACE="$IFACE_OVERRIDE"
if [ -z "$IFACE" ]; then
    if find_qf_iface; then IFACE="$QF_IFACE"; fi
fi
if [ -n "$IFACE" ] && [ -d "/sys/class/net/$IFACE" ]; then
    pass "network interface exists ($IFACE)"
else
    fail "network interface not found (expected enxXXXXXXXXXXXX from QF9700; check: ip link ; dmesg | tail -100)"
    IFACE=""
fi

# 6. MAC / state
if [ -n "$IFACE" ]; then
    MAC=$(cat "/sys/class/net/$IFACE/address" 2>/dev/null || echo "")
    STATE=$(cat "/sys/class/net/$IFACE/operstate" 2>/dev/null || echo unknown)
    CARRIER=$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null || echo unknown)
    if [[ "$MAC" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] && [ "$MAC" != "00:00:00:00:00:00" ]; then
        pass "MAC exists ($MAC)"
    else
        fail "MAC missing/invalid ($MAC)"
    fi
    log "Interface state: $STATE  carrier: $CARRIER"
    if [ "$STATE" != "unknown" ]; then pass "interface state detected ($STATE)"; else fail "interface state unknown"; fi
    # IP config
    if ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q "inet "; then
        pass "IP address assigned ($(ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | tr '\n' ' '))"
    else
        fail "no IPv4 on $IFACE (configure DHCP/static via ./configure.sh)"
    fi
    # persistence of net config
    if is_ours "$(nm_connection_path "$IFACE")" 2>/dev/null || is_ours "$(netplan_path "$IFACE")" 2>/dev/null; then
        pass "persistent network config detected"
    else
        # also accept any NM connection bound to iface
        if command -v nmcli >/dev/null 2>&1 && nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep -q ":$IFACE$"; then
            pass "active NetworkManager connection for $IFACE"
        else
            fail "no persistent config found for $IFACE (run ./configure.sh)"
        fi
    fi
fi

# 7. Module persistence
if [ -f /etc/modules-load.d/qf9700.conf ] && grep -q "^qf9700" /etc/modules-load.d/qf9700.conf; then
    pass "module persistence (modules-load.d)"
elif command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -q "qf9700"; then
    pass "module persistence (DKMS)"
else
    fail "module persistence missing (/etc/modules-load.d/qf9700.conf)"
fi

if [ -f /etc/udev/rules.d/99-qf9700.rules ] && grep -q "0fe6" /etc/udev/rules.d/99-qf9700.rules; then
    pass "udev hotplug rule present"
else
    fail "udev hotplug rule missing (/etc/udev/rules.d/99-qf9700.rules)"
fi

# ---- summary table ----
echo ""
header "QF9700 INSTALLATION REPORT"
printf '%-14s: %s\n' "Driver"       "$( [ -n "$KO_FILE" ] && echo PASS || echo FAIL )"
printf '%-14s: %s\n' "Kernel"       "$( [ -d "/lib/modules/$(get_kernel)/build" ] && echo PASS || echo FAIL )"
printf '%-14s: %s\n' "USB Device"   "$( [ "${QF_FOUND:-0}" = "1" ] && echo "PASS ($QF_VIDPID)" || echo FAIL )"
printf '%-14s: %s\n' "Network"      "$( [ -n "${IFACE:-}" ] && echo "PASS ($IFACE)" || echo FAIL )"
printf '%-14s: %s\n' "Persistence"  "$( ([ -f /etc/modules-load.d/qf9700.conf ] || (command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -q qf9700)) && echo PASS || echo FAIL )"
if [ -n "${IFACE:-}" ]; then
    printf '%-14s: %s\n' "Interface" "$IFACE"
    printf '%-14s: %s\n' "MAC Address" "${MAC:-?}"
    printf '%-14s: %s\n' "State" "${STATE:-?} / carrier ${CARRIER:-?}"
    printf '%-14s: %s\n' "IP" "$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | tr '\n' ' ' || echo none)"
fi
echo "===================================="
if [ "$FAIL" -eq 0 ]; then
    ok "Installation completed successfully ($PASS checks passed)"
    exit 0
else
    err "$FAIL check(s) failed, $PASS passed. See above + dmesg + $LOG_FILE"
    exit 1
fi
