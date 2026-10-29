#!/bin/sh
# Smoke test an unpacked package directory:
#   - print the version
#   - run a configuration test with the bundled rules
#   - run tests/pdf-dl.pcap through tests/smoke.rules and check that both
#     the libmagic (bundled magic.mgc) and Hyperscan rules alert
#
# No magic-file is configured, so the bundled magic.mgc must be found next
# to the executable (see patches/).
#
# POSIX sh on purpose: it also runs inside minimal images (busybox) to
# prove the binary has no hidden host dependencies.
# Usage: smoke-test.sh <package-dir> <tests-dir>
set -eu

pkg=${1:?usage: $0 <package-dir> <tests-dir>}
tests=${2:?usage: $0 <package-dir> <tests-dir>}
cd "$pkg"

logdir=$(mktemp -d)
trap 'rm -rf "$logdir"' EXIT

common="--set classification-file=./classification.config
    --set reference-config-file=./reference.config
    --set threshold-file=./threshold.config
    --set mpm-algo=hs
    --set spm-algo=hs
    --set detect.sgh-mpm-caching=no"

./suricata -V

# shellcheck disable=SC2086
./suricata -c suricata.yaml -T -l "$logdir" -S rules/app-layer-events.rules \
    $common

# shellcheck disable=SC2086
./suricata -c suricata.yaml -l "$logdir" -k none --runmode single \
    -r "$tests/pdf-dl.pcap" -S "$tests/smoke.rules" $common \
    > "$logdir/console.log" 2>&1 || { cat "$logdir/console.log" >&2; exit 1; }
cat "$logdir/console.log"
if grep -q '^E: ' "$logdir/console.log"; then
    echo "error: suricata logged errors" >&2
    exit 1
fi

for sid in 1000001 1000002; do
    if ! grep -q "\"signature_id\":$sid," "$logdir/eve.json"; then
        echo "error: expected an alert for sid $sid" >&2
        exit 1
    fi
done
echo "Smoke test passed"
