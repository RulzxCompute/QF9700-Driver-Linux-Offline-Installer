# Offline toolchain — arm64 (placeholder)

arm64 `.deb` files are NOT bundled (to keep the repo small).

On an ONLINE Ubuntu host, fetch them for your target:

```bash
./prepare-offline.sh --kernel <target-uname-r> --arch arm64
```

This creates `packages/toolchain-arm64/*.deb` plus top-level
`packages/*.deb` (kernel headers) and `dist/` for USB copy.

Layout must mirror `../toolchain-amd64/`:
  make_*.deb, gcc_*.deb, cpp_*.deb, gcc-11_*.deb, cpp-11_*.deb

`scripts/install-toolchain.sh --arch arm64` installs them offline
with `dpkg -i` (no network).
