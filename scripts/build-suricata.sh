#!/usr/bin/env bash
# Configure and build Suricata against the static dependencies in
# $DEPS_PREFIX. Runs inside the build container.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

SRC="$WORK/src/suricata-${SURICATA_VERSION}"
P=$DEPS_PREFIX

# --- Source tarball ---------------------------------------------------------
log "Suricata $SURICATA_VERSION"
tarball=$(fetch SURICATA "suricata-${SURICATA_VERSION}.tar.gz")
rm -rf "$WORK/src"
mkdir -p "$WORK/src"
tar xzf "$tarball" -C "$WORK/src"
[[ -d "$SRC" ]] || die "expected $SRC after extraction"

# --- Patches ----------------------------------------------------------------
if compgen -G "$ROOT/patches/*.patch" >/dev/null; then
    for p in "$ROOT"/patches/*.patch; do
        echo "Applying $(basename "$p")"
        patch -p1 -d "$SRC" --no-backup-if-mismatch < "$p"
    done
fi

# --- Configure --------------------------------------------------------------
# Paths follow the usual system layout (/etc/suricata, /var/log/suricata,
# /var/lib/suricata), matching the Suricata container images. They are
# only defaults; everything can be overridden at runtime.
#
# Release tarballs ship vendored Rust crates and pre-generated bindings, so
# cargo works offline and cbindgen is not needed.
# --disable-gccmarch-native keeps the binary portable across CPUs.
CONFIGURE_ARGS=(
    --prefix=/usr
    --sysconfdir=/etc
    --localstatedir=/var
    --disable-shared
    --disable-gccmarch-native
    --enable-gccprotect
    --enable-geoip
    --enable-hyperscan
    --enable-libmagic
    --disable-suricata-update
    --disable-python
    "--with-libnet-includes=$DEPS_PREFIX/include"
    "--with-libnet-libraries=$DEPS_PREFIX/lib"
)
if [[ -n ${CONFIGURE_EXTRA:-} ]]; then
    # shellcheck disable=SC2206
    CONFIGURE_ARGS+=($CONFIGURE_EXTRA)
fi

export CFLAGS="-O2 -g"
export CPPFLAGS="-I$P/include"
export PKG_CONFIG_PATH="$P/lib/pkgconfig"
# --static pulls in Libs.private (e.g. Vectorscan's C++ runtime).
export PKG_CONFIG="pkg-config --static"
export CARGO_HOME="$WORK/cargo-home"

case "$VARIANT" in
    gnu)
        CONFIGURE_ARGS+=(--enable-pie)
        # Everything but glibc is linked statically, including the
        # C++ runtime needed by Vectorscan and the GCC support library.
        export LDFLAGS="-L$P/lib -static-libgcc -static-libstdc++"
        ;;
    musl)
        export LDFLAGS="-L$P/lib -static"
        ;;
    *) die "unknown variant $VARIANT" ;;
esac

cd "$SRC"
log "Configuring: ./configure ${CONFIGURE_ARGS[*]}"
./configure "${CONFIGURE_ARGS[@]}"

# --- Build ------------------------------------------------------------------
log "Building"
make_args=()
if [[ $VARIANT == musl ]]; then
    # Suricata links through libtool, which swallows a plain -static (to
    # libtool it only means "prefer static libtool libraries"). Override
    # LDFLAGS for the build so libtool hands -static to gcc. This also
    # drops the -rdynamic configure adds for plugins, which a static binary
    # cannot load anyway.
    make_args+=(LDFLAGS="-L$P/lib -all-static")
fi
make -j"$JOBS" "${make_args[@]}"

exe="$SRC/src/suricata"
"$exe" -V

# --- Checks -----------------------------------------------------------------
log "Checking the binary"
file "$exe"
build_info=$("$exe" --build-info)
# configure only warns when an optional feature is missing; make the ones
# we rely on fatal here.
for feature in "AF_PACKET support" "Hyperscan support" "Libmagic support" \
        "GeoIP2 support" "Libnet support" "liblz4 support" "PCRE jit"; do
    if ! grep -qE "^ *${feature}:[[:space:]]+yes" <<< "$build_info"; then
        die "suricata was built without ${feature}"
    fi
done
if ! grep -qE "^Features:.* LIBCAP_NG( |$)" <<< "$build_info"; then
    die "suricata was built without LIBCAP_NG"
fi

"$ROOT/scripts/check-linkage.sh" "$exe"
