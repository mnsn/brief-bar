import Foundation
import Synchronization

// MARK: - Azure DevOps' shapes

/// One of a run's logs, from `{project}/_apis/build/builds/{id}/logs`.
public struct ADOBuildLog: Decodable, Sendable {
    public var id: Int
    public var lineCount: Int?

    private enum CodingKeys: String, CodingKey { case id, lineCount }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        lineCount = container.lenient(Int.self, forKey: .lineCount)
    }
}

/// A log's lines, from `{project}/_apis/build/builds/{id}/logs/{logId}` asked for as JSON: `{"count": 2, "value": ["…",
/// "…"]}`, or the bare array. Each still has its timestamp. A line that isn't a string is nil, in its place, so the lines
/// after it keep their numbers.
struct ADOLogLines: Decodable, Sendable {
    var lines: [String?]

    private enum CodingKeys: String, CodingKey { case value }

    /// Consumes one element of any shape, to step over one that isn't a string.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var items: UnkeyedDecodingContainer
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            items = try container.nestedUnkeyedContainer(forKey: .value)
        } else {
            items = try decoder.unkeyedContainer()
        }
        var lines: [String?] = []
        while !items.isAtEnd {
            if let line = try? items.decode(String.self) {
                lines.append(line)
            } else {
                _ = try items.decode(Skip.self)
                lines.append(nil)
            }
        }
        self.lines = lines
    }
}

/// A test run that a pipeline's run published, from `{project}/_apis/test/runs?buildUri=…&includeRunDetails=true`.
public struct ADOTestRun: Decodable, Sendable {
    public var id: Int
    public var name: String?
    public var totalTests: Int?
    public var passedTests: Int?
    /// The failed tests nobody has looked into: every failed one, for a pipeline's run.
    public var unanalyzedTests: Int?
    /// How many tests had each outcome.
    public var runStatistics: LenientArray<Statistic>?
    /// One of its counts is there but isn't a number, so its totals can't be told. One that isn't there is none.
    public var hasUnreadableCounts: Bool

    public struct Statistic: Decodable, Sendable {
        /// `Passed`, `Failed`, `NotExecuted`…
        public var outcome: String?
        public var count: Int?

        private enum CodingKeys: String, CodingKey { case outcome, count }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            outcome = container.lenient(String.self, forKey: .outcome)
            count = container.lenient(Int.self, forKey: .count)
        }
    }

    private enum CodingKeys: String, CodingKey { case id, name, totalTests, passedTests, unanalyzedTests, runStatistics }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = container.lenient(String.self, forKey: .name)
        totalTests = container.lenient(Int.self, forKey: .totalTests)
        passedTests = container.lenient(Int.self, forKey: .passedTests)
        unanalyzedTests = container.lenient(Int.self, forKey: .unanalyzedTests)
        runStatistics = container.lenient(LenientArray<Statistic>.self, forKey: .runStatistics)
        hasUnreadableCounts = [CodingKeys.totalTests, .passedTests, .unanalyzedTests].contains { key in
            container.contains(key) && (try? container.decodeNil(forKey: key)) != true && container.lenient(Int.self, forKey: key) == nil
        }
    }
}

/// A test's result, from `{project}/_apis/test/Runs/{runId}/results?outcomes=…`.
public struct ADOTestResult: Decodable, Sendable {
    public var id: Int
    /// `Failed`, `Error`, `Timeout`, `Aborted`…
    public var outcome: String?
    /// Its short name, for an automated test.
    public var testCaseTitle: String?
    /// Its full name, with its namespace and class.
    public var automatedTestName: String?
    /// Where it is, such as its assembly.
    public var automatedTestStorage: String?
    public var errorMessage: String?
    public var stackTrace: String?
    public var durationInMs: Double?
    public var failingSince: FailingSince?

    /// When the test started failing, and in which run.
    public struct FailingSince: Decodable, Sendable {
        public var date: Date?
        public var build: Build?

        public struct Build: Decodable, Sendable {
            /// A number, or a string of one.
            public var id: Int?

            private enum CodingKeys: String, CodingKey { case id }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = container.lenient(Int.self, forKey: .id)
                    ?? container.lenient(String.self, forKey: .id).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
        }

        private enum CodingKeys: String, CodingKey { case date, build }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = container.lenient(Date.self, forKey: .date)
            build = container.lenient(Build.self, forKey: .build)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, outcome, testCaseTitle, automatedTestName, automatedTestStorage, errorMessage, stackTrace, durationInMs, failingSince
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        outcome = container.lenient(String.self, forKey: .outcome)
        testCaseTitle = container.lenient(String.self, forKey: .testCaseTitle)
        automatedTestName = container.lenient(String.self, forKey: .automatedTestName)
        automatedTestStorage = container.lenient(String.self, forKey: .automatedTestStorage)
        errorMessage = container.lenient(String.self, forKey: .errorMessage)
        stackTrace = container.lenient(String.self, forKey: .stackTrace)
        durationInMs = container.lenient(Double.self, forKey: .durationInMs)
        failingSince = container.lenient(FailingSince.self, forKey: .failingSince)
    }
}

