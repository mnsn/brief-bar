import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Where a pull request opens from anywhere in BriefBar: its details in the window, at the comment or the run it's about,
/// from the window's pages, and, once you choose to Open Pull Requests in BriefBar, from the menu bar, widgets and
/// notifications; or else Azure DevOps. With the made-up pull requests, which never use the Azure CLI or Azure DevOps,
/// and nothing here opens Azure DevOps: each test only notes where it would.
@MainActor
@Suite struct OpeningPullRequestsTests {
    private let records: [PRRecord]
    private let items: [PRSnapshot]

    init() {
        let now = Date()
        let seen = DemoData.seenState(now: now)
        records = DemoData.records(now: now)
        items = PROrdering.sorted(records.compactMap {
            PRClassifier.snapshot(for: $0, seenCutoff: seen.cutoff(for: $0.id), dismissedCutoff: seen.dismissedCutoff(for: $0.id), now: now)
        })
    }

    private func item(_ number: Int) throws -> PRSnapshot {
        try #require(items.first { $0.key.number == number })
    }

    private func record(_ number: Int) -> PRRecord? {
        records.first { $0.id.number == number }
    }

    /// Where each pull request opened: its details in the window, and Azure DevOps.
    private final class Openings {
        var pages = 0
        var azureDevOps: [Int] = []
        var seen: [Int] = []
    }

    /// The details of the made-up pull requests, as the list read them, with a window that has the Pull Requests page or
    /// not, and Open Pull Requests in BriefBar on or off.
    private func makeStore(hasPage: Bool = true, inBriefBar: Bool = false) -> (PullRequestDetailsStore, Openings) {
        let openings = Openings()
        let store = PullRequestDetailsStore()
        let records = records
        store.readRecord = { key in records.first { $0.id == key } }
        store.markSeen = { openings.seen.append($0.key.number) }
        store.openInAzureDevOps = { openings.azureDevOps.append($0.key.number) }
        store.opensInBriefBar = { inBriefBar }
        store.hasPage = { hasPage }
        store.openPage = { openings.pages += 1 }
        store.itemsChanged(items)
        return (store, openings)
    }

    typealias Place = PullRequestDetailsStore.Place

    /// The comment that needs you, the run after a merge that waits for an approval, or the build that failed; the top of the
    /// details for what's ready, and for conflicts, which have no part of their own.
    @Test func aRowIsAboutTheCommentOrTheRunItSays() throws {
        #expect(Place.about(try item(4102), record: record(4102)) == .thread(11))
        #expect(Place.about(try item(4097), record: record(4097)) == .thread(21))
        #expect(Place.about(try item(4085), record: record(4085)) == .run(82_109))
        #expect(Place.about(try item(4088), record: record(4088)) == .run(204_417))
        #expect(Place.about(try item(4091), record: record(4091)) == nil)
        #expect(Place.about(try item(4079), record: record(4079)) == nil)
        // A failing build whose checks the list hasn't read: nothing to go to.
        #expect(Place.about(try item(4088), record: nil) == nil)
        // Answered, at the comment you answered.
        var answered = try item(4102)
        answered.group = .answered
        #expect(Place.about(answered, record: record(4102)) == .thread(11))
    }

    /// A thread, a build or a check the details don't have, such as a run that isn't one a policy queued last, takes you to
    /// their comments, or their builds and checks.
    @Test func goesToTheirPartForWhatTheyDontHave() throws {
        let retry = PullRequestPanel(try item(4102), record: record(4102))
        #expect(Place.thread(11).anchor(in: retry) == .thread(11))
        #expect(Place.thread(13).anchor(in: retry) == .thread(13))
        #expect(Place.thread(999).anchor(in: retry) == .section(.comments))
        #expect(Place.run(1).anchor(in: retry) == .section(.checks))
        #expect(Place.check("Nothing of the kind").anchor(in: retry) == .section(.checks))
        #expect(Place.section(.reviewers).anchor(in: retry) == .section(.reviewers))
        let failing = PullRequestPanel(try item(4088), record: record(4088))
        #expect(Place.run(204_417).anchor(in: failing) == .check("run 204417"))
        // Without what the list read: their parts.
        let bare = PullRequestPanel(try item(4088), record: nil)
        #expect(Place.thread(43).anchor(in: bare) == .section(.comments))
        #expect(Place.run(204_417).anchor(in: bare) == .section(.checks))
    }

