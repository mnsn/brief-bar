import Foundation
import Testing
@testable import AzureDevOpsCore

private typealias Run = RichText.Run

@Suite struct RichTextHTMLTests {
    @Test func readsTheEditorsLinesAsLinesOfOneParagraph() {
        let text = RichText(html: "<div>First line</div><div>Second <b>bold</b> line</div><div><br></div><div>&nbsp;</div><div>After a blank line</div>")
        #expect(text.blocks == [.paragraph([
            Run("First line\nSecond "), Run("bold", style: .bold), Run(" line\n\nAfter a blank line"),
        ])])
    }

    @Test func collapsesSpacesAsABrowserDoes() {
        let text = RichText(html: "<p>\n   Some   text\n spread <i> over </i>lines  </p><p>Next</p>")
        #expect(text.blocks == [.paragraph([Run("Some text spread "), Run("over ", style: .italic), Run("lines")]), .paragraph([Run("Next")])])
    }

    @Test func readsListsTheirNumbersAndNesting() {
        let text = RichText(html: "<ol start=\"3\"><li>Three</li><li>Four<ul><li>Nested</li></ul></li></ol><ul><li>One<li>Two</ul><p>After</p>")
        #expect(text.blocks == [
            .listItem(.number(3), depth: 0, [Run("Three")]),
            .listItem(.number(4), depth: 0, [Run("Four")]),
            .listItem(.bullet, depth: 1, [Run("Nested")]),
            .listItem(.bullet, depth: 0, [Run("One")]),
            .listItem(.bullet, depth: 0, [Run("Two")]),
            .paragraph([Run("After")]),
        ])
    }

    @Test func readsTaskListsAsMarkdownRendersThem() {
        let text = RichText(html: "<ul><li><input type=\"checkbox\" checked disabled> Done</li><li><input type=checkbox> To do</li></ul>")
        #expect(text.blocks == [
            .listItem(.checkbox(checked: true), depth: 0, [Run("Done")]),
            .listItem(.checkbox(checked: false), depth: 0, [Run("To do")]),
        ])
    }

    @Test func linksOnlyToWebPagesAndMentionsLinkNowhere() throws {
        let text = RichText(html: """
            <a href="https://example.test/a?b=1&amp;c=2">a page</a> <a href="javascript:alert(1)">a script</a> \
            <a href="#" data-vss-mention="version:2.0,b001">@Sam Rivera</a> <a href='mailto:sam@example.test'>mail</a>
            """)
        guard case .paragraph(let runs) = try #require(text.blocks.first) else { Issue.record("Not a paragraph"); return }
        #expect(runs == [
            Run("a page", link: URL(string: "https://example.test/a?b=1&c=2")), Run(" a script "), Run("@Sam Rivera", style: .bold),
            Run(" "), Run("mail", link: URL(string: "mailto:sam@example.test")),
        ])
    }

    @Test func decodesCharacterReferences() {
        let text = RichText(html: "Fish &amp; chips&nbsp;&mdash; &#233;t&#xE9; &unknown; 5 &lt; 6 &#0;")
        #expect(text.plainText == "Fish & chips\u{00A0}— été &unknown; 5 < 6 &#0;")
    }

    @Test func decodesEveryNamedReference() {
        let text = RichText(html: "caf&eacute; &ouml; &Eacute;&szlig; &alpha;&Omega; &hearts; &hellip; &rsquo;&euro;&trade; &lang;x&rang; &apos;")
        #expect(text.plainText == "café ö Éß αΩ ♥ … ’€™ ⟨x⟩ '")
        // Names are case-sensitive, as in HTML.
        #expect(RichText(html: "&EACUTE;").plainText == "&EACUTE;")
    }

    @Test func leavesOutScriptsStylesAndComments() {
        let text = RichText(html: "<style>p { color: red }</style><script>alert('<p>no</p>')</script><!-- <p>hidden</p> --><p>Shown</p>")
        #expect(text.blocks == [.paragraph([Run("Shown")])])
    }

    @Test func readsHeadingsQuotesCodeRulesAndImages() {
        let text = RichText(html: """
            <h2>Title</h2><blockquote><p>Quoted</p></blockquote><pre>  let a = 1
                b &lt; c</pre><hr><img src="https://dev.azure.com/contoso/p/_apis/wit/attachments/1?fileName=shot.png">\
            <img alt="A diagram" src="data:image/png;base64,AAAA">
            """)
        #expect(text.blocks == [
            .heading(level: 2, [Run("Title")]),
            .quote([Run("Quoted")]),
            .code("  let a = 1\n    b < c"),
            .rule,
            .image(alt: "shot.png", url: URL(string: "https://dev.azure.com/contoso/p/_apis/wit/attachments/1?fileName=shot.png")),
            .image(alt: "A diagram", url: nil),
        ])
    }

    @Test func readsTables() {
        let text = RichText(html: "<table><tbody><tr><th>Balance</th><th>Total</th></tr><tr><td>$50</td><td><b>$30</b><br>paid</td></tr></tbody></table>")
        #expect(text.blocks == [.table([
            [[Run("Balance", style: .bold)], [Run("Total", style: .bold)]],
            [[Run("$50")], [Run("$30", style: .bold), Run("\npaid")]],
        ])])
    }

    @Test func survivesBrokenHTML() {
        let text = RichText(html: "<div>a < b and <b>bold <i>both</b> italic")
        #expect(text.blocks == [.paragraph([
            Run("a < b and "), Run("bold ", style: .bold), Run("both", style: [.bold, .italic]), Run(" italic", style: .italic),
        ])])
        #expect(RichText(html: "").isEmpty)
        #expect(RichText(html: "<div><br></div><p>&nbsp;</p>").isEmpty)
        #expect(RichText(html: "<b").blocks == [.paragraph([Run("<b")])])
    }

    @Test func listNumbersCantOverflow() {
        let text = RichText(html: "<ol start=\"9223372036854775807\"><li>A</li><li value=\"9223372036854775807\">B</li><li>C</li></ol>")
        #expect(text.blocks == [
            .listItem(.number(999_999_999), depth: 0, [Run("A")]),
            .listItem(.number(999_999_999), depth: 0, [Run("B")]),
            .listItem(.number(1_000_000_000), depth: 0, [Run("C")]),
        ])
        #expect(RichText(html: "<ol start=\"-3\"><li>A</li></ol>").blocks == [.listItem(.number(-3), depth: 0, [Run("A")])])
    }

    @Test func readsATagThatNeverEndsOnce() {
        // Every "<a " would otherwise be read to the end again: a long description would take minutes.
        let html = "Start " + String(repeating: "<a ", count: 50_000) + "end"
        var text = RichText()
        let elapsed = ContinuousClock().measure { text = RichText(html: html) }
        #expect(text.plainText == html)
        #expect(elapsed < .seconds(3))
        // What follows it is its text too, even what would be a tag in a value that never ends.
        #expect(RichText(html: "Hi <a title=\"x <b>bold</b>").plainText == "Hi <a title=\"x <b>bold</b>")
        #expect(RichText(html: "<b>Bold</b> <i").blocks == [.paragraph([Run("Bold", style: .bold), Run(" <i")])])
    }

    @Test func keepsTheLookOfPastedText() {
        let text = RichText(html: """
            <span style="font-weight: 700">B</span><span style="text-decoration: line-through">S</span>\
            <span style="font-family: Consolas, monospace">C</span><u>U</u>
            """)
        #expect(text.blocks == [.paragraph([
            Run("B", style: .bold), Run("S", style: .strikethrough), Run("C", style: .code), Run("U", style: .underline),
        ])])
    }
}

