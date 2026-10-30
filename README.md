Custom portable Suricata Linux builds for EveCtl.

Builds Suricata from the pinned release tarball into self-contained
archives that run without installing any packages on the target host.

## Variants

| Variant | Linkage | Runs on | Plugins |
|---|---|---|---|
| `linux-gnu` | glibc dynamic, everything else static | glibc >= 2.28: RHEL/Alma/Rocky 8+, Debian 10+, Ubuntu 20.04+, Amazon Linux 2023 | yes |
| `linux-musl` | fully static (musl), static PIE | any Linux, including Alpine and NixOS | no |

Both are built for `x86_64` and `aarch64` and include Hyperscan
(Vectorscan), libmagic, AF_PACKET, GeoIP2 (libmaxminddb), libnet,
libcap-ng, lz4 and PCRE2 JIT. NFQueue, eBPF/XDP, DPDK and hwloc are not
included.

Hyperscan CPU support:

- `gnu`: fat runtime selecting the best implementation at startup
  (x86_64: SSE4.2, AVX2, AVX-512, AVX-512 VBMI; aarch64: NEON, SVE, SVE2).
- `musl`: musl has no ifunc, so a single baseline is built (x86_64:
  x86-64-v2/SSE4.2; aarch64: NEON).

On x86_64 CPUs without SSE4.2, Suricata falls back to its own pattern
matchers.

## Archive layout

```
suricata-<version>-<release>-linux-<variant>-<arch>/
  bin/
    suricata
    suricatasc           unix socket client
    suricatactl          filestore management
  etc/
    suricata.yaml        default config (paths: /etc/suricata,
                         /var/log/suricata, /var/lib/suricata)
    classification.config
    reference.config
    threshold.config
    magic.mgc            libmagic database matching the linked libmagic
  rules/                 Suricata's bundled event rules
  LICENSE
  BUILD-INFO.txt         versions, patches and `suricata --build-info`
```

Every program `make install` puts in `bin` is shipped. suricata-update is
Python and not included.

With no `magic-file` configured, the patched Suricata uses `magic.mgc`
next to the executable or in `../etc/` relative to it (see `patches/`).
Older or missing system databases are not compatible with the bundled
libmagic.

In the `gnu` variant, `suricatasc` and `suricatactl` (Rust) also link
`libgcc_s.so.1`, which every glibc system has; `suricata` links only
glibc.

## Building

Needs podman or docker. Builds run inside containers
(`containers/*.Containerfile`); all libraries are built from pinned,
checksummed source tarballs (`versions.env`).

```
./build.sh              # both variants for the host architecture
./build.sh gnu          # one variant
ARCH=aarch64 ./build.sh # another architecture (needs qemu-user binfmt; slow)
```

Output is written to `dist/` with a `SHA256SUMS` file. Static
dependencies are cached per library in `work/<variant>-<arch>/deps` and
rebuilt only when their version or build steps change.

Each build checks the binary's linkage (`scripts/check-linkage.sh`), runs
a smoke test (`scripts/smoke-test.sh`: config test, a pcap that must
trigger libmagic and Hyperscan rules, `suricatasc` against a running
Suricata, and `suricatactl`), then repeats the smoke test in
other distributions' images (`scripts/test-portability.sh`).

## Releasing

Bump `SURICATA_VERSION`/`SURICATA_SHA256` (resetting `PACKAGE_RELEASE` to
1) or `PACKAGE_RELEASE` in `versions.env`, then push a tag of the form
`<suricata>-<release>`, e.g. `8.0.8-1`. CI checks the tag against
`versions.env`, builds all four archives and publishes a GitHub release.
Any other tag produces a prerelease.

## Test data

`tests/pdf-dl.pcap` is from suricata-verify (`tests/filemagic-flowbits`).
