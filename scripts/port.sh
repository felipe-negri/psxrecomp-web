#!/usr/bin/env bash
# Builds a PS1 game for the browser.
#   scripts/port.sh <name> <disc.cue|disc.chd|disc.pbp>
# Output: build/web-<name>/ (index.html, runtime .js/.wasm, disc/, web-files.txt).
# Only discs whose serial has a game project in scripts/web/games.txt are accepted:
# psxrecomp needs per-game configuration and seeds, not just the disc.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
NAME="${1:?usage: port.sh <name> <disc.cue|disc.chd|disc.pbp>}"
ROM="$(realpath "${2:?usage: port.sh <name> <disc.cue|disc.chd|disc.pbp>}")"
WORK="$ROOT/games"
OUT="$ROOT/build/web-$NAME"
N=7
step() { echo "== [$1/$N] $2"; }

step 1 "disc"
DISC="$WORK/discs/$NAME"
rm -rf "$DISC"; mkdir -p "$DISC"
case "${ROM,,}" in
  *.chd)
    command -v chdman >/dev/null || { echo "chdman is required for .chd" >&2; exit 1; }
    chdman extractcd -i "$ROM" -o "$DISC/game.cue" -ob "$DISC/game.bin" >/dev/null 2>&1 \
      || { echo "chdman extractcd failed" >&2; exit 1; } ;;
  *.cue)
    cp "$ROM" "$DISC/game.cue"
    grep -o 'FILE "[^"]*"' "$ROM" | sed 's/^FILE "//; s/"$//' | while read -r f; do
      ln -f "$(dirname "$ROM")/$f" "$DISC/$f" 2>/dev/null || cp "$(dirname "$ROM")/$f" "$DISC/$f"
    done ;;
  *.pbp)
    python3 "$ROOT/scripts/web/pbp2bin.py" "$ROM" "$DISC/game.bin" ;;
  *) echo "unsupported disc format: $ROM (use .cue, .chd or .pbp)" >&2; exit 1 ;;
