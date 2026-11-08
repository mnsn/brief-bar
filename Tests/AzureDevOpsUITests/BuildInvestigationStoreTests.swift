import AzureDevOpsCore
import BriefBarCore
import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsUI

/// Reads of builds that wait for the test to answer them, as Azure DevOps answers later: what the store does meanwhile.
@MainActor
private final class InvestigationGate {
    /// Each read asked for: which run, whether anew, for the pull request as it was then, and how far along its check said
    /// the run was.
    private(set) var asked: [(buildId: Int, again: Bool, pullRequest: PullRequest, phase: PipelineRun.Phase?)] = []
    private var waiting: [(buildId: Int, continuation: CheckedContinuation<BuildInvestigation, Error>)] = []

    var reader: BuildInvestigationStore.Reader {
        { [self] buildId, pullRequest, again, phase in
            try await self.read(buildId, pullRequest, again: again, phase: phase)
        }
    }

    private func read(_ buildId: Int, _ pullRequest: PullRequest, again: Bool, phase: PipelineRun.Phase?) async throws
        -> BuildInvestigation {
        asked.append((buildId, again, pullRequest, phase))
        return try await withCheckedThrowingContinuation { waiting.append((buildId, $0)) }
    }

    /// Waits for the store to ask, then answers its oldest read.
    func answer(_ result: Result<BuildInvestigation, ADOError>) async throws {
        try await until("a read") { !waiting.isEmpty }
        waiting.removeFirst().continuation.resume(with: result.mapError { $0 as Error })
    }

    /// Waits for the store to ask for a run, then answers its oldest read of it.
    func answer(_ buildId: Int, _ result: Result<BuildInvestigation, ADOError>) async throws {
        try await until("a read of \(buildId)") { waiting.contains { $0.buildId == buildId } }
        guard let index = waiting.firstIndex(where: { $0.buildId == buildId }) else { return }
        waiting.remove(at: index).continuation.resume(with: result.mapError { $0 as Error })
    }

    /// Waits for the store to ask, then fails its oldest read with `error`, as the investigator may.
    func fail(_ error: Error) async throws {
        try await until("a read") { !waiting.isEmpty }
        waiting.removeFirst().continuation.resume(throwing: error)
    }
}

/// A stand-in for Azure DevOps, for a store that reads through its own `BuildInvestigator`: a run, as Azure DevOps answers
/// one, and an empty list for anything else; what's asked is noted by the token each request has.
private final class StandInAzureDevOps: URLProtocol, @unchecked Sendable {
    static let asked = Mutex<[String: [String]]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        Self.asked.withLock { $0[token, default: []].append(url.path) }
        let isRun = url.path.range(of: #"/_apis/build/builds/\d+$"#, options: .regularExpression) != nil
        let json: [String: Any] = isRun
            ? ["id": 1, "status": "completed", "result": "failed", "definition": ["id": 31], "sourceBranch": "refs/pull/4088/merge"]
            : ["count": 0, "value": [Any]()]
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A sign-in whose first token waits until it's let go, as the Azure CLI's can, saying when it's asked for and when whoever
/// waits for it is called off (`events`), for a test to wait on rather than for a while: one token for each test, by which
/// the stand-in tells its requests apart.
private actor HeldToken: AccessTokenProvider {
    /// What becomes of the first token.
    enum Event: Equatable, Sendable {
        /// It's asked for, and waits.
        case holding
        /// Whoever waits for it was called off.
        case calledOff
    }

    let value = UUID().uuidString
    /// What becomes of the first token, as it happens.
    let events: AsyncStream<Event>
    private let event: AsyncStream<Event>.Continuation
    private var calls = 0
    private var held: CheckedContinuation<Void, Never>?

    init() {
        let (events, event) = AsyncStream<Event>.makeStream()
        self.events = events
        self.event = event
    }

    func token(tenant: String?) async throws -> AccessToken {
        calls += 1
        if calls == 1 {
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    held = $0
                    event.yield(.holding)
                }
            } onCancel: { [event] in
                event.yield(.calledOff)
            }
        }
        return AccessToken(value: value, expiresOn: .distantFuture)
    }

    func invalidate(tenant: String?) {}

    func release() {
        held?.resume()
        held = nil
    }
}

private struct Timeout: Error, CustomStringConvertible {
    let description: String
}

/// Lets the store's reads go on until `condition` holds, for as long as a busy machine could need (`waitLimit`).
@MainActor
private func until(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: waitLimit)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw Timeout(description: "Timed out waiting for \(what)") }
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// The builds opened in a pull request's details, and what's read of them: asked for as one opens, and as it opens again;
/// again when what it's read for changes, its check or its pull request, or when you ask, while what was read shows, after
/// a read under way; and let go of for another pull request, someone else signing in, or Azure DevOps turned off. With reads
/// the tests answer, or the made-up builds, which never use the Azure CLI or Azure DevOps.
@MainActor
@Suite struct BuildInvestigationStoreTests {
    private struct NoTokens: AccessTokenProvider {
        struct Unused: Error {}
        func token(tenant: String?) async throws -> AccessToken { throw Unused() }
        func invalidate(tenant: String?) async {}
    }

    private let now = Date()
    private let delivery: PullRequest
    private let slowQueries: PullRequest

