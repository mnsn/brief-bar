import BriefBarCore
import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsCore

@Suite struct WorkLinksTests {
    // MARK: Reading the responses

    @Test func readsAPullRequestsWorkItemsAsAzureDevOpsSendsThem() throws {
        let refs = try Fixture.decode(ADOWorkItemRefs.self, [
            "count": 4,
            "value": [
                ["id": "5101", "url": "https://example.invalid/5101"], ["id": 5110, "url": "https://example.invalid/5110"],
                ["id": "not a number"], ["url": "https://example.invalid"], "junk",
            ] as [Any],
        ])
        #expect(refs.ids == [5101, 5110])
        #expect(try Fixture.decode(ADOWorkItemRefs.self, ["count": 0]).ids.isEmpty)
    }

    @Test func findsAWorkItemsPullRequestsAmongItsRelations() throws {
        let item = try Fixture.decode(ADOWorkItemRelations.self, [
            "id": 5101, "fields": ["System.Title": "Save items for later"],
            "relations": [
                ["rel": "ArtifactLink", "url": "vstfs:///Git/PullRequestId/p1%2Fr1%2F4120", "attributes": ["name": "Pull Request"]],
                ["rel": "ArtifactLink", "url": "vstfs:///Git/PullRequestId/p1%2Fr2%2F4071", "attributes": ["name": "Pull Request"]],
                ["rel": "ArtifactLink", "url": "vstfs:///Git/PullRequestId/p1%2Fr1%2F4120"],
                ["rel": "ArtifactLink", "url": "vstfs:///Git/Ref/p1%2Fr1%2FGBsaved-items", "attributes": ["name": "Branch"]],
                ["rel": "ArtifactLink", "url": "vstfs:///Git/Commit/p1%2Fr1%2Fabc123"],
                ["rel": "System.LinkTypes.Hierarchy-Reverse", "url": "https://dev.azure.com/contoso/_apis/wit/workItems/5100"],
                ["rel": "Hyperlink", "url": "https://example.invalid/pullrequest/9"],
            ] as [Any],
        ])
        #expect(item.pullRequests(in: "Contoso") == [PRKey("contoso", 4071), PRKey("contoso", 4120)])
        // Without relations, there's nothing linked.
        #expect(try Fixture.decode(ADOWorkItemRelations.self, ["id": 5102]).pullRequests(in: "contoso").isEmpty)
    }

    @Test func readsOnlyPullRequestLinksThatAreWhole() {
        #expect(ArtifactLink.pullRequest("vstfs:///Git/PullRequestId/p1%2Fr1%2F4120")?.id == 4120)
        #expect(ArtifactLink.pullRequest("VSTFS:///git/pullrequestid/p1/r1/4120")?.repositoryId == "r1")
        for url in [
            "vstfs:///Git/PullRequestId/p1%2Fr1", "vstfs:///Git/PullRequestId/p1%2Fr1%2Fx", "vstfs:///Git/PullRequestId/%2F%2F4",
            "vstfs:///Git/PullRequestId/p1%2Fr1%2F0", "vstfs:///Git/Ref/p1%2Fr1%2FGBmain", "https://dev.azure.com/c/p/_git/r/pullrequest/4",
        ] {
            #expect(ArtifactLink.pullRequest(url) == nil, "\(url)")
        }
    }

