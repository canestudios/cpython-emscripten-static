# Shared by the build scripts: the pinned versions, the folders and the helpers. Sourced, not run.
# shellcheck shell=bash disable=SC2034  # the scripts that source this file use its variables

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$ROOT/versions.env"

TAG="cpython-${PYTHON_VERSION}_numpy-${NUMPY_VERSION}_emsdk-${EMSDK_VERSION}-r${REVISION}"
PY_MINOR="${PYTHON_VERSION%.*}"  # 3.11: libpython3.11.a, include/python3.11
PY_NODOT="${PY_MINOR/./}"        # 311: python311.zip
WORK="${WORK:-$HOME/.cache/unrealpy-cpython-wasm}"
# Every build folder of this recipe revision: another tag never reuses them.
CACHE="$WORK/$TAG"
JOBS="${JOBS:-$(nproc)}"

# Reproducible outputs: the compiler's date macros (CPython's build information) and the order of sets in
# marshalled bytecode.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-315532800}"  # 1980-01-01, also the time of every zip entry
export PYTHONHASHSEED=0
export LC_ALL=C

# CPython's Wasm build. pack.sh records these in build-info.json.
CPYTHON_CFLAGS="-O3 -pthread"
CPYTHON_CONFIGURE=(
  --host=wasm64-unknown-emscripten
  --with-emscripten-target=browser
  --enable-wasm-pthreads
  --disable-wasm-dynamic-linking
  --disable-shared
  --disable-ipv6
  --without-ensurepip
)

out_dir() {  # the output folder: a script's argument, or out/<tag> in this repository
  realpath -m "${1:-$ROOT/out/$TAG}"
}

sha256_of() {
  sha256sum "$1" | cut -d' ' -f1
}

fetch() {  # url, SHA-256, file: downloads once, and refuses a file whose hash differs
  local url="$1" expected="$2" file="$3" actual
  if [ -f "$file" ] && [ "$(sha256_of "$file")" = "$expected" ]; then
    return
  fi
  mkdir -p "$(dirname "$file")"
  curl -fsSL --retry 3 -o "$file.part" "$url"
  actual="$(sha256_of "$file.part")"
  if [ "$actual" != "$expected" ]; then
    rm -f "$file.part"
    echo "SHA-256 mismatch for $url: expected $expected, got $actual" >&2
    exit 1
  fi
  mv "$file.part" "$file"
}

activate_emsdk() {  # the pinned emsdk, with its compiler installed and on PATH
  local emsdk="$WORK/emsdk-$EMSDK_COMMIT"
  if [ ! -f "$emsdk/.installed-$EMSDK_VERSION" ]; then
    rm -rf "$emsdk"
    git init -q "$emsdk"
    git -C "$emsdk" fetch -q --depth 1 https://github.com/emscripten-core/emsdk "$EMSDK_COMMIT"
    git -C "$emsdk" checkout -q FETCH_HEAD
    "$emsdk/emsdk" install "$EMSDK_VERSION" >/dev/null
    "$emsdk/emsdk" activate "$EMSDK_VERSION" >/dev/null
    touch "$emsdk/.installed-$EMSDK_VERSION"
  fi
  # shellcheck disable=SC1091
  source "$emsdk/emsdk_env.sh" >/dev/null 2>&1
}

port_dir() {  # port, one of its headers: the folder of Emscripten's cached sources for that port
  local ports header
  ports="$(em-config CACHE)/ports"
  header="$(find "$ports/$1" -name "$2" -print -quit 2>/dev/null || true)"
  if [ -z "$header" ]; then
    embuilder build "$1" >/dev/null  # fetches the sources
    header="$(find "$ports/$1" -name "$2" -print -quit)"
  fi
  [ -n "$header" ] || { echo "Emscripten's $1 port has no $2" >&2; exit 1; }
  dirname "$header"
}

port_library() {  # archive, source folder, C files...
  # Emscripten's cached port libraries are built without -pthread and for wasm32: the sources are compiled again.
  local archive="$1" source="$2" objects=() file build
  build="$CACHE/ports/$(basename "$archive" .a)"
  shift 2
  rm -rf "$build"
  mkdir -p "$build"
  for file in "$@"; do
    emcc -O3 -pthread -sMEMORY64=1 -c "$source/$file" -o "$build/${file%.c}.o"
    objects+=("$build/${file%.c}.o")
  done
  rm -f "$archive"
  emar rcs "$archive" "${objects[@]}"
}
