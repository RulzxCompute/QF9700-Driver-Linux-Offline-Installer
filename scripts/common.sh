#!/bin/bash
# QF9700 offline installer — shared helpers
# Sourced by install.sh / detect.sh / configure.sh / uninstall.sh
# Must NOT perform any network access. Must be safe with `set -u`.
# Usage: SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$SCRIPT_DIR/scripts/common.sh"

# Guard against double sourcing
if [ -n "${QF_COMMON_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
QF_COMMON_LOADED=1

MODULE_NAME="qf9700"
SUPPORTED_VID="0fe6"
SUPPORTED_PIDS=("9700" "9702")

# Resolve project root (bundle root = parent of scripts/)
COMMON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -f "$COMMON_SCRIPT_DIR/common.sh" ]; then
    # called as scripts/common.sh directly (should not happen)
    PROJECT_ROOT="$(cd "$COMMON_SCRIPT_DIR/.." && pwd)"
elif [ -d "$COMMON_SCRIPT_DIR/scripts" ]; then
    PROJECT_ROOT="$COMMON_SCRIPT_DIR"
else
    PROJECT_ROOT="$(cd "$COMMON_SCRIPT_DIR/.." && pwd)"
fi
LOG_DIR="$PROJECT_ROOT/logs"
LOG_FILE="${QF_LOG_FILE:-$LOG_DIR/install.log}"

# ---------- colours (disabled when not a tty) ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

# ---------- logging ----------
_log_to_file() {
    local msg="$1"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    # strip colour codes for file
    printf '%s\n' "$msg" | sed -r 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE" 2>/dev/null || true
}

log()    { printf '%s\n' "$*"; _log_to_file "$*"; }
info()   { printf '  %b→%b %s\n' "$C_CYAN" "$C_RESET" "$*"; _log_to_file "INFO: $*"; }
ok()     { printf '  %b✓%b %s\n' "$C_GREEN" "$C_RESET" "$*"; _log_to_file "OK: $*"; }
warn()   { printf '  %b!%b %s\n' "$C_YELLOW" "$C_RESET" "$*"; _log_to_file "WARN: $*"; }
err()    { printf '  %bx%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; _log_to_file "ERROR: $*"; }
step()   { printf '\n%b== %s ==%b\n' "$C_BOLD" "$*" "$C_RESET"; _log_to_file "== $* =="; }
header() {
    printf '\n%b====================================%b\n' "$C_CYAN" "$C_RESET"
    printf '%b%s%b\n' "$C_BOLD" "$*" "$C_RESET"
    printf '%b====================================%b\n' "$C_CYAN" "$C_RESET"
    _log_to_file "===== $* ====="
}
die() {
    err "ERROR: $*"
    err "See diagnostics below. Log: $LOG_FILE"
    exit 1
}

run_logged() {
    # run_logged <description> <cmd...>: run, tee to log, keep exit code
    local desc="$1"; shift
    info "$desc: $*"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

# ---------- basic checks ----------
require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        die "Must run as root. Try: sudo $0"
    fi
}

get_kernel() { uname -r; }
get_arch() {
    if command -v dpkg >/dev/null 2>&1; then
        dpkg --print-architecture 2>/dev/null || uname -m
    else
        uname -m
    fi
}

check_ubuntu() {
    # Prints ID + VERSION_ID, warns if not jammy (22.04). Returns 0 always
    # unless --strict is wanted by caller.
    local id="unknown" ver="unknown"
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID:-unknown}"; ver="${VERSION_ID:-unknown}"
    fi
    log "OS: $id $ver"
    if [ "$id" != "ubuntu" ] || [ "$ver" != "22.04" ]; then
        warn "Target is Ubuntu 22.04 (jammy). Detected: $id $ver."
        warn "Installer will continue, but kernel/headers checks still apply."
        return 1
    fi
    ok "Ubuntu 22.04 detected"
    return 0
}

