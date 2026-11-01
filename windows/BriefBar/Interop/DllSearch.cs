using System.Runtime.InteropServices;

// Windows' own DLLs, loaded only from System32, never from the app's folder or the current directory.
[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
