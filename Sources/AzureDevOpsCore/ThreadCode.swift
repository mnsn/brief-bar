import Foundation

/// A row of code, as a pull request's details draw it: a line of a file, before the change, after it or both, or a note
/// where lines are left out.
public struct CodeRow: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        /// A line of the file: in both versions, or only in the one before the change or after it.
        case line(DiffLine.Kind)
        /// Lines left out, as its text says: "12 lines".
        case gap
    }

    public var kind: Kind
    /// The line, or what the note says.
    public var text: String
    /// Its number before the change: nil for an added line or a note.
    public var oldNumber: Int?
    /// Its number after the change: nil for a removed line or a note.
    public var newNumber: Int?
    /// One of the lines a comment is on.
    public var isMarked: Bool

    public init(_ kind: Kind, _ text: String, old oldNumber: Int? = nil, new newNumber: Int? = nil, isMarked: Bool = false) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.isMarked = isMarked
    }
}

/// What a pull request's details show of the code a comment thread is on, from what `PullRequestCode` reads of it
/// (`ThreadExcerpt`): its rows, the lines it's on, and, when it can't be read, why.
public enum ThreadCode {
    /// The rows of the code a thread is on: a note first when its first lines are left out, then the lines, with a note
    /// wherever lines are left out between them.
    public static func rows(of excerpt: ThreadExcerpt) -> [CodeRow] {
        var rows: [CodeRow] = []
        if excerpt.hiddenCommentedLines > 0 {
            let count = excerpt.hiddenCommentedLines
            rows.append(CodeRow(.gap, count == 1 ? "1 more line it's on, above" : "\(count) more lines it's on, above"))
        }
        for line in excerpt.lines {
            rows.append(CodeRow(.line(line.kind), line.text, old: line.oldNumber, new: line.newNumber, isMarked: line.isCommented))
            if line.omittedAfter > 0 {
                rows.append(CodeRow(.gap, line.omittedAfter == 1 ? "1 line" : "\(line.omittedAfter) lines"))
            }
        }
        return rows
    }

    /// The rows without the indentation their lines share, so that code deep in a file starts where the room for it does:
    /// the spaces and tabs that start every line that isn't blank go from each line; a blank line loses as many as it has.
    /// The notes stay as they are.
    public static func outdented(_ rows: [CodeRow]) -> [CodeRow] {
        func indent(_ text: String) -> Substring {
            text.prefix { $0 == " " || $0 == "\t" }
        }
        let indents = rows.compactMap { row -> Substring? in
            guard row.kind != .gap, row.text.contains(where: { !$0.isWhitespace }) else { return nil }
            return indent(row.text)
        }
        guard var common = indents.first else { return rows }
        for other in indents.dropFirst() {
            common = common.prefix(zip(common, other).prefix { $0 == $1 }.count)
        }
        guard !common.isEmpty else { return rows }
        return rows.map { row in
            guard row.kind != .gap else { return row }
            var row = row
            row.text = String(row.text.dropFirst(min(common.count, indent(row.text).count)))
            return row
        }
    }

    /// The lines a thread is on in the diff it was made on, which its code shows: on the file after the change, or else
    /// before it. Nil for one that isn't on lines of a file, such as one on the pull request or on a whole file.
    public static func span(of thread: ReviewThread) -> (lines: ClosedRange<Int>, side: ThreadExcerpt.Side)? {
        guard let location = thread.location else {
            // Without its location, as the demo's threads: its line, after the change.
            guard let path = thread.filePath, !path.isEmpty, let line = thread.line, line >= 1 else { return nil }
            return (line...line, .right)
        }
        var spans = (left: location.left, right: location.right)
        // Where it was made, before Azure DevOps followed it to a later diff.
        if let tracking = location.tracking, location.madeOn != nil, tracking.originalLeft != nil || tracking.originalRight != nil {
            spans = (tracking.originalLeft, tracking.originalRight)
        }
        if let right = spans.right { return (right.lines, .right) }
        if let left = spans.left { return (left.lines, .left) }
        return nil
    }

    /// Whether a thread is on lines of a file, so that its code shows above it.
    public static func isOnLines(_ thread: ReviewThread) -> Bool {
        span(of: thread) != nil
    }

    /// About how many rows a thread's code takes, before it's read: its lines, as many as an excerpt shows, and the lines
    /// around them. Nil for one that isn't on lines.
    public static func expectedRows(of thread: ReviewThread) -> Int? {
        guard let span = span(of: thread) else { return nil }
        return min(span.lines.count, ThreadExcerpt.maxCommentedLines) + 2 * ThreadExcerpt.context
    }

    /// "Line 88", or "Lines 86–88": where a thread is on its file, as its code shows it.
    public static func linesName(_ lines: ClosedRange<Int>) -> String {
        lines.count == 1 ? "Line \(lines.lowerBound)" : "Lines \(lines.lowerBound)–\(lines.upperBound)"
    }

    /// Why a thread's code can't be shown, in a sentence; nil for one that isn't on lines, which shows no code.
    public static func sentence(for problem: ThreadExcerpt.Problem) -> String? {
        switch problem {
        case .notOnLines: return nil
        case .unreadable(.notFound): return "Azure DevOps doesn't have this version of the file."
        case .unreadable(.forbidden): return "You don't have access to this repository's files."
        default: return problem.description
        }
    }

    /// Whether reading it again may show it: Azure DevOps couldn't be reached, asked BriefBar to wait, or didn't accept the
    /// sign-in. What isn't there, can't be read or can't be shown stays so.
    public static func mayPass(_ problem: ThreadExcerpt.Problem) -> Bool {
        guard case .unreadable(let error) = problem else { return false }
        switch error {
        case .notFound, .forbidden, .decoding, .redirected: return false
        case .auth, .unauthorized, .otherDirectory, .throttled, .offline, .http, .network: return true
        }
    }
}

// MARK: - Links

extension ADOEndpoint {
    /// A pull request's Files page at a file, with what changed in it from one of its updates to another; or from the
    /// commit its branch left its target at, for a `base` of 0.
    public static func pullRequestFilePage(
        organization: String, project: String, repository: String, id: Int, path: String, iteration: Int, base: Int
    ) -> URL {
        url("https://dev.azure.com", [organization, project, "_git", repository, "pullrequest", String(id)], [
            ("_a", "files"), ("path", path), ("iteration", String(iteration)), ("base", String(base)),
        ])
    }
}

extension PRSnapshot {
    /// The pull request's Files page at a file that changed since a comment was made on it: what changed from the update
    /// the comment was made on to the latest.
    public func filePageURL(path: String, since excerpt: ThreadExcerpt) -> URL {
        ADOEndpoint.pullRequestFilePage(
            organization: key.organization, project: project, repository: repository, id: key.number, path: path,
            iteration: excerpt.latestIteration, base: excerpt.iteration
        )
    }
}
