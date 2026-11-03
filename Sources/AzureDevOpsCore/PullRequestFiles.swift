import Foundation

// A pull request's whole change, file by file, as its details' Files show it: the files it touched, by folder, each
// one's diff, with its changes and a few lines around them, the rest folded, and its comment threads at their lines.
// `PullRequestCode` reads it (`changedFiles`, `diff`).

/// Which of a pull request's changes its Files show.
public enum ChangeScope: Hashable, Sendable {
    /// All of it: its latest update against where its branch left its target, as Azure DevOps' Files page shows it.
    case whole
    /// What the updates after this one changed: from it to the latest.
    case since(Int)
}

extension FileChange: Identifiable {
    /// A file as Git tells files apart, by its path's bytes: two paths that look the same, as "é" written as one
    /// character and as two, are two files.
    public struct ID: Hashable, Sendable {
        let path: GitPath

        public init(path: String) {
            self.path = GitPath(path)
        }
    }

    /// By its path after the change, which no other file in the same diff has.
    public var id: ID { ID(path: path) }

    /// "PaymentsClient.cs".
    public var name: String {
        (path as NSString).lastPathComponent
    }

    /// The folder it's in, without the slashes around it: "src/Payments"; nil at the top of the repository.
    public var folder: String? {
        Self.folder(of: path)
    }

    /// The same of a path.
    static func folder(of path: String) -> String? {
        let folder = (path as NSString).deletingLastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return folder.isEmpty ? nil : folder
    }

    /// What happened to it, in a word or a few: "Added", "Deleted", "Renamed from RetryPolicy.cs", "Renamed from
    /// src/RetryPolicy.cs and edited" when it moved to another folder and changed too, or "Edited".
    public var what: String {
        if kind.contains(.add) { return "Added" }
        if kind.contains(.delete) { return "Deleted" }
        if let originalPath {
            let sameFolder = Self.folder(of: originalPath).map(GitPath.init) == folder.map(GitPath.init)
            let before = sameFolder ? (originalPath as NSString).lastPathComponent
                : originalPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return "Renamed from " + before + (kind.contains(.edit) ? " and edited" : "")
        }
        return "Edited"
    }
}

/// How many lines a file's change adds and removes.
public struct LineCounts: Sendable, Hashable {
    public var added: Int
    public var removed: Int

    public init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }

    /// Of a diff's lines.
    public init(_ lines: [DiffLine]) {
        var added = 0
        var removed = 0
        for line in lines {
            switch line.kind {
            case .added: added += 1
            case .removed: removed += 1
            case .unchanged: break
            }
        }
        self.init(added: added, removed: removed)
    }

    /// "+12 −3", "+12", "−3", or "No changes to its lines" for a file renamed as it was.
    public var text: String {
        guard added > 0 || removed > 0 else { return "No changes to its lines" }
        return [added > 0 ? "+\(added)" : nil, removed > 0 ? "−\(removed)" : nil].compactMap { $0 }.joined(separator: " ")
    }

    /// "12 lines added, 3 removed", for VoiceOver and tooltips.
    public var spoken: String {
        func lines(_ count: Int) -> String { count == 1 ? "1 line" : "\(count) lines" }
        switch (added, removed) {
        case (0, 0): return "No lines added or removed"
        case (_, 0): return "\(lines(added)) added"
        case (0, _): return "\(lines(removed)) removed"
        default: return "\(lines(added)) added, \(removed) removed"
        }
    }
}

/// The files a pull request's change touched, as its details list them.
public struct ChangedFiles: Sendable, Equatable {
    /// The change they're of: the whole of it, or since an update.
    public var scope: ChangeScope
    /// The updates its diff compares: `second` the latest; `first` the same, for the whole change, against where its
    /// branch left its target, or the update it's since.
    public var comparison: ReviewThread.Comparison
    /// The pull request's updates, oldest first.
    public var iterations: [PRIteration]
    /// As Azure DevOps' Files page lists them, folder by folder (`PullRequestPanel.listsFirst`).
    public var files: [FileChange]
    /// False when it changed more files than BriefBar reads, and the rest aren't here.
    public var isComplete: Bool

    public init(
        scope: ChangeScope, comparison: ReviewThread.Comparison, iterations: [PRIteration], files: [FileChange], isComplete: Bool = true
    ) {
        self.scope = scope
        self.comparison = comparison
        self.iterations = iterations
        self.files = files.sorted { PullRequestPanel.listsFirst($0.path, $1.path) }
        self.isComplete = isComplete
    }