    /// From the menu bar, a widget or the brief: Azure DevOps, until you choose to Open Pull Requests in BriefBar; then its
    /// details, at what it's about, while a window has the page.
    @Test func opensWhereYouChose() throws {
        let (store, openings) = makeStore()
        store.open(try item(4102))
        #expect(openings.azureDevOps == [4102])
        #expect(store.selected == nil && openings.pages == 0 && openings.seen.isEmpty)

        let (chosen, inBriefBar) = makeStore(inBriefBar: true)
        chosen.open(try item(4088))
        #expect(chosen.selected?.key.number == 4088)
        #expect(chosen.place == .run(204_417))
        #expect(inBriefBar.pages == 1 && inBriefBar.seen == [4088] && inBriefBar.azureDevOps.isEmpty)

        let (pageless, withoutPage) = makeStore(hasPage: false, inBriefBar: true)
        pageless.open(try item(4088))
        #expect(pageless.selected == nil)
        #expect(withoutPage.azureDevOps == [4088] && withoutPage.pages == 0)
    }

    /// From another page of the window, such as the Overview, its details, whatever you chose for the menu bar; Azure
    /// DevOps only when no window has the page.
    @Test func showsItsDetailsFromTheWindow() throws {
        let (store, openings) = makeStore()
        store.showDetails(try item(4102))
        #expect(store.selected?.key.number == 4102)
        #expect(store.place == .thread(11))
        #expect(openings.pages == 1 && openings.seen == [4102] && openings.azureDevOps.isEmpty)

        let (pageless, withoutPage) = makeStore(hasPage: false)
        pageless.showDetails(try item(4102))
        #expect(pageless.selected == nil)
        #expect(withoutPage.azureDevOps == [4102])
    }

    /// A notification shows its own thread or run, rather than the one its row is about; one about the pull request itself,
    /// what its row is about. One about a pull request the list doesn't have shows nothing, for its link to open instead.
    @Test func aNotificationShowsWhatItsAbout() throws {
        let (store, openings) = makeStore()
        let organization = DemoData.organization
        let resolved = ADOEndpoint.pullRequestPage(organization: organization, project: "Storefront", repository: "payments-api",
                                                   id: 4102, threadId: 13)
        #expect(store.reveal(notification: "\(organization)/4102", link: resolved))
        #expect(store.selected?.key.number == 4102 && store.place == .thread(13))

        let run = ADOEndpoint.buildPage(organization: organization, project: "Storefront", buildId: 82_109)
        #expect(store.reveal(notification: "\(organization)/4085", link: run))
        #expect(store.selected?.key.number == 4085 && store.place == .run(82_109))

        // "Build failed", which links to the pull request: the build that failed.
        let failing = try item(4088)
        #expect(store.reveal(notification: failing.key.description, link: failing.pageURL()))
        #expect(store.selected?.key.number == 4088 && store.place == .run(204_417))
        #expect(openings.seen == [4102, 4085, 4088] && openings.pages == 3)

        for key in ["\(organization)/1", "4102", "", nil] {
            #expect(!store.reveal(notification: key, link: resolved), "\(key ?? "nil")")
        }
        #expect(store.selected?.key.number == 4088)
        let (pageless, _) = makeStore(hasPage: false)
        #expect(!pageless.reveal(notification: "\(organization)/4102", link: resolved))
        #expect(openings.azureDevOps.isEmpty)
    }

