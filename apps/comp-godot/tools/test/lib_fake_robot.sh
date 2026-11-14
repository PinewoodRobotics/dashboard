# Sourced by the tools/test scripts that need tools/sim/fake_robot.py.
# start_fake NAME ARGS... starts one on a free port (sets FAKE_PORT, FAKE_PID_FILE)
# and waits until it listens; stop_fakes stops every fake robot this script started.
FAKE="$APP/tools/sim/fake_robot.py"
FAKE_TAG="comp-godot-$(basename "$0" .sh)-$$"

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

wait_port() {
  local port="$1" tries="${2:-100}"
  for _ in $(seq 1 "$tries"); do
    nc -z -G 1 127.0.0.1 "$port" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

start_fake() {
  local name="$1"; shift
  FAKE_PORT="$(free_port)"
  FAKE_PID_FILE="$WORK/$name.pid"
  uv run --quiet --script "$FAKE" --port "$FAKE_PORT" --pid-file "$FAKE_PID_FILE" --tag "$FAKE_TAG" "$@" >"$WORK/$name.log" 2>&1 &
  wait_port "$FAKE_PORT" || { echo "fake robot $name did not start:"; cat "$WORK/$name.log"; return 1; }
}

stop_fakes() {
  pkill -f -- "--tag $FAKE_TAG" 2>/dev/null || true
  sleep 0.3
  pkill -9 -f -- "--tag $FAKE_TAG" 2>/dev/null || true
}
