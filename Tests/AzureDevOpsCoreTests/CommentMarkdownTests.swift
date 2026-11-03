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
        // One that ends on the line it starts makes the block that line: one after it there that doesn't end on it hides
        // the rest, as HTML reads it.
        #expect(plain("<!-- one --><!-- two --> <!-- three\n--> Hidden") == "")
        // One that ends on the line it starts is a block of its own: what follows it is what it would be after any other.
        #expect(RichText(markdown: "<!-- bot -->\n    <!-- literal code -->").blocks == [.code("<!-- literal code -->")])
        // What follows one's end on its line is the HTML block's: it shows as written, not read as Markdown, on the page,
        // in a list's item, whose next line is a paragraph of its own, and in a quote; and HTML in it is still HTML.
        #expect(RichText(markdown: "<!-- bot --> # Title").blocks == [.paragraph([RichText.Run("# Title")])])
        #expect(RichText(markdown: "- <!-- bot --> **literal**\n  more").blocks == [
            .listItem(.bullet, depth: 0, [RichText.Run("**literal**")]), .paragraph([RichText.Run("more")]),
        ])
        #expect(plain("- <!-- x --> a\\ \n  more") == "• a\\\nmore")
        #expect(RichText(markdown: "> <!-- bot --> _quoted_").blocks == [.quote([RichText.Run("_quoted_")])])
        #expect(plain("<!-- bot --> <b>bold</b>, `code` and a\\b") == "bold, `code` and a\\b")
        #expect(plain("<!-- bot --> shown <!-- unended\n\nhidden") == "shown")
        // What follows one's end shows in the list's item it's in, which goes on, counting on.
        let numbered = RichText(markdown: "1. one\n   <!--\n   x\n   --> after\n1. two")
        #expect(numbered.plainText == "1. one\nafter\n2. two")
        #expect(numbered.blocks.last == .listItem(.number(2), depth: 0, [RichText.Run("two")]))
        // In a list's item, starting it too, and in a quote.
        #expect(plain("- one\n\n  <!--\n  hidden\n\n  -->\n- two") == "• one\n• two")
        #expect(plain("- <!--\n  hidden\n\n  more\n  -->\n- shown") == "• shown")
        #expect(plain("- <!--\n  hidden\n  --> kept\n- shown") == "• kept\n• shown")
        // An item that's only a comment has no paragraph for indented code after it to go on with.
        #expect(RichText(markdown: "- <!--\n  hidden\n  -->\n      <!-- literal code -->").blocks == [.code("<!-- literal code -->")])
        // An item whose text is indented as code starts with no comment, and what follows it shows.
        #expect(plain("-     <!--\n      literal code\n\nOutside") == "• <!--\nliteral code\nOutside")
        // Nor one whose comments end on its line, whose text is what follows them, or the paragraph after.
        #expect(RichText(markdown: "- <!-- bot -->\n      <!-- literal code -->").blocks == [.code("<!-- literal code -->")])
        #expect(plain("- <!-- one --> <!-- two --> kept\n- <!-- bot -->\n  more\n- shown") == "• kept\n• more\n• shown")
        // Only an item's first comment goes on past its line: one after it there that doesn't end on it hides the rest.
        #expect(plain("- <!-- one --> <!-- two\n  --> Hidden\n\nAfter") == "")
        #expect(plain("- <!--\n  one\n  --> <!-- two\n  --> Hidden\n\nAfter") == "")
        #expect(plain("- <!-- one --> <!-- two -->\n  more") == "• more")
        #expect(plain("> <!--\n> hidden\n>\n> -->\n> shown") == "shown")
        // One in a quote that doesn't end there hides the rest, past the quote too: text's "-->" doesn't end it, since
        // Azure DevOps writes its ">" as "&gt;".
        #expect(plain("> <!--\n> hidden\n\nAlso hidden") == "")
        #expect(plain("> Shown\n> <!--\nhidden\n-->\nAfter") == "Shown")
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
        // A block starts on a line of its own as it ends on one, and blocks one after another, or one in another, break
        // the line once.
        #expect(plain("Before<div>Inside</div>After") == "Before\nInside\nAfter")
        #expect(plain("<div><p>One</p></div> <div><p>Two</p></div>") == "One\nTwo")
        #expect(plain("Line<br><div>Block</div>") == "Line\nBlock")
        #expect(plain("Before\n<div>Inside</div>") == "Before\nInside")
        #expect(plain("`code`<div>Block</div>") == "code\nBlock")
        #expect(plain("<table><tr><th>File</th><th>Issues</th></tr><tr><td>a.cs</td><td>2</td></tr></table>") == "File | Issues\na.cs | 2")
        #expect(plain("Files: <table><tr><th>File</th><th>Issues</th></tr><tr><td>a.cs</td><td>2</td></tr></table>")
            == "Files:\nFile Issues\na.cs 2")
    }

    /// HTML that starts a line starts an HTML block, as CommonMark has them, which Azure DevOps passes on as it is, for
    /// HTML to show: BriefBar shows it as it shows HTML, Markdown in it as it's written.
    @Test func showsHTMLBlocksAsHTML() {
        #expect(RichText(markdown: "<div>**literal**</div>").blocks == [.paragraph([RichText.Run("**literal**")])])
        #expect(RichText(markdown: "<div>\n*not emphasis*\n  - nor a list\n</div>").blocks == [
            .paragraph([RichText.Run("*not emphasis* - nor a list")]),
        ])
        #expect(RichText(markdown: "<p>A <b>bold</b> word</p>").blocks == [
            .paragraph([RichText.Run("A "), RichText.Run("bold", style: .bold), RichText.Run(" word")]),
        ])
        // To a blank line, after which Markdown is Markdown again.
        #expect(RichText(markdown: "<div>\n\n**bold**\n\n</div>").blocks == [.paragraph([RichText.Run("bold", style: .bold)])])
        // One of the elements that start blocks ends a paragraph; another tag alone on its line doesn't, but starts a
        // block where no paragraph goes on.
        #expect(RichText(markdown: "Text\n<div>**x**</div>").blocks == [.paragraph([RichText.Run("Text")]), .paragraph([RichText.Run("**x**")])])
        #expect(RichText(markdown: "Text\n<abbr>\n**more**").blocks.contains(.paragraph([
            RichText.Run("Text\n\n"), RichText.Run("more", style: .bold),
        ])))
        #expect(RichText(markdown: "<abbr>\n**more**").blocks == [.paragraph([RichText.Run("**more**")])])
        // Those whose text HTML shows as it is, to their end tag, blank lines and all, with scripts and styles left out;
        // and declarations, instructions and CDATA, to their ends.
        #expect(RichText(markdown: "<pre>\n**kept**\n\n  as is\n</pre>\nAfter **it**").blocks == [
            .code("**kept**\n\n  as is"), .paragraph([RichText.Run("After "), RichText.Run("it", style: .bold)]),
        ])
        #expect(plain("<script>\nalert('**x**')\n\n</script>\n<style>\np { color: red }\n</style>\nShown") == "Shown")
        #expect(plain("<!DOCTYPE html>\n<?xml version=\"1.0\"\n?>\n<![CDATA[\nx\n]]>\nShown") == "Shown")
        // In a list's item, starting it or in it, and in a quote, as on the page.
        #expect(RichText(markdown: "- <div>**literal**</div>\n- **bold**").blocks == [
            .listItem(.bullet, depth: 0, [RichText.Run("**literal**")]), .listItem(.bullet, depth: 0, [RichText.Run("bold", style: .bold)]),
        ])
        #expect(RichText(markdown: "- one\n\n  <div>**literal**\n  </div>\n- two").blocks == [
            .listItem(.bullet, depth: 0, [RichText.Run("one")]), .paragraph([RichText.Run("**literal**")]),
            .listItem(.bullet, depth: 0, [RichText.Run("two")]),
        ])
        #expect(RichText(markdown: "> <div>**literal**</div>").blocks == [.quote([RichText.Run("**literal**")])])
        // A table as a table, and an image on a line of its own as an image.
        #expect(RichText(markdown: "<table>\n<tr><td>a.cs</td><td>2</td></tr>\n</table>").plainText == "a.cs | 2")
        #expect(RichText(markdown: "<img src=\"https://example.invalid/badge.png\" alt=\"Quality gate: passed\">").blocks == [
            .image(alt: "Quality gate: passed", url: URL(string: "https://example.invalid/badge.png")),
        ])
        // Indented as code, it's code.
        #expect(RichText(markdown: "    <div>**x**</div>").blocks == [.code("<div>**x**</div>")])
        // A comment in one that doesn't end there hides the rest.
        #expect(plain("<div>Shown <!-- hidden\n\nAfter") == "Shown")
    }

    @Test func formattingTagsKeepTheirText() {
        #expect(plain("Use <b>bold</b>, <i>italics</i>, <sub>small</sub> and <span style=\"color:red\">red</span>.")
            == "Use bold, italics, small and red.")
        #expect(plain("<a href=\"https://example.invalid/rules\">The rule</a> says so") == "The rule says so")
        // What's in an attribute's quotes is the tag's, a bracket or backticks included.
        #expect(plain("<span title=\"a > b\">shown</span>") == "shown")
        #expect(plain("<span title=\"<!--\">Shown</span><!-- bot marker --> after") == "Shown after")
        #expect(plain("<span title=\"use `x`\">Shown</span> and `<b>`") == "Shown and <b>")
        #expect(RichText(markdown: "See <img src=\"https://example.invalid/badge.svg\" alt=\"A > B\">").blocks == [
            .paragraph([RichText.Run("See "), RichText.Run("A > B", link: URL(string: "https://example.invalid/badge.svg"))]),
        ])
    }

    @Test func keepsFormattingThatHTMLKeptApartApart() {
        #expect(RichText(markdown: "**one**<b></b>**two**, ~~old~~<!-- x -->~~older~~ and *a*<img src=x>*b*").blocks == [
            .paragraph([
                RichText.Run("onetwo", style: .bold), RichText.Run(", "), RichText.Run("oldolder", style: .strikethrough),
                RichText.Run(" and "), RichText.Run("ab", style: .italic),
            ]),
        ])
        // What isn't two runs of a mark goes on as if the HTML had never been there.
        #expect(RichText(markdown: "**bold**<b></b>text, `a`<i>x</i>`b`").blocks == [
            .paragraph([
                RichText.Run("bold", style: .bold), RichText.Run("text, "), RichText.Run("a", style: .code), RichText.Run("x"),
                RichText.Run("b", style: .code),
            ]),
        ])
        // Nor are a link's text and where it goes, an image's too, or an image's `!` and its description: what's left is text,
        // with its web address a link of its own.
        let build = URL(string: "https://example.invalid/build")
        #expect(RichText(markdown: "[build]<!-- bot -->(https://example.invalid/build)").blocks == [
            .paragraph([RichText.Run("[build]("), RichText.Run("https://example.invalid/build", link: build), RichText.Run(")")]),
        ])
        let chart = URL(string: "https://example.invalid/chart.png")
        #expect(RichText(markdown: "![chart]<!-- bot -->(https://example.invalid/chart.png)").blocks == [
            .paragraph([RichText.Run("![chart]("), RichText.Run("https://example.invalid/chart.png", link: chart), RichText.Run(")")]),
        ])
        #expect(RichText(markdown: "!<b></b>[chart](https://example.invalid/chart)").blocks == [
            .paragraph([RichText.Run("!"), RichText.Run("chart", link: URL(string: "https://example.invalid/chart"))]),
        ])
    }

    /// In text: an image on a line of its own is an HTML block (`showsHTMLBlocksAsHTML`).
    @Test func readsImagesInHTMLAsImages() {
        let badge = URL(string: "https://example.invalid/badge.png")
        #expect(RichText(markdown: "Gate: <img src=\"https://example.invalid/badge.png\" alt=\"Quality gate: passed\">").blocks == [
            .paragraph([RichText.Run("Gate: "), RichText.Run("Quality gate: passed", link: badge)]),
        ])
        // Its description as it's written, which isn't Markdown, but for its character references.
        #expect(RichText(markdown: "Build: <img src=\"https://example.invalid/b.png\" alt=\"Build [Linux] **failed** &amp; _x_\">").blocks == [
            .paragraph([RichText.Run("Build: "), RichText.Run("Build [Linux] **failed** & _x_", link: URL(string: "https://example.invalid/b.png"))]),
        ])
        // And its source, read once.
        #expect(RichText(markdown: "Badge: <img src=\"https&#58;//example.invalid/b.svg?style=flat&amp;label=a%20b\" alt=\"Badge\">").blocks == [
            .paragraph([RichText.Run("Badge: "), RichText.Run("Badge", link: URL(string: "https://example.invalid/b.svg?style=flat&label=a%20b"))]),
        ])
        #expect(RichText(markdown: "Badge: <img src=\"https://example.invalid/b.svg?q=&amp;lt;\" alt=\"Badge\">").blocks == [
            .paragraph([RichText.Run("Badge: "), RichText.Run("Badge", link: URL(string: "https://example.invalid/b.svg?q=&lt;"))]),
        ])
        // Only of a web page, and otherwise its description.
        #expect(RichText(markdown: "See <img src='javascript:alert(1)' alt='Badge'>").blocks == [.paragraph([RichText.Run("See Badge")])])
        #expect(plain("See <img src='javascript:alert(1)' alt='Build [Linux] *1*'>") == "See Build [Linux] *1*")
        #expect(plain("Before<img src=data:image/png;base64,AAAA> after") == "Before after")
        // A tag its description mentions is text, as the rest of it is.
        #expect(RichText(markdown: "See <img src=\"https://example.invalid/b.png\" alt=\"Use &lt;br /&gt; here\">").blocks == [
            .paragraph([RichText.Run("See "), RichText.Run("Use <br /> here", link: URL(string: "https://example.invalid/b.png"))]),
        ])
        #expect(plain("See <img alt='Use &lt;span class=\"x\"&gt; here'>") == "See Use <span class=\"x\"> here")
        // Its own source and description, whatever another attribute's quoted value says.
        #expect(RichText(markdown: "See <img src=\"https://example.invalid/real.png\" alt=\"Real\" "
            + "data-v2=\" src='https://example.invalid/other.svg' alt='Other'\">").blocks == [
            .paragraph([RichText.Run("See "), RichText.Run("Real", link: URL(string: "https://example.invalid/real.png"))]),
        ])
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
        // Code spans that HTML kept apart stay apart without it.
        #expect(RichText(markdown: "`a`<!-- hidden -->`b` and `c`<b></b>`d`").blocks == [
            .paragraph([RichText.Run("ab", style: .code), RichText.Run(" and "), RichText.Run("cd", style: .code)]),
        ])
        // A comment without an end is text, and code after it is still code.
        #expect(RichText(markdown: "An unended <!-- and `<br>` in code").blocks == [
            .paragraph([RichText.Run("An unended <!-- and "), RichText.Run("<br>", style: .code), RichText.Run(" in code")]),
        ])
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

    /// Each in a fraction of a second, where reading them in quadratic time would take far longer than the limit: kept
    /// small, since every test runs on one thread in `make test`.
    @Test func readsAManyTaggedCommentInLinearTime() {
        for long in [
            String(repeating: "<b>x</b> `y` <!-- z --> <a ", count: 1_000),
            "<img " + String(repeating: "a", count: 25_000) + ">",
            "<img src=" + String(repeating: "a-b ", count: 6_000) + ">",
            String(repeating: "<!-- `", count: 10_000),
            String(repeating: "<span title=\"`x` > ", count: 2_000),
            "<span title=\"" + String(repeating: "<a b ", count: 6_000),
            String(repeating: "<!-- -->", count: 10_000),
            String(repeating: "<!-- `x` ", count: 10_000),
            String(repeating: "<a title=\"<!--\"> ", count: 3_000),
            String(repeating: "<!-- --> ", count: 5_000) + "<!--\n-->\nShown",
            "<div>" + String(repeating: "<b></b>", count: 3_000) + String(repeating: "<p></p>", count: 3_000),
            String(repeating: "> <!--\nx\n-->\n", count: 3_000),
            "- " + String(repeating: "<!-- a --> ", count: 6_000) + "text",
        ] {
            let start = ContinuousClock.now
            _ = RichText(markdown: long)
            #expect(ContinuousClock.now - start < .seconds(10))
        }
    }
}
