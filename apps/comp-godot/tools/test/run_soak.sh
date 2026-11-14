#!/usr/bin/env bash
# Soak: both windows against the fake robot looping full matches at 8x (about
# 21 s each) while the Auto tab preview loops, for --minutes (default 10).
# Passes when the log has no script errors, errors or warnings (also none at
# exit), static memory and process RSS grow less than 20 MB after the first
# minute, no orphan nodes are left at the end, every match phase was seen and
# NT never dropped. Reports land in $OUT (default apps/comp-godot/.screenshots/soak).
# Usage: tools/test/run_soak.sh [--minutes=N]
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-godot}"
OUT="${OUT:-$APP/.screenshots/soak}"
WORK="$OUT/work"
MINUTES=10
for a in "$@"; do
  case "$a" in
    --minutes=*) MINUTES="${a#--minutes=}" ;;
    *) echo "unknown argument $a" >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT" "$WORK"
source "$APP/tools/test/lib_fake_robot.sh"
APP_PID=""
cleanup() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
  stop_fakes
}
trap cleanup EXIT
"$GODOT" --headless --path "$APP" --import >/dev/null 2>&1 || true
export PWRUP_SHARED_SETTINGS_PATH="$WORK/connection-settings.json"
printf '%s\n' '{}' >"$WORK/settings.json"

start_fake soak --match --loop --speed 8 --motion --alliance blue
SECONDS_TOTAL="$(python3 -c "print(int(float('$MINUTES') * 60))")"
echo "soak: $MINUTES min against the fake robot on :$FAKE_PORT"
"$GODOT" --path "$APP" -- --screen=both --live --fixture=live_match_preview \
  --nt-host=127.0.0.1 --nt-port="$FAKE_PORT" --settings="$WORK/settings.json" \
  --frames=30 --run-s="$SECONDS_TOTAL" --sample-s=10 --report="$OUT/soak.json" >"$OUT/soak.log" 2>&1 &
APP_PID=$!
START="$(date +%s)"
: >"$OUT/rss.csv"
while kill -0 "$APP_PID" 2>/dev/null; do
  rss="$(ps -o rss= -p "$APP_PID" 2>/dev/null | tr -d ' ' || true)"
  [[ -n "$rss" ]] && echo "$(( $(date +%s) - START )),$rss" >>"$OUT/rss.csv"
  sleep 10
done
set +e
wait "$APP_PID"
APP_STATUS=$?
set -e
APP_PID=""
stop_fakes

python3 - "$OUT" "$APP_STATUS" "$SECONDS_TOTAL" <<'PY'
import json, re, sys
out, app_status, total = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
fails = []
def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        fails.append(msg)
log = open(f"{out}/soak.log").read()
bad = [l for l in log.splitlines() if re.search(r"SCRIPT ERROR|ERROR|WARNING|leaked|Orphan", l)]
check(app_status == 0, f"app exited 0 (got {app_status})")
check(not bad, f"no errors or warnings in the log, also at exit {bad[:5]}")
r = json.load(open(f"{out}/soak.json"))
soak = r["soak"]
check(not r["failures"], f"no Dev failures {r['failures']}")
check(soak["seconds"] >= total, f"ran {soak['seconds']:.0f} s with {soak['frames']} frames, worst frame {soak['worst_frame_ms']:.1f} ms")
samples = soak["samples"]
base = next(s for s in samples if s["t"] >= 60)
later = [s for s in samples if s["t"] >= 60]
growth = max(s["static_memory"] for s in later) - base["static_memory"]
end_growth = samples[-1]["static_memory"] - base["static_memory"]
check(growth < 20e6, f"static memory growth after the first minute {growth / 1e6:.2f} MB (end {end_growth / 1e6:+.2f} MB) < 20 MB")
rss = [tuple(map(int, l.split(","))) for l in open(f"{out}/rss.csv") if l.strip()]
rss_later = [kb for t, kb in rss if t >= 60]
if rss_later:
    rss_growth = (max(rss_later) - rss_later[0]) * 1024
    check(rss_growth < 20e6, f"process RSS growth after the first minute {rss_growth / 1e6:.2f} MB < 20 MB "
          f"({rss_later[0] / 1024:.0f} -> {rss_later[-1] / 1024:.0f} MB)")
objects = [s["objects"] for s in later]
check(max(objects) - min(objects) < 200, f"object count stable after the first minute ({min(objects)}..{max(objects)})")
nodes = [s["nodes"] for s in later]
check(max(nodes) - min(nodes) < 50, f"node count stable ({min(nodes)}..{max(nodes)})")
check(r["objects"]["orphan_nodes"] == 0, f"orphan nodes at exit: {r['objects']['orphan_nodes']}")
phases = set(soak["phases"])
want = {"pre_match", "autonomous", "transition", "shift1", "shift2", "shift3", "shift4", "endgame", "post_match"}
check(want <= phases, f"every match phase seen ({len(phases & want)}/9), missing {sorted(want - phases)}")
check(soak["reconnects"] == 0 and soak["nt_states"] == ["READY"], f"NT stayed READY (states {soak['nt_states']}, reconnects {soak['reconnects']})")
check(soak["preview_loops"] >= total // 25, f"the 20 s preview kept looping ({soak['preview_loops']} loops)")
fps = [s["fps"] for s in later]
print(f"     fps {min(fps)}..{max(fps)} at the 60 fps cap, static memory {base['static_memory'] / 1e6:.1f} MB at 60 s")
sys.exit(1 if fails else 0)
PY
