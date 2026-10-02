#!/bin/bash
# QF9700 — persistent network configuration (Ubuntu 22.04 native).
# Usage:
#   sudo ./configure.sh                  # interactive menu
#   sudo ./configure.sh --dhcp [iface]   # non-interactive DHCP
#   sudo ./configure.sh --static <iface> <ip> <prefix> <gw> <dns1> [dns2]
#   sudo ./configure.sh --show [iface]
#   sudo ./configure.sh --test [iface]
# Permanent: NetworkManager .nmconnection or netplan yaml (never `ip addr add` only).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/net-config.sh"

usage() {
    cat <<'EOF'
Usage: sudo ./configure.sh [OPTION]
  (no args)                          interactive menu
  --dhcp [IFACE]                     configure DHCP (iface auto-detected if omitted)
  --static IFACE IP PREFIX GW DNS1 [DNS2]   configure static IP (PREFIX 0-32, e.g. 24)
  --show [IFACE]                     show current configuration
  --test [IFACE]                     test connectivity (ping gateway + 8.8.8.8)
  -h, --help                         this help
Examples:
  sudo ./configure.sh --dhcp enx001122334455
  sudo ./configure.sh --static enx001122334455 192.168.1.50 24 192.168.1.1 1.1.1.1 8.8.8.8
EOF
}

resolve_iface() {
    local want="${1:-}"
    if [ -n "$want" ]; then echo "$want"; return 0; fi
    if find_qf_iface; then echo "$QF_IFACE"; return 0; fi
    # fallback: single enx* interface?
    local enx
    enx=$(ls -1 /sys/class/net/ 2>/dev/null | grep -E "^enx" | head -n 1 || true)
    if [ -n "$enx" ]; then echo "$enx"; return 0; fi
    err "Cannot determine interface. Plug adapter and run: sudo ./detect.sh"
    err "Or pass explicitly: sudo ./configure.sh --dhcp <iface>"
    return 1
}

do_test() {
    local iface="$1"
    header "Test connection: $iface"
    iface_show "$iface" || true
    local gw
    gw=$(ip route show dev "$iface" 2>/dev/null | grep -oP 'default via \K[\d.]+' | head -n1 || true)
    # fallback: default route via any dev
    [ -z "$gw" ] && gw=$(ip route show default 2>/dev/null | grep -oP 'via \K[\d.]+' | head -n1 || true)
    local rc=0
    if [ -n "$gw" ]; then
        info "Ping gateway $gw via $iface (3x)..."
        if ping -c 3 -W 2 -I "$iface" "$gw" 2>&1 | tee -a "$LOG_FILE"; then ok "Gateway reachable"; else warn "Gateway unreachable"; rc=1; fi
    else
        warn "No default gateway found (DHCP may have failed)"
        rc=1
    fi
    info "Ping 8.8.8.8 via $iface (3x)..."
    if ping -c 3 -W 2 -I "$iface" 8.8.8.8 2>&1 | tee -a "$LOG_FILE"; then ok "Internet reachable via $iface"; else warn "8.8.8.8 unreachable (no internet / routing)"; rc=1; fi
    info "DNS check (getent hosts google.com)..."
    if getent hosts google.com >/dev/null 2>&1; then ok "DNS works"; else warn "DNS failed (check /etc/resolv.conf / nameservers)"; rc=1; fi
    return $rc
}

interactive() {
    local iface
    iface=$(resolve_iface "${1:-}") || exit 1
    info "QF9700 interface: $iface"
    info "Stack: $(detect_network_stack)"
    while true; do
        echo ""
        echo "===================================="
        echo "QF9700 Network Configuration"
        echo "===================================="
        echo "Interface: $iface"
        echo "1. DHCP"
        echo "2. Static IP"
        echo "3. Show current configuration"
        echo "4. Test connection"
        echo "5. Exit"
        echo -n "Choose [1-5]: "
        read -r choice
        case "$choice" in
            1)
                apply_dhcp "$iface"
                ok "DHCP configured (permanent, survives reboot)"
                show_current "$iface" || true
                ;;
            2)
                echo -n "IP Address (e.g. 192.168.1.50): "; read -r ip
                echo -n "Prefix / Netmask (e.g. 24 or 255.255.255.0): "; read -r prefix
                prefix=$(prefix_from_netmask "$prefix")
                echo -n "Gateway (e.g. 192.168.1.1, empty if none): "; read -r gw
                echo -n "DNS 1 (e.g. 1.1.1.1): "; read -r dns1
                echo -n "DNS 2 (e.g. 8.8.8.8, empty if none): "; read -r dns2
                if apply_static "$iface" "$ip" "$prefix" "$gw" "$dns1" "$dns2"; then
                    ok "Static IP configured (permanent, survives reboot)"
                    show_current "$iface" || true
                else
                    err "Static configuration failed (check values above)"
                fi
                ;;
            3) show_current "$iface" || true;;
            4) do_test "$iface" || true;;
            5) log "Bye."; exit 0;;
            *) warn "Invalid choice: $choice";;
        esac
    done
}

# ---------- main ----------
if [ $# -eq 0 ]; then
    require_root
    interactive ""
    exit 0
fi

case "${1:-}" in
    -h|--help) usage; exit 0;;
    --dhcp)
        require_root
        IFACE=$(resolve_iface "${2:-}") || exit 1
        apply_dhcp "$IFACE"
        ok "DHCP configured for $IFACE (permanent)"
        show_current "$IFACE" || true
        ;;
    --static)
        require_root
        [ $# -ge 6 ] || { usage >&2; die "--static needs: IFACE IP PREFIX GW DNS1 [DNS2]"; }
        IFACE="$2"; IP="$3"; PREFIX="$(prefix_from_netmask "$4")"; GW="$5"; DNS1="$6"; DNS2="${7:-}"
        apply_static "$IFACE" "$IP" "$PREFIX" "$GW" "$DNS1" "$DNS2"
        ok "Static $IP/$PREFIX configured for $IFACE (permanent)"
        show_current "$IFACE" || true
        ;;
    --show)
        resolve_iface_to_show="${2:-}"
        IFACE=$(resolve_iface "$resolve_iface_to_show") || exit 1
        show_current "$IFACE"
        ;;
    --test)
        require_root
        IFACE=$(resolve_iface "${2:-}") || exit 1
        do_test "$IFACE"
        ;;
    *) usage >&2; die "Unknown option: $1";;
esac
