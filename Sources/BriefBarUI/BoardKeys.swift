import AppKit
import SwiftUI

/// ⌘→ and ⌘← for the Board while its cards can't have the keyboard's focus: while the details of what you clicked cover it,
/// in a narrow window or at a bigger text size, which disables it (`DetailsSplit`). They move the card of the pull request
/// whose own details show, as its own keys would, where you see it move: not while a page is over them, such as a linked
/// item's or a file's. Only in the Board's own window, and never while a text field or text view has the keys, which move
/// its insertion point with them.
@MainActor
final class BoardKeys {
    /// What ⌘→ (true) and ⌘← (false) do; nil while the Board's cards can have the keys themselves.
    fileprivate var move: (@MainActor (_ forward: Bool) -> Void)?
    /// In the Board, for its window.
    fileprivate weak var view: NSView?
    private var monitor: Any?

    /// Whether text is being edited in the Board's window, which then has the keys.
    var isEditingText: Bool {
        view?.window?.firstResponder is NSText
    }

    /// Takes the keys while there's something for them to do and the Board is in a window; lets them go otherwise.
    fileprivate func update() {
        if move != nil, view?.window != nil {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // What the Board needs of the event goes to the main actor, rather than the event itself.
                let key = BoardKey(event)
                let taken = MainActor.assumeIsolated { self?.take(key) ?? false }
                return taken ? nil : event
            }
        } else if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func take(_ key: BoardKey) -> Bool {
        guard let move, let forward = key.forward, let window = view?.window, key.windowNumber == window.windowNumber,
              !(window.firstResponder is NSText)
        else { return false }
        // Held down, it moves once, as a card's own keys do.
        if !key.isRepeat { move(forward) }
        return true
    }
}

/// What the Board needs of a key.
private struct BoardKey: Sendable {
    /// ⌘→ for true, ⌘← for false; nil for any other key, or with another modifier too, such as ⇧ for selecting text.
    let forward: Bool?
    /// The window it's in.
    let windowNumber: Int
    let isRepeat: Bool

    init(_ event: NSEvent) {
        let isCommandAlone = event.modifierFlags.isCommandAlone
        forward = switch event.keyCode {
        case 124 where isCommandAlone: true
        case 123 where isCommandAlone: false
        default: nil
        }
        windowNumber = event.windowNumber
        isRepeat = event.isARepeat
    }
}

// The Board's keys take ⌘ alone, from a card that has the keyboard's focus as from the monitor: whatever else a key carries,
// such as an arrow's numeric pad and function flags, or Caps Lock, but not ⇧, ⌥ or ⌃ with it, which make another shortcut,
// such as ⇧⌘→, which selects text.

extension NSEvent.ModifierFlags {
    /// ⌘ alone, as the Board's keys take it.
    var isCommandAlone: Bool {
        intersection([.command, .shift, .option, .control]) == .command
    }
}

extension EventModifiers {
    /// ⌘ alone, as the Board's keys take it.
    var isCommandAlone: Bool {
        intersection([.command, .shift, .option, .control]) == .command
    }
}

/// Where the Board's keys learn its window: an empty view behind it, which nothing hits or draws.
struct BoardKeysView: NSViewRepresentable {
    let keys: BoardKeys
    /// What ⌘→ (true) and ⌘← (false) do; nil while the Board's cards can have the keys themselves.
    let move: (@MainActor (_ forward: Bool) -> Void)?

    func makeNSView(context: Context) -> Probe {
        Probe(keys: keys)
    }

    func updateNSView(_ view: Probe, context: Context) {
        keys.view = view
        keys.move = move
        keys.update()
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        guard view.keys.view === view else { return }
        view.keys.move = nil
        view.keys.update()
    }

    final class Probe: NSView {
        let keys: BoardKeys

        init(keys: BoardKeys) {
            self.keys = keys
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Out of its window it lets the keys go; back in, it takes them again. A window that closes keeps its views, as
        /// BriefBar's do, so the monitor stays while it's closed, but does nothing: no key comes to a closed window.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if keys.view === self { keys.update() }
        }
    }
}
