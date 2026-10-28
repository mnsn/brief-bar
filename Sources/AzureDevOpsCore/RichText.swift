import Foundation

/// Formatted text from Azure DevOps, such as a work item's description or a comment, as blocks of styled runs that
/// BriefBar draws itself. There's no web view, so nothing the text links to or embeds is loaded: an image is a link to
/// open in the browser. Azure DevOps keeps such text as HTML, or as Markdown in the fields switched to it.
public struct RichText: Sendable, Equatable {
    public struct Style: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let bold = Style(rawValue: 1 << 0)
        public static let italic = Style(rawValue: 1 << 1)
        public static let underline = Style(rawValue: 1 << 2)
        public static let strikethrough = Style(rawValue: 1 << 3)
        public static let code = Style(rawValue: 1 << 4)
    }

    /// Text in one style, which may link to a web page.
    public struct Run: Sendable, Equatable {
        public var text: String
        public var style: Style
        public var link: URL?

        public init(_ text: String, style: Style = [], link: URL? = nil) {
            self.text = text
            self.style = style
            self.link = link
        }
    }

    public enum ListMarker: Sendable, Equatable {
        case bullet
        case number(Int)
        case checkbox(checked: Bool)
    }

    public enum Block: Sendable, Equatable {
        /// Lines of text: a "\n" starts a new line, and two leave an empty one between.
        case paragraph([Run])
        case heading(level: Int, [Run])
        /// `depth` is 0 for an item of a list, 1 for an item of a list in it, and so on.
        case listItem(ListMarker, depth: Int, [Run])
        case quote([Run])
        case code(String)
        /// Rows of cells.
        case table([[[Run]]])
        /// An image, which isn't loaded: what it shows, and where it is.
        case image(alt: String, url: URL?)
        case rule
    }

    public var blocks: [Block]

    public init(blocks: [Block] = []) {
        self.blocks = blocks
    }

    /// From a long text field or a comment: as Markdown when `format` says so (`Markdown`, as Azure DevOps says it in a
    /// work item's `multilineFieldsFormat`, or a comment's `markdown`), and as HTML otherwise.
    public init(_ text: String, format: String?) {
        if format?.lowercased() == "markdown" {
            self.init(markdown: text)
        } else {
            self.init(html: text)
        }
    }

    /// From HTML, as Azure DevOps' editors write it and as it renders Markdown. Unknown tags keep their text; scripts,
    /// styles and the like are left out.
    public init(html: String) {
        var reader = HTMLReader()
        reader.read(html)
        self.init(blocks: reader.finish())
    }

    /// From Markdown: the blocks work items use (headings, lists and task lists, quotes, code, tables and rules), and
    /// inline formatting, links and images.
    public init(markdown: String) {
        self.init(blocks: MarkdownReader.read(markdown))
    }

    public var isEmpty: Bool { blocks.isEmpty }

    /// How deep HTML's inline elements' styles are followed. Text nests a few; deeper, it takes the style around it, so
    /// that every piece of text, and every closing tag, looks at a few elements at most.
    static let htmlInlineDepth = 32

    /// The text without its formatting, a line for each block: for VoiceOver, copying and tests.
    public var plainText: String {
        blocks.map { block in
            switch block {
            case .paragraph(let runs), .heading(_, let runs), .quote(let runs):
                return Self.text(of: runs)
            case .listItem(let marker, let depth, let runs):
                let prefix: String
                switch marker {
                case .bullet: prefix = "•"
                case .number(let number): prefix = "\(number)."
                case .checkbox(let checked): prefix = checked ? "[x]" : "[ ]"
                }
                return String(repeating: "  ", count: depth) + prefix + " " + Self.text(of: runs)
            case .code(let code):
                return code
            case .table(let rows):
                return rows.map { $0.map(Self.text(of:)).joined(separator: " | ") }.joined(separator: "\n")
            case .image(let alt, _):
                return alt
            case .rule:
                return "—"
            }
        }
        .joined(separator: "\n")
    }

    static func text(of runs: [Run]) -> String {
        runs.map(\.text).joined()
    }

    /// A link that opens a web page or writes an email; anything else isn't a link, such as `javascript:` or `#`.
    static func webLink(_ text: String?) -> URL? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme)
        else { return nil }
        return url
    }

    static func webLink(_ url: URL?) -> URL? {
        webLink(url?.absoluteString)
    }

    /// Runs as they show: no spaces at the ends of lines or before the first word, no empty lines before or after the
    /// text, and at most one in a row. No-break spaces at the start of a line stay: they indent it.
    static func normalized(_ runs: [Run]) -> [Run] {
        var result: [Run] = []
        func emit(_ character: Character, style: Style, link: URL?) {
            if let last = result.last, last.style == style, last.link == link {
                result[result.count - 1].text.append(character)
            } else {
                result.append(Run(String(character), style: style, link: link))
            }
        }
        var spaces: [(Character, Run)] = []
        var breaks = 0
        var atLineStart = true
        var hasText = false
        for run in runs {
            for character in run.text {
                if character == "\n" || character == "\r\n" || character == "\r" {
                    spaces.removeAll()
                    if hasText { breaks += 1 }
                    atLineStart = true
                } else if character.isWhitespace {
                    spaces.append((character, run))
                } else {
                    if breaks > 0 {
                        // Unstyled, so no line's background or underline runs on past its end.
                        for _ in 0..<min(breaks, 2) { emit("\n", style: [], link: nil) }
                        breaks = 0
                    }
                    for (space, spaceRun) in spaces where !atLineStart || space == "\u{00A0}" {
                        emit(space, style: spaceRun.style, link: spaceRun.link)
                    }
                    spaces.removeAll()
                    emit(character, style: run.style, link: run.link)
                    hasText = true
                    atLineStart = false
                }
            }
        }
        return result
    }

    /// The name an image's address gives it: an attachment's `fileName`, or the last part of its path.
    static func fileName(of url: URL?) -> String? {
        guard let url else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let name = query.first(where: { $0.name.lowercased() == "filename" })?.value, !name.isEmpty { return name }
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? nil : last
    }
}

