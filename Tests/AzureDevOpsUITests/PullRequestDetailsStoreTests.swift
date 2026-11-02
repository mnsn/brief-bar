import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation
import Testing
@testable import AzureDevOpsUI

/// The pull request whose details show beside the window's list: which one, the pages opened over it, where in it to go,
/// and that it follows the list, sees what it shows, and closes for someone else. With the made-up pull requests, which
/// never use the Azure CLI or Azure DevOps.
@MainActor
@Suite struct PullRequestDetailsStoreTests {
    private let items: [PRSnapshot]

    init() {
        let now = Date()
        let seen = DemoData.seenState(now: now)
        items = PROrdering.sorted(DemoData.records(now: now).compactMap {
            PRClassifier.snapshot(for: $0, seenCutoff: seen.cutoff(for: $0.id), dismissedCutoff: seen.dismissedCutoff(for: $0.id), now: now)
        })
    }

    private func item(_ number: Int) throws -> PRSnapshot {
        try #require(items.first { $0.key.number == number })
    }

    private func makeStore(seen: @escaping (PRSnapshot) -> Void = { _ in }) -> PullRequestDetailsStore {
        let store = PullRequestDetailsStore()
        store.markSeen = seen
        store.itemsChanged(items)
        return store
    }

    private let workItem = ItemRef.workItem(organization: DemoData.organization, id: 5160)
    private let session = ItemRef.session("1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b01")!

    @Test func showingAPullRequestSeesIt() throws {
        var seen: [PRKey] = []
        let store = makeStore { seen.append($0.key) }
        #expect(store.selected == nil)
        store.show(try item(4102))
        #expect(store.selected?.key.number == 4102)
        #expect(store.pages.isEmpty && store.place == nil && !store.canGoBack)
        #expect(seen.map(\.number) == [4102])
        // Another one, at a thread: what was open over the first goes.
        store.open(page: workItem)
        store.show(try item(4088), at: .thread(43))
        #expect(store.selected?.key.number == 4088)
        #expect(store.pages.isEmpty)
        #expect(store.place == .thread(43))
        #expect(seen.map(\.number) == [4102, 4088])
        store.close()
        #expect(store.selected == nil && store.place == nil)
    }

    @Test func pagesOpenOverTheDetailsAndGoBack() throws {
        let store = makeStore()
        // Nothing opens over nothing.
        store.open(page: workItem)
        #expect(store.pages.isEmpty)

        let retry = try item(4102)
        store.show(retry)
        store.open(page: workItem)
        store.open(page: session)
        #expect(store.pages == [workItem, session])
        #expect(store.canGoBack)
        // One that shows already, under the one on top: back to it.
        store.open(page: workItem)
        #expect(store.pages == [workItem])
        store.open(page: session)
        store.back(toPage: 0)
        #expect(store.pages == [workItem])
        store.back(toPage: 5)
        #expect(store.pages == [workItem])
        store.back()
        #expect(store.pages.isEmpty)
        store.back()
        #expect(store.selected?.key == retry.key)
        // The pull request itself, from a page: its details.
        store.open(page: session)
        store.open(page: retry.key.linkRef)
        #expect(store.pages.isEmpty)
        store.open(page: session)
        store.back(toPage: nil)
        #expect(store.pages.isEmpty)
        // Show Links went off.
        store.open(page: workItem)
        store.closePages()
        #expect(store.pages.isEmpty && store.selected?.key == retry.key)
    }

    @Test func goesToAPlaceInTheDetailsOnce() throws {
        let store = makeStore()
        store.go(to: .section(.comments))
        #expect(store.place == nil)

        store.show(try item(4102))
        store.open(page: workItem)
        store.go(to: .section(.comments))
        // From the pages too.
        #expect(store.pages.isEmpty)
        #expect(store.place == .section(.comments))
        // Somewhere else meanwhile: going there doesn't stop it.
        store.reached(.thread(11))
        #expect(store.place == .section(.comments))
        store.reached(.section(.comments))
        #expect(store.place == nil)
    }

