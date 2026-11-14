#!/usr/bin/env bash
# Touchscreen fixture screenshots and scripted-input runs (offline: no socket).
# Fixture screenshots cover every tab, panel, dock and keyboard state for
# --screen=touch and a subset for --screen=both. Scripted runs synthesize touch
# and mouse input through the Dev hook and fail on any unmet expectation; the
# *_restart runs reuse the settings file of the run before them to prove the
# layout, map and visual settings survive an app restart. The *_controls_live run
# selects an auto and drives the intake slider against the fake robot.
# PNGs, logs and JSON reports land in $OUT (default apps/comp-godot/.screenshots/m4).
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot}"
OUT="${OUT:-$APP/.screenshots/m4}"
mkdir -p "$OUT"
# PWRUP_EXPORTED_BIN runs an exported binary instead of the project (no --path, no import).
if [[ -n "${PWRUP_EXPORTED_BIN:-}" ]]; then
  RUN=("$PWRUP_EXPORTED_BIN")
else
  RUN=("$GODOT" --path "$APP")
  "$GODOT" --headless --path "$APP" --import >/dev/null 2>&1 || true
fi

status=0
run() {
  local name="$1" fixture="$2"; shift 2
  if "${RUN[@]}" -- --design-size --fixture="$fixture" --screenshot="$OUT/$name" --frames=5 "$@" >"$OUT/$name.log" 2>&1; then
    echo "ok   $name"
  else
    echo "FAIL $name:"; grep -E "DEV FAIL|ERROR|SCRIPT" "$OUT/$name.log" || tail -5 "$OUT/$name.log"
    status=1
  fi
}

SHOTS=(touch_driver touch_preset_turret touch_tab_auto touch_tab_settings touch_tab_effects touch_tab_howard
  touch_tab_robot3d touch_tab_robot3d_manual touch_tab_visual touch_panel_map touch_panel_intake touch_tab_visual_map
  touch_dock touch_dock_over_tab touch_gallery touch_gallery_keyboard touch_gallery_keypad
  touch_auto_selected touch_auto_locked touch_auto_conflict touch_auto_invalid touch_auto_none touch_settings_disconnected
  touch_intake_confirmed touch_intake_waiting touch_intake_disconnected touch_intake_readouts)
for fx in "${SHOTS[@]}"; do
  run "$fx" "$fx" --screen=touch
done
for fx in touch_driver touch_tab_robot3d touch_panel_map touch_dock; do
  run "both_$fx" "$fx" --screen=both
done

SETTINGS="$OUT/settings"
mkdir -p "$SETTINGS"
printf '%s\n' '{"layout": {"rail": ["auto", "record", "settings", "auto"], "dock": ["visual", "record", "auto", "auto"]}}' >"$SETTINGS/layout.json"
run touch_script_nav touch_script_nav --screen=touch --settings="$SETTINGS/layout.json"
run touch_script_restart touch_script_restart --screen=touch --settings="$SETTINGS/layout.json"
printf '%s\n' '{}' >"$SETTINGS/map.json"
run touch_script_map touch_script_map --screen=both --settings="$SETTINGS/map.json"
run touch_script_map_restart touch_script_map_restart --screen=both --settings="$SETTINGS/map.json"
printf '%s\n' '{}' >"$SETTINGS/visual.json"
run touch_script_visual touch_script_visual --screen=both --settings="$SETTINGS/visual.json"
run touch_script_visual_restart touch_script_visual_restart --screen=both --settings="$SETTINGS/visual.json"
run touch_script_widgets touch_script_widgets --screen=touch
run touch_script_widgets_both touch_script_widgets --screen=both
run touch_script_robot3d touch_script_robot3d --screen=both
run touch_script_robot3d_live touch_script_robot3d_live --screen=touch
run touch_script_driver touch_script_driver --screen=touch
run touch_script_howard touch_script_howard --screen=touch
run touch_script_controls_offline touch_script_controls_offline --screen=touch
run touch_script_displays touch_script_displays --screen=touch
run both_script_touch_test both_script_touch_test --screen=both

FAKE="$APP/tools/sim/fake_robot.py"
TAG="comp-godot-touch-$$"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
stop_fake() { pkill -f -- "--tag $TAG" 2>/dev/null || true; sleep 0.3; pkill -9 -f -- "--tag $TAG" 2>/dev/null || true; }
trap stop_fake EXIT
uv run --quiet --script "$FAKE" --port "$PORT" --pose 2.0,4.03,0 --alliance red --turret 0.25 --wrist 0.1 --tag "$TAG" >"$OUT/fake.log" 2>&1 &
for _ in $(seq 1 100); do nc -z -G 1 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.1; done
printf '%s\n' '{}' >"$SETTINGS/live.json"
run touch_live_fake touch_live_fake --screen=touch --live --nt-host=127.0.0.1 --nt-port="$PORT" --settings="$SETTINGS/live.json"
printf '%s\n' '{}' >"$SETTINGS/controls.json"
PWRUP_SHARED_SETTINGS_PATH="$SETTINGS/connection-settings.json" \
  run touch_script_controls_live touch_script_controls_live --screen=touch --live --nt-host=127.0.0.1 --nt-port="$PORT" --settings="$SETTINGS/controls.json"
stop_fake

python3 "$APP/tools/test/check_touch.py" "$OUT" "$SETTINGS" "${SHOTS[@]}" || status=1
exit $status