// MARK: - HTML

/// Reads HTML into blocks. Block elements start blocks; `div`s and the like, which Azure DevOps' editor writes for each
/// line, start lines; inline elements style their text.
private struct HTMLReader {
    private enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case listItem(RichText.ListMarker, depth: Int)
    }

    private struct Inline {
        var name: String
        var style: RichText.Style
        var link: URL?
    }

    private var blocks: [RichText.Block] = []
    private var runs: [RichText.Run] = []
    private var kind = Kind.paragraph
    /// The inline elements open, whose styles and links the text takes.
    private var inline: [Inline] = []
    /// Inline elements opened deeper than `RichText.htmlInlineDepth`, by name: their closing tags close them before any of
    /// `inline`.
    private var untracked: [String: Int] = [:]
    private var lists: [(ordered: Bool, next: Int)] = []
    private var listItems = 0
    private var quotes = 0
    /// Inside `pre`: its text as it is.
    private var preDepth = 0
    private var code = ""
    /// The element whose content is left out, such as `script`.
    private var skipped: String?
    /// Tables, with the outermost one's rows; one inside a cell is read as lines.
    private var tables = 0
    private var rows: [[[RichText.Run]]] = []
    private var row: [[RichText.Run]] = []
    private var inCell = false

    private static let voids: Set<String> = [
        "br", "hr", "img", "input", "meta", "link", "wbr", "col", "area", "base", "embed", "source", "track", "param",
    ]
    private static let skippedElements: Set<String> = [
        "script", "style", "head", "title", "noscript", "template", "svg", "math", "object", "iframe", "select", "textarea",
    ]
    /// Elements that start a line, without the space a paragraph has around it.
    private static let lineElements: Set<String> = [
        "div", "section", "article", "header", "footer", "main", "nav", "aside", "figure", "figcaption", "center", "address",
        "details", "summary", "dl", "dt", "dd", "form", "fieldset", "legend", "caption", "body", "html",
    ]

    mutating func read(_ html: String) {
        var index = html.startIndex
        while index < html.endIndex {
            if html[index] == "<", let tag = Tag.parse(html, at: index) {
                if tag.kind == .unterminated {
                    // A tag that never ends: what follows can't be told apart from its attributes, so the rest is text,
                    // read once rather than again from every "<" in it.
                    text(HTMLEntities.decode(html[index...]))
                    break
                }
                index = tag.end
                handle(tag)
            } else {
                let next = html[html.index(after: index)...].firstIndex(of: "<") ?? html.endIndex
                text(HTMLEntities.decode(html[index..<next]))
                index = next
            }
        }
    }

    mutating func finish() -> [RichText.Block] {
        if preDepth > 0 {
            preDepth = 0
            endPre()
        }
        if tables > 0 {
            tables = 1
            endTable()
        }
        flush()
        return blocks
    }

    private mutating func handle(_ tag: Tag) {
        if let skipped {
            if tag.kind == .close, tag.name == skipped { self.skipped = nil }
            return
        }
        switch tag.kind {
        case .ignored, .unterminated:
            return
        case .open:
            if Self.skippedElements.contains(tag.name) {
                if !tag.selfClosing { skipped = tag.name }
                return
            }
            open(tag)
            if tag.selfClosing && !Self.voids.contains(tag.name) { close(tag.name) }
        case .close:
            close(tag.name)
        }
    }

    private mutating func open(_ tag: Tag) {
        let name = tag.name
        if preDepth > 0 {
            if name == "pre" {
                preDepth += 1
            } else if name == "br" {
                code += "\n"
            }
            return
        }
        switch name {
        case "br":
            append("\n")
        case "p":
            if tables > 0 || listItems > 0 { lineBreak() } else { flush() }
        case "h1", "h2", "h3", "h4", "h5", "h6":
            if tables > 0 {
                lineBreak()
                push(Inline(name: name, style: .bold))
            } else {
                flush()
                kind = .heading(Int(String(name.dropFirst())) ?? 1)
            }
        case "ul", "ol":
            guard tables == 0 else { return lineBreak() }
            flush()
            let start = name == "ol" ? (Self.listNumber(tag.attributes["start"]) ?? 1) : 1
            lists.append((name == "ol", start))
        case "li":
            guard tables == 0 else {
                lineBreak()
                return append("• ")
            }
            flush()
            // An item left open, as HTML allows, ends at the next one: a list has one open item at most.
            listItems = min(listItems + 1, max(lists.count, 1))
            var marker = RichText.ListMarker.bullet
            if let last = lists.indices.last, lists[last].ordered {
                let number = Self.listNumber(tag.attributes["value"]) ?? lists[last].next
                marker = .number(number)
                lists[last].next = number + 1
            }
            kind = .listItem(marker, depth: max(lists.count - 1, 0))
        case "blockquote":
            guard tables == 0 else { return lineBreak() }
            flush()
            quotes += 1
        case "pre":
            if tables > 0 {
                lineBreak()
                push(Inline(name: name, style: .code))
            } else {
                flush()
                preDepth = 1
                code = ""
            }
        case "hr":
            guard tables == 0 else { return lineBreak() }
            flush()
            blocks.append(.rule)
        case "img":
            let url = RichText.webLink(tag.attributes["src"])
            let alt = tag.attributes["alt"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = alt.isEmpty ? RichText.fileName(of: url) ?? "Image" : alt
            if tables > 0 {
                push(Inline(name: "img", style: [], link: url))
                append(title)
                pop("img")
            } else {
                flush()
                blocks.append(.image(alt: title, url: url))
            }
        case "table":
            if tables > 0 {
                tables += 1
                return lineBreak()
            }
            flush()
            tables = 1
            rows = []
            row = []
            inCell = false
        case "tr":
            if tables == 1 { endRow() } else if tables > 1 { lineBreak() }
        case "td", "th":
            if tables == 1 {
                endCell()
                inCell = true
                if name == "th" { push(Inline(name: "th", style: .bold)) }
            } else if tables > 1 {
                append(" ")
            }
        case "input":
            // A task list's checkbox, as Markdown renders it: `<li><input type="checkbox" checked> Done</li>`.
            if tag.attributes["type"]?.lowercased() == "checkbox", case .listItem(_, let depth) = kind,
               RichText.text(of: runs).allSatisfy(\.isWhitespace) {
                kind = .listItem(.checkbox(checked: tag.attributes["checked"] != nil), depth: depth)
            }
        default:
            if Self.lineElements.contains(name) {
                lineBreak()
            } else if let style = Self.inlineStyle(name, tag.attributes) {
                push(style)
            }
        }
    }

    private mutating func close(_ name: String) {
        if preDepth > 0 {
            if name == "pre" {
                preDepth -= 1
                if preDepth == 0 { endPre() }
            }
            return
        }
        switch name {
        case "p":
            if tables > 0 || listItems > 0 { lineBreak() } else { flush() }
        case "h1", "h2", "h3", "h4", "h5", "h6":
            if tables > 0 {
                pop(name)
                lineBreak()
            } else {
                flush()
            }
        case "ul", "ol":
            guard tables == 0 else { return lineBreak() }
            flush()
            if !lists.isEmpty { lists.removeLast() }
            listItems = min(listItems, lists.count)
        case "li":
            guard tables == 0 else { return lineBreak() }
            flush()
            listItems = max(listItems - 1, 0)
        case "blockquote":
            guard tables == 0 else { return lineBreak() }
            flush()
            quotes = max(quotes - 1, 0)
        case "table":
            if tables > 1 {
                tables -= 1
                lineBreak()
            } else if tables == 1 {
                endTable()
            }
        case "tr":
            if tables == 1 { endRow() }
        case "td", "th":
            if tables == 1 { endCell() }
        default:
            if Self.lineElements.contains(name) {
                lineBreak()
            } else {
                pop(name)
            }
        }
    }

    /// Text, its spaces collapsed as a browser would, but for no-break spaces.
    private mutating func text(_ text: String) {
        guard skipped == nil, !text.isEmpty else { return }
        if preDepth > 0 {
            code += text
            return
        }
        var collapsed = ""
        var afterSpace = endsWithSpace
        for character in text {
            if character.isWhitespace && character != "\u{00A0}" {
                if !afterSpace {
                    collapsed.append(" ")
                    afterSpace = true
                }
            } else {
                collapsed.append(character)
                afterSpace = false
            }
        }
        append(collapsed)
    }

    private var endsWithSpace: Bool {
        guard let last = runs.last?.text.last else { return true }
        return last == " " || last == "\n"
    }

    private mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        let style = inline.reduce(into: RichText.Style()) { $0.formUnion($1.style) }
        let link = inline.last(where: { $0.link != nil })?.link
        if let last = runs.last, last.style == style, last.link == link {
            runs[runs.count - 1].text += text
        } else {
            runs.append(RichText.Run(text, style: style, link: link))
        }
    }

    /// A new line in the block, unless it's at one already.
    private mutating func lineBreak() {
        guard let last = runs.last?.text.last, last != "\n" else { return }
        append("\n")
    }

    private mutating func push(_ element: Inline) {
        guard inline.count < RichText.htmlInlineDepth else {
            untracked[element.name, default: 0] += 1
            return
        }
        inline.append(element)
    }

    private mutating func pop(_ name: String) {
        if let count = untracked[name] {
            untracked[name] = count > 1 ? count - 1 : nil
            return
        }
        if let index = inline.lastIndex(where: { $0.name == name }) {
            inline.remove(at: index)
        }
    }

    /// Ends the block being read, if it has any text.
    private mutating func flush() {
        let content = RichText.normalized(runs)
        runs = []
        defer { kind = .paragraph }
        guard !content.isEmpty else { return }
        switch kind {
        case .paragraph:
            blocks.append(quotes > 0 ? .quote(content) : .paragraph(content))
        case .heading(let level):
            blocks.append(.heading(level: level, content))
        case .listItem(let marker, let depth):
            blocks.append(.listItem(marker, depth: depth, content))
        }
    }

    private mutating func endPre() {
        var text = code.replacingOccurrences(of: "\r\n", with: "\n")
        code = ""
        while text.hasPrefix("\n") { text.removeFirst() }
        while let last = text.last, last.isWhitespace { text.removeLast() }
        if !text.isEmpty { blocks.append(.code(text)) }
    }

    private mutating func endCell() {
        guard inCell else { return }
        inline.removeAll { $0.name == "th" }
        untracked["th"] = nil
        row.append(RichText.normalized(runs))
        runs = []
        inCell = false
    }

    private mutating func endRow() {
        endCell()
        if !row.isEmpty { rows.append(row) }
        row = []
    }

    private mutating func endTable() {
        endRow()
        tables = 0
        let filled = rows.filter { $0.contains { !$0.isEmpty } }
        rows = []
        if !filled.isEmpty { blocks.append(.table(filled)) }
    }

    /// A list's number, as an attribute gives it: up to nine digits, as Markdown allows, so counting on can't overflow.
    private static func listNumber(_ text: String?) -> Int? {
        guard let text, let number = Int(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        return min(max(number, -999_999_999), 999_999_999)
    }

    private static func inlineStyle(_ name: String, _ attributes: [String: String]) -> Inline? {
        switch name {
        case "b", "strong": return Inline(name: name, style: .bold)
        case "i", "em", "cite", "dfn", "var": return Inline(name: name, style: .italic)
        case "u", "ins": return Inline(name: name, style: .underline)
        case "s", "strike", "del": return Inline(name: name, style: .strikethrough)
        case "code", "kbd", "samp", "tt": return Inline(name: name, style: .code)
        case "a":
            // A mention, "@Sam Rivera", links nowhere.
            if attributes["data-vss-mention"] != nil { return Inline(name: name, style: .bold) }
            return Inline(name: name, style: [], link: RichText.webLink(attributes["href"]))
        case "span", "font", "mark", "small", "big", "sup", "sub", "abbr", "label", "q", "time":
            return Inline(name: name, style: style(css: attributes["style"]))
        default:
            return nil
        }
    }

    /// What an inline `style` says about weight, slant, lines and fonts: what pasted text keeps of its look.
    private static func style(css: String?) -> RichText.Style {
        guard let css = css?.lowercased().filter({ !$0.isWhitespace }), !css.isEmpty else { return [] }
        var style = RichText.Style()
        if css.contains("font-weight:bold") || css.contains("font-weight:bolder")
            || ["600", "700", "800", "900"].contains(where: { css.contains("font-weight:\($0)") }) {
            style.insert(.bold)
        }
        if css.contains("font-style:italic") { style.insert(.italic) }
        if css.contains("underline") { style.insert(.underline) }
        if css.contains("line-through") { style.insert(.strikethrough) }
        if ["monospace", "consolas", "courier", "menlo", "monaco"].contains(where: { css.contains($0) }) { style.insert(.code) }
        return style
    }
}

