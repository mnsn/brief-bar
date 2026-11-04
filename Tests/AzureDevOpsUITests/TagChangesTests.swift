import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// A pull request's tags as you change them, with Make Changes in Azure DevOps on: what goes to Azure DevOps, only while it's
/// on and you click; what shows, as Azure DevOps answered; what they say when a change can't be made; what adding one
/// suggests, and the tags you added, which BriefBar remembers until you turn it off; and the tags lists don't carry, read
/// only while the details show on screen. With the demo's made-up pull requests, read as a list that reads Azure DevOps
/// would, and a stand-in for Azure DevOps that answers as it does.
@MainActor
@Suite struct TagChangesTests {
    /// What the stand-in for Azure DevOps was sent, and answers.
    final class AzureDevOps {
        var sent: [ADOWrite] = []
        var fails: ADOError?
        /// How Azure DevOps spells a tag it has already, as the project has it.
        var spelling: [String: String] = [:]

        func send(_ write: ADOWrite) throws -> ADOWrite.Answer {
            sent.append(write)
            if let fails { throw fails }
            switch write {
            case .addTag(_, let name):
                return .tag(ADOTag(id: "id-\(name.lowercased())", name: spelling[name.lowercased()] ?? name, active: true))
            case .removeTag:
                return .done
            case .reply, .setStatus:
                // Tags' changes never send one (ThreadChangesTests).
                throw ADOError.http(400)
            }
        }
    }

    /// The demo's pull request whose details the pictures show, tagged deploy-eu and needs-qa.
    private let key = PRKey(DemoData.organization, 4102)

