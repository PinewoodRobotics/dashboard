#!/usr/bin/env bash
# Auto preview (M7): real-time playback of every auto at every speed (headless,
# ~40 s), fixture screenshots of the preview and the HUD overlay with pixel
# probes, scripted play/pause/scrub/speed/loop input, a two-window run that
# samples frame rate and 3D view count while the preview plays, and a live run
# against the fake robot where the robot confirms the selection.
# PNGs, logs and JSON reports land in $OUT (default apps/comp-godot/.screenshots/m7).
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot}"
OUT="${OUT:-$APP/.screenshots/m7}"
mkdir -p "$OUT"
"$GODOT" --headless --path "$APP" --import >/dev/null 2>&1 || true

status=0
"$GODOT" --headless --path "$APP" --script res://tests/run_tests.gd -- --dir=realtime || status=1

run() {
  local name="$1" fixture="$2"; shift 2
  if "$GODOT" --path "$APP" -- --design-size --fixture="$fixture" --screenshot="$OUT/$name" --frames=5 "$@" >"$OUT/$name.log" 2>&1; then
    echo "ok   $name"
  else
    echo "FAIL $name:"; grep -E "DEV FAIL|ERROR|SCRIPT" "$OUT/$name.log" || tail -5 "$OUT/$name.log"
    status=1
  fi
}

for fx in touch_preview_blue touch_preview_red touch_preview_blue_field touch_preview_red_field touch_preview_stay \
  touch_preview_noop touch_preview_turret touch_script_preview; do
  run "$fx" "$fx" --screen=touch
done
for fx in hud_auto_path hud_auto_mirror hud_auto_gone; do
  run "$fx" "$fx" --screen=hud
done
run both_script_preview both_script_preview --screen=both --perf-frames=300

SETTINGS="$OUT/settings"
mkdir -p "$SETTINGS"
FAKE="$APP/tools/sim/fake_robot.py"
TAG="comp-godot-preview-$$"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
stop_fake() { pkill -f -- "--tag $TAG" 2>/dev/null || true; sleep 0.3; pkill -9 -f -- "--tag $TAG" 2>/dev/null || true; }
trap stop_fake EXIT
uv run --quiet --script "$FAKE" --port "$PORT" --pose 13.17,4.04,-0.785 --alliance red --tag "$TAG" >"$OUT/fake.log" 2>&1 &
for _ in $(seq 1 100); do nc -z -G 1 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
printf '%s\n' '{}' >"$SETTINGS/live.json"
PWRUP_SHARED_SETTINGS_PATH="$SETTINGS/connection-settings.json" \
  run both_live_auto_preview both_live_auto_preview --screen=both --live --nt-host=127.0.0.1 --nt-port="$PORT" --settings="$SETTINGS/live.json"
stop_fake

python3 - "$OUT" <<'PY' || status=1
import json, sys
out = sys.argv[1]
r = json.load(open(f"{out}/both_script_preview.json"))
perf = r["perf"]
ok = perf["fps"] >= 0.97 * perf["max_fps_setting"] and r["max_rendering_views"] <= 2
print(f"{'ok  ' if ok else 'FAIL'} preview playing with the HUD: {perf['fps']:.1f} fps at cap {perf['max_fps_setting']}, "
      f"p95 {perf['frame_ms_p95']:.1f} ms, max {r['max_rendering_views']} 3D views, preview t {r['autos']['t']:.2f} playing {r['autos']['playing']}")
sys.exit(0 if ok and r["autos"]["playing"] else 1)
PY
exit $status
