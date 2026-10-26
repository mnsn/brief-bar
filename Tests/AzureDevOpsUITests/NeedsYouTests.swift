import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Opening or seeing a pull request doesn't take a comment that waits on you off Needs You: answering it, taking the pull
/// request off, or sending the comments to Copilot does. With the made-up pull requests, which never use the Azure CLI or
/// Azure DevOps.
@MainActor
@Suite struct NeedsYouTests {
    /// The demo's pull requests, as of a time of their own. It reads them once and starts nothing, so the comment the
    /// running demo adds a few seconds in never comes, however long a busy runner takes.
    @MainActor
    private struct Demo {
        let store: PRStore
        let settings: AppSettings
        /// The preferences, where what you've seen is saved, with each account.
        let defaults: MemoryDefaults
        /// When the demo's pull requests are made up as of.
        let now: Date
        /// What the next refresh reads.
        var snapshot: PulseSnapshot

        /// The next refresh: the list looks again, at what you've seen or taken off Needs You too.
        func refresh() {
            store.receive(snapshot)
        }

        func item(_ number: Int) -> PRSnapshot? {
            store.items.first { $0.key.number == number }
        }

        /// Adds a comment to one of the pull request's threads, or a thread of its own, for the next refresh.
        mutating func add(_ comment: ReviewComment, to number: Int, thread: Int) {
            guard let index = snapshot.records.firstIndex(where: { $0.id.number == number }),
                  var details = snapshot.records[index].details
            else { return }
            if let existing = details.threads.firstIndex(where: { $0.id == thread }) {
                details.threads[existing].comments.append(comment)
            } else {
                details.threads.append(ReviewThread(id: thread, comments: [comment]))
            }
            details.lastActivity = max(details.lastActivity ?? .distantPast, comment.publishedAt)
            snapshot.records[index].details = details
        }

        /// Sets one of the pull request's threads' status, such as "fixed" or "active", for the next refresh.
        mutating func setStatus(_ status: String, of thread: Int, in number: Int) {
            guard let index = snapshot.records.firstIndex(where: { $0.id.number == number }),
                  var details = snapshot.records[index].details,
                  let existing = details.threads.firstIndex(where: { $0.id == thread })
            else { return }
            details.threads[existing].status = status
            snapshot.records[index].details = details
        }
    }

    private func loadDemo() async -> Demo {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        let store = PRStore(settings: settings, mode: .demo)
        // What `loadOnce` makes the demo up as of.
        let now = store.now
        await store.loadOnce()
        let demo = Demo(store: store, settings: settings, defaults: defaults, now: now, snapshot: DemoData.snapshot(now: now))
        #expect(store.record(for: PRKey(DemoData.organization, 4102)) == demo.snapshot.records.first { $0.id.number == 4102 })
        return demo
    }

    @Test func whatYouveSeenStaysUntilYouTakeItOff() async throws {
        let demo = await loadDemo()
        let store = demo.store
        // Sam's reply, which you've seen but not answered, is in Needs You with what's new, and counted with it.
        let seen = try #require(demo.item(4102))
        #expect(seen.group == .needsYou)
        #expect(!seen.hasNews)
        #expect(store.items(in: .needsYou).filter(\.hasNews).count == 3)
        #expect(store.counts.needsYou == 4)

        store.dismiss(seen)
        demo.refresh()
        #expect(demo.item(4102)?.group == .waiting)
        #expect(store.counts.needsYou == 3)
        #expect(demo.settings.dismissedCutoff(for: seen.key) == seen.since)
    }

    @Test func markAsSeenKeepsWhatWaitsOnYou() async {
        let demo = await loadDemo()
        let store = demo.store
        store.clear(.needsYou)
        demo.refresh()
        // The review request waits in To Review, and the pull request Dana sent leaves; the reply and the mention stay.
        #expect(demo.item(4110)?.group == .toReview)
        #expect(demo.item(4113) == nil)
        let needsYou = store.items(in: .needsYou)
        #expect(needsYou.map(\.key.number).sorted() == [4097, 4102])
        #expect(needsYou.filter(\.hasNews).isEmpty)
        #expect(store.counts.needsYou == 2)
    }

