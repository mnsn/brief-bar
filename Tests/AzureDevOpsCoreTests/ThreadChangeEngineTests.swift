import Foundation
import Testing
@testable import AzureDevOpsCore

/// What the engine does with a change BriefBar made to a thread: it shows at once, the pull request is read again, and a
/// read that started before the change never undoes it.
@Suite struct ThreadChangeEngineTests {
    private let key = PRKey(Fixture.org, 1)

    private func threads(_ comments: [[String: Any]], status: String = "active", at date: Date) -> [String: Any] {
        Fixture.list([Fixture.thread(7, comments: comments, status: status, published: date)])
    }

    private func thread(in snapshot: PulseSnapshot?) -> ReviewThread? {
        snapshot?.records.first { $0.id == key }?.details?.threads.first { $0.id == 7 }
    }

    private func threadReads(_ server: StubServer) -> Int {
        server.requests.filter { $0.url?.path.hasSuffix("/pullRequests/1/threads") == true }.count
    }

    @Test func aChangeShowsAtOnceAndItsPullRequestIsReadAgain() async throws {
        let now = Date()
        let server = StubServer()
        server.serveOrganization(mine: [Fixture.pullRequest(1, created: now.addingTimeInterval(-day))])
        let question = Fixture.comment(1, People.sam, "Cap it?", at: now.addingTimeInterval(-hour))
        server.on("/pullRequests/1/threads", json: threads([question], at: now.addingTimeInterval(-hour)))
        let collector = SnapshotCollector()
        let engine = PulseEngine(client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org])) {
            collector.add($0)
        }
        await engine.refreshNow()
        #expect(thread(in: await engine.currentSnapshot())?.comments.count == 1)

        // Azure DevOps has the reply now, and someone resolved the thread meanwhile.
        let reply = Fixture.comment(2, People.me, "Capped at 30 seconds", at: now)
        server.on("/pullRequests/1/threads", json: threads([question, reply], status: "fixed", at: now.addingTimeInterval(-hour)))
        let reads = threadReads(server)
        let published = collector.count
        await engine.changed(key, by: ThreadChange(thread: 7, comments: [comment(2, People.me, "Capped at 30 seconds", at: now)]))

        // At once, before it's read again: with the reply, still active.
        let first = try #require(collector.all.dropFirst(published).first)
        #expect(thread(in: first)?.comments.map(\.id) == [1, 2])
        #expect(thread(in: first)?.status == "active")
        // Then as Azure DevOps has it, read once more.
        let read = try #require(thread(in: await engine.currentSnapshot()))
        #expect(read.comments.map(\.id) == [1, 2])
        #expect(read.status == "fixed")
        #expect(threadReads(server) == reads + 1)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    /// A read of its threads that started before the change, and answers as they were, doesn't undo it: the pull request is
    /// read again instead.
    @Test(.timeLimit(.minutes(1)))
    func aReadThatStartedBeforeAChangeDoesntUndoIt() async throws {
        let now = Date()
        let server = StubServer()
        server.serveOrganization(mine: [Fixture.pullRequest(1, created: now.addingTimeInterval(-day))])
        let question = Fixture.comment(1, People.sam, "Cap it?", at: now.addingTimeInterval(-hour))
        let before = threads([question], at: now.addingTimeInterval(-hour))
        server.on("/pullRequests/1/threads", json: before)
        let collector = SnapshotCollector()
        // Its details are due at every refresh.
        let engine = PulseEngine(client: server.client(), configuration: PulseEngine.Configuration(
            organizations: [Fixture.org], planner: RefreshPlanner.Options(busyInterval: 0, activeInterval: 0, quietInterval: 0)
        )) { collector.add($0) }
        await engine.refreshNow()

        // The next read is slow, and answers as the threads were before the change; those after it, as they are after it.
        let after = StubServer.Reply.json(threads([question, Fixture.comment(2, People.me, "Capped", at: now)], at: now.addingTimeInterval(-hour)))
        let stale = StubServer.Reply.json(before)
        let reads = Locked(0)
        server.on("/pullRequests/1/threads") { _ in
            guard reads.increment() == 1 else { return after }
            Thread.sleep(forTimeInterval: 0.3)
            return stale
        }
        let refresh = Task { await engine.refreshNow() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: waitLimit)
        while reads.value < 1, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reads.value >= 1)
        let published = collector.count
        await engine.changed(key, by: ThreadChange(thread: 7, comments: [comment(2, People.me, "Capped", at: now)]))
        await refresh.value

        // From the change on, the thread has the reply in every snapshot, and in the last.
        let since = collector.all.dropFirst(published)
        #expect(!since.isEmpty)
        #expect(since.allSatisfy { thread(in: $0)?.comments.map(\.id) == [1, 2] })
        #expect(thread(in: await engine.currentSnapshot())?.comments.map(\.id) == [1, 2])
    }

    /// Read again, as after a change Azure DevOps didn't answer in time: two requests, now.
    @Test func readsAPullRequestAgainWhenAsked() async throws {
        let now = Date()
        let server = StubServer()
        server.serveOrganization(mine: [Fixture.pullRequest(1, created: now.addingTimeInterval(-day))])
        let question = Fixture.comment(1, People.sam, "Cap it?", at: now.addingTimeInterval(-hour))
        server.on("/pullRequests/1/threads", json: threads([question], at: now.addingTimeInterval(-hour)))
        let engine = PulseEngine(client: server.client(), configuration: PulseEngine.Configuration(organizations: [Fixture.org])) { _ in }
        await engine.refreshNow()
        let requests = server.requests.count

        server.on("/pullRequests/1/threads", json: threads([question, Fixture.comment(2, People.me, "Capped", at: now)],
                                                          at: now.addingTimeInterval(-hour)))
        await engine.readAgain(key)
        #expect(thread(in: await engine.currentSnapshot())?.comments.map(\.id) == [1, 2])
        #expect(server.requests.count == requests + 2)

        // One it doesn't list is read at no time.
        await engine.readAgain(PRKey(Fixture.org, 99))
        #expect(server.requests.count == requests + 2)
    }
}
