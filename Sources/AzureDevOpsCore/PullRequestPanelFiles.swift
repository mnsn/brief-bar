import Foundation

// A pull request's comment threads by file, as its details list them, and what each says of itself: who it waits on, and
// which of its comments show before you unfold it.

extension PullRequestPanel {
    /// The threads on one of a pull request's files, or those on the pull request itself.
    public struct FileThreads: Sendable, Equatable, Identifiable {
        /// The file, such as "/src/PaymentsClient.cs"; nil for the threads on the pull request itself.
        public var path: String?
        public var threads: [Thread]

        public init(path: String?, threads: [Thread]) {
            self.path = path
            self.threads = threads
        }

        /// Its file as Git tells files apart, by its path's bytes: two paths that look the same, as "é" written as one
        /// character and as two, are two files.
        public var id: ID { ID(path: path.map(GitPath.init)) }

        public struct ID: Hashable, Sendable {
            /// Nil for the threads on the pull request itself.
            let path: GitPath?
        }

        /// "PaymentsClient.cs".
        public var name: String? {
            path.map { ($0 as NSString).lastPathComponent }
        }

        /// The folder it's in, without the slash before it: "src/Coupons"; nil at the top of the repository.
        public var folder: String? {
            guard let path else { return nil }
            let folder = (path as NSString).deletingLastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return folder.isEmpty ? nil : folder
        }
    }

    /// Whether one file comes before another as a change lists its files, as Azure DevOps' Files page does: folder by
    /// folder, each folder's folders before its files, by name, numbers in names by their value. Two paths Git tells
    /// apart are never in the same place: names that differ only in case, or in how their letters are written, go by
    /// their bytes.
    public static func listsFirst(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: "/", omittingEmptySubsequences: true)
        let right = rhs.split(separator: "/", omittingEmptySubsequences: true)
        for index in 0..<min(left.count, right.count) {
            let leftIsFolder = index < left.count - 1
            let rightIsFolder = index < right.count - 1
            if leftIsFolder != rightIsFolder { return leftIsFolder }
            // Case folded first, so that every pair compares the same way both ways round, as sorting needs: comparing
            // without case doesn't, for a name with "ß".
            let order = Self.folded(left[index]).compare(Self.folded(right[index]), options: .numeric)
            if order != .orderedSame { return order == .orderedAscending }
            // Names that differ only in case, in how their letters are written, as "é" in one character or two, or in
            // a number's zeros before it: by their bytes, which Swift's strings don't compare.
            if !left[index].utf8.elementsEqual(right[index].utf8) {
                return left[index].utf8.lexicographicallyPrecedes(right[index].utf8)
            }
        }
        if left.count != right.count { return left.count < right.count }
        // The same names, apart only in their slashes.
        return lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func folded(_ name: Substring) -> String {
        name.folding(options: .caseInsensitive, locale: nil)
    }
}

extension PullRequestPanel.Threads {
    /// The threads that wait on you and the other open ones, by file: those on the pull request itself first, then each
    /// file's, as a change lists its files (`PullRequestPanel.listsFirst`). In each, those that wait on you come first,
    /// then the others, from the top of the file down.
    public var openByFile: [PullRequestPanel.FileThreads] {
        arranged().open
    }

    /// The resolved ones, by file in the same way.
    public var resolvedByFile: [PullRequestPanel.FileThreads] {
        arranged().resolved
    }

    /// The threads by file, the open ones and the resolved ones apart, as the details list them while you change some of
    /// them there (`held`): each of those stays where it was as you first changed it, with the open ones or the resolved
    /// ones, with those that wait on you or not, and among them, by when something was said in it then, however it stands
    /// now, so it doesn't move away as you reply or resolve it.
    public func arranged(
        holding held: [Int: PullRequestPanel.Thread.Held] = [:]
    ) -> (open: [PullRequestPanel.FileThreads], resolved: [PullRequestPanel.FileThreads]) {
        func placement(_ thread: PullRequestPanel.Thread) -> PullRequestPanel.Thread.Placement {
            held[thread.id]?.placement ?? thread.placement
        }
        func date(_ thread: PullRequestPanel.Thread) -> Date? {
            if let kept = held[thread.id] { return kept.date }
            return thread.date
        }
        let all = all
        return (
            Self.byFile(all.filter { placement($0) != .resolved }, waitsFirst: { placement($0) == .waitingOnYou }, date: date),
            Self.byFile(all.filter { placement($0) == .resolved }, waitsFirst: { placement($0) == .waitingOnYou }, date: date)
        )
    }

