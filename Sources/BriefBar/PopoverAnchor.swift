import AppKit

/// What a menu-bar item's popover opens from: an invisible window over the item, on the display you clicked.
///
/// With more than one display, macOS moves an item's own window to whichever menu bar is active, and a popover
/// shown from the item goes with it. A click on an item can itself bring forward a Space on another display,
/// making that display's menu bar active (the README's FAQ explains why), so the list would open on the
/// display you clicked and then jump to the other. Shown from here, it stays where you opened it.
@MainActor
final class PopoverAnchor {
    private let window: NSPanel = {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.level = .statusBar
        // On every Space, full-screen ones too, as the menu bar is.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return window
    }()

    /// A view where `item` is now, to show a popover from; nil while the item isn't in a window.
    func view(over item: NSView) -> NSView? {
        guard let itemWindow = item.window, let view = window.contentView else { return nil }
        window.setFrame(itemWindow.convertToScreen(item.convert(item.bounds, to: nil)), display: false)
        window.orderFrontRegardless()
        return view
    }

    func remove() {
        window.orderOut(nil)
    }
}
