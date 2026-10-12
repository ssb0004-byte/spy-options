#!/usr/bin/env bash
# Runs `swift <args>` for the VitalCore package inside the official Swift Linux image.
# Used on non-Mac machines/CI. On a Mac, just run `swift test` in Packages/VitalCore.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
docker run --rm -v "$ROOT/Packages/VitalCore:/pkg" -v vitalcore-build:/pkg/.build -w /pkg swift:6.1-noble swift "$@"
