import Foundation
import Testing
@testable import AzureDevOpsCore
import BriefBarCore

/// What Copilot is told about a pull request: the comments word for word, where its build failed, and what it may
/// change.
@Suite struct PullRequestPromptTests {
    private let threads = [
        ReviewThread(id: 7, filePath: "/src/Checkout/Total.cs", line: 42, comments: [
            comment(1, People.me, "Rounded half up.", at: t(-2 * hour)),
            comment(2, People.sam, "Could we round half to even?", at: t(-hour)),
        ]),
        ReviewThread(id: 9, comments: [comment(1, People.priya, "Please add a test.", at: t(-hour))]),
        // Answered by you last: not waiting on you.
        ReviewThread(id: 11, filePath: "/README.md", comments: [
            comment(1, People.sam, "Typo?", at: t(-3 * hour)), comment(2, People.me, "Fixed.", at: t(-2 * hour)),
        ]),
        ReviewThread(id: 12, status: "fixed", comments: [comment(1, People.sam, "Done", at: t(-hour))]),
    ]

    private func record(role: PRRole = .author, threads: [ReviewThread]? = nil, activity: [Activity] = []) -> PRRecord {
        let pr = makePR(4071, author: role == .author ? People.me : People.alex)
        return PRRecord(pullRequest: pr, role: role, details: makeDetails(for: pr, threads: threads ?? self.threads, activity: activity),
                        me: People.me.id)
    }

