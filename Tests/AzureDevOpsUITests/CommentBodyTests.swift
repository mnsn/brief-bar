import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// What a comment says, in a pull request's details: drawn again only when that changes, byte for byte, or how quiet it
/// reads, not as the time beside it moves on.
@MainActor
@Suite struct CommentBodyTests {
    @Test func itsTheSameWhileItsMarkdownIsByteForByte() {
        let markdown = "Could we cap the backoff at **30 seconds**?"
        #expect(CommentBody(markdown: markdown, isQuiet: false) == CommentBody(markdown: markdown, isQuiet: false))
        #expect(CommentBody(markdown: markdown, isQuiet: false) != CommentBody(markdown: markdown, isQuiet: true))
        #expect(CommentBody(markdown: markdown, isQuiet: false) != CommentBody(markdown: markdown + " Thanks.", isQuiet: false))
        // "é" in one character and in two look the same, but aren't what was written.
        #expect("caf\u{E9}" == "cafe\u{301}")
        #expect(CommentBody(markdown: "caf\u{E9}", isQuiet: false) != CommentBody(markdown: "cafe\u{301}", isQuiet: false))
    }
}
