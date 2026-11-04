import BriefBarCore
import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsCore

/// Reading again sooner what a Copilot session says it changed (`AgentRereads`): only what the engines read anyway, and
/// only GETs.
@Suite struct RereadTests {
    private final class Clock: Sendable {
        private let date = Mutex(Date(timeIntervalSince1970: 1_791_979_200))
        var now: Date { date.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { date.withLock { $0 += seconds } }
    }

    private static let place = LinkEngine.Place(projectId: "p1", repositoryId: "r1")

    private static func count(_ server: StubServer, _ path: String) -> Int {
        server.requests.filter { $0.url?.path.lowercased().contains(path.lowercased()) == true }.count
    }

    @Test func aPullRequestsDetailsAreReadInTheNextRefreshOnlyForOnesTheListsHave() async {
        let now = Date()
        let server = StubServer()
        server.serveOrganization(mine: [
            Fixture.pullRequest(1, created: now.addingTimeInterval(-86_400)),
            Fixture.pullRequest(2, created: now.addingTimeInterval(-86_400)),
        ])
        let engine = PulseEngine(client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org])) { _ in }
        await engine.refreshNow()
        #expect(Self.count(server, "/pullRequests/1/threads") == 1)
        // Not due again so soon.
        await engine.refreshNow()
        #expect(Self.count(server, "/pullRequests/1/threads") == 1)

        await engine.reread([PRKey(Fixture.org, 1), PRKey(Fixture.org, 99)])
        await engine.refreshNow()
        #expect(Self.count(server, "/pullRequests/1/threads") == 2)
        #expect(Self.count(server, "/pullRequests/2/threads") == 1)
        #expect(Self.count(server, "/pullRequests/99") == 0)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func linksAreReadAgainAtOnceForWhatTheEngineReadsAnyway() async {
        let server = StubServer()
        server.on("/pullRequests/7/workitems", json: Fixture.list([["id": "5101"]]))
        server.on("/pullRequests/8/workitems", json: Fixture.list([]))
        server.on("/_apis/wit/workitems", json: Fixture.list([WorkFixture.workItem(5101, "User Story", "Save items for later")]))
        let clock = Clock()
        let engine = LinkEngine(client: server.client(), now: { clock.now }, onChange: { _ in })
        await engine.update(.init(pullRequests: [PRKey("contoso", 7): Self.place, PRKey("contoso", 8): Self.place]))
        #expect(Self.count(server, "/pullRequests/7/workitems") == 1)
        #expect(Self.count(server, "/_apis/wit/workitems") == 1)

        clock.advance(60)
        await engine.reread(pullRequests: [PRKey("Contoso", 7), PRKey("contoso", 99)], workItems: [WorkItemKey("contoso", 5101)])
        #expect(Self.count(server, "/pullRequests/7/workitems") == 2)
        #expect(Self.count(server, "/pullRequests/8/workitems") == 1)
        #expect(Self.count(server, "/pullRequests/99/workitems") == 0)
        #expect(Self.count(server, "/_apis/wit/workitems") == 2)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }
}
