#!/usr/bin/env bash
# End-to-end against the real robot code: refreshes a scratch copy of the FIR
# robot project (never the repo itself), disables the PhotonVision cameras and
# the sim GUI there, runs the WPILib sim (NT4 server on 5810), runs tests/sim
# and a windowed overlay screenshot, then stops the sim and checks that port
# 5810 is free and the FIR repo is unchanged.
#
# Env: FIR_SRC (robot project), FIR_SIM_DIR (scratch copy, outside both repos),
#      SIM_JAVA_HOME (WPILib JDK), GODOT.
# Usage: tools/test/run_sim_e2e.sh [--filter=substr] [--no-screenshot]
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot}"
FIR_SRC="${FIR_SRC:-$HOME/Developer/FIR/src/2026Rebuilt}"
FIR_SIM_DIR="${FIR_SIM_DIR:-${TMPDIR:-/tmp}/pwrup-comp-godot-fir-sim}"
SIM_JAVA_HOME="${SIM_JAVA_HOME:-$HOME/.wpilib/2027_alpha7/jdk}"
PORT=5810
SCREENSHOT=1
ARGS=()
for a in "$@"; do
  case "$a" in
    --no-screenshot) SCREENSHOT=0 ;;
    *) ARGS+=("$a") ;;
  esac
done

case "$FIR_SIM_DIR" in
  "$FIR_SRC"*|"$APP"*) echo "FIR_SIM_DIR must be outside the FIR and dashboard repos" >&2; exit 2 ;;
esac

# The robot project is its own repo nested inside the FIR checkout; watch both.
FIR_REPOS=()
for d in "$FIR_SRC" "$(dirname "$(dirname "$FIR_SRC")")"; do
  root="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$root" && ! " ${FIR_REPOS[*]-} " =~ " $root " ]] && FIR_REPOS+=("$root")
done
fir_status() {
  local r
  for r in "${FIR_REPOS[@]}"; do echo "== $r"; git -C "$r" status --porcelain; done
}
FIR_STATUS_BEFORE="$(fir_status)"

port_open() { nc -z -G 1 127.0.0.1 "$PORT" >/dev/null 2>&1; }

if port_open; then
  echo "port $PORT is already in use; refusing to start a second NT server" >&2
  exit 2
fi

mkdir -p "$FIR_SIM_DIR"
rsync -a --delete \
  --exclude .git --exclude build --exclude .gradle --exclude logs --exclude node_modules \
  --exclude ctre_sim --exclude replays --exclude "hs_err_pid*" --exclude sim-e2e.log --exclude networktables.json \
  "$FIR_SRC/" "$FIR_SIM_DIR/"
# PhotonVision's 2027 alpha JNI needs libcscore, which is missing on macOS.
sed -i '' -E 's/camera\("([a-z_]+)", true,/camera("\1", false,/' \
  "$FIR_SIM_DIR/src/main/java/frc/robot/constant/VisionConstants.java"
sed -i '' -E 's/wpi\.sim\.addGui\(\)\.defaultEnabled = true/wpi.sim.addGui().defaultEnabled = false/' \
  "$FIR_SIM_DIR/build.gradle"

LOG="$FIR_SIM_DIR/sim-e2e.log"
(
  cd "$FIR_SIM_DIR"
  exec env JAVA_HOME="$SIM_JAVA_HOME" ./gradlew run --console=plain --no-daemon
) >"$LOG" 2>&1 &
SIM_PID=$!

descendants() {
  local p
  for p in $(pgrep -P "$1" 2>/dev/null); do
    descendants "$p"
    echo "$p"
  done
}

stop_sim() {
  local pids
  pids="$(descendants "$SIM_PID") $SIM_PID"
  kill $pids 2>/dev/null || true
  for _ in $(seq 1 40); do
    port_open || break
    sleep 0.5
  done
  # Anything still holding the port was started by this script (it was free before).
  local holders
  holders="$(lsof -t -nP -iTCP:$PORT -sTCP:LISTEN 2>/dev/null || true)"
  [[ -n "$holders" ]] && kill -9 $holders 2>/dev/null || true
  kill -9 $pids 2>/dev/null || true
  pkill -9 -f -- "$FIR_SIM_DIR" 2>/dev/null || true
  sleep 0.5
}
trap stop_sim EXIT

echo "waiting for the sim NT server on :$PORT (log: $LOG)"
for i in $(seq 1 600); do
  port_open && break
  if ! kill -0 "$SIM_PID" 2>/dev/null; then
    echo "sim exited early:"; tail -40 "$LOG"; exit 1
  fi
  sleep 1
done
port_open || { echo "sim did not open :$PORT"; tail -40 "$LOG"; exit 1; }
echo "sim is listening"

"$GODOT" --headless --path "$APP" --import >/dev/null 2>&1 || true
set +e
PWRUP_SIM_PORT="$PORT" PWRUP_SIM_CAPTURE_GOLDEN="${PWRUP_SIM_CAPTURE_GOLDEN:-1}" \
  "$GODOT" --headless --path "$APP" --script res://tests/run_tests.gd -- --dir=sim "${ARGS[@]+"${ARGS[@]}"}"
STATUS=$?
if [[ $SCREENSHOT == 1 ]]; then
  mkdir -p "$APP/.screenshots"
  PWRUP_SHARED_SETTINGS_PATH="$FIR_SIM_DIR/no-shared-settings.json" \
    "$GODOT" --path "$APP" -- --nt-host=127.0.0.1 --nt-port="$PORT" --debug-overlay \
    --screenshot="$APP/.screenshots/sim_overlay.png" --screenshot-delay=4 || STATUS=1
fi
set -e

stop_sim
trap - EXIT

if port_open; then
  echo "FAIL: something still listens on :$PORT" >&2
  STATUS=1
fi
if pgrep -f -- "$FIR_SIM_DIR" >/dev/null; then
  echo "FAIL: sim processes still running" >&2
  STATUS=1
fi
if [[ "$(fir_status)" != "$FIR_STATUS_BEFORE" ]]; then
  echo "FAIL: FIR git status changed" >&2
  STATUS=1
fi
echo "sim stopped, :$PORT free, git status unchanged in: ${FIR_REPOS[*]}"
exit $STATUS
