#!/bin/bash
# QF9700 — offline gcc/make toolchain installer (no network).
# Usage: ./scripts/install-toolchain.sh [--force] [--dry-run] [--arch amd64|arm64]
# Installs bundled .debs from packages/toolchain-<arch>/ with dpkg only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

FORCE=0
ARCH_WANT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1; shift;;
        --dry-run) DRY_RUN=1; export DRY_RUN; shift;;
        --arch) ARCH_WANT="$2"; shift 2;;
        -h|--help)
            echo "Usage: sudo ./scripts/install-toolchain.sh [--force] [--dry-run] [--arch amd64|arm64]"
            echo "Installs offline gcc/make from packages/toolchain-<arch>/ via dpkg (no network)."
            exit 0;;
        *) shift;;
    esac
done

step "Offline toolchain (gcc/make)"
log "Project: $PROJECT_ROOT"

# Resolve arch: dpkg arch (amd64/arm64) preferred, fallback uname -m.
ARCH_DEB="${ARCH_WANT:-}"
if [ -z "$ARCH_DEB" ]; then
    if command -v dpkg >/dev/null 2>&1; then
        ARCH_DEB=$(dpkg --print-architecture 2>/dev/null || echo "")
    fi
    if [ -z "$ARCH_DEB" ]; then
        case "$(uname -m)" in
            x86_64) ARCH_DEB="amd64";;
            aarch64|arm64) ARCH_DEB="arm64";;
            *) ARCH_DEB="$(uname -m)";;
        esac
    fi
fi
log "Arch: $ARCH_DEB"

TOOL_DIR="$PROJECT_ROOT/packages/toolchain-$ARCH_DEB"
if [ ! -d "$TOOL_DIR" ]; then
    warn "No toolchain dir for arch: $TOOL_DIR"
    log "Available:"
    ls -1 "$PROJECT_ROOT/packages/" 2>/dev/null | tee -a "$LOG_FILE" || true
    if [ "$ARCH_DEB" != "amd64" ]; then
        err "Only toolchain-amd64 is bundled. On an ONLINE Ubuntu host run:"
        err "  ./prepare-offline.sh --kernel $(get_kernel) --arch $ARCH_DEB"
        err "to fetch toolchain + headers for $ARCH_DEB."
    else
        err "Toolchain dir missing (repo incomplete?). Expected $TOOL_DIR with make_*.deb gcc_*.deb."
    fi
    exit 1
fi

