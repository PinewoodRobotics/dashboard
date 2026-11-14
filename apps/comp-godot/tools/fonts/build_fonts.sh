#!/usr/bin/env bash
# Static Inter and Roboto Mono weights cut from the upstream variable fonts,
# with overlapping contours merged. The UI renders text as MSDF (one glyph
# texture per weight for every size), and msdfgen draws artifacts where a
# variable font's contours overlap.
# Usage: tools/fonts/build_fonts.sh /path/to/InterVariable.ttf /path/to/RobotoMono-VariableFont_wght.ttf
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
INTER="${1:?Inter variable font}"
MONO="${2:?Roboto Mono variable font}"
OUT="$APP/ui/fonts"
run() { uv run --quiet --python 3.12 --with fonttools==4.58.4 --with skia-pathops==0.9.2 fonttools varLib.instancer "$@"; }
for w in 300 400 500 600 700; do
  run "$INTER" opsz=14 wght=$w --remove-overlaps --update-name-table -q -o "$OUT/Inter-$w.ttf"
done
for w in 400 500; do
  run "$MONO" wght=$w --remove-overlaps --update-name-table -q -o "$OUT/RobotoMono-$w.ttf"
done
