#!/usr/bin/env bash
# Exports the release builds and smoke-tests them:
# - build/windows-arm64 and build/windows-x64: PWRUP-Comp.exe + .pck (+ the
#   launchers from tools/windows), checked by tools/export/check_export.py (PE
#   machine type, every runtime file in the pck);
# - build/macos/PWRUP-Comp.app (arm64, ad-hoc signed), whose binary then runs the
#   HUD and touchscreen fixture screenshot suites (proves nothing depends on
#   editor-only files).
# Needs the Godot 4.7.2 export templates (README, "Windows export").
# Usage: tools/test/run_export.sh [--no-runs]
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot}"
OUT="${OUT:-$APP/.screenshots/export}"
RUNS=1
[[ "${1:-}" == "--no-runs" ]] && RUNS=0
mkdir -p "$APP/build/windows-arm64" "$APP/build/windows-x64" "$APP/build/macos" "$OUT"
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

status=0
for arch in arm64 x64; do
  dir="$APP/build/windows-$arch"
  /usr/bin/trash "$dir/PWRUP-Comp.exe" "$dir/PWRUP-Comp.pck" 2>/dev/null || true
  export_preset "Windows ${arch/arm64/ARM64}" "$dir/PWRUP-Comp.exe" "windows-$arch"
  cp "$APP/tools/windows/"*.bat "$dir/"
  python3 "$APP/tools/export/check_export.py" "$APP" "$dir/PWRUP-Comp.exe" "${arch/x64/x86_64}" || status=1
  for bat in PWRUP-Comp.bat PWRUP-Comp-TwoProcess.bat PWRUP-Comp-Benchmark.bat; do
    [[ -f "$dir/$bat" ]] && file "$dir/$bat" | grep -q "with CRLF line terminators" \
      && echo "ok   launcher $bat (CRLF) next to the $arch exe" || { echo "FAIL launcher $bat missing or not CRLF ($arch)"; status=1; }
  done
done
/usr/bin/trash "$APP/build/macos/PWRUP-Comp.app" 2>/dev/null || true
export_preset "macOS" "$APP/build/macos/PWRUP-Comp.app" macos
BIN="$APP/build/macos/PWRUP-Comp.app/Contents/MacOS/PWRUP Comp Dashboard"
file "$BIN" | grep -q "Mach-O 64-bit executable arm64" && echo "ok   macOS binary is arm64 only" || { echo "FAIL macOS binary: $(file -b "$BIN")"; status=1; }
codesign --verify --strict "$APP/build/macos/PWRUP-Comp.app" && codesign -dv "$APP/build/macos/PWRUP-Comp.app" 2>&1 | grep -q "Signature=adhoc" \
  && echo "ok   macOS app ad-hoc signed and valid" || { echo "FAIL macOS app signature"; status=1; }

if [[ $RUNS == 1 ]]; then
  [[ -x "$BIN" ]] || { echo "FAIL no macOS binary at $BIN"; exit 1; }
  # Startup: both windows from the exported binary. The first launch after an
  # export pays the macOS signature check, so the second one is measured.
  for run in cold warm; do
    python3 -c 'import json,sys,time; json.dump({"launch_unix": time.time()}, open(sys.argv[1], "w"))' "$OUT/startup.launch.json"
    "$BIN" -- --screen=both --fixture=m2_base --frames=5 --report="$OUT/startup_$run.json" --quit-after-run >"$OUT/startup_$run.log" 2>&1 || status=1
  done
  python3 - "$OUT" <<'PY' || status=1
import json, sys
out = sys.argv[1]
r = json.load(open(f"{out}/startup_warm.json"))
launch = json.load(open(f"{out}/startup.launch.json"))["launch_unix"]
t = r["timings"]
first = (t["first_frame_unix"] - launch) * 1000
visible = first + t["models_visible_msec"] - t["first_frame_msec"]
ok = first <= 1000 and visible <= 3000 and not r["failures"]
print(f"{'ok  ' if ok else 'FAIL'} exported build: first frame {first:.0f} ms after launch (<= 1000), models visible {visible:.0f} ms (<= 3000)")
sys.exit(0 if ok else 1)
PY
  echo "== HUD fixtures from the exported macOS binary"
  PWRUP_EXPORTED_BIN="$BIN" OUT="$OUT/hud" "$APP/tools/test/run_hud_screenshots.sh" || status=1
  echo "== touchscreen fixtures from the exported macOS binary"
  PWRUP_EXPORTED_BIN="$BIN" OUT="$OUT/touch" "$APP/tools/test/run_touch_screenshots.sh" || status=1
fi
exit $status
