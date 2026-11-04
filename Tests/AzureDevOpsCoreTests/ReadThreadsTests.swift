import Foundation
import Testing
@testable import AzureDevOpsCore

/// A comment thread you mark as read doesn't wait on you anymore, up to its latest comment, whatever its status and your
/// part in the pull request; a newer comment in it does again. BriefBar keeps the marks with what you've seen, and the
/// details can show only the active threads.
@Suite struct ReadThreadsTests {
    private let me = People.me
    /// Seen up to three days ago, as on BriefBar's first run.
    private let cutoff = t(-3 * day)

    private func classify(
        _ pr: PullRequest, role: PRRole = .author, threads: [ReviewThread], seen: Date? = nil, read: [Int: Date] = [:]
    ) -> PRSnapshot? {
        let checks = [Check(name: "CI", kind: .build, state: .passed), Check(name: "Minimum number of reviewers", kind: .reviewers, state: .passed)]
        return PRClassifier.snapshot(
            for: PRRecord(pullRequest: pr, role: role, details: makeDetails(for: pr, checks: checks, threads: threads), me: me.id),
            seenCutoff: seen ?? cutoff, dismissedCutoff: cutoff, read: read, now: t(0)
        )
    }

    /// Someone's comment that waits on you, as each role has one.
    struct Example: Sendable, CustomTestStringConvertible {
        var role: PRRole
        var kind: PREvent.Kind

        var testDescription: String { "\(kind.rawValue) on a pull request as \(role.rawValue)" }

        /// Yours, one you review, and one sent to you that you're not on; comments between others don't wait on you as a
        /// reviewer.
        static let all = [
            Example(role: .author, kind: .comment), Example(role: .author, kind: .reply), Example(role: .author, kind: .mention),
            Example(role: .reviewer, kind: .reply), Example(role: .reviewer, kind: .mention),
            Example(role: .linked, kind: .reply), Example(role: .linked, kind: .mention),
        ]

        var pullRequest: PullRequest {
            role == .author ? makePR() : makePR(author: People.alex, reviewers: role == .reviewer ? [Reviewer(person: People.me, vote: .approved)] : [])
        }

        func thread(status: String) -> ReviewThread {
            switch kind {
            case .mention:
                ReviewThread(id: 5, status: status, comments: [
                    comment(1, People.priya, "@Robin Diaz thoughts?", at: t(-hour), mentions: [People.me]),
                ])
            case .reply:
                ReviewThread(id: 5, status: status, comments: [
                    comment(1, People.me, "Should this retry?", at: t(-2 * hour)), comment(2, People.sam, "It does, see line 40", at: t(-hour)),
                ])
            default:
                ReviewThread(id: 5, status: status, comments: [comment(1, People.sam, "Updated the description with a summary.", at: t(-hour))])
            }
        }
    }

    /// Up to its latest comment, in an open thread or a resolved one, whether you've seen it or not: the pull request leaves
    /// Needs You, and one you're not on leaves your lists.
    @Test(arguments: Example.all)
    func aThreadMarkedAsReadDoesntWaitOnYou(_ example: Example) throws {
        let pr = example.pullRequest
        for status in ["active", "closed"] {
            // A resolved thread waits on you only while it's new.
            for seen in status == "active" ? [cutoff, t(-30 * minute)] : [cutoff] {
                let waiting = example.thread(status: status)
                let before = try #require(classify(pr, role: example.role, threads: [waiting], seen: seen))
                #expect(before.group == .needsYou, "\(status)")
                #expect(before.events.map(\.kind) == [example.kind], "\(status)")
                let latest = try #require(waiting.comments.last?.publishedAt)
                let read = classify(pr, role: example.role, threads: [waiting], seen: seen, read: [waiting.id: latest])
                #expect(read?.events.contains { $0.threadId == waiting.id } != true, "\(status)")
                if example.role == .linked {
                    #expect(read == nil, "\(status)")
                } else {
                    #expect(read?.group != .needsYou, "\(status)")
                }
            }
        }
    }

