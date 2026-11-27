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
[ -z "${UI_OVERRIDE:-}" ] || { git -C "$GAME/recomp-ui" fetch -q origin "$UI_OVERRIDE" 2>/dev/null; git -C "$GAME/recomp-ui" checkout -q -f "$UI_OVERRIDE"; }
# Build against the framework commit the game pins, plus this fork's web
# runtime changes (the diff from scripts/web/BASE to HEAD, outside scripts/).
PIN="${FW_OVERRIDE:-$(git -C "$GAME" ls-tree HEAD psxrecomp-v4 psxrecomp | awk '$2 == "commit" { print $3; exit }')}"
[ -n "$PIN" ] || { echo "game pins no psxrecomp commit" >&2; exit 1; }
FW="$WORK/framework/$PIN"
PATCH_ID="$(git -C "$ROOT" diff "$(cat "$ROOT/scripts/web/BASE")" HEAD -- . ':!scripts' ':!.gitignore' ':!runtime/src/main.cpp' | sha256sum | cut -c1-16)"
if [ "$(cat "$FW/.psx-web-patch" 2>/dev/null)" != "$PATCH_ID" ]; then
  echo "   framework ${PIN:0:7} + web runtime"
  git -C "$ROOT" worktree remove --force "$FW" 2>/dev/null || rm -rf "$FW"
  git -C "$ROOT" worktree prune
  git -C "$ROOT" cat-file -e "$PIN^{commit}" 2>/dev/null \
    || git -C "$ROOT" fetch -q --depth 1 origin "$PIN" 2>/dev/null \
    || git -C "$ROOT" fetch -q --depth 1 https://github.com/RetroPortingToolKit/psxrecomp.git "$PIN"
  git -C "$ROOT" worktree add -q --detach "$FW" "$PIN"
  git -C "$ROOT" diff "$(cat "$ROOT/scripts/web/BASE")" HEAD -- . ':!scripts' ':!.gitignore' ':!runtime/src/main.cpp' \
    | git -C "$FW" apply --3way --whitespace=nowarn \
    || { echo "web runtime patch does not apply to framework ${PIN:0:7}" >&2; exit 1; }
  python3 "$ROOT/scripts/web/hook_main.py" "$FW/runtime/src/main.cpp"
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
python3 "$FW/psxrecomp_cli.py" generate --config "$GAME/game.toml" --project-root "$GAME" \
    --disc "$DISC/game.cue" --no-toolchain-download > "$WORK/$NAME-generate.log" 2>&1 \
  || { tail -5 "$WORK/$NAME-generate.log" >&2; exit 1; }

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
python3 "$ROOT/scripts/web/mod_state.py" "$OUT/mods" "$(cat "$OUT/disc/$(basename "$FIRST_BIN").sha256")"
(cd "$OUT" && find bios mods "$(dirname "$GAME_EXE")" game.toml -type f $( [ -d assets ] && echo -o -path 'assets/*' ) | sort -u > web-files.txt)
TITLE="$(python3 -c 'import sys,tomllib;print(tomllib.load(open(sys.argv[1],"rb"))["game"]["name"])' "$GAME/game.toml")"
sed -e "s|@TITLE@|$TITLE|" -e "s|@JS@|$EXE.js|" "$ROOT/scripts/web/index.html" > "$OUT/index.html"

step 7 "done"
echo "   $OUT ($(du -sh "$OUT" | cut -f1)); serve with scripts/web/serve.py $OUT"
