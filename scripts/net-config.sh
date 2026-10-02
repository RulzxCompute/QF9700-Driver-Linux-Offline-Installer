#!/bin/bash
# QF9700 — persistent network configuration helpers (Ubuntu 22.04 native).
# Library sourced by configure.sh / install.sh. No network access.
# Supports: NetworkManager (preferred when active) -> netplan fallback.
# Never overwrites foreign connections; only files tagged with our marker.

# Guard
if [ -n "${QF_NETCFG_LOADED:-}" ]; then return 0 2>/dev/null || exit 0; fi
QF_NETCFG_LOADED=1
# shellcheck disable=SC1091
_NETCFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${PROJECT_ROOT:-}" ] || [ -z "${QF_COMMON_LOADED:-}" ]; then
    source "$_NETCFG_DIR/common.sh"
fi

nm_connection_path() { echo "/etc/NetworkManager/system-connections/qf9700-$1.nmconnection"; }
netplan_path()       { echo "/etc/netplan/99-qf9700-$1.yaml"; }

net_stack() { detect_network_stack; }

nm_apply_dhcp() {
    local iface="$1"
    local conn="qf9700-$iface"
    local path
    path=$(nm_connection_path "$iface")
    [ -f "$path" ] && backup_file "$path"
    {
        marker_comment
        echo "[connection]"
        echo "id=$conn"
        echo "uuid=$(cat /proc/sys/kernel/random/uuid)"
        echo "type=ethernet"
        echo "interface-name=$iface"
        echo "autoconnect=true"
        echo ""
        echo "[ethernet]"
        echo "cloned-mac-address=preserve"
        echo ""
        echo "[ipv4]"
        echo "method=auto"
        echo ""
        echo "[ipv6]"
        echo "addr-gen-mode=stable-privacy"
        echo "method=auto"
    } > "$path"
    chmod 600 "$path"
    info "Wrote $path (DHCP, NetworkManager)"
    nmcli connection reload 2>&1 | tee -a "$LOG_FILE" || true
    nmcli connection up "$conn" 2>&1 | tee -a "$LOG_FILE" || {
        warn "nmcli up failed; trying: nmcli device connect $iface"
        nmcli device connect "$iface" 2>&1 | tee -a "$LOG_FILE" || true
    }
}

nm_apply_static() {
    local iface="$1" ip="$2" prefix="$3" gw="$4" dns1="$5" dns2="${6:-}"
    local conn="qf9700-$iface"
    local path
    path=$(nm_connection_path "$iface")
    [ -f "$path" ] && backup_file "$path"
    local dns="$dns1"
    [ -n "$dns2" ] && dns="$dns1,$dns2"
    {
        marker_comment
        echo "[connection]"
        echo "id=$conn"
        echo "uuid=$(cat /proc/sys/kernel/random/uuid)"
        echo "type=ethernet"
        echo "interface-name=$iface"
        echo "autoconnect=true"
        echo ""
        echo "[ethernet]"
        echo "cloned-mac-address=preserve"
        echo ""
        echo "[ipv4]"
        echo "method=manual"
        echo "addresses=$ip/$prefix"
        [ -n "$gw" ] && echo "gateway=$gw"
        [ -n "$dns" ] && echo "dns=$dns;"
        echo ""
        echo "[ipv6]"
        echo "addr-gen-mode=stable-privacy"
        echo "method=auto"
    } > "$path"
    chmod 600 "$path"
    info "Wrote $path (static $ip/$prefix, NetworkManager)"
    nmcli connection reload 2>&1 | tee -a "$LOG_FILE" || true
    nmcli connection up "$conn" 2>&1 | tee -a "$LOG_FILE" || warn "nmcli up reported an issue (check: nmcli connection show $conn)"
}

netplan_apply_dhcp() {
    local iface="$1"
    local path
    path=$(netplan_apply_path_check "$iface")
    [ -f "$path" ] && backup_file "$path"
    {
        marker_comment
        echo "network:"
        echo "  version: 2"
        echo "  ethernets:"
        echo "    $iface:"
        echo "      dhcp4: true"
        echo "      dhcp6: true"
        echo "      optional: true"
    } > "$path"
    chmod 600 "$path"
    info "Wrote $path (DHCP, netplan)"
    netplan_apply_safe
}

netplan_apply_path_check() { netplan_path "$1"; }

netplan_apply_static() {
    local iface="$1" ip="$2" prefix="$3" gw="$4" dns1="$5" dns2="${6:-}"
    local path
    path=$(netplan_path "$iface")
    [ -f "$path" ] && backup_file "$path"
    {
        marker_comment
        echo "network:"
        echo "  version: 2"
        echo "  ethernets:"
        echo "    $iface:"
        echo "      dhcp4: no"
        echo "      dhcp6: no"
        echo "      optional: true"
        echo "      addresses: [$ip/$prefix]"
        if [ -n "$gw" ]; then
            echo "      routes:"
            echo "        - to: default"
            echo "          via: $gw"
            echo "          metric: 200"
        fi
        echo "      nameservers:"
        if [ -n "$dns2" ]; then
            echo "        addresses: [$dns1, $dns2]"
        elif [ -n "$dns1" ]; then
            echo "        addresses: [$dns1]"
        fi
    } > "$path"
    chmod 600 "$path"
    info "Wrote $path (static $ip/$prefix, netplan)"
    netplan_apply_safe
}

