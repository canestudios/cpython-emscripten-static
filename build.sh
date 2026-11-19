#!/usr/bin/env bash
# Builds CPython as static WebAssembly libraries for UnrealPy's Wasm target, with the Emscripten version the
# engine's Wasm platform requires. Run on Linux x86_64. The engine builds wasm64 objects only (its link lowers the
# pointers with -sMEMORY64=2), so CPython is wasm64.
#
#   build.sh [output dir]      default: out/<tag>
#
# Output: include/ (Python headers and pyconfig.h), lib/*.a (libpython with the stdlib's C modules built in,
# and the libraries they need), licenses/ for them, and python-stdlib/ (the pure-Python standard library, which
# make_zip.sh compiles). Everything is compiled with -pthread: the engine links its Wasm game with shared memory.
# zlib is not built: the engine links its own (Engine/Platforms/Wasm/Build/ThirdParty/zlib), which the zlib
# module uses.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
OUT="$(out_dir "${1:-}")"

activate_emsdk
emcc --version | head -1

SRC="$CACHE/Python-$PYTHON_VERSION"
if [ ! -f "$SRC/configure" ]; then
  fetch "https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tgz" "$PYTHON_SHA256" \
    "$WORK/downloads/Python-$PYTHON_VERSION.tgz"
  mkdir -p "$CACHE"
  tar xzf "$WORK/downloads/Python-$PYTHON_VERSION.tgz" -C "$CACHE"
fi

# A native interpreter of the same version runs the build's own Python steps (cross-compiling needs one), the
# NumPy build tools and make_zip.sh. pip needs its zlib and ssl modules.
NATIVE="$CACHE/build-native/python"
if [ ! -x "$NATIVE" ]; then
  mkdir -p "$CACHE/build-native"
  (cd "$CACHE/build-native" && "$SRC/configure" -q && make -s -j"$JOBS")
fi
"$NATIVE" -c "import ssl, zlib" || {
  echo "The native Python has no ssl or zlib module: install the OpenSSL and zlib development packages" >&2
  exit 1
}

# The Wasm build. Dynamic linking stays off, so the stdlib's C modules are compiled into libpython.
HOST="$CACHE/build-wasm"
# An existing build is reused (REBUILD=1 starts again from configure).
if [ -n "${REBUILD:-}" ] || [ ! -f "$HOST/libpython$PY_MINOR.a" ]; then
  rm -rf "$HOST"
  mkdir -p "$HOST"
  cd "$HOST"
  CONFIG_SITE="$SRC/Tools/wasm/config.site-wasm32-emscripten" \
    emconfigure "$SRC/configure" -q "${CPYTHON_CONFIGURE[@]}" \
      --build="$("$SRC/config.guess")" \
      --with-build-python="$NATIVE" \
      CFLAGS="$CPYTHON_CFLAGS" LDFLAGS="-pthread"
  # pybuilddir.txt also writes the Wasm sysconfig data, which build_numpy.sh points Meson at.
  emmake make -s -j"$JOBS" "libpython$PY_MINOR.a" pybuilddir.txt
fi
cd "$HOST"

# What the engine links: libpython plus the static libraries its built-in modules use.
rm -rf "${OUT:?}/include" "${OUT:?}/lib" "${OUT:?}/python-stdlib" "${OUT:?}/licenses"
mkdir -p "$OUT/include/python$PY_MINOR" "$OUT/lib" "$OUT/licenses"
cp -r "$SRC/Include/." "$OUT/include/python$PY_MINOR/"
cp pyconfig.h "$OUT/include/python$PY_MINOR/"
cp "libpython$PY_MINOR.a" Modules/_decimal/libmpdec/libmpdec.a Modules/expat/libexpat.a "$OUT/lib/"
BZIP2_DIR="$(port_dir bzip2 bzlib.h)"
port_library "$OUT/lib/libbz2.a" "$BZIP2_DIR" \
  blocksort.c huffman.c crctable.c randtable.c compress.c decompress.c bzlib.c
grep -E "^(MODBUILT_NAMES|MODDISABLED_NAMES|MODOBJS)" Makefile > "$OUT/lib/modules.txt" || true

# The licences of what the libraries contain. CPython's Doc/license.rst also covers the code it bundles.
mkdir -p "$OUT/licenses/cpython" "$OUT/licenses/expat" "$OUT/licenses/libmpdec" "$OUT/licenses/bzip2"
cp "$SRC/LICENSE" "$OUT/licenses/cpython/LICENSE"
cp "$SRC/Doc/license.rst" "$OUT/licenses/cpython/license.rst"
cp "$SRC/Modules/expat/COPYING" "$OUT/licenses/expat/COPYING"
# libmpdec has no licence file in CPython's tree: its terms are the comment that opens each source file.
sed -n '1,/\*\//p' "$SRC/Modules/_decimal/libmpdec/mpdecimal.h" > "$OUT/licenses/libmpdec/LICENSE"
grep -q "Redistribution and use" "$OUT/licenses/libmpdec/LICENSE" || { echo "No libmpdec licence found" >&2; exit 1; }
cp "$BZIP2_DIR/LICENSE" "$OUT/licenses/bzip2/LICENSE"

# The pure-Python stdlib, without what a game never imports (tests, GUI, installers, the 2to3 tool...).
rsync -a --prune-empty-dirs \
  --exclude '__pycache__' --exclude 'test/' --exclude 'tests/' --exclude 'idlelib/' --exclude 'tkinter/' \
  --exclude 'turtledemo/' --exclude 'turtle.py' --exclude 'ensurepip/' --exclude 'lib2to3/' --exclude 'venv/' \
  --exclude 'distutils/' --exclude 'pydoc_data/' --exclude 'site-packages/' --exclude "config-$PY_MINOR*" \
  "$SRC/Lib/" "$OUT/python-stdlib/"
# The build's sysconfig data stays out: it describes this machine (its paths) and the game does not read it.
echo "CPython $PYTHON_VERSION for Wasm (emsdk $EMSDK_VERSION) in $OUT"
du -sh "$OUT/lib" "$OUT/python-stdlib"
