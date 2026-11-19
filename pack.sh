#!/usr/bin/env bash
# Writes the release archive from the outputs of build.sh, build_numpy.sh and make_zip.sh: include/, lib/,
# python311.zip, licenses/ and build-info.json (versions, recipe commit, compiler, flags and the SHA-256 of every
# file), as <dist>/<tag>.zip, with <dist>/SHA256SUMS. The intermediates (python-stdlib/, numpy-builtins.txt) stay
# out. The archive is deterministic: sorted entries, fixed times and modes.
#
#   pack.sh [output dir] [dist dir]      defaults: out/<tag>, dist
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
OUT="$(out_dir "${1:-}")"
DIST="$(realpath -m "${2:-$ROOT/dist}")"
NATIVE="$CACHE/build-native/python"

for required in "include/python$PY_MINOR/Python.h" include/numpy/ndarrayobject.h include/numpy_builtins.inl \
  "lib/libpython$PY_MINOR.a" lib/libnumpy.a "python$PY_NODOT.zip" licenses/cpython/LICENSE licenses/numpy/LICENSE.txt; do
  [ -f "$OUT/$required" ] || { echo "No $OUT/$required: run build.sh, build_numpy.sh and make_zip.sh first" >&2; exit 1; }
done

activate_emsdk
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
MODIFIED=false
[ -z "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ] || MODIFIED=true
PYMALLOC=false
grep -q '^#define WITH_PYMALLOC 1' "$OUT/include/python$PY_MINOR/pyconfig.h" && PYMALLOC=true
mkdir -p "$DIST"

INFO_TAG="$TAG" INFO_REVISION="$REVISION" INFO_PYTHON="$PYTHON_VERSION" INFO_NUMPY="$NUMPY_VERSION" \
INFO_EMSDK="$EMSDK_VERSION" INFO_EMSDK_COMMIT="$EMSDK_COMMIT" INFO_EMCC="$(emcc --version | head -1)" \
INFO_REPOSITORY="${GITHUB_REPOSITORY:-canestudios/cpython-emscripten-static}" INFO_COMMIT="$COMMIT" \
INFO_MODIFIED="$MODIFIED" INFO_PYMALLOC="$PYMALLOC" INFO_CFLAGS="$CPYTHON_CFLAGS -ffile-prefix-map=<work>=." \
INFO_CONFIGURE="$(printf '%s\n' "${CPYTHON_CONFIGURE[@]}")" \
INFO_PYTHON_URL="https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tgz" \
INFO_PYTHON_SHA256="$PYTHON_SHA256" INFO_NUMPY_URL="$NUMPY_URL" INFO_NUMPY_SHA256="$NUMPY_SHA256" \
INFO_FOLDERS="$WORK
$ROOT" \
"$NATIVE" - "$OUT" "$DIST/$TAG.zip" "python$PY_NODOT.zip" <<'EOF'
import hashlib
import io
import json
import os
import sys
import zipfile
from pathlib import Path

out, target, stdlib = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
env = os.environ
members = sorted(
    path.relative_to(out).as_posix()
    for top in ("include", "lib", "licenses")
    for path in (out / top).rglob("*")
    if path.is_file()
) + [stdlib]
members.sort()
info = {
    "schema": 1,
    "tag": env["INFO_TAG"],
    "revision": int(env["INFO_REVISION"]),
    "python": env["INFO_PYTHON"],
    "numpy": env["INFO_NUMPY"],
    "emsdk": env["INFO_EMSDK"],
    "emcc": env["INFO_EMCC"],
    "recipe": {
        "repository": env["INFO_REPOSITORY"],
        "commit": env["INFO_COMMIT"],
        "modified": env["INFO_MODIFIED"] == "true",
    },
    "build": {
        "target": "wasm64-unknown-emscripten",
        "cflags": env["INFO_CFLAGS"],
        "configure": env["INFO_CONFIGURE"].split(),
        "pthreads": True,
        "memory64": True,
        "pymalloc": env["INFO_PYMALLOC"] == "true",
    },
    "sources": {
        "python": {"url": env["INFO_PYTHON_URL"], "sha256": env["INFO_PYTHON_SHA256"]},
        "numpy": {"url": env["INFO_NUMPY_URL"], "sha256": env["INFO_NUMPY_SHA256"]},
        "emsdk": {"repository": "https://github.com/emscripten-core/emsdk", "commit": env["INFO_EMSDK_COMMIT"]},
    },
    "files": {name: hashlib.sha256((out / name).read_bytes()).hexdigest() for name in members},
}
data = {name: (out / name).read_bytes() for name in members}
# The archive must not depend on where it was built: no file, nor any member of the stdlib zip, may name the
# build machine's folders.
folders = [folder.encode() for folder in env["INFO_FOLDERS"].splitlines() if folder]
contents = dict(data)
with zipfile.ZipFile(io.BytesIO(data[stdlib])) as zipped:
    contents.update({f"{stdlib}/{name}": zipped.read(name) for name in zipped.namelist()})
leaks = sorted(name for name, content in contents.items() if any(folder in content for folder in folders))
if leaks:
    sys.exit("These files name the build folders, so the archive depends on where it was built: " + ", ".join(leaks))
data["build-info.json"] = (json.dumps(info, indent=2) + "\n").encode()
(out / "build-info.json").write_bytes(data["build-info.json"])
temporary = target.with_suffix(".part")
with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for name in sorted(data):
        entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
        entry.compress_type = zipfile.ZIP_DEFLATED
        entry.external_attr = 0o644 << 16
        archive.writestr(entry, data[name])
temporary.replace(target)
print(f"{target}: {target.stat().st_size / 1e6:.1f} MB, {len(data)} files")
EOF
(cd "$DIST" && sha256sum "$TAG.zip" > SHA256SUMS && cat SHA256SUMS)
