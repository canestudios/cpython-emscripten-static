/*
 * A minimal host: starts the Wasm CPython the way an embedding program does (NumPy's modules registered as
 * built-ins, an isolated config whose search path is the standard library zip) and runs a check script.
 * Built and run under node by run.sh, with Unreal Engine's link settings, to find link and runtime problems
 * without a real host. Arguments: the build folder (mounted at /cpw) and the harness folder (/harness).
 */
#include <Python.h>
#include <emscripten/wasmfs.h>
#include <stdio.h>

#include "numpy_builtins.inl"

int main(int argc, char** argv)
{
	/* The host's folders: /cpw/python311.zip is the standard library, /harness/check.py the script. */
	if (argc < 3)
	{
		fprintf(stderr, "usage: harness.js <build folder> <harness folder>\n");
		return 2;
	}
	if (wasmfs_create_directory("/cpw", 0777, wasmfs_create_node_backend(argv[1])) != 0
		|| wasmfs_create_directory("/harness", 0777, wasmfs_create_node_backend(argv[2])) != 0)
	{
		fprintf(stderr, "cannot mount the build and harness folders\n");
		return 2;
	}
	for (size_t I = 0; I < sizeof(GNumPyBuiltins) / sizeof(GNumPyBuiltins[0]); ++I)
	{
		if (PyImport_AppendInittab(GNumPyBuiltins[I].Name, GNumPyBuiltins[I].Init) != 0)
		{
			fprintf(stderr, "cannot register %s\n", GNumPyBuiltins[I].Name);
			return 2;
		}
	}
	PyConfig Config;
	PyConfig_InitIsolatedConfig(&Config);
	Config.install_signal_handlers = 0;
	Config.write_bytecode = 0;
	PyStatus Status = PyConfig_SetString(&Config, &Config.home, L"/cpw");
	if (!PyStatus_Exception(Status))
	{
		Config.module_search_paths_set = 1;
		Status = PyWideStringList_Append(&Config.module_search_paths, L"/cpw/python311.zip");
	}
	if (!PyStatus_Exception(Status))
	{
		Status = Py_InitializeFromConfig(&Config);
	}
	PyConfig_Clear(&Config);
	if (PyStatus_Exception(Status))
	{
		fprintf(stderr, "Py_InitializeFromConfig failed: %s\n", Status.err_msg ? Status.err_msg : "?");
		return 3;
	}
	FILE* Script = fopen("/harness/check.py", "r");
	if (!Script)
	{
		fprintf(stderr, "no /harness/check.py\n");
		return 2;
	}
	const int Result = PyRun_SimpleFileEx(Script, "/harness/check.py", 1);
	Py_FinalizeEx();
	return Result == 0 ? 0 : 1;
}
