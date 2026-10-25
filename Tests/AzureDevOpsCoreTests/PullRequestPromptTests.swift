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
