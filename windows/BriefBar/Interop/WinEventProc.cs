namespace BriefBar.Interop;

/// What `SetWinEventHook` calls.
internal delegate void WinEventProc(nint hook, uint eventKind, nint hWnd, int idObject, int idChild, uint thread, uint time);
