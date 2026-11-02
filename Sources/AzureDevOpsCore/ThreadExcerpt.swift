import Foundation

/// The code a comment thread is on: its lines, and a few around them, as the diff it was made on showed them, with the
/// lines removed and added there.
public struct ThreadExcerpt: Sendable, Equatable {
    /// Which version of the file a thread's lines are in.
    public enum Side: String, Sendable, Codable, Hashable {
        /// Before the change, as for a thread on lines the pull request removed.
        case left
        /// After the change.
        case right
    }

    /// A line of the excerpt.
    public struct Line: Sendable, Equatable, Hashable {
        public var kind: DiffLine.Kind
        /// Cut at `ThreadExcerpt.maxLineLength` characters, with "…".
        public var text: String
        /// Its number before the change: nil for an added line.
        public var oldNumber: Int?
        /// Its number after the change: nil for a removed line.
        public var newNumber: Int?
        /// One of the lines the thread is on.
        public var isCommented: Bool
        /// How many lines are left out after it: those of a long run of the other side's lines, between its ends.
        public var omittedAfter: Int

        public init(
            kind: DiffLine.Kind, text: String, oldNumber: Int?, newNumber: Int?, isCommented: Bool = false, omittedAfter: Int = 0
        ) {
            self.kind = kind
            self.text = text
            self.oldNumber = oldNumber
            self.newNumber = newNumber
            self.isCommented = isCommented
            self.omittedAfter = omittedAfter
        }
    }

    /// Why a thread's code can't be shown.
    public enum Problem: Error, Sendable, Equatable, CustomStringConvertible {
        /// It isn't on lines of a file: it's on the pull request, or a whole file.
        case notOnLines
        /// Azure DevOps doesn't say which iterations the pull request has, as for one from before it kept them.
        case noIterations
        /// The file isn't text, such as an image.
        case binary
        /// The file is longer than BriefBar reads (`FileText.limit`).
        case tooLarge
        /// The file doesn't have the lines it's on.
        case linesNotFound
        /// The pull request changed more files than BriefBar reads, and this one isn't among those it read.
        case tooManyFiles
        /// It's another pull request's: each reader reads one.
        case otherPullRequest
        /// Azure DevOps couldn't be read.
        case unreadable(ADOError)

        public var description: String {
            switch self {
            case .notOnLines: return "It isn't on lines of a file."
            case .noIterations: return "Azure DevOps doesn't say which version of the file it's on."
            case .binary: return "The file isn't text."
            case .tooLarge: return "The file is too long to show here."
            case .linesNotFound: return "The file doesn't have the lines it's on."
            case .tooManyFiles: return "The pull request changes too many files to find this one."
            case .otherPullRequest: return "It's on another pull request."
            case .unreadable(let error): return error.description
            }
        }
    }

    public var threadId: Int
    /// The file, such as "/src/PaymentsClient.cs".
    public var path: String
    /// What the file was called before, when the diff renamed it.
    public var originalPath: String?
    /// How the diff changed the file: nil when it didn't.
    public var change: FileChange.Kind?
    public var side: Side
    public var lines: [Line]
    /// Nothing of the diff comes before its lines: they start at the top of the file, with all that was removed or added
    /// above it.
    public var reachesStart: Bool
    /// Nothing of the diff comes after its lines: they end at the end of the file, with all that was removed or added
    /// below it.
    public var reachesEnd: Bool
    /// The thread is on more lines than it shows: how many of its first ones are left out.
    public var hiddenCommentedLines: Int
    /// The iteration on the right of the diff it shows: the one the comment was made on.
    public var iteration: Int
    /// The pull request's latest iteration, when it was read.
    public var latestIteration: Int
    /// The file changed after `iteration`, so the code may not look like this anymore; nil when that couldn't be read.
    public var changedSince: Bool?

