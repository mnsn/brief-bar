import AzureDevOpsCore
import SwiftUI
import Testing
@testable import AzureDevOpsUI

/// A description's or a comment's text, as `RichTextView` draws it, opens its links, those in its text and its images',
/// through `ThisMac` (`opensLinksThroughThisMac`), which refuses each in tests, rather than as SwiftUI would by itself.
@MainActor
@Suite struct RichTextViewTests {
    /// Its whole body has what opens its links set, which only ThisMac makes (`scripts/check-boundaries.sh`). A test can't
    /// click one, so this is what says they go through ThisMac.
    @Test func opensItsLinksThroughThisMac() {
        let view = RichTextView(text: RichText(markdown: "See [the notes](https://dev.azure.com/contoso) and ![a chart](https://dev.azure.com/contoso/chart.png)."))
        #expect(String(describing: type(of: view.body)).hasSuffix(", _EnvironmentKeyWritingModifier<OpenURLAction>>"))
    }
}
