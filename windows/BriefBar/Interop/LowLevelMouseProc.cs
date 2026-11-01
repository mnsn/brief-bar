namespace BriefBar.Interop;

/// What a low-level mouse hook calls for each mouse event.
internal delegate nint LowLevelMouseProc(int code, nint message, nint data);
