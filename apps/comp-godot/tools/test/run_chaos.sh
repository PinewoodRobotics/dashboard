#!/usr/bin/env bash
# Chaos: 10 fake-robot restarts (SIGKILL or SIGTERM, 0.2..4 s down) at random
# times while the dashboard runs both windows; see tools/test/chaos.py.
# Usage: tools/test/run_chaos.sh [--restarts N] [--seed N]
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot}"
OUT="${OUT:-$APP/.screenshots/chaos}"
mkdir -p "$OUT"
"$GODOT" --headless --path "$APP" --import >/dev/null 2>&1 || true
cleanup() { pkill -f -- "--tag comp-godot-chaos-" 2>/dev/null || true; }
trap cleanup EXIT
uv run --quiet --script "$APP/tools/test/chaos.py" --app "$APP" --godot "$GODOT" --work "$OUT" "$@"
