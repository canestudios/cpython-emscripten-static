# CPython and NumPy for UnrealPy's web build

[UnrealPy](https://unrealpy.canestudios.xyz) runs a game's Python in Unreal Engine 5.9 web (Wasm) builds on
CPython 3.11.8 and NumPy 2.4.6 compiled to wasm64 and linked into the game. This repository holds the recipe for
those static libraries, the CI that builds them, and the releases the plugin downloads.

A release is one zip, named after its tag, for example `cpython-3.11.8_numpy-2.4.6_emsdk-6.0.10-r1.zip`:

| Path | What |
| --- | --- |
| `include/python3.11/` | CPython's headers and the Wasm build's `pyconfig.h` |
| `include/numpy/`, `include/numpy_builtins.inl` | NumPy's C headers as configured for Wasm, and the table of its extension modules |
| `lib/*.a` | `libpython3.11.a` (the standard library's C modules built in), `libmpdec`, `libexpat`, `libbz2`, `libnumpy*.a` |
| `python311.zip` | The standard library and NumPy's Python files, compiled to bytecode |
| `licenses/` | The licences of everything above |
| `build-info.json` | Versions, recipe commit, compiler, build flags and the SHA-256 of every file |

`SHA256SUMS` sits next to the zip in the release. Everything is wasm64 and compiled with `-pthread`, as the engine
links. zlib is not included: the engine links its own. pymalloc is off (configure's Emscripten default).

## Using a release

The plugin pins one release in `Plugins/UnrealPy/Source/ThirdParty/CPythonWasm/pin.json` and installs it before
every web build, so a project does nothing. To use another archive, for example one built from this recipe, set
`UNREALPY_WASM_PYTHON_ARCHIVE` to its path or URL before the build; the plugin marks that install `local` and warns
that it is not the pinned build. Maintainers move the pin with `unrealpy update-wasm-python --tag <tag>`.

## Building

On Linux x86_64 with a C compiler, the OpenSSL and zlib development packages, `curl`, `git` and `rsync`:

```bash
bash build.sh          # CPython: include/, lib/libpython3.11.a, libmpdec, libexpat, libbz2, python-stdlib/
bash build_numpy.sh    # NumPy: lib/libnumpy*.a, include/numpy, include/numpy_builtins.inl, python-stdlib/numpy
bash make_zip.sh       # python311.zip: python-stdlib/ compiled to bytecode
bash pack.sh           # dist/<tag>.zip and dist/SHA256SUMS
bash harness/run.sh    # links with the engine's settings and runs harness/check.py under node
```

Each script takes the output folder as its argument (default `out/<tag>`). Downloads and build folders go to
`$WORK` (default `~/.cache/unrealpy-cpython-wasm`), one folder per tag, so a new version or revision never reuses
an old build. `harness/run.sh` links a zlib stand-in compiled from Emscripten's port; `ZLIB=<path to libz.a>` links
the engine's instead (`Engine/Platforms/Wasm/Build/ThirdParty/zlib/wasm64/libz.a`).

Every input is pinned in `versions.env` and `requirements-build.txt`: the CPython and NumPy sources by SHA-256, the
emsdk repository by commit (which fixes the compiler binaries its version installs), and Cython and ninja by
wheel hash. pip is the wheel CPython's source bundles. NumPy builds with its own vendored Meson.

## Releasing

1. Change `versions.env` (and `requirements-build.txt` if a build tool changes). Raise `REVISION` when only the
   recipe changes; reset it to 1 when a version changes.
2. Push, then push the tag the versions name: `cpython-<python>_numpy-<numpy>_emsdk-<emsdk>-r<revision>`.

The release workflow refuses a tag that does not match `versions.env`. It builds on two runners from clean,
runs the harness on the packed archive, checks that the two archives are byte-identical and publishes one with
`SHA256SUMS`. A manual run of the workflow does all of this without publishing. The two builds use the same
folders: CPython records its source folder in `libpython`, so a build elsewhere has different bytes. Tags are
never reused, and the repository keeps releases immutable.

## Licences

The scripts are under the MIT licence (`LICENSE`). The archives hold CPython (PSF licence), NumPy (BSD) and the
code they bundle, expat (MIT), libmpdec (BSD) and bzip2 (bzip2 licence); `licenses/` in each archive has their
texts, and `NOTICE` lists them.
