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
    /// The demo's pull requests, in a list that follows what you see and take off Needs You.
    private func demo() -> (store: PRStore, settings: AppSettings) {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = PRStore(settings: settings, mode: .demo)
        store.start()
        return (store, settings)
    }

    private func group(_ number: Int, in store: PRStore) -> PRGroup? {
        store.items.first { $0.key.number == number }?.group
    }

    /// The list looks again on the main queue.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func whatYouveSeenStaysUntilYouTakeItOff() async throws {
        let (store, settings) = demo()
        defer { store.stop() }
        // Sam's reply, which you've seen but not answered, is in Needs You with what's new, and counted with it.
        let seen = try #require(store.items.first { $0.key.number == 4102 })
        #expect(seen.group == .needsYou)
        #expect(!seen.hasNews)
        #expect(store.items(in: .needsYou).filter(\.hasNews).count == 3)
        #expect(store.counts.needsYou == 4)

        store.dismiss(seen)
        await until { group(4102, in: store) != .needsYou }
        #expect(group(4102, in: store) == .waiting)
        #expect(store.counts.needsYou == 3)
        #expect(settings.dismissedCutoff(for: seen.key) == seen.since)
    }

    @Test func markAsSeenKeepsWhatWaitsOnYou() async {
        let (store, _) = demo()
        defer { store.stop() }
        store.clear(.needsYou)
        // The review request waits in To Review, and the pull request Dana sent leaves; the reply and the mention stay.
        await until { group(4110, in: store) == .toReview }
        #expect(group(4110, in: store) == .toReview)
        #expect(group(4113, in: store) == nil)
        let needsYou = store.items(in: .needsYou)
        #expect(needsYou.map(\.key.number).sorted() == [4097, 4102])
        #expect(needsYou.filter(\.hasNews).isEmpty)
        #expect(store.counts.needsYou == 2)
    }

    @Test func sendingTheCommentsToCopilotTakesThemOff() async throws {
        let (store, settings) = demo()
        defer { store.stop() }
        let item = try #require(store.items.first { $0.key.number == 4102 })
        let replied = try #require(item.since)
        let before = settings.dismissedCutoff(for: item.key)
        // Fixing its build leaves the comments to you. Organization names are case-insensitive.
        let key = PRKey(DemoData.organization.uppercased(), 4102)
        store.sentToCopilot(key, action: .fixBuild, at: Date())
        #expect(settings.dismissedCutoff(for: item.key) == before)
        // A comment that came after you sent the task wasn't in its prompt: it still needs you.
        store.sentToCopilot(key, action: .fixComments, at: replied.addingTimeInterval(-60))
        #expect(settings.dismissedCutoff(for: item.key) == before)

        store.sentToCopilot(key, action: .fixComments, at: Date())
        await until { group(4102, in: store) != .needsYou }
        #expect(group(4102, in: store) == .waiting)
        #expect(settings.dismissedCutoff(for: item.key) == replied)
    }
}
