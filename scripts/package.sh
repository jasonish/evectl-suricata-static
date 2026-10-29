#!/usr/bin/env bash
# Stage the built Suricata into a self-contained directory, smoke test it
# and produce dist/<package>.tar.gz. Runs inside the build container.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

SRC="$WORK/src/suricata-${SURICATA_VERSION}"
exe="$SRC/src/suricata"
[[ -x "$exe" ]] || die "$exe not found (build first)"

DIST="$ROOT/dist"
stage="$WORK/stage"
pkg="$stage/$PACKAGE_NAME"
rm -rf "$stage"
mkdir -p "$pkg" "$DIST"

log "Staging $PACKAGE_NAME"
cp "$exe" "$pkg/suricata"
strip -s "$pkg/suricata"

# Ship the libmagic database built alongside the linked libmagic, so the
# two always match.
cp "$DEPS_PREFIX/share/misc/magic.mgc" "$pkg/"

cp "$SRC/suricata.yaml" "$pkg/suricata.yaml"
cp "$SRC/etc/classification.config" "$SRC/etc/reference.config" "$pkg/"
cp "$SRC/threshold.config" "$pkg/"
cp "$SRC/COPYING" "$pkg/LICENSE"
mkdir -p "$pkg/rules"
cp "$SRC"/rules/*.rules "$pkg/rules/"

# --- Smoke test -------------------------------------------------------------
# The staged tree must work on its own. Logs go to a scratch dir so the
# staged tree stays clean.
log "Smoke testing the staged tree"
"$ROOT/scripts/smoke-test.sh" "$pkg" "$ROOT/tests"

# --- Build info -------------------------------------------------------------
case "$VARIANT" in
    gnu) linkage="dynamically linked against glibc >= ${GLIBC_BASELINE} only; all other libraries static" ;;
    musl) linkage="fully static (musl libc); plugins cannot be loaded" ;;
esac
{
    echo "Package:   $PACKAGE_NAME"
    echo "Built:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Source:    ${SURICATA_URL}"
    echo "Variant:   ${VARIANT} (${linkage})"
    echo "Arch:      ${ARCH}"
    echo "Rust:      $(rustc --version)"
    echo "Patches:"
    if compgen -G "$ROOT/patches/*.patch" >/dev/null; then
        for p in "$ROOT"/patches/*.patch; do echo "  $(basename "$p")"; done
    else
        echo "  (none)"
    fi
    echo "Static libraries:"
    echo "  zlib ${ZLIB_VERSION}"
    echo "  lz4 ${LZ4_VERSION}"
    echo "  pcre2 ${PCRE2_VERSION}"
    echo "  jansson ${JANSSON_VERSION}"
    echo "  libyaml ${LIBYAML_VERSION}"
    echo "  libpcap ${LIBPCAP_VERSION}"
    echo "  libmagic (file) ${FILE_VERSION}"
    echo "  libcap-ng ${LIBCAP_NG_VERSION}"
    echo "  libmaxminddb ${LIBMAXMINDDB_VERSION}"
    echo "  libnet ${LIBNET_VERSION}"
    echo "  vectorscan ${VECTORSCAN_VERSION}"
    echo
    "$pkg/suricata" --build-info
} > "$pkg/BUILD-INFO.txt"

# --- Archive ----------------------------------------------------------------
archive="$DIST/$PACKAGE_NAME.tar.gz"
rm -f "$archive"
tar -C "$stage" --sort=name --owner=0 --group=0 --numeric-owner \
    -czf "$archive" "$PACKAGE_NAME"

echo
echo "Packaged files:"
(cd "$pkg" && find . -type f | sort | sed 's/^/  /')
echo
echo "Archive: $archive"
