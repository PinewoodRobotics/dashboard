#!/usr/bin/env bash
# Two-process fallback check: --screen=hud and --screen=touch as two processes
# against the fake robot, only the touch process publishing; see two_process.py.
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot}"
OUT="${OUT:-$APP/.screenshots/two_process}"
mkdir -p "$OUT"
"$GODOT" --headless --path "$APP" --import >/dev/null 2>&1 || true
cleanup() { pkill -f -- "--tag comp-godot-two-" 2>/dev/null || true; }
trap cleanup EXIT
uv run --quiet --script "$APP/tools/test/two_process.py" --app "$APP" --godot "$GODOT" --work "$OUT"
