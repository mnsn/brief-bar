import AppKit
import BriefBarCore
import SwiftUI
import Testing
@testable import BriefBarUI

/// Ask…'s field in a window, as it opens under a session's row (`SessionAskPart`): it takes the keyboard as it opens;
/// Return asks what you wrote, or where the session stands when you wrote nothing; Esc closes it, asking nothing.
@MainActor
@Suite(.serialized) struct SessionAskFieldTests {
    private let session = ItemRef.session("2f8a4c6e-1b3d-4e5f-8a7b-9c0d1e2f3a14")!

    /// The keys a test presses.
    private enum Key {
        case returnKey
        case escape

        var characters: String { self == .returnKey ? "\r" : "\u{1b}" }
        var code: UInt16 { self == .returnKey ? 36 : 53 }
    }

    /// The session's part under its row in a window off screen, as BriefBar's windows are, its field open, with a way to ask
    /// that never answers until it's stopped.
    private func show(_ services: AppServices) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        services.sessionAsks.setAsker { _ in
            do {
                try await Task.sleep(for: .seconds(600))
            } catch {
                return .failure(SessionAsks.Problem("Stopped"))
            }
            return .success("Too late")
        }
        services.sessionAsks.openField(for: session)
        let view = SessionAskPart(ref: session, name: "Retry backoff", place: .row)
            .environmentObject(services)
            .frame(width: 400)
        let window = TestWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 300), styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    /// Opens the field until SwiftUI gives it the keyboard, as it does as the field shows, and then does `act` with its
    /// editor at once. SwiftUI's keyboard is one for all a test process's windows, none of them key, and another test's
    /// field that asks for it as it shows can take it first: then it opens the field again.
    private func opened(then act: (NSWindow, NSView, NSTextView, SessionAsks) async throws -> Void) async throws -> SessionAsks {
        for _ in 0..<20 {
            let services = AppServices(defaults: MemoryDefaults(), isDemo: false)
            let (window, host) = show(services)
            let since = ContinuousClock.now
            while (window.firstResponder as? NSTextView)?.isFieldEditor != true, ContinuousClock.now - since < .seconds(3) {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
                window.contentView = nil
                continue
            }
            #expect(editor.string.isEmpty)
            try await act(window, host, editor, services.sessionAsks)
            window.contentView = nil
            return services.sessionAsks
        }
        throw TestError("SwiftUI never gave the field the keyboard")
    }

    /// Presses a key in the window, as the keyboard does, for the field.
    private func press(_ key: Key, in window: NSWindow) throws {
        window.sendEvent(try event(key, in: window))
    }

    private func event(_ key: Key, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: key.characters,
            charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code
        ))
    }

    @Test func returnAsksWhatYouWrote() async throws {
        let asks = try await opened { window, _, editor, asks in
            editor.insertText("Why did you cap it at 30 s?", replacementRange: editor.selectedRange())
            try await until("the field to keep what you wrote") { asks.words(for: session) == "Why did you cap it at 30 s?" }
            try press(.returnKey, in: window)
            try await until("the session to be asked") { asks.question(for: session)?.isAsking == true }
        }
        let question = try #require(asks.question(for: session))
        #expect(question.asked == "Why did you cap it at 30 s?")
        #expect(question.isAsking)
        #expect(!asks.isFieldOpen(for: session))
        asks.dismiss(session)
    }

    @Test func returnWithNothingWrittenAsksWhereItStands() async throws {
        let asks = try await opened { window, _, _, asks in
            try press(.returnKey, in: window)
            try await until("the session to be asked") { asks.question(for: session)?.isAsking == true }
        }
        let question = try #require(asks.question(for: session))
        #expect(question.asked == nil)
        #expect(question.shownQuestion == "Where do you stand?")
        asks.dismiss(session)
    }

    /// Esc is ✕'s shortcut: it closes the field, forgetting what you wrote, and asks nothing.
    @Test func escapeClosesItAskingNothing() async throws {
        let asks = try await opened { window, host, editor, asks in
            editor.insertText("Never mind", replacementRange: editor.selectedRange())
            try await until("the field to keep what you wrote") { asks.words(for: session) == "Never mind" }
            let escape = try event(.escape, in: window)
            try await until("Esc to close the field") { host.performKeyEquivalent(with: escape) }
            try await until("the field to close") { !asks.isFieldOpen(for: session) }
        }
        #expect(asks.field == nil)
        #expect(asks.question(for: session) == nil)
    }
}
