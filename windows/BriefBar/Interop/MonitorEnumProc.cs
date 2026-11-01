namespace BriefBar.Interop;

/// What `EnumDisplayMonitors` calls for each display.
internal delegate bool MonitorEnumProc(nint monitor, nint hdc, ref Win32Rect rect, nint data);
