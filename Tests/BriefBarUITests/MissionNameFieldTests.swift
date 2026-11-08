import AppKit
import BriefBarUI
import SwiftUI
import Testing

/// Rename…'s field in a window, as you'd use it (`MissionNameField`): it takes the keyboard as it shows, holding the
/// mission's name; Return keeps what you typed, as clicking elsewhere does, and Escape doesn't. What it says first counts:
/// its mission's header keeps or drops the name then, and stops renaming, so what follows as the field goes is too late.
@MainActor
@Suite(.serialized) struct MissionNameFieldTests {
    /// What the field says to its header, in order.
    private final class Field {
        var draft: String
        var said: [String] = []

        init(_ draft: String) { self.draft = draft }
    }

    /// The keys a test presses.
    private enum Key {
        case returnKey
        case escape

        var characters: String { self == .returnKey ? "\r" : "\u{1b}" }
        var code: UInt16 { self == .returnKey ? 36 : 53 }
    }

    /// The field in a window off screen, as BriefBar's windows are, as a mission's header shows it once you choose
    /// Rename….
    private func show(_ field: Field) -> NSWindow {
        _ = NSApplication.shared
        let view = MissionNameField(
            draft: Binding(get: { field.draft }, set: { field.draft = $0 }),
            keep: { field.said.append("keep \(field.draft)") }, cancel: { field.said.append("cancel") },
            gone: { field.said.append("gone") }
        )
        let window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 60), styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.frame(width: 400))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return window
    }

    /// Shows the field, holding `name`, until SwiftUI gives it the keyboard, as it does as the field shows, and then does
    /// `act` with its editor at once, nothing else running between. SwiftUI's keyboard is one for all a test process's
    /// windows, none of them key, and another test's field that asks for it as it shows, such as `DetailsDraftsTests`'
    /// composer, can take it first: then it shows the field again.
    private func shown(_ name: String, then act: (NSWindow, NSTextView) throws -> Void) async throws -> Field {
        for _ in 0..<20 {
            let field = Field(name)
            let window = show(field)
            let since = ContinuousClock.now
            while (window.firstResponder as? NSTextView)?.isFieldEditor != true, ContinuousClock.now - since < .seconds(3) {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, field.said.isEmpty else {
                window.contentView = nil
                continue
            }
            #expect(editor.string == name)
            try act(window, editor)
            try await until("the field to say something") { !field.said.isEmpty }
            window.contentView = nil
            return field
        }
        throw TestError("SwiftUI never gave the field the keyboard")
    }

    /// Types `text` over all the field holds, as you would once it's selected.
    private func type(_ text: String, in editor: NSTextView) {
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    /// Presses a key in the window, as the keyboard does.
    private func press(_ key: Key, in window: NSWindow) throws {
        window.sendEvent(try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: key.characters,
            charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code
        )))
    }

    @Test func itHoldsTheNameAndReturnKeepsWhatYouTyped() async throws {
        let field = try await shown("Checkout redesign") { window, editor in
            type("Checkout coupons", in: editor)
            try press(.returnKey, in: window)
        }
        #expect(field.said.first == "keep Checkout coupons")
    }

    @Test func escapeKeepsNothing() async throws {
        let field = try await shown("Checkout redesign") { window, editor in
            type("Checkout coupons", in: editor)
            try press(.escape, in: window)
        }
        #expect(field.said.first == "cancel")
    }

    @Test func clickingElsewhereKeepsWhatYouTypedAsFinderDoes() async throws {
        let field = try await shown("Checkout redesign") { window, editor in
            type("Faster checkout", in: editor)
            // Something else takes the keyboard.
            #expect(window.makeFirstResponder(nil))
        }
        #expect(field.said.first == "keep Faster checkout")
    }
}