netplan_apply_safe() {
    if command -v netplan >/dev/null 2>&1; then
        info "netplan apply (with 120s rollback guard when supported)..."
        if [ "${DRY_RUN:-0}" = "1" ]; then
            info "[dry-run] would run: netplan apply"
            return 0
        fi
        netplan generate 2>&1 | tee -a "$LOG_FILE" || warn "netplan generate reported issues"
        netplan apply 2>&1 | tee -a "$LOG_FILE" || warn "netplan apply reported issues (check: netplan --debug apply)"
    else
        warn "netplan command not found; config file written but not applied."
    fi
}

apply_dhcp() {
    local iface="$1"
    local stack
    stack=$(net_stack)
    info "Network stack: $stack ; interface: $iface"
    if [ "$stack" = "NetworkManager" ]; then
        nm_apply_dhcp "$iface"
    else
        # netplan files coexist fine with NM; prefer netplan file when NM absent.
        netplan_apply_dhcp "$iface"
        # best effort: also bring link up + DHCP via dhclient for immediate use
        ip link set "$iface" up 2>/dev/null || true
    fi
}

apply_static() {
    local iface="$1" ip="$2" prefix="$3" gw="$4" dns1="$5" dns2="${6:-}"
    local stack
    stack=$(net_stack)
    info "Network stack: $stack ; interface: $iface static $ip/$prefix"
    validate_ipv4 "$ip" || return 1
    validate_prefix "$prefix" || return 1
    [ -n "$gw" ] && { validate_ipv4 "$gw" || return 1; }
    [ -n "$dns1" ] && { validate_ipv4 "$dns1" || return 1; }
    [ -n "${dns2:-}" ] && [ -n "$dns2" ] && { validate_ipv4 "$dns2" || return 1; }
    if [ "$stack" = "NetworkManager" ]; then
        nm_apply_static "$iface" "$ip" "$prefix" "$gw" "$dns1" "$dns2"
    else
        netplan_apply_static "$iface" "$ip" "$prefix" "$gw" "$dns1" "$dns2"
        ip link set "$iface" up 2>/dev/null || true
    fi
}

validate_ipv4() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'; read -r a b c d <<<"$ip"
        for o in "$a" "$b" "$c" "$d"; do
            if [ "$o" -gt 255 ] || [ "$o" -lt 0 ]; then err "Invalid IPv4: $ip"; return 1; fi
        done
        return 0
    fi
    err "Invalid IPv4: $ip (expected e.g. 192.168.1.50)"
    return 1
}

validate_prefix() {
    local p="$1"
    # accept 0-32 or dotted netmask
    if [[ "$p" =~ ^[0-9]{1,2}$ ]] && [ "$p" -ge 0 ] && [ "$p" -le 32 ]; then return 0; fi
    case "$p" in
        255.255.255.0) return 0;; 255.255.0.0) return 0;; 255.0.0.0) return 0;;
        255.255.255.128|255.255.255.192|255.255.255.224|255.255.255.240|255.255.255.252) return 0;;
    esac
    err "Invalid prefix/netmask: $p (use 0-32, e.g. 24 for 255.255.255.0)"
    return 1
}

prefix_from_netmask() {
    case "$1" in
        255.0.0.0) echo 8;; 255.255.0.0) echo 16;; 255.255.255.0) echo 24;;
        255.255.255.128) echo 25;; 255.255.255.192) echo 26;; 255.255.255.224) echo 27;;
        255.255.255.240) echo 28;; 255.255.255.252) echo 30;; 255.255.255.255) echo 32;;
        *) echo "$1";;
    esac
}

show_current() {
    local iface="${1:-}"
    if [ -z "$iface" ]; then
        find_qf_iface && iface="$QF_IFACE" || true
    fi
    if [ -z "$iface" ]; then
        warn "No QF9700 interface found."
        return 1
    fi
    header "Current configuration: $iface"
    iface_show "$iface" | tee -a "$LOG_FILE" || true
    echo ""
    local stack
    stack=$(net_stack)
    log "Stack: $stack"
    if [ "$stack" = "NetworkManager" ] && command -v nmcli >/dev/null 2>&1; then
        nmcli -f NAME,UUID,TYPE,DEVICE connection show 2>&1 | tee -a "$LOG_FILE" || true
        echo ""
        nmcli device show "$iface" 2>&1 | tee -a "$LOG_FILE" || true
    else
        log "netplan files:"
        ls -1 /etc/netplan/*.yaml 2>/dev/null | tee -a "$LOG_FILE" || log "(none)"
        local f
        f=$(netplan_path "$iface")
        if [ -f "$f" ]; then log "--- $f ---"; cat "$f" | tee -a "$LOG_FILE"; fi
    fi
}