    /// A comment after what you marked as read waits on you again, as new; what came before it doesn't.
    @Test(arguments: Example.all)
    func aNewerCommentWaitsOnYouAgain(_ example: Example) throws {
        var thread = example.thread(status: "active")
        let read = [thread.id: try #require(thread.comments.last?.publishedAt)]
        let more = example.kind == .mention
            ? comment(9, People.sam, "@Robin Diaz ping", at: t(-minute), mentions: [People.me])
            : comment(9, People.sam, "Ping", at: t(-minute))
        thread.comments.append(more)
        let again = try #require(classify(example.pullRequest, role: example.role, threads: [thread], seen: t(-30 * minute), read: read))
        #expect(again.group == .needsYou)
        #expect(again.hasNews)
        #expect(again.events.map(\.id) == ["c5.9"])
    }

    /// Marked up to an earlier comment, only that one and those before it don't wait on you.
    @Test func onlyWhatItSaidUpToThenIsRead() throws {
        let thread = ReviewThread(id: 5, comments: [
            comment(1, People.sam, "Nit: typo", at: t(-2 * hour)), comment(2, People.sam, "And another", at: t(-hour)),
        ])
        let snapshot = try #require(classify(makePR(), threads: [thread], read: [5: t(-2 * hour)]))
        #expect(snapshot.events.map(\.id) == ["c5.2"])
    }

    /// Another thread's mark leaves this one waiting on you.
    @Test func onlyThatThreadIsRead() throws {
        let threads = [
            ReviewThread(id: 5, comments: [comment(1, People.sam, "Nit: typo", at: t(-hour))]),
            ReviewThread(id: 6, status: "closed", comments: [comment(1, People.priya, "Updated the description.", at: t(-2 * hour))]),
        ]
        let snapshot = try #require(classify(makePR(), threads: threads, read: [6: t(-2 * hour)]))
        #expect(snapshot.group == .needsYou)
        #expect(snapshot.events.map(\.threadId) == [5])
        #expect(snapshot.headline == "Sam Rivera commented")
    }

    // MARK: Kept with what you've seen

    @Test func keepsWhatEachThreadWasReadUpTo() throws {
        var seen = SeenState(baseline: cutoff)
        let key = PRKey("Contoso", 7)
        seen.markRead(5, of: key, upTo: t(-hour))
        // An earlier time doesn't take it back; spelled another way, it's the same pull request.
        seen.markRead(5, of: PRKey("contoso", 7), upTo: t(-2 * hour))
        #expect(seen.readThreads(of: PRKey("CONTOSO", 7)) == [5: t(-hour)])
        #expect(seen.readThreads(of: PRKey("contoso", 8)).isEmpty)
        // Mark as Unread puts it back as it was.
        seen.setRead(5, of: key, to: t(-3 * hour))
        #expect(seen.readThreads(of: key) == [5: t(-3 * hour)])
        seen.setRead(5, of: key, to: nil)
        #expect(seen.readThreads.isEmpty)

        seen.markRead(5, of: key, upTo: t(-hour))
        seen.markRead(6, of: key, upTo: t(-minute))
        #expect(try JSONDecoder().decode(SeenState.self, from: JSONEncoder().encode(seen)) == seen)
    }

    /// What earlier builds saved has no marks; and threads that aren't named by a number, which another program could have
    /// written there, are left out, never what you've seen.
    @Test func readsWhatEarlierBuildsAndOtherProgramsSaved() throws {
        func decode(_ json: String) throws -> SeenState {
            try JSONDecoder().decode(SeenState.self, from: Data(json.utf8))
        }
        let earlier = try decode(#"{"baseline":0,"seenAt":{"contoso/7":10},"dismissedAt":{}}"#)
        #expect(earlier.readThreads.isEmpty)
        #expect(earlier.seenAt["contoso/7"] == Date(timeIntervalSinceReferenceDate: 10))

        let odd = try decode(#"{"baseline":0,"seenAt":{"contoso/7":10},"readThreads":{"Contoso/7":{"5":20,"five":30},"contoso/8":{}}}"#)
        #expect(odd.readThreads == ["contoso/7": [5: Date(timeIntervalSinceReferenceDate: 20)]])
        for broken in [#""nope""#, #"{"contoso/7":{"5":"soon"}}"#, #"{"contoso/7":[1,2]}"#] {
            let read = try decode(#"{"baseline":0,"seenAt":{"contoso/7":10},"readThreads":"# + broken + "}")
            #expect(read.readThreads.isEmpty, "\(broken)")
            #expect(read.seenAt["contoso/7"] == Date(timeIntervalSinceReferenceDate: 10), "\(broken)")
        }
    }

    /// Forgotten with when you last looked at their pull request, and kept while it's listed.
    @Test func forgetsTheMarksWithWhatYouSaw() {
        var seen = SeenState(baseline: t(-100 * day))
        let listed = PRKey("contoso", 7), gone = PRKey("contoso", 8), recent = PRKey("contoso", 9), unseen = PRKey("contoso", 10)
        seen.markSeen([listed, gone], at: t(-90 * day))
        seen.markSeen([recent], at: t(-day))
        for key in [listed, gone, recent, unseen] {
            seen.markRead(5, of: key, upTo: t(-95 * day))
        }
        seen.prune(keeping: [listed], olderThan: t(-60 * day))
        #expect(seen.readThreads(of: listed) == [5: t(-95 * day)])
        #expect(seen.readThreads(of: gone).isEmpty)
        #expect(seen.readThreads(of: recent) == [5: t(-95 * day)])
        #expect(seen.readThreads(of: unseen).isEmpty)

        let inMemory = SeenState.pruned(
            seenAt: ["contoso/7": t(-day)], dismissedAt: [:], readThreads: ["contoso/7": [5: t(-day)], "contoso/8": [5: t(-day)]],
            keeping: [], olderThan: t(-60 * day)
        )
        #expect(inMemory.readThreads == ["contoso/7": [5: t(-day)]])
    }

    // MARK: Active or all of them

    /// Each said in an hour earlier than the one before it.
    private func thread(_ id: Int, _ status: String, waits: Bool = false) -> PullRequestPanel.Thread {
        PullRequestPanel.Thread(
            thread: ReviewThread(id: id, status: status, comments: [comment(1, People.sam, "Comment \(id)", at: t(-Double(id) * hour))]),
            waitsOnYou: waits, isNew: waits
        )
    }

    private var threads: PullRequestPanel.Threads {
        PullRequestPanel.Threads(
            waitingOnYou: [thread(1, "active", waits: true), thread(4, "closed", waits: true)],
            open: [thread(2, "active"), thread(3, "pending")],
            resolved: [thread(5, "fixed"), thread(6, "wontFix"), thread(7, "byDesign")]
        )
    }

    /// All, as the details always listed them; Active, only those whose status is active or pending, without the resolved
    /// ones, even one that waits on you, and their fold, saying how many it hides.
    @Test func activeShowsOnlyTheActiveThreadsAndSaysHowManyItHides() {
        let threads = threads
        let all = threads.listed(.all)
        #expect(all.open == threads.arranged().open && all.resolved == threads.arranged().resolved)
        #expect(all.shown == threads && all.hidden.isEmpty)
        #expect(all.count == 4)
        #expect(all.hiddenSentence == nil)

        let active = threads.listed(.active)
        #expect(active.open.flatMap(\.threads).map(\.id) == [1, 2, 3])
        #expect(active.resolved.isEmpty)
        #expect(Set(active.shown.all.map(\.id)) == [1, 2, 3])
        #expect(Set(active.hidden.all.map(\.id)) == [4, 5, 6, 7])
        #expect(active.count == 3)
        #expect(active.hiddenSentence == "4 closed or resolved comments hidden")
        #expect(PullRequestPanel.CommentListing.hiddenSentence(1) == "1 closed or resolved comment hidden")
        #expect(PullRequestPanel.CommentListing.hiddenSentence(0) == nil)
        #expect(PullRequestPanel.Threads(open: [thread(2, "active")]).listed(.active).hiddenSentence == nil)
    }

    /// With Active too, a thread you changed in the details stays where it was while they show it, unless it was resolved
    /// then and still is; and one they were taken to shows, whatever its status.
    @Test func whatYouChangeOrGoToStaysWithActive() {
        let threads = threads
        // You resolved 2 there, and marked 4 as read: both where they were, as before, though resolved now.
        var changed = threads
        changed.open.removeAll { $0.id == 2 }
        changed.waitingOnYou.removeAll { $0.id == 4 }
        changed.resolved += [thread(2, "fixed"), thread(4, "closed")]
        let held: [Int: PullRequestPanel.Thread.Held] = [
            2: .init(threads.open[0]), 4: .init(threads.waitingOnYou[1]), 5: .init(threads.resolved[0]),
        ]
        let active = changed.listed(.active, holding: held)
        #expect(active.open.flatMap(\.threads).map(\.id) == [1, 4, 2, 3])
        #expect(Set(active.hidden.all.map(\.id)) == [5, 6, 7])
        // Those it counts are active or pending.
        #expect(active.count == 2)

        // Taken to 6, from a notification.
        let revealed = threads.listed(.active, revealing: [6])
        #expect(revealed.shown.all.contains { $0.id == 6 })
        #expect(revealed.hiddenSentence == "3 closed or resolved comments hidden")
    }
}
