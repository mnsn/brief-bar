namespace BriefBar.Interop;

/// A window procedure added with `SetWindowSubclass`.
internal delegate nint SubclassProc(nint hWnd, uint message, nint wParam, nint lParam, nuint id, nuint data);