    @Test func turnsWhatItReadIntoLinksBetweenPullRequestsAndWorkItems() {
        let links = WorkLinks(
            workItemsOfPullRequests: [PRKey("contoso", 4091): [5110, 5112]],
            pullRequestsOfWorkItems: [WorkItemKey("Contoso", 5110): [PRKey("contoso", 4091)], WorkItemKey("contoso", 5101): [PRKey("contoso", 4120)]]
        )
        let pairs = Set(links.links.map(\.pair))
        #expect(pairs == [
            LinkPair(.pullRequest(organization: "contoso", number: 4091), .workItem(organization: "contoso", id: 5110))!,
            LinkPair(.pullRequest(organization: "contoso", number: 4091), .workItem(organization: "contoso", id: 5112))!,
            LinkPair(.pullRequest(organization: "contoso", number: 4120), .workItem(organization: "contoso", id: 5101))!,
        ])
        #expect(links.links.allSatisfy { $0.origin == .azureDevOps })
    }

    // MARK: Reading Azure DevOps

    private final class Clock: Sendable {
        private let date = Mutex(t(0))
        var now: Date { date.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { date.withLock { $0 += seconds } }
    }

    private final class Published: Sendable {
        private let all = Mutex<[WorkLinks]>([])
        func add(_ links: WorkLinks) { all.withLock { $0.append(links) } }
        var last: WorkLinks? { all.withLock { $0.last } }
        var each: [WorkLinks] { all.withLock { $0 } }
    }

    private func engine(_ server: StubServer, clock: Clock, published: Published = Published()) -> LinkEngine {
        LinkEngine(client: server.client(), now: { clock.now }, onChange: { published.add($0) })
    }

    private func count(_ server: StubServer, _ path: String) -> Int {
        server.requests.filter { $0.url?.path.contains(path) == true }.count
    }

    private static let place = LinkEngine.Place(projectId: "p1", repositoryId: "r1")

    @Test func readsEachPullRequestsWorkItemsThenAgainAQuarterOfAnHourLater() async {
        let server = StubServer()
        server.on("/pullRequests/7/workitems", json: Fixture.list([["id": "5101"]]))
        server.on("/pullRequests/8/workitems", json: Fixture.list([]))
        server.on("/_apis/wit/workitems", json: Fixture.list([WorkFixture.workItem(5101, "User Story", "Save items for later")]))
        let clock = Clock()
        let published = Published()
        let engine = engine(server, clock: clock, published: published)
        await engine.update(.init(pullRequests: [PRKey("Contoso", 7): Self.place, PRKey("contoso", 8): Self.place]))
        var links = await engine.currentLinks()
        #expect(links.workItemsOfPullRequests == [PRKey("contoso", 7): [5101], PRKey("contoso", 8): []])
        // The linked work item isn't in a sprint shown: what it is is read too, with only the fields it shows.
        #expect(links.workItems[WorkItemKey("contoso", 5101)]?.title == "Save items for later")
        #expect(links.workItems[WorkItemKey("contoso", 5101)]?.project == "Shop")
        let fields = server.requests.last { $0.url?.path.hasSuffix("/_apis/wit/workitems") == true }
            .flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "fields" }?.value }
        #expect(fields == WorkLinks.workItemFields.joined(separator: ","))
        #expect(published.last == links)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })

        await engine.refresh()
        #expect(count(server, "/workitems") == 3)
        clock.advance(15 * minute)
        await engine.refresh()
        #expect(count(server, "/pullRequests/7/workitems") == 2)
        #expect(count(server, "/pullRequests/8/workitems") == 2)

        // A pull request that leaves the lists takes its links with it, at once.
        await engine.update(.init(pullRequests: [PRKey("contoso", 8): Self.place]))
        links = await engine.currentLinks()
        #expect(links.workItemsOfPullRequests == [PRKey("contoso", 8): []])
        #expect(links.workItems.isEmpty)
    }

    @Test func readsTheSprintsPullRequestsOnlyWhileItShows() async {
        let server = StubServer()
        server.on("/_apis/wit/workitems", query: ["$expand": "relations"], json: Fixture.list([
            ["id": 5101, "relations": [["rel": "ArtifactLink", "url": "vstfs:///Git/PullRequestId/p1%2Fr1%2F4120"]]],
            ["id": 5102, "relations": [] as [Any]],
        ]))
        server.on("/_apis/git/pullrequests/4120", json: Fixture.pullRequest(4120, title: "Save items in the cart service", author: People.sam))
        let clock = Clock()
        let engine = engine(server, clock: clock)
        let sprint: Set<WorkItemKey> = [WorkItemKey("contoso", 5101), WorkItemKey("contoso", 5102)]
        await engine.update(.init(sprintItems: sprint, sprintShows: false))
        #expect(server.requests.isEmpty)

        await engine.update(.init(sprintItems: sprint, sprintShows: true))
        let links = await engine.currentLinks()
        #expect(links.pullRequestsOfWorkItems == [WorkItemKey("contoso", 5101): [PRKey("contoso", 4120)]])
        // A teammate's pull request that your lists don't show is read for what it is.
        #expect(links.pullRequests[PRKey("contoso", 4120)]?.title == "Save items in the cart service")
        let relations = server.requests.first { $0.url?.query?.contains("expand") == true }?.url
        #expect(relations?.query?.contains("fields=") == false)

        await engine.refresh()
        #expect(count(server, "/_apis/wit/workitems") == 1)
        #expect(count(server, "/pullrequests/4120") == 1)
        clock.advance(15 * minute)
        await engine.refresh()
        #expect(count(server, "/_apis/wit/workitems") == 2)
        #expect(count(server, "/pullrequests/4120") == 2)

        // A pull request your lists show isn't read again: the lists have it.
        await engine.update(.init(pullRequests: [PRKey("contoso", 4120): Self.place], sprintItems: sprint, sprintShows: true))
        #expect(await engine.currentLinks().pullRequests.isEmpty)
    }

    @Test func whatCantBeReadIsTriedAgainAnHourLaterWithoutHoldingUpTheRest() async {
        let server = StubServer()
        server.on("/pullRequests/7/workitems") { _ in .status(403) }
        server.on("/pullRequests/8/workitems", json: Fixture.list([["id": "5110"]]))
        server.on("/_apis/wit/workitems", json: Fixture.list([WorkFixture.workItem(5110, "Bug")]))
        let clock = Clock()
        let engine = engine(server, clock: clock)
        await engine.update(.init(pullRequests: [PRKey("contoso", 7): Self.place, PRKey("contoso", 8): Self.place]))
        #expect(await engine.currentLinks().workItemsOfPullRequests == [PRKey("contoso", 8): [5110]])
        clock.advance(20 * minute)
        await engine.refresh()
        #expect(count(server, "/pullRequests/7/workitems") == 1)
        clock.advance(45 * minute)
        await engine.refresh()
        #expect(count(server, "/pullRequests/7/workitems") == 2)
    }

    @Test func stopsWhenAzureDevOpsAsksToSlowDown() async {
        let server = StubServer()
        server.on("/workitems") { _ in .status(429, headers: ["Retry-After": "30"]) }
        let engine = engine(server, clock: Clock())
        await engine.update(.init(pullRequests: [PRKey("contoso", 7): Self.place, PRKey("contoso", 8): Self.place]))
        #expect(server.requests.count == 1)
    }

    @Test func readsNothingOnceStopped() async {
        let server = StubServer()
        server.on("/workitems", json: Fixture.list([]))
        let engine = engine(server, clock: Clock())
        await engine.stop()
        await engine.update(.init(pullRequests: [PRKey("contoso", 7): Self.place], sprintItems: [WorkItemKey("contoso", 1)], sprintShows: true))
        await engine.refresh()
        #expect(server.requests.isEmpty)
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
    }

    /// Stories (§7.4.1): only while Pull Request Order wants them, the linked work items' parent and place in the backlog,
    /// three more fields in the read Show Links makes anyway, and the parents nothing else has, with what they are only,
    /// up to 200 a GET; without them, nothing more.
    @Test func readsParentsAndPlacesInTheBacklogOnlyWhileStoriesAreWanted() async {
        let server = StubServer()
        server.on("/pullRequests/7/workitems", json: Fixture.list([["id": "5102"]]))
        // Whatever fields are asked for, as a check that what isn't wanted isn't kept.
        server.on("/_apis/wit/workitems", json: Fixture.list([WorkFixture.workItem(5102, "Task", "Round coupon totals", parent: 5101, rank: 2)]))
        server.on("/_apis/wit/workitems", query: ["ids": "5101"], json: Fixture.list([WorkFixture.workItem(5101, "User Story", "Checkout redesign")]))
        let clock = Clock()
        let engine = engine(server, clock: clock)
        let task = WorkItemKey("contoso", 5102)
        let story = WorkItemKey("contoso", 5101)
        let inSprint = WorkItemKey("contoso", 5110)
        let pullRequests = [PRKey("contoso", 7): Self.place]
        func workItemReads() -> [URLRequest] { server.requests.filter { $0.url?.path.hasSuffix("/_apis/wit/workitems") == true } }

        await engine.update(.init(pullRequests: pullRequests, parentLookups: [story]))
        var links = await engine.currentLinks()
        #expect(workItemReads().map { query($0, "fields") } == [WorkLinks.workItemFields.joined(separator: ",")])
        #expect(links.workItems[task]?.title == "Round coupon totals")
        #expect(links.workItems[task]?.parentId == nil && links.workItems[task]?.rank == nil)
        #expect(links.parents.isEmpty)

        // Wanted: the linked work items are read again at once, with their parent and place in the backlog, and the parent
        // with what it is only; one the sprint has isn't read.
        await engine.update(.init(pullRequests: pullRequests, sprintItems: [inSprint], wantsStories: true, parentLookups: [story, inSprint]))
        links = await engine.currentLinks()
        let reads = workItemReads()
        #expect(reads.map { query($0, "fields") } == [
            WorkLinks.workItemFields.joined(separator: ","), (WorkLinks.workItemFields + WorkLinks.storyFields).joined(separator: ","),
            WorkLinks.workItemFields.joined(separator: ","),
        ])
        #expect(reads.last.flatMap { query($0, "ids") } == "5101")
        #expect(links.workItems[task]?.parentId == 5101 && links.workItems[task]?.rank == 2)
        #expect(links.parents.keys.sorted() == [story])
        #expect(links.parents[story]?.title == "Checkout redesign" && links.parents[story]?.type == "User Story")
        // Read again, as linked work items are, every quarter of an hour.
        await engine.refresh()
        #expect(workItemReads().count == 3)
        clock.advance(15 * minute)
        await engine.refresh()
        #expect(workItemReads().count == 5)

        // Up to 200 a GET.
        let many = Set((6_000...6_200).map { WorkItemKey("contoso", $0) }).union([story])
        await engine.update(.init(pullRequests: pullRequests, sprintItems: [inSprint], wantsStories: true, parentLookups: many))
        #expect(workItemReads().count == 7)
        #expect(workItemReads().suffix(2).map { query($0, "ids")?.split(separator: ",").count } == [200, 1])

        // No longer wanted: what they wanted goes at once, and nothing more is read for them.
        let before = server.requests.count
        await engine.update(.init(pullRequests: pullRequests, sprintItems: [inSprint], parentLookups: many))
        links = await engine.currentLinks()
        #expect(links.parents.isEmpty)
        #expect(links.workItems[task]?.parentId == nil && links.workItems[task]?.rank == nil)
        #expect(server.requests.count == before)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    /// Waits for what a read under way has asked, for as long as a busy machine could need (`waitLimit`).
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: waitLimit)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    /// Stories turned off while a read is under way: the requests after it ask for what Show Links shows only.
    @Test func storiesTurnedOffDuringAReadArentAskedForByTheRequestsAfterIt() async throws {
        let server = StubServer()
        let turnedOff = Mutex(false)
        let withStories = (WorkLinks.workItemFields + WorkLinks.storyFields).joined(separator: ",")
        // 201 linked work items: two requests.
        server.on("/pullRequests/7/workitems", json: Fixture.list((7_000...7_200).map { ["id": "\($0)"] }))
        server.on("/_apis/wit/workitems", json: Fixture.list([]))
        server.on("/_apis/wit/workitems", query: ["fields": withStories]) { _ in
            var reply = StubServer.Reply.json(Fixture.list([]))
            reply.waitsFor = { turnedOff.withLock { $0 } }
            return reply
        }
        let engine = engine(server, clock: Clock())
        let pullRequests = [PRKey("contoso", 7): Self.place]
        let reading = Task { await engine.update(.init(pullRequests: pullRequests, wantsStories: true)) }
        try await until { server.requests.contains { query($0, "fields") == withStories } }
        await engine.update(.init(pullRequests: pullRequests))
        turnedOff.withLock { $0 = true }
        await reading.value
        let reads = server.requests.filter { $0.url?.path.hasSuffix("/_apis/wit/workitems") == true }
        #expect(reads.map { query($0, "fields") } == [withStories, WorkLinks.workItemFields.joined(separator: ",")])
        #expect(reads.map { query($0, "ids")?.split(separator: ",").count } == [200, 1])
    }

    /// Stories turned off while their parents are read: the rest of them aren't.
    @Test func storiesTurnedOffDuringAReadOfTheirParentsReadNoMoreOfThem() async throws {
        let server = StubServer()
        let turnedOff = Mutex(false)
        let shown = WorkLinks.workItemFields.joined(separator: ",")
        server.on("/pullRequests/7/workitems", json: Fixture.list([["id": "5102"]]))
        server.on("/_apis/wit/workitems", json: Fixture.list([WorkFixture.workItem(5102, "Task", "Round coupon totals", parent: 5101, rank: 2)]))
        // The parents, with what they are only: the first request answers once the test turned stories off.
        server.on("/_apis/wit/workitems", query: ["fields": shown]) { _ in
            var reply = StubServer.Reply.json(Fixture.list([]))
            reply.waitsFor = { turnedOff.withLock { $0 } }
            return reply
        }
        let engine = engine(server, clock: Clock())
        let pullRequests = [PRKey("contoso", 7): Self.place]
        // 201 parents: two requests.
        let parents = Set((6_000...6_200).map { WorkItemKey("contoso", $0) })
        let reading = Task { await engine.update(.init(pullRequests: pullRequests, wantsStories: true, parentLookups: parents)) }
        try await until { server.requests.contains { query($0, "fields") == shown } }
        await engine.update(.init(pullRequests: pullRequests, parentLookups: parents))
        turnedOff.withLock { $0 = true }
        await reading.value
        #expect(server.requests.filter { query($0, "fields") == shown }.count == 1)
        #expect(await engine.currentLinks().parents.isEmpty)
    }

    /// A story a read leaves out, deleted or that can't be read now, is forgotten: its mission is named by its number.
    @Test func aStoryLeftOutOfAReadIsForgotten() async {
        let server = StubServer()
        let deleted = Mutex(false)
        server.on("/pullRequests/7/workitems", json: Fixture.list([["id": "5102"]]))
        server.on("/_apis/wit/workitems", json: Fixture.list([WorkFixture.workItem(5102, "Task", "Round coupon totals", parent: 5101, rank: 2)]))
        server.on("/_apis/wit/workitems", query: ["ids": "5101"]) { _ in
            .json(Fixture.list(deleted.withLock { $0 } ? [] : [WorkFixture.workItem(5101, "User Story", "Checkout redesign")]))
        }
        let clock = Clock()
        let engine = engine(server, clock: clock)
        let story = WorkItemKey("contoso", 5101)
        await engine.update(.init(pullRequests: [PRKey("contoso", 7): Self.place], wantsStories: true, parentLookups: [story]))
        #expect(await engine.currentLinks().parents[story]?.title == "Checkout redesign")
        deleted.withLock { $0 = true }
        clock.advance(15 * minute)
        await engine.refresh()
        #expect(await engine.currentLinks().parents[story] == nil)
    }

    /// A linked work item a read leaves out, deleted or that can't be read now, is forgotten, with the story it gave its
    /// pull requests; one whose read failed is kept.
    @Test func aLinkedWorkItemLeftOutOfAReadIsForgottenUnlessTheReadFailed() async {
        let server = StubServer()
        let reply = Mutex("task")
        server.on("/pullRequests/7/workitems", json: Fixture.list([["id": "5102"]]))
        server.on("/_apis/wit/workitems") { _ in
            switch reply.withLock({ $0 }) {
            case "task": .json(Fixture.list([WorkFixture.workItem(5102, "Task", "Round coupon totals", parent: 5101, rank: 2)]))
            case "fails": .status(500)
            default: .json(Fixture.list([]))
            }
        }
        let clock = Clock()
        let engine = engine(server, clock: clock)
        let task = WorkItemKey("contoso", 5102)
        await engine.update(.init(pullRequests: [PRKey("contoso", 7): Self.place], wantsStories: true))
        #expect(await engine.currentLinks().workItems[task]?.parentId == 5101)
        reply.withLock { $0 = "fails" }
        clock.advance(15 * minute)
        await engine.refresh()
        #expect(await engine.currentLinks().workItems[task]?.parentId == 5101)
        reply.withLock { $0 = "left out" }
        clock.advance(61 * minute)
        await engine.refresh()
        #expect(await engine.currentLinks().workItems[task] == nil)
        #expect(await engine.currentLinks().pendingWorkItems.isEmpty)
    }

    /// While stories are wanted, a pull request's work items that no read answered for yet, with what stories want, are
    /// pending, until one answers; one a read leaves out isn't, nor one whose read failed, which gives no story until a read
    /// gets it, rather than keep its pull request's stories unknown for as long as it fails. A pull request whose work items'
    /// read failed is unreadable, until a read answers for it.
    @Test func aPullRequestsWorkItemsArePendingUntilAReadAnswersForThem() async {
        let server = StubServer()
        let fails = Mutex(false)
        server.on("/pullRequests/7/workitems", json: Fixture.list([["id": "5102"], ["id": "5103"]]))
        server.on("/pullRequests/8/workitems", json: Fixture.list([["id": "5104"]]))
        server.on("/pullRequests/9/workitems") { _ in fails.withLock { $0 } ? .status(500) : .json(Fixture.list([["id": "5102"]])) }
        // 5103 and 5104 are left out: deleted, or can't be read.
        server.on("/_apis/wit/workitems") { _ in
            fails.withLock { $0 } ? .status(500) : .json(Fixture.list([WorkFixture.workItem(5102, "Task", "Round coupon totals", parent: 5101)]))
        }
        let clock = Clock()
        let published = Published()
        let engine = engine(server, clock: clock, published: published)
        let seven = [PRKey("contoso", 7): Self.place]
        let all = seven.merging([PRKey("contoso", 8): Self.place, PRKey("contoso", 9): Self.place]) { $1 }
        await engine.update(.init(pullRequests: seven))
        #expect(await engine.currentLinks().pendingWorkItems.isEmpty)
        await engine.update(.init(pullRequests: seven, wantsStories: true))
        // As stories became wanted, until the read with what they want answered.
        #expect(published.each.contains { $0.pendingWorkItems == [WorkItemKey("contoso", 5102), WorkItemKey("contoso", 5103)] })
        #expect(await engine.currentLinks().pendingWorkItems.isEmpty)

        // Reads that fail: 5104's gives it no story, and !9's work items aren't known.
        fails.withLock { $0 = true }
        await engine.update(.init(pullRequests: all, wantsStories: true))
        #expect(await engine.currentLinks().workItemsOfPullRequests[PRKey("contoso", 8)] == [5104])
        #expect(await engine.currentLinks().pendingWorkItems.isEmpty)
        #expect(await engine.currentLinks().unreadablePullRequests == [PRKey("contoso", 9)])
        // While stories aren't wanted, none is.
        await engine.update(.init(pullRequests: all))
        #expect(await engine.currentLinks().unreadablePullRequests.isEmpty)
        await engine.update(.init(pullRequests: all, wantsStories: true))
        #expect(await engine.currentLinks().unreadablePullRequests == [PRKey("contoso", 9)])
        #expect(await engine.currentLinks().pendingWorkItems.isEmpty)
        fails.withLock { $0 = false }
        clock.advance(61 * minute)
        await engine.refresh()
        #expect(await engine.currentLinks().workItemsOfPullRequests[PRKey("contoso", 9)] == [5102])
        #expect(await engine.currentLinks().pendingWorkItems.isEmpty)
        #expect(await engine.currentLinks().unreadablePullRequests.isEmpty)
        // Read since, their failures are over: wanted again, they wait for a read again.
        await engine.update(.init(pullRequests: all))
        let before = published.each.count
        await engine.update(.init(pullRequests: all, wantsStories: true))
        let linked: Set<WorkItemKey> = [WorkItemKey("contoso", 5102), WorkItemKey("contoso", 5103), WorkItemKey("contoso", 5104)]
        #expect(published.each.dropFirst(before).contains { $0.pendingWorkItems == linked })
    }

    @Test func looksUpWhatYouLinkedThatNoListShows() async {
        let server = StubServer()
        server.on("/_apis/git/pullrequests/4130") { _ in .status(404) }
        server.on("/_apis/git/pullrequests/4131", json: Fixture.pullRequest(4131, title: "Tidy the cart", status: "completed", closed: t(-day)))
        server.on("/_apis/wit/workitems", json: Fixture.list([WorkFixture.workItem(5199, "Bug", "Totals are off")]))
        let clock = Clock()
        let engine = engine(server, clock: clock)
        await engine.update(.init(
            workItemLookups: [WorkItemKey("contoso", 5199)], pullRequestLookups: [PRKey("Contoso", 4130), PRKey("contoso", 4131)]
        ))
        let links = await engine.currentLinks()
        #expect(links.workItems.keys.sorted() == [WorkItemKey("contoso", 5199)])
        #expect(links.pullRequests.keys.sorted() == [PRKey("contoso", 4131)])
        // A closed pull request is read again only hours later.
        clock.advance(2 * hour)
        await engine.refresh()
        #expect(count(server, "/pullrequests/4131") == 1)
        #expect(count(server, "/pullrequests/4130") == 2)
    }

    @Test func looksUpPullRequestsByNumberUntilAskedToSlowDown() async {
        let server = StubServer()
        server.on("/_apis/git/pullrequests/4130") { _ in .status(404) }
        server.on("/_apis/git/pullrequests/4131", json: Fixture.pullRequest(4131, title: "Tidy the cart"))
        server.on("/_apis/git/pullrequests/4132") { _ in .status(429, headers: ["Retry-After": "30"]) }
        server.on("/_apis/git/pullrequests/4133", json: Fixture.pullRequest(4133, title: "Never asked for"))
        let lookups = await LinkEngine.lookUp([4130, 4131, 4132, 4133].map { PRKey("contoso", $0) }, client: server.client())
        #expect(lookups.read.keys.sorted() == [PRKey("contoso", 4131)])
        #expect(lookups.read[PRKey("contoso", 4131)]?.title == "Tidy the cart")
        #expect(lookups.failed == [PRKey("contoso", 4130)])
        // Once asked to slow down, it stops: what it didn't get to is neither read nor failed.
        #expect(count(server, "/pullrequests/4133") == 0)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func looksUpEveryPullRequestItsGiven() async {
        let server = StubServer()
        for number in 1...60 {
            server.on("/_apis/git/pullrequests/\(number)", json: Fixture.pullRequest(number, title: "Change \(number)"))
        }
        let lookups = await LinkEngine.lookUp((1...60).map { PRKey("contoso", $0) }, client: server.client())
        #expect(lookups.read.count == 60)
        #expect(lookups.failed.isEmpty)
    }

    // MARK: The demo

    @Test func theDemosLinksJoinItsOwnPullRequestsAndSprint() {
        let links = DemoData.workLinks()
        let listed = Set(DemoData.records(now: Date()).map { PRKey($0.id.organization.lowercased(), $0.id.number) })
        let board = DemoData.sprintBoard(now: Date())
        let sprint = Set(board.rows.flatMap { ($0.parent.map { [$0] } ?? []) + $0.tasks }.map { WorkItemKey($0.organization, $0.id) })
        #expect(Set(links.workItemsOfPullRequests.keys).isSubset(of: listed))
        #expect(Set(links.pullRequestsOfWorkItems.keys).isSubset(of: sprint))
        #expect(Set(links.pullRequests.keys).isDisjoint(with: listed))
        #expect(Set(links.workItems.keys).isDisjoint(with: sprint))
        let linkedPullRequests = Set(links.pullRequestsOfWorkItems.values.flatMap { $0 })
        #expect(linkedPullRequests.subtracting(listed) == Set(links.pullRequests.keys))
        let linkedWorkItems = Set(links.workItemsOfPullRequests.flatMap { key, ids in ids.map { WorkItemKey(key.organization, $0) } })
        #expect(linkedWorkItems.subtracting(sprint) == Set(links.workItems.keys))
        // The stories read as parents are what nothing else has, and their tasks' parents.
        #expect(Set(links.parents.keys).isDisjoint(with: sprint.union(links.workItems.keys)))
        let parents = Set(links.workItems.values.compactMap { $0.parentId.map { WorkItemKey(DemoData.organization, $0) } })
        #expect(Set(links.parents.keys).isSubset(of: parents))
    }
}
