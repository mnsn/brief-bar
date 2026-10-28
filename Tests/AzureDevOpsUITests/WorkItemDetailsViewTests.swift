import AppKit
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// How the details lay out what they show.
@MainActor
@Suite struct WorkItemDetailsViewTests {
    @Test func aLongChipFitsTheWidthItsOffered() {
        _ = NSApplication.shared
        let tag = String(repeating: "a-very-long-tag-", count: 12)
        let offered = CGSize(width: 120, height: 200)
        // A tag, or a state, in the details: cut short to the panel's width, rather than cut off by it.
        let fitting = NSHostingController(rootView: Chip(text: tag, fitsWidth: true)).sizeThatFits(in: offered)
        #expect(fitting.width <= offered.width)
        #expect(fitting.height > 0 && fitting.height < 40)
        // Elsewhere, as wide as its text.
        let fixed = NSHostingController(rootView: Chip(text: tag)).sizeThatFits(in: offered)
        #expect(fixed.width > offered.width)
    }
}