    @Test func followsTheListAndKeepsWhatItLeft() throws {
        let store = makeStore()
        let records = DemoData.records(now: Date())
        var read = try #require(records.first { $0.id.number == 4102 })
        store.readRecord = { key in key == read.id ? read : nil }
        var retry = try item(4102)
        store.show(retry)
        #expect(store.isListed)
        #expect(store.record == read)
        retry.headline = "Sam Rivera replied again"
        read.details?.threads.removeAll()
        store.itemsChanged(items.map { $0.key == retry.key ? retry : $0 })
        #expect(store.selected?.headline == "Sam Rivera replied again")
        #expect(store.record?.details?.threads.isEmpty == true)
        // A refresh that changes what was read of it, but not its row, such as an optional build that passed.
        read.details?.checks = [Check(name: "lint", kind: .build, state: .passed, isBlocking: false)]
        store.recordsChanged()
        #expect(store.record?.details?.checks.map(\.name) == ["lint"])
        // No longer listed, as a review that merged, it stays as it was last, threads, policies and reviewers too, until
        // you close it, even once the list has forgotten what it read.
        store.itemsChanged(items.filter { $0.key != retry.key })
        #expect(!store.isListed)
        #expect(store.selected?.headline == "Sam Rivera replied again")
        #expect(store.record?.id == retry.key)
        // While the list still reads it, as one sent in a chat that you've seen, what's kept doesn't follow either.
        read.details?.checks = []
        store.recordsChanged()
        #expect(store.record?.details?.checks.map(\.name) == ["lint"])
        store.readRecord = { _ in nil }
        store.recordsChanged()
        #expect(store.record?.details?.checks.map(\.name) == ["lint"])
        store.close()
        #expect(store.record == nil && !store.isListed)
    }

    @Test func someoneElseSigningInClosesIt() throws {
        let store = makeStore()
        store.accountChanged("robin@contoso.com")
        store.show(try item(4102))
        store.accountChanged(nil)
        store.accountChanged("robin@contoso.com")
        #expect(store.selected != nil)
        store.accountChanged("sam@contoso.com")
        #expect(store.selected == nil)
        // The list stays as it is until the new one's is read, which may be the same: what it has shows as listed.
        store.show(try item(4102))
        #expect(store.isListed)
    }