/// An HTML tag, read leniently: names and attributes in any case, values quoted or not.
private struct Tag {
    /// An element's opening or closing tag; a comment, doctype or the like, which says nothing; or a tag whose ">" never
    /// comes, which isn't one.
    enum Kind { case open, close, ignored, unterminated }

    var kind: Kind
    var name: String
    var attributes: [String: String] = [:]
    var selfClosing = false
    /// Just after its `>`.
    var end: String.Index

    /// The tag at `start`, a `<`; nil when it's not one, such as in "a < b".
    static func parse(_ html: String, at start: String.Index) -> Tag? {
        var index = html.index(after: start)
        guard index < html.endIndex else { return nil }
        if html[index...].hasPrefix("!--") {
            let end = html.range(of: "-->", range: index..<html.endIndex)?.upperBound ?? html.endIndex
            return Tag(kind: .ignored, name: "", end: end)
        }
        if html[index] == "!" || html[index] == "?" {
            let end = html[index...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
            return Tag(kind: .ignored, name: "", end: end)
        }
        var closing = false
        if html[index] == "/" {
            closing = true
            index = html.index(after: index)
        }
        let nameStart = index
        guard nameStart < html.endIndex, html[nameStart].isASCII, html[nameStart].isLetter else { return nil }
        while index < html.endIndex, html[index].isASCII, html[index].isLetter || html[index].isNumber || html[index] == "-" || html[index] == ":" {
            index = html.index(after: index)
        }
        var tag = Tag(kind: closing ? .close : .open, name: html[nameStart..<index].lowercased(), end: html.endIndex)
        while index < html.endIndex {
            let character = html[index]
            if character == ">" {
                tag.end = html.index(after: index)
                return tag
            }
            if character.isWhitespace {
                index = html.index(after: index)
                continue
            }
            if character == "/" {
                tag.selfClosing = true
                index = html.index(after: index)
                continue
            }
            tag.selfClosing = false
            let attributeStart = index
            while index < html.endIndex, !html[index].isWhitespace, !"=>/".contains(html[index]) {
                index = html.index(after: index)
            }
            if index == attributeStart {
                // A stray "=", such as in `<a = b>`.
                index = html.index(after: index)
                continue
            }
            let attribute = html[attributeStart..<index].lowercased()
            while index < html.endIndex, html[index].isWhitespace { index = html.index(after: index) }
            guard index < html.endIndex, html[index] == "=" else {
                tag.attributes[attribute] = ""
                continue
            }
            index = html.index(after: index)
            while index < html.endIndex, html[index].isWhitespace { index = html.index(after: index) }
            guard index < html.endIndex else { break }
            if html[index] == "\"" || html[index] == "'" {
                let quote = html[index]
                let valueStart = html.index(after: index)
                let valueEnd = html[valueStart...].firstIndex(of: quote) ?? html.endIndex
                tag.attributes[attribute] = HTMLEntities.decode(html[valueStart..<valueEnd])
                index = valueEnd < html.endIndex ? html.index(after: valueEnd) : html.endIndex
            } else {
                let valueStart = index
                while index < html.endIndex, !html[index].isWhitespace, html[index] != ">" { index = html.index(after: index) }
                tag.attributes[attribute] = HTMLEntities.decode(html[valueStart..<index])
            }
        }
        // No ">", to the end: not a tag after all, nor is anything after it.
        return Tag(kind: .unterminated, name: tag.name, end: html.endIndex)
    }
}

/// HTML's character references: `&amp;`, `&#233;`, `&#x1F600;` and the named ones text uses.
enum HTMLEntities {
    static func decode<S: StringProtocol>(_ text: S) -> String {
        guard text.contains("&") else { return String(text) }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let semicolon = text[index...].prefix(32).firstIndex(of: ";"),
               let decoded = entity(text[text.index(after: index)..<semicolon]) {
                result += decoded
                index = text.index(after: semicolon)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func entity<S: StringProtocol>(_ name: S) -> String? {
        guard name.first == "#" else { return named[String(name)] }
        let digits = name.dropFirst()
        let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
        guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }

    /// Every named character reference HTML 4.01 has, such as `&eacute;`, `&ouml;`, `&alpha;` and `&hellip;`, with
    /// `&lang;` and `&rang;` as browsers show them now, and `&apos;` and `&check;`, from HTML5.
    private static let named: [String: String] = [
        "Aacute": "Á", "aacute": "á", "Acirc": "Â", "acirc": "â", "acute": "´", "AElig": "Æ", "aelig": "æ", "Agrave": "À",
        "agrave": "à", "alefsym": "ℵ", "Alpha": "Α", "alpha": "α", "amp": "&", "and": "∧", "ang": "∠", "apos": "'",
        "Aring": "Å", "aring": "å", "asymp": "≈", "Atilde": "Ã", "atilde": "ã", "Auml": "Ä", "auml": "ä", "bdquo": "„",
        "Beta": "Β", "beta": "β", "brvbar": "¦", "bull": "•", "cap": "∩", "Ccedil": "Ç", "ccedil": "ç", "cedil": "¸",
        "cent": "¢", "check": "✓", "Chi": "Χ", "chi": "χ", "circ": "ˆ", "clubs": "♣", "cong": "≅", "copy": "©",
        "crarr": "↵", "cup": "∪", "curren": "¤", "Dagger": "‡", "dagger": "†", "dArr": "⇓", "darr": "↓", "deg": "°",
        "Delta": "Δ", "delta": "δ", "diams": "♦", "divide": "÷", "Eacute": "É", "eacute": "é", "Ecirc": "Ê", "ecirc": "ê",
        "Egrave": "È", "egrave": "è", "empty": "∅", "emsp": "\u{2003}", "ensp": "\u{2002}", "Epsilon": "Ε", "epsilon": "ε",
        "equiv": "≡", "Eta": "Η", "eta": "η", "ETH": "Ð", "eth": "ð", "Euml": "Ë", "euml": "ë", "euro": "€", "exist": "∃",
        "fnof": "ƒ", "forall": "∀", "frac12": "½", "frac14": "¼", "frac34": "¾", "frasl": "⁄", "Gamma": "Γ", "gamma": "γ",
        "ge": "≥", "gt": ">", "hArr": "⇔", "harr": "↔", "hearts": "♥", "hellip": "…", "Iacute": "Í", "iacute": "í",
        "Icirc": "Î", "icirc": "î", "iexcl": "¡", "Igrave": "Ì", "igrave": "ì", "image": "ℑ", "infin": "∞", "int": "∫",
        "Iota": "Ι", "iota": "ι", "iquest": "¿", "isin": "∈", "Iuml": "Ï", "iuml": "ï", "Kappa": "Κ", "kappa": "κ",
        "Lambda": "Λ", "lambda": "λ", "lang": "⟨", "laquo": "«", "lArr": "⇐", "larr": "←", "lceil": "⌈", "ldquo": "“",
        "le": "≤", "lfloor": "⌊", "lowast": "∗", "loz": "◊", "lrm": "\u{200E}", "lsaquo": "‹", "lsquo": "‘", "lt": "<",
        "macr": "¯", "mdash": "—", "micro": "µ", "middot": "·", "minus": "−", "Mu": "Μ", "mu": "μ", "nabla": "∇",
        "nbsp": "\u{A0}", "ndash": "–", "ne": "≠", "ni": "∋", "not": "¬", "notin": "∉", "nsub": "⊄", "Ntilde": "Ñ",
        "ntilde": "ñ", "Nu": "Ν", "nu": "ν", "Oacute": "Ó", "oacute": "ó", "Ocirc": "Ô", "ocirc": "ô", "OElig": "Œ",
        "oelig": "œ", "Ograve": "Ò", "ograve": "ò", "oline": "‾", "Omega": "Ω", "omega": "ω", "Omicron": "Ο",
        "omicron": "ο", "oplus": "⊕", "or": "∨", "ordf": "ª", "ordm": "º", "Oslash": "Ø", "oslash": "ø", "Otilde": "Õ",
        "otilde": "õ", "otimes": "⊗", "Ouml": "Ö", "ouml": "ö", "para": "¶", "part": "∂", "permil": "‰", "perp": "⊥",
        "Phi": "Φ", "phi": "φ", "Pi": "Π", "pi": "π", "piv": "ϖ", "plusmn": "±", "pound": "£", "Prime": "″", "prime": "′",
        "prod": "∏", "prop": "∝", "Psi": "Ψ", "psi": "ψ", "quot": "\"", "radic": "√", "rang": "⟩", "raquo": "»",
        "rArr": "⇒", "rarr": "→", "rceil": "⌉", "rdquo": "”", "real": "ℜ", "reg": "®", "rfloor": "⌋", "Rho": "Ρ",
        "rho": "ρ", "rlm": "\u{200F}", "rsaquo": "›", "rsquo": "’", "sbquo": "‚", "Scaron": "Š", "scaron": "š", "sdot": "⋅",
        "sect": "§", "shy": "\u{AD}", "Sigma": "Σ", "sigma": "σ", "sigmaf": "ς", "sim": "∼", "spades": "♠", "sub": "⊂",
        "sube": "⊆", "sum": "∑", "sup": "⊃", "sup1": "¹", "sup2": "²", "sup3": "³", "supe": "⊇", "szlig": "ß", "Tau": "Τ",
        "tau": "τ", "there4": "∴", "Theta": "Θ", "theta": "θ", "thetasym": "ϑ", "thinsp": "\u{2009}", "THORN": "Þ",
        "thorn": "þ", "tilde": "˜", "times": "×", "trade": "™", "Uacute": "Ú", "uacute": "ú", "uArr": "⇑", "uarr": "↑",
        "Ucirc": "Û", "ucirc": "û", "Ugrave": "Ù", "ugrave": "ù", "uml": "¨", "upsih": "ϒ", "Upsilon": "Υ", "upsilon": "υ",
        "Uuml": "Ü", "uuml": "ü", "weierp": "℘", "Xi": "Ξ", "xi": "ξ", "Yacute": "Ý", "yacute": "ý", "yen": "¥",
        "Yuml": "Ÿ", "yuml": "ÿ", "Zeta": "Ζ", "zeta": "ζ", "zwj": "\u{200D}", "zwnj": "\u{200C}",
    ]
}

// MARK: - Markdown

/// Reads Markdown a line at a time into blocks, and each block's text with Foundation's inline Markdown. A single line
/// break stays a line break: Azure DevOps' editors don't wrap lines, so one there is one you typed.
private enum MarkdownReader {
    private enum Pending {
        case paragraph
        case listItem(RichText.ListMarker, depth: Int)
    }

    /// How many quotes in quotes it reads as quotes: deeper, the rest is their text, so a line of `>`s can't recurse deep.
    private static let quoteDepth = 8

    static func read(_ markdown: String, depth: Int = 0) -> [RichText.Block] {
        let raw = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Each line with its indentation in spaces, tabs going to the next multiple of four columns, for the blocks'
        // structure. What's after the indentation, and code, keep their tabs.
        let lines = raw.map(Self.expandingIndentation)
        var blocks: [RichText.Block] = []
        var pending: [String] = []
        var pendingKind = Pending.paragraph
        var listIndents: [Int] = []
        /// Each open list's next number, by depth: nil for a bulleted one.
        var numbers: [Int?] = []
        var afterBlank = false
        var index = 0

        func flush() {
            defer {
                pending = []
                pendingKind = .paragraph
            }
            guard !pending.isEmpty else { return }
            let runs = inline(joined(pending))
            guard !runs.isEmpty else { return }
            switch pendingKind {
            case .paragraph: blocks.append(.paragraph(runs))
            case .listItem(let marker, let depth): blocks.append(.listItem(marker, depth: depth, runs))
            }
        }
        /// Closes the lists that a block indented this much is outside of: those whose items are indented as much or more.
        /// It's in the others' items, which go on after it, counting on.
        func closeLists(at indent: Int) {
            while let last = listIndents.last, last >= indent { listIndents.removeLast() }
            if numbers.count > listIndents.count { numbers.removeSubrange(listIndents.count...) }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count
            defer { afterBlank = trimmed.isEmpty }
            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }
            // Indented four spaces or more, outside a list, a line starts nothing else, whatever it looks like: it's code,
            // or more of the paragraph above it.
            if listIndents.isEmpty, indent >= 4 {
                if !pending.isEmpty {
                    pending.append(Self.unindented(line))
                    index += 1
                    continue
                }
                var code: [String] = []
                while index < lines.count {
                    let next = lines[index]
                    let nextIndent = next.prefix { $0 == " " }.count
                    guard next.trimmingCharacters(in: .whitespaces).isEmpty || nextIndent >= 4 else { break }
                    code.append(Self.droppingIndentation(raw[index], columns: 4))
                    index += 1
                }
                let text = code.joined(separator: "\n").trimmingCharacters(in: .newlines)
                if !text.isEmpty { blocks.append(.code(text)) }
                continue
            }
            if let fence = Self.fence(trimmed) {
                // Where its closing fence may be, as CommonMark has it: up to three columns into what it's in, the text of
                // a list's item, as indented as the fence there, or the page.
                flush()
                closeLists(at: indent)
                let closingIndent = (listIndents.isEmpty ? 0 : indent) + 3
                var code: [String] = []
                index += 1
                while index < lines.count, !Self.closes(fence, lines[index], indentedUpTo: closingIndent) {
                    code.append(Self.droppingIndentation(raw[index], columns: indent))
                    index += 1
                }
                index += 1
                let text = code.joined(separator: "\n").trimmingCharacters(in: .newlines)
                if !text.isEmpty { blocks.append(.code(text)) }
                continue
            }
            if case .paragraph = pendingKind, !pending.isEmpty, !trimmed.isEmpty,
               trimmed.allSatisfy({ $0 == "=" }) || (trimmed.count >= 2 && trimmed.allSatisfy { $0 == "-" }) {
                // A setext heading: the paragraph above, underlined.
                let runs = inline(joined(pending))
                pending = []
                if !runs.isEmpty { blocks.append(.heading(level: trimmed.first == "=" ? 1 : 2, runs)) }
                index += 1
                continue
            }
            if let match = trimmed.wholeMatch(of: /(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*/) {
                flush()
                closeLists(at: indent)
                let runs = inline(String(match.2 ?? ""))
                if !runs.isEmpty { blocks.append(.heading(level: match.1.count, runs)) }
                index += 1
                continue
            }
            if Self.isRule(trimmed) {
                flush()
                closeLists(at: indent)
                blocks.append(.rule)
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                closeLists(at: indent)
                var quoted: [String] = []
                while index < lines.count {
                    // What ends its lines stays: spaces after a backslash keep it from breaking the line.
                    let next = Self.unindented(lines[index])
                    guard next.hasPrefix(">") else { break }
                    var content = next.dropFirst()
                    if content.first == " " { content = content.dropFirst() }
                    quoted.append(String(content))
                    index += 1
                }
                let inner = quoted.joined(separator: "\n")
                if depth < quoteDepth {
                    for block in read(inner, depth: depth + 1) {
                        if case .paragraph(let runs) = block { blocks.append(.quote(runs)) } else { blocks.append(block) }
                    }
                } else {
                    let runs = inline(inner)
                    if !runs.isEmpty { blocks.append(.quote(runs)) }
                }
                continue
            }
            if line.contains("|"), index + 1 < lines.count, Self.isTableSeparator(lines[index + 1]) {
                flush()
                closeLists(at: indent)
                var rows = [Self.cells(line).map { cell in inline(cell).map { run in
                    var bold = run
                    bold.style.insert(.bold)
                    return bold
                } }]
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(Self.cells(lines[index]).map(inline))
                    index += 1
                }
                blocks.append(.table(rows))
                continue
            }
            if let match = trimmed.wholeMatch(of: /!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+["'(][^)]*["')])?\s*\)/) {
                flush()
                // Like a paragraph, after a blank line: in the list items it's indented into, and after the lists it isn't.
                if afterBlank { closeLists(at: indent) }
                let url = RichText.webLink(String(match.2))
                let alt = String(match.1).trimmingCharacters(in: .whitespaces)
                blocks.append(.image(alt: alt.isEmpty ? RichText.fileName(of: url) ?? "Image" : alt, url: url))
                index += 1
                continue
            }
            if let match = line.wholeMatch(of: /( *)([-*+]|(\d{1,9})[.)])(?:[ \t]+(.*))?/) {
                flush()
                let itemIndent = match.1.count
                while let last = listIndents.last, last > itemIndent { listIndents.removeLast() }
                if listIndents.last != itemIndent { listIndents.append(itemIndent) }
                let depth = listIndents.count - 1
                // The lists deeper than it are over. Less indented than the list it ends but more than the one around it,
                // it's that list's next item, as CommonMark has it, and counts on.
                if numbers.count > depth + 1 { numbers.removeSubrange((depth + 1)...) }
                while numbers.count <= depth { numbers.append(nil) }
                var content = String(match.4 ?? "")
                var marker = RichText.ListMarker.bullet
                if let digits = match.3 {
                    let number = numbers[depth] ?? Int(digits) ?? 1
                    numbers[depth] = number + 1
                    marker = .number(number)
                } else {
                    numbers[depth] = nil
                    if let task = content.wholeMatch(of: /\[([ xX])\](?:[ \t]+(.*))?/) {
                        marker = .checkbox(checked: task.1 != " ")
                        content = String(task.2 ?? "")
                    }
                }
                pendingKind = .listItem(marker, depth: depth)
                pending = [content]
                index += 1
                continue
            }
            // A paragraph after a blank line: in the list items it's indented into, and after the lists it isn't.
            if afterBlank, pending.isEmpty { closeLists(at: indent) }
            pending.append(Self.unindented(line))
            index += 1
        }
        flush()
        return blocks
    }

    /// A line without its indentation, but with what ends it: spaces after a backslash keep it from breaking the line.
    private static func unindented(_ line: String) -> String {
        String(line.drop { $0 == " " || $0 == "\t" })
    }

    /// A line that closes a code block: nothing but the fence's character, at least as many times, indented no further
    /// than `indentedUpTo` columns. Further, it's code too. `line`'s indentation is in spaces.
    private static func closes(_ fence: String, _ line: String, indentedUpTo maxIndent: Int) -> Bool {
        guard line.prefix(while: { $0 == " " }).count <= maxIndent else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= fence.count && trimmed.allSatisfy { $0 == fence.first }
    }

    /// A line with its indentation in spaces, tabs going to the next multiple of four columns, and the rest as it is.
    static func expandingIndentation(_ line: String) -> String {
        var columns = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            columns = line[index] == "\t" ? (columns / 4 + 1) * 4 : columns + 1
            index = line.index(after: index)
        }
        return String(repeating: " ", count: columns) + line[index...]
    }

