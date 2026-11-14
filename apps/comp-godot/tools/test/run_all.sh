#!/usr/bin/env bash
# Every suite in order, continuing past failures, with a summary at the end.
# Logs land in $OUT (default apps/comp-godot/.screenshots/all), one per suite.
# Usage: tools/test/run_all.sh [--quick] [--no-sim] [--soak-minutes=N]
#   --quick   skip the 10 minute soak and the robot sim (about 8 minutes total)
#   --no-sim  skip the robot sim e2e (needs the FIR checkout and WPILib 2027)
set -uo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
T="$APP/tools/test"
OUT="${OUT:-$APP/.screenshots/all}"
mkdir -p "$OUT"
SOAK=1
SIM=1
SOAK_MINUTES=10
for a in "$@"; do
  case "$a" in
    --quick) SOAK=0; SIM=0 ;;
    --no-sim) SIM=0 ;;
    --soak-minutes=*) SOAK_MINUTES="${a#--soak-minutes=}" ;;
    *) echo "unknown argument $a" >&2; exit 2 ;;
  esac
done

SUITES=(
  "unit:$T/run_unit.sh"
  "integration:$T/run_integration.sh"
  "screenshots-3d:$T/run_screenshots.sh"
  "hud:$T/run_hud_screenshots.sh"
  "touch:$T/run_touch_screenshots.sh"
  "preview:$T/run_preview_checks.sh"
  "perf:$T/run_perf.sh"
  "two-process:$T/run_two_process.sh"
  "chaos:$T/run_chaos.sh"
  "export:$T/run_export.sh"
)
[[ $SOAK == 1 ]] && SUITES+=("soak:$T/run_soak.sh --minutes=$SOAK_MINUTES")
[[ $SIM == 1 ]] && SUITES+=("sim-e2e:$T/run_sim_e2e.sh")

results=()
failed=0
for entry in "${SUITES[@]}"; do
  name="${entry%%:*}"
  cmd="${entry#*:}"
  start=$(date +%s)
  printf '%-14s ... ' "$name"
  # shellcheck disable=SC2086
  if $cmd >"$OUT/$name.log" 2>&1; then
    verdict="ok"
  else
    verdict="FAIL"
    failed=$((failed + 1))
  fi
  secs=$(( $(date +%s) - start ))
  echo "$verdict (${secs} s)"
  results+=("$(printf '%-4s %-14s %4d s  %s' "$verdict" "$name" "$secs" "$OUT/$name.log")")
  [[ $verdict == FAIL ]] && grep -E "^FAIL|FAIL |DEV FAIL|CHECK FAIL" "$OUT/$name.log" | head -10 | sed 's/^/    /'
done

leftovers=0
if pgrep -f "fake_robot.py" >/dev/null; then
  echo "FAIL fake robot processes still running:"; pgrep -fl "fake_robot.py"; leftovers=1
fi
if nc -z -G 1 127.0.0.1 5810 >/dev/null 2>&1; then
  echo "FAIL something still listens on :5810"; leftovers=1
fi

echo
echo "== summary"
printf '%s\n' "${results[@]}"
[[ $leftovers == 0 ]] && echo "no fake robot or sim left running" || failed=$((failed + 1))
echo "$failed failure(s)"
exit $(( failed > 0 ? 1 : 0 ))