    init() throws {
        let records = DemoData.records(now: now)
        delivery = try #require(records.first { $0.id.number == 4088 }).pullRequest
        slowQueries = try #require(records.first { $0.id.number == 4099 }).pullRequest
    }

    /// Live, with reads `gate` answers; or, without one, the demo's.
    private func makeStore(_ gate: InvestigationGate? = nil) -> BuildInvestigationStore {
        BuildInvestigationStore(mode: gate == nil ? .demo : .live, client: ADOClient(tokens: NoTokens()), now: { [now] in now },
                                reader: gate?.reader)
    }

    /// A run of `delivery`'s, as read at `readAt`.
    private func investigation(_ id: Int, number: String = "20261102.4", readAt: Date? = nil) -> BuildInvestigation {
        BuildInvestigation(
            pipeline: PipelineRef(organization: DemoData.organization, projectId: delivery.projectId, projectName: delivery.projectName,
                                  definitionId: 31, name: "shop-web CI"),
            run: PipelineRun(id: id, organization: DemoData.organization, projectName: delivery.projectName, number: number, status: .failed,
                             trigger: .pullRequest, branch: "!4088"),
            comparison: BuildComparison(revision: .current, targetBranch: "main"), readAt: readAt ?? now
        )
    }

    @Test func aBuildIsReadAsItOpensAndAskedForAgainAsItOpensAgain() async throws {
        let gate = InvestigationGate()
        let store = makeStore(gate)
        #expect(!store.isExpanded(1, of: delivery.key))
        store.expand(1, of: delivery)
        #expect(store.isExpanded(1, of: delivery.key))
        #expect(store.pullRequest == delivery.key)
        #expect(store.look(1, of: delivery.key)?.isReading == true)
        #expect(store.look(1, of: delivery.key)?.investigation == nil)
        try await gate.answer(.success(investigation(1)))
        try await until("the read") { store.look(1, of: delivery.key)?.isReading == false }
        #expect(store.look(1, of: delivery.key)?.investigation == investigation(1))
        #expect(store.look(1, of: delivery.key)?.failure == nil)
        #expect(gate.asked.map(\.again) == [false])

        // Closed, nothing's read. Opened again, the investigator's asked again, which answers with what it keeps while
        // that's fresh, and reads it otherwise: what was read shows meanwhile.
        store.toggle(1, of: delivery)
        #expect(!store.isExpanded(1, of: delivery.key))
        #expect(store.look(1, of: delivery.key)?.investigation != nil)
        #expect(gate.asked.count == 1)
        store.toggle(1, of: delivery)
        #expect(store.isExpanded(1, of: delivery.key))
        try await until("the second ask") { gate.asked.count == 2 }
        #expect(gate.asked.last?.again == false)
        #expect(store.look(1, of: delivery.key)?.isReading == true)
        #expect(store.look(1, of: delivery.key)?.investigation == investigation(1))
        let later = investigation(1, readAt: now.addingTimeInterval(700))
        try await gate.answer(.success(later))
        try await until("its answer") { store.look(1, of: delivery.key)?.investigation == later }

        // Not while it's being read.
        store.expand(2, of: delivery)
        store.collapse(2, of: delivery.key)
        store.expand(2, of: delivery)
        try await until("the read of another") { gate.asked.count == 3 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.asked.map(\.buildId) == [1, 1, 2])
        try await gate.answer(.success(investigation(2)))
        try await until("its answer") { store.look(2, of: delivery.key)?.isReading == false }
        #expect(store.expanded == [1, 2])

        // Another pull request's details don't have them.
        #expect(!store.isExpanded(1, of: slowQueries.key))
        #expect(store.look(1, of: slowQueries.key) == nil)
    }

    /// Fix the Build quotes what shows of a run while it's open, as its check and pull request are now: not what's kept of
    /// one that's folded, nor what was read before it ran again, under the same ID, until it's read again.
    @Test func fixTheBuildQuotesOnlyWhatsCurrent() async throws {
        let gate = InvestigationGate()
        let store = makeStore(gate)
        let failed = Check(name: "shop-web CI", kind: .build, state: .failed, completedAt: now, buildId: 1, definitionId: 31)
        #expect(store.current(1, check: failed, of: delivery) == nil)
        store.expand(1, of: delivery, check: failed)
        try await gate.answer(.success(investigation(1)))
        try await until("the read") { store.look(1, of: delivery.key)?.isReading == false }
        #expect(store.current(1, check: failed, of: delivery) == investigation(1))
        // It ran again under the same ID, and failed again: what shows is the attempt before's, until it's read.
        var again = failed
        again.completedAt = now.addingTimeInterval(600)
        #expect(store.current(1, check: again, of: delivery) == nil)
        store.changed(1, of: delivery, check: again)
        let second = investigation(1, number: "20261102.4", readAt: now.addingTimeInterval(601))
        try await gate.answer(.success(second))
        try await until("the read again") { store.look(1, of: delivery.key)?.investigation == second }
        #expect(store.current(1, check: again, of: delivery) == second)
        // Pushed to since: another commit.
        var pushed = delivery
        pushed.sourceCommit = "f00d"
        #expect(store.current(1, check: again, of: pushed) == nil)
        // Folded, it isn't read again as it changes.
        store.collapse(1, of: delivery.key)
        #expect(store.look(1, of: delivery.key)?.investigation == second)
        #expect(store.current(1, check: again, of: delivery) == nil)
    }

