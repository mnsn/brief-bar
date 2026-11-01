import Foundation
import SwiftUI

/// What a summary says beyond its headline and next step, in the little Markdown a summary has: a point a line, after
/// "- ", each starting with a word or two in bold, and **bold** and `code` within a line. Never a link: what a model
/// writes may come from anyone's comment, so a link shows as its words only.
enum SummaryMarkdown {
    enum Block: Equatable {
        case point(String)
        case text(String)
    }

    /// Its points, and the text between them, in order: a line right after a point goes on with it, unless the point
    /// ended its sentence; after a blank line, it's text of its own, its lines together.
    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var isAfterBlank = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                isAfterBlank = true
                continue
            }
            defer { isAfterBlank = false }
            if let point = point(trimmed) {
                blocks.append(.point(point))
            } else if !isAfterBlank, case .point(let before)? = blocks.last, !Self.endsSentence(before) {
                blocks[blocks.count - 1] = .point(before + " " + trimmed)
            } else if !isAfterBlank, case .text(let before)? = blocks.last {
                blocks[blocks.count - 1] = .text(before + " " + trimmed)
            } else {
                blocks.append(.text(trimmed))
            }
        }
        return blocks
    }

    /// Whether a point ends as a sentence does, so what's after it isn't its own: ".", "!" or "?", maybe in bold or code.
    private static func endsSentence(_ text: String) -> Bool {
        let end = text.trimmingCharacters(in: CharacterSet(charactersIn: "*`\"”)").union(.whitespaces))
        return end.hasSuffix(".") || end.hasSuffix("!") || end.hasSuffix("?")
    }

    private static func point(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            let point = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return point.isEmpty ? nil : point
        }
        return nil
    }

    /// A line, with its bold and code as written.
    static func inline(_ line: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var text = try? AttributedString(markdown: line, options: options) else { return AttributedString(line) }
        for range in text.runs.filter({ $0.link != nil || $0.imageURL != nil }).map(\.range) {
            text[range].link = nil
            text[range].imageURL = nil
        }
        return text
    }

    /// All of it in one text, a point a line after "•", for a row, where it's cut to a few lines.
    static func joined(_ text: String) -> AttributedString {
        var all = AttributedString()
        for (index, block) in blocks(text).enumerated() {
            if index > 0 { all += AttributedString("\n") }
            switch block {
            case .point(let point): all += AttributedString("•  ") + inline(point)
            case .text(let text): all += inline(text)
            }
        }
        return all
    }
}

/// A summary's points under its next step, on its card: a bullet each, its wrapped lines under its first word.
struct SummaryPoints: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(SummaryMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .point(let point):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .accessibilityHidden(true)
                        Text(SummaryMarkdown.inline(point))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .text(let text):
                    Text(SummaryMarkdown.inline(text))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }
}
