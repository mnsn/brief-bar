import BriefBarCore
import Foundation
import Testing
@testable import AzureDevOpsCore

/// What agents' tools read of the work that goes with pull requests (plan §7.4.6): a pull request's work items, each with
/// what it's under, and the pull requests of a story's tasks; with GETs only, as they answer.
@Suite struct PullRequestWorkTests {
    private let pullRequest = PullRequest(
        key: PRKey(Fixture.org, 7), title: "Show delivery estimates", author: Person(id: "robin", name: "Robin Diaz"), createdAt: t(-hour),
        projectId: "p1", projectName: "Shop", repositoryId: "r1", repositoryName: "shop-web"
    )

    /// Its work items, in ID order, each with what it's under: one GET for their IDs, one for what they are, and one for
    /// what those they're under are, when they aren't among them. One it can't read is left out.
    @Test func readsAPullRequestsWorkItemsWithWhatTheyreUnder() async throws {
        let server = StubServer()
        server.on("/pullRequests/7/workitems", json: Fixture.list([["id": "5182"], ["id": "5110"], ["id": "5112"], ["id": "5199"]]))
        server.on("/_apis/wit/workitems") { request in
            let ids = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ids" }?.value
            switch ids {
            case "5110,5112,5182,5199":
                return .json(Fixture.list([
                    WorkFixture.workItem(5110, "Bug", "Coupon totals round down"),
                    WorkFixture.workItem(5112, "Task", "Round half up", parent: 5110),
                    WorkFixture.workItem(5182, "Task", "Show delivery estimates", parent: 5180),
                ]))
            case "5180":
                return .json(Fixture.list([WorkFixture.workItem(5180, "User Story", "Checkout redesign")]))
            default:
                return .status(404)
            }
        }
        let work = try await PullRequestWork.read(pullRequest, client: server.client())
        #expect(work.map(\.item.id) == [5110, 5112, 5182])
        #expect(work[0].parent == nil)
        #expect(work[1].parent?.id == 5110)
        #expect(work[2].parent?.type == "User Story" && work[2].parent?.title == "Checkout redesign")
        #expect(server.requests.count == 3)
        // What it's under is read only for what it is.
        let parentRead = try #require(server.requests.last?.url)
        #expect(URLComponents(url: parentRead, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "fields" }?.value
            == WorkLinks.workItemFields.joined(separator: ","))

        // None linked: one GET.
        let none = StubServer()
        none.on("/pullRequests/7/workitems", json: Fixture.list([]))
        #expect(try await PullRequestWork.read(pullRequest, client: none.client()).isEmpty)
        #expect(none.requests.count == 1)
    }

    /// Each work item's pull requests, with one GET for all of them; those with none aren't named.
    @Test func readsEachWorkItemsPullRequests() async throws {
        let server = StubServer()
        server.on("/_apis/wit/workitems", query: ["$expand": "relations"], json: Fixture.list([
            ["id": 5112, "relations": [
                ["rel": "ArtifactLink", "url": "vstfs:///Git/PullRequestId/p1%2Fr1%2F4091", "attributes": ["name": "Pull Request"]],
                ["rel": "System.LinkTypes.Hierarchy-Reverse", "url": "https://dev.azure.com/contoso/_apis/wit/workItems/5110"],
            ]],
            ["id": 5113, "relations": []],
        ]))
        let found = try await PullRequestWork.pullRequests(of: [5113, 5112, 5112], in: Fixture.org, client: server.client())
        #expect(found == [5112: [PRKey(Fixture.org, 4091)]])
        #expect(server.requests.count == 1)
        #expect(try await PullRequestWork.pullRequests(of: [], in: Fixture.org, client: server.client()).isEmpty)
        #expect(server.requests.count == 1)
    }
}
