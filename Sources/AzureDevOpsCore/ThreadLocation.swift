import Foundation

extension ReviewThread {
    /// A character in a file: its line, from 1, and where it is in that line, as Azure DevOps counts it (from 1 in
    /// practice). Nil when Azure DevOps doesn't say.
    public struct Position: Sendable, Codable, Equatable, Hashable {
        public var line: Int
        public var offset: Int?

        public init(line: Int, offset: Int? = nil) {
            self.line = line
            self.offset = offset
        }

        /// Nil without a line, or with one before the first.
        init?(_ position: ADOThread.Position?) {
            guard let line = position?.line, line >= 1 else { return nil }
            self.init(line: line, offset: position?.offset)
        }
    }

    /// What a thread is on in one of the files a diff compares: from its first character to its last.
    public struct Span: Sendable, Codable, Equatable, Hashable {
        public var start: Position
        public var end: Position

        /// An end before the start, or none at all, ends at the start.
        public init(start: Position, end: Position? = nil) {
            self.start = start
            self.end = end.map { $0.line < start.line ? start : $0 } ?? start
        }

        /// A span on one line, or from `lines`' first to its last.
        public init(lines: ClosedRange<Int>) {
            self.init(start: Position(line: lines.lowerBound), end: Position(line: lines.upperBound))
        }

        /// Nil without a start.
        init?(_ start: ADOThread.Position?, _ end: ADOThread.Position?) {
            guard let start = Position(start) else { return nil }
            self.init(start: start, end: Position(end))
        }

        /// Its lines, first to last.
        public var lines: ClosedRange<Int> { start.line...end.line }
    }

    /// Two of a pull request's iterations that a diff compares: `first` on its left, and `second` on its right. When
    /// they're the same, the left is the base: the commit where the pull request's branch left its target, as of
    /// `second`, which is what Azure DevOps shows unless asked to compare two iterations.
    public struct Comparison: Sendable, Codable, Equatable, Hashable {
        public var first: Int
        public var second: Int

        public init(first: Int, second: Int) {
            self.first = first
            self.second = second
        }

        /// With the base on the left: also when `first` is missing, as some apps that add threads leave it.
        public init(base second: Int) {
            self.init(first: second, second: second)
        }

        /// Nil without an iteration on the right.
        init?(left first: Int?, right second: Int?) {
            guard let second, second >= 1 else { return nil }
            self.init(first: first ?? second, second: second)
        }

        /// The left side is the base rather than an earlier iteration.
        public var isWithBase: Bool { first <= 0 || first == second }
    }

    /// Where on a file a thread is: the characters it's on, on either side of the diff it's in, which iterations that
    /// diff compares, and where it was made when Azure DevOps has since followed it to a later diff.
    public struct Location: Sendable, Codable, Equatable {
        /// The file, such as "/src/PaymentsClient.cs": after a rename, its new path.
        public var path: String
        /// On the file before the change, such as on lines the pull request removed.
        public var left: Span?
        /// On the file after the change.
        public var right: Span?
        /// The diff it was made on. Nil when Azure DevOps doesn't say, as for a thread an app added without it: Azure
        /// DevOps shows those on the latest iteration's diff with the base.
        public var madeOn: Comparison?
        /// The file across the pull request's iterations, as their lists of changes number it.
        public var changeTrackingId: Int?
        /// Set once Azure DevOps followed it to a later diff, as pushes moved its lines: then `path`, `left` and
        /// `right` are where it is in that diff.
        public var tracking: Tracking?

        public init(
            path: String, left: Span? = nil, right: Span? = nil, madeOn: Comparison? = nil, changeTrackingId: Int? = nil,
            tracking: Tracking? = nil
        ) {
            self.path = path
            self.left = left
            self.right = right
            self.madeOn = madeOn
            self.changeTrackingId = changeTrackingId
            self.tracking = tracking
        }

        /// Nil for a thread that isn't on a file.
        init?(_ context: ADOThread.ThreadContext?, _ pullRequest: ADOThread.PullRequestThreadContext?) {
            guard let path = context?.filePath, !path.isEmpty else { return nil }
            let made = pullRequest?.iterationContext
            self.init(
                path: path,
                left: Span(context?.leftFileStart, context?.leftFileEnd),
                right: Span(context?.rightFileStart, context?.rightFileEnd),
                madeOn: Comparison(left: made?.firstComparingIteration, right: made?.secondComparingIteration),
                changeTrackingId: pullRequest?.changeTrackingId.flatMap { $0 > 0 ? $0 : nil },
                tracking: pullRequest?.trackingCriteria.flatMap(Tracking.init)
            )
        }
    }

    /// The later diff Azure DevOps followed a thread to, and where it was before that: in the diff it was made on.
    public struct Tracking: Sendable, Codable, Equatable {
        public var to: Comparison
        /// The file's path where the thread was made, when it was renamed since.
        public var originalPath: String?
        public var originalLeft: Span?
        public var originalRight: Span?

        public init(to: Comparison, originalPath: String? = nil, originalLeft: Span? = nil, originalRight: Span? = nil) {
            self.to = to
            self.originalPath = originalPath
            self.originalLeft = originalLeft
            self.originalRight = originalRight
        }

        /// Nil unless it says which diff the thread was followed to: Azure DevOps followed it only then.
        init?(_ criteria: ADOThread.TrackingCriteria) {
            guard let to = Comparison(left: criteria.firstComparingIteration, right: criteria.secondComparingIteration) else {
                return nil
            }
            self.init(
                to: to,
                originalPath: criteria.origFilePath.flatMap { $0.isEmpty ? nil : $0 },
                originalLeft: Span(criteria.origLeftFileStart, criteria.origLeftFileEnd),
                originalRight: Span(criteria.origRightFileStart, criteria.origRightFileEnd)
            )
        }
    }
}