    /// A list that reads Azure DevOps, with the demo's pull requests read, and what changes their tags.
    private func live(makesChanges: Bool = true) -> (store: PRStore, changes: TagChanges, azure: AzureDevOps) {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.makesChanges = makesChanges
        let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .live)
        settings.useSeenState(DemoData.seenState(now: store.now))
        store.receive(DemoData.snapshot(now: store.now))
        let changes = TagChanges(store: store, settings: settings)
        let azure = AzureDevOps()
        changes.send = { try azure.send($0) }
        changes.readTags = { _ in nil }
        return (store, changes, azure)
    }

    private func tags(_ store: PRStore, _ key: PRKey? = nil) -> [String]? {
        store.record(for: key ?? self.key)?.tags?.map(\.name)
    }

    @Test func nothingShowsOrGoesWhileItsOff() async throws {
        let (store, changes, azure) = live(makesChanges: false)
        #expect(!changes.canChange(store.record(for: key)))
        #expect(await changes.add("hotfix", to: key) == false)
        await changes.remove(PullRequestTag("deploy-eu"), from: key)
        #expect(azure.sent.isEmpty)
        #expect(tags(store) == ["deploy-eu", "needs-qa"])
    }

    /// Nor on one that's closed, or whose tags aren't known.
    @Test func nothingGoesForAClosedPullRequestOrUnknownTags() async throws {
        let (store, changes, azure) = live()
        let done = try #require(store.records.first { $0.pullRequest.status != .active })
        #expect(!changes.canChange(done))
        #expect(await changes.add("hotfix", to: done.id) == false)
        var unknown = try #require(store.record(for: key))
        unknown.tags = nil
        #expect(!changes.canChange(unknown))
        #expect(azure.sent.isEmpty)
    }

    /// A tag goes once, as you typed it, and shows as Azure DevOps answered, spelled as the project has it; it's remembered for
    /// its project, and comes first in what adding one suggests there.
    @Test func aTagGoesOnceAndShowsAsAzureDevOpsAnswered() async throws {
        let (store, changes, azure) = live()
        azure.spelling["deploy-us"] = "Deploy-US"
        let record = try #require(store.record(for: key))
        #expect(await changes.add("  deploy-us ", to: key))
        #expect(azure.sent == [.addTag(PullRequestAddress(record.pullRequest), name: "deploy-us")])
        #expect(tags(store) == ["deploy-eu", "Deploy-US", "needs-qa"])
        #expect(store.record(for: key)?.tags?.first { $0.name == "Deploy-US" }?.tagId == "id-deploy-us")
        #expect(changes.state(of: key) == nil)
        #expect(changes.settings.usedTags.tags(organization: key.organization, projectId: record.pullRequest.projectId) == ["Deploy-US"])
        // Another pull request in the project suggests it first.
        let other = try #require(store.record(for: PRKey(DemoData.organization, 4079)))
        #expect(changes.choices(for: "", on: other).suggestions.first?.lowercased() == "deploy-us")
    }

    /// One it has already, whatever its letter case, isn't sent again.
    @Test func aTagItHasAlreadyIsntSentAgain() async throws {
        let (store, changes, azure) = live()
        #expect(await changes.add("NEEDS-QA", to: key))
        #expect(azure.sent.isEmpty)
        #expect(tags(store) == ["deploy-eu", "needs-qa"])
    }

    /// Taking a tag off goes by the project's tag's ID, and it's gone at once.
    @Test func takingATagOffGoesByItsID() async throws {
        let (store, changes, azure) = live()
        let record = try #require(store.record(for: key))
        let tag = try #require(record.tags?.first { $0.name == "deploy-eu" })
        await changes.remove(tag, from: key)
        #expect(azure.sent == [.removeTag(PullRequestAddress(record.pullRequest), tag: "demo-tag-deploy-eu")])
        #expect(tags(store) == ["needs-qa"])
        #expect(changes.state(of: key) == nil)
    }

    /// A change that fails says why, by the tags, which stay as they were; one that may have gone reads them again. Try
    /// Again sends it again.
    @Test func aChangeThatFailsSaysWhy() async throws {
        let (store, changes, azure) = live()
        azure.fails = .forbidden
        #expect(await changes.add("hotfix", to: key) == false)
        #expect(changes.state(of: key) == .failed(.notAllowed, .add("hotfix")))
        #expect(tags(store) == ["deploy-eu", "needs-qa"])
        changes.dismiss(key)
        #expect(changes.state(of: key) == nil)

        var reads = 0
        changes.readTags = { _ in
            reads += 1
            return .failure(.offline)
        }
        azure.fails = .offline
        await changes.remove(PullRequestTag("needs-qa", tagId: "demo-tag-needs-qa"), from: key)
        #expect(changes.state(of: key) == .failed(.offline, .remove(PullRequestTag("needs-qa", tagId: "demo-tag-needs-qa"))))
        try await waitUntil { reads == 1 }
        #expect(tags(store) == ["deploy-eu", "needs-qa"])

        // Closed meanwhile: Azure DevOps says so.
        azure.fails = .refused(.notEditable, message: "TF401181")
        await changes.retry(.add("hotfix"), on: key)
        #expect(changes.state(of: key) == .failed(.closed, .add("hotfix")))
        azure.fails = nil
        await changes.retry(.add("hotfix"), on: key)
        #expect(changes.state(of: key) == nil)
        #expect(tags(store) == ["deploy-eu", "hotfix", "needs-qa"])
    }

    /// A tag Azure DevOps says isn't on the pull request, when its tags, read again, don't have it, is off, as you wanted;
    /// when they still do, the tags say what went wrong.
    @Test func aTagThatsNotThereIsOffAsYouWanted() async throws {
        let (store, changes, azure) = live()
        azure.fails = .notFound
        changes.readTags = { _ in .success([PullRequestTag("needs-qa")]) }
        await changes.remove(PullRequestTag("deploy-eu", tagId: "demo-tag-deploy-eu"), from: key)
        #expect(changes.state(of: key) == nil)

        changes.readTags = { _ in .success([PullRequestTag("deploy-eu"), PullRequestTag("needs-qa")]) }
        await changes.remove(PullRequestTag("deploy-eu", tagId: "demo-tag-deploy-eu"), from: key)
        #expect(changes.state(of: key) == .failed(.gone, .remove(PullRequestTag("deploy-eu", tagId: "demo-tag-deploy-eu"))))
        withExtendedLifetime(store) {}
    }

    /// A list read before the change, which has the tags as they were, doesn't undo it; one with the change is taken, and so
    /// is one with tags someone changed since, which the engine publishes only after any it read before.
    @Test func aListReadBeforeAChangeDoesntUndoIt() async throws {
        let (store, changes, _) = live()
        #expect(await changes.add("hotfix", to: key))
        // Read before: as they were.
        store.receive(DemoData.snapshot(now: store.now))
        #expect(tags(store) == ["deploy-eu", "hotfix", "needs-qa"])
        // Read since, with it.
        var snapshot = DemoData.snapshot(now: store.now)
        let index = try #require(snapshot.records.firstIndex { $0.id == key })
        snapshot.records[index].tags = ["deploy-eu", "hotfix", "needs-qa"].map { PullRequestTag($0) }
        store.receive(snapshot)
        #expect(tags(store) == ["deploy-eu", "hotfix", "needs-qa"])
        // Changed again, then read before that change, then with tags someone changed since: as they are now.
        #expect(await changes.add("deploy-us", to: key))
        store.receive(snapshot)
        #expect(tags(store) == ["deploy-eu", "deploy-us", "hotfix", "needs-qa"])
        snapshot.records[index].tags = [PullRequestTag("hotfix")]
        store.receive(snapshot)
        #expect(tags(store) == ["hotfix"])
    }

    /// The demo sends nothing: its tags change in its made-up data, which they stay in while it runs.
    @Test func theDemoChangesOnlyItsMadeUpData() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        settings.makesChanges = true
        let store = PRStore(settings: settings, summarizer: .withoutModel, mode: .demo)
        await store.loadOnce()
        let changes = TagChanges(store: store, settings: settings)
        changes.send = { _ in
            Issue.record("The demo sent a change")
            return .done
        }
        #expect(await changes.add("hotfix", to: key))
        await changes.remove(PullRequestTag("needs-qa", tagId: "demo-tag-needs-qa"), from: key)
        #expect(tags(store) == ["deploy-eu", "hotfix"])
        // As the demo reads its made-up pull requests again.
        store.receive(DemoData.update(DemoData.snapshot(now: store.now), at: store.now))
        #expect(tags(store) == ["deploy-eu", "hotfix"])
    }

    /// Turned off, the tags you added are forgotten, and so is what went wrong.
    @Test func turningItOffForgetsTheTagsYouAdded() async throws {
        let (store, changes, azure) = live()
        defer { withExtendedLifetime(store) {} }
        #expect(await changes.add("hotfix", to: key))
        azure.fails = .forbidden
        #expect(await changes.add("deploy-us", to: key) == false)
        #expect(!changes.settings.usedTags.isEmpty)
        changes.settings.makesChanges = false
        #expect(changes.settings.usedTags.isEmpty)
        #expect(changes.state(of: key) == nil)
    }

    /// What adding a tag offers: the tags you added in the project, then those on its pull requests, but the pull request's
    /// own; then what you typed, as a new one.
    @Test func suggestsTheTagsOfThePullRequestsInItsProject() throws {
        let (store, changes, _) = live()
        let record = try #require(store.record(for: key))
        let choices = changes.choices(for: "dep", on: record)
        #expect(choices.suggestions == ["deploy-us", "deploy-apac"])
        #expect(choices.newTag == "dep")
        #expect(changes.choices(for: "", on: record).suggestions.contains("hotfix"))
        #expect(!changes.choices(for: "", on: record).suggestions.contains("needs-qa"))
    }

    /// Tags its lists don't carry, as for a pull request sent to you, are read, one request, only once a window shows its
    /// details on screen; then not again for a while.
    @Test func readsTagsListsDontCarryOnlyOnScreen() async throws {
        let (store, changes, _) = live()
        var snapshot = DemoData.snapshot(now: store.now)
        let index = try #require(snapshot.records.firstIndex { $0.id == key })
        snapshot.records[index].tags = nil
        store.receive(snapshot)
        var reads = 0
        changes.readTags = { _ in
            reads += 1
            return .success([PullRequestTag("deploy-eu")])
        }
        let page = "pull requests in window 1"
        let following = Task { await changes.follow(key, on: page) }
        defer { following.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(reads == 0)
        changes.setVisible(true, for: page)
        try await waitUntil { reads == 1 }
        // Known now, as the list keeps them.
        snapshot.records[index].tags = [PullRequestTag("deploy-eu")]
        store.receive(snapshot)
        changes.setVisible(false, for: page)
        changes.setVisible(true, for: page)
        try await Task.sleep(for: .milliseconds(50))
        #expect(reads == 1)
        // A pull request whose lists carry them is never read on its own.
        let another = Task { await changes.follow(PRKey(DemoData.organization, 4091), on: page) }
        defer { another.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(reads == 1)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
