#!/usr/bin/env bash
# Windowed screenshot runs (fixtures, offline: no socket is opened) with pixel
# probes, joint-motion diffs, mesh sharing, perf counters and startup timing.
# PNGs and JSON reports land in $OUT (default apps/comp-godot/.screenshots/m2).
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot}"
OUT="${OUT:-$APP/.screenshots/m2}"
mkdir -p "$OUT"
"$GODOT" --headless --path "$APP" --import >/dev/null 2>&1 || true

run() {
  local name="$1"; shift
  "$GODOT" --path "$APP" -- --screen=both "$@" --screenshot="$OUT/$name" >"$OUT/$name.log" 2>&1 || {
    echo "run $name failed:"; cat "$OUT/$name.log"; return 1; }
}

for fx in m2_overview_blue m2_overview_red m2_close m2_close_turret_q m2_close_wrist; do
  run "$fx" --fixture="$fx"
done

FAKE="$APP/tools/sim/fake_robot.py"
TAG="comp-godot-shots-$$"
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
stop_fake() { pkill -f -- "--tag $TAG" 2>/dev/null || true; sleep 0.3; pkill -9 -f -- "--tag $TAG" 2>/dev/null || true; }
trap stop_fake EXIT
for alliance in blue red; do
  PORT="$(free_port)"
  uv run --quiet --script "$FAKE" --port "$PORT" --pose 2.0,4.03,0 --alliance "$alliance" --tag "$TAG" >"$OUT/fake_$alliance.log" 2>&1 &
  for _ in $(seq 1 100); do nc -z -G 1 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
  run "live_$alliance" --fixture="m2_overview_$alliance" --live --nt-host=127.0.0.1 --nt-port="$PORT"
  stop_fake
done

python3 -c 'import json,sys,time; json.dump({"launch_unix": time.time()}, open(sys.argv[1], "w"))' "$OUT/m2_perf.launch.json"
run m2_perf --fixture=m2_base --max-fps=0 --vsync=off --perf-frames=300

python3 "$APP/tools/test/check_screenshots.py" "$OUT" "$GODOT" "$APP"