    /// Off until you turn it on, and kept once you do; the details follow it.
    @Test func openingInBriefBarIsOffUntilYouTurnItOn() {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.opensPullRequestsInBriefBar)
        let list = PRStore(settings: settings, mode: .demo)
        let details = PullRequestDetailsStore()
        details.use(list)
        #expect(!details.opensInBriefBar())
        settings.opensPullRequestsInBriefBar = true
        #expect(details.opensInBriefBar())
        #expect(AppSettings(defaults: defaults).opensPullRequestsInBriefBar)
        settings.opensPullRequestsInBriefBar = false
        #expect(!AppSettings(defaults: defaults).opensPullRequestsInBriefBar)
    }

    /// A pull request's page over a work item's details, or another pull request's, is its own details while the list has
    /// it; anything else is what Show Links knows of it.
    @Test func aPullRequestsPageIsItsDetailsWhileTheListHasIt() throws {
        let retry = try item(4102)
        #expect(LinkedItemPage.pullRequest(retry.key.linkRef, in: items) == retry)
        #expect(LinkedItemPage.pullRequest(.pullRequest(organization: "CONTOSO", number: 4102), in: items) == retry)
        #expect(LinkedItemPage.pullRequest(.pullRequest(organization: DemoData.organization, number: 1), in: items) == nil)
        #expect(LinkedItemPage.pullRequest(.workItem(organization: DemoData.organization, id: 4102), in: items) == nil)
        #expect(LinkedItemPage.pullRequest(ItemRef.session("1d6b2c7e-4f0a-4b8e-9c31-5a2e7d8f6b01")!, in: items) == nil)
    }

    /// One under Done that you hadn't seen leaves the list once its page sees it: the page keeps it, with what was read of
    /// it, until you go elsewhere, rather than turning into what Show Links knows of it.
    @Test func aPagesPullRequestStaysOnceItLeavesTheList() async throws {
        let store = PRStore(settings: AppSettings(defaults: MemoryDefaults()), mode: .demo)
        // What `loadOnce` makes the demo up as of.
        let now = store.now
        await store.loadOnce()
        // You completed it a minute ago in Azure DevOps: the list doesn't read a closed one's threads and policies.
        var snapshot = DemoData.snapshot(now: now)
        let index = try #require(snapshot.records.firstIndex { $0.id.number == 4091 })
        snapshot.records[index].pullRequest.status = .completed
        snapshot.records[index].pullRequest.closedAt = Date().addingTimeInterval(-60)
        snapshot.records[index].details = nil
        store.receive(snapshot)
        let done = try #require(store.items.first { $0.key.number == 4091 })
        #expect(done.group == .done)
        let ref = done.key.linkRef
        let page = PullRequestDetailsStore()
        #expect(LinkedItemPage.pullRequest(ref, in: store.items, kept: page) == done)

        page.use(store)
        page.show(done)
        // The next refresh: seen, Done lets it go.
        store.receive(snapshot)
        #expect(!store.items.contains { $0.key == done.key })
        #expect(!page.isListed)
        #expect(LinkedItemPage.pullRequest(ref, in: store.items, kept: page) == done)
        #expect(page.record?.id == done.key)
        // Another pull request's page: the list's.
        let other = ItemRef.pullRequest(organization: DemoData.organization, number: 4102)
        #expect(LinkedItemPage.pullRequest(other, in: store.items, kept: page)?.key.number == 4102)
        // Gone elsewhere: the page lets it go too.
        page.close()
        #expect(LinkedItemPage.pullRequest(ref, in: store.items, kept: page) == nil)
    }

    /// Azure DevOps' own: a notification, from the window's Notifications page whatever you chose, and from Notification
    /// Center once you chose so, and the brief across sources, from the window's Overview, show the pull request in the
    /// window. Nothing here takes a path that would open Azure DevOps.
    @Test func notificationsAndTheBriefShowItInTheWindow() throws {
        let services = AppServices(defaults: MemoryDefaults(), isDemo: true)
        var opened: [SectionID?] = []
        services.hasPage = { $0 == .azureDevOpsPullRequests }
        services.openWindow = { opened.append($0) }
        let source = AzureDevOpsSource(services: services)
        source.start()
        defer { source.stop() }
        let details = try #require(source.pullRequestDetails)
        let organization = DemoData.organization
        #expect(!source.settings.opensPullRequestsInBriefBar)

        let thread = ADOEndpoint.pullRequestPage(organization: organization, project: "Storefront", repository: "payments-api",
                                                 id: 4102, threadId: 13)
        source.openNotificationInWindow(["url": thread.absoluteString, "pullRequest": "\(organization)/4102"])
        #expect(details.selected?.key.number == 4102 && details.place == .thread(13))
        #expect(opened == [.azureDevOpsPullRequests])

        source.settings.opensPullRequestsInBriefBar = true
        let run = ADOEndpoint.buildPage(organization: organization, project: "Storefront", buildId: 82_109)
        source.openNotification(["url": run.absoluteString, "pullRequest": "\(organization)/4085"])
        #expect(details.selected?.key.number == 4085 && details.place == .run(82_109))
        #expect(opened.count == 2)

        let lines = source.briefLines(for: .azureDevOpsPullRequests)
        let failing = try #require(lines.first { $0.id.hasPrefix("azureDevOps/\(organization)/4088:") })
        #expect(failing.show?() == true)
        #expect(details.selected?.key.number == 4088 && details.place == .run(204_417))
        // From the menu bar or a widget, as you chose.
        let mention = try #require(lines.first { $0.id.hasPrefix("azureDevOps/\(organization)/4097:") })
        mention.open()
        #expect(details.selected?.key.number == 4097 && details.place == .thread(21))
        #expect(opened.count == 4)
    }
}
