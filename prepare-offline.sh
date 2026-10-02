#!/bin/bash
# QF9700 — build the OFFLINE bundle on an ONLINE host (Ubuntu recommended).
# This script NEEDS internet. The resulting dist/qf9700-offline-installer/
# must be fully installable OFFLINE via USB stick.
#
# Usage:
#   ./prepare-offline.sh [--kernel 5.15.0-91-generic] [--arch amd64]
#                        [--ubuntu jammy] [--output dist] [--no-apt]
# Examples:
#   ./prepare-offline.sh --kernel 5.15.0-91-generic
#   ./prepare-offline.sh --kernel $(uname -r)
#   apt-cache search linux-headers-5.15 | grep generic   # find valid kernel names
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

TARGET_KERNEL=""
TARGET_ARCH=""
UBUNTU_CODENAME="jammy"
OUTPUT_BASE="dist"
NO_APT=0

usage() {
    cat <<'EOF'
Usage: ./prepare-offline.sh [OPTIONS]   (run on ONLINE host)

  --kernel <ver>    target kernel, e.g. 5.15.0-91-generic (default: host uname -r)
  --arch <arch>     target arch, e.g. amd64, arm64 (default: host dpkg arch)
  --ubuntu <name>   jammy (Ubuntu 22.04). Only jammy is supported.
  --output <dir>    output base (default: dist). Bundle -> <dir>/qf9700-offline-installer/
  --no-apt          skip .deb download (driver-only bundle)
  -h, --help        this help

What it does:
  1. Verifies driver source in driver/qf9700/
  2. Downloads .debs (headers + build tools + dkms) into packages/
  3. Writes packages/MANIFEST.txt + SOURCES.txt
  4. Copies self-contained bundle to dist/qf9700-offline-installer/

Copy that folder to USB, then on OFFLINE target: sudo ./install.sh
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --kernel) TARGET_KERNEL="$2"; shift 2;;
        --arch) TARGET_ARCH="$2"; shift 2;;
        --ubuntu) UBUNTU_CODENAME="$2"; shift 2;;
        --output) OUTPUT_BASE="$2"; shift 2;;
        --no-apt) NO_APT=1; shift;;
        -h|--help) usage; exit 0;;
        *) echo "Unknown: $1" >&2; usage >&2; exit 1;;
    esac
done

if [ -z "$TARGET_KERNEL" ]; then TARGET_KERNEL="$(uname -r)"; fi
if [ -z "$TARGET_ARCH" ]; then
    TARGET_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
fi

echo "===================================="
echo "QF9700 prepare-offline"
echo "===================================="
echo "Target kernel : $TARGET_KERNEL"
echo "Target arch   : $TARGET_ARCH"
echo "Ubuntu        : $UBUNTU_CODENAME"
echo "Output        : $OUTPUT_BASE/qf9700-offline-installer/"
echo ""

# 1. Driver source check (already vendored; never git-clone at install time)
if [ ! -f "$PROJECT_ROOT/driver/qf9700/qf9700.c" ]; then
    echo "ERROR: driver/qf9700/qf9700.c missing." >&2
    echo "Upstream: https://github.com/pgquiles/qf9700 (vendored, see driver/qf9700/README.source)" >&2
    exit 1
fi
echo "Driver source OK: driver/qf9700/ ($(wc -l <"$PROJECT_ROOT/driver/qf9700/qf9700.c") lines qf9700.c)"
grep -q "0fe6" "$PROJECT_ROOT/driver/qf9700/qf9700.c" || { echo "ERROR: driver lacks 0fe6 IDs?" >&2; exit 1; }
echo "Driver claims 0fe6:9700 + 0fe6:9702 (interface 1)."

# Derive base ABI: 5.15.0-91-generic -> 5.15.0-91
BASE="${TARGET_KERNEL%-generic}"
BASE="${BASE%-lowlatency}"
echo "Headers base : $BASE"

if [ "$NO_APT" = "1" ]; then
    echo "--no-apt: skipping .deb download."
