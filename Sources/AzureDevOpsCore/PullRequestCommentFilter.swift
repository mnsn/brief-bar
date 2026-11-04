import Foundation

// Which of a pull request's comment threads its details show, as you choose: all of them, or only the active ones; and
// what that leaves out.

extension PullRequestPanel {
    /// Which comment threads a pull request's details show, as you choose in their Comments' heading, for every pull
    /// request: all of them, the resolved ones folded until you ask; or only the active ones. What's Left, Needs You and the
    /// lists' rows count them all the same.
    public enum CommentFilter: String, Sendable, CaseIterable {
        /// Only those whose status is active or pending.
        case active
        case all
    }

    /// A pull request's comment threads as its details list them with a filter (`Threads.listed(_:holding:)`): what shows,
    /// by file, and what's left out.
    public struct CommentListing: Sendable, Equatable {
        /// Those that wait on you and the other open ones, by file; with Active, every thread that shows.
        public var open: [FileThreads]
        /// The resolved ones, by file, folded until you ask: with All only.
        public var resolved: [FileThreads]
        /// Every thread that shows, wherever.
        public var shown: Threads
        /// Those it leaves out: with Active, the closed, fixed, won't fix and by design ones, even those that wait on you.
        public var hidden: Threads
        /// How many the Comments' heading counts: with All, those that are open or wait on you; with Active, those that show
        /// and are active or pending.
        public var count: Int

        public init(open: [FileThreads], resolved: [FileThreads], shown: Threads, hidden: Threads, count: Int) {
            self.open = open
            self.resolved = resolved
            self.shown = shown
            self.hidden = hidden
            self.count = count
        }

        /// "4 closed or resolved comments hidden", "1 closed or resolved comment hidden"; nil when none is.
        public var hiddenSentence: String? {
            Self.hiddenSentence(hidden.all.count)
        }

        /// The same, for `count` of them, such as those on one file.
        public static func hiddenSentence(_ count: Int) -> String? {
            switch count {
            case ..<1: nil
            case 1: "1 closed or resolved comment hidden"
            default: "\(count) closed or resolved comments hidden"
            }
        }
    }
}

extension PullRequestPanel.Thread.Held {
    /// Where the details keep threads while they show a pull request: those you changed there, with your reply or their
    /// status (`changed`), each where it was as you first did, and those you marked as read there (`read`), where each was
    /// then, unless you changed it first.
    public static func kept(changed: [Int: Self], read: [Int: Self]) -> [Int: Self] {
        read.merging(changed) { _, changed in changed }
    }

    /// Where a thread you change in the details stays: where it was as you first changed it, or as you marked it as read
    /// there, before; else where it is now.
    public static func holding(_ thread: PullRequestPanel.Thread, changed: [Int: Self], read: [Int: Self]) -> Self {
        changed[thread.id] ?? read[thread.id] ?? Self(thread)
    }
}

extension PullRequestPanel.Threads {
    /// The threads as the details list them with `filter`, while you change some of them there (`held`). With All, as
    /// `arranged(holding:)` arranges them, the resolved ones apart. With Active, only those whose status is active or
    /// pending, by file in the same way, leaving out the resolved ones, even those that wait on you, and their fold. A thread
    /// you changed in the details stays where it was, however it stands now, unless it was among the resolved ones then and
    /// still is; and one you were taken to (`revealing`), such as from a notification, shows whatever its status.
    public func listed(
        _ filter: PullRequestPanel.CommentFilter, holding held: [Int: PullRequestPanel.Thread.Held] = [:], revealing: Set<Int> = []
    ) -> PullRequestPanel.CommentListing {
        guard filter == .active else {
            let arranged = arranged(holding: held)
            return .init(open: arranged.open, resolved: arranged.resolved, shown: self, hidden: Self(), count: unresolvedCount)
        }
        func shows(_ thread: PullRequestPanel.Thread) -> Bool {
            if revealing.contains(thread.id) { return true }
            guard let kept = held[thread.id] else { return !thread.isResolved }
            return kept.placement != .resolved || !thread.isResolved
        }
        func placement(_ thread: PullRequestPanel.Thread) -> PullRequestPanel.Thread.Placement {
            held[thread.id]?.placement ?? thread.placement
        }
        func date(_ thread: PullRequestPanel.Thread) -> Date? {
            if let kept = held[thread.id] { return kept.date }
            return thread.date
        }
        let shown = Self(waitingOnYou: waitingOnYou.filter(shows), open: open.filter(shows), resolved: resolved.filter(shows))
        let hidden = Self(
            waitingOnYou: waitingOnYou.filter { !shows($0) }, open: open.filter { !shows($0) }, resolved: resolved.filter { !shows($0) }
        )
        return .init(
            open: Self.byFile(shown.all, waitsFirst: { placement($0) == .waitingOnYou }, date: date), resolved: [], shown: shown,
            hidden: hidden, count: shown.all.filter { !$0.isResolved }.count
        )
    }
}