    public func file(_ id: FileChange.ID) -> FileChange? {
        files.first { $0.id == id }
    }

    /// The file at a path after the change, or else the one renamed from it, as a thread made before the rename names it.
    public func file(atPath path: String) -> FileChange? {
        let id = FileChange.ID(path: path)
        return file(id) ?? files.first { $0.originalPath.map(FileChange.ID.init(path:)) == id }
    }

    public func index(of id: FileChange.ID) -> Int? {
        files.firstIndex { $0.id == id }
    }

    /// The files in a folder, as the details list them: those right in it, under its path.
    public struct Folder: Sendable, Equatable, Identifiable {
        /// "src/Payments"; nil at the top of the repository.
        public var path: String?
        public var files: [FileChange]

        public var id: ID { ID(path: path.map(GitPath.init)) }

        public struct ID: Hashable, Sendable {
            let path: GitPath?
        }
    }

    /// The files by the folder they're right in, folder by folder as they're listed: a folder's folders, each with what
    /// it has, before its own files. A folder whose only content is another folder isn't listed apart: its path is part
    /// of that one's, "src/Payments/Retry".
    public var folders: [Folder] {
        var folders: [Folder] = []
        for file in files {
            let folder = file.folder
            if let last = folders.last, last.path.map(GitPath.init) == folder.map(GitPath.init) {
                folders[folders.count - 1].files.append(file)
            } else {
                folders.append(Folder(path: folder, files: [file]))
            }
        }
        return folders
    }

    /// The update you'd seen at `date`, when you last looked at the pull request: the latest pushed by then, as long as a
    /// later one came after it, for what changed since. Nil when you've seen them all, when none was pushed by then, and
    /// for an update Azure DevOps doesn't say the time of.
    public func lastSeenUpdate(at date: Date?) -> Int? {
        guard let date, let latest = iterations.last, let createdAt = latest.createdAt, createdAt > date else { return nil }
        return iterations.last { $0.createdAt.map { $0 <= date } ?? false }?.id
    }

    /// How many updates came after `iteration`: "2 updates".
    public func updates(since iteration: Int) -> Int {
        iterations.filter { $0.id > iteration }.count
    }

    /// The pull request's Files page in Azure DevOps at a file, with what this change changed in it.
    public func filePageURL(of file: FileChange, in pullRequest: PRSnapshot) -> URL {
        ADOEndpoint.pullRequestFilePage(
            organization: pullRequest.key.organization, project: pullRequest.project, repository: pullRequest.repository,
            id: pullRequest.key.number, path: file.path, iteration: comparison.second,
            base: comparison.isWithBase ? 0 : comparison.first
        )
    }
}

/// A file's change: its lines, as the diff compares its two versions, and how many it adds and removes.
public struct FileDiff: Sendable, Equatable {
    public var file: FileChange
    /// Every line of both versions, in order.
    public var lines: [DiffLine]
    public var counts: LineCounts

    public init(file: FileChange, lines: [DiffLine]) {
        self.file = file
        self.lines = lines
        counts = LineCounts(lines)
    }
}

// MARK: - Comment threads on a file

extension PullRequestPanel {
    /// The comment threads on one of a change's files, and how many of them are open and resolved.
    public struct FileComments: Sendable, Equatable {
        /// Those that wait on you first, then the other open ones, then the resolved ones; from the top of the file down in
        /// each.
        public var threads: [Thread]

        public init(threads: [Thread]) {
            self.threads = threads
        }

        public var open: Int { threads.filter { $0.waitsOnYou || !$0.isResolved }.count }
        public var resolved: Int { threads.count - open }
        public var waitingOnYou: Int { threads.filter(\.waitsOnYou).count }
        public var isEmpty: Bool { threads.isEmpty }

        /// "2 open comments, 1 resolved", "1 resolved comment", "No comments".
        public var spoken: String {
            func comments(_ count: Int, _ what: String) -> String {
                count == 1 ? "1 \(what) comment" : "\(count) \(what) comments"
            }
            switch (open, resolved) {
            case (0, 0): return "No comments"
            case (_, 0): return comments(open, "open") + (waitingOnYou > 0 ? ", \(waitingOnYou) waiting on you" : "")
            case (0, _): return comments(resolved, "resolved")
            default: return comments(open, "open") + (waitingOnYou > 0 ? ", \(waitingOnYou) waiting on you" : "") + ", \(resolved) resolved"
            }
        }
    }
}

