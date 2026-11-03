import Foundation

/// Fix Grammar, for what you write in BriefBar, such as a reply in a pull request's thread: what it asks a model, and what
/// it makes of the answer. It corrects spelling, grammar and punctuation only, in the language the text is written in,
/// keeping its meaning, its voice and its Markdown. The model never sees its code, links or @mentions: they're held back as
/// markers (`request(for:)`), and put back as they were (`corrected(_:for:)`), or the answer is turned down if it lost one.
/// What comes of it is a suggestion, which you accept or not.
public enum GrammarFix {
    /// What the model is told, before the text.
    public static let instructions = """
        You correct spelling, grammar and punctuation, and nothing else. Keep the text in the language it's written in: \
        never translate it. Keep its meaning, its tone, its voice and its wording: don't rephrase, shorten, expand, \
        explain or answer it, even when it asks something, and leave a sentence that's right as it is. Keep its Markdown \
        as it is: its line breaks, its lists, its emphasis and its quotes. Keep every marker such as {{1}} exactly as \
        it is, where it is: each stands for code, a link or a mention, which must not change. Answer with the corrected \
        text only, without the tags around it, and without a word about what you changed.
        """

    /// The text to give a model, with what it mustn't change held back as markers.
    public struct Request: Sendable, Equatable {
        /// All of it for the model: the instructions, then the text between tags. For a model without instructions of its
        /// own, such as the Copilot CLI's.
        public var prompt: String
        /// The text, with markers in place of what's held back, between `<text>` and `</text>`: for a model told the
        /// instructions apart, as Apple Intelligence is.
        public var text: String
        /// What each marker stands for, by its number, from 1.
        public var held: [String]
        /// How a marker looks: its number between these.
        var open: String
        var close: String

        func marker(_ number: Int) -> String { open + String(number) + close }
    }

    /// Why a model's answer isn't a correction to suggest.
    public enum Failure: Error, Sendable, Equatable {
        /// It answered nothing.
        case empty
        /// It lost, repeated or changed what was held back: code, a link or a mention.
        case changedHeld
    }

    /// The text to ask a model to correct: its code, its links and its mentions held back as markers.
    public static func request(for text: String) -> Request {
        let (open, close) = markerDelimiters(avoiding: text)
        var held: [String] = []
        var masked = ""
        var rest = Substring(text)
        while let found = firstHeld(in: rest) {
            masked += rest[rest.startIndex..<found.lowerBound]
            held.append(String(rest[found]))
            masked += open + String(held.count) + close
            rest = rest[found.upperBound...]
        }
        masked += rest
        let wrapped = "<text>\n\(masked)\n</text>"
        return Request(prompt: instructions + "\n\n" + wrapped, text: wrapped, held: held, open: open, close: close)
    }

    /// The correction a model answered with: without the tags or the quotes around it, and with what was held back put back
    /// as it was, or why it isn't one to suggest.
    public static func corrected(_ answer: String, for request: Request) -> Result<String, Failure> {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let inside = between("<text>", "</text>", in: text) { text = inside.trimmingCharacters(in: .whitespacesAndNewlines) }
        text = unwrapped(text)
        guard !text.isEmpty else { return .failure(.empty) }
        // Each marker once, in the order the text had them: else something held back moved, went or came twice.
        var positions: [String.Index] = []
        for number in request.held.indices.map({ $0 + 1 }) {
            let marker = request.marker(number)
            let ranges = text.ranges(of: marker)
            guard ranges.count == 1, let range = ranges.first else { return .failure(.changedHeld) }
            positions.append(range.lowerBound)
        }
        guard positions == positions.sorted() else { return .failure(.changedHeld) }
        // A marker it made up, such as the next number, is something that was never there.
        if text.ranges(of: request.marker(request.held.count + 1)).count > 0 { return .failure(.changedHeld) }
        for (index, original) in request.held.enumerated().reversed() {
            text = text.replacingOccurrences(of: request.marker(index + 1), with: original)
        }
        return .success(text)
    }

    // MARK: What it holds back