check_headers() {
    local kver="${1:-$(get_kernel)}"
    local build="/lib/modules/$kver/build"
    log "Kernel: $kver"
    log "Arch: $(get_arch)"
    if [ -d "$build" ] && [ -f "$build/Makefile" ]; then
        ok "Kernel headers present: $build"
        return 0
    fi
    err "Kernel headers for $kver are NOT available."
    err "Missing: $build"
    log "Available /lib/modules:"
    ls -1 /lib/modules/ 2>/dev/null || log "(cannot list /lib/modules)"
    log "Available /usr/src:"
    ls -1 /usr/src/ 2>/dev/null | grep -i header || log "(no linux-headers in /usr/src)"
    if ls "$PROJECT_ROOT"/packages/*.deb >/dev/null 2>&1; then
        log "Bundled .debs:"
        ls -1 "$PROJECT_ROOT"/packages/*.deb
    else
        log "No .deb files in packages/ (bundle not prepared? run prepare-offline.sh on online host)"
    fi
    return 1
}

check_tools() {
    # $1 = "strict" to fail on missing gcc/make, else warn only.
    local strict="${1:-warn}"
    local missing=0
    for t in gcc make modprobe depmod ip lsusb udevadm; do
        if command -v "$t" >/dev/null 2>&1; then
            ok "tool: $t ($(command -v "$t"))"
        else
            warn "tool missing: $t"
            missing=$((missing+1))
        fi
    done
    if [ "$missing" -gt 0 ] && [ "$strict" = "strict" ]; then
        err "$missing required tool(s) missing. Install bundled packages first (dpkg -i packages/*.deb)."
        return 1
    fi
    return 0
}

# ---------- local packages (OFFLINE ONLY) ----------
list_local_debs() {
    ls -1 "$PROJECT_ROOT"/packages/*.deb 2>/dev/null || true
    # toolchain subdirs (e.g. packages/toolchain-amd64/*.deb) are committed
    # for offline gcc/make; top-level packages/*.deb comes from prepare-offline.sh.
    ls -1 "$PROJECT_ROOT"/packages/toolchain-*/*.deb 2>/dev/null || true
}

