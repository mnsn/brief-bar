import Foundation
import Synchronization
import Testing
@testable import AzureDevOpsCore

/// A made-up failed run of `makePR()`'s pipeline, with everything an investigation reads, served by a stub Azure DevOps.
private enum FailedRun {
    static let id = 77
    static let definition = 31

    static func build(
        _ id: Int = FailedRun.id, status: String = "completed", result: String? = "failed", queued: Date = t(-hour),
        branch: String = "refs/pull/7/merge", source: String? = "abc", merge: String? = "merge"
    ) -> [String: Any] {
        var json = WorkFixture.build(
            id, definition: definition, status: status, result: result, queued: queued, branch: branch,
            reason: branch.hasPrefix("refs/pull/") ? "pullRequest" : "individualCI"
        )
        if let source { json["triggerInfo"] = ["pr.sourceSha": source] }
        if let merge { json["sourceVersion"] = merge }
        return json
    }

    static var timeline: [String: Any] {
        typealias F = InvestigationFixture
        return WorkFixture.timeline([
            F.record("build", "Stage", "Build", order: 1, finished: t(-55 * minute)),
            F.record("test", "Stage", "Test", order: 2, result: "failed", finished: t(-50 * minute)),
            F.record("test-phase", "Phase", "Unit tests", parent: "test", order: 1, result: "failed"),
            F.record("test-job", "Job", "Unit tests", parent: "test-phase", order: 1, result: "failed", log: 3),
            F.record("checkout", "Task", "Checkout", parent: "test-job", order: 1, finished: t(-54 * minute), log: 4),
            F.record("run-tests", "Task", "Run tests", parent: "test-job", order: 2, result: "failed", finished: t(-51 * minute), log: 9,
                     issues: [F.issue("error", "2 tests failed in CartTests.", data: ["type": "error", "logFileLineNumber": "5"])]),
            F.record("publish", "Task", "Publish test results", parent: "test-job", order: 3, finished: t(-50 * minute), log: 10),
        ])
    }

    static let logLines = [
        "2026-10-18T09:09:00.0000000Z ##[section]Starting: Run tests",
        "2026-10-18T09:09:01.0000000Z ##[command]/usr/bin/dotnet test",
        "2026-10-18T09:09:02.0000000Z \u{1B}[31m  Failed CartTests.AddsTax [3 ms]\u{1B}[0m",
        "2026-10-18T09:09:03.0000000Z ##[endgroup]",
        "2026-10-18T09:09:04.0000000Z ##[error]2 tests failed in CartTests.",
        "2026-10-18T09:09:05.0000000Z ##[section]Finishing: Run tests",
    ]

    static var testRuns: [[String: Any]] { [
        ["id": 501, "name": "Unit", "state": "Completed", "totalTests": 40, "passedTests": 38, "unanalyzedTests": 2,
         "runStatistics": [["state": "Completed", "outcome": "Passed", "count": 38], ["state": "Completed", "outcome": "Failed", "count": 2]]],
        ["id": 502, "name": "Lint", "state": "Completed", "totalTests": 5, "passedTests": 5,
         "runStatistics": [["state": "Completed", "outcome": "Passed", "count": 5]]],
    ] }

    static var results: [[String: Any]] { [
        ["id": 100_001, "outcome": "Failed", "testCaseTitle": "AddsTax", "automatedTestName": "Shop.Tests.CartTests.AddsTax",
         "errorMessage": "Expected 12, got 10", "stackTrace": "at Shop.Tests.CartTests.AddsTax()", "durationInMs": 3],
        ["id": 100_002, "outcome": "Failed", "automatedTestName": "Shop.Tests.CartTests.RoundsTotal"],
    ] }

    /// A log's lines as Azure DevOps lists them.
    static func lines(_ lines: [String]) -> [String: Any] {
        ["count": lines.count, "value": lines]
    }

    /// Serves the run, and everything about it. `replies` answers instead for what it names: `build`, `timeline`, `logs`,
    /// `lines`, `testRuns`, `results`, `earlier` or `target`.
    static func serve(_ server: StubServer, build: [String: Any] = FailedRun.build(), replies: [String: StubServer.Reply] = [:]) {
        func on(_ name: String, _ path: String, query: [String: String] = [:], json: Any) {
            let reply = replies[name] ?? .json(json)
            server.on(path, query: query) { _ in reply }
        }
        let builds = "/\(Fixture.org)/p1/_apis/build/builds"
        // Later routes are tried first: the run's own last, after the lists, so that it doesn't answer for its timeline.
        on("earlier", builds, query: ["definitions": "31", "branchName": "refs/pull/7/merge"], json: Fixture.list([
            FailedRun.build(70, result: "succeeded", queued: t(-2 * hour)),
            FailedRun.build(60, result: "failed", queued: t(-3 * hour), source: "older", merge: "older-merge"),
            FailedRun.build(),
        ]))
        on("target", builds, query: ["definitions": "31", "branchName": "refs/heads/main", "statusFilter": "completed"], json: Fixture.list([
            FailedRun.build(90, result: "canceled", queued: t(-30 * minute), branch: "refs/heads/main", source: nil, merge: "main-3"),
            FailedRun.build(89, result: "failed", queued: t(-2 * hour), branch: "refs/heads/main", source: nil, merge: "main-2"),
            FailedRun.build(88, result: "succeeded", queued: t(-3 * hour), branch: "refs/heads/main", source: nil, merge: "main-1"),
        ]))
        on("build", "\(builds)/\(id)", json: build)
        on("timeline", "\(builds)/\(id)/timeline", json: timeline)
        on("logs", "\(builds)/\(id)/logs", json: Fixture.list([
            ["id": 3, "lineCount": 50, "type": "Container"], ["id": 4, "lineCount": 12], ["id": 9, "lineCount": logLines.count],
        ]))
        on("lines", "\(builds)/\(id)/logs/9", json: lines(logLines))
        on("testRuns", "/\(Fixture.org)/p1/_apis/test/runs", query: ["buildUri": "vstfs:///Build/Build/\(id)"], json: Fixture.list(testRuns))
        on("results", "/\(Fixture.org)/p1/_apis/test/Runs/501/results", json: Fixture.list(results))
    }

    /// `makePR()`, whose latest commit the run built.
    static var pullRequest: PullRequest {
        var pr = makePR()
        pr.mergeCommit = "merge"
        return pr
    }
}

/// A clock that tests move.
private final class TestClock: Sendable {
    private let date: Mutex<Date>

    init(_ date: Date) {
        self.date = Mutex(date)
    }

    var now: Date { date.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        date.withLock { $0 += seconds }
    }
}

/// Hands out tokens, but holds the requests whose calls it's told (each request asks for a token first), each until it's
/// released: two reads caught in the middle, in an order.
private actor GatedTokens: AccessTokenProvider {
    private let value: String
    private let held: Set<Int>
    private var calls = 0
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]

    init(_ value: String, holding held: Set<Int>) {
        self.value = value
        self.held = held
    }

    func token(tenant: String?) async throws -> AccessToken {
        calls += 1
        let call = calls
        if held.contains(call) {
            await withCheckedContinuation { gates[call] = $0 }
        }
        return AccessToken(value: value, expiresOn: .distantFuture)
    }

    func invalidate(tenant: String?) {}

    func isHolding(_ call: Int) -> Bool {
        gates[call] != nil
    }

    func release(_ call: Int) {
        gates.removeValue(forKey: call)?.resume()
    }

    /// Lets every request held go, for a test that's ending.
    func releaseAll() {
        for gate in gates.values { gate.resume() }
        gates = [:]
    }
}

