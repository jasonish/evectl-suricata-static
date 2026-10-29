#!/usr/bin/env bash
# Verify that a suricata binary has only the runtime dependencies allowed
# for its variant:
#   gnu:  only glibc's own libraries, with no symbol versions newer than
#         GLIBC_BASELINE.
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

echo "Interpreter: ${interp:-none}"
echo "Needed: ${needed:-none}" | tr '\n' ' '
echo

case "$VARIANT" in
    gnu)
        allowed=" libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 \
libresolv.so.2 ld-linux-x86-64.so.2 ld-linux-aarch64.so.1 "
        for lib in $needed; do
            [[ $allowed == *" $lib "* ]] || die "unexpected shared library dependency: $lib"
        done
        newest=$(objdump -T "$exe" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' \
            | sed 's/^GLIBC_//' | sort -uV | tail -1)
        echo "Newest glibc symbol version: ${newest}"
        if [[ $(printf '%s\n%s\n' "$newest" "$GLIBC_BASELINE" | sort -V | tail -1) != "$GLIBC_BASELINE" ]]; then
            die "binary requires glibc $newest, newer than baseline $GLIBC_BASELINE"
        fi
        if objdump -T "$exe" | grep -qE 'GLIBCXX_|CXXABI_|GCC_[0-9]'; then
            die "binary depends on the shared C++ or GCC runtime"
        fi
        ;;
    musl)
        [[ -z $interp ]] || die "static binary has a program interpreter: $interp"
        [[ -z $needed ]] || die "static binary needs shared libraries: $needed"
        ;;
    *) die "unknown variant $VARIANT" ;;
esac
echo "Linkage OK for variant $VARIANT"
