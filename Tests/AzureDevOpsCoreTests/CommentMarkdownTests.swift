import Foundation
import Testing
@testable import AzureDevOpsCore

/// What comments on pull requests have in their Markdown beyond what work items' does: HTML, from bots most of all.
@Suite struct CommentMarkdownTests {
    private func plain(_ markdown: String) -> String {
        RichText(markdown: markdown).plainText
    }

    @Test func showsNothingOfHTMLComments() {
        #expect(RichText(markdown: "<!-- bot: 42 -->\nThe build **failed**.").blocks == [
            .paragraph([RichText.Run("The build "), RichText.Run("failed", style: .bold), RichText.Run(".")]),
        ])
        #expect(plain("Before<!-- hidden --> after") == "Before after")
        // Over several lines, blank ones among them, and whatever they look like.
        #expect(plain("<!--\nmarker: 7\n\n- not a list\n# not a heading\n-->\nShown") == "Shown")
        #expect(plain("Shown\n\n<!-- an end it never gets\n\n- hidden") == "Shown")
        #expect(plain("<!--\nhidden\n--> and what follows") == "and what follows")
        // In a list's item, starting it too, and in a quote.
        #expect(plain("- one\n\n  <!--\n  hidden\n\n  -->\n- two") == "• one\n• two")
        #expect(plain("- <!--\n  hidden\n\n  more\n  -->\n- shown") == "• shown")
        #expect(plain("- <!--\n  hidden\n  --> kept\n- shown") == "• kept\n• shown")
        #expect(plain("> <!--\n> hidden\n>\n> -->\n> shown") == "shown")
        // What looks like code in one is the comment's; code that starts first is code.
        #expect(plain("Fixes the retry.<!-- Link the work item with `AB#1234` before merging --> Thanks!") == "Fixes the retry. Thanks!")
        #expect(plain("<!-- template: describe `why`, not what --> Real text") == "Real text")
        #expect(RichText(markdown: "`a <!-- b` c").blocks == [.paragraph([RichText.Run("a <!-- b", style: .code), RichText.Run(" c")])])
        // One that starts after text is inline: it can't go past its paragraph, so what's after shows, as in Azure DevOps.
        #expect(plain("Before <!-- an end in another paragraph\n\nShown\n-->") == "Before <!-- an end in another paragraph\nShown\n-->")
    }

    @Test func breaksLinesAndBlocksAsHTMLDoes() {
        #expect(plain("Line one<br>Line two<br/>Line three<BR />Line four") == "Line one\nLine two\nLine three\nLine four")
        #expect(RichText(markdown: "<details><summary>2 warnings</summary>\n\nUnused variable `delay`.\n\n</details>").blocks == [
            .paragraph([RichText.Run("2 warnings")]),
            .paragraph([RichText.Run("Unused variable "), RichText.Run("delay", style: .code), RichText.Run(".")]),
        ])
        #expect(plain("<p>First</p><p>Second</p>") == "First\nSecond")
        #expect(plain("<table><tr><th>File</th><th>Issues</th></tr><tr><td>a.cs</td><td>2</td></tr></table>") == "File Issues\na.cs 2")
    }

    @Test func formattingTagsKeepTheirText() {
        #expect(plain("Use <b>bold</b>, <i>italics</i>, <sub>small</sub> and <span style=\"color:red\">red</span>.")
            == "Use bold, italics, small and red.")
        #expect(plain("<a href=\"https://example.invalid/rules\">The rule</a> says so") == "The rule says so")
        // What's in an attribute's quotes is the tag's, a bracket or backticks included.
        #expect(plain("<span title=\"a > b\">shown</span>") == "shown")
        #expect(plain("<span title=\"use `x`\">Shown</span> and `<b>`") == "Shown and <b>")
        #expect(RichText(markdown: "<img src=\"https://example.invalid/badge.svg\" alt=\"A > B\">").blocks == [
            .paragraph([RichText.Run("A > B", link: URL(string: "https://example.invalid/badge.svg"))]),
        ])
    }

    @Test func readsImagesInHTMLAsImages() {
        #expect(RichText(markdown: "<img src=\"https://example.invalid/badge.png\" alt=\"Quality gate: passed\">").blocks == [
            .paragraph([RichText.Run("Quality gate: passed", link: URL(string: "https://example.invalid/badge.png"))]),
        ])
        // Only of a web page, and otherwise its description.
        #expect(plain("<img src='javascript:alert(1)' alt='Badge'>") == "Badge")
        #expect(plain("<img src=data:image/png;base64,AAAA>") == "")
    }

    @Test func leavesCodeAsItIs() {
        #expect(RichText(markdown: "Use `<br/>` and ``a `<b>` b``, not <br>.").blocks == [
            .paragraph([
                RichText.Run("Use "), RichText.Run("<br/>", style: .code), RichText.Run(" and "), RichText.Run("a `<b>` b", style: .code),
                RichText.Run(", not\n."),
            ]),
        ])
        #expect(RichText(markdown: "```html\n<!-- kept -->\n<p>Kept</p>\n```").blocks == [.code("<!-- kept -->\n<p>Kept</p>")])
        // A fence indented four columns is code in a fenced block, and doesn't end it, wherever the block's own fence is.
        #expect(RichText(markdown: "```\n    ```\n<!--\nkept\n-->\n```").blocks == [.code("    ```\n<!--\nkept\n-->")])
        #expect(RichText(markdown: "   ```\n    ```\n<!--\nkept\n-->\n```").blocks == [.code(" ```\n<!--\nkept\n-->")])
        // A code span that ends with a backslash, which is a backslash in code.
        #expect(RichText(markdown: "`<br>\\` and <b>bold</b>").blocks == [
            .paragraph([RichText.Run("<br>\\", style: .code), RichText.Run(" and bold")]),
        ])
        // An escaped backtick starts none.
        #expect(plain("\\`<b>x</b>`") == "`x`")
        // Indented with tabs, as with spaces.
        #expect(RichText(markdown: "\t<!--\n\tliteral code\n\t-->").blocks == [.code("<!--\nliteral code\n-->")])
        #expect(RichText(markdown: "    <!--\n    literal code\n    -->").blocks == [.code("<!--\nliteral code\n-->")])
        // A backtick that nothing closes isn't code.
        #expect(plain("A lone ` and <b>bold</b>") == "A lone ` and bold")
    }

    @Test func keepsWhatOnlyLooksLikeATag() {
        #expect(plain("Return a List<T> or Dictionary<string, int> when a < b") == "Return a List<T> or Dictionary<string, int> when a < b")
        #expect(plain("Escaped: &lt;b&gt;bold&lt;/b&gt;") == "Escaped: <b>bold</b>")
        #expect(plain("Escaped \\<br> and \\<!-- not a comment -->") == "Escaped <br> and <!-- not a comment -->")
        // A backslash escaped itself doesn't escape what follows.
        #expect(plain("\\\\<br>after") == "\\\nafter")
        #expect(RichText(markdown: "See <https://example.invalid/docs>").blocks == [
            .paragraph([RichText.Run("See "), RichText.Run("https://example.invalid/docs", link: URL(string: "https://example.invalid/docs"))]),
        ])
    }

    @Test func showsAReviewersSuggestionAsCode() {
        #expect(RichText(markdown: "Cap it:\n```suggestion\ndelay = Min(delay * 2, MaxDelay);\n```").blocks == [
            .paragraph([RichText.Run("Cap it:")]), .code("delay = Min(delay * 2, MaxDelay);"),
        ])
    }

    /// Each in well under a second, where reading them in quadratic time would take minutes: plenty of room for a slow
    /// runner.
    @Test func readsAManyTaggedCommentInLinearTime() {
        for long in [
            String(repeating: "<b>x</b> `y` <!-- z --> <a ", count: 5_000),
            "<img " + String(repeating: "a", count: 100_000) + ">",
            "<img src=" + String(repeating: "a-b ", count: 25_000) + ">",
            String(repeating: "` <!-- ``", count: 20_000),
            String(repeating: "<span title=\"`x` > ", count: 10_000),
            "<span title=\"" + String(repeating: "<a b ", count: 20_000),
        ] {
            let start = ContinuousClock.now
            _ = RichText(markdown: long)
            #expect(ContinuousClock.now - start < .seconds(10))
        }
    }
}
