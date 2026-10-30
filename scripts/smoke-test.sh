#!/bin/sh
# Smoke test an unpacked package directory:
#   - print the version
#   - run a configuration test with the bundled rules
#   - run tests/pdf-dl.pcap through tests/smoke.rules and check that both
#     the libmagic (bundled etc/magic.mgc) and Hyperscan rules alert
#   - start suricata in unix-socket mode and talk to it with suricatasc
#   - run suricatactl
#
# No magic-file is configured, so the bundled magic.mgc must be found
# relative to the executable (see patches/).
#
# POSIX sh on purpose: it also runs inside minimal images (busybox) to
# prove the programs have no hidden host dependencies.
# Usage: smoke-test.sh <package-dir> <tests-dir>
set -eu

pkg=${1:?usage: $0 <package-dir> <tests-dir>}
tests=${2:?usage: $0 <package-dir> <tests-dir>}
cd "$pkg"

logdir=$(mktemp -d)
pid=""
cleanup() {
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
    fi
    rm -rf "$logdir"
}
trap cleanup EXIT

common="--set classification-file=./etc/classification.config
    --set reference-config-file=./etc/reference.config
    --set threshold-file=./etc/threshold.config
    --set mpm-algo=hs
    --set spm-algo=hs
    --set detect.sgh-mpm-caching=no"

./bin/suricata -V

# --- Configuration test -----------------------------------------------------
# shellcheck disable=SC2086
./bin/suricata -c etc/suricata.yaml -T -l "$logdir" \
    -S rules/app-layer-events.rules $common

# --- Pcap -------------------------------------------------------------------
mkdir "$logdir/pcap"
# shellcheck disable=SC2086
./bin/suricata -c etc/suricata.yaml -l "$logdir/pcap" -k none \
    --runmode single -r "$tests/pdf-dl.pcap" -S "$tests/smoke.rules" $common \
    > "$logdir/pcap/console.log" 2>&1 \
    || { cat "$logdir/pcap/console.log" >&2; exit 1; }
cat "$logdir/pcap/console.log"
if grep -q '^E: ' "$logdir/pcap/console.log"; then
    echo "error: suricata logged errors" >&2
    exit 1
fi
for sid in 1000001 1000002; do
    if ! grep -q "\"signature_id\":$sid," "$logdir/pcap/eve.json"; then
        echo "error: expected an alert for sid $sid" >&2
        exit 1
    fi
done

# --- suricatasc -------------------------------------------------------------
mkdir "$logdir/socket"
sock="$logdir/socket/suricata.socket"
# shellcheck disable=SC2086
./bin/suricata -c etc/suricata.yaml -l "$logdir/socket" -S /dev/null \
    --unix-socket="$sock" $common > "$logdir/socket/console.log" 2>&1 &
pid=$!
i=0
until ./bin/suricatasc -c uptime "$sock" > /dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 60 ] || ! kill -0 "$pid" 2>/dev/null; then
        cat "$logdir/socket/console.log" >&2
        echo "error: suricatasc could not reach suricata" >&2
        exit 1
    fi
    sleep 1
done
version=$(./bin/suricatasc -c version "$sock")
echo "suricatasc version: $version"
case "$version" in
    *'"return":"OK"'*) ;;
    *) echo "error: unexpected suricatasc reply" >&2; exit 1 ;;
esac
./bin/suricatasc -c shutdown "$sock" > /dev/null
wait "$pid"
pid=""

# --- suricatactl ------------------------------------------------------------
mkdir "$logdir/filestore"
./bin/suricatactl filestore prune -d "$logdir/filestore" --age 1d

echo "Smoke test passed"