esac
python3 "$ROOT/scripts/web/split_cue.py" "$DISC"
FIRST_BIN="$DISC/$(grep -o 'FILE "[^"]*"' "$DISC/game.cue" | head -1 | sed 's/^FILE "//; s/"$//')"

step 2 "identify"
SERIAL="$(python3 "$ROOT/scripts/web/disc_serial.py" "$FIRST_BIN")"
read -r REPO COMMIT FW_OVERRIDE UI_OVERRIDE < <(awk -v s="$SERIAL" '$1 == s { print $2, $3, $4, $5 }' "$ROOT/scripts/web/games.txt") || true
[ -n "${REPO:-}" ] || { echo "no psxrecomp game project for $SERIAL" >&2; exit 2; }
echo "   $SERIAL -> $REPO @ $COMMIT"

step 3 "game project"
GAME="$WORK/$(basename "$REPO" .git)"
if [ ! -d "$GAME/.git" ]; then git clone -q "$REPO" "$GAME"; fi
git -C "$GAME" fetch -q origin 2>/dev/null || true
git -C "$GAME" checkout -q -f "$COMMIT"
git -C "$GAME" submodule update -q --init recomp-ui 2>/dev/null || true
# Build against the framework commit the game pins (gitlink, or
# framework_pins.txt when the project records it there), plus this fork's web
# runtime, applied by anchors (scripts/web/apply_web.py) so it fits any commit.
pin_of() {  # <submodule path regex> <framework_pins key>
  git -C "$GAME" ls-tree HEAD | awk -v re="^($1)\$" '$2 == "commit" && $4 ~ re { print $3; exit }' | grep . \
    || sed -n "s/^$2=[0-9a-f]* (\([0-9a-f]\{40\}\)).*/\1/p" "$GAME/framework_pins.txt" 2>/dev/null | head -1
}
url_of() { git -C "$GAME" config -f .gitmodules --get-regexp "submodule\.($1)\.url" 2>/dev/null | awk '{ print $2; exit }'; }
PIN="${FW_OVERRIDE:-$(pin_of 'psxrecomp-v4|psxrecomp' psxrecomp)}"
[ -n "$PIN" ] || { echo "game pins no psxrecomp commit" >&2; exit 1; }
fetch_pin() {  # <repo> <commit> <urls...>
  local repo="$1" c="$2"; shift 2
  git -C "$repo" cat-file -e "$c^{commit}" 2>/dev/null && return 0
  for u in "$@"; do [ -n "$u" ] && git -C "$repo" fetch -q --depth 1 "$u" "$c" 2>/dev/null && return 0; done
  return 1
}
FW_URLS=(origin https://github.com/RetroPortingToolKit/psxrecomp.git "$(url_of 'psxrecomp-v4|psxrecomp')" https://github.com/mstan/psxrecomp.git)
if ! fetch_pin "$ROOT" "$PIN" "${FW_URLS[@]}"; then
  # Some projects commit a gitlink that was never pushed; their
  # framework_pins.txt names the published commit. Else use the web base.
  ALT="$(sed -n "s/^psxrecomp=[0-9a-f]* (\([0-9a-f]\{40\}\)).*/\1/p" "$GAME/framework_pins.txt" 2>/dev/null | head -1)"
  if [ -n "$ALT" ] && fetch_pin "$ROOT" "$ALT" "${FW_URLS[@]}"; then
    echo "   framework ${PIN:0:7} is not published; using ${ALT:0:7} from framework_pins.txt"; PIN="$ALT"
  else
    echo "   framework ${PIN:0:7} is not published; using the web base"
    PIN="$(cat "$ROOT/scripts/web/BASE")"
  fi
fi
if ! git -C "$ROOT" cat-file -e "$PIN:psxrecomp_cli.py" 2>/dev/null; then
  # Too old for the scripted generate flow: use the web base and its launcher UI.
  echo "   framework ${PIN:0:7} predates psxrecomp_cli.py; using the web base"
  PIN="$(cat "$ROOT/scripts/web/BASE")"; UI_OVERRIDE="${UI_OVERRIDE:-f009bd76e272b541df840878b9259125d24d44ee}"
fi
UI_PIN="${UI_OVERRIDE:-$(pin_of recomp-ui recomp-ui)}"
if [ -n "$UI_PIN" ]; then
  [ -e "$GAME/recomp-ui/.git" ] || { rm -rf "$GAME/recomp-ui"; git clone -q "$(url_of recomp-ui || true)" "$GAME/recomp-ui" 2>/dev/null \
    || git clone -q https://github.com/RetroPortingToolKit/recomp-ui.git "$GAME/recomp-ui"; }
  fetch_pin "$GAME/recomp-ui" "$UI_PIN" origin https://github.com/RetroPortingToolKit/recomp-ui.git https://github.com/mstan/recomp-ui.git \
    && git -C "$GAME/recomp-ui" checkout -q -f "$UI_PIN"
fi
FW="$WORK/framework/$PIN"
PATCH_ID="$(cat "$ROOT/scripts/web/apply_web.py" "$ROOT/runtime/src/psx_web_platform.c" "$ROOT/runtime/web/fetch_size.pre.js" | sha256sum | cut -c1-16)"
if [ "$(cat "$FW/.psx-web-patch" 2>/dev/null)" != "$PATCH_ID" ]; then
  echo "   framework ${PIN:0:7} + web runtime"
  git -C "$ROOT" worktree remove --force "$FW" 2>/dev/null || rm -rf "$FW"
  git -C "$ROOT" worktree prune
  git -C "$ROOT" worktree add -q --detach "$FW" "$PIN"
  python3 "$ROOT/scripts/web/apply_web.py" "$FW" "$ROOT" \
    || { echo "web runtime does not fit framework ${PIN:0:7}" >&2; exit 1; }
  echo "$PATCH_ID" > "$FW/.psx-web-patch"
fi
rm -rf "$GAME/psxrecomp-v4" "$GAME/psxrecomp"
ln -s "$FW" "$GAME/psxrecomp-v4"
ln -s psxrecomp-v4 "$GAME/psxrecomp"
mkdir -p "$GAME/mods/development"

step 4 "recompile (MIPS -> C)"
# Emitters build once per framework tree; drop a cache configured elsewhere.
EMIT_CACHE="$FW/recompiler/build/CMakeCache.txt"
if [ -f "$EMIT_CACHE" ] && ! grep -qx "CMAKE_HOME_DIRECTORY:INTERNAL=$(cd "$FW" && pwd -P)/recompiler" "$EMIT_CACHE"; then
  rm -rf "$FW/recompiler/build"
fi
generate() {
  python3 "$FW/psxrecomp_cli.py" generate --config "$GAME/game.toml" --project-root "$GAME" \
    --disc "$DISC/game.cue" --no-toolchain-download "$@" > "$WORK/$NAME-generate.log" 2>&1
}
if ! generate; then
  # Dumps that differ from the project's reference (PBP conversions, other
  # revisions) still carry the same boot EXE, which generate checks anyway.
  grep -qE "digests (are )?not in prepare_disc.known_" "$WORK/$NAME-generate.log" \
    && { echo "   disc differs from the project's reference dump; continuing"
         # Drop the reference digests from this local checkout (some CLI versions
         # do not pass --skip-hash-check on to prepare_disc); the EXE check stays.
         python3 - "$GAME/game.toml" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p).read()
t = re.sub(r'^known_(sizes|md5|sha1|crc32|sha256)\s*=\s*\[[^\]]*\]\s*\n', '', t, flags=re.M)
open(p, 'w').write(t)
PY
         generate --skip-hash-check; } \
    || { tail -5 "$WORK/$NAME-generate.log" >&2; exit 1; }
fi

step 5 "compile (C -> WebAssembly)"
# shellcheck disable=SC1091
source "$ROOT/tools/emsdk/emsdk_env.sh" >/dev/null 2>&1
# The cache pins absolute paths: start over when this checkout or the game
# tree moved (hosts that keep one tree per commit share games/).
STAMP="$(cd "$FW" && pwd -P)|$PATCH_ID|$(cd "$GAME" && pwd -P)"
if [ "$(cat "$GAME/build-web/.psx-port-root" 2>/dev/null)" != "$STAMP" ]; then
  rm -rf "$GAME/build-web"
fi
mkdir -p "$GAME/build-web"
echo "$STAMP" > "$GAME/build-web/.psx-port-root"
emcmake cmake -S "$GAME" -B "$GAME/build-web" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DPSX_RECOMP_UI=OFF -DPSX_NETPLAY=OFF -DPSX_REWIND=OFF -DPSX_ENABLE_VULKAN=OFF \
    > "$WORK/$NAME-configure.log" 2>&1 || { tail -5 "$WORK/$NAME-configure.log" >&2; exit 1; }
cmake --build "$GAME/build-web" --target psx-runtime > "$WORK/$NAME-build.log" 2>&1 \
  || { grep -m5 -E "error" "$WORK/$NAME-build.log" >&2; exit 1; }
EXE="$(cat "$GAME/build-web/psxrecomp_exe_name-psx-runtime.txt")"
# wasm-ld turns calls with mismatched C/C++ prototypes into traps.
grep -A2 "function signature mismatch" "$WORK/$NAME-build.log" | sed 's/^/   warning: /' || true

step 6 "package"
rm -rf "$OUT"; mkdir -p "$OUT/disc"
cp "$GAME/build-web/$EXE.js" "$GAME/build-web/$EXE.wasm" "$OUT/"
cp -r "$GAME/build-web/bios" "$GAME/build-web/mods" "$OUT/"
[ -d "$GAME/build-web/assets" ] && cp -r "$GAME/build-web/assets" "$OUT/"
cp "$GAME/game.toml" "$OUT/"
GAME_EXE="$(python3 -c 'import sys,tomllib;print(tomllib.load(open(sys.argv[1],"rb"))["game"]["exe"])' "$GAME/game.toml")"
mkdir -p "$OUT/$(dirname "$GAME_EXE")"; cp "$GAME/$GAME_EXE" "$OUT/$GAME_EXE"
cp "$DISC"/* "$OUT/disc/"
# Data-track SHA-256 for mod targeting, so the browser never hashes the whole image.
sha256sum "$FIRST_BIN" | cut -d' ' -f1 > "$OUT/disc/$(basename "$FIRST_BIN").sha256"
# Default-on mods that need a different disc, diagnostics and widescreen stay off.
# PGXP needs supersampling >= 2 to show and its plugin is not always linked.
FORCED_OFF="psx.enhancement.pgxp/pgxp"
python3 "$ROOT/scripts/web/mod_state.py" "$OUT/mods" "$(cat "$OUT/disc/$(basename "$FIRST_BIN").sha256")" $FORCED_OFF
[ -f "$GAME/build-web/game_options.toml" ] && cp "$GAME/build-web/game_options.toml" "$OUT/"
(cd "$OUT" && for d in bios mods assets; do [ -d "$d" ] && find "$d" -type f; done; echo "$GAME_EXE"; ls game.toml game_options.toml 2>/dev/null || true) | sort -u > "$OUT/web-files.txt"
TITLE="$(python3 -c 'import sys,tomllib;print(tomllib.load(open(sys.argv[1],"rb"))["game"]["name"])' "$GAME/game.toml")"
sed -e "s|@TITLE@|$TITLE|" -e "s|@JS@|$EXE.js|" "$ROOT/scripts/web/index.html" > "$OUT/index.html"

step 7 "done"
echo "   $OUT ($(du -sh "$OUT" | cut -f1)); serve with scripts/web/serve.py $OUT"
