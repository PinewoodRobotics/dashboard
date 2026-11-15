#!/usr/bin/env bash
# SF Pro cut down to the SF Symbols and text the dashboard draws (the web app
# loads the whole 26 MB variable font from apps/comp/public/fonts). Instanced
# at the web's rendering (.sf-symbol: wght 400, wdth 100; opsz 28, what the
# browser's automatic optical size picks at 28 px and up) with overlaps merged.
# Usage: tools/fonts/build_sf_symbols.sh [path/to/SF-Pro.ttf]
set -euo pipefail
APP="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${1:-$APP/../comp/public/fonts/SF-Pro.ttf}"
OUT="$APP/ui/fonts/SF-Pro-400.ttf"
SYMBOLS=(
  1008F1 100B31 100DD6 100DD7 10114B 10114C 1003B8 10064C 100B28 100CF4 1010AE 1010AF 1012EA 1012EB
  10064A 10064B 10094E 10094F 10042F 100430 100174 100175 10031E 10031F
  101FE2 101FE3 1003DE 1002D3 1002D4 1003AC 1003AD 100184 100185
  10004E 1003BC 10037A 100A15
)
TEXT="U+0020-007E,U+00A0-00FF,U+2010-2027,U+2030-203A,U+2122"
UNICODES="$TEXT$(printf ',U+%s' "${SYMBOLS[@]}")"
TMP="$(mktemp -d)"
trap '/usr/bin/trash "$TMP" 2>/dev/null || true' EXIT
ft() { uv run --quiet --python 3.12 --with fonttools==4.58.4 --with skia-pathops==0.9.2 fonttools "$@"; }
ft subset "$SRC" --unicodes="$UNICODES" --layout-features='*' --no-hinting --output-file="$TMP/subset.ttf"
ft varLib.instancer "$TMP/subset.ttf" wght=400 wdth=100 opsz=28 --remove-overlaps --update-name-table -q -o "$OUT"