    @Test func fixCommentsQuotesTheThreadsThatWaitOnYou() {
        let prompt = PullRequestPrompt.fixComments(record())
        #expect(prompt.hasPrefix("Pull request !4071 “Fix the checkout total” in shop-web, from fix-total into main:"))
        #expect(prompt.contains("detached at origin/fix-total"))
        #expect(prompt.contains("""
            1. src/Checkout/Total.cs, line 42 (thread 7)
               You: Rounded half up.
               Sam Rivera: Could we round half to even?
            2. General comment (thread 9)
               Priya Shah: Please add a test.
            """))
        #expect(!prompt.contains("thread 11"))
        #expect(!prompt.contains("thread 12"))
        #expect(prompt.contains("Don't commit, push or reply on the pull request"))
    }

    @Test func withoutThreadsWaitingOnYouItTakesEveryUnresolvedOne() {
        let answered = [threads[2]]
        #expect(PullRequestPrompt.waitingThreads(record(threads: answered)).map(\.id) == [11])
        #expect(PullRequestPrompt.waitingThreads(record(threads: [threads[3]])).isEmpty)
    }

    @Test func fixBuildSaysWhereEachBuildFailedAndItsErrors() {
        let url = URL(string: "https://dev.azure.com/contoso/Shop/_build/results?buildId=41")!
        let prompt = PullRequestPrompt.fixBuild(record(), failures: [FailedBuildReport(
            name: "web-ci", buildId: 41, url: url, failure: PipelineFailure(stage: "Test", step: "Run unit tests", message: "2 failed."),
            errors: ["2 failed.", "CheckoutTests.Rounds: expected 3"]
        )])
        #expect(prompt.contains("""
            1. web-ci: https://dev.azure.com/contoso/Shop/_build/results?buildId=41
               Failed in Test, at Run unit tests.
               - 2 failed.
               - CheckoutTests.Rounds: expected 3
            """))
        #expect(prompt.contains("Don't queue, retry or change pipelines. Don't commit or push"))
        #expect(PullRequestPrompt.fixBuild(record(), failures: []).contains("couldn't tell which run"))
    }

    @Test func reviewReadsTheDiffAndChangesNothing() {
        // Nothing of yours on it yet.
        let first = PullRequestPrompt.review(record(role: .reviewer, threads: [threads[1]]))
        #expect(first.contains("git diff origin/main...HEAD"))
        #expect(first.contains("Don't change any file, and don't comment, vote or push."))
        #expect(!first.contains("You reviewed it before"))
        #expect(first.contains("1. General comment (thread 9)\n   Priya Shah: Please add a test."))
        // Your comments count as reviewing it, as your votes do.
        #expect(PullRequestPrompt.review(record(role: .reviewer)).contains("You reviewed it before"))
        let vote = Activity(threadId: 30, kind: .vote, at: t(-day), actor: People.me, vote: .waitingForAuthor)
        let again = PullRequestPrompt.review(record(role: .reviewer, threads: [], activity: [vote]))
        #expect(again.contains("You reviewed it before"))
        #expect(again.contains("(none)"))
    }

    @Test func onlyPushAndReplyPushesAndWritesOnThePullRequest() {
        let ship = PullRequestPrompt.pushAndReply(record())
        #expect(ship.contains("git push origin HEAD:refs/heads/fix-total"))
        #expect(ship.contains("without force"))
        #expect(ship.contains("Don't complete, approve or abandon the pull request"))
        // The latest comment of each thread, for reference.
        #expect(ship.contains("1. src/Checkout/Total.cs, line 42 (thread 7)\n   Sam Rivera: Could we round half to even?"))
        #expect(ship.contains("1. Make sure it builds"))
        #expect(ship.contains("If that's rejected, rebase on origin/fix-total first"))
        let conflicts = PullRequestPrompt.resolveConflicts(record())
        #expect(conflicts.contains("Fetch origin/main, merge it into this worktree"))
        #expect(conflicts.contains("Don't push"))
    }

    /// An agent may be on another branch, or have other work in its checkout: it checks before it ships, and never rebases.
    @Test func anAgentChecksWhereItIsBeforeItPushes() {
        let ship = PullRequestPrompt.pushAndReply(record(), workplace: .agent)
        #expect(ship.contains("in your checkout:"))
        #expect(ship.contains("1. First make sure it's safe: this must be a clone of shop-web"))
        #expect(ship.contains("git merge-base --is-ancestor origin/fix-total HEAD"))
        #expect(ship.contains("stop and ask me before you commit or push anything"))
        #expect(ship.contains("2. Make sure it builds"))
        #expect(ship.contains("If that's rejected, stop and tell me: don't rebase, merge or force."))
        #expect(!ship.contains("rebase on origin"))
        #expect(!ship.contains("worktree"))
    }

    @Test func listsEveryErrorInARunsTimelineOnce() throws {
        let timeline = try Fixture.decode(ADOTimeline.self, WorkFixture.timeline([
            WorkFixture.record("t2", "Task", "Publish", result: "failed", finished: t(-minute), issues: [["type": "error", "message": "##[error]Later"]]),
            WorkFixture.record("t1", "Task", "Test", result: "failed", finished: t(-2 * minute), issues: [
                ["type": "warning", "message": "Slow"], ["type": "error", "message": "First"], ["type": "error", "message": "First"],
            ]),
            WorkFixture.record("j", "Job", "Job", result: "failed", issues: [["type": "error", "message": "Job failed"]]),
        ]))
        #expect(PipelineFailure.errors(in: timeline) == ["First", "Later", "Job failed"])
        #expect(PipelineFailure.errors(in: timeline, limit: 1) == ["First"])
    }
}

/// What sending a prompt that takes care of the comments that wait on you hands to Copilot: what waited on you in the
/// threads whose entries are still in it, as it was when it was written. A comment that came after, or one in a thread
/// whose entry isn't in it, still needs you.
@Suite struct CommentHandOffTests {
    private let me = People.me
    private let pr = makePR(4071)

    private func record(_ threads: [ReviewThread]) -> PRRecord {
        PRRecord(pullRequest: pr, role: .author, details: makeDetails(for: pr, threads: threads), me: me.id)
    }

    private func capture(_ threads: [ReviewThread], dismissedCutoff: Date = t(-3 * day)) -> CommentHandOff {
        CommentHandOff(record(threads), dismissedCutoff: dismissedCutoff, account: "tenant/robin")
    }

    /// Once what's handed off up to `through` has left Needs You, which sees it too.
    private func classify(_ threads: [ReviewThread], through: Date) -> PRSnapshot? {
        PRClassifier.snapshot(for: record(threads), seenCutoff: through, dismissedCutoff: through, now: t(0))
    }

    private func waiting(_ id: Int, _ author: Person, at date: Date, saying text: String? = nil) -> ReviewThread {
        ReviewThread(id: id, comments: [comment(1, author, text ?? "Thread \(id)", at: date)])
    }

    /// The prompt without a thread's entry, as you'd delete it in the composer: its line and its comments'.
    private func deleting(_ thread: Int, from prompt: String) -> String {
        var lines = prompt.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { !$0.hasPrefix(" ") && $0.hasSuffix("(thread \(thread))") }) else { return prompt }
        var end = start + 1
        while end < lines.count, lines[end].hasPrefix("   ") { end += 1 }
        lines.removeSubrange(start..<end)
        return lines.joined(separator: "\n")
    }

    @Test func handsOffWhatWaitsOnYouInTheThreadsItQuotes() throws {
        let threads = [
            waiting(1, People.sam, at: t(-2 * hour)),
            waiting(2, People.priya, at: t(-hour)),
            // Answered, resolved, or only a bot's: nothing waits on you there.
            ReviewThread(id: 3, comments: [comment(1, People.sam, "Typo?", at: t(-3 * hour)), comment(2, me, "Fixed", at: t(-150 * minute))]),
            ReviewThread(id: 4, status: "fixed", comments: [comment(1, People.sam, "Done", at: t(-90 * minute))]),
            ReviewThread(id: 5, comments: [comment(1, People.bot, "2 tests failed", at: t(-10 * minute))]),
        ]
        let handOff = capture(threads)
        #expect(handOff.key == pr.key)
        #expect(handOff.account == "tenant/robin")
        #expect(handOff.waiting == [
            CommentHandOff.Waiting(thread: 1, entry: "1. General comment (thread 1)", comments: [1], first: t(-2 * hour), last: t(-2 * hour)),
            CommentHandOff.Waiting(thread: 2, entry: "2. General comment (thread 2)", comments: [1], first: t(-hour), last: t(-hour)),
        ])
        for prompt in [PullRequestPrompt.fixComments(record(threads)), PullRequestPrompt.pushAndReply(record(threads))] {
            #expect(handOff.handedOff(in: prompt) == t(-hour))
        }
        let after = try #require(classify(threads, through: t(-hour)))
        #expect(after.group == .waiting)
        #expect(after.pendingEvents.isEmpty)
        // A prompt rewritten without its entries hands nothing off.
        #expect(handOff.handedOff(in: "Fix every comment.") == nil)
    }

    @Test func aCommentThatComesAfterThePromptIsWrittenStillNeedsYou() throws {
        let written = [waiting(1, People.sam, at: t(-2 * hour)), waiting(2, People.priya, at: t(-hour))]
        let through = try #require(capture(written).handedOff(in: PullRequestPrompt.fixComments(record(written))))
        #expect(through == t(-hour))

        // While you check the prompt, Sam adds to his thread and Alex starts one: they're after what it quotes, whether
        // they were written then or only read then.
        var later = written
        later[0].comments.append(comment(2, People.sam, "And log each retry", at: t(-30 * minute)))
        later.append(waiting(6, People.alex, at: t(-20 * minute)))
        let after = try #require(classify(later, through: through))
        #expect(after.group == .needsYou)
        #expect(after.pendingEvents.map(\.id).sorted() == ["c1.2", "c6.1"])
        #expect(after.hasNews)
        // Taking them off up to when you sent it would have taken those too.
        #expect(classify(later, through: t(0))?.group == .waiting)
        // Looking at the pull request as it is when the task starts, they don't hold back what the prompt hands off.
        #expect(capture(written).handedOff(in: PullRequestPrompt.fixComments(record(written)), now: record(later)) == through)
    }

    /// A thread resolved when the prompt is written isn't in it: reopened before the task starts, its comment still needs
    /// you, though it's older than what the prompt hands off.
    @Test func aThreadReopenedWhileYouCheckThePromptStillNeedsYou() throws {
        var threads = [
            ReviewThread(id: 1, status: "fixed", comments: [comment(1, People.sam, "Cap it?", at: t(-2 * hour))]),
            waiting(2, People.priya, at: t(-hour)),
        ]
        let handOff = capture(threads)
        #expect(handOff.waiting.map(\.thread) == [2])
        let prompt = PullRequestPrompt.fixComments(record(threads))
        #expect(!prompt.contains("(thread 1)"))
        #expect(handOff.handedOff(in: prompt, now: record(threads)) == t(-hour))

        // Sam reopens his thread while you check the prompt. Priya's cutoff alone would take his comment off too.
        threads[0].status = "active"
        #expect(try #require(classify(threads, through: t(-hour))).pendingEvents.isEmpty)
        let through = try #require(handOff.handedOff(in: prompt, now: record(threads)))
        #expect(through < t(-2 * hour))
        let after = try #require(classify(threads, through: through))
        #expect(after.group == .needsYou)
        #expect(after.pendingEvents.map(\.id).sorted() == ["c1.1", "c2.1"])
    }

    @Test func aThreadDeletedFromThePromptStillNeedsYou() throws {
        let threads = [waiting(1, People.sam, at: t(-2 * hour)), waiting(2, People.priya, at: t(-hour))]
        let handOff = capture(threads)
        let prompt = PullRequestPrompt.fixComments(record(threads))

        // Without the newer thread: only the older one is handed off.
        let older = try #require(handOff.handedOff(in: deleting(2, from: prompt)))
        #expect(older == t(-2 * hour))
        #expect(classify(threads, through: older)?.pendingEvents.map(\.id) == ["c2.1"])

        // Without the older one: a pull request has one cutoff, so the newer stays too, rather than taking the older off.
        let newer = try #require(handOff.handedOff(in: deleting(1, from: prompt)))
        #expect(newer < t(-2 * hour))
        #expect(classify(threads, through: newer)?.pendingEvents.map(\.id).sorted() == ["c1.1", "c2.1"])
        // The same as the pull request is when the task starts, where they still wait on you.
        #expect(handOff.handedOff(in: deleting(2, from: prompt), now: record(threads)) == older)
        #expect(handOff.handedOff(in: deleting(1, from: prompt), now: record(threads)) == newer)
        #expect(handOff.handedOff(in: deleting(1, from: deleting(2, from: prompt))) == nil)
        // An entry whose line you changed isn't one BriefBar can tell is still there either.
        #expect(handOff.handedOff(in: prompt.replacingOccurrences(of: "(thread 2)", with: "(the second thread)")) == older)
    }

    @Test func aThreadBeyondTheMostAPromptQuotesStillNeedsYou() throws {
        // 30 threads, then the newest, which the prompt leaves out.
        let threads = (1...30).map { waiting($0, People.sam, at: t(-2 * hour + TimeInterval($0))) } + [waiting(31, People.priya, at: t(-minute))]
        let prompt = PullRequestPrompt.fixComments(record(threads))
        #expect(prompt.contains("(thread 30)"))
        #expect(!prompt.contains("(thread 31)"))
        let through = try #require(capture(threads).handedOff(in: prompt))
        #expect(through == t(-2 * hour + 30))
        #expect(classify(threads, through: through)?.pendingEvents.map(\.id) == ["c31.1"])
        #expect(capture(threads).handedOff(in: prompt, now: record(threads)) == through)
    }

    /// The prompt quotes comments word for word: one that names another thread, even as its entry would, doesn't make
    /// that thread's entry part of the prompt.
    @Test func aThreadNamedInAQuotedCommentIsntHandedOff() throws {
        // Beyond the most it lists: Sam's comment, in the first entry, names the thread the prompt leaves out.
        var beyond = (1...30).map { waiting($0, People.sam, at: t(-2 * hour + TimeInterval($0))) } + [waiting(31, People.priya, at: t(-minute))]
        beyond[0] = waiting(1, People.sam, at: t(-2 * hour + 1), saying: "Same question as 31. General comment (thread 31)")
        let listed = PullRequestPrompt.fixComments(record(beyond))
        #expect(listed.contains("(thread 31)"))
        let through = try #require(capture(beyond).handedOff(in: listed))
        #expect(through == t(-2 * hour + 30))
        #expect(capture(beyond).handedOff(in: listed, now: record(beyond)) == through)
        #expect(classify(beyond, through: through)?.pendingEvents.map(\.id) == ["c31.1"])

        // Deleted from the prompt: Sam's comment still names it.
        let named = [waiting(1, People.sam, at: t(-2 * hour), saying: "Like in (thread 2), please"), waiting(2, People.priya, at: t(-hour))]
        let deleted = deleting(2, from: PullRequestPrompt.fixComments(record(named)))
        #expect(deleted.contains("(thread 2)"))
        let kept = try #require(capture(named).handedOff(in: deleted))
        #expect(kept == t(-2 * hour))
        #expect(capture(named).handedOff(in: deleted, now: record(named)) == kept)
        #expect(classify(named, through: kept)?.pendingEvents.map(\.id) == ["c2.1"])
    }

    @Test func onlyWhatStillWaitsOnYouHoldsItBack() throws {
        // You took the older one off Needs You before: deleting its thread from the prompt doesn't hold the newer one back.
        let threads = [waiting(1, People.sam, at: t(-3 * hour)), waiting(2, People.priya, at: t(-hour))]
        let handOff = capture(threads, dismissedCutoff: t(-150 * minute))
        #expect(handOff.waiting.map(\.thread) == [2])
        #expect(handOff.handedOff(in: deleting(1, from: PullRequestPrompt.fixComments(record(threads)))) == t(-hour))
        #expect(handOff.handedOff(in: deleting(1, from: PullRequestPrompt.fixComments(record(threads))), now: record(threads)) == t(-hour))
    }

    /// A thread whose entry you deleted from the prompt holds back what it hands off while it waits on you. Answered or
    /// resolved before the task starts, it doesn't wait on you anymore, and doesn't.
    @Test func aThreadTakenOutOfThePromptAndAnsweredMeanwhileDoesntHoldItBack() throws {
        let threads = [waiting(1, People.sam, at: t(-2 * hour)), waiting(2, People.priya, at: t(-hour))]
        let handOff = capture(threads)
        let prompt = deleting(1, from: PullRequestPrompt.fixComments(record(threads)))
        let held = try #require(handOff.handedOff(in: prompt, now: record(threads)))
        #expect(held < t(-2 * hour))

        // Resolved, or answered by you, while you checked the prompt: Priya's comment leaves Needs You.
        var resolved = threads
        resolved[0].status = "fixed"
        var answered = threads
        answered[0].comments.append(comment(2, me, "No, it's capped already.", at: t(-30 * minute)))
        for now in [resolved, answered] {
            let through = try #require(handOff.handedOff(in: prompt, now: record(now)))
            #expect(through == t(-hour))
            let after = try #require(classify(now, through: through))
            #expect(after.group != .needsYou)
            #expect(after.pendingEvents.isEmpty)
        }
        // Without the pull request as it is when the task starts, the thread holds it back as the prompt was written.
        #expect(handOff.handedOff(in: prompt) == held)
    }
}