// MARK: - Endpoints

extension ADOEndpoint {
    /// A run's logs: each one's ID and how many lines it has.
    public static func buildLogs(organization: String, projectId: String, buildId: Int) -> URL {
        url("https://dev.azure.com", [organization, projectId, "_apis", "build", "builds", String(buildId), "logs"],
            [("api-version", apiVersion)])
    }

    /// One of a run's logs, from `startLine` to `endLine`, counting from 1, both included: as JSON, a list of lines,
    /// each with its timestamp.
    public static func buildLogLines(organization: String, projectId: String, buildId: Int, logId: Int, startLine: Int, endLine: Int) -> URL {
        url("https://dev.azure.com", [organization, projectId, "_apis", "build", "builds", String(buildId), "logs", String(logId)],
            [("startLine", String(startLine)), ("endLine", String(endLine)), ("api-version", apiVersion)])
    }

    /// A pipeline's latest finished runs on a branch, the last to finish first.
    public static func finishedBuilds(organization: String, projectId: String, definitionId: Int, branch: String, top: Int) -> URL {
        url("https://dev.azure.com", [organization, projectId, "_apis", "build", "builds"], [
            ("definitions", String(definitionId)), ("branchName", branch.hasPrefix("refs/") ? branch : "refs/heads/\(branch)"),
            ("statusFilter", "completed"), ("queryOrder", "finishTimeDescending"), ("$top", String(top)), ("api-version", apiVersion),
        ])
    }

    /// The test runs a pipeline's run published, with how many tests had each outcome: `top` of them, after the first
    /// `skip`.
    public static func testRuns(organization: String, projectId: String, buildId: Int, skip: Int = 0, top: Int = 100) -> URL {
        url("https://dev.azure.com", [organization, projectId, "_apis", "test", "runs"], [
            ("buildUri", "vstfs:///Build/Build/\(buildId)"), ("includeRunDetails", "true"), ("$skip", String(skip)),
            ("$top", String(top)), ("api-version", apiVersion),
        ])
    }

    /// A test run's first `top` results with these outcomes, each with its error message and stack trace.
    public static func testResults(organization: String, projectId: String, runId: Int, outcomes: [String], top: Int) -> URL {
        url("https://dev.azure.com", [organization, projectId, "_apis", "test", "Runs", String(runId), "results"], [
            ("outcomes", outcomes.joined(separator: ",")), ("$top", String(top)), ("api-version", apiVersion),
        ])
    }

    /// A run's logs on its page, opened at a stage's, a job's or a task's.
    public static func buildLogPage(
        organization: String, project: String, buildId: Int, stage: String? = nil, job: String? = nil, task: String? = nil
    ) -> URL {
        var query = [("buildId", String(buildId)), ("view", "logs")]
        if let stage { query.append(("s", stage)) }
        if let job { query.append(("j", job)) }
        if let task { query.append(("t", task)) }
        return url("https://dev.azure.com", [organization, project, "_build", "results"], query)
    }
}

// MARK: - Reading

/// Reads what `BuildInvestigation` holds for one of a pull request's builds, with GETs: the run first; then, at the same
/// time, its timeline, its logs, its test runs, the pipeline's runs on the pull request and its latest finished runs on
/// the target branch; then, at the same time again, the end of the failed step's log and the failed tests of the first
/// test runs with failures. Ten requests at most, and one more for each hundred test runs past the first hundred, up to
/// five hundred. What isn't there, or may not be read, is just missing; what can't be read otherwise is `unread`.
public enum BuildInvestigationReader {
    /// The most lines of the failed step's log it reads: its last.
    public static let logLines = 200
    /// The most test runs whose failed tests it reads, and the most failed tests it lists.
    public static let testRunsRead = 3
    public static let failedTestsListed = 20
    /// How many test runs it lists a request, and the most it adds up: a run with more says its totals are partial.
    static let testRunsPerRequest = 100
    public static let testRunsCounted = 500
    /// How many of the pipeline's runs on the pull request it looks through for one that passed on the same commit.
    static let earlierRunsRead = 25
    /// How many of the pipeline's latest finished runs on the target branch it looks through for one that passed or
    /// failed, rather than being canceled.
    static let targetRunsRead = 5

    /// Whether a run, read twice, is the same: it hasn't been run again since, which keeps its ID, but not its status, result
    /// or when it finished.
    static func isSameRun(_ run: ADOBuild, _ other: ADOBuild) -> Bool {
        run.id == other.id && run.status == other.status && run.result == other.result && run.finishTime == other.finishTime
    }

    /// What was read, with the run as Azure DevOps said it, to tell again whether it built the latest commit.
    struct Read: Sendable {
        var investigation: BuildInvestigation
        var build: ADOBuild

        /// The investigation, with whether it built the pull request's latest commit as the pull request is now.
        func revised(for pullRequest: PullRequest) -> BuildInvestigation {
            var investigation = investigation
            investigation.comparison.revision = PullRequestPipelines.revision(of: build, for: pullRequest)
            return investigation
        }
    }

