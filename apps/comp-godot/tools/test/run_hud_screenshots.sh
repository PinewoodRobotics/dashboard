#!/usr/bin/env bash
# HUD fixture screenshots at the 1920x1080 design size (offline, no socket),
# each with its pixel probes, then cross-fixture checks in check_hud.py.
# PNGs and JSON reports land in $OUT (default apps/comp-godot/.screenshots/m3).
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot}"
OUT="${OUT:-$APP/.screenshots/m3}"
mkdir -p "$OUT"
# PWRUP_EXPORTED_BIN runs an exported binary instead of the project (no --path, no import).
if [[ -n "${PWRUP_EXPORTED_BIN:-}" ]]; then
  RUN=("$PWRUP_EXPORTED_BIN")
else
  RUN=("$GODOT" --path "$APP")
  "$GODOT" --headless --path "$APP" --import >/dev/null 2>&1 || true
fi

FIXTURES=(hud_pre_match hud_autonomous hud_transition hud_shift_active hud_shift_warning hud_shift_inactive
  hud_endgame hud_post_match hud_nt_disconnected hud_no_data hud_pose_invalid hud_stale hud_lane_toast hud_map_driver)

status=0
for fx in "${FIXTURES[@]}"; do
  python3 -c 'import json,sys,time; json.dump({"launch_unix": time.time()}, open(sys.argv[1], "w"))' "$OUT/$fx.launch.json"
  if ! "${RUN[@]}" -- --screen=hud --design-size --fixture="$fx" --screenshot="$OUT/$fx" >"$OUT/$fx.log" 2>&1; then
    echo "FAIL $fx:"; grep -E "DEV FAIL|ERROR|SCRIPT" "$OUT/$fx.log" || tail -5 "$OUT/$fx.log"
    status=1
  else
    echo "ok   $fx"
  fi
done

python3 "$APP/tools/test/check_hud.py" "$OUT" "${FIXTURES[@]}" || status=1
exit $status
