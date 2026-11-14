#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SOURCE_ROOT="${SOURCE_ROOT:-${HOME}/Developer/FIR/src/2026Rebuilt/src/main/deploy/pathplanner}"
DEST_ROOT="${DEST_ROOT:-${REPO_ROOT}/apps/comp/public/pathplanner}"
GODOT_ROOT="${GODOT_ROOT:-${REPO_ROOT}/apps/comp-godot}"
GODOT_DEST="${GODOT_ROOT}/data/pathplanner"

APPLY_CHANGES=false
AUTOS_ONLY=false
SYNC_COMP=true
SYNC_GODOT=true
USER_DIR=""

default_user_dir() {
  case "$(uname -s)" in
    Darwin) echo "${HOME}/Library/Application Support/PWRUP/CompDashboard" ;;
    MINGW*|MSYS*|CYGWIN*)
      if [[ -z "${APPDATA:-}" ]]; then
        echo "APPDATA is not set; pass --user-dir=DIR" >&2
        return 1
      fi
      if command -v cygpath >/dev/null 2>&1; then
        echo "$(cygpath -u "${APPDATA}")/PWRUP/CompDashboard"
      else
        echo "${APPDATA}/PWRUP/CompDashboard"
      fi
      ;;
    *) echo "${XDG_DATA_HOME:-${HOME}/.local/share}/PWRUP/CompDashboard" ;;
  esac
}

print_help() {
  cat <<'EOF'
Sync PathPlanner files from FIR into this dashboard repo.

Usage:
  ./scripts/sync-pathplanner-from-fir.sh [--apply] [--autos-only] [--godot-only | --no-godot] [--user-dir[=DIR]]

Flags:
  --apply       Perform the copy (default is dry-run, which writes nothing).
  --autos-only  Sync only autos (skip paths).
  --godot-only  Skip apps/comp; only refresh the Godot dashboard copy and export.
  --no-godot    Skip the Godot dashboard step (apps/comp only, the old behavior).
  --user-dir[=DIR]
                After the Godot export, also copy it to DIR/autos, where an
                installed dashboard picks it up (Reload Autos on the Auto tab,
                or a restart) without re-exporting the app. DIR is the
                dashboard's user data folder; the default is this machine's:
                  Windows  %APPDATA%\PWRUP\CompDashboard
                  macOS    ~/Library/Application Support/PWRUP/CompDashboard
                  Linux    ~/.local/share/PWRUP/CompDashboard
                Use a USB stick path to carry the export to another laptop and
                copy its autos folder into that laptop's user data folder.
  --help        Show this help.

The Godot step copies autos/, paths/ and settings.json to
apps/comp-godot/data/pathplanner, then precomputes every auto with the official
PathPlannerLib (tools/pathplanner/export_autos.py, run with uv) into
apps/comp-godot/data/autos.

Env overrides:
  SOURCE_ROOT   Defaults to ~/Developer/FIR/src/2026Rebuilt/src/main/deploy/pathplanner
  DEST_ROOT     Defaults to apps/comp/public/pathplanner in this repo
  GODOT_ROOT    Defaults to apps/comp-godot in this repo
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY_CHANGES=true
      shift
      ;;
    --autos-only)
      AUTOS_ONLY=true
      shift
      ;;
    --godot-only)
      SYNC_COMP=false
      shift
      ;;
    --no-godot)
      SYNC_GODOT=false
      shift
      ;;
    --user-dir)
      USER_DIR="$(default_user_dir)"
      shift
      ;;
    --user-dir=*)
      USER_DIR="${1#--user-dir=}"
      if [[ -z "${USER_DIR}" ]]; then
        echo "--user-dir= needs a directory" >&2
        exit 1
      fi
      shift
      ;;
    --help|-h)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      print_help >&2
      exit 1
      ;;
  esac
done

if [[ "${SYNC_COMP}" == false && "${SYNC_GODOT}" == false ]]; then
  echo "--godot-only and --no-godot together leave nothing to sync" >&2
  exit 1
fi

if [[ -n "${USER_DIR}" && "${SYNC_GODOT}" == false ]]; then
  echo "--user-dir copies the Godot export; it cannot be combined with --no-godot" >&2
  exit 1
fi

if [[ ! -d "${SOURCE_ROOT}" ]]; then
  echo "Source root not found: ${SOURCE_ROOT}" >&2
  exit 1
