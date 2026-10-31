using System.Runtime.InteropServices;
using BriefBar.Core.Presentation;
using BriefBar.Interop;

namespace BriefBar.Shell;

/// Reserves a strip along an edge of a display for a window, as the taskbar reserves its own, so maximized windows stay
/// clear of it: https://learn.microsoft.com/windows/win32/shell/application-desktop-toolbars
internal sealed class AppBarReservation(nint hwnd, BarEdge edge)
{
    /// What Windows sends the window about its reservation, such as a full-screen app opening.
    public const uint CallbackMessage = WindowMessages.WM_APP + 1;

    public bool IsRegistered { get; private set; }

    public void Register()
    {
        if (IsRegistered)
        {
            return;
        }
        var data = Data(rect: default);
        Shell32.SHAppBarMessage(message: AppBarMessages.ABM_NEW, data: ref data);
        IsRegistered = true;
    }

    /// Where a strip `height` pixels tall can go on `display`: next to anything already reserved on that edge.
    public PixelRect Query(PixelRect display, int height)
    {
        var wanted = edge == BarEdge.Top
            ? new PixelRect(Left: display.Left, Top: display.Top, Width: display.Width, Height: height)
            : new PixelRect(Left: display.Left, Top: display.Bottom - height, Width: display.Width, Height: height);
        var data = Data(rect: Win32Rect.From(rect: wanted));
        Shell32.SHAppBarMessage(message: AppBarMessages.ABM_QUERYPOS, data: ref data);
        // Windows moves the edge it was asked about; the other edge follows, to keep the strip `height` tall.
        if (edge == BarEdge.Top)
        {
            data.rc.Bottom = data.rc.Top + height;
        }
        else
        {
            data.rc.Top = data.rc.Bottom - height;
        }
        return data.rc.ToPixelRect();
    }

    /// Reserves `rect`, and returns what Windows reserved.
    public PixelRect Reserve(PixelRect rect)
    {
        var data = Data(rect: Win32Rect.From(rect: rect));
        Shell32.SHAppBarMessage(message: AppBarMessages.ABM_SETPOS, data: ref data);
        return data.rc.ToPixelRect();
    }

    /// The window was activated: Windows keeps the reservation's z-order with it.
    public void Activated()
    {
        if (!IsRegistered)
        {
            return;
        }
        var data = Data(rect: default);
        Shell32.SHAppBarMessage(message: AppBarMessages.ABM_ACTIVATE, data: ref data);
    }

    public void Moved()
    {
        if (!IsRegistered)
        {
            return;
        }
        var data = Data(rect: default);
        Shell32.SHAppBarMessage(message: AppBarMessages.ABM_WINDOWPOSCHANGED, data: ref data);
    }

    /// Gives the space back, at once.
    public void Remove()
    {
        if (!IsRegistered)
        {
            return;
        }
        var data = Data(rect: default);
        Shell32.SHAppBarMessage(message: AppBarMessages.ABM_REMOVE, data: ref data);
        IsRegistered = false;
    }

    /// Explorer restarted, and forgot every reservation.
    public void Forget() => IsRegistered = false;

    AppBarData Data(Win32Rect rect) => new()
    {
        cbSize = Marshal.SizeOf<AppBarData>(),
        hWnd = hwnd,
        uCallbackMessage = CallbackMessage,
        uEdge = edge == BarEdge.Top ? AppBarMessages.ABE_TOP : AppBarMessages.ABE_BOTTOM,
        rc = rect,
    };
}
