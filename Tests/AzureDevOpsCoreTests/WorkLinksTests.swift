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
    }
}
