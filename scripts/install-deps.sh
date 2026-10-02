#!/bin/bash
# QF9700 — offline dependency check + install (no network).
# Usage: ./scripts/install-deps.sh [--dry-run]
# Never runs `apt install`, `curl`, `wget` or `git clone`.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

DRY_RUN="${DRY_RUN:-0}"
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; fi

step "Dependency check (offline)"
log "Project: $PROJECT_ROOT"
log "Kernel: $(get_kernel)  Arch: $(get_arch)"

# 1. OS / kernel / arch info (never fatal here; install.sh decides)
check_ubuntu || true
log "Architecture: $(get_arch)"
log "Kernel: $(get_kernel)"
log "gcc: $(gcc --version 2>/dev/null | head -n1 || echo MISSING)"
log "make: $(make --version 2>/dev/null | head -n1 || echo MISSING)"

# 2. Toolchain: delegate to install-toolchain.sh (idempotent).
# It runs a functional compile test (temp .c, gcc, exit 0, cleanup) and
# skips reinstall when READY, so reruns are cheap. Never uses network,
# never removes/downgrades system packages.
if [ -x "$PROJECT_ROOT/scripts/install-toolchain.sh" ]; then
    "$PROJECT_ROOT/scripts/install-toolchain.sh" || die "Offline toolchain not functional. See above (dpkg fatal only when compiler test fails)."
else
    install_local_debs || true
    command -v gcc >/dev/null 2>&1 || die "gcc still missing after offline install. Check packages/toolchain-*/ (amd64 bundled, arm64 via prepare-offline.sh)."
    command -v make >/dev/null 2>&1 || die "make still missing after offline install. Check packages/toolchain-*/."
fi
log "gcc: $(gcc --version 2>/dev/null | head -n1 || echo MISSING)"
log "make: $(make --version 2>/dev/null | head -n1 || echo MISSING)"

# 3. Headers must exist; if not, try local packages, else clear error.
KVER="$(get_kernel)"
if ! check_headers "$KVER"; then
    warn "Trying bundled packages before giving up..."
    install_local_debs || true
    if ! check_headers "$KVER"; then
        err ""
        err "ERROR: Kernel headers for $KVER are not available in offline bundle."
        if ls "$PROJECT_ROOT"/packages/*.deb >/dev/null 2>&1 || ls "$PROJECT_ROOT"/packages/toolchain-*/*.deb >/dev/null 2>&1; then
            err "Available bundled packages:"
            list_local_debs | sed 's/^/  - /' >&2 || true
        else
            err "No packages bundled (packages/ is empty)."
        fi
        err ""
        err "Fix: on an ONLINE host run:"
        err "  ./prepare-offline.sh --kernel $KVER --arch $(get_arch)"
        err "then copy dist/ folder to this machine via USB."
        err "Note: gcc/make are already bundled in packages/toolchain-*/; only kernel headers are kernel-specific."
        err "Diagnostics: uname -r ; ls /lib/modules/ ; ls /usr/src/ ; ls packages/ packages/toolchain-*/"
        exit 1
    fi
fi

check_tools strict

# 5. Install remaining bundled debs (headers, dkms, ...) — offline only.
install_local_debs

ok "Dependencies OK (offline, no network used)"
