# Shared helpers for the in-container build scripts. Source, don't run.
# shellcheck shell=bash
# shellcheck disable=SC2034 # variables are used by the sourcing scripts

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=../versions.env
source "$ROOT/versions.env"

: "${VARIANT:?VARIANT must be set (gnu or musl)}"
: "${ARCH:?ARCH must be set (x86_64 or aarch64)}"

JOBS=${JOBS:-$(nproc)}
DOWNLOADS="$ROOT/work/downloads"
WORK="$ROOT/work/${VARIANT}-${ARCH}"
DEPS_PREFIX="$WORK/deps"
PACKAGE_NAME="suricata-${SURICATA_VERSION}-${PACKAGE_RELEASE}-linux-${VARIANT}-${ARCH}"

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    echo "error: $*" >&2
    exit 1
}

# fetch NAME FILE: download ${NAME}_URL to $DOWNLOADS/FILE (cached) and
# verify it against ${NAME}_SHA256. Prints the local path.
fetch() {
    local name=$1 file=$2
    local url_var="${name}_URL" sha_var="${name}_SHA256"
    local url=${!url_var} sha=${!sha_var}
    local dest="$DOWNLOADS/$file"
    mkdir -p "$DOWNLOADS"
    if [[ ! -f "$dest" ]]; then
        echo "Downloading $url" >&2
        curl -sSfL -o "$dest.part" "$url"
        mv "$dest.part" "$dest"
    fi
    echo "${sha}  ${dest}" | sha256sum -c - >&2 \
        || die "checksum mismatch for $dest"
    printf '%s\n' "$dest"
}

# extract ARCHIVE DIR: extract a tarball into DIR, stripping the top-level
# directory.
extract() {
    local archive=$1 dir=$2
    rm -rf "$dir"
    mkdir -p "$dir"
    tar xf "$archive" -C "$dir" --strip-components=1
}
