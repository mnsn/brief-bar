import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// What a session answered with Explain, under what it's about: a long answer shows its beginning, with Show More, and what
/// it hides takes no clicks or scrolls, and isn't there for the keyboard or VoiceOver to reach. Drawn in a window off screen.
@MainActor
@Suite struct CopilotAnswerCardTests {
    /// A long answer that's mostly code: its code block, which scrolls sideways, starts in what shows and goes on far past it.
    private let answer = "Cap it where it doubles:\n\n```swift\n"
        + (1...60).map { "let delay\($0) = TimeSpan.FromTicks(Math.Min(delay.Ticks * 2, MaxDelay.Ticks))" }.joined(separator: "\n")
        + "\n```"

    @Test func whatALongAnswerHidesTakesNoClicks() async throws {
        _ = NSApplication.shared
        let (window, host) = try await host(answer)
        defer { window.contentView = nil }
        let code = try #require(scrollView(in: host))
        let frame = code.convert(code.bounds, to: host)
        // All of it, as tall as its 60 lines, far taller than what shows of the answer.
        #expect(frame.height > CopilotAnswerCard.wholeLines * 16)

        // Its beginning shows, and scrolls as it does.
        #expect(isIn(code, hit(host, at: CGPoint(x: frame.midX, y: frame.minY + 8))))
        // What's hidden of it, far below, doesn't take a click or a scroll there.
        #expect(!isIn(code, hit(host, at: CGPoint(x: frame.midX, y: frame.maxY - 20))))
    }

    /// The card, in a window off screen, once it measured its answer and cut it: the main run loop lays it out while the
    /// test waits, and the main actor goes on with other tests' work, as it wouldn't if the test ran that run loop itself.
    private func host(_ answer: String) async throws -> (NSWindow, NSHostingView<AnyView>) {
        let now = Date()
        let card = VStack(spacing: 0) {
            CopilotAnswerCard(answer: answer, asked: nil, place: "‘Retry backoff’", answeredAt: now, now: now, open: nil) {}
            Spacer(minLength: 0)
        }
        .frame(width: 440, height: 1_600, alignment: .top)
        let host = NSHostingView(rootView: AnyView(card))
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 440, height: 1_600), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
        }
        return (window, host)
    }

    /// A long answer's blocks that start below what shows aren't there at all, for the keyboard's focus or VoiceOver to
    /// reach, as an image's link there would be: here, a code block, whose scroll view isn't there, as all of the answer,
    /// which measures it unseen, has none either. A short answer has all of its blocks.
    @Test func whatALongAnswerHidesIsntThere() async throws {
        _ = NSApplication.shared
        let first = "Cap it where it doubles."
        let points = (1...20).map { "Point \($0): each wait doubles until one outlasts the load balancer's 60 seconds." }
        let code = "```swift\nlet delay = TimeSpan.FromSeconds(30)\n```"
        let (window, host) = try await host(([first] + points + [code]).joined(separator: "\n\n"))
        defer { window.contentView = nil }
        #expect(scrollView(in: host) == nil)

        let (shortWindow, short) = try await self.host([first, code].joined(separator: "\n\n"))
        defer { shortWindow.contentView = nil }
        #expect(scrollView(in: short) != nil)
    }

    /// While it's cut, the blocks that start in what shows are there, the last of them cut: at least the first.
    @Test func theBlocksThatStartInWhatShowsAreThere() {
        #expect(CopilotAnswerCard.shown(of: [0: 0, 1: 40, 2: 150, 3: 190, 4: 400], in: 192) == 4)
        #expect(CopilotAnswerCard.shown(of: [0: 0, 1: 192], in: 192) == 1)
        #expect(CopilotAnswerCard.shown(of: [0: 0], in: 192) == 1)
        #expect(CopilotAnswerCard.shown(of: [:], in: 192) == 1)
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
