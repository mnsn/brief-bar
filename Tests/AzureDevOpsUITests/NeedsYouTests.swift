import AzureDevOpsCore
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
    }

    private func loadDemo() async -> Demo {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = PRStore(settings: settings, mode: .demo)
        // What `loadOnce` makes the demo up as of.
        let now = store.now
        await store.loadOnce()
        let demo = Demo(store: store, settings: settings, now: now, snapshot: DemoData.snapshot(now: now))
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

        // You keep the feature flag for yourself: only the older reply goes to Copilot.
        store.sentToCopilot(handOff, prompt: prompt.replacingOccurrences(of: "(thread 64)", with: ""))
        demo.refresh()
        let after = try #require(demo.item(4102))
        #expect(after.group == .needsYou)
        #expect(after.pendingEvents.map(\.id) == ["c64.1"])
    }
}