else
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "ERROR: apt-get not found. Run this on Ubuntu 22.04 with internet." >&2
        echo "Manual fallback: download these .debs from http://archive.ubuntu.com/ubuntu/pool/ :" >&2
        echo "  linux-headers-${BASE}_${BASE}*_all.deb" >&2
        echo "  linux-headers-${TARGET_KERNEL}_*_${TARGET_ARCH}.deb" >&2
        echo "  build-essential, gcc, make, dkms + deps for $TARGET_ARCH" >&2
        exit 1
    fi
    if [ "$UBUNTU_CODENAME" != "jammy" ]; then
        echo "ERROR: only --ubuntu jammy supported (Ubuntu 22.04 target)." >&2
        exit 1
    fi
    echo ""
    echo "Updating apt lists (needs internet)..."
    sudo apt-get update

    PKG_TMP="$PROJECT_ROOT/packages/.dl-tmp"
    mkdir -p "$PKG_TMP" "$PROJECT_ROOT/packages"
    rm -f "$PKG_TMP"/*.deb

    # Curated closure (proven on 5.15.0-119-generic, CC/MODPOST/LD + DHCP OK):
    # headers + dkms + usbutils only. Toolchain (gcc/make + cc1 runtime libs)
    # is curated in packages/toolchain-<arch>/ and must NOT be re-resolved
    # here: a naive `apt-cache depends --recurse` on the toolchain pulls the
    # conflicting GCC 11 + GCC 12 mix (libcc1-0 -> gcc-12-base) and the full
    # sanitizer chain of libgcc-11-dev (libgomp1/libitm1/libatomic1/libasan6/
    # liblsan0/libtsan0/libubsan1/libquadmath0) that the kernel build never
    # links. Those two were removed from the bundle after proving the build
    # succeeds without them; the functional compile test is authoritative.
    WANT=(
        "linux-headers-${BASE}"
        "linux-headers-${TARGET_KERNEL}"
        "dkms"
        "usbutils"
    )
    # Packages that must never enter the offline bundle (version-skew noise,
    # proven unnecessary for `CC [M] qf9700.o`). Matched by exact package name
    # from `apt-cache depends` output.
    DENYLIST="libcc1-0 libgcc-11-dev libgcc-12-dev libgomp1 libitm1 libatomic1 libasan6 libasan8 liblsan0 libtsan0 libubsan1 libquadmath0"
    if ! ls "$PROJECT_ROOT"/packages/toolchain-*/*.deb >/dev/null 2>&1; then
        WANT+=("build-essential" "gcc" "make")
    else
        echo "Toolchain already bundled in packages/toolchain-*/ — skipping gcc/make re-download."
        echo "(Delete packages/toolchain-*/*.deb to force full re-fetch.)"
    fi
    echo "Downloading (apt download, no install): ${WANT[*]}"
    pushd "$PKG_TMP" >/dev/null
    MISSING=()
    for p in "${WANT[@]}"; do
        echo "--- $p ---"
        if apt download "$p" 2>&1 | tail -n 3; then
            echo "OK: $p"
        else
            echo "WARN: apt download $p failed (will try deps anyway)"
            MISSING+=("$p")
        fi
    done
    # Pull dependencies for WANT only (headers/dkms/usbutils) — never recurse
    # into the curated toolchain. Denied packages are skipped silently.
    echo ""
    echo "Resolving dependencies (apt-cache depends, download-only)..."
    if command -v apt-cache >/dev/null 2>&1; then
        DEPS=$(apt-cache depends --recurse --no-recommends --no-suggests \
            --no-conflicts --no-breaks --no-replaces --no-enhances \
            "${WANT[@]}" 2>/dev/null | grep -oP '^\s*Depends:\s*\K[^\s<>]+' | sort -u || true)
        for d in $DEPS; do
            case " $DENYLIST " in *" $d "*) continue;; esac
            # Best effort: fetch missing dependency .debs (ignore failures).
            # Skip if a file for this package already exists (top-level or toolchain).
            if ls ./"${d}"_*.deb >/dev/null 2>&1; then
                continue
            fi
            if ls "$PROJECT_ROOT"/packages/"${d}"_*.deb >/dev/null 2>&1 || ls "$PROJECT_ROOT"/packages/toolchain-*/"${d}"_*.deb >/dev/null 2>&1; then
                continue
            fi
            apt download "$d" >/dev/null 2>&1 || true
        done
    fi
    popd >/dev/null

    echo ""
    echo "Collected .debs:"
    ls -lh "$PKG_TMP"/*.deb 2>/dev/null || { echo "ERROR: no .debs downloaded. Check kernel name with: apt-cache search linux-headers | grep $BASE" >&2; exit 1; }
    # Move into packages/ (keep existing + dedupe by name)
    for f in "$PKG_TMP"/*.deb; do
        [ -f "$f" ] || continue
        cp -n "$f" "$PROJECT_ROOT/packages/" 2>/dev/null || cp "$f" "$PROJECT_ROOT/packages/"
    done
    rm -rf "$PKG_TMP"
    echo ""
    echo "packages/ now contains:"
    ls -1 "$PROJECT_ROOT/packages"/*.deb

    # Verify headers for TARGET kernel are present
    if ls "$PROJECT_ROOT/packages"/linux-headers-*"$TARGET_KERNEL"*deb >/dev/null 2>&1 || \
       ls "$PROJECT_ROOT/packages"/linux-headers-*"$BASE"*deb >/dev/null 2>&1; then
        echo "Headers for $TARGET_KERNEL bundled."
    else
        echo "WARNING: no linux-headers .deb matching $TARGET_KERNEL in packages/." >&2
        echo "Available:" >&2
        ls "$PROJECT_ROOT/packages"/*.deb >&2
        echo "Hint: apt-cache search linux-headers | grep ${BASE}" >&2
        echo "Re-run with correct --kernel. Continuing anyway (bundle incomplete)." >&2
    fi
fi

# 2. Manifests (top-level + curated toolchain subdirs; toolchain has its own
# MANIFEST.txt too and is never re-resolved here)
echo ""
echo "Writing manifests..."
{
    echo "# QF9700 offline packages manifest"
    echo "# target kernel: $TARGET_KERNEL"
    echo "# target arch: $TARGET_ARCH"
    echo "# built: $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(hostname) $(uname -r)"
    echo "# note: toolchain/*.deb curated separately (see packages/toolchain-*/MANIFEST.txt),"
    echo "#   excluded: libcc1-0, libgcc-*-dev + sanitizer chain (proven unnecessary for kernel build)"
    echo ""
    for f in "$PROJECT_ROOT"/packages/*.deb "$PROJECT_ROOT"/packages/toolchain-*/*.deb; do
        [ -f "$f" ] || continue
        rel="${f#$PROJECT_ROOT/packages/}"
        # dpkg-deb may be missing on non-debian hosts; degrade gracefully
        if command -v dpkg-deb >/dev/null 2>&1; then
            pkg=$(dpkg-deb -f "$f" Package 2>/dev/null || echo "?")
            ver=$(dpkg-deb -f "$f" Version 2>/dev/null || echo "?")
            arch=$(dpkg-deb -f "$f" Architecture 2>/dev/null || echo "?")
            echo "$rel  Package=$pkg Version=$ver Arch=$arch  sha256=$(sha256sum "$f" | awk '{print $1}')"
        else
            echo "$rel  sha256=$(sha256sum "$f" | awk '{print $1}')"
        fi
    done
} > "$PROJECT_ROOT/packages/MANIFEST.txt"
{
    echo "QF9700 offline bundle sources"
    echo "=============================="
    echo "target kernel : $TARGET_KERNEL"
    echo "target arch   : $TARGET_ARCH"
    echo "ubuntu        : $UBUNTU_CODENAME (jammy)"
    echo "built         : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "builder       : $(hostname) $(uname -a)"
    echo ""
    echo "driver upstream: https://github.com/pgquiles/qf9700"
    echo "driver patches : see driver/qf9700/README.source"
    echo ""
    echo "deb provenance : apt download on Ubuntu $UBUNTU_CODENAME ($TARGET_ARCH)"
    echo "  + curated toolchain packages/toolchain-*/ (gcc/make closure proven on 5.15.0-119-generic)"
    echo "  + denylist (never bundled): libcc1-0 libgcc-*-dev libgomp1 libitm1 libatomic1 libasan* liblsan* libtsan* libubsan* libquadmath*"
    echo "install method : dpkg -i packages/*.deb packages/toolchain-*/*.deb (no network on target)"
    echo "health gate    : temp .c compile test (authoritative); dpkg noise for unneeded pkgs is WARN-only"
} > "$PROJECT_ROOT/packages/SOURCES.txt"
cat "$PROJECT_ROOT/packages/MANIFEST.txt"

