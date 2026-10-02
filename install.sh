#!/bin/bash
# QF9700 offline installer — main entry point (Ubuntu 22.04, no internet needed).
# Usage: sudo ./install.sh [--dry-run] [--status] [--uninstall] [--dhcp [IFACE]]
#        sudo ./install.sh --static IFACE IP PREFIX GW DNS1 [DNS2]
#        sudo ./install.sh --no-config | --yes | -h
#
# OFFLINE CONTRACT:
#   - NEVER runs git clone / curl / wget / apt install (online).
#   - ONLY uses dpkg -i ./packages/*.deb and local driver source.
#   - If something is missing, it FAILS with a clear message (no silent network).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/common.sh"

VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo 1.0.0)"
MODE="install"
DRY_RUN="${DRY_RUN:-0}"
NO_CONFIG=0
AUTO_YES=0
DHCP_WANT=""
STATIC_ARGS=()

usage() {
    cat <<EOF
QF9700 offline installer v$VERSION (Ubuntu 22.04, kernel $(uname -r))

Usage: sudo ./install.sh [OPTION]

  (no args)                  full install (interactive network step)
  --dry-run                  checks only, changes nothing
  --status                   show driver + interface status
  --uninstall                remove installer artefacts (calls uninstall.sh)
  --dhcp [IFACE]             install + configure DHCP non-interactively
  --static IFACE IP PREFIX GW DNS1 [DNS2]
                             install + configure static IP non-interactively
  --no-config                install driver but skip network configuration
  --yes                      assume yes (for --dhcp/--static automation)
  -h, --help                 this help

Examples:
  sudo ./install.sh
  sudo ./install.sh --dry-run
  sudo ./install.sh --status
  sudo ./install.sh --dhcp
  sudo ./install.sh --static enx001122334455 192.168.1.50 24 192.168.1.1 1.1.1.1 8.8.8.8
  sudo ./install.sh --uninstall

Offline: all dependencies come from packages/*.deb + driver/ source.
Logs: logs/install.log
EOF
}

# ---------- arg parsing ----------
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0;;
        --dry-run) MODE="dry-run"; DRY_RUN=1; export DRY_RUN; shift;;
        --status) MODE="status"; shift;;
        --uninstall) MODE="uninstall"; shift;;
        --dhcp) MODE="install"; DHCP_WANT="${2:-}"; if [[ "${2:-}" != "" && "${2:-}" != -* ]]; then shift 2; else shift; fi;;
        --static)
            MODE="install"
            [ $# -ge 6 ] || { usage >&2; die "--static needs: IFACE IP PREFIX GW DNS1 [DNS2]"; }
            STATIC_ARGS=("$2" "$3" "$4" "$5" "$6" "${7:-}")
            if [ -n "${7:-}" ]; then shift 7; else shift 6; fi
            ;;
        --no-config) NO_CONFIG=1; shift;;
        --yes|-y) AUTO_YES=1; shift;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1;;
    esac
done
export DRY_RUN

mkdir -p "$LOG_DIR"
echo "===== install.sh v$VERSION mode=$MODE $(date -u +%Y-%m-%dT%H:%M:%SZ) kernel=$(uname -r) =====" >>"$LOG_FILE"

# ---------- sub-modes ----------
if [ "$MODE" = "status" ]; then
    # read-only status (root not strictly required, but more info with it)
    bash "$SCRIPT_DIR/scripts/verify.sh" || true
    echo ""
    bash "$SCRIPT_DIR/detect.sh" --short || true
    exit 0
fi

if [ "$MODE" = "uninstall" ]; then
    exec bash "$SCRIPT_DIR/uninstall.sh" "$@"
fi

# From here: install or dry-run. Root required (except dry-run still wants root for realistic checks).
if [ "$EUID" -ne 0 ]; then
    die "Must run as root. Try: sudo ./install.sh"
fi

header "QF9700 Offline Installer v$VERSION"
log "Mode: $MODE   Project: $SCRIPT_DIR"
log "Log : $LOG_FILE"

# 1. Root
step "1/14 Root"
ok "Running as root"

# 2. Ubuntu version
step "2/14 OS version"
check_ubuntu || warn "(continuing despite OS mismatch — kernel checks still enforced)"

# 3. Architecture
step "3/14 Architecture"
ARCH=$(get_arch)
log "Architecture: $ARCH"
ok "Arch: $ARCH"

# 4. Kernel
step "4/14 Kernel"
KVER="$(get_kernel)"
log "Kernel: $KVER"
log "Headers dir: /lib/modules/$KVER/build"
if [ "$DRY_RUN" = "1" ]; then
    if [ -d "/lib/modules/$KVER/build" ]; then ok "[dry-run] headers present"; else warn "[dry-run] headers MISSING for $KVER"; fi
else
    if [ ! -d "/lib/modules/$KVER/build" ]; then
        warn "Headers missing — will try bundled packages (offline) before failing."
    fi
fi

# 5. Local packages inventory
step "5/14 Local packages (offline)"
HAVE_DEBS=0
if ls "$SCRIPT_DIR"/packages/*.deb >/dev/null 2>&1; then
    log "Bundled (top-level):"
    ls -1 "$SCRIPT_DIR"/packages/*.deb | tee -a "$LOG_FILE"
    HAVE_DEBS=1
fi
if ls "$SCRIPT_DIR"/packages/toolchain-*/*.deb >/dev/null 2>&1; then
    log "Bundled (toolchain):"
    ls -1 "$SCRIPT_DIR"/packages/toolchain-*/*.deb | tee -a "$LOG_FILE"
    HAVE_DEBS=1
fi
if [ "$HAVE_DEBS" = "0" ]; then
    warn "packages/ is EMPTY. If build tools/headers are already installed this is fine."
    warn "Otherwise re-run on online host: ./prepare-offline.sh --kernel $KVER --arch $ARCH"
fi
if [ "$DRY_RUN" = "1" ]; then
    info "[dry-run] would install: dpkg -i packages/*.deb (no network)"
fi

# 6. Dependencies (headers/gcc/make/dkms) — offline only
step "6/14 Dependencies"
if [ "$DRY_RUN" = "1" ]; then
    DRY_RUN=1 bash "$SCRIPT_DIR/scripts/install-deps.sh" --dry-run || warn "dependency check reported issues (see above)"
else
    bash "$SCRIPT_DIR/scripts/install-deps.sh"
fi

# 7-8. Build + install driver
step "7/14 Build driver"
step "8/14 Install driver"
if [ "$DRY_RUN" = "1" ]; then
    DRY_RUN=1 bash "$SCRIPT_DIR/scripts/build-driver.sh" --dry-run
else
    bash "$SCRIPT_DIR/scripts/build-driver.sh"
fi

# 9. Detect QF9700 (non-fatal if unplugged)
step "9/14 Detect QF9700 USB"
if detect_qf_usb; then
    ok "QF9700 detected  USB ID: $QF_VIDPID  Bus/Device: ${QF_BUS:-?}/${QF_DEV:-?}"
    log "lsusb: $QF_LSUSB_LINE"
else
    warn "Adapter belum dicolok (QF9700 not found on USB)."
    print_usb_devices || true
    warn "Installation continues — driver is ready; replug adapter later, no reboot needed."
    warn "Re-check anytime: sudo ./detect.sh"
fi

# 10. Detect network interface (non-fatal)
step "10/14 Detect network interface"
IFACE=""
if find_qf_iface; then
    IFACE="$QF_IFACE"
    ok "Interface: $IFACE  MAC: ${QF_MAC:-?}  State: ${QF_STATE:-?}  Driver: ${QF_DRIVER:-?}"
else
    warn "No QF9700 interface yet."
    log "Existing interfaces:"
    ip -o link show 2>&1 | tee -a "$LOG_FILE" || true
    if [ "${QF_FOUND:-0}" = "1" ]; then
        warn "USB present but no interface — check: dmesg | tail -50"
    else
        warn "Plug adapter later then run: sudo ./detect.sh (no reinstall needed)"
    fi
fi

# 11. Configure network
step "11/14 Configure network"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/net-config.sh"
do_configure() {
    local iface="$1"
    if [ -z "$iface" ]; then
        warn "Skipping network configuration (no interface)."
        return 0
    fi
    # Interactive path only (non-interactive DHCP/static handled by caller).
    info "Launching interactive network menu for $iface ..."
    bash "$SCRIPT_DIR/configure.sh"
}

if [ "$DRY_RUN" = "1" ]; then
    info "[dry-run] would configure network for: ${IFACE:-<none yet>} (DHCP/static menu)"
else
    if [ -n "$IFACE" ]; then
        if [ "${#STATIC_ARGS[@]}" -gt 0 ]; then
            # static iface must match detected or be explicit
            apply_static "${STATIC_ARGS[@]}"
            ok "Static IP configured (permanent)"
        elif [ -n "$DHCP_WANT" ]; then
            DHCPIFACE="${DHCP_WANT:-$IFACE}"
            apply_dhcp "$DHCPIFACE"
            ok "DHCP configured for $DHCPIFACE (permanent)"
        elif [ "$NO_CONFIG" = "1" ]; then
            warn "Skipped network config (--no-config). Later: sudo ./configure.sh --dhcp $IFACE"
        else
            do_configure "$IFACE"
        fi
    else
        if [ "${#STATIC_ARGS[@]}" -gt 0 ]; then
            apply_static "${STATIC_ARGS[@]}" || warn "Static config attempted without detected interface."
        elif [ -n "$DHCP_WANT" ]; then
            warn "No interface to DHCP-configure yet; will apply on next ./configure.sh --dhcp"
        else
            warn "No interface — skipping network step. After plugging adapter: sudo ./configure.sh"
        fi
    fi
fi

# 12. Persistence (already done in build-driver.sh + net-config; verify here)
step "12/14 Persistence (boot + hotplug)"
if [ "$DRY_RUN" = "1" ]; then
    info "[dry-run] would ensure: /etc/modules-load.d/qf9700.conf, /etc/udev/rules.d/99-qf9700.rules, NM/netplan file"
else
    [ -f /etc/modules-load.d/qf9700.conf ] && ok "modules-load: $(cat /etc/modules-load.d/qf9700.conf | tr '\n' ' ')" || warn "modules-load missing"
    [ -f /etc/udev/rules.d/99-qf9700.rules ] && ok "udev: /etc/udev/rules.d/99-qf9700.rules" || warn "udev rule missing"
    [ -f /etc/modprobe.d/qf9700.conf ] && ok "modprobe quirk: $(cat /etc/modprobe.d/qf9700.conf | tr '\n' ' ')" || warn "modprobe quirk missing"
    if [ -n "$IFACE" ]; then
        if is_ours "$(nm_connection_path "$IFACE")" || is_ours "$(netplan_path "$IFACE")"; then
            ok "network config persistent for $IFACE"
        else
            warn "no persistent net file yet for $IFACE (run ./configure.sh)"
        fi
    fi
fi

# 13. Verification
step "13/14 Verification"
if [ "$DRY_RUN" = "1" ]; then
    info "[dry-run] would run: scripts/verify.sh (read-only checks)"
    # still run read-only parts best-effort without failing the dry run
    bash "$SCRIPT_DIR/scripts/verify.sh" || warn "[dry-run] verification reported issues (expected if adapter unplugged)"
else
    if bash "$SCRIPT_DIR/scripts/verify.sh"; then
        ok "Verification passed"
    else
        warn "Verification reported failures — see report above."
        warn "Common: adapter unplugged (USB FAIL) or no IP yet (run ./configure.sh)."
        if [ "${QF_FOUND:-0}" != "1" ] && [ -z "${IFACE:-}" ]; then
            warn "Driver itself is installed; USB/interface checks will pass once adapter is plugged in."
        else
            err "Critical verification failed. Check: dmesg | tail -50 ; sudo ./detect.sh"
            exit 1
        fi
    fi
fi

# 14. Report
step "14/14 Report"
echo ""
header "QF9700 INSTALLATION REPORT"
printf '%-14s: %s\n' "Driver"       "$(modinfo qf9700 >/dev/null 2>&1 && echo PASS || echo FAIL)"
printf '%-14s: %s\n' "Kernel"       "$KVER"
printf '%-14s: %s\n' "USB Device"   "${QF_VIDPID:-not-plugged}"
printf '%-14s: %s\n' "Network"      "${IFACE:-none-yet}"
printf '%-14s: %s\n' "Persistence"  "modules-load.d + udev + NM/netplan"
if [ -n "${IFACE:-}" ]; then
    printf '%-14s: %s\n' "Interface" "$IFACE"
    printf '%-14s: %s\n' "MAC Address" "$(cat /sys/class/net/"$IFACE"/address 2>/dev/null || echo ?)"
fi
echo "===================================="
if [ "$DRY_RUN" = "1" ]; then
    ok "[dry-run] complete — no system changes made."
else
    ok "Installation completed successfully"
    if [ -z "${IFACE:-}" ]; then
        log "Next: plug adapter, then sudo ./detect.sh && sudo ./configure.sh"
    fi
fi
log "Full log: $LOG_FILE"
