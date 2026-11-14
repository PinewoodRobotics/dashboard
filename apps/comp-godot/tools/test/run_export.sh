#!/usr/bin/env bash
# Exports the release builds and smoke-tests them:
# - build/windows/PWRUP-Comp.exe + .pck (+ the PWRUP-Comp.bat launcher), checked
#   by tools/export/check_export.py (PE x86-64, every runtime file in the pck);
# - build/macos/PWRUP-Comp.app, whose binary then runs the HUD and touchscreen
#   fixture screenshot suites (proves nothing depends on editor-only files).
# Needs the Godot 4.7.2 export templates (README, "Windows export").
# Usage: tools/test/run_export.sh [--no-runs]
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot}"
OUT="${OUT:-$APP/.screenshots/export}"
RUNS=1
[[ "${1:-}" == "--no-runs" ]] && RUNS=0
mkdir -p "$APP/build/windows" "$APP/build/macos" "$OUT"
"$GODOT" --headless --path "$APP" --import >/dev/null 2>&1 || true

export_preset() {
  local preset="$1" target="$2" log="$OUT/export_$3.log"
  if ! "$GODOT" --headless --path "$APP" --export-release "$preset" "$target" >"$log" 2>&1; then
    echo "FAIL export $preset:"; cat "$log"; return 1
  fi
  if grep -E "ERROR|SCRIPT ERROR|WARNING" "$log"; then
    echo "FAIL export $preset logged errors or warnings (see $log)"; return 1
  fi
  echo "ok   export $preset -> ${target#"$APP"/}"
}

/usr/bin/trash "$APP/build/windows/PWRUP-Comp.exe" "$APP/build/windows/PWRUP-Comp.pck" "$APP/build/macos/PWRUP-Comp.app" 2>/dev/null || true
export_preset "Windows Desktop" "$APP/build/windows/PWRUP-Comp.exe" windows
cp "$APP/tools/windows/PWRUP-Comp.bat" "$APP/build/windows/PWRUP-Comp.bat"
export_preset "macOS" "$APP/build/macos/PWRUP-Comp.app" macos

status=0
python3 "$APP/tools/export/check_export.py" "$APP" "$APP/build/windows/PWRUP-Comp.exe" || status=1
[[ -f "$APP/build/windows/PWRUP-Comp.bat" ]] && grep -q $'\r$' "$APP/build/windows/PWRUP-Comp.bat" \
  && echo "ok   launcher PWRUP-Comp.bat (CRLF) next to the exe" || { echo "FAIL launcher missing or not CRLF"; status=1; }

if [[ $RUNS == 1 ]]; then
  BIN="$APP/build/macos/PWRUP-Comp.app/Contents/MacOS/PWRUP Comp Dashboard"
  [[ -x "$BIN" ]] || { echo "FAIL no macOS binary at $BIN"; exit 1; }
  echo "== HUD fixtures from the exported macOS binary"
  PWRUP_EXPORTED_BIN="$BIN" OUT="$OUT/hud" "$APP/tools/test/run_hud_screenshots.sh" || status=1
  echo "== touchscreen fixtures from the exported macOS binary"
  PWRUP_EXPORTED_BIN="$BIN" OUT="$OUT/touch" "$APP/tools/test/run_touch_screenshots.sh" || status=1
fi
exit $status
