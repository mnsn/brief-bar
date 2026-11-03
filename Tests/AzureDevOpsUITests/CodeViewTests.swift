import AppKit
import AzureDevOpsCore
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// How code draws in a pull request's details: a row for each line, all as tall, at the window's text size, its text
/// copied without the numbers beside it.
@MainActor
@Suite struct CodeViewTests {
    private let rows = [
        CodeRow(.line(.unchanged), "if (attempt == MaxAttempts)", old: 79, new: 80),
        CodeRow(.line(.removed), "\tthrow;", old: 80),
        CodeRow(.gap, "12 lines"),
        CodeRow(.line(.added), "    delay *= 2;", new: 88, isMarked: true),
    ]

    @Test func everyRowIsAsTallAsTheOthersAtTheWindowsTextSize() {
        _ = NSApplication.shared
        let offered = CGSize(width: 320, height: 2_000)
        let usual = CodeMetrics(scale: 1)
        let size = NSHostingController(rootView: CodeView(rows: rows)).sizeThatFits(in: offered)
        #expect(size.height == usual.lineHeight * 4)
        #expect(size.width == offered.width)
        // Bigger text, taller rows.
        let bigger = CodeMetrics(scale: 1.5)
        #expect(bigger.lineHeight > usual.lineHeight && bigger.font.pointSize > usual.font.pointSize)
        let scaled = NSHostingController(rootView: CodeView(rows: rows).environment(\.textScale, 1.5)).sizeThatFits(in: offered)
        #expect(scaled.height == bigger.lineHeight * 4)
    }

    /// A form feed, a line separator or a vertical tab in a line would start another in the text, and every row after it
    /// would be beside another's number: each is a space.
    @Test func everyRowIsOneLine() {
        _ = NSApplication.shared
        let breaking = ["\u{0C}", "\u{0B}", "\u{85}", "\u{2028}", "\u{2029}", "\r"]
        let rows = breaking.enumerated().map { CodeRow(.line(.unchanged), "a\($1)b", old: $0 + 1, new: $0 + 1) }
        let view = CodeNSView()
        view.update(rows: rows, metrics: CodeMetrics(scale: 1), showsOldNumbers: false, label: "Code", onOverflow: nil)
        #expect(view.text.components(separatedBy: .newlines).count == rows.count)
        #expect(view.text == Array(repeating: "a b", count: rows.count).joined(separator: "\n"))
        #expect(CodeTextView.oneLine("\tlet a = 1") == "\tlet a = 1")
    }

    /// VoiceOver reads the code from a list of its rows, each with what the gutter shows of it, and then its text, which
    /// is copied as it is.
    @Test func voiceOverReadsEachRowWithItsNumbersAndHowItChanged() throws {
        _ = NSApplication.shared
        let view = CodeNSView()
        view.update(rows: rows, metrics: CodeMetrics(scale: 1), showsOldNumbers: true, label: "Code of Cart.cs", onOverflow: nil)
        let children = view.accessibilityChildren()?.compactMap { $0 as? NSView } ?? []
        let list = try #require(children.first { $0.accessibilityRole() == .list })
        #expect(list.isAccessibilityElement())
        #expect(list.accessibilityLabel() == "Code of Cart.cs")
        let spoken = (list.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        #expect(spoken == rows.map(ThreadCode.spoken))
        #expect(spoken.last == "Line 88, added, commented: delay *= 2;")
        // The text, to select and copy, says none of it.
        #expect(view.text == "if (attempt == MaxAttempts)\n\tthrow;\n⋯ 12 lines\n    delay *= 2;")
        // Other rows, other words.
        view.update(rows: Array(rows.prefix(1)), metrics: CodeMetrics(scale: 1), showsOldNumbers: true, label: "Code", onOverflow: nil)
        let again = (list.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        #expect(again == ["Line 80, 79 before the change: if (attempt == MaxAttempts)"])
    }

    /// VoiceOver finds each row where it shows: across the code, as tall as a row, one under another from the top.
    @Test func voiceOverFindsEachRowWhereItShows() throws {
        _ = NSApplication.shared
        let metrics = CodeMetrics(scale: 1)
        let view = CodeNSView()
        view.update(rows: rows, metrics: metrics, showsOldNumbers: true, label: "Code", onOverflow: nil)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let children = view.accessibilityChildren()?.compactMap { $0 as? NSView } ?? []
        let list = try #require(children.first { $0.accessibilityRole() == .list })
        let frames = (list.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityFrame() }
        #expect(frames.count == rows.count)
        for frame in frames {
            #expect(abs(frame.height - metrics.lineHeight) < 0.5 && abs(frame.width - 300) < 0.5)
            #expect(abs(frame.minX - 100) < 0.5)
        }
        // From the window's top down: the screen's y grows upward.
        #expect(frames.first.map { abs($0.maxY - window.frame.maxY) < 0.5 } == true)
        for (upper, lower) in zip(frames, frames.dropFirst()) {
            #expect(abs(upper.minY - lower.maxY) < 0.5)
        }
        window.contentView = nil
    }

    /// Rows that differ only in how a letter is written, as "é" in one character and in two, are other rows: what's
    /// copied is what shows.
    @Test func rowsThatLookTheSameButDifferInTheirBytesShowAsTheyAre() {
        _ = NSApplication.shared
        let composed = [CodeRow(.line(.added), "let caf\u{E9} = 1", new: 1)]
        let decomposed = [CodeRow(.line(.added), "let cafe\u{301} = 1", new: 1)]
        #expect(composed == decomposed)
        #expect(!CodeNSView.same(composed, decomposed))
        #expect(CodeNSView.same(composed, composed))
        let view = CodeNSView()
        view.update(rows: composed, metrics: CodeMetrics(scale: 1), showsOldNumbers: false, label: "Code", onOverflow: nil)
        view.update(rows: decomposed, metrics: CodeMetrics(scale: 1), showsOldNumbers: false, label: "Code", onOverflow: nil)
        #expect(view.text.utf8.elementsEqual("let cafe\u{301} = 1".utf8))
    }

    @Test func itsTextCopiesWithoutTheNumbers() {
        _ = NSApplication.shared
        let view = CodeNSView()
        view.update(rows: rows, metrics: CodeMetrics(scale: 1), showsOldNumbers: true, label: "Code", onOverflow: nil)
        #expect(view.text == "if (attempt == MaxAttempts)\n\tthrow;\n⋯ 12 lines\n    delay *= 2;")
        // As wide as its longest line wants, past the room it's given: it scrolls sideways rather than wrap.
        let long = [CodeRow(.line(.added), String(repeating: "x", count: 400), new: 1)]
        view.update(rows: long, metrics: CodeMetrics(scale: 1), showsOldNumbers: false, label: "Code", onOverflow: nil)
        #expect(view.idealWidth > 1_000)
    }
}
