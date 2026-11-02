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

        public var id: String { path.map { "file \($0)" } ?? "pull request" }

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
    /// folder, each folder's folders before its files, by name, numbers in names by their value.
    public static func listsFirst(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: "/", omittingEmptySubsequences: true)
        let right = rhs.split(separator: "/", omittingEmptySubsequences: true)
        for index in 0..<min(left.count, right.count) {
            let leftIsFolder = index < left.count - 1
            let rightIsFolder = index < right.count - 1
            if leftIsFolder != rightIsFolder { return leftIsFolder }
            let order = left[index].compare(right[index], options: [.caseInsensitive, .numeric])
            if order != .orderedSame { return order == .orderedAscending }
            // Names that differ only in case, by their letters' code.
            if left[index] != right[index] { return left[index] < right[index] }
        }
        return left.count < right.count
    }
}

extension PullRequestPanel.Threads {
    /// The threads that wait on you and the other open ones, by file: those on the pull request itself first, then each
    /// file's, as a change lists its files (`PullRequestPanel.listsFirst`). In each, those that wait on you come first,
    /// then the others, from the top of the file down.
    public var openByFile: [PullRequestPanel.FileThreads] {
        Self.byFile(waitingOnYou + open)
    }

    /// The resolved ones, by file in the same way.
    public var resolvedByFile: [PullRequestPanel.FileThreads] {
        Self.byFile(resolved)
    }

    static func byFile(_ threads: [PullRequestPanel.Thread]) -> [PullRequestPanel.FileThreads] {
        var byPath: [String?: [PullRequestPanel.Thread]] = [:]
        for thread in threads {
            let path = thread.thread.filePath.flatMap { $0.isEmpty ? nil : $0 }
            byPath[path, default: []].append(thread)
        }
        let paths = byPath.keys.compactMap { $0 }.sorted(by: PullRequestPanel.listsFirst)
        let general = byPath[nil].map { [PullRequestPanel.FileThreads(path: nil, threads: $0.sorted(by: showsFirst))] } ?? []
        return general + paths.map { PullRequestPanel.FileThreads(path: $0, threads: (byPath[$0] ?? []).sorted(by: showsFirst)) }
    }

    /// Those that wait on you first; then from the top of the file down, those on the whole file first; then the latest
    /// first.
    private static func showsFirst(_ lhs: PullRequestPanel.Thread, _ rhs: PullRequestPanel.Thread) -> Bool {
        if lhs.waitsOnYou != rhs.waitsOnYou { return lhs.waitsOnYou }
        let lhsLine = ThreadCode.span(of: lhs.thread)?.lines.lowerBound ?? lhs.thread.line ?? 0
        let rhsLine = ThreadCode.span(of: rhs.thread)?.lines.lowerBound ?? rhs.thread.line ?? 0
        if lhsLine != rhsLine { return lhsLine < rhsLine }
        if lhs.date != rhs.date { return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast) }
        return lhs.id > rhs.id
    }
}

extension PullRequestPanel.Thread {
    /// How many comments a thread has at most for all of them to show; past that, the first and the latest show, and those
    /// between them fold until you ask for them.
    public static let unfoldedComments = 3

    /// How many of its comments fold between the first and the latest.
    public var foldedComments: Int {
        comments.count > Self.unfoldedComments ? comments.count - 2 : 0
    }

    /// Who has to answer in an open thread that doesn't wait on you, for "Waiting on Sam": the person its latest comment
    /// mentions; else, when someone else spoke last, the pull request's author; else, when its author did, whoever else
    /// spoke last in it. A person by their first name, and a team by its name. Nil once it's resolved, when it waits on
    /// you (`waitsOnYou` says so), when it's your turn though nothing waits on you there anymore, and when nobody else
    /// spoke in it.
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
        if !latest.author.isBot,
           let mentioned = latest.mentions.first(where: { $0 != latest.author.id && $0 != me && names[$0] != nil }) {
            return names[mentioned]
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
