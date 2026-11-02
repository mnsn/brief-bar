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

    @Test func aRunWithoutALogOrTestsHasNone() async throws {
        let server = StubServer()
        FailedRun.serve(server, replies: [
            "logs": .json(Fixture.list([["id": 4, "lineCount": 12], ["id": 9]])), "testRuns": .json(Fixture.list([])),
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
        #expect(try Fixture.decode(ADOLogLines.self, ["count": 3, "value": ["a", NSNull(), "b"]]).lines == ["a", "b"])
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
        #expect(try await investigator.investigation(buildId: 77, of: upper) == first)
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
        let reading = Task { try await investigator.investigation(buildId: 77, of: retargeted) }
        let readAlone = (try? await waitUntil("its own read") { requests(server, to: "/timeline").count == 1 }) != nil
        await tokens.release()
        #expect(readAlone)
        let toRelease = try await reading.value
        #expect(toRelease.comparison.targetBranch == "release")
        #expect(toRelease.comparison.targetRun == nil)
        #expect(try await toMain.value.comparison.targetRun?.id == 89)
        #expect(requests(server, to: "/timeline").count == 2)
    }

    @Test func forgettingWhileItChecksAKeptRunReadsItAgain() async throws {
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
        // Someone else signed in: what was read before isn't shown, and what's read now, as them, is.
        await investigator.forget()
        await tokens.release()
        #expect(try await again.value.readAt == t(10))
        #expect(requests(server, to: "/timeline").count == 2)
        #expect(await investigator.keptBuilds == [77])
    }

    @Test func aReadUnderWayWhenItForgetsIsntKept() async throws {
        let server = StubServer()
        FailedRun.serve(server)
        let tokens = HeldTokens(server.id, holdAt: 1)
        let investigator = BuildInvestigator(client: server.client(tokens: tokens))
        let read = Task { try await investigator.investigation(buildId: 77, of: FailedRun.pullRequest) }
        try await waitUntilHeld(tokens)
        await investigator.forget()
        await tokens.release()
        #expect(try await read.value.run.id == 77)
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
        // Nothing for another build, or another organization's.
        #expect(DemoData.buildInvestigation(buildId: 1, of: failing.pullRequest, now: now) == nil)
        #expect(DemoData.buildInvestigation(buildId: buildId, of: records[0].pullRequest, now: now) == nil)
        var elsewhere = failing.pullRequest
        elsewhere.key = PRKey("fabrikam", 4088)
        #expect(DemoData.buildInvestigation(buildId: buildId, of: elsewhere, now: now) == nil)
    }
}
