import Foundation
import SwiftUI

/// What a Copilot session answered, in the Markdown a model writes, in blocks: paragraphs, headings, points and numbered
/// points, code, quotes, tables and rules; within a line, its bold, italics and code, as written (`SummaryMarkdown.inline`).
/// Never a link: what a model writes may quote anyone's comment, so a link shows as its words only, as a summary's does.
enum AnswerMarkdown {
    enum Block: Equatable {
        case paragraph(String)
        case heading(String)
        /// A point: its marker, "•" or its number, "2.", and how deep it's nested, from 0.
        case point(marker: String, text: String, depth: Int)
        /// Code, as written, line by line.
        case code(String)
        case quote(String)
        /// A table's rows, each its cells, without the line under its header.
        case table([[String]])
        case rule
    }

    /// How deep points nest at most.
    static let deepest = 3

    /// Its blocks, in order. A line right after a paragraph, a point or a quote goes on with it, unless a blank line or
    /// another block came between; a fence that never closes holds the rest as code.
    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var fence: (marker: Character, length: Int, indent: Int, lines: [String])?
        var isAfterBlank = true
        // Whether the table being read has had the line under its header: after it, a row of dashes is one of its own.
        var isPastTableRule = false
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for line in lines {
            if let open = fence {
                if closes(line, marker: open.marker, length: open.length) {
                    blocks.append(.code(open.lines.joined(separator: "\n")))
                    fence = nil
                    isAfterBlank = true
                } else {
                    fence?.lines.append(withoutIndent(line, upTo: open.indent))
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                isAfterBlank = true
                continue
            }
            let continues = !isAfterBlank
            isAfterBlank = false
            if let opening = fenceOpening(line) {
                fence = (opening.marker, opening.length, opening.indent, [])
            } else if let heading = heading(trimmed) {
                blocks.append(.heading(heading))
            } else if isRule(trimmed) {
                blocks.append(.rule)
            } else if let point = point(line) {
                blocks.append(.point(marker: point.marker, text: point.text, depth: point.depth))
            } else if let quote = quote(trimmed) {
                if continues, case .quote(let before)? = blocks.last {
                    blocks[blocks.count - 1] = .quote(joined(before, quote))
                } else {
                    blocks.append(.quote(quote))
                }
            } else if let row = tableRow(trimmed) {
                if continues, case .table(let rows)? = blocks.last {
                    if !isPastTableRule, rows.count == 1, isTableRule(row) {
                        isPastTableRule = true
                    } else {
                        blocks[blocks.count - 1] = .table(rows + [row])
                    }
                } else {
                    blocks.append(.table([row]))
                    isPastTableRule = false
                }
            } else if continues, let last = blocks.last, let goesOn = goingOn(last, with: trimmed) {
                blocks[blocks.count - 1] = goesOn
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }
        if let open = fence { blocks.append(.code(open.lines.joined(separator: "\n"))) }
        return blocks
    }

    /// A paragraph, a point or a quote, going on with a line of text; nil for anything else, which a line doesn't go on.
    private static func goingOn(_ block: Block, with line: String) -> Block? {
        switch block {
        case .paragraph(let text): .paragraph(joined(text, line))
        case .point(let marker, let text, let depth): .point(marker: marker, text: joined(text, line), depth: depth)
        case .quote(let text): .quote(joined(text, line))
        case .heading, .code, .table, .rule: nil
        }
    }

    /// Two lines of the same block, as one: a line break inside a paragraph is a space, as Markdown reads it.
    private static func joined(_ text: String, _ line: String) -> String {
        text.isEmpty ? line : text + " " + line
    }

    /// Up to three spaces, then three backticks or tildes or more: its marker, how many, and how far it's indented.
    private static func fenceOpening(_ line: String) -> (marker: Character, length: Int, indent: Int)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        // A backtick fence's words after it can't have a backtick.
        if marker == "`", rest.dropFirst(length).contains("`") { return nil }
        return (marker, length, indent)
    }