    /// A place resolves to one thing to scroll to: a build by its run, a check by its name, the first of that name.
    @Test func aPlaceLeadsToOneRow() throws {
        let now = Date()
        let seen = DemoData.seenState(now: now)
        let record = try #require(DemoData.records(now: now).first { $0.id.number == 4088 })
        var twins = record
        twins.details?.checks += [
            Check(name: "Status check", kind: .status, state: .pending), Check(name: "Status check", kind: .status, state: .passed),
        ]
        let row = try #require(PRClassifier.snapshot(
            for: twins, seenCutoff: seen.cutoff(for: twins.id), dismissedCutoff: seen.dismissedCutoff(for: twins.id), now: now
        ))
        let lines = PullRequestPanel(row, record: twins).checks
        typealias Place = PullRequestDetailsStore.Place
        #expect(Place.run(204_417).anchor(in: lines) == .check("run 204417"))
        #expect(Place.check("Status check").anchor(in: lines) == .check("check Status check"))
        #expect(Set(lines.map { PullRequestDetailsStore.Anchor.check($0.id) }).count == lines.count)
        #expect(Place.run(1).anchor(in: lines) == nil)
        #expect(Place.thread(43).anchor(in: lines) == .thread(43))
        #expect(Place.section(.reviewers).anchor(in: lines) == .section(.reviewers))
    }

    /// From a list, a widget or a notification: the details on the Pull Requests page, in BriefBar's window, while one
    /// shows that page.
    @Test func revealsAPullRequestOnThePage() throws {
        var seen: [Int] = []
        var opened = 0
        let store = makeStore { seen.append($0.key.number) }
        store.openPage = { opened += 1 }
        #expect(!store.reveal(try item(4088), at: .run(204_417)))
        #expect(store.selected == nil && opened == 0 && seen.isEmpty)

        store.hasPage = { true }
        #expect(store.reveal(try item(4088), at: .run(204_417)))
        #expect(store.selected?.key.number == 4088)
        #expect(store.place == .run(204_417))
        #expect(opened == 1 && seen == [4088])
        // By its key, one the list has, however its organization is spelled.
        #expect(store.reveal(PRKey("Contoso", 4102), at: .thread(11)))
        #expect(store.selected?.key.number == 4102)
        #expect(store.place == .thread(11))
        #expect(!store.reveal(PRKey(DemoData.organization, 1)))
        #expect(store.selected?.key.number == 4102)
    }

    @Test func forgetsEverythingWhenStopped() throws {
        let store = makeStore()
        store.hasPage = { true }
        store.show(try item(4102), at: .section(.reviewers))
        store.open(page: workItem)
        store.stop()
        #expect(store.selected == nil && store.pages.isEmpty && store.place == nil)
        #expect(!store.reveal(PRKey(DemoData.organization, 4102)))
    }

    /// Seen as opening it is: what needs you there now is no longer new, and a comment that waits on you still does.
    @Test func showingItsDetailsSeesItAsOpeningItDoes() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = PRStore(settings: settings, mode: .demo)
        // What `loadOnce` makes the demo up as of.
        let now = store.now
        await store.loadOnce()
        let details = PullRequestDetailsStore()
        details.markSeen = { [weak store] in store?.markSeen($0) }
        let mention = try #require(store.items.first { $0.key.number == 4097 })
        #expect(mention.hasNews)
        details.show(mention)
        // The next refresh.
        store.receive(DemoData.snapshot(now: now))
        let seen = try #require(store.items.first { $0.key.number == 4097 })
        #expect(seen.group == .needsYou)
        #expect(!seen.hasNews)
    }

    @Test func keepsHowWideYouMadeTheDetails() {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.pullRequestDetailsWidth == nil)
        settings.pullRequestDetailsWidth = 520
        #expect(AppSettings(defaults: defaults).pullRequestDetailsWidth == 520)
        // The Sprint page keeps its own.
        #expect(AppSettings(defaults: defaults).sprintDetailsWidth == nil)
        settings.pullRequestDetailsWidth = nil
        #expect(defaults.object(forKey: SettingsKey.pullRequestDetailsWidth) == nil)
        for odd: Any in [Double.nan, Double.infinity, -40.0, 0.0, "wide"] {
            defaults.set(odd, forKey: SettingsKey.pullRequestDetailsWidth)
            #expect(AppSettings(defaults: defaults).pullRequestDetailsWidth == nil)
        }
    }

    /// While Copilot is at work on a pull request, what's left that its task takes care of is its turn, not yours.
    @Test func aTaskTakesCareOfWhatItWasSentFor() {
        #expect(PullRequestAction.fixComments.takesCare(of: .comments))
        #expect(!PullRequestAction.fixComments.takesCare(of: .builds))
        #expect(PullRequestAction.fixBuild.takesCare(of: .builds))
        #expect(!PullRequestAction.fixBuild.takesCare(of: .checks))
        #expect(PullRequestAction.resolveConflicts.takesCare(of: .conflicts))
        #expect([.comments, .builds, .conflicts].allSatisfy { PullRequestAction.pushAndReply.takesCare(of: $0) })
        #expect(!PullRequestAction.review.takesCare(of: .comments))
        // Approvals, drafts and linked work items are never Copilot's.
        for action in PullRequestAction.allCases {
            #expect(![.approvals, .requiredReviewers, .draft, .workItems].contains { action.takesCare(of: $0) }, "\(action)")
        }
    }

    /// ↗ opens what the row opens: the comment that needs you, the one you answered, or the run after a merge.
    @Test func saysWhatOpenInAzureDevOpsOpens() throws {
        #expect(PullRequestDetailsPanel.openHelp(try item(4102)) == "Open in Azure DevOps, at the comment that needs you")
        #expect(PullRequestDetailsPanel.openHelp(try item(4091)) == "Open in Azure DevOps")
        #expect(PullRequestDetailsPanel.openHelp(try item(4085)) == "Open the run after its merge in Azure DevOps")
        var answered = try item(4102)
        answered.group = .answered
        #expect(PullRequestDetailsPanel.openHelp(answered) == "Open in Azure DevOps, at the comment you answered")
    }
}