    @Test func sendingTheCommentsToCopilotTakesOffWhatItsPromptQuotes() async throws {
        let demo = await loadDemo()
        let store = demo.store
        let key = PRKey(DemoData.organization, 4102)
        let record = try #require(store.record(for: key))
        let replied = try #require(demo.item(4102)?.since)
        // Fixing its build, or reviewing it, leaves the comments to you.
        #expect(store.commentHandOff(.fixBuild, for: record) == nil)
        #expect(store.commentHandOff(.review, for: record) == nil)

        let handOff = try #require(store.commentHandOff(.fixComments, for: record))
        let prompt = await PullRequestTasks.prompt(.fixComments, for: record, client: nil)
        #expect(handOff.key == key)
        #expect(prompt.contains("(thread 11)"))
        store.sentToCopilot(handOff, prompt: prompt)
        demo.refresh()
        #expect(demo.item(4102)?.group == .waiting)
        #expect(demo.settings.dismissedCutoff(for: key) == replied)
    }

    /// The composer's prompt is written when you open it: what comes while you check it isn't in it, so sending it leaves
    /// that in Needs You.
    @Test func aCommentThatComesWhileYouCheckThePromptStillNeedsYou() async throws {
        var demo = await loadDemo()
        let store = demo.store
        let key = PRKey(DemoData.organization, 4102)
        let record = try #require(store.record(for: key))
        let replied = try #require(demo.item(4102)?.since)
        let sam = try #require(record.details?.threads.first { $0.id == 11 }?.comments.last?.author)
        #expect(sam.name == "Sam Rivera")
        let handOff = try #require(store.commentHandOff(.fixComments, for: record))
        let prompt = await PullRequestTasks.prompt(.fixComments, for: record, client: nil)

        // Then the list reads two more: Sam's, from a minute before you opened it, which the details BriefBar had didn't
        // have yet, and one in a new thread, written while you check the prompt.
        demo.add(ReviewComment(id: 3, author: sam, text: "And log each retry, please.", publishedAt: demo.now.addingTimeInterval(-60)),
                 to: 4102, thread: 11)
        demo.add(ReviewComment(id: 1, author: sam, text: "Does this need a feature flag?", publishedAt: demo.now.addingTimeInterval(30)),
                 to: 4102, thread: 64)
        demo.refresh()
        #expect(demo.item(4102)?.pendingEvents.map(\.id).sorted() == ["c11.2", "c11.3", "c64.1"])

        // You send it: Sam's first reply, which it quotes, leaves Needs You; the two that came after it don't.
        store.sentToCopilot(handOff, prompt: prompt)
        demo.refresh()
        let after = try #require(demo.item(4102))
        #expect(after.group == .needsYou)
        #expect(after.hasNews)
        #expect(after.pendingEvents.map(\.id).sorted() == ["c11.3", "c64.1"])
        #expect(demo.settings.dismissedCutoff(for: key) == replied)
    }

    /// A thread you take out of the prompt before you send it isn't handed to Copilot, and still needs you.
    @Test func aThreadYouTakeOutOfThePromptStillNeedsYou() async throws {
        var demo = await loadDemo()
        let store = demo.store
        let key = PRKey(DemoData.organization, 4102)
        let sam = try #require(demo.snapshot.records.first { $0.id == key }?.details?.threads.first { $0.id == 11 }?.comments.last?.author)
        demo.add(ReviewComment(id: 1, author: sam, text: "Does this need a feature flag?", publishedAt: demo.now.addingTimeInterval(-60)),
                 to: 4102, thread: 64)
        demo.refresh()
        let record = try #require(store.record(for: key))
        let handOff = try #require(store.commentHandOff(.fixComments, for: record))
        let prompt = await PullRequestTasks.prompt(.fixComments, for: record, client: nil)
        #expect(prompt.contains("(thread 64)"))

        // You keep the feature flag for yourself, and delete its entry: only the older reply goes to Copilot.
        let entry = "2. General comment (thread 64)\n   Sam Rivera: Does this need a feature flag?"
        #expect(prompt.contains(entry))
        store.sentToCopilot(handOff, prompt: prompt.replacingOccurrences(of: entry, with: ""))
        demo.refresh()
        let after = try #require(demo.item(4102))
        #expect(after.group == .needsYou)
        #expect(after.pendingEvents.map(\.id) == ["c64.1"])
    }