    /// One of a pull request's builds, in its project. Throws when the run itself can't be read.
    public static func read(client: ADOClient, buildId: Int, of pullRequest: PullRequest, now: Date = Date()) async throws
        -> BuildInvestigation {
        try await readRun(client: client, buildId: buildId, of: pullRequest, now: now).investigation
    }

    /// - Parameter readTheRun: called once the run itself is read, before the rest of what's read of it.
    static func readRun(
        client: ADOClient, buildId: Int, of pullRequest: PullRequest, now: Date, readTheRun: @Sendable () -> Void = {}
    ) async throws -> Read {
        let pr = pullRequest
        let organization = pr.key.organization
        let projectId = pr.projectId
        let build = try await client.get(ADOEndpoint.build(organization: organization, project: projectId, id: buildId), as: ADOBuild.self)
        readTheRun()
        // Stopped meanwhile: nothing more is read.
        try Task.checkCancellation()
        let definition = build.definition.id
        let branch = build.sourceBranch ?? "refs/pull/\(pr.key.number)/merge"
        async let timeline = attempt {
            try await client.get(ADOEndpoint.timeline(organization: organization, projectId: projectId, buildId: buildId), as: ADOTimeline.self)
        }
        async let logs = attempt {
            try await client.get(ADOEndpoint.buildLogs(organization: organization, projectId: projectId, buildId: buildId),
                                 as: ADOList<ADOBuildLog>.self)
        }
        async let testRuns = attempt {
            try await readTestRuns(client: client, organization: organization, projectId: projectId, buildId: buildId)
        }
        async let earlierRuns = attempt {
            try await client.get(ADOEndpoint.builds(
                organization: organization, projectId: projectId, definitionIds: [definition], branch: branch, perDefinition: earlierRunsRead
            ), as: ADOList<ADOBuild>.self)
        }
        async let targetRuns = attempt {
            try await client.get(ADOEndpoint.finishedBuilds(
                organization: organization, projectId: projectId, definitionId: definition, branch: pr.targetBranch, top: targetRunsRead
            ), as: ADOList<ADOBuild>.self)
        }

        var unread: [BuildInvestigation.Part: ADOError] = [:]
        let read = found(await timeline, .steps, unread: &unread)
        if let skipped = read?.records.skipped, skipped > 0 {
            // Its steps, and where it failed, may be among those.
            unread[.steps] = .decoding("steps that couldn't be read")
        }
        let failed = read.flatMap(PipelineFailure.failedRecord(in:))
        let (logsRead, testRunsRead) = await (logs, testRuns)
        try Task.checkCancellation()
        async let log = readLog(client: client, organization: organization, projectId: projectId, buildId: buildId, step: failed, logs: logsRead)
        async let tests = readTests(client: client, organization: organization, projectId: projectId, runs: testRunsRead)

        let runFinished = PipelineRun.Status(status: build.status, result: build.result).isFinished
        func run(_ dto: ADOBuild) -> PipelineRun {
            PipelineRun(organization: organization, projectName: pr.projectName, dto)
        }
        let target = whole(found(await targetRuns, .targetBranch, unread: &unread), .targetBranch, unread: &unread)
            .filter { $0.definition.id == definition }
            .first(where: BuildComparison.hasVerdict)
        let earlierPass = BuildComparison.earlierPass(
            of: build, among: whole(found(await earlierRuns, .earlierRuns, unread: &unread), .earlierRuns, unread: &unread)
        )
        let (logRead, testsRead) = await (log, tests)
        if let error = logRead.error { unread[.log] = error }
        if let error = testsRead.error { unread[.tests] = error }

        let investigation = BuildInvestigation(
            pipeline: PipelineRef(
                organization: organization, projectId: build.project?.id ?? projectId, projectName: build.project?.name ?? pr.projectName,
                definitionId: definition, name: PlainText.singleLine(build.definition.name ?? "Pipeline \(definition)"),
                folder: PipelineRef.folder(build.definition.path)
            ),
            run: run(build),
            steps: read.map { BuildStep.tree(from: $0, runFinished: runFinished) } ?? [],
            failure: read.flatMap(PipelineFailure.first(in:)),
            failedStepId: failed?.id,
            errors: read.map { BuildIssue.errors(in: $0, limit: BuildInvestigation.errorLimit) } ?? [],
            log: logRead.log,
            tests: testsRead.tests,
            comparison: BuildComparison(
                revision: PullRequestPipelines.revision(of: build, for: pr), targetBranch: pr.targetBranch,
                targetRun: target.map(run),
                earlierPass: earlierPass.map { BuildComparison.EarlierPass(run: run($0.build), builtTheSame: $0.builtTheSame) }
            ),
            unread: unread,
            readAt: now
        )
        return Read(investigation: investigation, build: build)
    }