@Suite struct BuildInvestigatorTests {
    private func query(_ request: URLRequest) -> [String: String] {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private func requests(_ server: StubServer, to path: String) -> [URLRequest] {
        server.requests.filter { $0.url?.path.hasSuffix(path) == true }
    }

    @Test func readsAFailedBuildWithAFewGETs() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        let investigation = try await BuildInvestigationReader.read(
            client: server.client(), buildId: FailedRun.id, of: FailedRun.pullRequest, now: t(0)
        )
        #expect(investigation.readAt == t(0))
        #expect(investigation.unread.isEmpty)
        #expect(investigation.pipeline.definitionId == 31)
        #expect(investigation.pipeline.name == "pipeline 31")
        #expect(investigation.pipeline.folder == "Shop")
        #expect(investigation.run.id == FailedRun.id)
        #expect(investigation.run.status == .failed)
        #expect(investigation.run.branch == "!7")
        #expect(investigation.run.webURL.absoluteString.hasSuffix("/contoso/Shop/_build/results?buildId=77"))

        // Its steps, where it failed and its errors.
        #expect(investigation.steps.map(\.name) == ["Build", "Test"])
        #expect(investigation.steps[1].steps.first?.steps.map(\.name) == ["Checkout", "Run tests", "Publish test results"])
        #expect(investigation.failure == PipelineFailure(stage: "Test", step: "Run tests", message: "2 tests failed in CartTests."))
        #expect(investigation.failedStep?.id == "run-tests")
        #expect(investigation.errors.map(\.message) == ["2 tests failed in CartTests."])
        #expect(investigation.errors.first?.logLine == 5)

        // The end of the failed step's log, without timestamps, colors or the ends of groups.
        let log = try #require(investigation.log)
        #expect(log.stepId == "run-tests")
        #expect(log.logId == 9)
        #expect(log.lineCount == 6)
        #expect(!log.isCut)
        #expect(log.lines.map(\.number) == [1, 2, 3, 5, 6])
        #expect(log.lines.map(\.kind) == [.section, .command, .plain, .error, .section])
        #expect(log.lines[2].text == "  Failed CartTests.AddsTax [3 ms]")
        let lines = try #require(requests(server, to: "/builds/77/logs/9").first)
        #expect(query(lines)["startLine"] == "1")
        #expect(query(lines)["endLine"] == "6")

        // Its tests: both runs added up, and the failures of the one that had them.
        let tests = try #require(investigation.tests)
        #expect(tests.total == 45)
        #expect(tests.passed == 43)
        #expect(tests.failed == 2)
        #expect(tests.runs == 2)
        #expect(tests.failures.map(\.name) == ["AddsTax", "RoundsTotal"])
        #expect(tests.failures.first?.message == "Expected 12, got 10")
        #expect(tests.failures.first?.run == "Unit")
        #expect(requests(server, to: "/Runs/502/results").isEmpty)
        let results = try #require(requests(server, to: "/Runs/501/results").first)
        #expect(query(results)["outcomes"] == "Failed,Error,Timeout,Aborted")
        #expect(query(results)["$top"] == "20")
        #expect(query(try #require(requests(server, to: "/_apis/test/runs").first))["includeRunDetails"] == "true")

        // Whether it's the change: it built the latest commit, passed on it before, and main fails too; a canceled run on
        // main says neither.
        #expect(investigation.comparison.revision == .current)
        #expect(investigation.comparison.earlierPass?.run.id == 70)
        #expect(investigation.comparison.earlierPass?.builtTheSame == true)
        #expect(investigation.comparison.targetRun?.id == 89)
        #expect(investigation.comparison.targetRun?.branch == "main")
        #expect(investigation.hints.map(\.sentence) == [
            "It passed on the same commit in 20261018.70: it may be flaky.", "main's latest run failed too: it may not be this change.",
        ])

        // The run, then five at once, then the log's end and one test run's failures: eight GETs.
        #expect(server.requests.count == 8)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func readsTheEndOfALongLog() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        server.on("/_apis/build/builds/77/logs", json: Fixture.list([["id": 9, "lineCount": 1_000]]))
        server.on("/_apis/build/builds/77/logs/9", json: FailedRun.lines((801...1_000).map { "2026-10-18T09:09:00.0000000Z line \($0)" }))
        let investigation = try await BuildInvestigationReader.read(client: server.client(), buildId: 77, of: FailedRun.pullRequest)
        let lines = try #require(requests(server, to: "/builds/77/logs/9").first)
        #expect(query(lines)["startLine"] == "801")
        #expect(query(lines)["endLine"] == "1000")
        let log = try #require(investigation.log)
        #expect(log.lines.count == BuildInvestigationReader.logLines)
        #expect(log.lines.first == BuildLogLine(number: 801, text: "line 801"))
        #expect(log.lines.last?.number == 1_000)
        #expect(log.isCut)
    }

    @Test func whatIsntThereIsMissingAndWhatFailsIsUnread() async throws {
        let server = StubServer()
        FailedRun.serve(server, replies: [
            "timeline": .status(404), "testRuns": .status(403), "earlier": .status(500), "target": .json(["value": "not a list"]),
        ])
        let investigation = try await BuildInvestigationReader.read(client: server.client(), buildId: 77, of: FailedRun.pullRequest)
        // No timeline, and no tests you may read: nothing to show, and nothing to read again.
        #expect(investigation.steps.isEmpty)
        #expect(investigation.failure == nil)
        #expect(investigation.failedStep == nil)
        #expect(investigation.errors.isEmpty)
        #expect(investigation.log == nil)
        #expect(investigation.tests == nil)
        #expect(requests(server, to: "/logs/9").isEmpty)
        // The rest couldn't be read.
        #expect(investigation.unread[.earlierRuns] == .http(500))
        #expect(investigation.unread[.targetBranch].map { if case .decoding = $0 { true } else { false } } == true)
        #expect(Set(investigation.unread.keys) == [.earlierRuns, .targetBranch])
        #expect(investigation.comparison.earlierPass == nil)
        #expect(investigation.comparison.targetRun == nil)
        #expect(investigation.comparison.revision == .current)

        let other = StubServer()
        FailedRun.serve(other, replies: ["logs": .status(500), "results": .status(503, headers: ["Retry-After": "1"])])
        let partial = try await BuildInvestigationReader.read(client: other.client(), buildId: 77, of: FailedRun.pullRequest)
        #expect(partial.log == nil)
        #expect(partial.unread[.log] == .http(500))
        // The tests are counted, though their failures couldn't be read.
        #expect(partial.tests?.failed == 2)
        #expect(partial.tests?.failures.isEmpty == true)
        #expect(partial.unread[.tests] == .throttled(retryAfter: 1))
        #expect(partial.steps.count == 2)
    }

    @Test func aLineThatIsntTextKeepsTheOthersNumbers() async throws {
        let server = StubServer()
        FailedRun.serve(server, replies: [
            "logs": .json(Fixture.list([["id": 9, "lineCount": 3]])),
            "lines": .json(["count": 3, "value": ["2026-10-18T09:09:00.0000000Z one", NSNull(), "2026-10-18T09:09:02.0000000Z three"]]),
        ])
        let log = try #require(try await BuildInvestigationReader.read(client: server.client(), buildId: 77, of: FailedRun.pullRequest).log)
        #expect(log.lines == [BuildLogLine(number: 1, text: "one"), BuildLogLine(number: 3, text: "three")])
        #expect(!log.isCut)
    }

    @Test func addsUpTestRunsAHundredARequest() async throws {
        /// Serves `count` test runs of two passed tests each, as pages of what's asked for, but fails the page `failing` skips to.
        func serveTestRuns(_ server: StubServer, count: Int, failing: Int? = nil) {
            server.on("/\(Fixture.org)/p1/_apis/test/runs") { request in
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let skip = Int(items.first { $0.name == "$skip" }?.value ?? "") ?? 0
                let top = Int(items.first { $0.name == "$top" }?.value ?? "") ?? 0
                if skip == failing { return .status(500) }
                let page = (skip..<min(count, skip + top)).map { ["id": 1_000 + $0, "totalTests": 2, "passedTests": 2] as [String: Any] }
                return .json(Fixture.list(page))
            }
        }
        let server = StubServer()
        FailedRun.serve(server)
        serveTestRuns(server, count: 250)
        let tests = try #require(try await BuildInvestigationReader.read(client: server.client(), buildId: 77, of: FailedRun.pullRequest).tests)
        #expect(tests.runs == 250)
        #expect(tests.total == 500)
        #expect(tests.isComplete)
        #expect(requests(server, to: "/_apis/test/runs").map { query($0)["$skip"] } == ["0", "100", "200"])

        let many = StubServer()
        FailedRun.serve(many)
        serveTestRuns(many, count: 750)
        let cut = try await BuildInvestigationReader.read(client: many.client(), buildId: 77, of: FailedRun.pullRequest)
        let partial = try #require(cut.tests)
        #expect(partial.runs == BuildInvestigationReader.testRunsCounted)
        #expect(!partial.isComplete)
        #expect(requests(many, to: "/_apis/test/runs").count == 5)
        // Those it doesn't add up weren't left unread: reading them again wouldn't add them.
        #expect(cut.unread[.tests] == nil)

        // A page after the first that can't be read keeps those before, and is read again next time.
        let failing = StubServer()
        FailedRun.serve(failing)
        serveTestRuns(failing, count: 250, failing: 200)
        let stopped = try await BuildInvestigationReader.read(client: failing.client(), buildId: 77, of: FailedRun.pullRequest)
        let some = try #require(stopped.tests)
        #expect(some.runs == 200)
        #expect(some.total == 400)
        #expect(!some.isComplete)
        #expect(stopped.unread[.tests] == .http(500))
        // When the first can't be read, there's nothing to keep.
        let none = StubServer()
        FailedRun.serve(none)
        serveTestRuns(none, count: 250, failing: 0)
        let unread = try await BuildInvestigationReader.read(client: none.client(), buildId: 77, of: FailedRun.pullRequest)
        #expect(unread.tests == nil)
        #expect(unread.unread[.tests] == .http(500))
    }

    @Test func readsTheFailuresOfATestRunThatDoesntCountThem() async throws {
        let server = StubServer()
        // Its failures were looked into, so none is unanalyzed, and it has no counts by outcome; the other run's are known.
        FailedRun.serve(server, replies: ["testRuns": .json(Fixture.list([
            ["id": 601, "name": "Analyzed", "totalTests": 10, "passedTests": 8, "unanalyzedTests": 0],
            ["id": 602, "name": "Known", "totalTests": 4, "passedTests": 3,
             "runStatistics": [["outcome": "Passed", "count": 3], ["outcome": "Failed", "count": 1]]],
        ]))])
        // One of them can't be read, but it came back, so it counts.
        server.on("/\(Fixture.org)/p1/_apis/test/Runs/601/results", json: Fixture.list([
            ["id": 1, "outcome": "Failed", "testCaseTitle": "AddsTax"], ["id": 2, "outcome": "Failed", "testCaseTitle": "RoundsTotal"],
            ["outcome": "Failed", "testCaseTitle": "Without an ID"],
        ]))
        server.on("/\(Fixture.org)/p1/_apis/test/Runs/602/results", json: Fixture.list([["id": 3, "outcome": "Failed", "testCaseTitle": "Ships"]]))
        let investigation = try await BuildInvestigationReader.read(client: server.client(), buildId: 77, of: FailedRun.pullRequest)
        let tests = try #require(investigation.tests)
        #expect(tests.failed == 4)
        #expect(tests.isComplete)
        // The test run whose failures are known comes first.
        #expect(tests.failures.map(\.name) == ["Ships", "AddsTax", "RoundsTotal"])
        // The one that can't be read is read again next time.
        #expect(investigation.unread[.tests].map { if case .decoding = $0 { true } else { false } } == true)

        // As many as a read lists, though one can't be read, are only some of them.
        let full = StubServer()
        FailedRun.serve(full, replies: ["testRuns": .json(Fixture.list([
            ["id": 601, "name": "Analyzed", "totalTests": 40, "passedTests": 10, "unanalyzedTests": 0],
        ]))])
        full.on("/\(Fixture.org)/p1/_apis/test/Runs/601/results", json: Fixture.list(
            (1..<BuildInvestigationReader.failedTestsListed).map { ["id": $0, "outcome": "Failed"] } + [["outcome": "Failed"]]
        ))
        let some = try #require(try await BuildInvestigationReader.read(client: full.client(), buildId: 77, of: FailedRun.pullRequest).tests)
        #expect(some.failed == BuildInvestigationReader.failedTestsListed)
        #expect(some.failures.count == BuildInvestigationReader.failedTestsListed - 1)
        #expect(!some.isComplete)

        // Failed results none of which can be read count, but list nothing, and are read again next time.
        let none = StubServer()
        FailedRun.serve(none, replies: ["results": .json(Fixture.list([["outcome": "Failed"], ["outcome": "Failed"]]))])
        let unreadable = try await BuildInvestigationReader.read(client: none.client(), buildId: 77, of: FailedRun.pullRequest)
        #expect(unreadable.tests?.failed == 2)
        #expect(unreadable.tests?.failures.isEmpty == true)
        #expect(unreadable.unread[.tests].map { if case .decoding = $0 { true } else { false } } == true)
        // And an investigation with something unread isn't kept.
        let investigator = BuildInvestigator(client: none.client())
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        #expect(await investigator.keptBuilds.isEmpty)
    }

    @Test func aTestRunThatCantBeReadLeavesTheTotalsPartialAndUnread() async throws {
        let server = StubServer()
        FailedRun.serve(server, replies: ["testRuns": .json(Fixture.list([
            ["id": 701, "name": "Unit", "totalTests": 3, "passedTests": 3], ["name": "Without an ID", "totalTests": 9, "passedTests": 9],
        ]))])
        let investigation = try await BuildInvestigationReader.read(client: server.client(), buildId: 77, of: FailedRun.pullRequest)
        let tests = try #require(investigation.tests)
        #expect(tests.runs == 1)
        #expect(tests.total == 3)
        #expect(!tests.isComplete)
        // The one that can't be read is read again next time.
        #expect(investigation.unread[.tests].map { if case .decoding = $0 { true } else { false } } == true)

        // So is one whose counts can't be read, though it's there.
        let counts = StubServer()
        FailedRun.serve(counts, replies: ["testRuns": .json(Fixture.list([
            ["id": 701, "name": "Unit", "totalTests": 3, "passedTests": 3], ["id": 702, "name": "Many", "totalTests": "many", "passedTests": 9],
        ]))])
        counts.on("/\(Fixture.org)/p1/_apis/test/Runs/702/results", json: Fixture.list([]))
        let uncounted = try await BuildInvestigationReader.read(client: counts.client(), buildId: 77, of: FailedRun.pullRequest)
        let partial = try #require(uncounted.tests)
        #expect(partial.runs == 2)
        #expect(partial.passed == 12)
        #expect(!partial.isComplete)
        #expect(uncounted.unread[.tests].map { if case .decoding = $0 { true } else { false } } == true)
        let investigator = BuildInvestigator(client: counts.client())
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        #expect(await investigator.keptBuilds.isEmpty)
    }

    @Test func whatCantBeReadIsntTakenForNone() async throws {
        // Test runs, none of which can be read, aren't no tests.
        let server = StubServer()
        FailedRun.serve(server, replies: ["testRuns": .json(Fixture.list([["name": "Without an ID"], ["name": "Nor this"]]))])
        let unreadable = try await BuildInvestigationReader.read(client: server.client(), buildId: 77, of: FailedRun.pullRequest)
        #expect(unreadable.tests == nil)
        #expect(unreadable.unread[.tests].map { if case .decoding = $0 { true } else { false } } == true)
        // Nor is a log missing from the run's logs, when some of them can't be read.
        let logs = StubServer()
        FailedRun.serve(logs, replies: ["logs": .json(Fixture.list([["id": 4, "lineCount": 12], ["lineCount": 6]]))])
        let unlisted = try await BuildInvestigationReader.read(client: logs.client(), buildId: 77, of: FailedRun.pullRequest)
        #expect(unlisted.log == nil)
        #expect(unlisted.unread[.log].map { if case .decoding = $0 { true } else { false } } == true)
        #expect(requests(logs, to: "/logs/9").isEmpty)
        // Nor one whose length can't be read.
        for log: [String: Any] in [["id": 9], ["id": 9, "lineCount": "many"], ["id": 9, "lineCount": -1]] {
            let lengths = StubServer()
            FailedRun.serve(lengths, replies: ["logs": .json(Fixture.list([log]))])
            let unmeasured = try await BuildInvestigationReader.read(client: lengths.client(), buildId: 77, of: FailedRun.pullRequest)
            #expect(unmeasured.log == nil)
            #expect(unmeasured.unread[.log].map { if case .decoding = $0 { true } else { false } } == true)
            #expect(requests(lengths, to: "/logs/9").isEmpty)
        }
    }

    @Test func stepsThatCantBeReadAreUnread() async throws {
        // None of its records can be read: no steps, and that's an error, not a run without any.
        let server = StubServer()
        FailedRun.serve(server, replies: ["timeline": .json(WorkFixture.timeline([["name": "Build"], ["type": "Task"]]))])
        let unreadable = try await BuildInvestigationReader.read(client: server.client(), buildId: 77, of: FailedRun.pullRequest)
        #expect(unreadable.steps.isEmpty)
        #expect(unreadable.unread[.steps].map { if case .decoding = $0 { true } else { false } } == true)
        // Some of them: the steps that could be read show, and the rest are read again next time.
        let some = StubServer()
        var records = (FailedRun.timeline["records"] as? [[String: Any]]) ?? []
        records.append(["name": "Without an ID"])
        FailedRun.serve(some, replies: ["timeline": .json(WorkFixture.timeline(records))])
        let partial = try await BuildInvestigationReader.read(client: some.client(), buildId: 77, of: FailedRun.pullRequest)
        #expect(partial.steps.map(\.name) == ["Build", "Test"])
        #expect(partial.unread[.steps] != nil)
    }

    @Test func runsThatCantAllBeReadSayNothingOfTheChange() async throws {
        // A run that can't be read may be main's latest, or the one that passed on the same commit: what the others say
        // could be wrong, so they say nothing, and they're read again next time.
        let server = StubServer()
        FailedRun.serve(server, replies: [
            "earlier": .json(Fixture.list([FailedRun.build(70, result: "succeeded", queued: t(-2 * hour)), ["id": 71]])),
            "target": .json(Fixture.list([["id": 91, "result": "succeeded"], FailedRun.build(89, result: "failed", branch: "refs/heads/main")])),
        ])
        let investigation = try await BuildInvestigationReader.read(client: server.client(), buildId: 77, of: FailedRun.pullRequest)
        #expect(investigation.comparison.earlierPass == nil)
        #expect(investigation.comparison.targetRun == nil)
        #expect(investigation.hints.isEmpty)
        #expect(Set(investigation.unread.keys) == [.earlierRuns, .targetBranch])
    }

    @Test func aRunWithoutALogOrTestsHasNone() async throws {
        let server = StubServer()
        FailedRun.serve(server, replies: [
            "logs": .json(Fixture.list([["id": 4, "lineCount": 12]])), "testRuns": .json(Fixture.list([])),
        ])
        let investigation = try await BuildInvestigationReader.read(client: server.client(), buildId: 77, of: FailedRun.pullRequest)
        #expect(investigation.log == nil)
        #expect(investigation.tests == nil)
        #expect(investigation.unread.isEmpty)
        #expect(requests(server, to: "/logs/9").isEmpty)

        let empty = StubServer()
        FailedRun.serve(empty, replies: ["logs": .json(Fixture.list([["id": 9, "lineCount": 0]]))])
        let emptyLog = try await BuildInvestigationReader.read(client: empty.client(), buildId: 77, of: FailedRun.pullRequest)
        #expect(emptyLog.log == BuildLog(stepId: "run-tests", logId: 9, lines: [], lineCount: 0))
        #expect(requests(empty, to: "/logs/9").isEmpty)
    }

    @Test func throwsWhenTheRunCantBeRead() async {
        let server = StubServer()
        FailedRun.serve(server, replies: ["build": .status(404)])
        await #expect(throws: ADOError.notFound) {
            try await BuildInvestigationReader.read(client: server.client(), buildId: 77, of: FailedRun.pullRequest)
        }
        #expect(server.requests.count == 1)
    }

    @Test func readsLogLinesAsAListOrAnArray() throws {
        #expect(try Fixture.decode(ADOLogLines.self, ["count": 4, "value": ["a", NSNull(), 3, "b"]]).lines == ["a", nil, nil, "b"])
        #expect(try Fixture.decode(ADOLogLines.self, ["a", "b"]).lines == ["a", "b"])
        #expect(throws: (any Error).self) { try Fixture.decode(ADOLogLines.self, ["count": 0]) }
        let logs = try Fixture.decode(ADOList<ADOBuildLog>.self, Fixture.list([["id": 1, "lineCount": "many"], ["lineCount": 3], ["id": 2]]))
        #expect(logs.value.map(\.id) == [1, 2])
        #expect(logs.value.map(\.lineCount) == [nil, nil])
    }

    @Test func endpointsAskForWhatTheInvestigationNeeds() {
        func items(_ url: URL) -> [String: String] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        }
        let target = ADOEndpoint.finishedBuilds(organization: "contoso", projectId: "p1", definitionId: 31, branch: "main", top: 5)
        #expect(target.path == "/contoso/p1/_apis/build/builds")
        #expect(items(target) == [
            "definitions": "31", "branchName": "refs/heads/main", "statusFilter": "completed", "queryOrder": "finishTimeDescending",
            "$top": "5", "api-version": "7.1",
        ])
        let release = ADOEndpoint.finishedBuilds(
            organization: "contoso", projectId: "p1", definitionId: 31, branch: "refs/heads/release/1.0", top: 5
        )
        #expect(items(release)["branchName"] == "refs/heads/release/1.0")
        let runs = ADOEndpoint.testRuns(organization: "contoso", projectId: "p1", buildId: 77)
        #expect(runs.absoluteString.contains("buildUri=vstfs%3A%2F%2F%2FBuild%2FBuild%2F77"))
        #expect(items(runs)["buildUri"] == "vstfs:///Build/Build/77")
        #expect(items(runs)["$skip"] == "0")
        #expect(items(runs)["$top"] == "100")
        #expect(items(ADOEndpoint.testRuns(organization: "contoso", projectId: "p1", buildId: 77, skip: 200, top: 100))["$skip"] == "200")
        let lines = ADOEndpoint.buildLogLines(organization: "contoso", projectId: "p1", buildId: 77, logId: 9, startLine: 1, endLine: 200)
        #expect(lines.path == "/contoso/p1/_apis/build/builds/77/logs/9")
        #expect(items(lines) == ["startLine": "1", "endLine": "200", "api-version": "7.1"])
        #expect(ADOEndpoint.buildLogs(organization: "contoso", projectId: "p1", buildId: 77).path == "/contoso/p1/_apis/build/builds/77/logs")
        let results = ADOEndpoint.testResults(organization: "contoso", projectId: "p1", runId: 501, outcomes: ["Failed", "Error"], top: 20)
        #expect(results.path == "/contoso/p1/_apis/test/Runs/501/results")
        #expect(items(results) == ["outcomes": "Failed,Error", "$top": "20", "api-version": "7.1"])
    }

    // MARK: Keeping

    @Test func keepsWhatItReadAndRevisesItForThePullRequest() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        let clock = TestClock(t(0))
        let investigator = BuildInvestigator(client: server.client(), now: { clock.now })
        let pr = FailedRun.pullRequest
        // Each read reads the run's timeline once; showing what's kept reads only the run.
        func reads() -> Int { requests(server, to: "/timeline").count }
        func runs() -> Int { requests(server, to: "/_apis/build/builds/77").count }
        let first = try await investigator.investigation(buildId: 77, of: pr)
        #expect(first.comparison.revision == .current)
        #expect(first.readAt == t(0))
        #expect(reads() == 1)
        #expect(runs() == 1)

        clock.advance(BuildInvestigator.keptFor - 1)
        #expect(try await investigator.investigation(buildId: 77, of: pr) == first)
        // In the organization, whatever its name's letter case.
        var upper = pr
        upper.key = PRKey("CONTOSO", pr.key.number)
        server.on("/CONTOSO/p1/_apis/build/builds/77", json: FailedRun.build())
        #expect(try await investigator.investigation(buildId: 77, of: upper) == first)
        #expect(reads() == 1)
        #expect(requests(server, to: "/CONTOSO/p1/_apis/build/builds/77").count == 1)
        // Pushed to since: it built an older commit, which the run it read says.
        var pushed = pr
        pushed.sourceCommit = "new"
        pushed.mergeCommit = "new-merge"
        #expect(try await investigator.investigation(buildId: 77, of: pushed).comparison.revision == .outdated)
        #expect(reads() == 1)
        #expect(runs() == 4)

        // Asked to, or once it's old, it's read again.
        #expect(try await investigator.investigation(buildId: 77, of: pr, refresh: true).readAt == t(BuildInvestigator.keptFor - 1))
        #expect(reads() == 2)
        clock.advance(BuildInvestigator.keptFor)
        _ = try await investigator.investigation(buildId: 77, of: pr)
        #expect(reads() == 3)
        // A pull request that targets another branch now is compared with that branch.
        var retargeted = pr
        retargeted.targetBranch = "release"
        #expect(try await investigator.investigation(buildId: 77, of: retargeted).comparison.targetBranch == "release")
        #expect(reads() == 4)
        #expect(requests(server, to: "/_apis/build/builds").contains { query($0)["branchName"] == "refs/heads/release" })
        // Someone else signed in: nothing's kept.
        await investigator.forget()
        #expect(await investigator.keptBuilds.isEmpty)
        _ = try await investigator.investigation(buildId: 77, of: retargeted)
        #expect(reads() == 5)
        #expect(server.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func aRunThatsRunAgainIsReadAgain() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        let investigator = BuildInvestigator(client: server.client())
        let pr = FailedRun.pullRequest
        func reads() -> Int { requests(server, to: "/timeline").count }
        /// The run as Azure DevOps says it now, and what's under it, which the run's route would answer for otherwise.
        func serveRun(_ build: [String: Any]) {
            server.on("/_apis/build/builds/77", json: build)
            server.on("/_apis/build/builds/77/timeline", json: FailedRun.timeline)
            server.on("/_apis/build/builds/77/logs", json: Fixture.list([["id": 9, "lineCount": FailedRun.logLines.count]]))
            server.on("/_apis/build/builds/77/logs/9", json: FailedRun.lines(FailedRun.logLines))
        }
        #expect(try await investigator.investigation(buildId: 77, of: pr).run.finishedAt == t(-hour + 330))
        // Its failed jobs ran again, under the same ID, and failed again: the run says so before what's kept shows.
        var again = FailedRun.build()
        again["finishTime"] = iso(t(-minute))
        serveRun(again)
        let rerun = try await investigator.investigation(buildId: 77, of: pr)
        #expect(rerun.run.finishedAt == t(-minute))
        #expect(reads() == 2)
        // When the run can't be read to tell, what's kept shows.
        server.on("/_apis/build/builds/77") { _ in .failure(.notConnectedToInternet) }
        #expect(try await investigator.investigation(buildId: 77, of: pr) == rerun)
        #expect(reads() == 2)
        // Run again, it's running.
        serveRun(FailedRun.build(status: "inProgress", result: nil))
        #expect(try await investigator.investigation(buildId: 77, of: pr).run.status == .running)
        #expect(reads() == 3)
    }

    @Test func aRunRunAgainThatCantAllBeReadLetsGoOfWhatsKept() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        let investigator = BuildInvestigator(client: server.client())
        let pr = FailedRun.pullRequest
        _ = try await investigator.investigation(buildId: 77, of: pr)
        #expect(await investigator.keptBuilds == [77])
        // Run again, it passed, but its steps can't be read now: that isn't kept, and the failure kept before goes.
        var passed = FailedRun.build(result: "succeeded")
        passed["finishTime"] = iso(t(-minute))
        server.on("/_apis/build/builds/77", json: passed)
        server.on("/_apis/build/builds/77/timeline") { _ in .status(500) }
        server.on("/_apis/build/builds/77/logs", json: Fixture.list([]))
        let rerun = try await investigator.investigation(buildId: 77, of: pr)
        #expect(rerun.run.status == .succeeded)
        #expect(rerun.unread[.steps] == .http(500))
        #expect(await investigator.keptBuilds.isEmpty)
        // So when the run can't be read, the failure doesn't show.
        server.on("/_apis/build/builds/77") { _ in .failure(.notConnectedToInternet) }
        await #expect(throws: ADOError.offline) { try await investigator.investigation(buildId: 77, of: pr) }

        // Read again when it's the same run, what couldn't be read leaves what's kept.
        let same = StubServer()
        FailedRun.serve(same)
        let keeping = BuildInvestigator(client: same.client())
        let first = try await keeping.investigation(buildId: 77, of: pr)
        same.on("/_apis/build/builds/77/timeline") { _ in .status(500) }
        #expect(try await keeping.investigation(buildId: 77, of: pr, refresh: true).unread[.steps] == .http(500))
        #expect(await keeping.keptBuilds == [77])
        #expect(try await keeping.investigation(buildId: 77, of: pr) == first)

        // Found run again by the look at it, though it can't be read again after: the failure kept before goes all the same,
        // and it says the run ran again, with why it can't be read; asked again, it knows nothing of the run to say so.
        let lost = StubServer()
        FailedRun.serve(lost)
        let losing = BuildInvestigator(client: lost.client())
        _ = try await losing.investigation(buildId: 77, of: pr)
        let runReads = Locked(0)
        let runAgain = StubServer.Reply.json(passed)
        // Only the run is asked for from here: each read stops when it can't be read.
        lost.on("/_apis/build/builds/77") { _ in runReads.increment() == 1 ? runAgain : .failure(.notConnectedToInternet) }
        await #expect(throws: BuildInvestigator.RunReplaced(error: .offline)) { try await losing.investigation(buildId: 77, of: pr) }
        #expect(await losing.keptBuilds.isEmpty)
        await #expect(throws: ADOError.offline) { try await losing.investigation(buildId: 77, of: pr) }
    }

    @Test func keepsARunningBuildBrieflyAndNotWhatCouldntBeRead() async throws {
        let server = StubServer()
        FailedRun.serve(server, build: FailedRun.build(status: "inProgress", result: nil))
        let clock = TestClock(t(0))
        let investigator = BuildInvestigator(client: server.client(), now: { clock.now })
        let running = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        #expect(running.run.status == .running)
        let reads = server.requests.count
        clock.advance(BuildInvestigator.keptWhileRunningFor - 1)
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        #expect(server.requests.count == reads)
        clock.advance(2)
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        #expect(server.requests.count == 2 * reads)

        let failing = StubServer()
        FailedRun.serve(failing, replies: ["target": .status(500)])
        let investigator2 = BuildInvestigator(client: failing.client(), now: { clock.now })
        #expect(try await investigator2.investigation(buildId: 77, of: FailedRun.pullRequest).unread[.targetBranch] == .http(500))
        let firstReads = failing.requests.count
        #expect(await investigator2.keptBuilds.isEmpty)
        _ = try await investigator2.investigation(buildId: 77, of: FailedRun.pullRequest)
        #expect(failing.requests.count == 2 * firstReads)
    }

    @Test func callersAtTheSameTimeShareARead() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        let tokens = HeldTokens(server.id, holdAt: 1)
        let investigator = BuildInvestigator(client: server.client(tokens: tokens))
        let one = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        try await waitUntilHeld(tokens)
        let two = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        let bothWait = (try? await waitUntil("both to wait for the read") { await investigator.waiting == 2 }) != nil
        await tokens.release()
        #expect(bothWait)
        let (first, second) = try await (one.value, two.value)
        #expect(first == second)
        #expect(requests(server, to: "/_apis/build/builds/77").count == 1)
        #expect(requests(server, to: "/timeline").count == 1)
        #expect(await investigator.waiting == 0)
    }

    @Test func callersAtTheSameTimeShareALookAtAKeptRun() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        // The first read's eight requests, then the look at the run it kept.
        let tokens = HeldTokens(server.id, holdAt: 9)
        let investigator = BuildInvestigator(client: server.client(tokens: tokens))
        let first = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        let one = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        let two = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        try await waitUntilHeld(tokens)
        let bothWait = (try? await waitUntil("both to wait for the look") { await investigator.waiting == 2 }) != nil
        await tokens.release()
        #expect(bothWait)
        #expect(try await one.value == first)
        #expect(try await two.value == first)
        #expect(requests(server, to: "/_apis/build/builds/77").count == 2)
        #expect(requests(server, to: "/timeline").count == 1)
    }

    @Test func aReadUnderWayIsWaitedForRatherThanLookingAtTheRun() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        // The first read's eight requests, then the second read's first.
        let tokens = HeldTokens(server.id, holdAt: 9)
        let clock = TestClock(t(0))
        let investigator = BuildInvestigator(client: server.client(tokens: tokens), now: { clock.now })
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        clock.advance(10)
        let refreshed = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest, refresh: true) }
        try await waitUntilHeld(tokens)
        let asked = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        let bothWait = (try? await waitUntil("both to wait for the read") { await investigator.waiting == 2 }) != nil
        await tokens.release()
        #expect(bothWait)
        #expect(try await asked.value.readAt == t(10))
        #expect(try await refreshed.value.readAt == t(10))
        // The run was read twice, by the two reads, and never only to look at it.
        #expect(requests(server, to: "/_apis/build/builds/77").count == 2)
    }

    @Test func aRefreshStartedWhileAKeptRunIsLookedAtIsWaitedFor() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        // The first read's eight requests; then the look at the run it kept, and the refresh's first request.
        let tokens = GatedTokens(server.id, holding: [9, 10])
        let clock = TestClock(t(0))
        let investigator = BuildInvestigator(client: server.client(tokens: tokens), now: { clock.now })
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        clock.advance(10)
        let looking = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        let held = (try? await waitUntil("the look at the run") { await tokens.isHolding(9) }) != nil
        let refreshing = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest, refresh: true) }
        let refreshHeld = (try? await waitUntil("the refresh") { await tokens.isHolding(10) }) != nil
        // The look ends while the refresh is under way: it waits for the refresh, rather than show what's kept.
        await tokens.release(9)
        let bothWait = (try? await waitUntil("both to wait for the refresh") { await investigator.waiting == 2 }) != nil
        await tokens.releaseAll()
        #expect(held && refreshHeld && bothWait)
        #expect(try await looking.value.readAt == t(10))
        #expect(try await refreshing.value.readAt == t(10))
    }

    @Test func aRunTheLookFindsRunAgainGoesThoughTheRefreshItWaitsForFails() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        // The first read's eight requests; then the look at the run it kept, and the refresh's first request.
        let tokens = GatedTokens(server.id, holding: [9, 10])
        let clock = TestClock(t(0))
        let investigator = BuildInvestigator(client: server.client(tokens: tokens), now: { clock.now })
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        clock.advance(10)
        // The look finds it run again; the refresh then can't read it. Only the run is asked for from here.
        var again = FailedRun.build(result: "succeeded")
        again["finishTime"] = iso(t(-minute))
        let runAgain = StubServer.Reply.json(again)
        let runReads = Locked(0)
        server.on("/_apis/build/builds/77") { _ in runReads.increment() == 1 ? runAgain : .failure(.notConnectedToInternet) }
        let looking = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        let held = (try? await waitUntil("the look at the run") { await tokens.isHolding(9) }) != nil
        let refreshing = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest, refresh: true) }
        let refreshHeld = (try? await waitUntil("the refresh") { await tokens.isHolding(10) }) != nil
        await tokens.release(9)
        // The failure kept goes as the look ends, though the refresh is waited for rather than what's kept shown.
        let gone = (try? await waitUntil("what's kept to go") { await investigator.keptBuilds.isEmpty }) != nil
        let bothWait = (try? await waitUntil("both to wait for the refresh") { await investigator.waiting == 2 }) != nil
        await tokens.releaseAll()
        #expect(held && refreshHeld && gone && bothWait)
        // The one that looked found the run ran again since what was kept: it says so, with why it couldn't be read.
        await #expect(throws: BuildInvestigator.RunReplaced(error: .offline)) { try await looking.value }
        await #expect(throws: ADOError.offline) { try await refreshing.value }
        // So, offline, it doesn't show.
        await #expect(throws: ADOError.offline) { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
    }

    @Test func whatAReadKeptWhileTheRunWasLookedAtIsLookedAtAgain() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        // The first read's eight requests; then the look at the run it kept.
        let tokens = GatedTokens(server.id, holding: [9])
        let clock = TestClock(t(0))
        let investigator = BuildInvestigator(client: server.client(tokens: tokens), now: { clock.now })
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        clock.advance(10)
        let looking = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        let held = (try? await waitUntil("the look at the run") { await tokens.isHolding(9) }) != nil
        // Run again, and read again meanwhile; the look, answered after, says the run as it was, as a server behind might.
        var again = FailedRun.build()
        again["finishTime"] = iso(t(-minute))
        let answers: [StubServer.Reply] = [.json(again), .json(FailedRun.build()), .json(again)]
        let runReads = Locked(0)
        server.on("/_apis/build/builds/77") { _ in answers[min(runReads.increment(), answers.count) - 1] }
        server.on("/_apis/build/builds/77/timeline", json: FailedRun.timeline)
        server.on("/_apis/build/builds/77/logs", json: Fixture.list([["id": 9, "lineCount": FailedRun.logLines.count]]))
        server.on("/_apis/build/builds/77/logs/9", json: FailedRun.lines(FailedRun.logLines))
        let refreshed = Locked<BuildInvestigation?>(nil)
        let refreshing = Task { refreshed.set(try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest, refresh: true)) }
        let refreshDone = (try? await waitUntil("the refresh") { refreshed.value != nil }) != nil
        await tokens.releaseAll()
        _ = try? await refreshing.value
        #expect(held && refreshDone)
        #expect(refreshed.value?.run.finishedAt == t(-minute))
        // What the refresh kept is looked at again, rather than compared with the earlier answer: it shows, not read again.
        #expect(try await looking.value == refreshed.value)
        #expect(await investigator.keptBuilds == [77])
        #expect(requests(server, to: "/timeline").count == 2)
        #expect(runReads.value == 3)
    }

    @Test func aLookStartedBeforeAReadIsntSharedWithWhoeverLooksAtIt() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        // The first read's eight requests; then the look at the run it kept.
        let tokens = GatedTokens(server.id, holding: [9])
        let clock = TestClock(t(0))
        let investigator = BuildInvestigator(client: server.client(tokens: tokens), now: { clock.now })
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        clock.advance(10)
        let looking = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        let held = (try? await waitUntil("the look at the run") { await tokens.isHolding(9) }) != nil
        // Run again, and read again meanwhile. The look under way, let go last, says the run as it was, as a server behind
        // might.
        var again = FailedRun.build()
        again["finishTime"] = iso(t(-minute))
        let (now, before) = (StubServer.Reply.json(again), StubServer.Reply.json(FailedRun.build()))
        let runReads = Locked(0)
        let stale = Locked(0)
        server.on("/_apis/build/builds/77") { _ in runReads.increment() == stale.value ? before : now }
        server.on("/_apis/build/builds/77/timeline", json: FailedRun.timeline)
        server.on("/_apis/build/builds/77/logs", json: Fixture.list([["id": 9, "lineCount": FailedRun.logLines.count]]))
        server.on("/_apis/build/builds/77/logs/9", json: FailedRun.lines(FailedRun.logLines))
        let refreshed = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest, refresh: true)
        // Asked for now, what the refresh kept gets a look of its own, rather than the look under way, which is older.
        let asked = Locked<BuildInvestigation?>(nil)
        let asking = Task { asked.set(try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)) }
        let lookedAlone = (try? await waitUntil("its own look") { asked.value != nil }) != nil
        stale.set(runReads.value + 1)
        await tokens.releaseAll()
        _ = try? await asking.value
        #expect(held && lookedAlone)
        #expect(asked.value == refreshed)
        // The look under way is of the read it kept first: what it says doesn't let go of the newer one.
        #expect(try await looking.value == refreshed)
        #expect(await investigator.keptBuilds == [77])
        #expect(requests(server, to: "/timeline").count == 2)
    }

    @Test func aKeptRunThatsGoneIsntShown() async throws {
        for (status, error) in [(404, ADOError.notFound), (403, ADOError.forbidden)] {
            let server = StubServer()
            FailedRun.serve(server)
            let investigator = BuildInvestigator(client: server.client())
            _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
            // Deleted, or no longer yours to read: what's kept goes, and reading the run again says why.
            server.on("/_apis/build/builds/77") { _ in .status(status) }
            await #expect(throws: error) { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
            #expect(await investigator.keptBuilds.isEmpty)
            #expect(requests(server, to: "/_apis/build/builds/77").count == 3)
        }
    }

    @Test func anOlderReadIsntKeptOverWhatANewerOneFound() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        // The first read's eight requests; then the refresh's run, and the five things it reads at the same time.
        let tokens = GatedTokens(server.id, holding: Set(10...14))
        let clock = TestClock(t(0))
        let investigator = BuildInvestigator(client: server.client(tokens: tokens), now: { clock.now })
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        clock.advance(10)
        // The refresh finds the run as it was. Then it's run again and passes, as a read for release finds, which can't
        // read release's runs. After that, the run can't be read.
        var passed = FailedRun.build(result: "succeeded")
        passed["finishTime"] = iso(t(-minute))
        let answers: [StubServer.Reply] = [.json(FailedRun.build()), .json(passed)]
        let runReads = Locked(0)
        server.on("/_apis/build/builds/77") { _ in
            let read = runReads.increment()
            return read <= answers.count ? answers[read - 1] : .failure(.notConnectedToInternet)
        }
        server.on("/_apis/build/builds/77/timeline", json: FailedRun.timeline)
        server.on("/_apis/build/builds/77/logs", json: Fixture.list([["id": 9, "lineCount": FailedRun.logLines.count]]))
        server.on("/_apis/build/builds/77/logs/9", json: FailedRun.lines(FailedRun.logLines))
        server.on("/_apis/build/builds", query: ["branchName": "refs/heads/release"]) { _ in .status(500) }
        let refreshing = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest, refresh: true) }
        let refreshHeld = (try? await waitUntil("the refresh's requests") {
            for call in 10...14 where !(await tokens.isHolding(call)) { return false }
            return true
        }) != nil
        var retargeted = FailedRun.pullRequest
        retargeted.targetBranch = "release"
        let newer = Locked<BuildInvestigation?>(nil)
        let reading = Task { newer.set(try await investigator.investigation(buildId: 77, of: retargeted)) }
        let newerDone = (try? await waitUntil("the read for release") { newer.value != nil }) != nil
        await tokens.releaseAll()
        _ = try? await reading.value
        #expect(refreshHeld && newerDone)
        #expect(newer.value?.run.status == .succeeded)
        #expect(newer.value?.unread[.targetBranch] == .http(500))
        // The refresh, though it could all be read and came back last, found the earlier attempt: it isn't kept.
        #expect(try await refreshing.value.run.status == .failed)
        #expect(await investigator.keptBuilds.isEmpty)
        // So when the run can't be read, the failure doesn't show.
        await #expect(throws: ADOError.offline) { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
    }

    @Test func aRefreshThatFindsTheRunGoneLetsGoOfWhatsKept() async throws {
        for (status, error) in [(404, ADOError.notFound), (403, ADOError.forbidden)] {
            for build in [FailedRun.build(), FailedRun.build(status: "inProgress", result: nil)] {
                let server = StubServer()
                FailedRun.serve(server, build: build)
                let investigator = BuildInvestigator(client: server.client())
                _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
                #expect(await investigator.keptBuilds == [77])
                server.on("/_apis/build/builds/77") { _ in .status(status) }
                await #expect(throws: error) {
                    try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest, refresh: true)
                }
                #expect(await investigator.keptBuilds.isEmpty)
                // Neither a run still going, kept a while without a look, nor one that finished, when it can't be looked at,
                // shows.
                server.on("/_apis/build/builds/77") { _ in .failure(.notConnectedToInternet) }
                await #expect(throws: ADOError.offline) { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
            }
        }
    }

    @Test func anOlderReadThatFindsTheRunGoneLeavesWhatANewerOneKept() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        // The first read's eight requests; then the refresh's first, for the run.
        let tokens = GatedTokens(server.id, holding: [9])
        let investigator = BuildInvestigator(client: server.client(tokens: tokens))
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        let refreshing = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest, refresh: true) }
        let held = (try? await waitUntil("the refresh") { await tokens.isHolding(9) }) != nil
        // A read for release, started after it, keeps what it finds.
        var retargeted = FailedRun.pullRequest
        retargeted.targetBranch = "release"
        let newer = Locked<BuildInvestigation?>(nil)
        let reading = Task { newer.set(try await investigator.investigation(buildId: 77, of: retargeted)) }
        let newerDone = (try? await waitUntil("the read for release") { newer.value != nil }) != nil
        // Then the refresh, which started before it, finds the run gone: that's older than what the read for release kept.
        server.on("/_apis/build/builds/77") { _ in .status(404) }
        await tokens.releaseAll()
        _ = try? await reading.value
        #expect(held && newerDone)
        await #expect(throws: ADOError.notFound) { try await refreshing.value }
        #expect(await investigator.keptBuilds == [77])
    }

    @Test func readsForEachTargetBranchAreSharedApart() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        let tokens = GatedTokens(server.id, holding: [1])
        let investigator = BuildInvestigator(client: server.client(tokens: tokens))
        let toMain = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        let held = (try? await waitUntil("the read for main") { await tokens.isHolding(1) }) != nil
        var retargeted = FailedRun.pullRequest
        retargeted.targetBranch = "release"
        let reading = Task { try await investigator.investigation(buildId: 77, of: retargeted) }
        let readAlone = (try? await waitUntil("the read for release") { requests(server, to: "/timeline").count == 1 }) != nil
        // Were it waiting for the held read for main instead, that's let go, so the test fails rather than waits for ever.
        if !readAlone { await tokens.releaseAll() }
        // Another caller comparing it with main, once the read for release is done, shares the read for main.
        _ = try? await reading.value
        let alsoToMain = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        let bothWait = (try? await waitUntil("both to wait for the read for main") { await investigator.waiting == 2 }) != nil
        await tokens.releaseAll()
        #expect(held && readAlone && bothWait)
        #expect(try await toMain.value == alsoToMain.value)
        #expect(try await reading.value.comparison.targetBranch == "release")
        #expect(requests(server, to: "/timeline").count == 2)
    }

    @Test func aReadForAnotherTargetBranchIsntShared() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        let tokens = HeldTokens(server.id, holdAt: 1)
        let investigator = BuildInvestigator(client: server.client(tokens: tokens))
        let toMain = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        try await waitUntilHeld(tokens)
        // Retargeted while that's read: compared with its new target, in a read of its own, which doesn't wait for the other.
        var retargeted = FailedRun.pullRequest
        retargeted.targetBranch = "release"
        let toReleaseBranch = retargeted
        let reading = Task { try await investigator.investigation(buildId: 77, of: toReleaseBranch) }
        let readAlone = (try? await waitUntil("its own read") { requests(server, to: "/timeline").count == 1 }) != nil
        // It comes back first; then the read for main, which started before it.
        if readAlone { _ = try? await reading.value }
        await tokens.release()
        #expect(readAlone)
        let toRelease = try await reading.value
        #expect(toRelease.comparison.targetBranch == "release")
        #expect(toRelease.comparison.targetRun == nil)
        #expect(try await toMain.value.comparison.targetRun?.id == 89)
        #expect(requests(server, to: "/timeline").count == 2)
        // What the read for release found is kept, rather than what the read for main, which started before it, found.
        #expect(try await investigator.investigation(buildId: 77, of: toReleaseBranch) == toRelease)
        #expect(requests(server, to: "/timeline").count == 2)
    }

    /// Forgetting while a caller looks at a kept run, as someone else signs in, calls the caller off: what it asked for as
    /// the last one isn't read as them. Whoever asks next reads the run anew.
    @Test func forgettingWhileItChecksAKeptRunCallsItOff() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        // The first read's eight requests, then the check of the run it kept.
        let tokens = HeldTokens(server.id, holdAt: 9)
        let clock = TestClock(t(0))
        let investigator = BuildInvestigator(client: server.client(tokens: tokens), now: { clock.now })
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        #expect(server.requests.count == 8)
        clock.advance(10)
        let again = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        try await waitUntilHeld(tokens)
        await investigator.forget()
        await tokens.release()
        await #expect(throws: CancellationError.self) { try await again.value }
        #expect(requests(server, to: "/timeline").count == 1)
        #expect(await investigator.keptBuilds.isEmpty)
        #expect(try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest).readAt == t(10))
        #expect(requests(server, to: "/timeline").count == 2)
        #expect(await investigator.keptBuilds == [77])
    }

    /// A read under way as it forgets, as someone else signs in, was asked for as the last one: it's called off, reads
    /// nothing more, and isn't kept; whoever asks next reads the run anew.
    @Test func aReadUnderWayWhenItForgetsIsCalledOff() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        let tokens = HeldTokens(server.id, holdAt: 1)
        let investigator = BuildInvestigator(client: server.client(tokens: tokens))
        let read = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        try await waitUntilHeld(tokens)
        await investigator.forget()
        await tokens.release()
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(requests(server, to: "/timeline").isEmpty)
        #expect(requests(server, to: "/logs").isEmpty)
        #expect(await investigator.keptBuilds.isEmpty)
        #expect(try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest).run.id == 77)
        #expect(requests(server, to: "/timeline").count == 1)
    }

    /// A read whose only caller is called off, as when the details close or show another pull request, is called off too:
    /// it reads nothing more, and whoever asks next reads the run anew.
    @Test(.timeLimit(.minutes(1)))
    func aReadNobodyWaitsForIsCalledOff() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        // The first request, for the run, held.
        let tokens = HeldTokens(server.id, holdAt: 1)
        let investigator = BuildInvestigator(client: server.client(tokens: tokens))
        let read = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        try await waitUntilHeld(tokens)
        #expect(await investigator.asking == 1)
        read.cancel()
        try await waitUntil("the read to be given up") { await investigator.asking == 0 }
        await tokens.release()
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(requests(server, to: "/timeline").isEmpty)
        #expect(requests(server, to: "/logs").isEmpty)
        #expect(await investigator.keptBuilds.isEmpty)
        #expect(try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest).run.id == 77)
        #expect(requests(server, to: "/timeline").count == 1)
        #expect(await investigator.keptBuilds == [77])
    }

    /// A read two callers wait for goes on when one of them is called off: the other gets it, and it's kept.
    @Test(.timeLimit(.minutes(1)))
    func aReadAnotherCallerWaitsForGoesOn() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        let tokens = HeldTokens(server.id, holdAt: 1)
        let investigator = BuildInvestigator(client: server.client(tokens: tokens))
        let one = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        try await waitUntilHeld(tokens)
        let two = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        try await waitUntil("both to wait for the read") { await investigator.asking == 2 }
        one.cancel()
        try await waitUntil("one to stop waiting") { await investigator.asking == 1 }
        await tokens.release()
        await #expect(throws: CancellationError.self) { try await one.value }
        #expect(try await two.value.run.id == 77)
        #expect(requests(server, to: "/timeline").count == 1)
        #expect(await investigator.keptBuilds == [77])
        #expect(await investigator.asking == 0)
    }

    /// A caller called off while it looks at a kept run, one GET, starts no read of it, though the look finds it ran again.
    @Test(.timeLimit(.minutes(1)))
    func aCallerCalledOffWhileItLooksAtAKeptRunReadsNothingInstead() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        // The first read's eight requests, then the look at the run it kept.
        let tokens = HeldTokens(server.id, holdAt: 9)
        let clock = TestClock(t(0))
        let investigator = BuildInvestigator(client: server.client(tokens: tokens), now: { clock.now })
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        clock.advance(10)
        // It ran again since, as the look finds.
        var again = FailedRun.build()
        again["finishTime"] = iso(t(-minute))
        server.on("/_apis/build/builds/77", json: again)
        let looking = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        try await waitUntilHeld(tokens)
        looking.cancel()
        await tokens.release()
        await #expect(throws: CancellationError.self) { try await looking.value }
        #expect(requests(server, to: "/timeline").count == 1)
    }

    /// A look at a kept run that hasn't run again, whose only caller is called off, as when the details close, is called off
    /// too: the caller comes back at once, with nothing rather than what's kept, which stays, though the look's answer
    /// hasn't come.
    @Test(.timeLimit(.minutes(1)))
    func aLookNobodyWaitsForIsCalledOff() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        let clock = TestClock(t(0))
        let investigator = BuildInvestigator(client: server.client(), now: { clock.now })
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        clock.advance(10)
        // The look at the run it kept, unchanged: answered only once it's let go, as a slow answer.
        let letGo = Mutex(false)
        server.on("/_apis/build/builds/77") { _ in
            var reply = StubServer.Reply.json(FailedRun.build())
            reply.waitsFor = { letGo.withLock { $0 } }
            return reply
        }
        let cameBack = Mutex(false)
        let looking = Task {
            defer { cameBack.withLock { $0 = true } }
            return try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        }
        try await waitUntil("the look to start") { await investigator.waiting == 1 }
        looking.cancel()
        // Without waiting for the look's answer, which hasn't come.
        try await waitUntil("the caller to come back", timeout: .seconds(10)) { cameBack.withLock { $0 } }
        await #expect(throws: CancellationError.self) { try await looking.value }
        #expect(await investigator.asking == 0)
        letGo.withLock { $0 = true }
        #expect(requests(server, to: "/timeline").count == 1)
        #expect(await investigator.keptBuilds == [77])
    }

    /// A look two callers share goes on when one of them is called off: the other gets what's kept, as the look finds the
    /// run hasn't run again, with one GET.
    @Test(.timeLimit(.minutes(1)))
    func aLookAnotherCallerWaitsForGoesOn() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        let clock = TestClock(t(0))
        let investigator = BuildInvestigator(client: server.client(), now: { clock.now })
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        let runGETs = requests(server, to: "/_apis/build/builds/77").count
        clock.advance(10)
        let letGo = Mutex(false)
        server.on("/_apis/build/builds/77") { _ in
            var reply = StubServer.Reply.json(FailedRun.build())
            reply.waitsFor = { letGo.withLock { $0 } }
            return reply
        }
        let one = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        try await waitUntil("one to look") { await investigator.waiting == 1 }
        let two = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        try await waitUntil("both to wait for the look") { await investigator.waiting == 2 }
        one.cancel()
        try await waitUntil("one to stop waiting") { await investigator.asking == 1 }
        letGo.withLock { $0 = true }
        await #expect(throws: CancellationError.self) { try await one.value }
        #expect(try await two.value.run.id == 77)
        #expect(requests(server, to: "/_apis/build/builds/77").count == runGETs + 1)
        #expect(requests(server, to: "/timeline").count == 1)
        #expect(await investigator.asking == 0)
    }

    @Test func stoppingStopsAReadUnderWayAndReadsNothingMore() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        // The first request, for the run, held.
        let tokens = HeldTokens(server.id, holdAt: 1)
        let investigator = BuildInvestigator(client: server.client(tokens: tokens))
        let read = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        try await waitUntilHeld(tokens)
        // Azure DevOps is turned off: the read stops, rather than go on to the run's timeline, logs and tests.
        await investigator.stop()
        await tokens.release()
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(requests(server, to: "/timeline").isEmpty)
        #expect(requests(server, to: "/logs").isEmpty)
        #expect(await investigator.keptBuilds.isEmpty)
        // And nothing is read any more.
        await #expect(throws: CancellationError.self) { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        #expect(requests(server, to: "/timeline").isEmpty)
    }

    @Test func stoppingAfterForgettingStillStopsTheReadUnderWay() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        let tokens = HeldTokens(server.id, holdAt: 1)
        let investigator = BuildInvestigator(client: server.client(tokens: tokens))
        let read = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        try await waitUntilHeld(tokens)
        // Someone else signed in, then Azure DevOps is turned off: the read it forgot stops all the same.
        await investigator.forget()
        await investigator.stop()
        await tokens.release()
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(requests(server, to: "/timeline").isEmpty)
        #expect(requests(server, to: "/logs").isEmpty)
    }

    @Test func aRunKeptBeforeItGotAsFarAsItsCheckSaysIsReadAgain() async throws {
        let server = StubServer()
        FailedRun.serve(server, build: FailedRun.build(status: "notStarted", result: nil))
        let clock = TestClock(t(0))
        let investigator = BuildInvestigator(client: server.client(), now: { clock.now })
        #expect(try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest).run.status == .queued)
        clock.advance(BuildInvestigator.keptWhileRunningFor - 1)
        // Still in the queue, as its check says, or its check doesn't say: what's kept answers.
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest, phase: .queued)
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        #expect(requests(server, to: "/timeline").count == 1)
        // It started, as its check says: what was kept while it waited isn't it any more.
        FailedRun.serve(server, build: FailedRun.build(status: "inProgress", result: nil))
        #expect(try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest, phase: .running).run.status == .running)
        #expect(requests(server, to: "/timeline").count == 2)
        // It finished, as its check says: nor is what was kept while it was going.
        FailedRun.serve(server)
        #expect(try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest, phase: .finished).run.status == .failed)
        #expect(requests(server, to: "/timeline").count == 3)
        // A run kept once it finished answers as it did, after a look at the run, even if its check is behind.
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest, phase: .running)
        #expect(requests(server, to: "/timeline").count == 3)
    }

    @Test func aReadItWaitsForThatsBehindItsCheckIsReadAgainOnce() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        // The run's first read says it's still going; the next, that it failed.
        let (going, failed) = (StubServer.Reply.json(FailedRun.build(status: "inProgress", result: nil)), StubServer.Reply.json(FailedRun.build()))
        let runReads = Locked(0)
        server.on("/_apis/build/builds/77") { _ in runReads.increment() == 1 ? going : failed }
        // What's under the run, which its route would answer for otherwise.
        server.on("/_apis/build/builds/77/timeline", json: FailedRun.timeline)
        server.on("/_apis/build/builds/77/logs", json: Fixture.list([["id": 9, "lineCount": FailedRun.logLines.count]]))
        server.on("/_apis/build/builds/77/logs/9", json: FailedRun.lines(FailedRun.logLines))
        let tokens = HeldTokens(server.id, holdAt: 1)
        let investigator = BuildInvestigator(client: server.client(tokens: tokens))
        let first = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest, phase: .running) }
        try await waitUntilHeld(tokens)
        // Reopened as its check says it failed, before the first read is done: it waits for that read, then reads again.
        let reopened = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest, phase: .finished) }
        let bothWait = (try? await waitUntil("both to wait for the read") { await investigator.waiting == 2 }) != nil
        await tokens.release()
        #expect(bothWait)
        #expect(try await first.value.run.status == .running)
        #expect(try await reopened.value.run.status == .failed)
        #expect(requests(server, to: "/timeline").count == 2)
        #expect(runReads.value == 2)
    }

    @Test func aReadThatHadReadTheRunWhenItWasAskedForIsCheckedWithALook() async throws {
        for readAgainFails in [false, true] {
            let server = StubServer()
            FailedRun.serve(server)
            // The read's first request, for the run, is answered; the next waits.
            let tokens = HeldTokens(server.id, holdAt: 2)
            let investigator = BuildInvestigator(client: server.client(tokens: tokens))
            let first = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
            try await waitUntilHeld(tokens)
            // Meanwhile its failed jobs ran again and failed again, and its details opened again, as their check says.
            var again = FailedRun.build()
            again["finishTime"] = iso(t(-minute))
            let (ranAgain, offline) = (StubServer.Reply.json(again), StubServer.Reply.failure(.notConnectedToInternet))
            let answers = readAgainFails ? [ranAgain, offline] : [ranAgain, ranAgain]
            let runReads = Locked(0)
            server.on("/_apis/build/builds/77") { _ in answers[min(runReads.increment(), answers.count) - 1] }
            // What's under the run, which its route would answer for otherwise.
            server.on("/_apis/build/builds/77/timeline", json: FailedRun.timeline)
            server.on("/_apis/build/builds/77/logs", json: Fixture.list([["id": 9, "lineCount": FailedRun.logLines.count]]))
            server.on("/_apis/build/builds/77/logs/9", json: FailedRun.lines(FailedRun.logLines))
            let reopened = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest, phase: .finished) }
            let bothWait = (try? await waitUntil("both to wait for the read") { await investigator.waiting == 2 }) != nil
            await tokens.release()
            #expect(bothWait)
            // Who asked for the read gets the run as it read it.
            #expect(try await first.value.run.finishedAt == t(-hour + 330))
            // Who asked for it after it had read the run waits for it, then looks at the run, which ran again since: it's
            // read again, or says so when it can't be.
            if readAgainFails {
                await #expect(throws: BuildInvestigator.RunReplaced(error: .offline)) { try await reopened.value }
                #expect(await investigator.keptBuilds.isEmpty)
            } else {
                #expect(try await reopened.value.run.finishedAt == t(-minute))
                #expect(requests(server, to: "/timeline").count == 2)
            }
            #expect(runReads.value == 2)
        }
    }

    @Test func stoppingWhileItLooksAtTheRunAJoinedReadFoundStopsIt() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        // The read's first request, for the run, is answered and its next waits; after its eight, the look at the run.
        let tokens = GatedTokens(server.id, holding: [2, 9])
        let investigator = BuildInvestigator(client: server.client(tokens: tokens))
        let first = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        let held = (try? await waitUntil("the read") { await tokens.isHolding(2) }) != nil
        let joined = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        let bothWait = (try? await waitUntil("both to wait for the read") { await investigator.waiting == 2 }) != nil
        await tokens.release(2)
        let looking = (try? await waitUntil("the look at the run") { await tokens.isHolding(9) }) != nil
        #expect(try await first.value.run.status == .failed)
        // Azure DevOps is turned off while the one that joined the read looks at the run: it says so, rather than answer.
        await investigator.stop()
        await tokens.releaseAll()
        #expect(held && bothWait && looking)
        await #expect(throws: CancellationError.self) { try await joined.value }
    }

    @Test func stoppingWhileItLooksAtAKeptRunReadsNothingInstead() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        // The first read's eight requests, then the look at the run it kept.
        let tokens = HeldTokens(server.id, holdAt: 9)
        let clock = TestClock(t(0))
        let investigator = BuildInvestigator(client: server.client(tokens: tokens), now: { clock.now })
        _ = try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest)
        clock.advance(10)
        let looking = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        try await waitUntilHeld(tokens)
        await investigator.stop()
        await tokens.release()
        await #expect(throws: CancellationError.self) { try await looking.value }
        // Nothing is read instead.
        #expect(requests(server, to: "/timeline").count == 1)
        #expect(await investigator.keptBuilds.isEmpty)
    }

    @Test func keepsTheLatestReadsUpToItsCapacity() async throws {
        let server = StubServer()
        let count = BuildInvestigator.capacity + 1
        // Only the runs are there: the rest is missing, which is no reason not to keep them.
        server.on("/\(Fixture.org)/p1/_apis/build/builds/") { request in
            guard let id = request.url.flatMap({ Int($0.lastPathComponent) }), (1...count).contains(id) else { return .status(404) }
            return .json(FailedRun.build(id))
        }
        let clock = TestClock(t(0))
        let investigator = BuildInvestigator(client: server.client(), now: { clock.now })
        for id in 1...count {
            #expect(try await investigator.investigation(buildId: id, of: FailedRun.pullRequest).unread.isEmpty)
            clock.advance(1)
        }
        #expect(await investigator.keptBuilds == Set(2...count))
    }

    // MARK: The demo

    @Test func theDemoInvestigatesItsFailedBuilds() throws {
        let now = t(0)
        let records = DemoData.records(now: now)
        let failing = try #require(records.first { $0.id.number == 4088 })
        let check = try #require(failing.details?.checks.first { $0.kind == .build && $0.state == .failed })
        let buildId = try #require(check.buildId)
        let investigation = try #require(DemoData.buildInvestigation(buildId: buildId, of: failing.pullRequest, now: now))
        // As the pull request's check says, and as the Pipelines page shows shop-web CI.
        #expect(investigation.failure == check.failure)
        #expect(investigation.failedStep?.name == check.failure?.step)
        #expect(investigation.errors.first?.message == check.failure?.message)
        let shopWeb = try #require(DemoData.pipelines(now: now).first { $0.pipeline.name == "shop-web CI" })
        #expect(investigation.pipeline == shopWeb.pipeline)
        #expect(investigation.steps.map(\.name) == shopWeb.stages.map(\.name))
        #expect(investigation.steps.map(\.state) == shopWeb.stages.map(\.state))
        #expect(investigation.run.id == buildId)
        #expect(investigation.run.finishedAt == check.completedAt)
        #expect(investigation.comparison.targetRun == shopWeb.latest)
        #expect(investigation.hints.map(\.sentence) == ["main's latest run failed too: it may not be this change."])
        // Its log ends with its errors, and its tests are the ones that failed.
        let log = try #require(investigation.log)
        #expect(log.stepId == investigation.failedStepId)
        #expect(log.lines.filter { $0.kind == .error }.map(\.text) == investigation.errors.map(\.message))
        for error in investigation.errors {
            #expect(log.lines.first { $0.number == error.logLine }?.text == error.message)
        }
        #expect(investigation.tests?.failed == investigation.tests?.failures.count)
        #expect(investigation.allSteps.filter { $0.state == .failed }.map(\.name) == ["Test", "Unit tests", "Run unit tests"])
        #expect(investigation.allSteps.compactMap(\.logId).count == Set(investigation.allSteps.compactMap(\.logId)).count)
        #expect(investigation.unread.isEmpty)

        // The runs the Pipelines page shows for your pull requests that failed, as the app lists them, the newest first:
        // each built the latest commit, or not, as the page says.
        let authored = records.filter { $0.role == .author && $0.pullRequest.status == .active }.map(\.pullRequest)
            .sorted { ($0.createdAt, $0.key) > ($1.createdAt, $1.key) }
        var revisions: [PullRequestPipelines.Revision] = []
        for card in DemoData.pullRequestPipelines(authored, now: now) {
            for status in card.pipelines {
                guard let run = status.latest, run.status == .failed else { continue }
                let investigation = try #require(DemoData.buildInvestigation(buildId: run.id, of: card.pullRequest, now: now))
                #expect(investigation.run == run)
                #expect(investigation.comparison.revision == card.revision(of: status))
                #expect(investigation.hints.contains(.olderCommit) == (card.revision(of: status) == .outdated))
                revisions.append(investigation.comparison.revision)
            }
        }
        #expect(revisions.contains(.current))
        #expect(revisions.contains(.outdated))
        // Nothing for another build, a run the Pipelines page doesn't show as failed, or another organization's.
        #expect(DemoData.buildInvestigation(buildId: 1, of: failing.pullRequest, now: now) == nil)
        let cardless = try #require(authored.dropFirst(3).first)
        #expect(DemoData.buildInvestigation(buildId: cardless.key.number * 1_000 + 31, of: cardless, now: now) == nil)
        let carded = try #require(authored.first)
        #expect(DemoData.buildInvestigation(buildId: carded.key.number * 1_000 + 32, of: carded, now: now) == nil)
        #expect(DemoData.buildInvestigation(buildId: buildId, of: records[0].pullRequest, now: now) == nil)
        var elsewhere = failing.pullRequest
        elsewhere.key = PRKey("fabrikam", 4088)
        #expect(DemoData.buildInvestigation(buildId: buildId, of: elsewhere, now: now) == nil)
    }
}
