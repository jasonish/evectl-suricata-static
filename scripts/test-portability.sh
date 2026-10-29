#!/usr/bin/env bash
# Run the smoke test of a built package inside other distributions' images
# to prove it does not depend on anything from the build environment.
# Runs on the host.
#
# Usage: test-portability.sh <gnu|musl> <x86_64|aarch64> <package.tar.gz>
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
variant=${1:?usage: $0 <variant> <arch> <package.tar.gz>}
arch=${2:?usage: $0 <variant> <arch> <package.tar.gz>}
archive=${3:?usage: $0 <variant> <arch> <package.tar.gz>}
CONTAINER=${CONTAINER:-podman}

case "$arch" in
    x86_64) platform=linux/amd64 ;;
    aarch64) platform=linux/arm64 ;;
    *) echo "error: unsupported architecture $arch" >&2; exit 1 ;;
esac

case "$variant" in
    gnu)
        # UBI 8 has the baseline glibc (2.28); Debian stable is current.
        images=(
            registry.access.redhat.com/ubi8/ubi-minimal:latest
            docker.io/library/debian:stable-slim
        )
        ;;
    musl)
        # No libc at all would be ideal; busybox:musl is the closest image
        # with a shell. Debian checks it also runs on a glibc system.
        images=(
            docker.io/library/busybox:musl
            docker.io/library/alpine:latest
            docker.io/library/debian:stable-slim
        )
        ;;
    *) echo "error: unknown variant $variant" >&2; exit 1 ;;
esac

name=$(basename "$archive" .tar.gz)
unpack="$ROOT/work/portability/$name"
rm -rf "$unpack"
mkdir -p "$unpack"
tar xzf "$archive" -C "$unpack"

for image in "${images[@]}"; do
    echo "==> Portability test: $name in $image"
    "$CONTAINER" run --rm --platform "$platform" \
        -v "$unpack/$name:/pkg:ro,Z" \
        -v "$ROOT/scripts/smoke-test.sh:/smoke-test.sh:ro,Z" \
        -v "$ROOT/tests:/tests:ro,Z" \
        "$image" /bin/sh /smoke-test.sh /pkg /tests
done
rm -rf "$unpack"
echo "Portability tests passed for $name"
