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
        changes.send = { write, _ in try azure.send(write) }
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
        #expect(changes.state(of: key) == nil)
        #expect(tags(store) == ["deploy-eu", "needs-qa"])
    }

    /// Nor on one that's closed, which says so by the tags, as a change that finds it so, or whose tags aren't known.
    @Test func nothingGoesForAClosedPullRequestOrUnknownTags() async throws {
        let (store, changes, azure) = live()
        let done = try #require(store.records.first { $0.pullRequest.status != .active })
        #expect(!changes.canChange(done))
        #expect(await changes.add("hotfix", to: done.id) == false)
        #expect(changes.state(of: done.id) == .failed(.closed, .add("hotfix")))
        var unknown = try #require(store.record(for: key))
        unknown.tags = nil
        #expect(!changes.canChange(unknown))
        #expect(azure.sent.isEmpty)
    }

    /// Nor on one your lists don't have anymore, though its details still show it as it was when it left them, open: a change
    /// that finds it so, as it left them as you clicked, says so by the tags.
    @Test func nothingGoesForAPullRequestThatLeftYourLists() async throws {
        let (store, changes, azure) = live()
        let shown = try #require(store.record(for: key))
        var snapshot = DemoData.snapshot(now: store.now)
        snapshot.records.removeAll { $0.id == key }
        store.receive(snapshot)
        #expect(store.record(for: key) == nil)
        #expect(shown.pullRequest.status == .active && shown.tags != nil)
        #expect(!changes.canChange(shown))
        #expect(await changes.add("hotfix", to: key) == false)
        #expect(changes.state(of: key) == .failed(.notListed, .add("hotfix")))
        await changes.remove(PullRequestTag("deploy-eu"), from: key)
        #expect(changes.state(of: key) == .failed(.notListed, .remove(PullRequestTag("deploy-eu"))))
        #expect(azure.sent.isEmpty)
        changes.dismiss(key)
        // Back in your lists, it can be changed again.
        store.receive(DemoData.snapshot(now: store.now))
        #expect(changes.canChange(store.record(for: key)))
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

    /// After a tag's taken off, Undo adds it back, as it was spelled; it goes with the next change, or once nothing shows the
    /// pull request.
    @Test func undoAddsBackTheTagYouTookOff() async throws {
        let (store, changes, azure) = live()
        let record = try #require(store.record(for: key))
        let page = "pull requests in window 1"
        let following = Task { await changes.follow(key, on: page) }
        try await Task.sleep(for: .milliseconds(20))
        let tag = try #require(record.tags?.first { $0.name == "deploy-eu" })
        await changes.remove(tag, from: key)
        #expect(changes.removed[key] == tag)
        await changes.undoRemoval(on: key)
        #expect(changes.removed[key] == nil)
        #expect(azure.sent == [
            .removeTag(PullRequestAddress(record.pullRequest), tag: "demo-tag-deploy-eu"),
            .addTag(PullRequestAddress(record.pullRequest), name: "deploy-eu"),
        ])
        #expect(tags(store) == ["deploy-eu", "needs-qa"])

        await changes.remove(tag, from: key)
        #expect(changes.removed[key] != nil)
        changes.dismissRemoval(on: key)
        #expect(changes.removed[key] == nil)
        await changes.remove(PullRequestTag("needs-qa", tagId: "demo-tag-needs-qa"), from: key)
        #expect(changes.removed[key]?.name == "needs-qa")
        following.cancel()
        try await waitUntil { changes.removed[key] == nil }
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
        changes.send = { _, _ in
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

    /// A change goes as whom the list was read as when you clicked: someone else signed in since, and Azure DevOps' client sends
    /// nothing (`ADOClient.send(_:as:)`), which the tags say, with Sign In.
    @Test func aChangeGoesAsWhomTheListWasReadAs() async throws {
        let (store, changes, azure) = live()
        changes.accountChanged("robin@contoso.example")
        var accounts: [String?] = []
        changes.send = { write, account in
            accounts.append(account)
            if account == "robin@contoso.example", case .removeTag = write { throw ADOError.otherAccount }
            return try azure.send(write)
        }
        #expect(await changes.add("hotfix", to: key))
        await changes.remove(PullRequestTag("needs-qa", tagId: "demo-tag-needs-qa"), from: key)
        #expect(accounts == ["robin@contoso.example", "robin@contoso.example"])
        #expect(changes.state(of: key) == .failed(.otherAccount, .remove(PullRequestTag("needs-qa", tagId: "demo-tag-needs-qa"))))
        #expect(tags(store) == ["deploy-eu", "hotfix", "needs-qa"])
        #expect(ADOWriteProblem.otherAccount.sentence(.removeTag).hasPrefix("Someone else is signed in to the Azure CLI now"))
    }

    /// A change on its way that hasn't gone yet, as one waiting for a token, is called off as the setting goes off, or
    /// someone else signs in: it never goes, says nothing, and nothing's read for it, since nothing went.
    @Test func aChangeOnItsWayIsCalledOffAsItGoesOff() async throws {
        let (store, changes, azure) = live()
        changes.send = { write, _ in
            // Waits, as for a token, until it's called off.
            try await Task.sleep(for: .seconds(30))
            return try azure.send(write)
        }
        var reads: [PRKey] = []
        changes.readTags = { key in
            reads.append(key)
            return .success([PullRequestTag("deploy-eu"), PullRequestTag("needs-qa")])
        }
        let adding = Task { await changes.add("hotfix", to: key) }
        try await waitUntil { changes.isSending(key) }
        changes.settings.makesChanges = false
        #expect(await adding.value == false)
        #expect(azure.sent.isEmpty)
        #expect(changes.state(of: key) == nil)
        #expect(tags(store) == ["deploy-eu", "needs-qa"])

        changes.settings.makesChanges = true
        changes.accountChanged("robin@contoso.example")
        let removing = Task { await changes.remove(PullRequestTag("needs-qa", tagId: "demo-tag-needs-qa"), from: key) }
        try await waitUntil { changes.isSending(key) }
        changes.accountChanged("sam@contoso.example")
        await removing.value
        #expect(azure.sent.isEmpty)
        #expect(changes.state(of: key) == nil)
        #expect(tags(store) == ["deploy-eu", "needs-qa"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(reads.isEmpty)
    }

    /// A change under way as the setting goes off, gone already, which the client doesn't call off then, settles all the
    /// same: the tags show what Azure DevOps answered, and are read again after it, not as the setting goes off, which may be
    /// before Azure DevOps made it, and would leave them as they were. One that may have been made without saying so, as one
    /// Azure DevOps didn't answer in time, has them read again once it settled.
    @Test(.timeLimit(.minutes(1)))
    func aChangeUnderWayAsItGoesOffShowsOnceItSettles() async throws {
        let (store, changes, azure) = live()
        var waiting: CheckedContinuation<Void, Never>?
        // Gone: it answers, called off or not.
        changes.send = { write, _ in
            await withCheckedContinuation { waiting = $0 }
            return try azure.send(write)
        }
        var reads: [PRKey] = []
        changes.readTags = { key in
            reads.append(key)
            // As Azure DevOps had them before it made the change.
            return .success([PullRequestTag("deploy-eu"), PullRequestTag("needs-qa")])
        }
        var readAfter: [[String]] = []
        changes.readAfterChange = { _, tags in
            readAfter.append(tags.map(\.name))
            return .success(tags)
        }
        let adding = Task { await changes.add("hotfix", to: key) }
        try await waitUntil { waiting != nil }
        changes.settings.makesChanges = false
        try await Task.sleep(for: .milliseconds(20))
        #expect(reads.isEmpty)
        try #require(waiting).resume()
        #expect(await adding.value == false)
        #expect(tags(store) == ["deploy-eu", "hotfix", "needs-qa"])
        try await waitUntil { readAfter.count == 1 }
        #expect(readAfter == [["deploy-eu", "hotfix", "needs-qa"]])
        #expect(reads.isEmpty)
        #expect(changes.state(of: key) == nil)
        #expect(changes.settings.usedTags.isEmpty)

        changes.settings.makesChanges = true
        waiting = nil
        let removing = Task { await changes.remove(PullRequestTag("needs-qa", tagId: "demo-tag-needs-qa"), from: key) }
        try await waitUntil { waiting != nil }
        changes.settings.makesChanges = false
        try await Task.sleep(for: .milliseconds(20))
        #expect(reads.isEmpty)
        azure.fails = .network(ADOClient.unansweredMessage)
        try #require(waiting).resume()
        await removing.value
        #expect(reads == [key])
        #expect(changes.state(of: key) == nil)
        #expect(azure.sent.map(\.kind) == [.addTag, .removeTag])
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
        // Known now, as the list keeps them, with when they were read.
        snapshot.records[index].tags = [PullRequestTag("deploy-eu")]
        snapshot.records[index].tagsReadAt = changes.now()
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

    /// Tags its lists don't carry are read again ten minutes after they were, as the list has it, while their details stay on
    /// screen, though Make Changes in Azure DevOps went off and on meanwhile; a read that fails is tried again half a minute
    /// later, and not before, whatever went off. Then the lists carry them again, and they're read only with the lists.
    @Test func readsTagsListsDontCarryAgainTenMinutesLater() async throws {
        let (store, changes, _) = live()
        var snapshot = DemoData.snapshot(now: store.now)
        snapshot.records[try #require(snapshot.records.firstIndex { $0.id == key })].tags = nil
        store.receive(snapshot)
        let start = Date()
        let engine = Engine(store: store, snapshot: snapshot, now: start)
        changes.now = { engine.now }
        changes.checkEvery = .milliseconds(10)
        changes.readTags = { key in await engine.readTags(key) }
        let page = "pull requests in window 1"
        changes.setVisible(true, for: page)
        let following = Task { await changes.follow(key, on: page) }
        defer { following.cancel() }
        try await waitUntil { engine.reads == 1 && !changes.isReading(key) }
        #expect(store.record(for: key)?.tagsReadAt == start)

        changes.settings.makesChanges = false
        changes.settings.makesChanges = true
        engine.now = start.addingTimeInterval(TagChanges.readAgainAfter - 1)
        try await Task.sleep(for: .milliseconds(80))
        #expect(engine.reads == 1)
        // Ten minutes later, while they still show: read again, though this one fails.
        engine.answer = .failure(.offline)
        engine.now = start.addingTimeInterval(TagChanges.readAgainAfter)
        // Done with, as it failed then, before the clock moves on.
        try await waitUntil { engine.reads == 2 && !changes.isReading(key) }
        changes.settings.makesChanges = false
        changes.settings.makesChanges = true
        engine.now = start.addingTimeInterval(TagChanges.readAgainAfter + TagChanges.retryAfter - 1)
        try await Task.sleep(for: .milliseconds(80))
        #expect(engine.reads == 2)
        engine.answer = .success([PullRequestTag("deploy-eu")])
        engine.now = start.addingTimeInterval(TagChanges.readAgainAfter + TagChanges.retryAfter)
        try await waitUntil { engine.reads == 3 && !changes.isReading(key) }

        // In its lists again, which carry them: not on its own anymore.
        engine.listsCarry(key)
        engine.now = start.addingTimeInterval(TagChanges.readAgainAfter * 10)
        try await Task.sleep(for: .milliseconds(80))
        #expect(engine.reads == 3)
    }

    /// A stand-in for the engine's reads of tags, on a clock the test moves: it answers as Azure DevOps has them when the read
    /// starts, keeps what it reads in the list's snapshot, with when the read started, but for a pull request whose lists
    /// carry its tags, and publishes it before it answers, as the engine does. It can hold a read, as a slow answer, until
    /// it's let go.
    @MainActor final class Engine {
        var now: Date
        var answer: Result<[PullRequestTag], ADOError> = .success([PullRequestTag("deploy-eu")])
        /// Holds the next read, until `letGo()`.
        var holdsNext = false
        private(set) var reads = 0
        private(set) var isHolding = false
        private var held: CheckedContinuation<Void, Never>?
        private let store: PRStore
        private var snapshot: PulseSnapshot
        /// The pull requests whose lists carry their tags.
        private var carried: Set<PRKey> = []

        init(store: PRStore, snapshot: PulseSnapshot, now: Date) {
            self.store = store
            self.snapshot = snapshot
            self.now = now
        }

        func readTags(_ key: PRKey) async -> Result<[PullRequestTag], ADOError> {
            reads += 1
            let (answer, startedAt) = (answer, now)
            if holdsNext {
                holdsNext = false
                isHolding = true
                await withCheckedContinuation { held = $0 }
                isHolding = false
            }
            if case .success(let read) = answer, let index = snapshot.records.firstIndex(where: { $0.id == key }) {
                snapshot.records[index].tags = read
                snapshot.records[index].tagsReadAt = carried.contains(key) ? nil : startedAt
                store.receive(snapshot)
            }
            return answer
        }

        func letGo() {
            held?.resume()
            held = nil
        }

        /// Its lists carry its tags, as again: nothing says when they were read.
        func listsCarry(_ key: PRKey) {
            carried.insert(key)
            guard let index = snapshot.records.firstIndex(where: { $0.id == key }) else { return }
            snapshot.records[index].tagsReadAt = nil
            store.receive(snapshot)
        }
    }

    /// A pull request that left its lists but stays, as one sent to you, keeps the tags they read last, with when (as the
    /// engine has it): its details, on screen, read them once that's ten minutes ago, and not while it's less.
    @Test func readsTheTagsOfAPullRequestThatLeftItsListsOnceTenMinutesOld() async throws {
        let (store, changes, _) = live()
        let now = Date()
        changes.now = { now }
        var snapshot = DemoData.snapshot(now: store.now)
        let index = try #require(snapshot.records.firstIndex { $0.id == key })
        snapshot.records[index].tagsReadAt = now.addingTimeInterval(-TagChanges.readAgainAfter + 60)
        store.receive(snapshot)
        var reads = 0
        changes.readTags = { _ in
            reads += 1
            return .success([PullRequestTag("deploy-eu")])
        }
        let page = "pull requests in window 1"
        changes.setVisible(true, for: page)
        let recent = Task { await changes.follow(key, on: page) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(reads == 0)
        recent.cancel()
        snapshot.records[index].tagsReadAt = now.addingTimeInterval(-TagChanges.readAgainAfter - 60)
        store.receive(snapshot)
        let old = Task { await changes.follow(key, on: page) }
        defer { old.cancel() }
        try await waitUntil { reads == 1 }
    }

    /// A change Azure DevOps may have made though it didn't say how, as one Azure Front Door answered 503 once Azure DevOps
    /// took too long, has its pull request's tags read again: though their lists carry them, and when that read can't go yet,
    /// as nothing goes out for a while after a 503, they're read as soon as they can be while its details show, and show
    /// as Azure DevOps has them; then not again on their own.
    @Test func tagsAChangeMayHaveChangedAreReadAgainOnceTheyCanBe() async throws {
        let (store, changes, azure) = live()
        let start = Date()
        let engine = Engine(store: store, snapshot: DemoData.snapshot(now: store.now), now: start)
        engine.listsCarry(key)
        changes.now = { engine.now }
        changes.checkEvery = .milliseconds(10)
        changes.readTags = { key in await engine.readTags(key) }
        let page = "pull requests in window 1"
        changes.setVisible(true, for: page)
        let following = Task { await changes.follow(key, on: page) }
        defer { following.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.reads == 0)

        azure.fails = .network(ADOClient.unansweredMessage)
        engine.answer = .failure(.throttled(retryAfter: 60))
        #expect(await changes.add("hotfix", to: key) == false)
        #expect(changes.state(of: key) == .failed(.unanswered, .add("hotfix")))
        try await waitUntil { engine.reads == 1 && !changes.isReading(key) }
        #expect(tags(store) == ["deploy-eu", "needs-qa"])
        try await Task.sleep(for: .milliseconds(80))
        #expect(engine.reads == 1)
        // Half a minute later, it can: it was made.
        engine.answer = .success(["deploy-eu", "hotfix", "needs-qa"].map { PullRequestTag($0) })
        engine.now = start.addingTimeInterval(TagChanges.retryAfter)
        try await waitUntil { engine.reads == 2 }
        #expect(tags(store) == ["deploy-eu", "hotfix", "needs-qa"])
        engine.now = start.addingTimeInterval(TagChanges.readAgainAfter * 10)
        try await Task.sleep(for: .milliseconds(80))
        #expect(engine.reads == 2)
    }

    /// While the tags are read again after a change that may have gone, its details, on screen, don't read them too: one
    /// request, which settles them.
    @Test func readsAChangesTagsOnceWhileTheyShow() async throws {
        let (store, changes, azure) = live()
        let start = Date()
        let engine = Engine(store: store, snapshot: DemoData.snapshot(now: store.now), now: start)
        engine.listsCarry(key)
        changes.now = { engine.now }
        changes.checkEvery = .milliseconds(10)
        changes.readTags = { key in await engine.readTags(key) }
        let page = "pull requests in window 1"
        changes.setVisible(true, for: page)
        let following = Task { await changes.follow(key, on: page) }
        defer { following.cancel() }
        azure.fails = .network(ADOClient.unansweredMessage)
        engine.answer = .success(["deploy-eu", "hotfix", "needs-qa"].map { PullRequestTag($0) })
        engine.holdsNext = true
        #expect(await changes.add("hotfix", to: key) == false)
        try await waitUntil { engine.isHolding }
        try await Task.sleep(for: .milliseconds(80))
        #expect(engine.reads == 1)
        engine.letGo()
        try await waitUntil { !engine.isHolding && !changes.isReading(key) }
        #expect(tags(store) == ["deploy-eu", "hotfix", "needs-qa"])
        try await Task.sleep(for: .milliseconds(80))
        #expect(engine.reads == 1)
    }

    /// A read of the tags that started before a change Azure DevOps may have made, and answers after it, has them as they were
    /// then: they're read again all the same, once they can be.
    @Test func aReadThatStartedBeforeAChangeDoesntCountForIt() async throws {
        let (store, changes, azure) = live()
        let start = Date()
        var snapshot = DemoData.snapshot(now: store.now)
        snapshot.records[try #require(snapshot.records.firstIndex { $0.id == key })].tagsReadAt =
            start.addingTimeInterval(-TagChanges.readAgainAfter - 60)
        store.receive(snapshot)
        let engine = Engine(store: store, snapshot: snapshot, now: start)
        engine.answer = .success([PullRequestTag("deploy-eu"), PullRequestTag("needs-qa")])
        engine.holdsNext = true
        changes.now = { engine.now }
        changes.checkEvery = .milliseconds(10)
        changes.readTags = { key in await engine.readTags(key) }
        let page = "pull requests in window 1"
        changes.setVisible(true, for: page)
        let following = Task { await changes.follow(key, on: page) }
        defer { following.cancel() }
        try await waitUntil { engine.isHolding }

        // Meanwhile a change goes, which Azure DevOps doesn't answer in time, and the read after it can't go yet.
        engine.now = start.addingTimeInterval(1)
        azure.fails = .network(ADOClient.unansweredMessage)
        engine.answer = .failure(.throttled(retryAfter: 60))
        #expect(await changes.add("hotfix", to: key) == false)
        try await waitUntil { engine.reads == 2 }
        engine.letGo()
        try await waitUntil { !engine.isHolding && !changes.isReading(key) }
        #expect(tags(store) == ["deploy-eu", "needs-qa"])
        // The one that started before the change answered since, as the tags were: not again before half a minute after
        // the read that failed, as nothing could go meanwhile.
        try await Task.sleep(for: .milliseconds(80))
        #expect(engine.reads == 2)
        // Then read again, with the change.
        engine.answer = .success(["deploy-eu", "hotfix", "needs-qa"].map { PullRequestTag($0) })
        engine.now = start.addingTimeInterval(1 + TagChanges.retryAfter)
        try await waitUntil { tags(store) == ["deploy-eu", "hotfix", "needs-qa"] }
    }

    /// Azure DevOps turned off calls off the reads of tags under way, as one waiting for the Azure CLI's sign-in: what it
    /// answers after does nothing, and nothing more is read or changed, though the details still show.
    @Test func stoppingCallsOffTheReadsUnderWay() async throws {
        let (store, changes, azure) = live()
        var snapshot = DemoData.snapshot(now: store.now)
        snapshot.records[try #require(snapshot.records.firstIndex { $0.id == key })].tags = nil
        store.receive(snapshot)
        var started = 0
        var calledOff = false
        changes.readTags = { _ in
            started += 1
            // Waits, as for a token, until it's called off.
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                calledOff = true
            }
            return .success([PullRequestTag("deploy-eu")])
        }
        changes.checkEvery = .milliseconds(10)
        let page = "pull requests in window 1"
        changes.setVisible(true, for: page)
        let following = Task { await changes.follow(key, on: page) }
        defer { following.cancel() }
        try await waitUntil { started == 1 }
        changes.stop()
        try await waitUntil { calledOff }
        changes.setVisible(true, for: page)
        let again = Task { await changes.follow(key, on: page) }
        defer { again.cancel() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(started == 1)
        #expect(await changes.add("hotfix", to: key) == false)
        #expect(azure.sent.isEmpty)
        #expect(tags(store) == nil)
    }

    /// After a change Azure DevOps answered, the engine reads the tags again, counted as a read of them, in a task that
    /// turning Azure DevOps off calls off, as one waiting for the Azure CLI's sign-in: what it answers after does nothing.
    @Test func stoppingCallsOffTheReadAfterAChange() async throws {
        let (store, changes, azure) = live()
        var started: [[String]] = []
        var calledOff = false
        changes.readAfterChange = { _, tags in
            started.append(tags.map(\.name))
            // Waits, as for a token, until it's called off.
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                calledOff = true
            }
            return .success(tags)
        }
        #expect(await changes.add("hotfix", to: key))
        try await waitUntil { started.count == 1 }
        #expect(started == [["deploy-eu", "hotfix", "needs-qa"]])
        #expect(changes.isReading(key))
        changes.stop()
        try await waitUntil { calledOff }
        #expect(!changes.isReading(key))
        #expect(azure.sent.count == 1)
        #expect(tags(store) == ["deploy-eu", "hotfix", "needs-qa"])
    }

    /// Undo offers the tag you took off while the pull request doesn't have it again: once someone else added it back, as the
    /// tags read since show, it goes, for good, and doesn't come back as they take it off again.
    @Test func undoGoesOnceTheTagIsBack() async throws {
        let (store, changes, _) = live()
        let tag = PullRequestTag("needs-qa", tagId: "demo-tag-needs-qa")
        await changes.remove(tag, from: key)
        #expect(tags(store) == ["deploy-eu"])
        #expect(changes.undoable(on: key, tags: store.record(for: key)?.tags) == tag)
        // The engine has the change, as it keeps it; then someone else added it back, as it read since.
        var snapshot = DemoData.snapshot(now: store.now)
        let index = try #require(snapshot.records.firstIndex { $0.id == key })
        snapshot.records[index].tags = [PullRequestTag("deploy-eu")]
        store.receive(snapshot)
        #expect(changes.undoable(on: key, tags: store.record(for: key)?.tags) == tag)
        snapshot.records[index].tags = [PullRequestTag("deploy-eu"), PullRequestTag("needs-qa")]
        store.receive(snapshot)
        #expect(tags(store) == ["deploy-eu", "needs-qa"])
        #expect(changes.undoable(on: key, tags: store.record(for: key)?.tags) == nil)
        // They take it off again: that's not yours to undo.
        snapshot.records[index].tags = [PullRequestTag("deploy-eu")]
        store.receive(snapshot)
        #expect(changes.undoable(on: key, tags: store.record(for: key)?.tags) == nil)
    }

    /// A removal that Azure DevOps answers after the details showing the pull request closed offers no Undo: not as they show
    /// it again either.
    @Test func aRemovalAnsweredAfterTheDetailsCloseOffersNoUndo() async throws {
        let (store, changes, azure) = live()
        var letGo = false
        changes.send = { write, _ in
            while !letGo { try await Task.sleep(for: .milliseconds(5)) }
            return try azure.send(write)
        }
        let shown = Task { await changes.follow(key, on: nil) }
        try await Task.sleep(for: .milliseconds(20))
        let tag = PullRequestTag("needs-qa", tagId: "demo-tag-needs-qa")
        let removing = Task { await changes.remove(tag, from: key) }
        try await waitUntil { changes.isSending(key) }
        shown.cancel()
        await shown.value
        let again = Task { await changes.follow(key, on: nil) }
        defer { again.cancel() }
        try await Task.sleep(for: .milliseconds(20))
        letGo = true
        await removing.value
        #expect(tags(store) == ["deploy-eu"])
        #expect(changes.state(of: key) == nil)
        #expect(changes.undoable(on: key, tags: store.record(for: key)?.tags) == nil)
    }

    /// Tags are due to be read on their own when they're unknown, or when the lists don't carry them and they were read ten
    /// minutes ago or more; never while the lists carry them.
    @Test func tagsAreDueWhenUnknownOrReadTenMinutesAgo() throws {
        let (store, _, _) = live()
        let now = Date()
        var record = try #require(store.record(for: key))
        #expect(!TagChanges.isDue(record, at: now))
        record.tagsReadAt = now.addingTimeInterval(-TagChanges.readAgainAfter + 1)
        #expect(!TagChanges.isDue(record, at: now))
        record.tagsReadAt = now.addingTimeInterval(-TagChanges.readAgainAfter)
        #expect(TagChanges.isDue(record, at: now))
        record.tags = nil
        record.tagsReadAt = nil
        #expect(TagChanges.isDue(record, at: now))
    }

    /// Waits for what the changes do, which runs on the main actor between this test's awaits, for as long as a busy machine
    /// could need (`waitLimit`), failing the test if it doesn't happen.
    private func waitUntil(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
