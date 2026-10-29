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

    @Test func readsDeeplyNestedInlineElementsInLinearTime() {
        // Every piece of text, and every closing tag, would otherwise look through all the elements open.
        let html = String(repeating: "<span>x", count: 20_000) + String(repeating: "</b>", count: 20_000)
        var text = RichText()
        let elapsed = ContinuousClock().measure { text = RichText(html: html) }
        #expect(text.plainText == String(repeating: "x", count: 20_000))
        #expect(elapsed < .seconds(3))
        // Styles nest as written; deeper than they're followed, the text keeps the style around it, and closing tags still
        // close what they opened.
        let spans = RichText.htmlInlineDepth + 8
        let deep = "<b>" + String(repeating: "<span>", count: spans) + "<i>x</i>" + String(repeating: "</span>", count: spans)
            + "y</b>z"
        #expect(RichText(html: deep).blocks == [.paragraph([Run("xy", style: .bold), Run("z")])])
        #expect(RichText(html: "<b>" + String(repeating: "<span>", count: 10) + "<i>x</i></b>").blocks == [
            .paragraph([Run("x", style: [.bold, .italic])]),
        ])
        // A closing tag closes the deepest element of its name, even one deeper than that: not the bold around it all.
        let inner = "<b>" + String(repeating: "<span>", count: spans) + "<b>x</b>y" + String(repeating: "</span>", count: spans)
            + "</b>z"
        #expect(RichText(html: inner).blocks == [.paragraph([Run("xy", style: .bold), Run("z")])])
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
        // Nor does one indented four columns into what the block is in: that's code. Up to three, it ends it.
        #expect(RichText(markdown: "```\ncode\n    ```\nmore\n```").blocks == [.code("code\n    ```\nmore")])
        #expect(RichText(markdown: "```\ncode\n   ```\nAfter").blocks == [.code("code"), .paragraph([Run("After")])])
        // In a list's item, its fence and code are indented as its text.
        #expect(RichText(markdown: "- Run:\n  ```\n  make\n  ```\n- Then test").blocks == [
            .listItem(.bullet, depth: 0, [Run("Run:")]), .code("make"), .listItem(.bullet, depth: 0, [Run("Then test")]),
        ])
    }

    @Test func blocksInAListItemKeepTheList() {
        // Ordered lists written with "1." throughout count on past code in an item.
        #expect(RichText(markdown: "1. Build\n   ```\n   make\n   ```\n1. Test").blocks == [
            .listItem(.number(1), depth: 0, [Run("Build")]), .code("make"), .listItem(.number(2), depth: 0, [Run("Test")]),
        ])
        // Nested items stay nested past a quote, a heading, a table or a rule in one.
        let nested = "- a\n  - b\n    > quoted\n  - c\n    ### Title\n  - d\n    | x | y |\n    | - | - |\n    | 1 | 2 |\n  - e\n    ***\n  - f"
        #expect(RichText(markdown: nested).blocks == [
            .listItem(.bullet, depth: 0, [Run("a")]), .listItem(.bullet, depth: 1, [Run("b")]), .quote([Run("quoted")]),
            .listItem(.bullet, depth: 1, [Run("c")]), .heading(level: 3, [Run("Title")]),
            .listItem(.bullet, depth: 1, [Run("d")]), .table([[[Run("x", style: .bold)], [Run("y", style: .bold)]], [[Run("1")], [Run("2")]]]),
            .listItem(.bullet, depth: 1, [Run("e")]), .rule, .listItem(.bullet, depth: 1, [Run("f")]),
        ])
        // A block that isn't indented into the list ends it: its numbers start over.
        #expect(RichText(markdown: "1. One\n# Title\n1. Two").blocks == [
            .listItem(.number(1), depth: 0, [Run("One")]), .heading(level: 1, [Run("Title")]), .listItem(.number(1), depth: 0, [Run("Two")]),
        ])
        // A paragraph in an outer item, after a blank line, ends the list in that item, and the next one starts over.
        #expect(RichText(markdown: "1. a\n   1. b\n   1. c\n\n   More of a.\n   1. d").blocks == [
            .listItem(.number(1), depth: 0, [Run("a")]), .listItem(.number(1), depth: 1, [Run("b")]),
            .listItem(.number(2), depth: 1, [Run("c")]), .paragraph([Run("More of a.")]), .listItem(.number(1), depth: 1, [Run("d")]),
        ])
        // A list in the next item counts from its own first number.
        #expect(RichText(markdown: "1. a\n   1. b\n   2. c\n2. d\n   5. e").blocks == [
            .listItem(.number(1), depth: 0, [Run("a")]), .listItem(.number(1), depth: 1, [Run("b")]),
            .listItem(.number(2), depth: 1, [Run("c")]), .listItem(.number(2), depth: 0, [Run("d")]),
            .listItem(.number(5), depth: 1, [Run("e")]),
        ])
        // An item less indented than the list it's in, but more than the one around it, is that list's next one, as
        // CommonMark has it.
        #expect(RichText(markdown: "1. a\n    3. b\n   7. c").blocks == [
            .listItem(.number(1), depth: 0, [Run("a")]), .listItem(.number(3), depth: 1, [Run("b")]), .listItem(.number(4), depth: 1, [Run("c")]),
        ])
        #expect(RichText(markdown: "  1. a\n1. b").blocks == [
            .listItem(.number(1), depth: 0, [Run("a")]), .listItem(.number(2), depth: 0, [Run("b")]),
        ])
        // A fence the list's items aren't indented into ends the list, and is the page's: its closing fence is indented
        // three columns at most.
        #expect(RichText(markdown: "  1. a\n  ```\n  code\n     ```\n  ```").blocks == [
            .listItem(.number(1), depth: 0, [Run("a")]), .code("code\n   ```"),
        ])
        // An image on its own, as a paragraph: in the item it's indented into, and after the list it isn't.
        let image = RichText.Block.image(alt: "Diagram", url: URL(string: "https://example.com/d.png"))
        #expect(RichText(markdown: "1. One\n\n   ![Diagram](https://example.com/d.png)\n\n1. Two").blocks == [
            .listItem(.number(1), depth: 0, [Run("One")]), image, .listItem(.number(2), depth: 0, [Run("Two")]),
        ])
        #expect(RichText(markdown: "1. One\n\n![Diagram](https://example.com/d.png)\n\n1. Two").blocks == [
            .listItem(.number(1), depth: 0, [Run("One")]), image, .listItem(.number(1), depth: 0, [Run("Two")]),
        ])
    }

    @Test func linesLessIndentedThanAnItemsTextAreOutsideIt() {
        // An item's text starts after its marker and the spaces after it: three columns into "1. One". A block between
        // the marker and the text isn't in the item, and ends the list, so the next one counts from its own first number.
        #expect(RichText(markdown: "1. One\n # Title\n1. Two").blocks == [
            .listItem(.number(1), depth: 0, [Run("One")]), .heading(level: 1, [Run("Title")]), .listItem(.number(1), depth: 0, [Run("Two")]),
        ])
        #expect(RichText(markdown: "1. One\n  > Quoted\n1. Two").blocks == [
            .listItem(.number(1), depth: 0, [Run("One")]), .quote([Run("Quoted")]), .listItem(.number(1), depth: 0, [Run("Two")]),
        ])
        #expect(RichText(markdown: "1. One\n  ```\n  code\n  ```\n1. Two").blocks == [
            .listItem(.number(1), depth: 0, [Run("One")]), .code("code"), .listItem(.number(1), depth: 0, [Run("Two")]),
        ])
        #expect(RichText(markdown: "1. One\n  | H |\n  | - |\n  | 1 |\n1. Two").blocks == [
            .listItem(.number(1), depth: 0, [Run("One")]), .table([[[Run("H", style: .bold)]], [[Run("1")]]]),
            .listItem(.number(1), depth: 0, [Run("Two")]),
        ])
        // An item there is the list's next one, not one in the item.
        #expect(RichText(markdown: "1. One\n  1. Two\n- a\n - b").blocks == [
            .listItem(.number(1), depth: 0, [Run("One")]), .listItem(.number(2), depth: 0, [Run("Two")]),
            .listItem(.bullet, depth: 0, [Run("a")]), .listItem(.bullet, depth: 0, [Run("b")]),
        ])
        // Where the text starts counts the spaces after the marker, but one when the text is indented as code.
        #expect(RichText(markdown: "1.  Two spaces\n    - In it").blocks == [
            .listItem(.number(1), depth: 0, [Run("Two spaces")]), .listItem(.bullet, depth: 1, [Run("In it")]),
        ])
        #expect(RichText(markdown: "1.  Two spaces\n   - Not in it").blocks == [
            .listItem(.number(1), depth: 0, [Run("Two spaces")]), .listItem(.bullet, depth: 0, [Run("Not in it")]),
        ])
        #expect(RichText(markdown: "-      Far\n  - In it").blocks == [
            .listItem(.bullet, depth: 0, [Run("Far")]), .listItem(.bullet, depth: 1, [Run("In it")]),
        ])
        // A quote's, a table's or code's line that leaves the item ends them, and the list.
        #expect(RichText(markdown: "1. A\n   > inside\n> outside\n1. B").blocks == [
            .listItem(.number(1), depth: 0, [Run("A")]), .quote([Run("inside")]), .quote([Run("outside")]),
            .listItem(.number(1), depth: 0, [Run("B")]),
        ])
        #expect(RichText(markdown: "1. First\n   | H |\n   | - |\n| Outside |\n1. Second").blocks == [
            .listItem(.number(1), depth: 0, [Run("First")]), .table([[[Run("H", style: .bold)]]]), .paragraph([Run("| Outside |")]),
            .listItem(.number(1), depth: 0, [Run("Second")]),
        ])
        #expect(RichText(markdown: "1. a\n   ```\n   code\nOutside\n1. b").blocks == [
            .listItem(.number(1), depth: 0, [Run("a")]), .code("code"), .paragraph([Run("Outside")]),
            .listItem(.number(1), depth: 0, [Run("b")]),
        ])
        // A fence indented further into the item is closed up to three columns into the item's text, not the fence's.
        #expect(RichText(markdown: "- a\n    ```\n    x\n       ```\n    ```").blocks == [
            .listItem(.bullet, depth: 0, [Run("a")]), .code("x\n   ```"),
        ])
        // So does an underline: "---" there is a rule, which ends the list, and "===" more of the paragraph. In the item,
        // it makes the paragraph a heading.
        #expect(RichText(markdown: "1. One\n\n   Para\n---\n1. Two").blocks == [
            .listItem(.number(1), depth: 0, [Run("One")]), .paragraph([Run("Para")]), .rule, .listItem(.number(1), depth: 0, [Run("Two")]),
        ])
        #expect(RichText(markdown: "1. One\n\n   Para\n===\n1. Two").blocks == [
            .listItem(.number(1), depth: 0, [Run("One")]), .paragraph([Run("Para\n===")]), .listItem(.number(2), depth: 0, [Run("Two")]),
        ])
        #expect(RichText(markdown: "1. One\n\n   Para\n   ---\n1. Two").blocks == [
            .listItem(.number(1), depth: 0, [Run("One")]), .heading(level: 2, [Run("Para")]), .listItem(.number(2), depth: 0, [Run("Two")]),
        ])
        // A table whose separator is outside the item isn't one: its lines go on with the item's text.
        #expect(RichText(markdown: "1. a\n   | H |\n| - |").blocks == [.listItem(.number(1), depth: 0, [Run("a\n| H |\n| - |")])])
        // After a block, a paragraph is in the item when it's indented into it. A line that goes on with a paragraph, or
        // an image on such a line, is in what the paragraph is in, however it's indented.
        #expect(RichText(markdown: "1. a\n   # H\n   Text\nmore\n1. b").blocks == [
            .listItem(.number(1), depth: 0, [Run("a")]), .heading(level: 1, [Run("H")]), .paragraph([Run("Text\nmore")]),
            .listItem(.number(2), depth: 0, [Run("b")]),
        ])
        #expect(RichText(markdown: "1. a\n   # H\nText\n1. b").blocks == [
            .listItem(.number(1), depth: 0, [Run("a")]), .heading(level: 1, [Run("H")]), .paragraph([Run("Text")]),
            .listItem(.number(1), depth: 0, [Run("b")]),
        ])
        #expect(RichText(markdown: "1. One\n![Diagram](https://example.com/d.png)\n1. Two").blocks == [
            .listItem(.number(1), depth: 0, [Run("One")]), .image(alt: "Diagram", url: URL(string: "https://example.com/d.png")),
            .listItem(.number(2), depth: 0, [Run("Two")]),
        ])
    }

    @Test func anImageDoesntEndTheParagraphItsIn() {
        // An image on a line of its own shows as a block, but what follows it without a blank line, text or another image,
        // is still the paragraph's, here the item's text: the list goes on.
        let a = RichText.Block.image(alt: "A", url: URL(string: "https://example.test/a.png"))
        let b = RichText.Block.image(alt: "B", url: URL(string: "https://example.test/b.png"))
        #expect(RichText(markdown: "1. One\n![A](https://example.test/a.png)\ncontinued\n1. Two").blocks == [
            .listItem(.number(1), depth: 0, [Run("One")]), a, .paragraph([Run("continued")]), .listItem(.number(2), depth: 0, [Run("Two")]),
        ])
        #expect(RichText(markdown: "1. One\n![A](https://example.test/a.png)\n![B](https://example.test/b.png)\n1. Two").blocks == [
            .listItem(.number(1), depth: 0, [Run("One")]), a, b, .listItem(.number(2), depth: 0, [Run("Two")]),
        ])
        // Indented four columns, it's more of the paragraph, not code.
        #expect(RichText(markdown: "Text\n![A](https://example.test/a.png)\n    more").blocks == [
            .paragraph([Run("Text")]), a, .paragraph([Run("more")]),
        ])
        // A blank line still ends it.
        #expect(RichText(markdown: "1. One\n![A](https://example.test/a.png)\n\ncontinued\n1. Two").blocks == [
            .listItem(.number(1), depth: 0, [Run("One")]), a, .paragraph([Run("continued")]), .listItem(.number(1), depth: 0, [Run("Two")]),
        ])
        // A backslash that ends the line before the image breaks the line, which the image takes; an escaped one is a
        // backslash.
        #expect(RichText(markdown: "First\\\n![A](https://example.test/a.png)").blocks == [.paragraph([Run("First")]), a])
        #expect(RichText(markdown: "Path \\\\\n![A](https://example.test/a.png)").blocks == [.paragraph([Run("Path \\")]), a])
        #expect(RichText(markdown: "1. Step\\\n![A](https://example.test/a.png)\n1. Next").blocks == [
            .listItem(.number(1), depth: 0, [Run("Step")]), a, .listItem(.number(2), depth: 0, [Run("Next")]),
        ])
    }

    @Test func codeIsIndentedFourColumnsIntoWhatItsIn() {
        // Four columns into an item's text, a line is code in the item, whatever it looks like; the list goes on after it.
        #expect(RichText(markdown: "1. A\n   # Notes\n\n       # literal\n1. B").blocks == [
            .listItem(.number(1), depth: 0, [Run("A")]), .heading(level: 1, [Run("Notes")]), .code("# literal"),
            .listItem(.number(2), depth: 0, [Run("B")]),
        ])
        #expect(RichText(markdown: "- a\n\n      code\n      - not a list\n- b").blocks == [
            .listItem(.bullet, depth: 0, [Run("a")]), .code("code\n- not a list"), .listItem(.bullet, depth: 0, [Run("b")]),
        ])
        // Less indented than the item's text but four columns into the page, it's code on the page, after the list.
        #expect(RichText(markdown: "1234. A\n      # Heading\n\n    # literal\n1. B").blocks == [
            .listItem(.number(1234), depth: 0, [Run("A")]), .heading(level: 1, [Run("Heading")]), .code("# literal"),
            .listItem(.number(1), depth: 0, [Run("B")]),
        ])
        // Under the item's text, it's more of it, as on the page.
        #expect(RichText(markdown: "- a\n      - b").blocks == [.listItem(.bullet, depth: 0, [Run("a\n- b")])])
    }

    @Test func keepsBackslashesThatArentLineBreaks() {
        // Nothing follows it to break: it's the path's.
        #expect(RichText(markdown: #"Folder: C:\"#).plainText == #"Folder: C:\"#)
        #expect(RichText(markdown: "- Copy it to D:\\").plainText == "• Copy it to D:\\")
        #expect(RichText(markdown: "> Saved in C:\\").plainText == "Saved in C:\\")
        // An escaped backslash at the end of a line is one backslash, and the line still ends there.
        #expect(RichText(markdown: "Path \\\\\nnext").plainText == "Path \\\nnext")
        #expect(RichText(markdown: "# Saved in C:\\").plainText == "Saved in C:\\")
        #expect(RichText(markdown: "Saved in C:\\\n===").plainText == "Saved in C:\\")
        #expect(RichText(markdown: "| Path |\n| - |\n| C:\\ |").blocks == [.table([[[Run("Path", style: .bold)]], [[Run("C:\\")]]])])
        // A backslash then spaces is a backslash.
        #expect(RichText(markdown: "C:\\ \nnext").plainText == "C:\\\nnext")
        #expect(RichText(markdown: "> C:\\ \n> next").plainText == "C:\\\nnext")
        // A backslash that ends a line that goes on breaks it, as Markdown says, and goes.
        #expect(RichText(markdown: "First\\\nSecond").plainText == "First\nSecond")
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
