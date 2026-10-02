# Packages — offline .deb bundle

## Toolchain (committed, auto-installed)

`toolchain-amd64/` already contains gcc + make for Ubuntu 22.04 jammy amd64
(~30 MB), auto-installed offline by `install.sh` when gcc/make are missing:

```bash
sudo ./scripts/install-toolchain.sh   # direct
sudo ./install.sh                     # auto
```

Contents: `make_4.3`, `gcc_11.2.0` + `cpp_11.2.0` metapackages,
`gcc-11_11.4.0` + `cpp-11_11.4.0` (jammy-security).
See `toolchain-amd64/README.md` + `MANIFEST.txt` for versions/SHA256.

`toolchain-arm64/` is a placeholder; generate it on an online host with
`./prepare-offline.sh --arch arm64`.

## Kernel headers etc. (via prepare-offline.sh)

Top-level `*.deb` files are added by `prepare-offline.sh` on an online host
(kernel-specific, cannot be bundled universally):

```bash
./prepare-offline.sh --kernel 5.15.0-91-generic --arch amd64
```

After preparation this directory holds e.g.:

```text
linux-headers-5.15.0-91-generic_*.deb
linux-headers-5.15.0-91_*.deb
dkms_*.deb + dependencies
MANIFEST.txt + SOURCES.txt
```

`install.sh` installs everything with `dpkg -i` and NEVER uses the network.
See `prepare-offline.sh` for provenance.
