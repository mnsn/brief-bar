import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// What a session answered with Explain, under what it's about: a long answer shows its beginning, with Show More, and what
/// it hides takes no clicks or scrolls. Drawn in a window off screen.
@MainActor
@Suite struct CopilotAnswerCardTests {
    /// A long answer that's mostly code: its code block, which scrolls sideways, starts in what shows and goes on far past it.
    private let answer = "Cap it where it doubles:\n\n```swift\n"
        + (1...60).map { "let delay\($0) = TimeSpan.FromTicks(Math.Min(delay.Ticks * 2, MaxDelay.Ticks))" }.joined(separator: "\n")
        + "\n```"

    @Test func whatALongAnswerHidesTakesNoClicks() throws {
        _ = NSApplication.shared
        let now = Date()
        let card = VStack(spacing: 0) {
            CopilotAnswerCard(answer: answer, asked: nil, place: "‘Retry backoff’", answeredAt: now, now: now, open: nil) {}
            Spacer(minLength: 0)
        }
        .frame(width: 440, height: 1_600, alignment: .top)
        let host = NSHostingView(rootView: card)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 440, height: 1_600), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        // Once it measured the answer, and cut it.
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        let code = try #require(scrollView(in: host))
        let frame = code.convert(code.bounds, to: host)
        // All of it, as tall as its 60 lines, far taller than what shows of the answer.
        #expect(frame.height > CopilotAnswerCard.wholeLines * 16)

        // Its beginning shows, and scrolls as it does.
        #expect(isIn(code, hit(host, at: CGPoint(x: frame.midX, y: frame.minY + 8))))
        // What's hidden of it, far below, doesn't take a click or a scroll there.
        #expect(!isIn(code, hit(host, at: CGPoint(x: frame.midX, y: frame.maxY - 20))))
    }

    /// What a click at a point of the window's content takes, the point from its top left.
    private func hit(_ host: NSView, at point: CGPoint) -> NSView? {
        let local = CGPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
        return host.hitTest(host.convert(local, to: host.superview))
    }

    private func isIn(_ view: NSView, _ hit: NSView?) -> Bool {
        hit.map { $0 === view || $0.isDescendant(of: view) } ?? false
    }

    /// The first view that scrolls in it, as a code block's does.
    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }
}