extension PullRequestPanel.Threads {
    /// The threads on a file of the change: those Azure DevOps tracks on it, or else those on its path, after the change or
    /// before it. Those that wait on you first, then the other open ones, then the resolved ones; in each, from the top of
    /// the file down.
    public func comments(on file: FileChange) -> PullRequestPanel.FileComments {
        func onFile(_ threads: [PullRequestPanel.Thread]) -> [PullRequestPanel.Thread] {
            threads.filter { Self.isOn(file, $0.thread) }.sorted(by: Self.fromTheTop)
        }
        return PullRequestPanel.FileComments(threads: onFile(waitingOnYou) + onFile(open) + onFile(resolved))
    }

    /// The change's files with open threads, by their places among its files, each with its open threads from the top of
    /// the file down: those to go through, from one file's comments on to another's.
    public func openOnFiles(of changes: ChangedFiles) -> [(index: Int, threads: [PullRequestPanel.Thread])] {
        let open = all.filter { $0.waitsOnYou || !$0.isResolved }
        guard !open.isEmpty else { return [] }
        return changes.files.indices.compactMap { index in
            let onFile = open.filter { Self.isOn(changes.files[index], $0.thread) }.sorted(by: Self.fromTheTop)
            return onFile.isEmpty ? nil : (index, onFile)
        }
    }

    /// From the top of a file down: by the first line each is on, then in the order they were made.
    static func fromTheTop(_ lhs: PullRequestPanel.Thread, _ rhs: PullRequestPanel.Thread) -> Bool {
        func line(_ thread: PullRequestPanel.Thread) -> Int {
            ThreadCode.span(of: thread.thread)?.lines.lowerBound ?? thread.thread.line ?? 0
        }
        return line(lhs) != line(rhs) ? line(lhs) < line(rhs) : lhs.id < rhs.id
    }

    /// Whether a thread is on a file: its tracking ID, when both have one, says; else its path, as the file is now or as
    /// it was before a rename.
    static func isOn(_ file: FileChange, _ thread: ReviewThread) -> Bool {
        if let tracking = thread.location?.changeTrackingId, let fileTracking = file.changeTrackingId {
            return tracking == fileTracking
        }
        guard let path = (thread.location?.path ?? thread.filePath).flatMap({ $0.isEmpty ? nil : GitPath($0) }) else { return false }
        return path == GitPath(file.path) || file.originalPath.map(GitPath.init) == path
    }
}

extension FileDiff {
    /// Where a comment thread on this file shows in its diff, as `files` compares it: under the line it ends on, its index
    /// in `lines`. Nil for one on the whole file, and for one on lines of a version the diff doesn't show, as one made on
    /// an earlier update that Azure DevOps hasn't followed since, or on lines the file doesn't have.
    public func row(of thread: ReviewThread, in files: ChangedFiles) -> Int? {
        guard let span = Self.span(of: thread, latest: files.comparison.second) else { return nil }
        let shown = files.comparison
        switch span.side {
        case .right:
            // On the version after the change: the same as long as the diff's right side is the same update.
            guard span.comparison.second == shown.second else { return nil }
            return lines.firstIndex { $0.newNumber == span.lines.upperBound }
        case .left:
            // Before the change: the same diff.
            guard Self.same(span.comparison, shown) else { return nil }
            return lines.firstIndex { $0.oldNumber == span.lines.upperBound }
        }
    }

    /// The lines of this diff a thread is on, on the side it's on, by their indices in `lines`: for the lines it marks.
    public func rows(of thread: ReviewThread, in files: ChangedFiles) -> ClosedRange<Int>? {
        guard let last = row(of: thread, in: files), let span = Self.span(of: thread, latest: files.comparison.second) else { return nil }
        let number: (DiffLine) -> Int? = span.side == .right ? { $0.newNumber } : { $0.oldNumber }
        let first = lines[...last].lastIndex { number($0) == span.lines.lowerBound } ?? last
        return first...last
    }

