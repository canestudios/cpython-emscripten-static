#!/usr/bin/env bash
# Builds NumPy for UnrealPy's Wasm target, statically: Emscripten turns each extension module ("-shared")
# into a relocatable object, and they are archived into lib/libnumpy.a. UnrealPy registers their PyInit_*
# functions as built-in modules (include/numpy_builtins.inl lists them) before Python starts. Run after build.sh.
#
#   build_numpy.sh [output dir]      default: out/<tag>
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
OUT="$(out_dir "${1:-}")"
NATIVE="$CACHE/build-native/python"
HOST="$CACHE/build-wasm"
if [ ! -x "$NATIVE" ] || [ ! -d "$HOST/build" ]; then
  echo "No CPython build in $CACHE: run build.sh first" >&2
  exit 1
fi

activate_emsdk

# Build tools run on the native interpreter of the same version. pip is the wheel CPython's source bundles for
# ensurepip, so the source's hash pins it; the tools are pinned by theirs.
TOOLS="$CACHE/tools-venv"
if [ ! -x "$TOOLS/bin/cython" ]; then
  rm -rf "$TOOLS"
  "$NATIVE" -m venv --without-pip "$TOOLS"
  PIP_WHEEL="$(find "$CACHE/Python-$PYTHON_VERSION/Lib/ensurepip/_bundled" -name 'pip-*.whl' -print -quit)"
  PYTHONPATH="$PIP_WHEEL" "$TOOLS/bin/python" -m pip install -q --disable-pip-version-check --no-index "$PIP_WHEEL"
  "$TOOLS/bin/python" -m pip install -q --disable-pip-version-check --require-hashes --only-binary=:all: \
    -r "$ROOT/requirements-build.txt"
fi

fetch "$NUMPY_URL" "$NUMPY_SHA256" "$WORK/downloads/numpy-$NUMPY_VERSION.tar.gz"
SRC="$CACHE/numpy-$NUMPY_VERSION"
if [ ! -f "$SRC/meson.build" ]; then
  tar xzf "$WORK/downloads/numpy-$NUMPY_VERSION.tar.gz" -C "$CACHE"
fi

# Meson's python module asks the interpreter for its configuration: point the native interpreter at the
# Wasm build's sysconfig data, so headers, extension suffix and flags are the Wasm ones.
# CPython names the file after its configure-time triplet, which says wasm32 even for this wasm64 build.
SYSCONFIG="$(find "$HOST/build" -name '_sysconfigdata__emscripten*.py' -print -quit)"
[ -n "$SYSCONFIG" ] || { echo "No sysconfig data in $HOST/build: run build.sh first" >&2; exit 1; }
SYSCONFIG_DIR="$(dirname "$SYSCONFIG")"
SYSCONFIG_NAME="$(basename "$SYSCONFIG" .py)"
cat > "$CACHE/python-wasm" <<EOF
#!/usr/bin/env bash
export _PYTHON_SYSCONFIGDATA_NAME=$SYSCONFIG_NAME
export _PYTHON_HOST_PLATFORM=emscripten_wasm64
export PYTHONPATH="$SYSCONFIG_DIR\${PYTHONPATH:+:\$PYTHONPATH}"
exec "$TOOLS/bin/python" "\$@"
EOF
chmod +x "$CACHE/python-wasm"

cat > "$CACHE/emscripten-cross.ini" <<EOF
[binaries]
c = 'emcc'
cpp = 'em++'
ar = 'emar'
strip = 'emstrip'
cython = '$TOOLS/bin/cython'
python = '$CACHE/python-wasm'
exe_wrapper = '$EMSDK_NODE'

[built-in options]
c_args = ['-O3', '-pthread', '-sMEMORY64=1', '-I$HOST', '-I$CACHE/Python-$PYTHON_VERSION/Include']
cpp_args = ['-O3', '-pthread', '-sMEMORY64=1', '-I$HOST', '-I$CACHE/Python-$PYTHON_VERSION/Include']
# The extension modules' own links stay relocatable (FAKE_DYLIBS): their output is not used, the objects are.
c_link_args = ['-pthread', '-sMEMORY64=1', '-sFAKE_DYLIBS=1']
cpp_link_args = ['-pthread', '-sMEMORY64=1', '-sFAKE_DYLIBS=1']

[properties]
needs_exe_wrapper = true
longdouble_format = 'IEEE_QUAD_LE'

[host_machine]
system = 'emscripten'
cpu_family = 'wasm64'
cpu = 'wasm64'
endian = 'little'
EOF

BUILD="$CACHE/build-numpy"
rm -rf "$BUILD" "$CACHE/numpy-install"
# NumPy builds with its own Meson (vendored-meson: the CPU features module), as its pyproject.toml sets.
MESON=("$TOOLS/bin/python" "$SRC/vendored-meson/meson/meson.py")
PATH="$TOOLS/bin:$PATH" "${MESON[@]}" setup "$BUILD" "$SRC" --cross-file "$CACHE/emscripten-cross.ini" \
  -Dbuildtype=release -Db_ndebug=if-release -Dallow-noblas=true -Ddisable-optimization=true \
  -Dprefix=/ --python.install-env=auto