    /// A thread resolved when the prompt is written isn't in it: reopened before the task starts, its comment still needs
    /// you, though it's older than what the prompt hands off. BriefBar looks at the pull request again when the task starts.
    @Test func aThreadReopenedWhileYouCheckThePromptStillNeedsYou() async throws {
        var demo = await loadDemo()
        let store = demo.store
        let key = PRKey(DemoData.organization, 4102)
        let sam = try #require(demo.snapshot.records.first { $0.id == key }?.details?.threads.first { $0.id == 11 }?.comments.last?.author)
        // Sam's earlier question, in a thread he'd resolved.
        let asked = demo.now.addingTimeInterval(-2 * 3_600)
        demo.add(ReviewComment(id: 1, author: sam, text: "Should the client time out too?", publishedAt: asked), to: 4102, thread: 65)
        demo.setStatus("fixed", of: 65, in: 4102)
        demo.refresh()
        #expect(demo.item(4102)?.pendingEvents.map(\.id) == ["c11.2"])
        let record = try #require(store.record(for: key))
        let handOff = try #require(store.commentHandOff(.fixComments, for: record))
        let prompt = await PullRequestTasks.prompt(.fixComments, for: record, client: nil)
        #expect(!prompt.contains("(thread 65)"))

        // He reopens it while you check the prompt, then you send it.
        demo.setStatus("active", of: 65, in: 4102)
        demo.refresh()
        #expect(demo.item(4102)?.pendingEvents.map(\.id).sorted() == ["c11.2", "c65.1"])
        store.sentToCopilot(handOff, prompt: prompt)
        demo.refresh()
        let after = try #require(demo.item(4102))
        #expect(after.group == .needsYou)
        #expect(after.pendingEvents.map(\.id).contains("c65.1"))
        #expect(demo.settings.dismissedCutoff(for: key) < asked)
    }

    /// A thread you take out of the prompt holds back what it hands off while it waits on you. Resolved before the task
    /// starts, it doesn't wait on you anymore: what the prompt hands off leaves Needs You.
    @Test func aThreadYouTakeOutAndResolveMeanwhileDoesntHoldItBack() async throws {
        var demo = await loadDemo()
        let store = demo.store
        let key = PRKey(DemoData.organization, 4102)
        let replied = try #require(demo.item(4102)?.since)
        let sam = try #require(demo.snapshot.records.first { $0.id == key }?.details?.threads.first { $0.id == 11 }?.comments.last?.author)
        // Sam's earlier question, which waits on you too.
        let asked = demo.now.addingTimeInterval(-2 * 3_600)
        demo.add(ReviewComment(id: 1, author: sam, text: "Should the client time out too?", publishedAt: asked), to: 4102, thread: 65)
        demo.refresh()
        #expect(demo.item(4102)?.pendingEvents.map(\.id).sorted() == ["c11.2", "c65.1"])
        let record = try #require(store.record(for: key))
        let handOff = try #require(store.commentHandOff(.fixComments, for: record))
        let prompt = await PullRequestTasks.prompt(.fixComments, for: record, client: nil)

        // You keep the timeout question for yourself, delete its entry, and resolve its thread before you send the prompt.
        let entry = "2. General comment (thread 65)\n   Sam Rivera: Should the client time out too?"
        #expect(prompt.contains(entry))
        demo.setStatus("fixed", of: 65, in: 4102)
        demo.refresh()
        store.sentToCopilot(handOff, prompt: prompt.replacingOccurrences(of: entry, with: ""))
        demo.refresh()
        #expect(demo.item(4102)?.group == .waiting)
        #expect(demo.item(4102)?.pendingEvents.isEmpty == true)
        #expect(demo.settings.dismissedCutoff(for: key) == replied)
    }

    // MARK: Accounts

    /// Robin's prompt for 4102, written as the composer opens, with Robin signed in to the Azure CLI.
    private func composeAsRobin(_ demo: Demo) async throws -> (handOff: CommentHandOff, prompt: String, record: PRRecord, replied: Date) {
        #expect(!demo.settings.useAccount("tenant/robin", now: demo.now))
        let record = try #require(demo.store.record(for: PRKey(DemoData.organization, 4102)))
        let replied = try #require(demo.item(4102)?.since)
        let handOff = try #require(demo.store.commentHandOff(.fixComments, for: record))
        #expect(handOff.account == "tenant/robin")
        return (handOff, await PullRequestTasks.prompt(.fixComments, for: record, client: nil), record, replied)
    }

