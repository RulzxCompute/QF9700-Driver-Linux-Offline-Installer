#!/bin/bash
# QF9700 — USB + driver + network detection (runnable anytime, no reboot needed).
# Usage: sudo ./detect.sh [--short]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/common.sh"

SHORT=0
[ "${1:-}" = "--short" ] && SHORT=1

header "QF9700 Detection"
log "Kernel: $(get_kernel)  Arch: $(get_arch)  Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Best effort: ensure module is loaded so a freshly plugged adapter binds
# without reboot (harmless if already loaded or if headers/driver missing).
if command -v modprobe >/dev/null 2>&1; then
    modprobe qf9700 2>/dev/null || true
fi
if command -v udevadm >/dev/null 2>&1; then
    udevadm settle 2>/dev/null || true
fi

echo ""
echo "--- USB ---"
if detect_qf_usb; then
    ok "QF9700 detected"
    log "USB ID : $QF_VIDPID"
    log "Bus/Device: ${QF_BUS:-?}/${QF_DEV:-?}"
    log "lsusb  : $QF_LSUSB_LINE"
    # Per-interface driver binding (reveals 9702 composite quirk state)
    if [ -d /sys/bus/usb/devices ]; then
        for vpath in /sys/bus/usb/devices/*/idVendor; do
            dir=$(dirname "$vpath")
            vid=$(cat "$dir/idVendor" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
            [ "$vid" = "$SUPPORTED_VID" ] || continue
            pid=$(cat "$dir/idProduct" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
            case " $pid " in *" ${SUPPORTED_PIDS[*]} "*|*" $pid "*) :;; *) :;; esac
            echo "  Device $(basename "$dir"): idVendor=$vid idProduct=$pid product=$(cat "$dir/product" 2>/dev/null || echo ?)"
            for i in "$dir"/*/bInterfaceClass; do
                [ -f "$i" ] || continue
                idir=$(dirname "$i")
                cls=$(cat "$idir/bInterfaceClass" 2>/dev/null || echo ?)
                num=$(cat "$idir/bInterfaceNumber" 2>/dev/null || echo ?)
                drv="NONE"
                if [ -L "$idir/driver" ]; then drv=$(basename "$(readlink "$idir/driver")"); fi
                echo "    Interface $num: class=$cls driver=$drv"
                if [ "$QF_VIDPID" = "0fe6:9702" ] && [ "$num" = "0" ] && [ "$drv" = "usb-storage" ]; then
                    warn "If#0 claimed by usb-storage: quirk missing? Expected quirks=0fe6:9702:i in /etc/modprobe.d/qf9700.conf"
                fi
            done
        done
    fi
else
    warn "QF9700 NOT found (adapter belum dicolok?)"
    log "Looked for: 0fe6:9700, 0fe6:9702"
    print_usb_devices
    log "Tip: colok adapter, tunggu 3 detik, jalankan lagi: sudo ./detect.sh"
    log "Instalasi driver TIDAK dianggap gagal hanya karena adapter belum terpasang."
fi

echo ""
echo "--- Driver ---"
if command -v lsmod >/dev/null 2>&1 && lsmod 2>/dev/null | grep -q "^qf9700"; then
    ok "Module loaded: $(lsmod 2>/dev/null | grep ^qf9700 | awk '{print $1}')"
else
    warn "Module qf9700 not loaded"
    log "Try: sudo modprobe qf9700 ; dmesg | tail -30"
fi
if command -v modinfo >/dev/null 2>&1 && modinfo qf9700 >/dev/null 2>&1; then
    modinfo qf9700 2>/dev/null | grep -E "^(filename|version|description|alias)" | tee -a "$LOG_FILE" || true
else
    warn "modinfo qf9700 failed (driver not installed? run sudo ./install.sh)"
fi

echo ""
echo "--- Network interface ---"
if find_qf_iface; then
    ok "Interface: $QF_IFACE"
    log "MAC      : ${QF_MAC:-?}"
    log "State    : ${QF_STATE:-?}  carrier: ${QF_CARRIER:-?}  driver: ${QF_DRIVER:-?}"
    iface_show "$QF_IFACE" || true
    echo ""
    # Link status human-readable
    if [ "${QF_CARRIER:-unknown}" = "1" ]; then
        ok "Link: UP (cable connected)"
    elif [ "${QF_CARRIER:-unknown}" = "0" ]; then
        warn "Link: DOWN (no cable? check Ethernet cable)"
    else
        log "Link: ${QF_CARRIER:-unknown}"
    fi
    # IP
    IP4=""
    if command -v ip >/dev/null 2>&1; then
        IP4=$(ip -4 -o addr show dev "$QF_IFACE" 2>/dev/null | awk '{print $4}' | tr '\n' ' ' || true)
    fi
    if [ -n "$IP4" ]; then ok "IPv4: $IP4"; else warn "No IPv4 on $QF_IFACE (run sudo ./configure.sh)"; fi
    if [ "$SHORT" = "0" ]; then
        echo ""
        log "dmesg (qf9700, last 10):"
        if command -v dmesg >/dev/null 2>&1; then
            dmesg 2>/dev/null | grep -i "qf9700" | tail -10 | tee -a "$LOG_FILE" || log "(no qf9700 lines in dmesg)"
        else
            log "(dmesg not available)"
        fi
    fi
else
    warn "No QF9700 network interface found"
    log "All interfaces (ip link):"
    if command -v ip >/dev/null 2>&1; then
        ip link show 2>&1 | tee -a "$LOG_FILE" || true
    else
        log "(ip command not available; on target Ubuntu 22.04 it exists via iproute2)"
    fi
    if [ "${QF_FOUND:-0}" = "1" ]; then
        warn "USB device present but no interface — driver may not be bound."
        log "Diagnose: dmesg | tail -50 ; lsmod | grep qf9700 ; modinfo qf9700"
    fi
fi

echo ""
if [ "${QF_FOUND:-0}" = "1" ] && [ -n "${QF_IFACE:-}" ]; then
    header "SUMMARY: QF9700 detected  USB $QF_VIDPID  Interface $QF_IFACE  MAC ${QF_MAC:-?}"
else
    header "SUMMARY: QF9700 not fully ready (see above)"
fi