    @Test func readingAgainShowsWhatWasReadUntilItsAnswered() async throws {
        let gate = InvestigationGate()
        let store = makeStore(gate)
        store.expand(1, of: delivery)
        try await gate.answer(.success(investigation(1)))
        try await until("the read") { store.look(1, of: delivery.key)?.isReading == false }

        store.read(1, of: delivery, again: true)
        try await until("the read again") { gate.asked.count == 2 }
        #expect(gate.asked.last?.again == true)
        #expect(store.look(1, of: delivery.key)?.isReading == true)
        #expect(store.look(1, of: delivery.key)?.investigation == investigation(1))
        // It couldn't be: what was read stays, with why.
        try await gate.answer(.failure(.offline))
        try await until("the read again") { store.look(1, of: delivery.key)?.isReading == false }
        #expect(store.look(1, of: delivery.key)?.investigation == investigation(1))
        #expect(store.look(1, of: delivery.key)?.failure == .offline)

        // Then it could.
        let later = investigation(1, number: "20261102.5", readAt: now.addingTimeInterval(60))
        store.read(1, of: delivery, again: true)
        try await gate.answer(.success(later))
        try await until("the third read") { store.look(1, of: delivery.key)?.isReading == false }
        #expect(store.look(1, of: delivery.key)?.investigation == later)
        #expect(store.look(1, of: delivery.key)?.failure == nil)

        // Asked to read it anew while it's read, it waits for that read, which the investigator would share, then reads.
        store.read(1, of: delivery, again: true)
        try await until("the fourth read") { gate.asked.count == 4 }
        store.read(1, of: delivery, again: true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.asked.count == 4)
        try await gate.answer(.success(investigation(1, number: "first")))
        try await until("the fifth read") { gate.asked.count == 5 }
        #expect(gate.asked.last?.again == true)
        #expect(store.look(1, of: delivery.key)?.investigation?.run.number == "first")
        #expect(store.look(1, of: delivery.key)?.isReading == true)
        try await gate.answer(.success(investigation(1, number: "second")))
        try await until("the last read") { store.look(1, of: delivery.key)?.isReading == false }
        #expect(store.look(1, of: delivery.key)?.investigation?.run.number == "second")
        #expect(gate.asked.count == 5)
    }

    @Test func aRunWhoseCheckChangedIsReadAgain() async throws {
        let gate = InvestigationGate()
        let store = makeStore(gate)
        let running = Check(name: "shop-web CI", kind: .build, state: .running, buildId: 1)
        var failed = running
        failed.state = .failed
        failed.completedAt = now
        store.expand(1, of: delivery, check: running)
        try await gate.answer(.success(investigation(1, number: "running")))
        try await until("the read") { store.look(1, of: delivery.key)?.isReading == false }

        // The list reads the same check again: nothing changed.
        store.changed(1, of: delivery, check: running)
        #expect(gate.asked.count == 1)
        // It finished while it was open: it's read again, rather than what the investigator kept of it.
        store.changed(1, of: delivery, check: failed)
        try await until("the read again") { gate.asked.count == 2 }
        #expect(gate.asked.last?.again == true)
        #expect(store.look(1, of: delivery.key)?.investigation?.run.number == "running")
        try await gate.answer(.success(investigation(1, number: "failed")))
        try await until("the answer") { store.look(1, of: delivery.key)?.investigation?.run.number == "failed" }

        // It runs again while it's folded: nothing's read until it opens, and then it is.
        store.collapse(1, of: delivery.key)
        var again = failed
        again.state = .running
        again.completedAt = nil
        store.changed(1, of: delivery, check: again)
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.asked.count == 2)
        store.expand(1, of: delivery, check: again)
        try await until("the read as it opens") { gate.asked.count == 3 }
        #expect(gate.asked.last?.again == true)
        try await gate.answer(.success(investigation(1, number: "again")))
        try await until("its answer") { store.look(1, of: delivery.key)?.investigation?.run.number == "again" }

