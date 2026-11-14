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
for fx in hud_auto_path hud_auto_mirror hud_auto_gone hud_auto_start_off; do
  run "$fx" "$fx" --screen=hud
done
for fx in touch_auto_long_names touch_auto_robot_only touch_script_preview_expand; do
  run "$fx" "$fx" --screen=touch
done
USER_AUTOS="$OUT/user_autos"
python3 - "$APP/data/autos" "$USER_AUTOS" <<'PY'
import json, shutil, sys
from pathlib import Path
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
shutil.rmtree(dst, ignore_errors=True)
shutil.copytree(src, dst)
idx = json.loads((dst / "index.json").read_text())
first = dict(idx["autos"][0])
body = json.loads((dst / first["file"]).read_text())
body["name"] = first["name"] = "Event Fix Auto"
first["file"] = "Event Fix Auto.json"
(dst / first["file"]).write_text(json.dumps(body))
idx["autos"].append(first)
idx["exported_at"] = "2999-01-02T03:04:05Z"
(dst / "index.json").write_text(json.dumps(idx))
PY
run touch_autos_user_export touch_autos_user_export --screen=touch --autos-dir="$USER_AUTOS"
LATE_AUTOS="$OUT/late_autos"
python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$LATE_AUTOS"
run touch_autos_reload_new touch_autos_reload_new --screen=touch --autos-dir="$LATE_AUTOS" --autos-stage="$USER_AUTOS"
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
chips = {n: json.load(open(f"{out}/{n}.json"))["hud_layout"]["start_chip"] for n in ("hud_auto_path", "hud_auto_start_off", "hud_auto_mirror")}
want = {"hud_auto_path": "On start pose (0.00 m / 0°)", "hud_auto_start_off": "Start pose off by 2.01 m / 32°", "hud_auto_mirror": ""}
for n, text in want.items():
    ok = chips[n]["text"] == text
    print(f"{'ok  ' if ok else 'FAIL'} {n} start pose chip: {chips[n]['text']!r}")
    if not ok:
        sys.exit(1)
r = json.load(open(f"{out}/both_script_preview.json"))
perf = r["perf"]
ok = perf["fps"] >= 0.97 * perf["max_fps_setting"] and r["max_rendering_views"] <= 2
print(f"{'ok  ' if ok else 'FAIL'} preview playing with the HUD: {perf['fps']:.1f} fps at cap {perf['max_fps_setting']}, "
      f"p95 {perf['frame_ms_p95']:.1f} ms, max {r['max_rendering_views']} 3D views, preview t {r['autos']['t']:.2f} playing {r['autos']['playing']}")
sys.exit(0 if ok and r["autos"]["playing"] else 1)
PY
exit $status