@Suite struct RichTextMarkdownTests {
    @Test func readsBlocks() {
        let text = RichText(markdown: """
            # Title

            A paragraph
            on two lines.

            - One
              - Nested
            - [x] Done
            1. First
            1. Second

            > Quoted

            ```
            let a = 1
            ```

            ---

            | Balance | Total |
            | --- | ---: |
            | $50 | $30 |

            ![Shot](https://example.test/shot.png)
            """)
        #expect(text.blocks == [
            .heading(level: 1, [Run("Title")]),
            .paragraph([Run("A paragraph\non two lines.")]),
            .listItem(.bullet, depth: 0, [Run("One")]),
            .listItem(.bullet, depth: 1, [Run("Nested")]),
            .listItem(.checkbox(checked: true), depth: 0, [Run("Done")]),
            .listItem(.number(1), depth: 0, [Run("First")]),
            .listItem(.number(2), depth: 0, [Run("Second")]),
            .quote([Run("Quoted")]),
            .code("let a = 1"),
            .rule,
            .table([[[Run("Balance", style: .bold)], [Run("Total", style: .bold)]], [[Run("$50")], [Run("$30")]]]),
            .image(alt: "Shot", url: URL(string: "https://example.test/shot.png")),
        ])
    }

    @Test func readsInlineFormatting() {
        let text = RichText(markdown: "**bold** *italic* `code` ~~gone~~ [a link](https://example.test) [not](javascript:x)")
        #expect(text.blocks == [.paragraph([
            Run("bold", style: .bold), Run(" "), Run("italic", style: .italic), Run(" "), Run("code", style: .code), Run(" "),
            Run("gone", style: .strikethrough), Run(" "), Run("a link", link: URL(string: "https://example.test")), Run(" not"),
        ])])
    }

    @Test func readsIndentedCodeWhateverItLooksLike() {
        #expect(RichText(markdown: "    # a comment\n    - not a list\n\n    > not a quote").blocks == [
            .code("# a comment\n- not a list\n\n> not a quote"),
        ])
        #expect(RichText(markdown: "Text\n\n    ```\n    code\n    ```\n\nAfter").blocks == [
            .paragraph([Run("Text")]), .code("```\ncode\n```"), .paragraph([Run("After")]),
        ])
        // Under a paragraph, it's more of it; in a list, a list in it.
        #expect(RichText(markdown: "Text\n    # more of it").blocks == [.paragraph([Run("Text\n# more of it")])])
        #expect(RichText(markdown: "- One\n    - Nested").blocks == [
            .listItem(.bullet, depth: 0, [Run("One")]), .listItem(.bullet, depth: 1, [Run("Nested")]),
        ])
    }

    @Test func keepsTabsInCode() {
        // A Makefile's recipe needs its tab.
        #expect(RichText(markdown: "```\nall:\n\tcc -o app main.c\n```").blocks == [.code("all:\n\tcc -o app main.c")])
        #expect(RichText(markdown: "\tcode\twith a tab").blocks == [.code("code\twith a tab")])
        #expect(RichText(markdown: "Run `a\tb` here").blocks == [.paragraph([Run("Run "), Run("a\tb", style: .code), Run(" here")])])
        // A tab still indents as four spaces: a list in a list.
        #expect(RichText(markdown: "- One\n\t- Nested").blocks == [
            .listItem(.bullet, depth: 0, [Run("One")]), .listItem(.bullet, depth: 1, [Run("Nested")]),
        ])
    }

    @Test func onlyAWholeFenceLineEndsCode() {
        #expect(RichText(markdown: "~~~\n~~~not-a-close\ncode\n~~~~\nAfter").blocks == [
            .code("~~~not-a-close\ncode"), .paragraph([Run("After")]),
        ])
        // A shorter fence doesn't end it either.
        #expect(RichText(markdown: "````\n```\n````").blocks == [.code("```")])
    }

    @Test func readsQuotesInQuotesToADepth() {
        #expect(RichText(markdown: "> One\n>> Two").blocks == [.quote([Run("One")]), .quote([Run("Two")])])
        // A line of thousands of them doesn't recurse as deep: past a few, they're text.
        let deep = RichText(markdown: String(repeating: ">", count: 20_000) + " Deep")
        #expect(deep.blocks.count == 1)
        #expect(deep.plainText.hasSuffix(" Deep"))
    }

    @Test func aSetextHeadingUnderlinesItsParagraph() {
        #expect(RichText(markdown: "Title\n=====\n\nSub\n---").blocks == [
            .heading(level: 1, [Run("Title")]), .heading(level: 2, [Run("Sub")]),
        ])
    }

    @Test func readsAsTheFieldsFormatSays() {
        #expect(RichText("**x**", format: "Markdown").blocks == [.paragraph([Run("x", style: .bold)])])
        #expect(RichText("**x**", format: "markdown").blocks == [.paragraph([Run("x", style: .bold)])])
        #expect(RichText("<b>x</b>", format: "html").blocks == [.paragraph([Run("x", style: .bold)])])
        #expect(RichText("<b>x</b>", format: nil).blocks == [.paragraph([Run("x", style: .bold)])])
    }
}
