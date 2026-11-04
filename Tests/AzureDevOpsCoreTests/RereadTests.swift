import BriefBarCore
import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsCore

/// Reading again sooner what a Copilot session says it changed (`AgentRereads`): only what the engines read anyway, and
/// only GETs.
/// A reply held until the test lets it go, as a slow answer is.
private final class Hold: Sendable {
    private let open = Mutex(false)
    var isOpen: Bool { open.withLock { $0 } }
    func release() { open.withLock { $0 = true } }
}

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

    /// Waits until a request has gone out as often as `times`.
    private static func until(_ server: StubServer, _ path: String, _ times: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while count(server, path) < times {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A session said it changed a pull request while its details were read: that read may be from before, so it isn't
    /// taken, and the next refresh reads them again.
    @Test func aDetailsReadUnderWayDoesntCountForARereadAskedMeanwhile() async throws {
        let now = Date()
        let server = StubServer()
        server.serveOrganization(mine: [Fixture.pullRequest(1, created: now.addingTimeInterval(-86_400))])
        let hold = Hold()
        let reads = Mutex(0)
        server.on("/pullRequests/1/threads") { _ in
            var reply = StubServer.Reply.json(Fixture.list([]))
            if reads.withLock({ $0 += 1; return $0 }) == 2 { reply.waitsFor = { hold.isOpen } }
            return reply
        }
        let engine = PulseEngine(client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org])) { _ in }
        await engine.refreshNow()
        await engine.reread([PRKey(Fixture.org, 1)])
        let refresh = Task { await engine.refreshNow() }
        try await Self.until(server, "/pullRequests/1/threads", 2)
        await engine.reread([PRKey(Fixture.org, 1)])
        hold.release()
        await refresh.value

        await engine.refreshNow()
        #expect(Self.count(server, "/pullRequests/1/threads") == 3)
    }

    /// A session said it changed a pull request while its work items were read: that read doesn't count, and they're read
    /// again in the same refresh.
    @Test func aLinksReadUnderWayDoesntCountForARereadAskedMeanwhile() async throws {
        let server = StubServer()
        let hold = Hold()
        let reads = Mutex(0)
        server.on("/pullRequests/7/workitems") { _ in
            var reply = StubServer.Reply.json(Fixture.list([["id": "5101"]]))
            if reads.withLock({ $0 += 1; return $0 }) == 1 { reply.waitsFor = { hold.isOpen } }
            return reply
        }
        server.on("/_apis/wit/workitems", json: Fixture.list([WorkFixture.workItem(5101, "User Story", "Save items for later")]))
        let clock = Clock()
        let engine = LinkEngine(client: server.client(), now: { clock.now }, onChange: { _ in })
        let first = Task { await engine.update(.init(pullRequests: [PRKey("contoso", 7): Self.place])) }
        try await Self.until(server, "/pullRequests/7/workitems", 1)
        clock.advance(1)
        await engine.reread(pullRequests: [PRKey("contoso", 7)], workItems: [])
        hold.release()
        await first.value
        #expect(Self.count(server, "/pullRequests/7/workitems") == 2)
        // And not again after that, until it's due.
        await engine.refresh()
        #expect(Self.count(server, "/pullRequests/7/workitems") == 2)
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