    public init(
        threadId: Int, path: String, originalPath: String? = nil, change: FileChange.Kind? = nil, side: Side, lines: [Line],
        reachesStart: Bool, reachesEnd: Bool, hiddenCommentedLines: Int = 0, iteration: Int, latestIteration: Int,
        changedSince: Bool? = false
    ) {
        self.threadId = threadId
        self.path = path
        self.originalPath = originalPath
        self.change = change
        self.side = side
        self.lines = lines
        self.reachesStart = reachesStart
        self.reachesEnd = reachesEnd
        self.hiddenCommentedLines = hiddenCommentedLines
        self.iteration = iteration
        self.latestIteration = latestIteration
        self.changedSince = changedSince
    }

    /// How many lines it shows before and after the thread's.
    public static let context = 3
    /// How many of a thread's own lines it shows: the last ones, which Azure DevOps shows the thread under.
    public static let maxCommentedLines = 20
    /// How many characters of a line it keeps.
    public static let maxLineLength = 1_000
    /// How many of the other side's lines it shows in a row, such as lines removed among those the thread is on: past
    /// that, as many from the run's two ends, with the rest left out between them; or, above the file's first line or
    /// below its last, the ones nearest it.
    public static let maxOtherLines = 10

    /// The part of a diff an excerpt shows.
    struct Window: Equatable {
        var lines: [Line]
        var reachesStart: Bool
        var reachesEnd: Bool
        var hiddenCommentedLines: Int
    }

    /// The lines of `diff` around those numbered `lines` on `side`: `context` of that side's before and after them, with
    /// the other side's lines between, and at the top or the bottom of the file, the other side's lines beyond, which have
    /// nothing else to come before or after; `maxOther` of the other side's in a row at most. Of a thread's own lines, it
    /// keeps the last `maxCommented`. Nil when that side doesn't have the first of them.
    static func window(
        of diff: [DiffLine], side: Side, lines: ClosedRange<Int>, context: Int = context, maxCommented: Int = maxCommentedLines,
        maxOther: Int = maxOtherLines
    ) -> Window? {
        let number: (DiffLine) -> Int? = side == .right ? { $0.newNumber } : { $0.oldNumber }
        // Where each of the side's lines is in the diff, by its number less one.
        let rows = diff.indices.filter { number(diff[$0]) != nil }
        guard lines.lowerBound >= 1, lines.lowerBound <= rows.count else { return nil }
        let last = min(lines.upperBound, rows.count)
        let first = max(lines.lowerBound, last - max(1, maxCommented) + 1)
        let from = max(1, first - max(0, context))
        let to = min(rows.count, last + max(0, context))
        let start = from == 1 ? 0 : rows[from - 1]
        let end = to == rows.count ? diff.count - 1 : rows[to - 1]
        var shown: [Line] = []
        var reachesStart = start == 0
        var reachesEnd = end == diff.count - 1
        func show(_ rows: some Sequence<Int>) {
            for row in rows {
                let line = diff[row]
                shown.append(Line(
                    kind: line.kind, text: Self.cut(line.text), oldNumber: line.oldNumber, newNumber: line.newNumber,
                    isCommented: number(line).map { (first...last).contains($0) } ?? false
                ))
            }
        }
        let limit = max(2, maxOther)
        var row = start
        while row <= end {
            guard number(diff[row]) == nil else {
                show(row...row)
                row += 1
                continue
            }
            // A run of the other side's lines.
            var runEnd = row
            while runEnd < end, number(diff[runEnd + 1]) == nil { runEnd += 1 }
            let count = runEnd - row + 1
            if count <= limit {
                show(row...runEnd)
            } else if row == start {
                show((runEnd - limit + 1)...runEnd)
                reachesStart = false
            } else if runEnd == end {
                show(row...(row + limit - 1))
                reachesEnd = false
            } else {
                show(row...(row + limit / 2 - 1))
                shown[shown.count - 1].omittedAfter = count - limit / 2 * 2
                show((runEnd - limit / 2 + 1)...runEnd)
            }
            row = runEnd + 1
        }
        return Window(lines: shown, reachesStart: reachesStart, reachesEnd: reachesEnd, hiddenCommentedLines: first - lines.lowerBound)
    }

    private static func cut(_ text: String) -> String {
        guard text.count > maxLineLength else { return text }
        return String(text.prefix(maxLineLength - 1)) + "…"
    }
}
