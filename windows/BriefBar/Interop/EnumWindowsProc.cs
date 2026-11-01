namespace BriefBar.Interop;

/// What `EnumWindows` calls for each top-level window: true to go on.
internal delegate bool EnumWindowsProc(nint hWnd, nint data);