    /// Whether a line closes a fence: up to three spaces, as many of its marker or more, and nothing after but spaces. One
    /// indented further is the code's own.
    private static func closes(_ line: String, marker: Character, length: Int) -> Bool {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return false }
        let fence = line.dropFirst(indent).prefix { $0 == marker }
        return fence.count >= length && line.dropFirst(indent + fence.count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// A code line, without as many of its leading spaces as its fence was indented by.
    private static func withoutIndent(_ line: String, upTo indent: Int) -> String {
        let spaces = min(indent, line.prefix { $0 == " " }.count)
        return String(line.dropFirst(spaces))
    }

    /// "## Where it stands": its words.
    private static func heading(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        var words = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        // Closing hashes, after a space, as in "## Done ##"; a word's own stay, as in "## C#".
        let closing = words.reversed().prefix { $0 == "#" }.count
        if closing == words.count || words.dropLast(closing).last?.isWhitespace == true {
            words = words.dropLast(closing).trimmingCharacters(in: .whitespaces)
        }
        return words.isEmpty ? nil : words
    }

    /// "---", "***", "___", spaced or not.
    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// "- point", "* point", "+ point", "• point", "1. point", "2) point": its marker, its text, and how deep it's nested,
    /// by its indent.
    private static func point(_ line: String) -> (marker: String, text: String, depth: Int)? {
        let expanded = line.replacingOccurrences(of: "\t", with: "    ")
        let indent = expanded.prefix { $0 == " " }.count
        let rest = expanded.dropFirst(indent)
        let depth = min(indent / 2, deepest)
        if let first = rest.first, "-*+•".contains(first), rest.dropFirst().first == " " {
            let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : ("•", text, depth)
        }
        let digits = rest.prefix(while: \.isNumber)
        guard (1...3).contains(digits.count), let mark = rest.dropFirst(digits.count).first, mark == "." || mark == ")",
              rest.dropFirst(digits.count + 1).first == " "
        else { return nil }
        let text = rest.dropFirst(digits.count + 2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : ("\(digits).", text, depth)
    }

    /// "> quoted": its words; "" for a quote's blank line.
    private static func quote(_ line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        return line.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    /// "| a | b |": its cells. A pipe after a backslash is a cell's own, in its words or its code, as in "| `a \| b` |",
    /// and shows without the backslash, as GitHub reads a table.
    private static func tableRow(_ line: String) -> [String]? {
        guard line.count >= 2, line.hasPrefix("|"), line.hasSuffix("|") else { return nil }
        var cells: [String] = []
        var cell = ""
        var isEscaped = false
        for character in line.dropFirst() {
            if character == "|", !isEscaped {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(character)
            }
            isEscaped = character == "\\" && !isEscaped
        }
        // After the last pipe, when it's a cell's own: "| a | b \|".
        if !cell.trimmingCharacters(in: .whitespaces).isEmpty { cells.append(cell) }
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    /// The line under a table's header: "|---|:--:|".
    private static func isTableRule(_ cells: [String]) -> Bool {
        cells.allSatisfy { cell in !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" } }
    }

    /// All of it as plain text, for VoiceOver and what the row's tooltip says: its words, a block a line.
    static func plain(_ blocks: [Block]) -> String {
        blocks.map { block -> String in
            switch block {
            case .paragraph(let text), .heading(let text), .quote(let text): String(SummaryMarkdown.inline(text).characters)
            case .point(let marker, let text, _): marker + " " + String(SummaryMarkdown.inline(text).characters)
            case .code(let code): code
            case .table(let rows): rows.map { $0.joined(separator: ", ") }.joined(separator: "\n")
            case .rule: ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
}

/// An answer's blocks (`AnswerMarkdown`), drawn as BriefBar draws what a model wrote: its text can be selected, and code
/// wraps rather than scrolling, so nothing in it takes the keyboard's focus. Only its first `shownBlocks`, when given:
/// those after aren't there at all, for VoiceOver to reach, as below the beginning of a long answer.
struct AnswerText: View {
    let blocks: [AnswerMarkdown.Block]
    /// Its text's size, which follows the text size on windows' pages.
    var size: CGFloat = 12.5
    /// How many of its blocks show, from the first; all of them when nil.
    var shownBlocks: Int?
    /// It says where each of its blocks starts (`AnswerBlockTops`), for what shows only some of them to tell which fit.
    var reportsBlockTops = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.prefix(shownBlocks ?? blocks.count).enumerated()), id: \.offset) { index, block in
                if reportsBlockTops {
                    view(of: block)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: AnswerBlockTops.self, value: [index: proxy.frame(in: .named(AnswerBlockTops.space)).minY]
                                )
                            }
                        }
                } else {
                    view(of: block)
                }
            }
        }
        .coordinateSpace(.named(AnswerBlockTops.space))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(of block: AnswerMarkdown.Block) -> some View {
        switch block {
        case .paragraph(let text):
            line(text)
        case .heading(let text):
            line(text, weight: .semibold)
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
        case .point(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(size: size, weight: marker == "•" ? .bold : .regular)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(marker == "•")
                line(text)
            }
            .padding(.leading, 2 + CGFloat(depth) * 14)
        case .code(let code):
            Text(code)
                .font(size: size - 1, design: .monospaced)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
        case .quote(let text):
            line(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 2.5)
                }
        case .table(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            line(cell, weight: index == 0 && rows.count > 1 ? .semibold : nil)
                        }
                    }
                }
            }
        case .rule:
            Divider()
                .padding(.vertical, 2)
        }
    }

    private func line(_ text: String, weight: Font.Weight? = nil) -> some View {
        Text(SummaryMarkdown.inline(text))
            .font(size: size, weight: weight)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Where each block of an `AnswerText` that reports them starts, from its top, by its index.
struct AnswerBlockTops: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    /// The space they're measured in: the answer's own.
    static let space = "answer-blocks"

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}
