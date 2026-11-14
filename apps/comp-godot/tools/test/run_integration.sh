#!/usr/bin/env bash
# Starts tools/sim/fake_robot.py (real ntcore) on a free port, runs the
# headless tests in tests/integration against it, and always tears it down.
# Env: PWRUP_TMP_DIR (scratch root, default apps/comp-godot/.scratch), GODOT.
# Usage: tools/test/run_integration.sh [--filter=substr]
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot}"
FAKE="$APP/tools/sim/fake_robot.py"
TMP_ROOT="${PWRUP_TMP_DIR:-$APP/.scratch}"
WORK="$TMP_ROOT/integration"
mkdir -p "$WORK"
touch "$TMP_ROOT/.gdignore"
export TMPDIR="$WORK/"
export PWRUP_SHARED_SETTINGS_PATH="${PWRUP_SHARED_SETTINGS_PATH:-$WORK/connection-settings.json}"
TAG="comp-godot-it-$$"

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

cleanup() {
  local pid
  if [[ -f "$WORK/fake_robot.pid" ]]; then
    pid="$(cat "$WORK/fake_robot.pid" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -CONT "$pid" 2>/dev/null || true
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  fi
  pkill -f -- "--tag $TAG" 2>/dev/null || true
  sleep 0.5
  pkill -9 -f -- "--tag $TAG" 2>/dev/null || true
  if pgrep -f -- "--tag $TAG" >/dev/null; then
    echo "WARNING: fake robot processes still running" >&2
  fi
}
trap cleanup EXIT

uv run --quiet --script "$FAKE" --help >/dev/null

PORT="$(free_port)"
CMD=(uv run --quiet --script "$FAKE" --port "$PORT" --total-topics 438 --pid-file "$WORK/fake_robot.pid" --persist-dir "$WORK/nt-persist" --tag "$TAG")
"${CMD[@]}" >"$WORK/fake_robot.log" 2>&1 &

for _ in $(seq 1 100); do
  nc -z -G 1 127.0.0.1 "$PORT" 2>/dev/null && break
  sleep 0.1
done
nc -z -G 1 127.0.0.1 "$PORT" || { echo "fake robot did not start"; cat "$WORK/fake_robot.log"; exit 1; }

CMD_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${CMD[@]}")"
"$GODOT" --headless --path "$APP" --import >/dev/null 2>&1 || true
set +e
PWRUP_FAKE_ROBOT_PORT="$PORT" \
PWRUP_FAKE_ROBOT_PIDFILE="$WORK/fake_robot.pid" \
PWRUP_FAKE_ROBOT_CMD="$CMD_JSON" \
  "$GODOT" --headless --path "$APP" --script res://tests/run_tests.gd -- --dir=integration "$@"
STATUS=$?
set -e
exit $STATUS
