#!/usr/bin/env bash
# Verify that a packaged program has only the runtime dependencies allowed
# for its variant:
#   gnu:  only glibc's own libraries, with no symbol versions newer than
#         GLIBC_BASELINE (plus libgcc_s for the Rust tools).
#   musl: fully static, no program interpreter and no shared libraries.
# Usage: check-linkage.sh <binary>
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

exe=${1:?usage: $0 <binary>}

needed=$(readelf -dW "$exe" | sed -nE 's/.*\(NEEDED\).*\[(.*)\]/\1/p' | sort)
interp=$(readelf -lW "$exe" | sed -nE 's/.*Requesting program interpreter: (.*)\]/\1/p')

rpath=$(readelf -dW "$exe" | sed -nE 's/.*\((RPATH|RUNPATH)\).*\[(.*)\]/\2/p')
[[ -z $rpath ]] || die "binary has an rpath/runpath: $rpath"

echo "$(basename "$exe"): interpreter: ${interp:-none}"
echo "$(basename "$exe"): needed: $(tr '\n' ' ' <<< "${needed:-none}")"

case "$VARIANT" in
    gnu)
        allowed=" libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 \
libresolv.so.2 ld-linux-x86-64.so.2 ld-linux-aarch64.so.1 "
        # Rust programs (suricatasc, suricatactl) always link the GCC
        # unwinder dynamically. Like glibc itself, which loads it for thread
        # cancellation, it is present on every glibc system and is on the
        # manylinux allow list. suricata itself must not need it.
        if [[ $(basename "$exe") != suricata ]]; then
            allowed+="libgcc_s.so.1 "
        fi
        for lib in $needed; do
            [[ $allowed == *" $lib "* ]] || die "unexpected shared library dependency: $lib"
        done
        newest=$(objdump -T "$exe" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' \
            | sed 's/^GLIBC_//' | sort -uV | tail -1)
        echo "Newest glibc symbol version: ${newest}"
        if [[ $(printf '%s\n%s\n' "$newest" "$GLIBC_BASELINE" | sort -V | tail -1) != "$GLIBC_BASELINE" ]]; then
            die "binary requires glibc $newest, newer than baseline $GLIBC_BASELINE"
        fi
        if objdump -T "$exe" | grep -qE 'GLIBCXX_|CXXABI_'; then
            die "binary depends on the shared C++ runtime"
        fi
        # Unwinder symbols up to GCC 7 (manylinux_2_28 limit).
        newest_gcc=$(objdump -T "$exe" | { grep -oE 'GCC_[0-9]+(\.[0-9]+)+' || true; } \
            | sed 's/^GCC_//' | sort -uV | tail -1)
        if [[ -n $newest_gcc && $(printf '%s\n7.0.0\n' "$newest_gcc" | sort -V | tail -1) != 7.0.0 ]]; then
            die "binary requires libgcc_s symbols from GCC $newest_gcc"
        fi
        ;;
    musl)
        [[ -z $interp ]] || die "static binary has a program interpreter: $interp"
        [[ -z $needed ]] || die "static binary needs shared libraries: $needed"
        ;;
    *) die "unknown variant $VARIANT" ;;
esac
echo "Linkage OK for $(basename "$exe") ($VARIANT)"