    /// The end of the failed step's log, from its line count in the run's logs: nil when it has no log. When the run's logs
    /// don't have it, but some of them couldn't be read, it may be one of those: that's an error, not a missing log. So is
    /// a line count that can't be read.
    static func readLog(
        client: ADOClient, organization: String, projectId: String, buildId: Int, step: ADOTimeline.Record?,
        logs: Result<ADOList<ADOBuildLog>, ADOError>
    ) async -> (log: BuildLog?, error: ADOError?) {
        guard let step, let logId = step.log?.id else { return (nil, nil) }
        let list: ADOList<ADOBuildLog>
        switch logs {
        case .success(let value): list = value
        case .failure(let error): return (nil, isMissing(error) ? nil : error)
        }
        guard let entry = list.value.first(where: { $0.id == logId }) else {
            return (nil, list.skipped > 0 ? .decoding("a log that couldn't be read") : nil)
        }
        guard let lineCount = entry.lineCount, lineCount >= 0 else { return (nil, .decoding("a log's length that couldn't be read")) }
        guard lineCount > 0 else { return (BuildLog(stepId: step.id, logId: logId, lines: [], lineCount: 0), nil) }
        let first = max(1, lineCount - logLines + 1)
        let lines = await attempt {
            try await client.get(ADOEndpoint.buildLogLines(
                organization: organization, projectId: projectId, buildId: buildId, logId: logId, startLine: first, endLine: lineCount
            ), as: ADOLogLines.self).lines
        }
        switch lines {
        case .success(let lines): return (BuildLog(stepId: step.id, logId: logId, lineCount: lineCount, lines: lines, keep: logLines), nil)
        case .failure(let error): return (nil, isMissing(error) ? nil : error)
        }
    }

    /// A run's test runs, as far as they could be read.
    struct TestRuns: Sendable {
        /// Those that could be read, each once.
        var runs: [ADOTestRun]
        /// As many came back as it adds up, `testRunsCounted`: it may have published more.
        var isCut = false
        /// Some couldn't be read.
        var unreadable = false
        /// Why those after the first hundred stopped coming: the runs before are here.
        var error: ADOError?

        /// They're all its test runs.
        var isWhole: Bool {
            !isCut && !unreadable && error == nil
        }

        /// What couldn't be read of them, runs or their counts: reading them again may work.
        var problem: ADOError? {
            if let error { return error }
            if unreadable { return .decoding("test runs that couldn't be read") }
            if runs.contains(where: \.hasUnreadableCounts) { return .decoding("test counts that couldn't be read") }
            return nil
        }
    }

    /// The test runs a run published, a hundred a request, up to `testRunsCounted`, each once. Throws when the first
    /// hundred can't be read.
    static func readTestRuns(client: ADOClient, organization: String, projectId: String, buildId: Int) async throws -> TestRuns {
        var read = TestRuns(runs: [])
        var seen: Set<Int> = []
        for skip in stride(from: 0, to: testRunsCounted, by: testRunsPerRequest) {
            try Task.checkCancellation()
            let page: ADOList<ADOTestRun>
            do {
                page = try await client.get(ADOEndpoint.testRuns(
                    organization: organization, projectId: projectId, buildId: buildId, skip: skip, top: testRunsPerRequest
                ), as: ADOList<ADOTestRun>.self)
            } catch where skip > 0 {
                read.error = (error as? ADOError) ?? .network(error.localizedDescription)
                return read
            }
            read.runs += page.value.filter { seen.insert($0.id).inserted }
            read.unreadable = read.unreadable || page.skipped > 0
            if page.value.count + page.skipped < testRunsPerRequest { return read }
        }
        read.isCut = true
        return read
    }

    /// The run's tests, added up, and the failed tests of its first test runs with failures, each read at the same time:
    /// nil when it published none. Test runs, their counts or failed tests that couldn't be read are an error, as reading
    /// them again may work, but the rest are there all the same.
    static func readTests(
        client: ADOClient, organization: String, projectId: String, runs read: Result<TestRuns, ADOError>
    ) async -> (tests: BuildTests?, error: ADOError?) {
        let testRuns: TestRuns
        switch read {
        case .success(let value): testRuns = value
        case .failure(let error): return (nil, isMissing(error) ? nil : error)
        }
        let runs = testRuns.runs
        var problem = testRuns.problem
        // None at all is no tests; none that could be read is an error.
        guard !runs.isEmpty else { return (nil, problem) }
        // The test runs with failures, and then those that don't say how many failed.
        let failing = Array(runs
            .filter { (BuildTests.failed(in: $0) ?? 1) > 0 }
            .sorted { (BuildTests.failed(in: $0) == nil ? 1 : 0, $0.id) < (BuildTests.failed(in: $1) == nil ? 1 : 0, $1.id) }
            .prefix(testRunsRead))
        let answers = await withTaskGroup(of: (Int, Result<ADOList<ADOTestResult>, ADOError>).self) { group in
            for run in failing {
                group.addTask {
                    (run.id, await attempt {
                        try await client.get(ADOEndpoint.testResults(
                            organization: organization, projectId: projectId, runId: run.id, outcomes: BuildTests.failedOutcomes,
                            top: failedTestsListed
                        ), as: ADOList<ADOTestResult>.self)
                    })
                }
            }
            var answers: [Int: Result<ADOList<ADOTestResult>, ADOError>] = [:]
            for await (id, result) in group { answers[id] = result }
            return answers
        }
        // How many failed results came back for each, whether or not they could be read.
        var results: [Int: Int] = [:]
        var failures: [FailedTest] = []
        for run in failing {
            switch answers[run.id] {
            case .success(let list)?:
                results[run.id] = list.value.count + list.skipped
                failures += list.value.map { FailedTest($0, run: run) }
                // They count, but the ones that couldn't be read are read again next time.
                if list.skipped > 0 { problem = problem ?? .decoding("failed tests that couldn't be read") }
            case .failure(let error)? where !isMissing(error): problem = problem ?? error
            default: break
            }
        }
        let tests = BuildTests(
            runs: runs, results: results, listed: failedTestsListed, failures: Array(failures.prefix(failedTestsListed)),
            countsAllRuns: testRuns.isWhole
        )
        return (tests, problem)
    }