    /// A line without up to `columns` columns of its indentation; a tab that goes past them leaves the rest of its width
    /// in spaces.
    static func droppingIndentation(_ line: String, columns: Int) -> String {
        var column = 0
        var index = line.startIndex
        while index < line.endIndex, column < columns {
            if line[index] == " " {
                column += 1
            } else if line[index] == "\t" {
                let next = (column / 4 + 1) * 4
                if next > columns {
                    return String(repeating: " ", count: next - columns) + line[line.index(after: index)...]
                }
                column = next
            } else {
                break
            }
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    /// The fence that opens a code block, such as "```".
    private static func fence(_ line: String) -> String? {
        for mark in ["```", "~~~"] where line.hasPrefix(mark) {
            return String(line.prefix { $0 == mark.first })
        }
        return nil
    }

    /// `---`, `***` or `___`, with spaces between or not.
    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// `| --- | :---: |`, under a table's header.
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        let cells = cells(trimmed)
        return !cells.isEmpty && cells.allSatisfy { $0.wholeMatch(of: /:?-+:?/) != nil }
    }

    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        let placeholder = "\u{FFFC}"
        return text.replacingOccurrences(of: "\\|", with: placeholder).split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces) }
    }

    /// A block's lines as one text, as they were written: inline Markdown reads their backslashes, a line break's among them.
    private static func joined(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    /// Inline Markdown: emphasis, code, strikethrough, links and images, which link to where they are.
    private static func inline(_ text: String) -> [RichText.Run] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let attributed = try? AttributedString(markdown: text, options: options) else {
            return RichText.normalized([RichText.Run(text)])
        }
        var runs: [RichText.Run] = []
        for run in attributed.runs {
            var piece = String(attributed[run.range].characters)
            var style = RichText.Style()
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { style.insert(.bold) }
                if intent.contains(.emphasized) { style.insert(.italic) }
                if intent.contains(.code) { style.insert(.code) }
                if intent.contains(.strikethrough) { style.insert(.strikethrough) }
            }
            var link = RichText.webLink(run.link)
            if let image = run.imageURL {
                link = RichText.webLink(image)
                if piece.trimmingCharacters(in: .whitespaces).isEmpty { piece = RichText.fileName(of: link) ?? "Image" }
            }
            if let last = runs.last, last.style == style, last.link == link {
                runs[runs.count - 1].text += piece
            } else {
                runs.append(RichText.Run(piece, style: style, link: link))
            }
        }
        return RichText.normalized(runs)
    }
}
