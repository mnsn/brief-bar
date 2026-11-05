import Foundation

/// A comment of yours as you edit it: what it says, as Azure DevOps keeps it, with each mention as the name it shows, "@Sam
/// Rivera", rather than as its ID, "@<…>"; and back, what you wrote, with those names as their mentions again, so that a
/// comment you edit still mentions whom it did. A mention whose name isn't known, or that two of its mentions share, or that
/// would come back as something else, stays as Azure DevOps keeps it: what you leave as it was always goes as it was.
public struct CommentEditing: Sendable, Equatable {
    /// What it says, as Azure DevOps keeps it.
    public let content: String
    /// What you edit: `content`, with its mentions as names where they come back as they were.
    public let text: String
    /// The mentions `text` shows as names, the longest name first.
    private let named: [Named]

    private struct Named: Sendable, Equatable {
        /// "@Sam Rivera".
        var name: String
        /// "@<…>", as the comment has it.
        var mention: String
    }

    /// - Parameters:
    ///   - content: what the comment says, as Azure DevOps keeps it.
    ///   - names: names by lowercased IDs, as the details show mentions.
    public init(content: String, names: [String: String]) {
        self.content = content
        // Each person it mentions once, as the comment first has them, by name.
        var mentions: [String: String] = [:]
        for match in content.matches(of: CommentText.mention) {
            let id = String(match.output.1).lowercased()
            if mentions[id] == nil { mentions[id] = String(match.output.0) }
        }
        var byName: [String: [String]] = [:]
        for id in mentions.keys {
            guard let name = names[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            byName[name, default: []].append(id)
        }
        // A name two mentions share, or one the comment says as text already, would come back as something else.
        var shown: [String: String] = [:]
        for (name, ids) in byName where ids.count == 1 && !Self.contains("@" + name, in: content) {
            shown[ids[0]] = "@" + name
        }
        let named = shown.compactMap { id, name in mentions[id].map { Named(name: name, mention: $0) } }
            .sorted { ($0.name.count, $0.name) > ($1.name.count, $1.name) }
        let text = content.replacing(CommentText.mention) { match in
            shown[String(match.output.1).lowercased()] ?? String(match.output.0)
        }
        // Left as it is, it goes as it was, or nothing shows as a name.
        if Self.content(of: text, named) == content {
            self.text = text
            self.named = named
        } else {
            self.text = content
            self.named = []
        }
    }

    /// What you wrote, as it would go: each name a mention showed as, "@Sam Rivera", followed by anything but a letter, a
    /// digit or an underscore, as that mention again.
    public func content(of text: String) -> String {
        Self.content(of: text, named)
    }

    private static func content(of text: String, _ named: [Named]) -> String {
        var text = text
        for named in named {
            var out = ""
            var rest = text[...]
            while let range = rest.range(of: named.name) {
                out += rest[..<range.lowerBound]
                out += endsWord(at: range.upperBound, in: rest) ? named.mention : named.name
                rest = rest[range.upperBound...]
            }
            out += rest
            text = out
        }
        return text
    }

    /// Whether `word` is in `text`, as a word of its own at its end.
    private static func contains(_ word: String, in text: String) -> Bool {
        var rest = text[...]
        while let range = rest.range(of: word) {
            if endsWord(at: range.upperBound, in: rest) { return true }
            rest = rest[range.upperBound...]
        }
        return false
    }

    private static func endsWord(at index: Substring.Index, in text: Substring) -> Bool {
        guard index < text.endIndex else { return true }
        let next = text[index]
        return !(next.isLetter || next.isNumber || next == "_")
    }
}

extension CommentEditing {
    /// A comment of yours in a pull request's thread, as you'd edit it, its mentions named as the details name them: by the
    /// pull request's people and the thread's.
    public init(_ comment: ReviewComment, in thread: ReviewThread, of pullRequest: PullRequest) {
        var names = PRDetails.names(of: pullRequest)
        for other in thread.comments { names[other.author.id] = other.author.name }
        self.init(content: comment.kept, names: names)
    }
}