    /// The value read, or nil: when it isn't there, or may not be read, it's missing; when it couldn't be read
    /// otherwise, it's unread too.
    private static func found<T>(
        _ result: Result<T, ADOError>, _ part: BuildInvestigation.Part, unread: inout [BuildInvestigation.Part: ADOError]
    ) -> T? {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            if !isMissing(error) { unread[part] = error }
            return nil
        }
    }

    /// The runs a list has, when they could all be read. Otherwise none: one that couldn't may be the latest, or the one
    /// that passed on the same commit, so what the rest say could be wrong, and the list is unread.
    private static func whole(
        _ list: ADOList<ADOBuild>?, _ part: BuildInvestigation.Part, unread: inout [BuildInvestigation.Part: ADOError]
    ) -> [ADOBuild] {
        guard let list else { return [] }
        guard list.skipped == 0 else {
            unread[part] = .decoding("runs that couldn't be read")
            return []
        }
        return list.value
    }

    /// It isn't there, or isn't yours to read: reading it again won't change that.
    private static func isMissing(_ error: ADOError) -> Bool {
        error == .notFound || error == .forbidden
    }

    private static func attempt<T>(_ read: () async throws -> T) async -> Result<T, ADOError> {
        do {
            return .success(try await read())
        } catch let error as ADOError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}

// MARK: - Keeping

