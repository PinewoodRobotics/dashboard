#!/usr/bin/env bash
# Headless unit tests. Usage: tools/test/run_unit.sh [--filter=substr]
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot}"

"$GODOT" --headless --path "$APP" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$APP" --script res://tests/run_tests.gd -- --dir=unit "$@"
