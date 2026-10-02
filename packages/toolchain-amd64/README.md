# Offline toolchain — gcc/make for Ubuntu 22.04 (jammy), amd64

This directory is bundled so `install.sh` can auto-install `gcc` + `make`
on an **offline** target with `dpkg -i` only (no network).

Auto-install entry points:
  sudo ./scripts/install-toolchain.sh        # direct
  sudo ./install.sh                          # auto (calls toolchain when gcc/make missing or broken)
  sudo ./scripts/install-deps.sh             # auto

Install order used by the script:
  1. gcc-11-base, libisl23, libmpc3, libcc1-0, libgcc-11-dev (runtime libs)
  2. cpp-11_*.deb
  3. gcc-11_*.deb
  4. cpp_*.deb (metapackage)
  5. gcc_*.deb (metapackage)
  6. make_*.deb
  + any other *.deb in this dir (second dpkg pass if needed)

Contents (jammy amd64, ~31 MB total, 8 debs):
  make_4.3-4.1build1_amd64.deb                     179742 bytes
  gcc_11.2.0-1ubuntu1_amd64.deb                      5112 bytes  (metapackage -> gcc-11)
  cpp_11.2.0-1ubuntu1_amd64.deb                     27700 bytes  (metapackage -> cpp-11)
  gcc-11_11.4.0-1ubuntu1~22.04.3_amd64.deb        20143406 bytes  (jammy-security)
  cpp-11_11.4.0-1ubuntu1~22.04.3_amd64.deb        10000304 bytes  (jammy-security)
  gcc-11-base_11.4.0-1ubuntu1~22.04.3_amd64.deb    215826 bytes  (REQUIRED, was missing -> libisl error)
  libisl23_0.24-2build1_amd64.deb                 726854 bytes  (REQUIRED, cc1 needs libisl.so.23)
  libmpc3_1.2.1-2build1_amd64.deb                  46868 bytes  (REQUIRED)

Deliberately EXCLUDED (proven unnecessary on 5.15.0-119-generic where
CC/MODPOST/LD + DHCP succeeded without them; they only produced dpkg noise):
  libcc1-0 (GDB plugin; bundled 12.3.0 wanted a different gcc-12-base)
  libgcc-11-dev + sanitizer chain (libgomp1, libitm1, libatomic1, libasan6,
    liblsan0, libtsan0, libubsan1, libquadmath0 — userspace runtimes the
    kernel module build never links).
Existing system copies are left untouched (no remove/downgrade).

Provenance:
  make/gcc/cpp metapackages : http://archive.ubuntu.com/ubuntu/pool/main/g/gcc-defaults/
                              http://archive.ubuntu.com/ubuntu/pool/main/m/make-dfsg/
  gcc-11/cpp-11/base/dev    : http://security.ubuntu.com/ubuntu/pool/main/g/gcc-11/
  libcc1-0                  : http://security.ubuntu.com/ubuntu/pool/main/g/gcc-12/
  libisl23                  : http://archive.ubuntu.com/ubuntu/pool/main/i/isl/
  libmpc3                   : http://archive.ubuntu.com/ubuntu/pool/main/m/mpclib3/
SHA256: see MANIFEST.txt in this directory.

Notes:
* Functional check is used, not just `command -v gcc`: the script compiles
  `int main(void){return 0;}` to catch unpacked-but-unconfigured states
  (e.g. missing libisl.so.23 where `gcc --version` still prints).
* Kernel headers are kernel-specific and are NOT bundled here;
  they come from top-level packages/*.deb via prepare-offline.sh.
* arm64 is not bundled (size). Use prepare-offline.sh --arch arm64 on an
  online host to create packages/toolchain-arm64/.
