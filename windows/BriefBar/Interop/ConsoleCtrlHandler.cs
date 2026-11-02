namespace BriefBar.Interop;

/// What `SetConsoleCtrlHandler` calls for a console's Ctrl+C, Ctrl+Break or close, by its kind: true when it's handled,
/// so that Windows doesn't end the process.
internal delegate bool ConsoleCtrlHandler(uint kind);