/// Investigates pull requests' builds when you open them, and keeps what it read for a while, so opening one again reads
/// little: a run that finished, for `keptFor`, as long as the run itself, read again, says it hasn't been run again
/// since, and isn't gone (when it can't be read, what's kept shows); one still running, for `keptWhileRunningFor`,
/// without reading anything; one that couldn't all be read, not at all. Of the reads of a run and the looks at it, the one
/// that started last, of those that found it or that it's gone, says what's kept: what doesn't agree with it goes, and
/// isn't kept. What's kept is revised for the pull request as it is when it's asked for again: whether the run built its
/// latest commit. Asking for a build that's being read, to compare it with the same target branch, waits for that read;
/// when that read had read the run before it was asked for, and found it finished, a look at the run tells whether it ran
/// again since, which reads it again. It reads only when asked: it never polls; and, once stopped, nothing at all.
public actor BuildInvestigator {
    /// Why a run couldn't be read, when a look at it found it ran again, or gone, since what was read of it before: what
    /// shows of that should go, rather than stay beside why. Not for `notFound` or `forbidden`, which say so themselves.
    public struct RunReplaced: Error, Equatable, Sendable {
        /// Why it couldn't be read.
        public var error: ADOError

        public init(error: ADOError) {
            self.error = error
        }
    }

    /// How long a finished run's investigation is kept: its steps, log and tests don't change unless it's run again, which
    /// Azure DevOps does under the same ID, but the runs it's compared with may.
    public static let keptFor: TimeInterval = 600
    /// How long the investigation of a run that's still going is kept.
    public static let keptWhileRunningFor: TimeInterval = 30
    /// The most investigations kept: the ones read longest ago go first.
    public static let capacity = 20

    /// A run: build IDs are unique within an organization, whose name's letter case doesn't matter.
    private struct Key: Hashable {
        var organization: String
        var buildId: Int

        init(_ organization: String, _ buildId: Int) {
            self.organization = organization.lowercased()
            self.buildId = buildId
        }
    }

    /// A read of a run, to compare it with a target branch.
    private struct ReadKey: Hashable {
        var run: Key
        var targetBranch: String
    }

    private struct Reading {
        var id = UUID()
        /// When it started, among reads and looks: what it finds is newer than what those that started before it found.
        var order: Int
        /// What it's read for: `forget()` makes what's read before it, and comes after, not kept.
        var generation: Int
        var task: Task<BuildInvestigationReader.Read, Error>
        /// Whether it has read the run itself yet, which it says before the actor hears its answer.
        var readTheRun: RunRead
    }

    /// That a read has read the run itself: set as the read goes on, rather than on the actor.
    private final class RunRead: Sendable {
        private let done = Mutex(false)

        var isDone: Bool { done.withLock { $0 } }

        func set() {
            done.withLock { $0 = true }
        }
    }

    /// A look at a kept run, to tell whether it's been run again since.
    private struct Checking {
        var id = UUID()
        /// When it started, among reads and looks: it tells nothing of what a read that started after it found.
        var order: Int
        var task: Task<Look, Never>
    }

    /// What a look at a kept run found.
    private enum Look: Sendable {
        /// The run, as it is now.
        case run(ADOBuild)
        /// It isn't there, or may not be read, any more.
        case gone
        /// It couldn't be read: reading it again may work.
        case unread
    }

    /// What's kept of a run: what a read found, and when the read started.
    private struct Kept {
        var read: BuildInvestigationReader.Read
        var order: Int
    }

    /// What the read or look that started last, of those that found the run or that it's gone, found: the run, or nil
    /// when it's gone.
    private struct Seen {
        var order: Int
        var build: ADOBuild?

        /// Whether a read that found `build` agrees: it found the same run, which hasn't been run again since, or gone.
        func agrees(with build: ADOBuild) -> Bool {
            self.build.map { BuildInvestigationReader.isSameRun($0, build) } ?? false
        }
    }

    private let client: ADOClient
    private let now: @Sendable () -> Date
    private var kept: [Key: Kept] = [:]
    private var seen: [Key: Seen] = [:]
    private var reading: [ReadKey: Reading] = [:]
    private var checking: [Key: Checking] = [:]
    /// How many reads and looks have started: the order they started in.
    private var started = 0
    private var generation = 0
    /// How many callers wait for reads, or looks at kept runs, under way, for tests.
    private(set) var waiting = 0
    /// It was stopped: it reads nothing any more.
    private var isStopped = false
    /// The reads and looks under way, by their IDs, to call off when it stops or forgets.
    private var underway: [UUID: @Sendable () -> Void] = [:]
    /// Who waits for each read under way, by the read's ID: a read none waits for any more is called off.
    private var asks: [UUID: Set<Int>] = [:]
    private var lastAsk = 0

    public init(client: ADOClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    /// One of a pull request's builds, investigated: what was kept of it, while it's fresh, or read now.
    /// - Parameters:
    ///   - refresh: read it again even when it's kept, as when you ask to.
    ///   - phase: how far along the run is, as its check says now: what was kept or read of it before it got there, such
    ///     as while it waited in the queue, or was still going, isn't it any more. A read under way that it waits for, which
    ///     comes back with the run not that far along, is read again, once.
    /// - Throws: `CancellationError` once it's stopped, when it's stopped or forgets meanwhile, or when its caller is called
    ///   off, as when the details close or show another pull request: a read nobody waits for any more is called off;
    ///   `RunReplaced` when a look found the run ran again, or gone, since what was read of it before, and it couldn't be
    ///   read now; else `ADOError`.
    public func investigation(
        buildId: Int, of pullRequest: PullRequest, refresh: Bool = false, phase: PipelineRun.Phase? = nil
    ) async throws -> BuildInvestigation {
        try await investigation(buildId: buildId, of: pullRequest, refresh: refresh, phase: phase, mayReadAgain: true, replaced: false)
    }

    /// - Parameters:
    ///   - mayReadAgain: a read it waits for, which started before it was asked for, is read again when it's behind, or
    ///     of the run before it ran again: once.
    ///   - replaced: a look found what was read of the run before isn't it any more.
    private func investigation(
        buildId: Int, of pullRequest: PullRequest, refresh: Bool, phase: PipelineRun.Phase?, mayReadAgain: Bool, replaced: Bool
    ) async throws -> BuildInvestigation {
        try checkStopped()
        try Task.checkCancellation()
        let key = Key(pullRequest.key.organization, buildId)
        let readKey = ReadKey(run: key, targetBranch: pullRequest.targetBranch)
        let asked = started
        var replaced = replaced
        // A read under way is newer than what's kept: wait for it rather than look at the run.
        if !refresh, reading[readKey] == nil {
            let kept = await stillKept(key, readKey: readKey, pullRequest: pullRequest, phase: phase)
            if let read = kept.read { return read.revised(for: pullRequest) }
            replaced = replaced || kept.replaced
        }
        // Stopped, or called off, while it looked at what's kept: it isn't read instead.
        try checkStopped()
        try Task.checkCancellation()
        let joined = reading[readKey]
        // Under way since before this was asked for, it had read the run by then: it may have, before the run ran again.
        let readTheRunBefore = joined.map { $0.order <= asked && $0.readTheRun.isDone } ?? false
        let current = joined ?? start(readKey, pullRequest: pullRequest)
        lastAsk += 1
        let ask = lastAsk
        asks[current.id, default: []].insert(ask)
        waiting += 1
        let task = current.task, id = current.id
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            Task { await self.giveUp(ask, on: id, readKey) }
        }
        waiting -= 1
        stopAsking(ask, on: id)
        underway[current.id] = nil
        finish(readKey, current, result)
        try checkStopped()
        // Called off, as its caller was, or with the read, as it forgot.
        if Task.isCancelled || task.isCancelled { throw CancellationError() }
        let read: BuildInvestigationReader.Read
        do {
            read = try result.get()
        } catch let error as ADOError where replaced && error != .notFound && error != .forbidden {
            throw RunReplaced(error: error)
        }
        guard joined != nil, mayReadAgain else { return read.revised(for: pullRequest) }
        // It started before this was asked for: once more, now, when the run got further since, as its check says, or ran
        // again since, or went, as a look at it finds.
        var readAgain = phase.map { read.investigation.run.status.phase < $0 } ?? false
        if !readAgain, readTheRunBefore, read.investigation.run.status.isFinished {
            let isStill = await stillTheRun(key, as: read.build, after: asked, pullRequest: pullRequest)
            // Stopped, or called off, while it looked, which a canceled look can't tell from a run it couldn't read.
            try checkStopped()
            try Task.checkCancellation()
            if !isStill {
                readAgain = true
                replaced = true
            }
        }
        guard readAgain else { return read.revised(for: pullRequest) }
        return try await investigation(
            buildId: buildId, of: pullRequest, refresh: true, phase: nil, mayReadAgain: false, replaced: replaced
        )
    }

    /// Stops for good, as when Azure DevOps is turned off: the reads and looks under way are canceled, what's kept goes, and
    /// nothing is read any more. Whoever waits for a build, or asks for one, gets `CancellationError`.
    public func stop() {
        isStopped = true
        for cancel in underway.values { cancel() }
        underway = [:]
        forget()
    }

    private func checkStopped() throws {
        if isStopped { throw CancellationError() }
    }

    /// Forgets what it read, as when someone else signs in: the reads and looks under way, as the last one, are called off,
    /// and whoever waits for a read gets `CancellationError`; nothing read before is kept.
    public func forget() {
        for cancel in underway.values { cancel() }
        underway = [:]
        asks = [:]
        kept = [:]
        seen = [:]
        reading = [:]
        checking = [:]
        generation += 1
    }

    /// The builds whose investigations are kept, by ID, for tests.
    var keptBuilds: Set<Int> {
        Set(kept.keys.map(\.buildId))
    }

    /// What's kept of the run, while it's fresh, unless it's from before the run got as far as its check says now (`phase`):
    /// as it was, for a run still going; for one that had finished, once a look at the run that started after it was read
    /// says it hasn't been run again since, or the run can't be read. Nil when it has to be read again: when the look finds
    /// the run run again, or gone, what's kept goes, even if a read under way is waited for instead, and `replaced` says so.
    /// Callers at the same time share a look, but what a read that started after it kept gets a look of its own.
    private func stillKept(
        _ key: Key, readKey: ReadKey, pullRequest: PullRequest, phase: PipelineRun.Phase?
    ) async -> (read: BuildInvestigationReader.Read?, replaced: Bool) {
        guard let held = kept[key], isFresh(held.read.investigation, for: pullRequest) else { return (nil, false) }
        if let phase, held.read.investigation.run.status.phase < phase { return (nil, false) }
        guard held.read.investigation.run.status.isFinished else { return (held.read, false) }
        let generation = generation
        let check = checking[key].flatMap { $0.order > held.order ? $0 : nil } ?? startCheck(key, pullRequest: pullRequest)
        waiting += 1
        let look = await check.task.value
        waiting -= 1
        underway[check.id] = nil
        if checking[key]?.id == check.id { checking[key] = nil }
        guard generation == self.generation else { return (nil, false) }
        let replaced: Bool
        switch look {
        case .run(let run):
            see(key, order: check.order, build: run)
            replaced = !BuildInvestigationReader.isSameRun(run, held.read.build)
        case .gone:
            see(key, order: check.order, build: nil)
            replaced = true
        case .unread:
            replaced = false
        }
        // A read started meanwhile is newer: it's waited for.
        guard reading[readKey] == nil, let current = kept[key] else {
            tidy(key)
            return (nil, replaced)
        }
        guard current.order < check.order else {
            let again = await stillKept(key, readKey: readKey, pullRequest: pullRequest, phase: phase)
            return (again.read, again.replaced || replaced)
        }
        return (isFresh(current.read.investigation, for: pullRequest) ? current.read : nil, replaced)
    }

    /// Whether the run is still as a read that started before a caller asked for it found it (`build`): a look at it,
    /// started after the caller asked (`asked`), says it hasn't run again since, or it can't be looked at. Not when it ran
    /// again, or it's gone, which what's kept of it learns too.
    private func stillTheRun(_ key: Key, as build: ADOBuild, after asked: Int, pullRequest: PullRequest) async -> Bool {
        let generation = generation
        let check = checking[key].flatMap { $0.order > asked ? $0 : nil } ?? startCheck(key, pullRequest: pullRequest)
        waiting += 1
        let look = await check.task.value
        waiting -= 1
        underway[check.id] = nil
        if checking[key]?.id == check.id { checking[key] = nil }
        defer { tidy(key) }
        let learns = generation == self.generation
        switch look {
        case .run(let run):
            if learns { see(key, order: check.order, build: run) }
            return BuildInvestigationReader.isSameRun(run, build)
        case .gone:
            if learns { see(key, order: check.order, build: nil) }
            return false
        case .unread:
            return true
        }
    }

    private func isFresh(_ investigation: BuildInvestigation, for pullRequest: PullRequest) -> Bool {
        guard investigation.unread.isEmpty, investigation.comparison.targetBranch == pullRequest.targetBranch else { return false }
        let keptFor = investigation.run.status.isFinished ? Self.keptFor : Self.keptWhileRunningFor
        return now().timeIntervalSince(investigation.readAt) < keptFor
    }

    private func startCheck(_ key: Key, pullRequest: PullRequest) -> Checking {
        let client = client
        let address = ADOEndpoint.build(organization: pullRequest.key.organization, project: pullRequest.projectId, id: key.buildId)
        started += 1
        let check = Checking(order: started, task: Task { () async -> Look in
            do {
                return .run(try await client.get(address, as: ADOBuild.self))
            } catch ADOError.notFound, ADOError.forbidden {
                return .gone
            } catch {
                return .unread
            }
        })
        checking[key] = check
        let task = check.task
        underway[check.id] = { task.cancel() }
        return check
    }

    private func start(_ readKey: ReadKey, pullRequest: PullRequest) -> Reading {
        let client = client
        let readAt = now()
        let buildId = readKey.run.buildId
        let readTheRun = RunRead()
        started += 1
        let reading = Reading(order: started, generation: generation, task: Task {
            try await BuildInvestigationReader.readRun(client: client, buildId: buildId, of: pullRequest, now: readAt) {
                readTheRun.set()
            }
        }, readTheRun: readTheRun)
        self.reading[readKey] = reading
        let task = reading.task
        underway[reading.id] = { task.cancel() }
        return reading
    }

    /// Learns what a read or look that started `order`th found: the run, or that it's gone (nil). Unless one that started
    /// later found something already, that's what's known of the run now, and what's kept goes unless it agrees.
    private func see(_ key: Key, order: Int, build: ADOBuild?) {
        guard order > seen[key]?.order ?? 0 else { return }
        let latest = Seen(order: order, build: build)
        seen[key] = latest
        if let held = kept[key], !latest.agrees(with: held.read.build) { kept[key] = nil }
    }

    /// Learns what a read found, once, as the first of its callers comes back: the run, or that it's gone. Keeps it when
    /// it could all be read, agrees with what's known of the run, and nothing read since is kept; then lets go of the
    /// oldest beyond `capacity`. What was read before `forget()` is neither learned nor kept.
    private func finish(_ readKey: ReadKey, _ current: Reading, _ result: Result<BuildInvestigationReader.Read, Error>) {
        guard reading[readKey]?.id == current.id else { return }
        reading[readKey] = nil
        let key = readKey.run
        defer { tidy(key) }
        guard current.generation == generation else { return }
        switch result {
        case .success(let read):
            see(key, order: current.order, build: read.build)
            guard read.investigation.unread.isEmpty, seen[key]?.agrees(with: read.build) == true else { return }
            if let held = kept[key], held.order > current.order { return }
            kept[key] = Kept(read: read, order: current.order)
            while kept.count > Self.capacity, let oldest = kept.min(by: { $0.value.order < $1.value.order })?.key {
                kept[oldest] = nil
                tidy(oldest)
            }
        case .failure(let error as ADOError) where error == .notFound || error == .forbidden:
            // Gone, or no longer yours to read: what's kept of it goes.
            see(key, order: current.order, build: nil)
        case .failure:
            break
        }
    }

    /// A caller stopped waiting for a read before it was done, as its task was called off: when it was the last, the read
    /// is called off too, and whoever asks for the run next reads it anew.
    private func giveUp(_ ask: Int, on id: UUID, _ readKey: ReadKey) {
        guard stopAsking(ask, on: id), asks[id] == nil else { return }
        underway.removeValue(forKey: id)?()
        guard reading[readKey]?.id == id else { return }
        reading[readKey] = nil
        tidy(readKey.run)
    }

    /// Notes that a caller doesn't wait for a read any more: it's done, or it stopped waiting. False when that was noted
    /// already.
    @discardableResult
    private func stopAsking(_ ask: Int, on id: UUID) -> Bool {
        guard asks[id]?.remove(ask) != nil else { return false }
        if asks[id]?.isEmpty == true { asks[id] = nil }
        return true
    }

    /// How many callers wait for each read under way, for tests.
    var asking: Int { asks.values.reduce(0) { $0 + $1.count } }

    /// Lets go of what's known of a run once nothing of it is kept, read or looked at.
    private func tidy(_ key: Key) {
        guard kept[key] == nil, checking[key] == nil, !reading.keys.contains(where: { $0.run == key }) else { return }
        seen[key] = nil
    }
}