    /// Sam's Needs You is as it was when Sam signed in, and Robin's took the reply off, as BriefBar keeps it for when Robin
    /// signs in again, now and after BriefBar starts again.
    private func expectEachKeepsTheirOwn(_ demo: Demo, sams: (seen: Date, dismissed: Date), replied: Date) {
        let key = PRKey(DemoData.organization, 4102)
        #expect(demo.settings.account == "tenant/sam")
        #expect(demo.settings.seenCutoff(for: key) == sams.seen)
        #expect(demo.settings.dismissedCutoff(for: key) == sams.dismissed)
        let restarted = AppSettings(defaults: demo.defaults)
        #expect(restarted.account == "tenant/sam")
        #expect(restarted.useAccount("tenant/robin", now: demo.now))
        #expect(restarted.dismissedCutoff(for: key) == replied)
        #expect(demo.settings.useAccount("tenant/robin", now: demo.now))
        #expect(demo.settings.dismissedCutoff(for: key) == replied)
    }

    /// Someone else signs in to the Azure CLI while the composer is open: sending the prompt takes Robin's comments off
    /// Robin's Needs You, not the new account's.
    @Test func switchingAccountsWhileComposingKeepsEachOnesNeedsYou() async throws {
        let demo = await loadDemo()
        let robin = try await composeAsRobin(demo)

        #expect(demo.settings.useAccount("tenant/sam", now: demo.now))
        let key = PRKey(DemoData.organization, 4102)
        let sams = (seen: demo.settings.seenCutoff(for: key), dismissed: demo.settings.dismissedCutoff(for: key))
        demo.store.sentToCopilot(robin.handOff, prompt: robin.prompt)
        expectEachKeepsTheirOwn(demo, sams: sams, replied: robin.replied)
    }

    /// Someone else signs in while Copilot is still starting, after you sent the prompt: the same, through the task's
    /// own start, as the app wires it to the list.
    @Test func switchingAccountsWhileTheTaskStartsKeepsEachOnesNeedsYou() async throws {
        let demo = await loadDemo()
        let robin = try await composeAsRobin(demo)
        let settings = demo.settings
        settings.copilotEnabled = true
        let copilot = CopilotTasksStore(settings: settings, mode: .live, notifier: nil)
        defer { copilot.stop() }
        copilot.useEnvironment(["COPILOT_HOME": "/nonexistent"])
        copilot.handedOff = { [weak store = demo.store] handOff, prompt in store?.sentToCopilot(handOff, prompt: prompt) }
        // Starting it waits until the test lets it go on, and starts nothing.
        let (go, letItGo) = AsyncStream<Void>.makeStream()
        copilot.launchForTests = { request, id, now in
            for await _ in go { break }
            guard case .pullRequest(let pullRequest, let action) = request.subject else { throw CancellationError() }
            return CopilotRun(
                id: id, workItem: nil, onPullRequest: pullRequest.reference, action: action, options: request.options,
                repository: request.repository, worktree: URL(fileURLWithPath: "/tmp/copilot-worktrees/payments-api/pr-4102"),
                startedAt: now, process: DetachedProgram.Handle(pid: getpid(), startedAt: nil)
            )
        }
        let pr = robin.record.pullRequest
        let task = TaskPullRequest(
            organization: pr.key.organization, project: pr.projectName, repository: pr.repositoryName, id: pr.key.number,
            title: pr.title, url: pr.webURL, sourceBranch: pr.sourceBranch, targetBranch: pr.targetBranch,
            projectId: pr.projectId, repositoryId: pr.repositoryId
        )
        copilot.send(.pullRequest(task, .fixComments), prompt: robin.prompt, options: CopilotModel.standard,
                     repository: URL(fileURLWithPath: "/tmp/payments-api"), handOff: robin.handOff)

        #expect(settings.useAccount("tenant/sam", now: demo.now))
        let key = PRKey(DemoData.organization, 4102)
        let sams = (seen: settings.seenCutoff(for: key), dismissed: settings.dismissedCutoff(for: key))
        #expect(settings.copilotRuns.isEmpty)
        letItGo.yield()
        for _ in 0..<500 where settings.copilotRuns.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(settings.copilotRuns.map(\.action) == [.fixComments])
        expectEachKeepsTheirOwn(demo, sams: sams, replied: robin.replied)
    }
}