# 3. Self-contained dist copy
DIST="$PROJECT_ROOT/$OUTPUT_BASE/qf9700-offline-installer"
echo ""
echo "Assembling self-contained bundle: $DIST"
rm -rf "$DIST"
mkdir -p "$DIST"
cp -a "$PROJECT_ROOT/install.sh" "$PROJECT_ROOT/uninstall.sh" "$PROJECT_ROOT/detect.sh" \
      "$PROJECT_ROOT/configure.sh" "$PROJECT_ROOT/prepare-offline.sh" "$DIST"/ 2>/dev/null || true
# top-level helpers if present
for f in README.md LICENSE VERSION; do
    [ -f "$PROJECT_ROOT/$f" ] && cp -a "$PROJECT_ROOT/$f" "$DIST"/
done
# bundle README: prefer local README.md (installer docs live there)
if [ -f "$PROJECT_ROOT/README.md" ]; then
    cp -a "$PROJECT_ROOT/README.md" "$DIST/README.md"
fi
mkdir -p "$DIST/driver" "$DIST/packages" "$DIST/scripts" "$DIST/config" "$DIST/logs"
cp -a "$PROJECT_ROOT/driver/qf9700" "$DIST/driver/"
cp -a "$PROJECT_ROOT/packages/." "$DIST/packages/"
rm -rf "$DIST/packages/.dl-tmp"
cp -a "$PROJECT_ROOT/scripts/." "$DIST/scripts/"
cp -a "$PROJECT_ROOT/config/." "$DIST/config/"
mkdir -p "$DIST/logs" "$DIST/config/backup"
touch "$DIST/logs/.gitkeep" "$DIST/config/backup/.gitkeep" 2>/dev/null || true
chmod +x "$DIST/install.sh" "$DIST/uninstall.sh" "$DIST/detect.sh" "$DIST/configure.sh" \
         "$DIST/prepare-offline.sh" "$DIST/scripts/"*.sh 2>/dev/null || true

echo ""
echo "Bundle ready: $DIST"
du -sh "$DIST"
echo ""
echo "Copy to USB, then on OFFLINE Ubuntu 22.04:"
echo "  cd qf9700-offline-installer && sudo ./install.sh"
echo ""
echo "Kernel check on target must show: $(echo "$TARGET_KERNEL" | head -c 20)..."
echo "If target uname -r differs, rebuild with: ./prepare-offline.sh --kernel <target-uname-r>"