log "Toolchain dir: $TOOL_DIR"
ls -lh "$TOOL_DIR"/*.deb 2>/dev/null | tee -a "$LOG_FILE" || {
    err "No .deb files in $TOOL_DIR"
    exit 1
}

toolchain_functional() {
    # Authoritative health check: actually compile a temp .c file.
    # `gcc --version` alone is NOT sufficient (cc1 may fail on missing
    # libisl/libmpc while --version still prints). Proven on
    # 5.15.0-119-generic where dpkg reported optional-dep noise yet the
    # driver built (CC/MODPOST/LD) and DHCP worked.
    command -v gcc >/dev/null 2>&1 || return 1
    command -v make >/dev/null 2>&1 || return 1
    local tmpc tmpo
    tmpc="$(mktemp /tmp/.qf_gcctest.XXXXXX.c)" || return 1
    tmpo="$(mktemp /tmp/.qf_gcctest.XXXXXX)" || { rm -f "$tmpc"; return 1; }
    printf 'int main(void){return 0;}\n' >"$tmpc"
    if ! gcc "$tmpc" -o "$tmpo" >/dev/null 2>&1; then
        rm -f "$tmpc" "$tmpo"
        return 1
    fi
    rm -f "$tmpc" "$tmpo"
    return 0
}

if toolchain_functional && [ "$FORCE" = "0" ]; then
    ok "Toolchain READY (functional compile test passed, use --force to reinstall)"
    log "gcc: $(gcc --version 2>/dev/null | head -n1)"
    log "make: $(make --version 2>/dev/null | head -n1)"
    exit 0
fi
log "gcc: $(gcc --version 2>/dev/null | head -n1 || echo MISSING)"
log "make: $(make --version 2>/dev/null | head -n1 || echo MISSING)"
# dpkg status is informational only — a package may show unconfigured for an
# optional dep (e.g. sanitizer libs) while the compiler is fully functional.
# Never gate on it; the functional test above is authoritative.
if command -v dpkg >/dev/null 2>&1; then
    dpkg -s gcc-11 cpp-11 2>/dev/null | grep -E "^(Package|Status):" | tee -a "$LOG_FILE" || true
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] would run: dpkg -i $TOOL_DIR/*.deb (ordered, no network)"
    exit 0
fi

require_root
command -v dpkg >/dev/null 2>&1 || die "dpkg not found, cannot install offline toolchain."

# Install in dependency order. REQUIRED = needed for `CC [M] qf9700.o`
# (proven on 5.15.0-119-generic). OPTIONAL = GDB plugin / sanitizer runtimes
# that dpkg may complain about but the kernel build never links; they must
# never fail the install and never downgrade system packages.
# NOTE: libcc1-0 (GCC 12) and libgcc-11-dev (sanitizer chain) were removed
# from the curated bundle because the functional build succeeds without
# them; if they ever reappear (manual drop / old bundle) they stay OPTIONAL.
info "Installing offline toolchain with dpkg (no network)..."
set +e
REQUIRED_PATTERNS="gcc-11-base_*.deb libisl*.deb libmpc*.deb libmpfr*.deb libgmp*.deb binutils*.deb libc6-dev*.deb linux-libc-dev*.deb cpp-11_*.deb gcc-11_*.deb cpp_*.deb gcc_*.deb make_*.deb"
OPTIONAL_PATTERNS="libcc1-*.deb libgcc-*-dev_*.deb libgomp*.deb libitm*.deb libatomic*.deb libasan*.deb liblsan*.deb libtsan*.deb libubsan*.deb libquadmath*.deb"
REQUIRED=""
for pat in $REQUIRED_PATTERNS; do
    for f in "$TOOL_DIR"/$pat; do
        [ -f "$f" ] || continue
        case " $REQUIRED " in *" $f "*) continue;; esac
        REQUIRED="$REQUIRED $f"
    done
done
OPTIONAL=""
for pat in $OPTIONAL_PATTERNS; do
    for f in "$TOOL_DIR"/$pat; do
        [ -f "$f" ] || continue
        case " $REQUIRED " in *" $f "*) continue;; esac
        case " $OPTIONAL " in *" $f "*) continue;; esac
        OPTIONAL="$OPTIONAL $f"
    done
done
# Any other bundled deb not matched above is treated as REQUIRED-adjacent
# (appended) so nothing bundled is silently skipped; OPTIONAL stays explicit.
for f in "$TOOL_DIR"/*.deb; do
    [ -f "$f" ] || continue
    case " $REQUIRED $OPTIONAL " in *" $f "*) continue;; esac
    REQUIRED="$REQUIRED $f"
done
ORDERED="$REQUIRED $OPTIONAL"
log "Install order (required first):"
for f in $REQUIRED; do log "  - REQUIRED $(basename "$f")"; done
for f in $OPTIONAL; do log "  - OPTIONAL $(basename "$f") (best-effort, never fatal)"; done

RC_REQ=0
if [ -n "$REQUIRED" ]; then
    # shellcheck disable=SC2086
    dpkg -i $REQUIRED 2>&1 | tee -a "$LOG_FILE"
    RC_REQ=${PIPESTATUS[0]:-0}
    if [ "$RC_REQ" -ne 0 ]; then
        warn "Required dpkg pass reported issues, retrying once..."
        # shellcheck disable=SC2086
        dpkg -i $REQUIRED 2>&1 | tee -a "$LOG_FILE"
        RC_REQ=${PIPESTATUS[0]:-0}
    fi
else
    warn "No REQUIRED toolchain debs found in $TOOL_DIR"
fi
# OPTIONAL phase: always best-effort, never touches RC_REQ, never removes.
if [ -n "$OPTIONAL" ]; then
    warn "Installing $(echo "$OPTIONAL" | wc -w) optional package(s) best-effort (failures here are non-fatal)..."
    # shellcheck disable=SC2086
    dpkg -i $OPTIONAL 2>&1 | tee -a "$LOG_FILE" || {
        warn "Optional packages left unconfigured (expected on minimal targets) — continuing, compiler test is authoritative."
    }
fi
set -e

# Disposition: functional test decides. dpkg noise for unneeded packages
# must not fail a working compiler.
if toolchain_functional; then
    if [ "$RC_REQ" -ne 0 ]; then
        warn "dpkg reported issues for optional/redundant packages, but the compiler functional test PASSED — treating toolchain as READY."
    fi
else
    err "Toolchain NOT functional after dpkg. This is fatal for the driver build."
    err "Present .debs:"
    ls -1 "$TOOL_DIR"/*.deb >&2 || true
    err "Diagnostics: gcc --version ; echo 'int main(void){return 0;}' > /tmp/t.c && gcc /tmp/t.c -o /tmp/t && rm /tmp/t /tmp/t.c ; ldd /usr/lib/gcc/x86_64-linux-gnu/11/cc1 2>&1 | grep 'not found' ; dpkg -s gcc-11 cpp-11 2>&1 | grep -E '^(Package|Status)'"
    err "Fix (online host): ./prepare-offline.sh --kernel $(get_kernel) --arch $ARCH_DEB  # fetches consistent closure"
    exit 1
fi

ok "Toolchain READY: $(gcc --version | head -n1), $(make --version | head -n1)"