    /// By file as Git tells files apart, by their paths' bytes, rather than as Swift's strings compare them; in each, those
    /// that `waitsFirst` first, then by line, then the latest first, by `date`.
    static func byFile(
        _ threads: [PullRequestPanel.Thread], waitsFirst: (PullRequestPanel.Thread) -> Bool = \.waitsOnYou,
        date: (PullRequestPanel.Thread) -> Date? = \.date
    ) -> [PullRequestPanel.FileThreads] {
        var general: [PullRequestPanel.Thread] = []
        var byPath: [GitPath: [PullRequestPanel.Thread]] = [:]
        for thread in threads {
            guard let path = thread.thread.filePath, !path.isEmpty else {
                general.append(thread)
                continue
            }
            byPath[GitPath(path), default: []].append(thread)
        }
        let files = byPath.sorted { PullRequestPanel.listsFirst($0.key.string, $1.key.string) }
            .map { file in
                PullRequestPanel.FileThreads(
                    path: file.key.string, threads: file.value.sorted { showsFirst($0, $1, waitsFirst: waitsFirst, date: date) }
                )
            }
        let onItself = general.sorted { showsFirst($0, $1, waitsFirst: waitsFirst, date: date) }
        return (general.isEmpty ? [] : [PullRequestPanel.FileThreads(path: nil, threads: onItself)]) + files
    }

    /// Those that wait on you first; then from the top of the file down, those on the whole file first; then the latest
    /// first.
    private static func showsFirst(
        _ lhs: PullRequestPanel.Thread, _ rhs: PullRequestPanel.Thread, waitsFirst: (PullRequestPanel.Thread) -> Bool,
        date: (PullRequestPanel.Thread) -> Date?
    ) -> Bool {
        if waitsFirst(lhs) != waitsFirst(rhs) { return waitsFirst(lhs) }
        let lhsLine = ThreadCode.span(of: lhs.thread)?.lines.lowerBound ?? lhs.thread.line ?? 0
        let rhsLine = ThreadCode.span(of: rhs.thread)?.lines.lowerBound ?? rhs.thread.line ?? 0
        if lhsLine != rhsLine { return lhsLine < rhsLine }
        let lhsDate = date(lhs), rhsDate = date(rhs)
        if lhsDate != rhsDate { return (lhsDate ?? .distantPast) > (rhsDate ?? .distantPast) }
        return lhs.id > rhs.id
    }
}

extension PullRequestPanel.Thread {
    /// Where the details list a thread: with those that wait on you, the other open ones, or the resolved ones.
    public enum Placement: Sendable, Hashable {
        case waitingOnYou, open, resolved
    }

    /// Where the details list it as it stands.
    public var placement: Placement {
        waitsOnYou ? .waitingOnYou : isResolved ? .resolved : .open
    }

    /// Where the details listed a thread as you first changed it there: with which ones, and when something was last said
    /// in it then, which orders it among them.
    public struct Held: Sendable, Hashable {
        public var placement: Placement
        public var date: Date?

        public init(placement: Placement, date: Date?) {
            self.placement = placement
            self.date = date
        }

        /// Where it is now.
        public init(_ thread: PullRequestPanel.Thread) {
            self.init(placement: thread.placement, date: thread.date)
        }
    }
    /// How many comments a thread has at most for all of them to show; past that, the first and the latest show, and those
    /// between them fold until you ask for them.
    public static let unfoldedComments = 3

    /// How many of its comments fold between the first and the latest.
    public var foldedComments: Int {
        comments.count > Self.unfoldedComments ? comments.count - 2 : 0
    }

    /// Who has to answer in an open thread that doesn't wait on you, for "Waiting on Sam": whom its latest comment asks,
    /// the first it mentions that BriefBar can name, of those who review the pull request or spoke in it; else, when
    /// someone else spoke last, the pull request's author; else, when its author did, whoever else spoke last in it. A
    /// person by their first name, and a team by its name. Nil once it's resolved, when it waits on you (`waitsOnYou`
    /// says so), when it's your turn though nothing waits on you there anymore, as when its latest comment asks you and
    /// you've removed it from Needs You, when it asks only people BriefBar can't name, and when nobody else spoke in it.
    public func waitingOn(in pullRequest: PullRequest, me: String?) -> String? {
        guard !isResolved, !waitsOnYou, let latest = comments.last else { return nil }
        let me = me?.lowercased()
        let author = pullRequest.author
        // Whom a mention names, of those who review it or spoke in it.
        var names: [String: String] = [:]
        for reviewer in pullRequest.reviewers {
            names[reviewer.person.id] = reviewer.isGroup ? PRReadiness.shortName(reviewer) : reviewer.person.firstName
        }
        names[author.id] = author.firstName
        for comment in comments {
            names[comment.author.id] = comment.author.firstName
        }
        // Whom the latest comment asks, but for its author: your turn when it's you, rather than anyone else's, and nobody's
        // BriefBar can say when it can't name them.
        let asked = latest.author.isBot ? [] : latest.mentions.filter { $0 != latest.author.id }
        if !asked.isEmpty {
            if let me, asked.contains(me) { return nil }
            return asked.lazy.compactMap { names[$0] }.first
        }
        let speakers = comments.map(\.author).filter { !$0.isBot }
        let waiter: Person?
        if let last = speakers.last, last.id == author.id {
            waiter = speakers.last { $0.id != author.id }
        } else {
            // Someone else spoke last, or only bots did.
            waiter = author
        }
        guard let waiter, waiter.id != me else { return nil }
        return names[waiter.id] ?? waiter.firstName
    }
}
