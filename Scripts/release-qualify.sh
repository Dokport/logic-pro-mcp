#!/bin/bash
#
# Scripts/release-qualify.sh — standalone live qualification test runner (#985).
#
# Ordinary tests must not drive Logic merely because a release executable exists.
# This runner builds the current tree, requires running Logic and its permissions,
# then explicitly enables the real-server tests for the full suite. A missing
# process or permission still stops before the suite; no live success is inferred.
#
# Release entrypoints consume staged final artifacts; this runner does not publish.
# Scripts/test_release_builds_before_live_qualification.py runs it with a stubbed `swift`, `pgrep` and release binary.
#
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release
if ! pgrep -xq "Logic Pro"; then
    echo "Error: Logic Pro is not running. The live qualification tests in the suite need it (#985)." >&2
    exit 1
fi
if ! .build/release/LogicProMCP --check-permissions; then
    echo "Error: the release binary lacks a macOS permission the live qualification needs; the lines above name it (#985)." >&2
    exit 1
fi
LOGIC_PRO_MCP_RUN_LIVE_QA=1 swift test --no-parallel