install_local_debs() {
    # Installs every .deb in packages/ (top-level + toolchain-*/) with dpkg.
    # NEVER touches the network. Respects DRY_RUN=1 (only print what would be done).
    # For gcc/make specifically, prefer scripts/install-toolchain.sh (ordered).
    local debs
    debs=$(list_local_debs)
    if [ -z "$debs" ]; then
        warn "No .deb files in packages/. Skipping local package install."
        warn "If build tools are missing, re-run prepare-offline.sh on an online host."
        return 0
    fi
    log "Local packages:"
    echo "$debs" | while read -r d; do log "  - ${d#$PROJECT_ROOT/}"; done
    if [ "${DRY_RUN:-0}" = "1" ]; then
        info "[dry-run] would run: dpkg -i packages/*.deb packages/toolchain-*/*.deb"
        return 0
    fi
    if ! command -v dpkg >/dev/null 2>&1; then
        die "dpkg not found — cannot install offline packages."
    fi
    info "Installing local packages with dpkg (no network)..."
    # Install toolchain first (ordered) so gcc/make exist before headers.dkms.
    if [ -x "$PROJECT_ROOT/scripts/install-toolchain.sh" ]; then
        "$PROJECT_ROOT/scripts/install-toolchain.sh" 2>&1 | tee -a "$LOG_FILE" || {
            warn "toolchain install reported issues (continuing to remaining packages)"
        }
    fi
    # Then remaining top-level debs (headers, dkms, ... from prepare-offline.sh).
    if ls "$PROJECT_ROOT"/packages/*.deb >/dev/null 2>&1; then
        # dpkg may exit non-zero if deps missing; capture and explain.
        if dpkg -i "$PROJECT_ROOT"/packages/*.deb 2>&1 | tee -a "$LOG_FILE"; then
            ok "Local packages installed"
        else
            err "dpkg reported errors. Common causes:"
        err "  - bundle built for a different kernel/arch"
        err "  - packages/*.deb incomplete (re-run prepare-offline.sh --kernel $(get_kernel))"
        err "Diagnose: dpkg -l | grep -E 'linux-headers|build-essential|dkms' ; apt-get install -f would need NETWORK (not used offline)"
        return 1
        fi
    else
        ok "Local packages installed (toolchain only, no top-level debs)"
    fi
}

# ---------- USB detection (NO hard-coded single PID) ----------
# Sets globals: QF_FOUND (0/1), QF_VIDPID (e.g. 0fe6:9702), QF_BUS, QF_DEV, QF_LSUSB_LINE
QF_FOUND=0
QF_VIDPID=""
QF_BUS=""
QF_DEV=""
QF_LSUSB_LINE=""

detect_qf_usb() {
    QF_FOUND=0; QF_VIDPID=""; QF_BUS=""; QF_DEV=""; QF_LSUSB_LINE=""
    if ! command -v lsusb >/dev/null 2>&1; then
        warn "lsusb not found (usbutils missing). Cannot detect USB devices."
        return 1
    fi
    local lsusb_out
    lsusb_out=$(lsusb 2>/dev/null || true)
    if [ -z "$lsusb_out" ]; then
        warn "lsusb produced no output."
        return 1
    fi
    local pid line
    for pid in "${SUPPORTED_PIDS[@]}"; do
        line=$(printf '%s\n' "$lsusb_out" | grep -i "${SUPPORTED_VID}:${pid}" | head -n 1 || true)
        if [ -n "$line" ]; then
            QF_FOUND=1
            QF_VIDPID="${SUPPORTED_VID}:${pid}"
            QF_LSUSB_LINE="$line"
            # Bus 001 Device 004: ID 0fe6:9702 ...
            QF_BUS=$(printf '%s' "$line" | sed -n 's/^Bus \([0-9]*\).*/\1/p')
            QF_DEV=$(printf '%s' "$line" | sed -n 's/^Bus [0-9]* Device \([0-9]*\).*/\1/p')
            return 0
        fi
    done
    return 1
}

print_usb_devices() {
    log "USB devices (lsusb):"
    if command -v lsusb >/dev/null 2>&1; then
        lsusb 2>&1 | tee -a "$LOG_FILE" || true
    else
        log "(lsusb not available)"
    fi
}

# ---------- network interface discovery (NO eth0 hard-code) ----------
# Sets: QF_IFACE, QF_MAC, QF_STATE, QF_DRIVER, QF_CARRIER
QF_IFACE=""; QF_MAC=""; QF_STATE=""; QF_DRIVER=""; QF_CARRIER=""

