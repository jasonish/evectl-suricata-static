#!/usr/bin/env bash
# Entry point inside the build container: build the static dependencies,
# Suricata, and the package. Expects VARIANT and ARCH in the environment.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
"$ROOT/scripts/build-deps.sh"
"$ROOT/scripts/build-suricata.sh"
"$ROOT/scripts/package.sh"
