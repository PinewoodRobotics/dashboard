#!/usr/bin/env bash
# Generates every path in data/pathplanner with the robot's own PathplannerLib-java,
# using the Gradle classpath of the FIR scratch copy that run_sim_e2e.sh maintains
# (never the FIR repo itself), and writes tools/pathplanner/java_trajectories.json.
# export_autos.py plays back these trajectories and compares them with the Python
# library for the parity table in data/autos/index.json.
# Env: FIR_SRC (robot project, read only), FIR_SIM_DIR (scratch copy, default
#      apps/comp-godot/.scratch/fir-sim), SIM_JAVA_HOME (default ~/.wpilib/2027_alpha7/jdk).
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
FIR_SRC="${FIR_SRC:-$HOME/Developer/FIR/src/2026Rebuilt}"
FIR_SIM_DIR="${FIR_SIM_DIR:-$APP/.scratch/fir-sim}"
JAVA_HOME="${SIM_JAVA_HOME:-$HOME/.wpilib/2027_alpha7/jdk}"
export JAVA_HOME

case "$FIR_SIM_DIR" in
  "$(dirname "$(dirname "$FIR_SRC")")"/*) echo "FIR_SIM_DIR must be outside the FIR checkout" >&2; exit 2 ;;
esac
fir_status() { git -C "$FIR_SRC" status --porcelain 2>/dev/null || true; }
FIR_STATUS_BEFORE="$(fir_status)"

if [[ ! -f "$FIR_SIM_DIR/build.gradle" ]]; then
  if [[ ! -f "$FIR_SRC/build.gradle" ]]; then
    echo "no FIR scratch copy at $FIR_SIM_DIR and no robot project at $FIR_SRC" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$FIR_SIM_DIR")"
  touch "$(dirname "$FIR_SIM_DIR")/.gdignore"
  rsync -a --exclude .git --exclude build --exclude .gradle --exclude logs --exclude node_modules \
    --exclude ctre_sim --exclude replays "$FIR_SRC/" "$FIR_SIM_DIR/"
fi

WORK="$FIR_SIM_DIR/build/pwrup-trajectory-dump"
mkdir -p "$WORK/classes" "$WORK/run/src/main/deploy"
rsync -a --delete "$APP/data/pathplanner/" "$WORK/run/src/main/deploy/pathplanner/"

cat >"$WORK/cp.init.gradle" <<'GRADLE'
allprojects {
  afterEvaluate { p ->
    if (p.plugins.hasPlugin('java')) {
      p.tasks.register('pwrupPrintClasspath') {
        def cp = p.sourceSets.main.runtimeClasspath
        doLast { println "PWRUP_CP=" + cp.asPath }
      }
    }
  }
}
GRADLE

(cd "$FIR_SIM_DIR" && ./gradlew -q --console=plain --no-configuration-cache -I "$WORK/cp.init.gradle" pwrupPrintClasspath) \
  | sed -n 's/^PWRUP_CP=//p' >"$WORK/cp.txt"
CP="$(cat "$WORK/cp.txt")"
if [[ -z "$CP" ]]; then
  echo "could not resolve the robot runtime classpath" >&2
  exit 1
fi
grep -o '[^:]*PathplannerLib-java-[^:]*\.jar' <<<"$CP" | head -1

"$JAVA_HOME/bin/javac" -d "$WORK/classes" -cp "$CP" "$APP/tools/pathplanner/TrajectoryDump.java"
(cd "$WORK/run" && "$JAVA_HOME/bin/java" -Djava.library.path="$FIR_SIM_DIR/build/jni/release" \
  -cp "$WORK/classes:$CP" TrajectoryDump) >"$WORK/java_raw.json"

PP_VERSION="$(grep -o 'PathplannerLib-java-[0-9][^/:]*\.jar' <<<"$CP" | head -1 | sed -E 's/PathplannerLib-java-(.*)\.jar/\1/')"
python3 -I - "$WORK/java_raw.json" "$APP/data/pathplanner/paths" "$APP/tools/pathplanner/java_trajectories.json" "$PP_VERSION" <<'PY'
import datetime, hashlib, json, sys
from pathlib import Path
raw, paths_dir, out, version = sys.argv[1:5]
src = Path(paths_dir)
entries = sorted((p.relative_to(src).as_posix(), hashlib.sha256(p.read_bytes()).hexdigest())
                 for p in src.rglob("*") if p.is_file() and not p.name.startswith("."))
h = hashlib.sha256()
for rel, digest in entries:
    h.update(f"{rel}\n{digest}\n".encode())
dump = json.loads(Path(raw).read_text())
dump = {
    "library": {"name": "PathplannerLib-java", "version": version},
    "dumped_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "paths_hash": h.hexdigest(),
    **dump,
}
prev = json.loads(Path(out).read_text()) if Path(out).is_file() else None
if prev is not None and {**prev, "dumped_at": None} == {**dump, "dumped_at": None}:
    print(f"unchanged {out}: {len(dump['paths'])} paths, PathplannerLib-java {version}")
else:
    Path(out).write_text(json.dumps(dump, separators=(",", ":")) + "\n")
    print(f"wrote {out}: {len(dump['paths'])} paths, PathplannerLib-java {version}")
PY

if [[ "$(fir_status)" != "$FIR_STATUS_BEFORE" ]]; then
  echo "the FIR repo changed during the dump" >&2
  exit 1
fi
