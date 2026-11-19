#!/usr/bin/env bash
# Packs the standard library and NumPy's Python files (python-stdlib/, from build.sh and build_numpy.sh) into
# python311.zip, the one file a web build stages for them. Every module is compiled to bytecode by the native
# interpreter of the same version (same magic number) and stored without its source: the browser then neither
# fetches thousands of small files nor compiles them on each load. Run after build_numpy.sh.
#
#   make_zip.sh [output dir]      default: out/<tag>
#
# The zip is deterministic: sorted entries, fixed times and modes, and bytecode marshalled with a fixed hash seed.
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
OUT="$(out_dir "${1:-}")"
NATIVE="$CACHE/build-native/python"
[ -d "$OUT/python-stdlib" ] || { echo "No $OUT/python-stdlib: run build.sh and build_numpy.sh first" >&2; exit 1; }

"$NATIVE" - "$OUT/python-stdlib" "$OUT/python$PY_NODOT.zip" <<'EOF'
import importlib.util
import marshal
import sys
import zipfile
from pathlib import Path

source, target = Path(sys.argv[1]), Path(sys.argv[2])
assert sys.version_info[:2] == (3, 11), sys.version
skipped = []


def entry(name: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    return info


with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted(source.rglob("*"), key=lambda p: p.relative_to(source).as_posix()):
        if not path.is_file() or "__pycache__" in path.parts:
            continue
        name = path.relative_to(source).as_posix()
        if path.suffix != ".py":
            archive.writestr(entry(name), path.read_bytes())  # data files that packages read (NumPy's, email's...)
            continue
        try:
            # Unchecked hashes: no timestamp or source to compare in the zip, the bytecode is used as it is.
            code = importlib.util.MAGIC_NUMBER + (1).to_bytes(4, "little") + importlib.util.source_hash(path.read_bytes())
            compiled = compile(path.read_bytes(), name, "exec", dont_inherit=True, optimize=0)
            archive.writestr(entry(name[:-3] + ".pyc"), code + marshal.dumps(compiled))
        except SyntaxError:
            skipped.append(name)  # a few stdlib files are templates or Python 2 test data
print(f"{target}: {target.stat().st_size / 1e6:.1f} MB, {len(skipped)} files not compiled")
EOF
