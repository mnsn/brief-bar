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
/// threads it quotes, as it was when it was written. A comment that came after, or one in a thread it doesn't quote, still
/// needs you.
@Suite struct CommentHandOffTests {
    private let me = People.me
    private let pr = makePR(4071)

    private func record(_ threads: [ReviewThread]) -> PRRecord {
        PRRecord(pullRequest: pr, role: .author, details: makeDetails(for: pr, threads: threads), me: me.id)
    }

    /// Once what's handed off up to `through` has left Needs You, which sees it too.
    private func classify(_ threads: [ReviewThread], through: Date) -> PRSnapshot? {
        PRClassifier.snapshot(for: record(threads), seenCutoff: through, dismissedCutoff: through, now: t(0))
    }

    private func waiting(_ id: Int, _ author: Person, at date: Date) -> ReviewThread {
        ReviewThread(id: id, comments: [comment(1, author, "Thread \(id)", at: date)])
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
        let handOff = CommentHandOff(record(threads), dismissedCutoff: t(-3 * day))
        #expect(handOff.key == pr.key)
        #expect(handOff.waiting == [
            CommentHandOff.Waiting(thread: 1, first: t(-2 * hour), last: t(-2 * hour)),
            CommentHandOff.Waiting(thread: 2, first: t(-hour), last: t(-hour)),
        ])
        for prompt in [PullRequestPrompt.fixComments(record(threads)), PullRequestPrompt.pushAndReply(record(threads))] {
            #expect(handOff.handedOff(in: prompt) == t(-hour))
        }
        let after = try #require(classify(threads, through: t(-hour)))
        #expect(after.group == .waiting)
        #expect(after.pendingEvents.isEmpty)
        // A prompt rewritten without its threads hands nothing off.
        #expect(handOff.handedOff(in: "Fix every comment.") == nil)
    }

    @Test func aCommentThatComesAfterThePromptIsWrittenStillNeedsYou() throws {
        let written = [waiting(1, People.sam, at: t(-2 * hour)), waiting(2, People.priya, at: t(-hour))]
        let handOff = CommentHandOff(record(written), dismissedCutoff: t(-3 * day))
        let through = try #require(handOff.handedOff(in: PullRequestPrompt.fixComments(record(written))))
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
    }

    @Test func aThreadTakenOutOfThePromptStillNeedsYou() throws {
        let threads = [waiting(1, People.sam, at: t(-2 * hour)), waiting(2, People.priya, at: t(-hour))]
        let handOff = CommentHandOff(record(threads), dismissedCutoff: t(-3 * day))
        let prompt = PullRequestPrompt.fixComments(record(threads))

        // Without the newer thread: only the older one is handed off.
        let older = try #require(handOff.handedOff(in: prompt.replacingOccurrences(of: "(thread 2)", with: "")))
        #expect(older == t(-2 * hour))
        #expect(classify(threads, through: older)?.pendingEvents.map(\.id) == ["c2.1"])

        // Without the older one: a pull request has one cutoff, so the newer stays too, rather than taking the older off.
        let newer = try #require(handOff.handedOff(in: prompt.replacingOccurrences(of: "(thread 1)", with: "")))
        #expect(newer < t(-2 * hour))
        #expect(classify(threads, through: newer)?.pendingEvents.map(\.id).sorted() == ["c1.1", "c2.1"])
        #expect(handOff.handedOff(in: prompt.replacingOccurrences(of: "(thread 1)", with: "").replacingOccurrences(of: "(thread 2)", with: "")) == nil)
    }

    @Test func aThreadBeyondTheMostAPromptQuotesStillNeedsYou() throws {
        // 30 threads, then the newest, which the prompt leaves out.
        let threads = (1...30).map { waiting($0, People.sam, at: t(-2 * hour + TimeInterval($0))) } + [waiting(31, People.priya, at: t(-minute))]
        let prompt = PullRequestPrompt.fixComments(record(threads))
        #expect(prompt.contains("(thread 30)"))
        #expect(!prompt.contains("(thread 31)"))
        let through = try #require(CommentHandOff(record(threads), dismissedCutoff: t(-3 * day)).handedOff(in: prompt))
        #expect(through == t(-2 * hour + 30))
        #expect(classify(threads, through: through)?.pendingEvents.map(\.id) == ["c31.1"])
    }

    @Test func onlyWhatStillWaitsOnYouHoldsItBack() throws {
        // You took the older one off Needs You before: leaving its thread out of the prompt doesn't hold the newer one back.
        let threads = [waiting(1, People.sam, at: t(-3 * hour)), waiting(2, People.priya, at: t(-hour))]
        let handOff = CommentHandOff(record(threads), dismissedCutoff: t(-150 * minute))
        #expect(handOff.waiting.map(\.thread) == [2])
        let prompt = PullRequestPrompt.fixComments(record(threads)).replacingOccurrences(of: "(thread 1)", with: "")
        #expect(handOff.handedOff(in: prompt) == t(-hour))
    }

    @Test func tellsThreadsApartByTheirWholeNumber() {
        // Thread 1, taken out of the prompt, isn't quoted by thread 12's "(thread 12)".
        let threads = [waiting(1, People.sam, at: t(-2 * hour)), waiting(12, People.priya, at: t(-hour))]
        let prompt = PullRequestPrompt.fixComments(record(threads)).replacingOccurrences(of: "(thread 1)\n", with: "\n")
        #expect(prompt.contains("(thread 12)"))
        #expect(CommentHandOff(record(threads), dismissedCutoff: t(-3 * day)).handedOff(in: prompt) == t(-2 * hour).addingTimeInterval(-0.001))
    }
}
