#!/usr/bin/env bash
# Prepares this checkout to build PS1 games for the browser. Idempotent.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMSDK_VERSION="${EMSDK_VERSION:-7.0.1}"
EMSDK="$ROOT/tools/emsdk"

echo "== [1/3] host tools"
missing=""
for t in git cmake ninja python3 c++; do command -v "$t" >/dev/null || missing="$missing $t"; done
[ -z "$missing" ] || { echo "missing:$missing" >&2; exit 1; }
command -v chdman >/dev/null || echo "   (chdman not found: .chd discs will not be accepted)"

echo "== [2/3] emsdk $EMSDK_VERSION"
[ -d "$EMSDK/.git" ] || git clone -q --depth 1 https://github.com/emscripten-core/emsdk "$EMSDK"
if [ "$(cat "$EMSDK/.psx-version" 2>/dev/null)" != "$EMSDK_VERSION" ]; then
    (cd "$EMSDK" && ./emsdk install "$EMSDK_VERSION" >/dev/null && ./emsdk activate "$EMSDK_VERSION" >/dev/null)
    echo "$EMSDK_VERSION" > "$EMSDK/.psx-version"
fi

echo "== [3/3] recompiler (native)"
cmake -S "$ROOT/recompiler" -B "$ROOT/recompiler/build" -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$ROOT/recompiler/build" >/dev/null
echo "ok"
