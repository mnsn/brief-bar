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

        public init(kind: DiffLine.Kind, text: String, oldNumber: Int?, newNumber: Int?, isCommented: Bool = false) {
            self.kind = kind
            self.text = text
            self.oldNumber = oldNumber
            self.newNumber = newNumber
            self.isCommented = isCommented
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
    /// Nothing of the diff comes before its lines: they start at the top of the file.
    public var reachesStart: Bool
    /// Nothing of the diff comes after its lines: they end at the end of the file.
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

    /// The part of a diff an excerpt shows.
    struct Window: Equatable {
        var lines: [Line]
        var reachesStart: Bool
        var reachesEnd: Bool
        var hiddenCommentedLines: Int
    }

    /// The lines of `diff` around those numbered `lines` on `side`: `context` of that side's before and after them, with
    /// the other side's lines between, and at the top or the bottom of the file, the other side's lines beyond, which have
    /// nothing else to come before or after. Of a thread's own lines, it keeps the last `maxCommented`. Nil when that side
    /// doesn't have the first of them.
    static func window(
        of diff: [DiffLine], side: Side, lines: ClosedRange<Int>, context: Int = context, maxCommented: Int = maxCommentedLines
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
        let shown = diff[start...end].map { line in
            Line(
                kind: line.kind, text: Self.cut(line.text), oldNumber: line.oldNumber, newNumber: line.newNumber,
                isCommented: number(line).map { (first...last).contains($0) } ?? false
            )
        }
        return Window(lines: shown, reachesStart: start == 0, reachesEnd: end == diff.count - 1,
                      hiddenCommentedLines: first - lines.lowerBound)
    }

    private static func cut(_ text: String) -> String {
        guard text.count > maxLineLength else { return text }
        return String(text.prefix(maxLineLength - 1)) + "…"
    }
}