fi

if [[ "${SYNC_COMP}" == true && "${APPLY_CHANGES}" == true ]]; then
  mkdir -p "${DEST_ROOT}/autos"
  mkdir -p "${DEST_ROOT}/paths"
fi

rsync_flags=(-avh --delete)
if [[ "${APPLY_CHANGES}" == false ]]; then
  rsync_flags+=(-n -c)
fi

sync_dir() {
  local name="$1"
  local dest_root="${2:-${DEST_ROOT}}"
  local src="${SOURCE_ROOT}/${name}/"
  local dest="${dest_root}/${name}/"

  if [[ ! -d "${src}" ]]; then
    echo "Missing source directory: ${src}" >&2
    exit 1
  fi

  echo "Syncing ${name}: ${src} -> ${dest}"
  rsync "${rsync_flags[@]}" "${src}" "${dest}"
}

if [[ "${APPLY_CHANGES}" == false ]]; then
  echo "Running in dry-run mode. Use --apply to copy files."
fi

if [[ "${SYNC_COMP}" == true ]]; then
  sync_dir "autos"
  if [[ "${AUTOS_ONLY}" == false ]]; then
    sync_dir "paths"
  fi
fi

if [[ "${SYNC_GODOT}" == true ]]; then
  if [[ ! -d "${GODOT_DEST}" ]]; then
    echo "Godot PathPlanner directory not found: ${GODOT_DEST}" >&2
    exit 1
  fi
  sync_dir "autos" "${GODOT_DEST}"
  if [[ "${AUTOS_ONLY}" == false ]]; then
    sync_dir "paths" "${GODOT_DEST}"
  fi
  echo "Syncing settings.json: ${SOURCE_ROOT}/settings.json -> ${GODOT_DEST}/settings.json"
  rsync "${rsync_flags[@]}" "${SOURCE_ROOT}/settings.json" "${GODOT_DEST}/settings.json"

  robot_src="$(cd "${SOURCE_ROOT}/../../../.." 2>/dev/null && pwd || true)"
  export_cmd=(uv run --quiet --script tools/pathplanner/export_autos.py)
  if [[ -n "${robot_src}" && -f "${robot_src}/src/main/java/frc/robot/RobotContainer.java" ]]; then
    export_cmd+=(--robot-src "${robot_src}")
  fi
  java_dump=("${GODOT_ROOT}/tools/pathplanner/run_java_dump.sh")
  if [[ "${APPLY_CHANGES}" == false ]]; then
    echo "Would dump the robot's Java trajectories: ${java_dump[*]}"
    echo "Would export autos: (cd ${GODOT_ROOT} && ${export_cmd[*]})"
  else
    if ! command -v uv >/dev/null 2>&1; then
      echo "uv is required for the Godot export step (https://docs.astral.sh/uv/)" >&2
      exit 1
    fi
    echo "Dumping the robot's Java trajectories"
    if [[ -n "${robot_src}" ]]; then
      FIR_SRC="${robot_src}" "${java_dump[@]}" 2> >(grep -v '^WARNING' >&2) \
        || echo "Java trajectory dump failed; the export only succeeds if the paths are unchanged" >&2
    else
      echo "No robot project next to ${SOURCE_ROOT}; keeping the existing Java trajectory dump" >&2
    fi
    echo "Exporting autos for the Godot dashboard"
    (cd "${GODOT_ROOT}" && "${export_cmd[@]}")
  fi
  if [[ -n "${USER_DIR}" ]]; then
    user_autos="${USER_DIR%/}/autos"
    if [[ "${APPLY_CHANGES}" == false ]]; then
      echo "Would copy ${GODOT_ROOT}/data/autos/ -> ${user_autos}/"
    else
      echo "Copying the export to ${user_autos}"
      mkdir -p "${user_autos}"
      # index.json goes last: the dashboard only trusts a folder whose index names files that exist.
      rsync -a --delete --exclude index.json "${GODOT_ROOT}/data/autos/" "${user_autos}/"
      rsync -a "${GODOT_ROOT}/data/autos/index.json" "${user_autos}/index.json"
      echo "Autos copied: tap Reload Autos on the dashboard's Auto tab (or restart it)."
    fi
  fi
fi

if [[ "${APPLY_CHANGES}" == false ]]; then
  echo "Dry-run complete."
else
  echo "Sync complete."
fi