find_qf_iface() {
    QF_IFACE=""; QF_MAC=""; QF_STATE=""; QF_DRIVER=""; QF_CARRIER=""
    local iface
    for iface_path in /sys/class/net/*; do
        [ -e "$iface_path" ] || continue
        iface=$(basename "$iface_path")
        [ "$iface" = "lo" ] && continue
        # Walk up from /sys/class/net/<iface>/device to find USB idVendor/idProduct
        local dev_path="$iface_path/device"
        local cur="$dev_path"
        local vid="" pid="" depth=0
        while [ -L "$cur" ] || [ -e "$cur" ]; do
            # resolve symlink once
            if [ -L "$cur" ]; then
                # readlink without -f to stay in sysfs
                local target
                target=$(readlink "$cur" 2>/dev/null || true)
                if [[ "$target" = /* ]]; then
                    cur="$target"
                else
                    cur="$(dirname "$cur")/$target"
                fi
            fi
            # normalise .. components crudely
            if [ -f "$cur/idVendor" ] && [ -f "$cur/idProduct" ]; then
                vid=$(cat "$cur/idVendor" 2>/dev/null | tr '[:upper:]' '[:lower:]')
                pid=$(cat "$cur/idProduct" 2>/dev/null | tr '[:upper:]' '[:lower:]')
                break
            fi
            # go one level up
            local parent
            parent=$(dirname "$cur")
            [ "$parent" = "$cur" ] && break
            cur="$parent"
            depth=$((depth+1))
            [ "$depth" -gt 12 ] && break
            # stop at /sys/devices
            if [ "$cur" = "/sys/devices" ] || [ "$cur" = "/sys" ] || [ "$cur" = "/" ]; then
                break
            fi
        done
        if [ "$vid" = "$SUPPORTED_VID" ]; then
            local match=0
            local p
            for p in "${SUPPORTED_PIDS[@]}"; do
                if [ "$pid" = "$p" ]; then match=1; break; fi
            done
            if [ "$match" = "1" ]; then
                QF_IFACE="$iface"
                QF_MAC=$(cat "$iface_path/address" 2>/dev/null || echo "")
                QF_STATE=$(cat "$iface_path/operstate" 2>/dev/null || echo "unknown")
                QF_CARRIER=$(cat "$iface_path/carrier" 2>/dev/null || echo "unknown")
                # driver via device/driver symlink
                if [ -L "$dev_path/driver" ]; then
                    QF_DRIVER=$(basename "$(readlink "$dev_path/driver" 2>/dev/null)" || echo "")
                elif [ -L "$iface_path/device/driver" ]; then
                    QF_DRIVER=$(basename "$(readlink "$iface_path/device/driver" 2>/dev/null)" || echo "")
                else
                    QF_DRIVER=$(basename "$(readlink "$iface_path/driver" 2>/dev/null)" 2>/dev/null || echo "")
                fi
                return 0
            fi
        fi
    done
    # Fallback: any enx* interface bound to qf9700 (predictable name from MAC)?
    # Only as hint, not authoritative.
    return 1
}

iface_show() {
    local iface="$1"
    [ -n "$iface" ] || return 1
    ip addr show dev "$iface" 2>&1 || ip link show "$iface" 2>&1 || true
}

# ---------- network stack detection ----------
detect_network_stack() {
    # echoes one of: NetworkManager | netplan | systemd-networkd | unknown
    if command -v nmcli >/dev/null 2>&1 && { systemctl is-active --quiet NetworkManager 2>/dev/null || pgrep -x NetworkManager >/dev/null 2>&1; }; then
        echo "NetworkManager"
    elif ls /etc/netplan/*.yaml >/dev/null 2>&1; then
        echo "netplan"
    elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        echo "systemd-networkd"
    elif command -v nmcli >/dev/null 2>&1; then
        echo "NetworkManager"
    else
        echo "unknown"
    fi
}

# ---------- backup ----------
backup_file() {
    # backup_file <absolute-path>: copies to $PROJECT_ROOT/config/backup/<ts>/...
    # also to /etc/qf9700-installer/backups/<ts>/ for system record. No-op if missing.
    local src="$1"
    [ -n "$src" ] || return 0
    if [ ! -e "$src" ]; then
        return 0
    fi
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local dest_dir="$PROJECT_ROOT/config/backup/$ts"
    mkdir -p "$dest_dir" 2>/dev/null || true
    local base
    base=$(basename "$src")
    cp -a "$src" "$dest_dir/$base" 2>/dev/null || warn "backup failed for $src"
    mkdir -p "/etc/qf9700-installer/backups/$ts" 2>/dev/null || true
    cp -a "$src" "/etc/qf9700-installer/backups/$ts/$base" 2>/dev/null || true
    ok "Backup: $src -> $dest_dir/$base"
}

marker_comment() {
    echo "# Generated by qf9700-offline-installer. Safe to delete with uninstall.sh."
}

# Network persistence paths (shared by net-config.sh and verify.sh).
# Kept here so verify.sh works without sourcing net-config.sh.
nm_connection_path() { echo "/etc/NetworkManager/system-connections/qf9700-$1.nmconnection"; }
netplan_path()       { echo "/etc/netplan/99-qf9700-$1.yaml"; }

is_ours() {
    # is_ours <file>: true if file contains our marker
    local f="$1"
    [ -f "$f" ] && grep -q "qf9700-offline-installer" "$f" 2>/dev/null
}
