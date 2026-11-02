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

    /// A made-up pull request on which Jordan answered you in a resolved thread ten minutes ago: only a new comment in one
    /// waits on you.
    private func answeredInAResolvedThread(as role: PRRole = .author, now: Date) throws -> PRRecord {
        var record = try #require(DemoData.records(now: now).first { $0.id.number == 4102 })
        record.role = role
        record.details?.threads.append(ReviewThread(id: 90, status: "fixed", filePath: "/src/PaymentsClient.cs", line: 60, comments: [
            ReviewComment(id: 1, author: Person(id: record.me, name: "You"), text: "Fixed.", publishedAt: now.addingTimeInterval(-3 * 3_600)),
            ReviewComment(id: 2, author: Person(id: "jordan", name: "Jordan Lee"), text: "Not quite.", publishedAt: now.addingTimeInterval(-600)),
        ]))
        return record
    }

    /// Seeing a pull request in its details doesn't fold a resolved thread whose comment was new, or make what was new old,
    /// while they show it. Removing it from Needs You does, and so does another look at it.
    @Test func whatNeedsYouStaysAsWhenItShowed() throws {
        let now = Date()
        // You last looked an hour ago.
        let record = try answeredInAResolvedThread(now: now)
        var seen = now.addingTimeInterval(-3_600)
        var dismissed = Date.distantPast
        func row() throws -> PRSnapshot {
            try #require(PRClassifier.snapshot(for: record, seenCutoff: seen, dismissedCutoff: dismissed, now: now))
        }
        let store = PullRequestDetailsStore()
        store.readRecord = { _ in record }
        store.cutoffs = { _ in .init(seen: seen, dismissed: dismissed) }
        store.classify = { record, seen in PRClassifier.snapshot(for: record, seenCutoff: seen, dismissedCutoff: dismissed, now: now) }
        store.markSeen = { _ in seen = now }
        store.itemsChanged([try row()])
        store.show(try row())
        // The list has seen it: the thread doesn't wait on you there anymore.
        let seenRow = try row()
        store.itemsChanged([seenRow])
        #expect(PullRequestPanel(seenRow, record: record).threads.resolved.contains { $0.id == 90 })
        func threads() -> PullRequestPanel.Threads {
            PullRequestPanel(seenRow, record: record, events: store.pendingEvents(of: seenRow, record: record)).threads
        }
        // Its details still have it waiting on you, as new.
        #expect(threads().waitingOnYou.first { $0.id == 90 }?.isNew == true)
        // Shown again from its row, it's the same look at it.
        store.show(seenRow)
        #expect(threads().waitingOnYou.contains { $0.id == 90 })
        // Removed from Needs You, it doesn't wait on you.
        dismissed = now
        #expect(threads().resolved.contains { $0.id == 90 })
        dismissed = .distantPast
        // Nor after another look at it.
        store.close()
        store.show(seenRow)
        #expect(threads().resolved.contains { $0.id == 90 })
        // Another pull request's, as its row has it.
        let other = try item(4088)
        #expect(store.pendingEvents(of: other, record: nil) == other.pendingEvents)
    }

    /// One sent in a chat leaves the list once you've removed what waited on you there from Needs You. Its details stay as
    /// they were, but nothing in it waits on you anymore.
    @Test func nothingWaitsOnYouInOneThatLeftTheList() throws {
        let now = Date()
        let record = try answeredInAResolvedThread(as: .linked, now: now)
        let before = now.addingTimeInterval(-3_600)
        var dismissed = Date.distantPast
        let store = PullRequestDetailsStore()
        store.readRecord = { _ in record }
        store.cutoffs = { _ in .init(seen: before, dismissed: dismissed) }
        store.classify = { record, seen in PRClassifier.snapshot(for: record, seenCutoff: seen, dismissedCutoff: dismissed, now: now) }
        let row = try #require(PRClassifier.snapshot(for: record, seenCutoff: before, dismissedCutoff: dismissed, now: now))
        store.itemsChanged([row])
        store.show(row)
        #expect(store.pendingEvents(of: row, record: record).contains { $0.threadId == 90 })
        dismissed = now
        #expect(PRClassifier.snapshot(for: record, seenCutoff: before, dismissedCutoff: dismissed, now: now) == nil)
        store.itemsChanged([])
        #expect(!store.isListed && store.selected == row)
        #expect(store.pendingEvents(of: row, record: record).isEmpty)
        #expect(PullRequestPanel(row, record: record, events: store.pendingEvents(of: row, record: record)).threads.waitingOnYou.isEmpty)
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
        details.use(store)
        let mention = try #require(store.items.first { $0.key.number == 4097 })
        #expect(mention.hasNews)
        details.show(mention)
        // The next refresh.
        store.receive(DemoData.snapshot(now: now))
        let seen = try #require(store.items.first { $0.key.number == 4097 })
        #expect(seen.group == .needsYou)
        #expect(!seen.hasNews)
    }

    /// A refresh that leaves the pull request out, as a review that merged, keeps what was read of it with its last row,
    /// though the list read it again before it left it out.
    @Test func whatALeftPullRequestShowsStaysWithItsLastRow() async throws {
        let store = PRStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo)
        // What `loadOnce` makes the demo up as of.
        let now = store.now
        await store.loadOnce()
        let details = PullRequestDetailsStore()
        details.use(store)
        let review = try #require(store.items.first { $0.role == .reviewer })
        details.show(review)
        #expect(details.isListed)
        let row = try #require(details.selected)
        let read = try #require(details.record)
        // The next refresh reads it merged: done is for your own pull requests.
        var snapshot = DemoData.snapshot(now: now)
        snapshot.refreshedAt = now.addingTimeInterval(60)
        let index = try #require(snapshot.records.firstIndex { $0.id == review.key })
        snapshot.records[index].pullRequest.status = .completed
        snapshot.records[index].pullRequest.closedAt = now
        store.receive(snapshot)
        #expect(!store.items.contains { $0.key == review.key })
        #expect(store.record(for: review.key)?.pullRequest.status == .completed)
        #expect(!details.isListed)
        #expect(details.selected == row)
        #expect(details.record == read)
    }

    /// Removed from Needs You from its row, which, seen, no longer has the new comment in a resolved thread that its details
    /// still show, and so is taken off only up to an older one, a reply in an open thread: then what you've seen is seen
    /// in its details too.
    @Test func removingItFromNeedsYouSeesWhatOnlyItsDetailsShowed() async throws {
        let settings = AppSettings(defaults: MemoryDefaults())
        let store = PRStore(settings: settings, mode: .demo)
        // What `loadOnce` makes the demo up as of.
        let now = store.now
        await store.loadOnce()
        // A minute ago, Jordan commented in a resolved thread, after Sam's reply in an open one, which you've seen.
        var snapshot = DemoData.snapshot(now: now)
        let index = try #require(snapshot.records.firstIndex { $0.id.number == 4102 })
        var read = try #require(snapshot.records[index].details)
        let resolved = try #require(read.threads.firstIndex { $0.id == 13 && $0.isResolved })
        let comment = ReviewComment(id: 3, author: Person(id: "jordan", name: "Jordan Lee"), text: "One more thing.",
                                    publishedAt: now.addingTimeInterval(-60))
        read.threads[resolved].comments.append(comment)
        read.lastActivity = comment.publishedAt
        snapshot.records[index].details = read
        store.receive(snapshot)
        let row = try #require(store.items.first { $0.key.number == 4102 })
        #expect(row.pendingEvents.contains { $0.threadId == 13 && $0.isNew })
        #expect(row.pendingEvents.contains { $0.threadId != 13 && !$0.isNew })

        let details = PullRequestDetailsStore()
        details.use(store)
        details.show(row)
        store.receive(snapshot)
        func waiting() throws -> [Int] {
            let item = try #require(details.selected)
            let record = store.record(for: item.key)
            return PullRequestPanel(item, record: record, events: details.pendingEvents(of: item, record: record)).threads.waitingOnYou.map(\.id)
        }
        let seen = try #require(store.items.first { $0.key.number == 4102 })
        #expect(!seen.pendingEvents.contains { $0.threadId == 13 })
        #expect(try waiting().contains(13))

        store.dismiss(seen)
        store.receive(snapshot)
        #expect(try !waiting().contains(13))
        #expect(try waiting().isEmpty)
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
