#!/usr/bin/env bash
# Links harness.c against the Wasm CPython and NumPy with the engine's link settings (WasmToolChain.cs:
# GetEmscriptenLinkArguments), then runs check.py under node. It finds link and runtime problems without
# packaging a game.
#
#   run.sh [build dir]      a build's output folder or an unpacked release archive; default: out/<tag>
#
# The engine links its own wasm64 zlib. ZLIB=<path to libz.a> links that one, for example
# "$ENGINE/Platforms/Wasm/Build/ThirdParty/zlib/wasm64/libz.a"; without it, a stand-in is compiled from
# Emscripten's zlib port the way build.sh compiles bzip2.
set -euo pipefail
HARNESS="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../common.sh
source "$HARNESS/../common.sh"
CPW="$(out_dir "${1:-}")"  # not DIR: emsdk_env.sh uses that name
[ -f "$CPW/lib/libpython$PY_MINOR.a" ] || { echo "No CPython build in $CPW" >&2; exit 1; }

activate_emsdk
BUILD="$CACHE/harness"
mkdir -p "$BUILD"
if [ -z "${ZLIB:-}" ]; then
  ZLIB="$BUILD/libz.a"
  port_library "$ZLIB" "$(port_dir zlib zlib.h)" \
    adler32.c compress.c crc32.c deflate.c gzclose.c gzlib.c gzread.c gzwrite.c infback.c inffast.c inflate.c \
    inftrees.c trees.c uncompr.c zutil.c
fi

emcc -O2 -pthread -sMEMORY64=1 -I"$CPW/include/python$PY_MINOR" -I"$CPW/include" -c "$HARNESS/harness.c" \
  -o "$BUILD/harness.o"
LIBS=("$CPW"/lib/*.a "$ZLIB")
em++ -O2 "$BUILD/harness.o" "${LIBS[@]}" -o "$BUILD/harness.js" \
  -m64 -sMEMORY64=2 -pthread -sPROXY_TO_PTHREAD -sPTHREAD_POOL_SIZE=8 \
  -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=512MB -sMAXIMUM_MEMORY=4096MB -sSTACK_SIZE=4096KB \
  -sDEFAULT_PTHREAD_STACK_SIZE=1024KB -sMALLOC=emmalloc -sWASMFS=1 -sFORCE_FILESYSTEM=1 \
  -sALLOW_BLOCKING_ON_MAIN_THREAD=1 -sABORTING_MALLOC=0 -sENVIRONMENT=node,worker -sEXIT_RUNTIME=1 \
  -Wl,--error-limit=0
# Emscripten's own node: the system one may predate 64-bit WebAssembly memory.
"$EMSDK_NODE" "$BUILD/harness.js" "$CPW" "$HARNESS"
