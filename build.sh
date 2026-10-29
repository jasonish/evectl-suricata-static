#!/usr/bin/env bash
# Build portable Suricata packages for Linux from the pinned release
# tarball, inside containers (podman or docker).
#
# Usage: ./build.sh [gnu|musl|all]...     (default: all)
#
# Variants:
#   gnu   links only glibc dynamically (glibc >= GLIBC_BASELINE); built on
#         manylinux_2_28. Supports plugins.
#   musl  fully static binary built on Alpine. No plugin support.
#
# Output lands in dist/.
#
# Environment overrides:
#   ARCH            target architecture, x86_64 or aarch64 (default: host).
#                   A foreign architecture needs qemu-user binfmt support.
#   CONTAINER       container engine (default: podman, then docker)
#   JOBS            parallel make jobs (default: nproc in the container)
#   CONFIGURE_EXTRA extra ./configure arguments for Suricata
#   SKIP_PORTABILITY_TESTS=1  skip running the packages in other images
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=versions.env
source "$ROOT/versions.env"

variants=()
for arg in "${@:-all}"; do
    case "$arg" in
        gnu|musl) variants+=("$arg") ;;
        all) variants+=(gnu musl) ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown variant '$arg' (gnu, musl or all)" >&2; exit 1 ;;
    esac
done

ARCH=${ARCH:-$(uname -m)}
case "$ARCH" in
    x86_64|amd64) ARCH=x86_64; platform=linux/amd64 ;;
    aarch64|arm64) ARCH=aarch64; platform=linux/arm64 ;;
    *) echo "error: unsupported architecture $ARCH" >&2; exit 1 ;;
esac

if [[ -z ${CONTAINER:-} ]]; then
    if command -v podman >/dev/null; then
        CONTAINER=podman
    elif command -v docker >/dev/null; then
        CONTAINER=docker
    else
        echo "error: podman or docker is required" >&2
        exit 1
    fi
fi

# Build as the invoking user so work/ and dist/ stay owned by them.
case "$(basename "$CONTAINER")" in
    podman) user_args=(--userns=keep-id) ;;
    *) user_args=(--user "$(id -u):$(id -g)") ;;
esac

mkdir -p "$ROOT/work/home" "$ROOT/dist"

for variant in "${variants[@]}"; do
    case "$variant" in
        gnu) base_image="${GNU_IMAGE}_${ARCH}" ;;
        musl) base_image="$MUSL_IMAGE" ;;
    esac
    image="localhost/evectl-suricata-build-${variant}-${ARCH}:latest"
    package="suricata-${SURICATA_VERSION}-${PACKAGE_RELEASE}-linux-${variant}-${ARCH}"

    echo "==> Building build image $image (from $base_image)"
    "$CONTAINER" build --platform "$platform" \
        -f "$ROOT/containers/${variant}.Containerfile" \
        --build-arg "BASE_IMAGE=$base_image" \
        --build-arg "RUST_VERSION=$RUST_VERSION" \
        --build-arg "RAGEL_URL=$RAGEL_URL" \
        --build-arg "RAGEL_SHA256=$RAGEL_SHA256" \
        -t "$image" "$ROOT/containers"

    echo "==> Building $package"
    "$CONTAINER" run --rm --platform "$platform" "${user_args[@]}" \
        -v "$ROOT:/build:Z" -w /build \
        -e HOME=/build/work/home \
        -e VARIANT="$variant" \
        -e ARCH="$ARCH" \
        ${JOBS:+-e JOBS="$JOBS"} \
        ${CONFIGURE_EXTRA:+-e CONFIGURE_EXTRA="$CONFIGURE_EXTRA"} \
        "$image" ./scripts/container-build.sh

    if [[ ${SKIP_PORTABILITY_TESTS:-} != 1 ]]; then
        CONTAINER=$CONTAINER "$ROOT/scripts/test-portability.sh" \
            "$variant" "$ARCH" "$ROOT/dist/$package.tar.gz"
    fi
done

(
    cd "$ROOT/dist"
    sha256sum suricata-*.tar.gz > SHA256SUMS
)
echo
echo "Artifacts:"
sed 's/^/  /' "$ROOT/dist/SHA256SUMS"
