import AzureDevOpsCore
import BriefBarCore
import Foundation
import Testing
@testable import AzureDevOpsUI

/// Reads of builds that wait for the test to answer them, as Azure DevOps answers later: what the store does meanwhile.
@MainActor
private final class InvestigationGate {
    private(set) var asked: [(buildId: Int, again: Bool)] = []
    private var waiting: [CheckedContinuation<BuildInvestigation, Error>] = []

    var reader: BuildInvestigationStore.Reader {
        { [self] buildId, _, again in try await self.read(buildId, again: again) }
    }

    private func read(_ buildId: Int, again: Bool) async throws -> BuildInvestigation {
        asked.append((buildId, again))
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }

    /// Waits for the store to ask, then answers its oldest read.
    func answer(_ result: Result<BuildInvestigation, ADOError>) async throws {
        try await until("a read") { !waiting.isEmpty }
        waiting.removeFirst().resume(with: result.mapError { $0 as Error })
    }
}

private struct Timeout: Error, CustomStringConvertible {
    let description: String
}

/// Lets the store's reads go on until `condition` holds.
@MainActor
private func until(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw Timeout(description: "Timed out waiting for \(what)") }
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// The builds opened in a pull request's details, and what's read of them: read when one opens, once; read again when
/// asked, while what was read shows; and let go of for another pull request, or someone else signing in. With reads the
/// tests answer, or the made-up builds, which never use the Azure CLI or Azure DevOps.
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

    @Test func aBuildIsReadWhenItOpensAndOnce() async throws {
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

        // Closed and opened again, what was read shows at once, without reading it again.
        store.toggle(1, of: delivery)
        #expect(!store.isExpanded(1, of: delivery.key))
        #expect(store.look(1, of: delivery.key)?.investigation != nil)
        store.toggle(1, of: delivery)
        #expect(store.isExpanded(1, of: delivery.key))
        #expect(gate.asked.count == 1)

        // Nor while it's being read.
        store.expand(2, of: delivery)
        store.collapse(2, of: delivery.key)
        store.expand(2, of: delivery)
        try await until("the second read") { gate.asked.count == 2 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.asked.map(\.buildId) == [1, 2])
        try await gate.answer(.success(investigation(2)))
        try await until("the second answer") { store.look(2, of: delivery.key)?.isReading == false }
        #expect(store.expanded == [1, 2])

        // Another pull request's details don't have them.
        #expect(!store.isExpanded(1, of: slowQueries.key))
        #expect(store.look(1, of: slowQueries.key) == nil)
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

        // Asked for again while it's read: the later read answers, and the earlier one is let go.
        store.read(1, of: delivery, again: true)
        try await until("the fourth read") { gate.asked.count == 4 }
        store.read(1, of: delivery, again: true)
        try await until("the fifth read") { gate.asked.count == 5 }
        try await gate.answer(.success(investigation(1, number: "first")))
        try await gate.answer(.success(investigation(1, number: "second")))
        try await until("the last read") { store.look(1, of: delivery.key)?.investigation?.run.number == "second" }
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.look(1, of: delivery.key)?.investigation?.run.number == "second")
        #expect(store.look(1, of: delivery.key)?.isReading == false)
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
        store.checkChanged(1, of: delivery, check: running)
        #expect(gate.asked.count == 1)
        // It finished while it was open: it's read again, rather than what the investigator kept of it.
        store.checkChanged(1, of: delivery, check: failed)
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
        store.checkChanged(1, of: delivery, check: again)
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
        store.checkChanged(1, of: delivery, check: failedAgain)
        try await until("the last read") { gate.asked.count == 4 }
        try await gate.answer(.success(investigation(1, number: "failed again")))
        try await until("the last answer") { store.look(1, of: delivery.key)?.isReading == false }
        // Opening it as it is reads nothing more.
        store.collapse(1, of: delivery.key)
        store.expand(1, of: delivery, check: failedAgain)
        try await Task.sleep(for: .milliseconds(20))
        #expect(gate.asked.count == 4)
        #expect(store.look(1, of: delivery.key)?.investigation?.run.number == "failed again")
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
        // Closing the details folds it.
        store.show(nil)
        #expect(store.pullRequest == nil && store.expanded.isEmpty && store.looks.isEmpty)
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

        // Nor does turning Azure DevOps off.
        store.expand(1, of: delivery)
        store.stop()
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
