#!/usr/bin/env bash
# Adaptive recompilation for a game with no hand-made project.
#   adapt.sh <game dir> <disc.cue> [rounds] [parallel runs] [seconds per run]
# Each round: headless discovery runs with pseudo-random input record the code
# the game loads from disc (overlays) and where the interpreter still ran;
# the captures are merged into <game>/coverage (additive, never shrinks) and
# compiled into generated/overlays_static.c, then the discovery runtime is
# rebuilt with them. Stops early when a round finds nothing new.
# Prints "interp=<instructions>" per round so progress is visible.
set -euo pipefail
GAME="$(cd "$1" && pwd -P)"; CUE="$2"
ROUNDS="${3:-3}"; PAR="${4:-3}"; SECS="${5:-150}"
HERE="$(cd "$(dirname "$0")" && pwd -P)"
FW="$(cd "$GAME/psxrecomp" && pwd -P)"
BUILD="$GAME/build-disc"
cd "$GAME"

build() {
  CC=clang CXX=clang++ cmake -S . -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DPSX_RECOMP_UI=OFF -DPSX_NETPLAY=OFF -DPSX_REWIND=OFF -DPSX_ENABLE_VULKAN=OFF \
    -DPSX_NATIVE_CPU_SPANS=OFF > adapt-configure.log 2>&1 || { tail -8 adapt-configure.log >&2; return 1; }
  cmake --build "$BUILD" --target psx-runtime > adapt-build.log 2>&1 \
    || { grep -m5 error adapt-build.log >&2; return 1; }
}

link_static_overlays() {
  # The project's runtime target takes the compiled overlays once they exist.
  grep -q GAME_OVERLAY_STATIC_C CMakeLists.txt && return 0
  python3 - CMakeLists.txt <<'PY'
import re, sys
p = sys.argv[1]; t = open(p).read()
# Before GEN_MARKER: after the multi-value GEN_FULL_GLOB it would be
# swallowed as one more glob instead of reaching the runtime target.
t = re.sub(r'(\n(\s*)GEN_MARKER )',
           r'\n\2GAME_OVERLAY_STATIC_C "${CMAKE_CURRENT_SOURCE_DIR}/generated/overlays_static.c"\1', t, count=1)
open(p, 'w').write(t)
PY
}

compile_overlays() {
  python3 "$FW/tools/coverage_vault.py" compact --vault coverage --output coverage/merged.json > /dev/null
  python3 "$FW/tools/compile_overlays.py" --static --force --captures coverage/merged.json --game-toml game.toml \
    --recompiler "$FW/recompiler/build/psxrecomp-game" --runtime-include "$FW/runtime/include" \
    --project-root . --out-dir generated --gcc clang --main-exe "$(python3 -c 'import tomllib;print(tomllib.load(open("game.toml","rb"))["game"]["exe"])')" \
    > adapt-overlays.log 2>&1 || { tail -5 adapt-overlays.log >&2; exit 1; }
}

# Coverage from earlier runs (or another framework layout) is recompiled first.
if [ -s coverage/merged.json ]; then
  compile_overlays; link_static_overlays; build
else
  [ -x "$BUILD/$(cat "$BUILD/psxrecomp_exe_name-psx-runtime.txt" 2>/dev/null)" ] || build
fi
mkdir -p coverage
best=""
for round in $(seq 1 "$ROUNDS"); do
  EXE="$BUILD/$(cat "$BUILD/psxrecomp_exe_name-psx-runtime.txt")"
  rm -rf discover; mkdir -p discover
  for k in $(seq 1 "$PAR"); do
    python3 "$HERE/discover.py" "$EXE" "$GAME/game.toml" "$CUE" "$GAME/discover/run$k" \
      $((47000 + RANDOM % 2000)) "$SECS" $((round * 100 + k)) > "discover/run$k.json" 2>"discover/run$k.err" &
  done
  wait
  interp=$(python3 -c 'import json,glob; print(sum(json.loads(open(f).read() or "{}").get("interp_insns",0) for f in glob.glob("discover/run*.json")))')
  frames=$(python3 -c 'import json,glob; print(sum(json.loads(open(f).read() or "{}").get("frame",0) or 0 for f in glob.glob("discover/run*.json")))')
  echo "   round $round: interp=$interp insns over $frames frames"
  before=$(python3 "$FW/tools/coverage_vault.py" stats --vault coverage 2>/dev/null | md5sum)
  for c in discover/run*/overlay_captures.json; do
    [ -s "$c" ] && python3 "$FW/tools/coverage_vault.py" merge --vault coverage --captures "$c" > /dev/null
  done
  after=$(python3 "$FW/tools/coverage_vault.py" stats --vault coverage 2>/dev/null | md5sum)
  [ "$before" = "$after" ] && [ "$round" -gt 1 ] && { echo "   no new code found; stopping"; break; }
  compile_overlays
  link_static_overlays
  build
done