    /// Where a thread is now: in the diff Azure DevOps followed it to, or else the one it was made on, or, when it doesn't
    /// say, the latest update's with the base; its lines, on the file after the change, or else before it.
    static func span(
        of thread: ReviewThread, latest: Int
    ) -> (comparison: ReviewThread.Comparison, lines: ClosedRange<Int>, side: ThreadExcerpt.Side)? {
        guard let location = thread.location else {
            // Without its location, as the demo's threads: its line, after the change, in the latest diff.
            guard let path = thread.filePath, !path.isEmpty, let line = thread.line, line >= 1 else { return nil }
            return (ReviewThread.Comparison(base: latest), line...line, .right)
        }
        let comparison = location.tracking?.to ?? location.madeOn ?? ReviewThread.Comparison(base: latest)
        if let right = location.right { return (comparison, right.lines, .right) }
        if let left = location.left { return (comparison, left.lines, .left) }
        return nil
    }

    /// Whether two diffs compare the same versions: both with the base of the same update, or the same two updates.
    static func same(_ lhs: ReviewThread.Comparison, _ rhs: ReviewThread.Comparison) -> Bool {
        lhs.second == rhs.second && (lhs.isWithBase ? rhs.isWithBase : !rhs.isWithBase && lhs.first == rhs.first)
    }
}

// MARK: - What a diff shows

/// What a file's diff shows: its changed lines and a few around them, the lines comment threads are on and a few around
/// those, and the lines you unfolded; the rest folded, a few at a time to unfold, or all at once.
public enum DiffLayout {
    /// How many unchanged lines show before and after a change.
    public static let context = 3
    /// How many lines unfolding shows at a time.
    public static let unfoldStep = 20

    /// A run of a diff's lines, by their indices.
    public enum Block: Sendable, Equatable, Hashable {
        case lines(Range<Int>)
        case folded(Range<Int>)
    }

    /// How to unfold a run of folded lines.
    public enum Unfold: Sendable, Equatable {
        /// All of them.
        case all
        /// Its last ones, up from the lines under it.
        case up(Int)
        /// Its first ones, down from the lines above it.
        case down(Int)
    }

    /// The diff's lines in runs, shown or folded: those within `context` of a change or an anchor, such as a line a thread
    /// is on, show, and so do those in `revealed`; the rest fold, but for a single line between shown ones, which takes no
    /// more room shown. A shown run ends at each of `breaks`, for what shows under that line, such as a thread.
    public static func blocks(
        of lines: [DiffLine], context: Int = context, anchors: [Int] = [], revealed: IndexSet = [], breaks: Set<Int> = []
    ) -> [Block] {
        guard !lines.isEmpty else { return [] }
        let context = max(0, context)
        var shown = IndexSet(revealed.filter { $0 >= 0 && $0 < lines.count })
        func show(around index: Int) {
            shown.insert(integersIn: max(0, index - context)..<min(lines.count, index + context + 1))
        }
        for index in lines.indices where lines[index].kind != .unchanged { show(around: index) }
        for anchor in anchors where lines.indices.contains(anchor) { show(around: anchor) }
        // A fold of one line takes as much room as the line.
        var blocks: [Block] = []
        var start = 0
        while start < lines.count {
            let isShown = shown.contains(start)
            var end = start + 1
            while end < lines.count, shown.contains(end) == isShown { end += 1 }
            if isShown || end - start < 2 {
                blocks.append(.lines(start..<end))
            } else {
                blocks.append(.folded(start..<end))
            }
            start = end
        }
        // Shown runs that a single line's fold joined, as one; then each ended at its breaks.
        var joined: [Block] = []
        for block in blocks {
            if case .lines(let range) = block, case .lines(let previous)? = joined.last {
                joined[joined.count - 1] = .lines(previous.lowerBound..<range.upperBound)
            } else {
                joined.append(block)
            }
        }
        return joined.flatMap { block -> [Block] in
            guard case .lines(let range) = block else { return [block] }
            var pieces: [Block] = []
            var from = range.lowerBound
            for index in range where breaks.contains(index) && index + 1 < range.upperBound {
                pieces.append(.lines(from..<(index + 1)))
                from = index + 1
            }
            pieces.append(.lines(from..<range.upperBound))
            return pieces
        }
    }

    /// `revealed` with more of a fold's lines in it, as `unfold` says.
    public static func reveal(_ fold: Range<Int>, _ unfold: Unfold, in revealed: IndexSet) -> IndexSet {
        var revealed = revealed
        switch unfold {
        case .all:
            revealed.insert(integersIn: fold)
        case .up(let count):
            revealed.insert(integersIn: max(fold.lowerBound, fold.upperBound - max(0, count))..<fold.upperBound)
        case .down(let count):
            revealed.insert(integersIn: fold.lowerBound..<min(fold.upperBound, fold.lowerBound + max(0, count)))
        }
        return revealed
    }
}
