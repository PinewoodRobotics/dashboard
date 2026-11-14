#!/usr/bin/env bash
# Perf budget, windowed, both screens at the design size, against the fake
# robot playing an 8x match on a loop while the Auto tab preview plays:
# - render scale 1.0, uncapped: <= 45 3D draw calls (summed over the rendering
#   SubViewports) and <= 650k primitives in every frame, frame time p95 < 8 ms,
#   at most 2 SubViewports rendering 3D. The engine-wide count also includes
#   the 2D UI batches (font and icon texture switches, about 85 with the Auto
#   tab open); it is held under 130 as a regression guard;
# - render scale 0.5: every 3D viewport reports scale 0.5 and an offline
#   fixture renders at half resolution (check_render_scale.py: the 3D image has
#   lost the detail above half the pixel Nyquist frequency).
# Reports land in $OUT (default apps/comp-godot/.screenshots/perf).
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot}"
OUT="${OUT:-$APP/.screenshots/perf}"
WORK="$OUT/work"
mkdir -p "$OUT" "$WORK"
source "$APP/tools/test/lib_fake_robot.sh"
trap stop_fakes EXIT
"$GODOT" --headless --path "$APP" --import >/dev/null 2>&1 || true
export PWRUP_SHARED_SETTINGS_PATH="$WORK/connection-settings.json"

start_fake perf --match --loop --speed 8 --motion --alliance red
status=0
for scale in 1.0 0.5; do
  printf '%s\n' '{}' >"$WORK/settings_$scale.json"
  if ! "$GODOT" --path "$APP" -- --screen=both --design-size --live --fixture=live_match_preview \
      --nt-host=127.0.0.1 --nt-port="$FAKE_PORT" --settings="$WORK/settings_$scale.json" \
      --render-scale="$scale" --max-fps=0 --vsync=off --frames=60 --perf-frames=900 \
      --screenshot="$OUT/live_$scale" >"$OUT/live_$scale.log" 2>&1; then
    echo "FAIL live run at render scale $scale:"; grep -E "DEV FAIL|ERROR|SCRIPT" "$OUT/live_$scale.log" || tail -5 "$OUT/live_$scale.log"
    status=1
  fi
done
stop_fakes

for scale in 1.0 0.5; do
  "$GODOT" --path "$APP" -- --screen=hud --design-size --fixture=hud_pre_match --render-scale="$scale" \
    --frames=10 --screenshot="$OUT/still_$scale" >"$OUT/still_$scale.log" 2>&1 || { echo "FAIL still run $scale"; status=1; }
done

python3 - "$OUT" <<'PY' || status=1
import json, re, sys
out = sys.argv[1]
fails = []
def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        fails.append(msg)
for scale in ("1.0", "0.5"):
    r = json.load(open(f"{out}/live_{scale}.json"))
    p = r["perf"]
    log = open(f"{out}/live_{scale}.log").read()
    check(not r["failures"], f"scale {scale}: no failures {r['failures']}")
    check(not re.search(r"SCRIPT ERROR|^ERROR|^WARNING", log, re.M), f"scale {scale}: clean log")
    check(r["autos"]["playing"] and r["nt"]["state"] == "READY", f"scale {scale}: preview playing ({r['autos']['t']:.2f} s) and NT READY")
    views = {k: v["scaling_3d_scale"] for k, v in p["per_view"].items()}
    drawing = sorted(k for k, v in p["per_view"].items() if v["draw_calls"] > 0)
    check(drawing == ["hud", "preview"] and all(abs(v - float(scale)) < 1e-6 for v in views.values()),
          f"scale {scale}: HUD minimap and preview draw 3D ({drawing}), scaling_3d_scale {views}")
    check(r["max_rendering_views"] <= 2, f"scale {scale}: at most 2 SubViewports render 3D ({r['max_rendering_views']})")
    print(f"     scale {scale}: {p['fps']:.0f} fps uncapped, p50 {p['frame_ms_p50']:.2f} ms, p95 {p['frame_ms_p95']:.2f} ms, "
          f"max {p['max_draw_calls_3d']} 3D draw calls / {p['max_primitives_3d']} 3D primitives, "
          f"engine-wide max {p['max_draw_calls']} draw calls / {p['max_primitives']} primitives, "
          f"phase {r['match']['phase']}, {p['adapter']}")
    if scale == "1.0":
        check(p["max_draw_calls_3d"] <= 45, f"<= 45 3D draw calls per frame (max {p['max_draw_calls_3d']})")
        check(p["max_primitives"] <= 650_000, f"<= 650k primitives per frame, 2D included (max {p['max_primitives']})")
        check(p["max_draw_calls"] <= 130, f"<= 130 draw calls per frame with the 2D UI batches (max {p['max_draw_calls']})")
        check(p["frame_ms_p95"] < 8.0, f"frame time p95 < 8 ms ({p['frame_ms_p95']:.2f} ms)")
sys.exit(1 if fails else 0)
PY
uv run --quiet --script "$APP/tools/test/check_render_scale.py" "$OUT/still_1.0_hud.png" "$OUT/still_0.5_hud.png" || status=1
exit $status
