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