    /// The first span the model mustn't change: a fenced code block, inline code, a link or a picture in Markdown, an
    /// autolink or an HTML tag, a web address, or a mention, whether Azure DevOps' (`@<…>`) or a name after `@`.
    static func firstHeld(in text: Substring) -> Range<Substring.Index>? {
        let patterns: [Regex<Substring>] = [
            // Fenced code, to its closing fence, or else to the end.
            /(?m)^[ \t]*```[^\n]*\n(?:.*\n)*?[ \t]*```[ \t]*$/,
            /(?m)^[ \t]*~~~[^\n]*\n(?:.*\n)*?[ \t]*~~~[ \t]*$/,
            /(?m)^[ \t]*(?:```|~~~)[\s\S]*/,
            // Inline code, between backticks.
            /``[^`](?:[^`]|`[^`])*?``|`[^`\n]+`/,
            // A link or a picture: its text and where it goes.
            /!?\[[^\]\n]*\]\([^)\n]*\)/,
            // A mention as Azure DevOps keeps it.
            /@<[^<>\s]+>/,
            // An autolink, or an HTML tag.
            /<[^<>\n]+>/,
            // A web address.
            /(?i)(?:https?:\/\/|www\.)[^\s<>()]*[^\s<>().,;:!?'"]/,
        ]
        var first: Range<Substring.Index>?
        for pattern in patterns {
            guard let match = try? pattern.firstMatch(in: text) else { continue }
            if first.map({ match.range.lowerBound < $0.lowerBound }) ?? true { first = match.range }
        }
        if let mention = firstMention(in: text), first.map({ mention.lowerBound < $0.lowerBound }) ?? true { first = mention }
        return first
    }

    /// The first name after an `@`, as you'd write a mention: not one in an email address, after a letter or a digit.
    private static func firstMention(in text: Substring) -> Range<Substring.Index>? {
        var index = text.startIndex
        while let at = text[index...].firstIndex(of: "@") {
            let after = text.index(after: at)
            let isStart = at == text.startIndex || !(text[text.index(before: at)].isLetter || text[text.index(before: at)].isNumber
                || text[text.index(before: at)] == "@" || text[text.index(before: at)] == "_")
            if isStart, after < text.endIndex, text[after].isLetter || text[after].isNumber || text[after] == "_" {
                var end = after
                while end < text.endIndex, text[end].isLetter || text[end].isNumber || "_.-".contains(text[end]) {
                    end = text.index(after: end)
                }
                // Not the full stop after it.
                while end > after, ".-".contains(text[text.index(before: end)]) { end = text.index(before: end) }
                return at..<end
            }
            index = after
        }
        return nil
    }

    /// A marker's delimiters that the text doesn't have, so that none in it is taken for one.
    static func markerDelimiters(avoiding text: String) -> (open: String, close: String) {
        let candidates = [("{{", "}}"), ("[[", "]]"), ("⟦", "⟧"), ("<<", ">>")]
        return candidates.first { !text.contains($0.0) && !text.contains($0.1) } ?? ("{{%", "%}}")
    }

    /// What's between two tags, when the text has both.
    private static func between(_ open: String, _ close: String, in text: String) -> String? {
        guard let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// Without the quotes or the fence a model may put around all of it.
    private static func unwrapped(_ text: String) -> String {
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'")] where text.count > 1 && text.hasPrefix(open) && text.hasSuffix(close) {
            let inside = text.dropFirst(open.count).dropLast(close.count)
            if !inside.contains(open) { return String(inside).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count >= 2, let first = lines.first, let last = lines.last, first.hasPrefix("```"), last.trimmingCharacters(in: .whitespaces) == "```" {
            return lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: What changed

    /// A run of the corrected text: one that's new, or that changed, or one that was there before.
    public struct Piece: Sendable, Equatable {
        public var text: String
        public var isChanged: Bool

        public init(_ text: String, isChanged: Bool) {
            self.text = text
            self.isChanged = isChanged
        }
    }

    /// The corrected text in runs, what changed apart, word by word, for a suggestion to show what it changes: a word it
    /// took out marks the word after it, or else the one before, so that every change shows. All of it changed, for texts
    /// too long to compare.
    public static func changes(from original: String, to corrected: String) -> [Piece] {
        let before = tokens(original)
        let after = tokens(corrected)
        guard before.count * after.count <= 1_000_000 else { return [Piece(corrected, isChanged: true)] }
        // The longest common run of tokens, as a table of what's left of each from each place.
        let rows = before.count + 1, columns = after.count + 1
        var lengths = [Int](repeating: 0, count: rows * columns)
        for i in stride(from: before.count - 1, through: 0, by: -1) {
            for j in stride(from: after.count - 1, through: 0, by: -1) {
                lengths[i * columns + j] = before[i] == after[j]
                    ? lengths[(i + 1) * columns + j + 1] + 1
                    : max(lengths[(i + 1) * columns + j], lengths[i * columns + j + 1])
            }
        }
        var kept = [Bool](repeating: false, count: after.count)
        var takenOutBefore = [Bool](repeating: false, count: after.count + 1)
        var i = 0, j = 0
        while i < before.count, j < after.count {
            if before[i] == after[j] {
                kept[j] = true
                i += 1
                j += 1
            } else if lengths[(i + 1) * columns + j] >= lengths[i * columns + j + 1] {
                // Taken out of the original.
                if !isSpace(before[i]) { takenOutBefore[j] = true }
                i += 1
            } else {
                j += 1
            }
        }
        if i < before.count, before[i...].contains(where: { !isSpace($0) }) { takenOutBefore[after.count] = true }
        var changed = kept.map { !$0 }
        // A word taken out shows on the word where it was: the next, or else the one before.
        for index in 0...after.count where takenOutBefore[index] {
            if let next = (index..<after.count).first(where: { !isSpace(after[$0]) }) {
                changed[next] = true
            } else if let previous = (0..<index).last(where: { !isSpace(after[$0]) }) {
                changed[previous] = true
            }
        }
        // Spaces between two changed words read as part of the change.
        for index in after.indices where isSpace(after[index]) && index > 0 && index + 1 < after.count {
            if changed[index - 1] && changed[index + 1] { changed[index] = true }
        }
        var pieces: [Piece] = []
        for (token, isChanged) in zip(after, changed) {
            // Spaces alone don't show as a change at either end of one.
            let isChanged = isChanged && !(isSpace(token) && !(pieces.last?.isChanged ?? false))
            if let last = pieces.last, last.isChanged == isChanged {
                pieces[pieces.count - 1].text += token
            } else {
                pieces.append(Piece(token, isChanged: isChanged))
            }
        }
        // A change that ends in spaces: the spaces aren't part of it.
        var trimmed: [Piece] = []
        for piece in pieces {
            guard piece.isChanged else {
                trimmed.append(piece)
                continue
            }
            let core = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !core.isEmpty, let range = piece.text.range(of: core) else {
                trimmed.append(Piece(piece.text, isChanged: false))
                continue
            }
            let leading = String(piece.text[..<range.lowerBound]), trailing = String(piece.text[range.upperBound...])
            if !leading.isEmpty { trimmed.append(Piece(leading, isChanged: false)) }
            trimmed.append(Piece(core, isChanged: true))
            if !trailing.isEmpty { trimmed.append(Piece(trailing, isChanged: false)) }
        }
        // Runs of the same kind, joined.
        return trimmed.reduce(into: []) { result, piece in
            if let last = result.last, last.isChanged == piece.isChanged {
                result[result.count - 1].text += piece.text
            } else {
                result.append(piece)
            }
        }
    }

    /// Words, runs of spaces, and each other character, such as a comma.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var kind = 0
        for character in text {
            let next = character.isLetter || character.isNumber || character == "'" || character == "’" ? 1 : character.isWhitespace ? 2 : 3
            if next == kind, next != 3 {
                current.append(character)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = String(character)
                kind = next
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func isSpace(_ token: String) -> Bool {
        token.allSatisfy(\.isWhitespace)
    }

    /// How many words changed: for VoiceOver, and to say there's nothing to change.
    public static func changeCount(_ pieces: [Piece]) -> Int {
        pieces.filter(\.isChanged).count
    }
}

extension GrammarFix {
    /// The demo's made-up correction, which runs no model: the start of each sentence and a lone "i" capitalized, a few
    /// common misspellings fixed, no space before punctuation, and a full stop at the end, outside what's held back, as a
    /// model's would be.
    public static func madeUp(_ text: String) -> String {
        let request = request(for: text)
        var body = between("<text>\n", "\n</text>", in: request.text) ?? text
        let misspellings = [
            "teh": "the", "recieve": "receive", "seperate": "separate", "definately": "definitely", "occured": "occurred",
            "untill": "until", "wich": "which", "becuase": "because", "dont": "don't", "doesnt": "doesn't", "isnt": "isn't",
            "thats": "that's", "ive": "I've", "i": "I",
        ]
        body = tokens(body).map { token in
            guard let fixed = misspellings[token.lowercased()] else { return token }
            return token.first?.isUppercase == true && fixed != "I" ? fixed.prefix(1).uppercased() + fixed.dropFirst() : fixed
        }.joined()
        body = body.replacing(/[ \t]+([,.;:!?])/) { String($0.output.1) }
        // Each sentence's first letter.
        var result = ""
        var startsSentence = true
        for character in body {
            if startsSentence, character.isLetter {
                result.append(contentsOf: character.uppercased())
                startsSentence = false
                continue
            }
            if ".!?\n".contains(character) { startsSentence = true } else if !character.isWhitespace { startsSentence = false }
            result.append(character)
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // A full stop after the last word, or after code, a link or a mention on its line, as the last thing it says.
        let endsInline = request.held.indices.contains { index in
            trimmed.hasSuffix(request.marker(index + 1)) && !request.held[index].contains("\n")
        }
        if let last = trimmed.last, last.isLetter || last.isNumber || endsInline { result = trimmed + "." } else { result = trimmed }
        for (index, original) in request.held.enumerated().reversed() {
            result = result.replacingOccurrences(of: request.marker(index + 1), with: original)
        }
        return result
    }
}