PATH="$TOOLS/bin:$PATH" ninja -C "$BUILD"
DESTDIR="$CACHE/numpy-install" PATH="$TOOLS/bin:$PATH" "${MESON[@]}" install -C "$BUILD" --quiet

PKG="$(dirname "$(find "$CACHE/numpy-install" -name '__init__.py' -path '*/numpy/__init__.py' -print -quit)")"
[ -f "$PKG/__init__.py" ] || { echo "meson install produced no numpy package" >&2; exit 1; }
mkdir -p "$OUT/lib"
rm -f "$OUT"/lib/libnumpy*.a "$OUT/numpy-builtins.txt"
# The engine links statically, so the extension modules' compiled objects are archived, not their .so files.
# Modules share sources (lapack_lite's are compiled into lapack_lite and _umath_linalg): members are named per
# module, so both copies stay in the archive and the linker pulls only the first one a symbol needs.
OBJECTS="$CACHE/numpy-objects"
rm -rf "$OBJECTS"
mkdir -p "$OBJECTS"
while IFS= read -r target; do
  rel="${target#"$BUILD"/}"
  module="${rel%%.cpython-*}"
  case "$module" in *_tests|*/tests/*|*/_simd) continue ;; esac  # the test modules (_umath_tests, _rational_tests...)
  dotted="${module//\//.}"
  for object in "$target"/*.o; do
    cp "$object" "$OBJECTS/${dotted//./_}__$(basename "$object")"
  done
  echo "$dotted PyInit_${dotted##*.}" >> "$OUT/numpy-builtins.txt"
done < <(find "$BUILD/numpy" -type d -name '*.so.p' | sort)
grep -q "numpy._core._multiarray_umath " "$OUT/numpy-builtins.txt" || { echo "_multiarray_umath was not built" >&2; exit 1; }
# The static libraries the modules link (npymath, npyrandom, the SIMD dispatch targets...), once each. Meson
# makes some of them thin archives, which only name objects in this build folder: their members join libnumpy.a.
while IFS= read -r lib; do
  name="$(basename "$lib" .a | sed 's/^lib//')"
  case "$name" in *_simd*|*_umath_tests*) continue ;; esac  # the test modules' own targets
  if [ "$(head -c 7 "$lib")" = '!<thin>' ]; then
    while IFS= read -r member; do
      [[ "$member" = /* ]] || member="$(dirname "$lib")/$member"
      cp "$member" "$OBJECTS/lib_${name//./_}__$(basename "$member")"
    done < <(emar t "$lib")
  else
    cp "$lib" "$OUT/lib/libnumpy-$name.a"
  fi
done < <(find "$BUILD" -name '*.a' -not -path '*/tests/*' -not -path '*bench*' | sort)
emar qc "$OUT/lib/libnumpy.a" "$OBJECTS"/*.o
emranlib "$OUT/lib/libnumpy.a"
for lib in "$OUT"/lib/*.a; do
  [ "$(head -c 7 "$lib")" != '!<thin>' ] || { echo "$lib is a thin archive" >&2; exit 1; }
done

# NumPy's C headers as configured for Wasm (UnrealPy's math arrays compile against them), and the table of
# built-in modules UnrealPy registers.
rm -rf "$OUT/include/numpy"
cp -r "$PKG/_core/include/numpy" "$OUT/include/numpy"
{
  echo "// Generated by build_numpy.sh: NumPy's extension modules, built into the web build."
  while read -r dotted init; do echo "PyMODINIT_FUNC $init(void);"; done < "$OUT/numpy-builtins.txt"
  echo "static const struct { const char* Name; PyObject* (*Init)(void); } GNumPyBuiltins[] = {"
  while read -r dotted init; do echo "	{\"$dotted\", $init},"; done < "$OUT/numpy-builtins.txt"
  echo "};"
} > "$OUT/include/numpy_builtins.inl"

# NumPy's licence, and those of the code it bundles, at their paths in the source.
rm -rf "$OUT/licenses/numpy"
mkdir -p "$OUT/licenses/numpy"
# Only the package's sources: the build tools (vendored Meson, tempita, spin) and the documentation ship nothing.
(cd "$SRC" && { printf '%s\n' LICENSE*; find numpy -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' \) \
  -not -path 'numpy/_build_utils/*'; } | sort | while IFS= read -r notice; do
    mkdir -p "$OUT/licenses/numpy/$(dirname "$notice")"
    cp "$notice" "$OUT/licenses/numpy/$notice"
  done)
[ -f "$OUT/licenses/numpy/LICENSE.txt" ] || { echo "No NumPy licence in $SRC" >&2; exit 1; }

# The package's Python files, staged with the standard library.
rm -rf "$OUT/python-stdlib/numpy"
rsync -a --exclude '*.so' --exclude 'tests/' --exclude '__pycache__' --exclude '*.pyi' "$PKG/" "$OUT/python-stdlib/numpy/"
echo "NumPy $NUMPY_VERSION for Wasm in $OUT"
cat "$OUT/numpy-builtins.txt"
du -sh "$OUT/lib/libnumpy.a" "$OUT/python-stdlib/numpy"
