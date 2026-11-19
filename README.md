# cpython-emscripten-static

Prebuilt static libraries of CPython (and NumPy) for wasm64 Emscripten with pthreads, for C and C++ programs that
embed Python and link it into their WebAssembly build. Every release is built in CI from the pinned, reproducible
recipe in this repository.

This is not a Python distribution for the browser like Pyodide, with dynamically loaded wheels. It is a set of
`.a` files and headers, plus the standard library as one zip of bytecode, that a host links statically, the way
a desktop program links `libpython`.

## Releases

One zip per tag, named after it, for example `cpython-3.11.8_numpy-2.4.6_emsdk-6.0.10-r1.zip`, with
`SHA256SUMS` next to it:

| Path | What |
| --- | --- |
| `include/python3.11/` | CPython's headers and the Wasm build's `pyconfig.h` |
| `include/numpy/`, `include/numpy_builtins.inl` | NumPy's C headers as configured for Wasm, and a table of its extension modules (name, `PyInit_` function) |
| `lib/*.a` | `libpython3.11.a` (the standard library's C modules built in), `libmpdec`, `libexpat`, `libbz2`, `libnumpy*.a` |
| `python311.zip` | The standard library and NumPy's Python files, compiled to 3.11 bytecode, without sources |
| `licenses/` | The licences of everything above |
| `build-info.json` | Versions, recipe commit, compiler, build flags and the SHA-256 of every file |

What every release targets:

- **wasm64, shared memory.** Everything is compiled with `-sMEMORY64=1 -pthread`. A host that links with shared
  memory needs atomics in every library; a wasm32 host can't use these objects.
- **One Emscripten.** Static objects must come from the Emscripten the host links with. The versions follow the
  Emscripten that Unreal Engine's Wasm platform pins (`Engine/Platforms/Wasm/Config/Wasm_SDK.json`).
- **No dynamic loading.** The standard library's C modules are compiled into `libpython`. NumPy's extension
  modules are compiled into `libnumpy.a`; the host registers them with `PyImport_AppendInittab` from
  `numpy_builtins.inl` before Python starts.
- **zlib is the host's.** The `zlib` module needs a wasm64, `-pthread` `libz.a`, which the host links. Unreal
  Engine links its own; elsewhere, Emscripten's zlib port compiled the way `harness/run.sh` compiles its stand-in
  works.
- **A pruned standard library.** `python311.zip` leaves out tests, `idlelib`, `tkinter`, `turtle`, `ensurepip`,
  `lib2to3`, `venv`, `distutils`, `pydoc_data` and `site-packages` (`build.sh`). pymalloc is off (configure's
  Emscripten default).

A host points `PyConfig.module_search_paths` at `python311.zip`; `harness/harness.c` is a minimal example. Variants
other than wasm64 with pthreads would be published as extra assets with a suffix, for example `<tag>-wasm32.zip`.

## Used by

[UnrealPy](https://unrealpy.canestudios.xyz) links these libraries into Unreal Engine 5.9 web builds. Its plugin
pins one release and installs it before every web build.

## Building

On Linux x86_64 with a C compiler, the OpenSSL and zlib development packages, `curl`, `git` and `rsync`:

```bash
bash build.sh          # CPython: include/, lib/libpython3.11.a, libmpdec, libexpat, libbz2, python-stdlib/
bash build_numpy.sh    # NumPy: lib/libnumpy*.a, include/numpy, include/numpy_builtins.inl, python-stdlib/numpy
bash make_zip.sh       # python311.zip: python-stdlib/ compiled to bytecode
bash pack.sh           # dist/<tag>.zip and dist/SHA256SUMS
bash harness/run.sh    # links the archive's libraries into a small host and runs harness/check.py under node
```

Each script takes the output folder as its argument (default `out/<tag>`). Downloads and build folders go to
`$WORK` (default `~/.cache/cpython-emscripten-static`), one folder per tag, so a new version or revision never
reuses an old build. `harness/run.sh` links a zlib stand-in compiled from Emscripten's port; `ZLIB=<path to libz.a>`
links another, such as Unreal Engine's (`Engine/Platforms/Wasm/Build/ThirdParty/zlib/wasm64/libz.a`). The harness
uses the link settings of Unreal Engine 5.9's Wasm platform.

Every input is pinned in `versions.env` and `requirements-build.txt`: the CPython and NumPy sources by SHA-256, the
emsdk repository by commit (which fixes the compiler binaries its version installs), and Cython and ninja by
wheel hash. pip is the wheel CPython's source bundles. NumPy builds with its own vendored Meson. The archive does
not depend on the folder it was built in: CPython is configured by a relative path and the debug information maps
the build folder to `.`.

## Releasing

1. Change `versions.env` (and `requirements-build.txt` if a build tool changes). Raise `REVISION` when only the
   recipe changes; reset it to 1 when a version changes.
2. Push, then push the tag the versions name: `cpython-<python>_numpy-<numpy>_emsdk-<emsdk>-r<revision>`.

The release workflow refuses a tag that does not match `versions.env`. It builds on two runners from clean, in
different folders, runs the harness on the packed archive, checks that the two archives are byte-identical and
publishes one with `SHA256SUMS`. A manual run of the workflow does all of this without publishing. Tags are never
reused, and the repository keeps releases immutable.

Release `-r1` was built before the folder independence above and before this repository was renamed from
`unrealpy-cpython-wasm`: its `build-info.json` names the old repository, and its two CI builds used the same folders.

## Licences

The scripts are under the MIT licence (`LICENSE`). The archives hold CPython (PSF licence), NumPy (BSD) and the
code they bundle, expat (MIT), libmpdec (BSD) and bzip2 (bzip2 licence); `licenses/` in each archive has their
texts, and `NOTICE` lists them.
