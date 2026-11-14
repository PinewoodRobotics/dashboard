#!/usr/bin/env bash
# Headless unit tests. Usage: tools/test/run_unit.sh [--filter=substr]
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot}"
mkdir -p "$APP/.scratch/shared"
export PWRUP_SHARED_SETTINGS_PATH="${PWRUP_SHARED_SETTINGS_PATH:-$APP/.scratch/shared/unit-connection-settings.json}"

"$GODOT" --headless --path "$APP" --import >/dev/null 2>&1 || true

selftest_out="$("$GODOT" --headless --path "$APP" --script res://tests/run_tests.gd -- --dir=selftest 2>&1)" && selftest_rc=0 || selftest_rc=$?
if [[ $selftest_rc -eq 0 ]] || ! grep -q "^3 tests, 3 failed" <<<"$selftest_out"; then
  echo "$selftest_out"
  echo "runner self-test: expected 3 tests, 3 failed and a non-zero exit (got rc=$selftest_rc)" >&2
  exit 1
fi
echo "runner self-test ok: errors inside tests are reported as failures"

"$GODOT" --headless --path "$APP" --script res://tests/run_tests.gd -- --dir=unit "$@"