        // It failed again, at another time, while it was off screen: as its row shows again, it's read again.
        var failedAgain = again
        failedAgain.state = .failed
        failedAgain.completedAt = now.addingTimeInterval(600)
        store.changed(1, of: delivery, check: failedAgain)
        try await until("the last read") { gate.asked.count == 4 }
        try await gate.answer(.success(investigation(1, number: "failed again")))
        try await until("the last answer") { store.look(1, of: delivery.key)?.isReading == false }
        // Opening it as it is asks the investigator for it, but not anew: what it keeps answers while it's fresh.
        store.collapse(1, of: delivery.key)
        store.expand(1, of: delivery, check: failedAgain)
        try await until("the ask as it opens again") { gate.asked.count == 5 }
        #expect(gate.asked.last?.again == false)
        #expect(store.look(1, of: delivery.key)?.investigation?.run.number == "failed again")
        try await gate.answer(.success(investigation(1, number: "failed again")))
        try await until("its answer") { store.look(1, of: delivery.key)?.isReading == false }
    }

    @Test func whatChangesWhileItsReadIsReadOnceThatReadIsDone() async throws {
        let gate = InvestigationGate()
        let store = makeStore(gate)
        let running = Check(name: "shop-web CI", kind: .build, state: .running, buildId: 1)
        var failed = running
        failed.state = .failed
        failed.completedAt = now
        store.expand(1, of: delivery, check: running)
        try await until("the read") { gate.asked.count == 1 }
        // It finishes while it's read: the investigator would answer with that read, from before, so it's waited for, then
        // the run is read anew.
        store.changed(1, of: delivery, check: failed)
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.asked.count == 1)
        try await gate.answer(.success(investigation(1, number: "running")))
        try await until("the read anew") { gate.asked.count == 2 }
        #expect(gate.asked.last?.again == true)
        #expect(store.look(1, of: delivery.key)?.investigation?.run.number == "running")
        #expect(store.look(1, of: delivery.key)?.isReading == true)
        try await gate.answer(.success(investigation(1, number: "failed")))
        try await until("its answer") { store.look(1, of: delivery.key)?.isReading == false }
        #expect(store.look(1, of: delivery.key)?.investigation?.run.number == "failed")
        #expect(store.look(1, of: delivery.key)?.readFor == BuildInvestigationStore.Stamp(check: failed, pullRequest: delivery))

        // Someone pushes while it's read: once that read is done, it's asked for again, for the new commit, but not anew.
        store.read(1, of: delivery, check: failed, again: true)
        try await until("the read again") { gate.asked.count == 3 }
        var pushed = delivery
        pushed.sourceCommit = "c4088-2"
        store.changed(1, of: pushed, check: failed)
        store.changed(1, of: pushed, check: failed)
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.asked.count == 3)
        try await gate.answer(.success(investigation(1, number: "before the push")))
        try await until("the ask for the push") { gate.asked.count == 4 }
        #expect(gate.asked.last?.again == false)
        #expect(gate.asked.last?.pullRequest.sourceCommit == "c4088-2")
        try await gate.answer(.success(investigation(1, number: "after the push")))
        try await until("its answer") { store.look(1, of: delivery.key)?.isReading == false }
        #expect(store.look(1, of: delivery.key)?.investigation?.run.number == "after the push")
        #expect(gate.asked.count == 4)
    }

    @Test func aPushOrARetargetIsAskedForAgainWhileItsOpen() async throws {
        let gate = InvestigationGate()
        let store = makeStore(gate)
        let failed = Check(name: "shop-web CI", kind: .build, state: .failed, completedAt: now, buildId: 1)
        store.expand(1, of: delivery, check: failed)
        try await gate.answer(.success(investigation(1)))
        try await until("the read") { store.look(1, of: delivery.key)?.isReading == false }

        // Someone pushed: the investigator's asked again, to say whether the run built the latest commit.
        var pushed = delivery
        pushed.sourceCommit = "c4088-2"
        pushed.mergeCommit = "m4088-2"
        store.changed(1, of: pushed, check: failed)
        try await until("the ask for the push") { gate.asked.count == 2 }
        #expect(gate.asked.last?.again == false)
        #expect(gate.asked.last?.pullRequest.sourceCommit == "c4088-2")
        try await gate.answer(.success(investigation(1)))
        try await until("its answer") { store.look(1, of: delivery.key)?.isReading == false }

        // Retargeted: asked again, to compare it with the new target branch.
        var retargeted = pushed
        retargeted.targetBranch = "release"
        store.changed(1, of: retargeted, check: failed)
        try await until("the ask for release") { gate.asked.count == 3 }
        #expect(gate.asked.last?.again == false)
        #expect(gate.asked.last?.pullRequest.targetBranch == "release")
        try await gate.answer(.success(investigation(1)))
        try await until("its answer") { store.look(1, of: delivery.key)?.isReading == false }

        // As it is, nothing's asked; folded, nothing is until it opens.
        store.changed(1, of: retargeted, check: failed)
        store.collapse(1, of: delivery.key)
        var conflicting = retargeted
        conflicting.mergeStatus = "conflicts"
        store.changed(1, of: conflicting, check: failed)
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.asked.count == 3)
    }

    @Test func aReadAskedForSinceIsDroppedWhenWhatsReadIsWhatsAskedForAgain() async throws {
        let gate = InvestigationGate()
        let store = makeStore(gate)
        let failed = Check(name: "shop-web CI", kind: .build, state: .failed, completedAt: now, buildId: 1)
        store.expand(1, of: delivery, check: failed)
        try await until("the read for main") { gate.asked.count == 1 }
        // Retargeted to release while it's read for main, then back to main: the read for release isn't needed any more.
        var retargeted = delivery
        retargeted.targetBranch = "release"
        store.changed(1, of: retargeted, check: failed)
        store.changed(1, of: delivery, check: failed)
        try await gate.answer(.success(investigation(1, number: "for main")))
        try await until("its answer") { store.look(1, of: delivery.key)?.isReading == false }
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.asked.count == 1)
        #expect(store.look(1, of: delivery.key)?.investigation?.run.number == "for main")
        #expect(store.look(1, of: delivery.key)?.readFor == BuildInvestigationStore.Stamp(check: failed, pullRequest: delivery))

        // A read asked for anew since, as when the check changed and back, still reads, anew, for what it's asked for now.
        store.read(1, of: delivery, check: failed, again: true)
        try await until("the read again") { gate.asked.count == 2 }
        var running = failed
        running.state = .running
        running.completedAt = nil
        store.changed(1, of: delivery, check: running)
        store.changed(1, of: delivery, check: failed)
        try await gate.answer(.success(investigation(1, number: "first")))
        try await until("the read anew") { gate.asked.count == 3 }
        #expect(gate.asked.last?.again == true)
        #expect(gate.asked.last?.phase == .finished)
        try await gate.answer(.success(investigation(1, number: "anew")))
        try await until("its answer") { store.look(1, of: delivery.key)?.isReading == false }
        #expect(store.look(1, of: delivery.key)?.investigation?.run.number == "anew")
    }

    @Test func theInvestigatorHearsHowFarAlongTheRunIs() async throws {
        let gate = InvestigationGate()
        let store = makeStore(gate)
        let queued = Check(name: "shop-web CI", kind: .build, state: .queued, buildId: 1)
        var running = queued
        running.state = .running
        var failed = queued
        failed.state = .failed
        failed.completedAt = now
        store.expand(1, of: delivery, check: queued)
        try await until("the read") { gate.asked.count == 1 }
        #expect(gate.asked.last?.phase == .queued)
        try await gate.answer(.success(investigation(1, number: "queued")))
        try await until("its answer") { store.look(1, of: delivery.key)?.isReading == false }
        // Another pull request shows, and what was read here goes. Back here, the run started since, then finished: the
        // investigator, which may keep it as it was, hears so each time, without being asked to read it anew.
        for (check, phase) in [(running, PipelineRun.Phase.running), (failed, .finished)] {
            store.show(slowQueries.key)
            store.expand(1, of: delivery, check: check)
            try await until("the read as it opens") { gate.asked.count == (phase == .running ? 2 : 3) }
            #expect(gate.asked.last?.phase == phase)
            #expect(gate.asked.last?.again == false)
            try await gate.answer(.success(investigation(1, number: "\(phase)")))
            try await until("its answer") { store.look(1, of: delivery.key)?.isReading == false }
        }
        #expect(store.look(1, of: delivery.key)?.investigation?.run.number == "finished")
        let phases = [Check.State.queued, .running, .passed, .failed, .expired, .notRun, .pending, .notApplicable].map {
            BuildInvestigationStore.Stamp(check: Check(name: "", kind: .build, state: $0), pullRequest: delivery).phase
        }
        #expect(phases == [.queued, .running, .finished, .finished, .finished, nil, nil, nil])
        #expect(BuildInvestigationStore.Stamp(check: nil, pullRequest: delivery).phase == nil)
    }

    @Test func aRunThatsGoneLetsGoOfWhatWasRead() async throws {
        let gate = InvestigationGate()
        let store = makeStore(gate)
        for error in [ADOError.notFound, .forbidden] {
            store.read(1, of: delivery, again: true)
            try await gate.answer(.success(investigation(1)))
            try await until("the read") { store.look(1, of: delivery.key)?.investigation != nil }
            // Deleted, or no longer yours to read: what was read of it goes too, rather than show beside why.
            store.read(1, of: delivery, again: true)
            try await gate.answer(.failure(error))
            try await until("the read again") { store.look(1, of: delivery.key)?.isReading == false }
            #expect(store.look(1, of: delivery.key)?.investigation == nil)
            #expect(store.look(1, of: delivery.key)?.failure == error)
        }
    }

    @Test func whatWasReadOfARunThatRanAgainGoesWhenItCantBeReadAgain() async throws {
        let gate = InvestigationGate()
        let store = makeStore(gate)
        var failed = Check(name: "shop-web CI", kind: .build, state: .failed, buildId: 1)
        failed.completedAt = now
        store.expand(1, of: delivery, check: failed)
        try await gate.answer(.success(investigation(1, number: "first")))
        try await until("the read") { store.look(1, of: delivery.key)?.isReading == false }

        // Opened again, the investigator's look at the run finds it ran again, and then it can't be read: what was read of
        // the earlier attempt goes, rather than show beside why.
        store.collapse(1, of: delivery.key)
        store.expand(1, of: delivery, check: failed)
        try await gate.fail(BuildInvestigator.RunReplaced(error: .offline))
        try await until("the read as it opens") { store.look(1, of: delivery.key)?.isReading == false }
        #expect(store.look(1, of: delivery.key)?.investigation == nil)
        #expect(store.look(1, of: delivery.key)?.failure == .offline)

        // Its check says it ran again, and finished at another time, since what shows was read: that goes too.
        store.read(1, of: delivery, check: failed, again: true)
        try await gate.answer(.success(investigation(1, number: "second")))
        try await until("the read again") { store.look(1, of: delivery.key)?.investigation?.run.number == "second" }
        var failedAgain = failed
        failedAgain.completedAt = now.addingTimeInterval(600)
        store.changed(1, of: delivery, check: failedAgain)
        try await gate.answer(.failure(.offline))
        try await until("the read for its check") { store.look(1, of: delivery.key)?.isReading == false }
        #expect(store.look(1, of: delivery.key)?.investigation == nil)
        #expect(store.look(1, of: delivery.key)?.failure == .offline)

        // A run that only finished since, the same attempt, keeps what was read while it went, beside why.
        let running = Check(name: "shop-web CI", kind: .build, state: .running, buildId: 2)
        var finished = running
        finished.state = .failed
        finished.completedAt = now
        store.expand(2, of: delivery, check: running)
        try await gate.answer(.success(investigation(2, number: "running")))
        try await until("the read") { store.look(2, of: delivery.key)?.isReading == false }
        store.changed(2, of: delivery, check: finished)
        try await gate.answer(.failure(.offline))
        try await until("the read once it finished") { store.look(2, of: delivery.key)?.isReading == false }
        #expect(store.look(2, of: delivery.key)?.investigation?.run.number == "running")
        #expect(store.look(2, of: delivery.key)?.failure == .offline)

        // What a check says of a run that ran again: it had finished, and it's queued or running now, or finished at
        // another time.
        func stamp(_ state: Check.State, at completedAt: Date? = nil) -> BuildInvestigationStore.Stamp {
            BuildInvestigationStore.Stamp(check: Check(name: "", kind: .build, state: state, completedAt: completedAt), pullRequest: delivery)
        }
        let done = stamp(.failed, at: now)
        #expect(stamp(.running).ranAgain(since: done))
        #expect(stamp(.queued).ranAgain(since: done))
        #expect(stamp(.passed, at: now.addingTimeInterval(60)).ranAgain(since: done))
        #expect(!stamp(.failed, at: now).ranAgain(since: done))
        #expect(!stamp(.notRun).ranAgain(since: done))
        #expect(!stamp(.failed, at: now).ranAgain(since: stamp(.running)))
        #expect(!stamp(.running).ranAgain(since: stamp(.queued)))
    }

    @Test func foldedBuildsKeepWhatsReadOnlyForTheLastFew() throws {
        let store = makeStore()
        let kept = BuildInvestigationStore.foldedKept
        let builds = Array(1...(kept + 3))
        for id in builds {
            store.expand(id, of: delivery)
        }
        #expect(store.looks.count == builds.count)
        // The first stays open; the others fold, the earliest first: only the last few keep what's read of them.
        for id in builds.dropFirst() {
            store.collapse(id, of: delivery.key)
        }
        #expect(Set(store.looks.keys) == Set([1] + builds.suffix(kept)))
        #expect(store.expanded == [1])
        // Opened again, the earliest of those doesn't count among the folded ones: folding the first then keeps it too.
        let reopened = builds[builds.count - kept]
        store.expand(reopened, of: delivery)
        store.collapse(1, of: delivery.key)
        #expect(Set(store.looks.keys) == Set([1, reopened] + builds.suffix(kept)))
        #expect(store.expanded == [reopened])
    }

    @Test func aFoldedBuildBeingReadKeepsItsReadUntilItsDone() async throws {
        let gate = InvestigationGate()
        let store = makeStore(gate)
        let kept = BuildInvestigationStore.foldedKept
        store.expand(1, of: delivery)
        try await until("the read") { gate.asked.count == 1 }
        store.collapse(1, of: delivery.key)
        for id in 2...(kept + 2) {
            store.expand(id, of: delivery)
            try await gate.answer(id, .success(investigation(id)))
            try await until("its answer") { store.looks[id]?.isReading == false }
            store.collapse(id, of: delivery.key)
        }
        // Folded first, but still being read, it stays, and those that folded after it go instead.
        #expect(Set(store.looks.keys) == Set([1] + Array(4...(kept + 2))))
        try await gate.answer(1, .success(investigation(1)))
        try await until("its answer") { store.looks[1]?.isReading == false }
        // Once it's read, it's the earliest that folded, and goes first.
        store.expand(kept + 3, of: delivery)
        try await gate.answer(kept + 3, .success(investigation(kept + 3)))
        try await until("its answer") { store.looks[kept + 3]?.isReading == false }
        store.collapse(kept + 3, of: delivery.key)
        #expect(Set(store.looks.keys) == Set(4...(kept + 3)))
    }

    @Test func aRunTheChecksDontListAnyMoreGoes() async throws {
        let gate = InvestigationGate()
        let store = makeStore(gate)
        store.expand(1, of: delivery)
        store.expand(2, of: delivery)
        try await until("both reads") { gate.asked.count == 2 }
        try await gate.answer(1, .success(investigation(1)))
        try await until("the first answer") { store.look(1, of: delivery.key)?.isReading == false }
        store.collapse(1, of: delivery.key)
        // A newer run replaced both: they go, and the read under way doesn't answer.
        store.retain([3], of: delivery.key)
        #expect(store.looks.isEmpty && store.expanded.isEmpty)
        try await gate.answer(2, .success(investigation(2)))
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.looks.isEmpty)
        // Another pull request's runs change nothing here; nor do this one's, while they list it.
        store.expand(3, of: delivery)
        store.retain([], of: slowQueries.key)
        store.retain([3, 4], of: delivery.key)
        #expect(store.isExpanded(3, of: delivery.key))
        try await gate.answer(3, .success(investigation(3)))
        try await until("its answer") { store.look(3, of: delivery.key)?.isReading == false }
        #expect(store.look(3, of: delivery.key)?.investigation == investigation(3))
    }

    @Test func aRunThatCantBeReadSaysWhyAndOpeningItAgainTriesAgain() async throws {
        let gate = InvestigationGate()
        let store = makeStore(gate)
        store.expand(1, of: delivery)
        try await gate.answer(.failure(.notFound))
        try await until("the read") { store.look(1, of: delivery.key)?.isReading == false }
        #expect(store.look(1, of: delivery.key)?.investigation == nil)
        #expect(store.look(1, of: delivery.key)?.failure == .notFound)
        store.collapse(1, of: delivery.key)
        store.expand(1, of: delivery)
        try await until("the read again") { gate.asked.count == 2 }
        try await gate.answer(.success(investigation(1)))
        try await until("the read again") { store.look(1, of: delivery.key)?.isReading == false }
        #expect(store.look(1, of: delivery.key)?.investigation == investigation(1))
        #expect(store.look(1, of: delivery.key)?.failure == nil)
    }

    @Test func anotherPullRequestFoldsTheBuildsAndLetsGoOfTheirReads() async throws {
        let gate = InvestigationGate()
        let store = makeStore(gate)
        store.expand(1, of: delivery)
        store.show(slowQueries.key)
        #expect(store.pullRequest == slowQueries.key)
        #expect(!store.isExpanded(1, of: delivery.key))
        #expect(store.expanded.isEmpty && store.looks.isEmpty)
        // The read that was under way answers, and nothing shows it.
        try await gate.answer(.success(investigation(1)))
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.looks.isEmpty)

        // Showing the same one again changes nothing.
        store.expand(3, of: slowQueries)
        store.show(slowQueries.key)
        #expect(store.isExpanded(3, of: slowQueries.key))
        // Opening one of another's shows that one.
        store.expand(1, of: delivery)
        #expect(store.pullRequest == delivery.key)
        #expect(store.expanded == [1])
        // The details beside the list stop showing another pull request, such as the one before: these stay.
        store.close(slowQueries.key)
        #expect(store.isExpanded(1, of: delivery.key))
        // They stop showing this one: it folds.
        store.close(delivery.key)
        #expect(store.pullRequest == nil && store.expanded.isEmpty && store.looks.isEmpty)
        store.expand(1, of: delivery)
        store.show(nil)
        #expect(store.pullRequest == nil && store.expanded.isEmpty && store.looks.isEmpty)
    }

    /// Showing another pull request calls off the store's reads under way: so do closing the details and someone else
    /// signing in.
    @Test(.timeLimit(.minutes(5)))
    func lettingGoCallsOffTheReadsUnderWay() async throws {
        let (started, startedOne) = AsyncStream<Int>.makeStream()
        let (calledOff, calledOffOne) = AsyncStream<Int>.makeStream()
        let store = BuildInvestigationStore(mode: .live, client: ADOClient(tokens: NoTokens()), now: { [now] in now }) { buildId, _, _, _ in
            startedOne.yield(buildId)
            do {
                while true { try await Task.sleep(for: .milliseconds(5)) }
            } catch {
                calledOffOne.yield(buildId)
                throw error
            }
        }
        var startedIterator = started.makeAsyncIterator()
        var calledOffIterator = calledOff.makeAsyncIterator()
        store.expand(1, of: delivery)
        #expect(await startedIterator.next() == 1)
        store.show(slowQueries.key)
        #expect(await calledOffIterator.next() == 1)
        store.expand(3, of: slowQueries)
        #expect(await startedIterator.next() == 3)
        store.close(slowQueries.key)
        #expect(await calledOffIterator.next() == 3)
        store.accountChanged("home/robin")
        store.expand(1, of: delivery)
        #expect(await startedIterator.next() == 1)
        store.accountChanged("home/sam")
        #expect(await calledOffIterator.next() == 1)
    }

    /// How the details let go of a run, for `lettingGoStopsTheInvestigatorsRead`.
    enum LetGo: String, CaseIterable, Sendable {
        case anotherPullRequest = "showing another pull request"
        case someoneElse = "someone else signing in"
    }

    /// Through its own `BuildInvestigator`, over a stand-in for Azure DevOps: as the details let go of a run, showing another
    /// pull request, or as someone else signs in, the investigator's read of it, waiting for a token, is called off
    /// (`BuildInvestigator.giveUp`, `forget`), and nothing more of the run is read, its timeline, logs and tests. It waits on
    /// what becomes of the token, never for a while: on CI's slow runners, `make test` took up to about three and a
    /// half minutes on 2026-11-08, all of it at once on the one thread it gives the cooperative pool, and a test that
    /// starts early can take most of that, however little it does. Its time limit is above that.
    @Test(.timeLimit(.minutes(5)), arguments: LetGo.allCases)
    func lettingGoStopsTheInvestigatorsRead(_ letGo: LetGo) async throws {
        let tokens = HeldToken()
        var events = tokens.events.makeAsyncIterator()
        let client = ADOClient(tokens: tokens, session: ADOClient.makeSession(protocolClasses: [StandInAzureDevOps.self]))
        let store = BuildInvestigationStore(mode: .live, client: client, now: { [now] in now })
        store.accountChanged("home/robin")
        store.expand(1, of: delivery)
        // Its read asks for its first token, which waits.
        #expect(await events.next() == .holding)
        switch letGo {
        case .anotherPullRequest: store.show(slowQueries.key)
        case .someoneElse: store.accountChanged("home/sam")
        }
        #expect(await events.next() == .calledOff, "\(letGo.rawValue): the read wasn't called off")
        await tokens.release()
        // A read that went on once its token came would ask for the run's timeline and logs at once, and one called off asks
        // for nothing more (`BuildInvestigationReader.readRun`): a while to see that, which a busy machine can only make too
        // short to catch one that went on, never fail one that didn't.
        try await Task.sleep(for: .milliseconds(100))
        let asked = StandInAzureDevOps.asked.withLock { $0[tokens.value] ?? [] }
        #expect(!asked.contains { $0.hasSuffix("/timeline") || $0.contains("/logs") }, "\(letGo.rawValue): \(asked)")
    }

    @Test func someoneElseSigningInLetsGoOfWhatWasRead() async throws {
        let gate = InvestigationGate()
        let store = makeStore(gate)
        store.accountChanged("robin@contoso.com")
        store.expand(1, of: delivery)
        try await gate.answer(.success(investigation(1)))
        try await until("the read") { store.look(1, of: delivery.key)?.isReading == false }
        // The same one, or not knowing, keeps it.
        store.accountChanged("robin@contoso.com")
        store.accountChanged(nil)
        #expect(store.isExpanded(1, of: delivery.key))
        #expect(store.look(1, of: delivery.key)?.investigation != nil)
        // Someone else doesn't.
        store.accountChanged("sam@contoso.com")
        #expect(store.expanded.isEmpty && store.looks.isEmpty)

        // Nor does turning Azure DevOps off: a read under way then shows nothing, and nothing's read any more.
        store.expand(1, of: delivery)
        store.stop()
        #expect(store.pullRequest == nil && store.expanded.isEmpty && store.looks.isEmpty)
        try await gate.answer(.success(investigation(1)))
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.looks.isEmpty)
        let asked = gate.asked.count
        store.expand(1, of: delivery)
        store.read(1, of: delivery, again: true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.asked.count == asked)
        #expect(store.pullRequest == nil && store.expanded.isEmpty && store.looks.isEmpty)
    }

    @Test func theDemoReadsItsMadeUpBuildsAtOnce() throws {
        let store = makeStore()
        store.expand(204_417, of: delivery)
        let look = try #require(store.look(204_417, of: delivery.key))
        #expect(!look.isReading)
        #expect(look.investigation?.failurePlace == ["Test", "Unit tests", "Run unit tests"])
        // One it didn't make up isn't there.
        store.expand(1, of: delivery)
        #expect(store.look(1, of: delivery.key)?.failure == .notFound)
        #expect(store.look(1, of: delivery.key)?.isReading == false)
    }

    /// What's left's failed build leads to its run, which the details open; what's left's other items lead to their part,
    /// only to scroll there, and the details don't open a build for that.
    @Test func whatsLeftLeadsToTheFailedBuildToOpenIt() throws {
        let now = Date()
        let seen = DemoData.seenState(now: now)
        let records = DemoData.records(now: now)
        func panel(_ number: Int) throws -> PullRequestPanel {
            let record = try #require(records.first { $0.id.number == number })
            let row = try #require(PRClassifier.snapshot(
                for: record, seenCutoff: seen.cutoff(for: record.id), dismissedCutoff: seen.dismissedCutoff(for: record.id), now: now
            ))
            return PullRequestPanel(row, record: record)
        }
        typealias Place = PullRequestDetailsStore.Place
        /// Where each item of what's left leads, by its label; one that leads nowhere isn't there.
        func places(_ number: Int) throws -> (labels: [String], places: [String: Place]) {
            let panel = try panel(number)
            let items = try #require(panel.readiness).items
            var places: [String: Place] = [:]
            for item in items { places[item.label] = Place.of(item, in: panel) }
            return (items.map(\.label), places)
        }
        let delivery = try places(4088)
        #expect(delivery.places["Build failed"] == .run(204_417))
        #expect(delivery.places["Approved"] == .section(.reviewers))
        let slowQueries = try places(4099)
        #expect(slowQueries.places["Build running"] == .section(.checks))
        let coupons = try places(4091)
        #expect(coupons.places["Build passed"] == .section(.checks))
        #expect(coupons.places["Comments resolved"] == .section(.comments))
        let draft = try places(4105)
        #expect(draft.places["Build hasn't run"] == .section(.checks))
        #expect(draft.labels.contains("Publish the draft") && draft.places["Publish the draft"] == nil)
    }

    @Test func itSaysWhyARunCantBeRead() {
        #expect(BuildInvestigationStore.message(for: .notFound)
            == "Azure DevOps can't find this run. It may have been deleted, or moved where you can't see it.")
        #expect(BuildInvestigationStore.message(for: .forbidden) == "You don't have access to this run.")
        #expect(BuildInvestigationStore.message(for: .otherDirectory(organization: "fabrikam", tenant: "t1"))
            == "fabrikam is in a directory your Azure CLI isn't signed in to.")
        #expect(BuildInvestigationStore.message(for: .offline) == "You're offline.")
        #expect(BuildInvestigationStore.message(for: .throttled(retryAfter: 30)) == "Azure DevOps asked BriefBar to slow down. Try again in a minute.")
        #expect(BuildInvestigationStore.message(for: .http(500)) == ADOError.http(500).description)
    }
}
