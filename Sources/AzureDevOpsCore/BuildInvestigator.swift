import Foundation

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

    static func readRun(client: ADOClient, buildId: Int, of pullRequest: PullRequest, now: Date) async throws -> Read {
        let pr = pullRequest
        let organization = pr.key.organization
        let projectId = pr.projectId
        let build = try await client.get(ADOEndpoint.build(organization: organization, project: projectId, id: buildId), as: ADOBuild.self)
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
    /// don't have it, but some of them couldn't be read, it may be one of those: that's an error, not a missing log.
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
        guard let lineCount = entry.lineCount, lineCount >= 0 else { return (nil, nil) }
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

    /// The test runs a run published, a hundred a request, up to `testRunsCounted`, each once, and whether that's all of
    /// them: not when there are more, or one of them couldn't be read.
    static func readTestRuns(client: ADOClient, organization: String, projectId: String, buildId: Int) async throws
        -> (runs: [ADOTestRun], all: Bool) {
        var runs: [ADOTestRun] = []
        var seen: Set<Int> = []
        var unreadable = false
        for skip in stride(from: 0, to: testRunsCounted, by: testRunsPerRequest) {
            let page = try await client.get(ADOEndpoint.testRuns(
                organization: organization, projectId: projectId, buildId: buildId, skip: skip, top: testRunsPerRequest
            ), as: ADOList<ADOTestRun>.self)
            runs += page.value.filter { seen.insert($0.id).inserted }
            unreadable = unreadable || page.skipped > 0
            if page.value.count + page.skipped < testRunsPerRequest { return (runs, !unreadable) }
        }
        return (runs, false)
    }

    /// The run's tests, added up, and the failed tests of its first test runs with failures, each read at the same time:
    /// nil when it published none.
    static func readTests(
        client: ADOClient, organization: String, projectId: String, runs read: Result<(runs: [ADOTestRun], all: Bool), ADOError>
    ) async -> (tests: BuildTests?, error: ADOError?) {
        let runs: [ADOTestRun]
        let all: Bool
        switch read {
        case .success(let value): (runs, all) = (value.runs, value.all)
        case .failure(let error): return (nil, isMissing(error) ? nil : error)
        }
        // None at all is no tests; none that could be read is an error.
        guard !runs.isEmpty else { return (nil, all ? nil : .decoding("test runs that couldn't be read")) }
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
        var problem: ADOError?
        for run in failing {
            switch answers[run.id] {
            case .success(let list)?:
                results[run.id] = list.value.count + list.skipped
                failures += list.value.map { FailedTest($0, run: run) }
            case .failure(let error)? where !isMissing(error): problem = problem ?? error
            default: break
            }
        }
        let tests = BuildTests(
            runs: runs, results: results, listed: failedTestsListed, failures: Array(failures.prefix(failedTestsListed)),
            countsAllRuns: all
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
/// since; one still running, for `keptWhileRunningFor`, without reading anything; one that couldn't all be read, not at
/// all. What's kept is revised for the pull request as it is when it's asked for again: whether the run built its latest
/// commit. Asking for a build that's being read, to compare it with the same target branch, waits for that read. It reads
/// only when asked: it never polls.
public actor BuildInvestigator {
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
        /// What it's read for: `forget()` makes what's read before it, and comes after, not kept.
        var generation: Int
        var task: Task<BuildInvestigationReader.Read, Error>
    }

    /// A look at a kept run, to tell whether it's been run again since: nil when it can't be read.
    private struct Checking {
        var id = UUID()
        var task: Task<ADOBuild?, Never>
    }

    private let client: ADOClient
    private let now: @Sendable () -> Date
    private var kept: [Key: BuildInvestigationReader.Read] = [:]
    private var reading: [ReadKey: Reading] = [:]
    private var checking: [Key: Checking] = [:]
    private var generation = 0
    /// How many callers wait for reads, or looks at kept runs, under way, for tests.
    private(set) var waiting = 0

    public init(client: ADOClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    /// One of a pull request's builds, investigated: what was kept of it, while it's fresh, or read now.
    /// - Parameter refresh: read it again even when it's kept, as when you ask to.
    public func investigation(buildId: Int, of pullRequest: PullRequest, refresh: Bool = false) async throws -> BuildInvestigation {
        let key = Key(pullRequest.key.organization, buildId)
        let readKey = ReadKey(run: key, targetBranch: pullRequest.targetBranch)
        // A read under way is newer than what's kept: wait for it rather than look at the run.
        if !refresh, reading[readKey] == nil, let read = await stillKept(key, readKey: readKey, pullRequest: pullRequest) {
            return read.revised(for: pullRequest)
        }
        let current = reading[readKey] ?? start(readKey, pullRequest: pullRequest)
        waiting += 1
        defer { waiting -= 1 }
        do {
            let read = try await current.task.value
            finish(readKey, current, read: read)
            return read.revised(for: pullRequest)
        } catch {
            finish(readKey, current, read: nil)
            throw error
        }
    }

    /// Forgets what it read, as when someone else signs in: a read under way still answers whoever waits for it, but
    /// isn't kept.
    public func forget() {
        kept = [:]
        reading = [:]
        checking = [:]
        generation += 1
    }

    /// The builds whose investigations are kept, by ID, for tests.
    var keptBuilds: Set<Int> {
        Set(kept.keys.map(\.buildId))
    }

    /// What's kept of the run, while it's fresh: as it was, for a run still going; for one that had finished, once the run,
    /// read again, says it hasn't been run again since, or when it can't be read. Nil when it has to be read again. Callers
    /// at the same time share that look at the run.
    private func stillKept(_ key: Key, readKey: ReadKey, pullRequest: PullRequest) async -> BuildInvestigationReader.Read? {
        guard let read = kept[key], isFresh(read.investigation, for: pullRequest) else { return nil }
        guard read.investigation.run.status.isFinished else { return read }
        let generation = generation
        let check = checking[key] ?? startCheck(key, pullRequest: pullRequest)
        waiting += 1
        let run = await check.task.value
        waiting -= 1
        if checking[key]?.id == check.id { checking[key] = nil }
        // What's kept now: it may have gone, or been read again, meanwhile; and a read started meanwhile is newer.
        guard generation == self.generation, reading[readKey] == nil, let kept = kept[key], isFresh(kept.investigation, for: pullRequest)
        else { return nil }
        guard let run else { return kept }
        return BuildInvestigationReader.isSameRun(run, kept.build) ? kept : nil
    }

    private func isFresh(_ investigation: BuildInvestigation, for pullRequest: PullRequest) -> Bool {
        guard investigation.unread.isEmpty, investigation.comparison.targetBranch == pullRequest.targetBranch else { return false }
        let keptFor = investigation.run.status.isFinished ? Self.keptFor : Self.keptWhileRunningFor
        return now().timeIntervalSince(investigation.readAt) < keptFor
    }

    private func startCheck(_ key: Key, pullRequest: PullRequest) -> Checking {
        let client = client
        let address = ADOEndpoint.build(organization: pullRequest.key.organization, project: pullRequest.projectId, id: key.buildId)
        let check = Checking(task: Task { try? await client.get(address, as: ADOBuild.self) })
        checking[key] = check
        return check
    }

    private func start(_ readKey: ReadKey, pullRequest: PullRequest) -> Reading {
        let client = client
        let readAt = now()
        let buildId = readKey.run.buildId
        let reading = Reading(generation: generation, task: Task {
            try await BuildInvestigationReader.readRun(client: client, buildId: buildId, of: pullRequest, now: readAt)
        })
        self.reading[readKey] = reading
        return reading
    }

    /// Keeps what a read found, unless something couldn't be read, it was read before `forget()`, or something newer is
    /// kept already; then lets go of the oldest beyond `capacity`.
    private func finish(_ readKey: ReadKey, _ current: Reading, read: BuildInvestigationReader.Read?) {
        if reading[readKey]?.id == current.id { reading[readKey] = nil }
        guard let read, current.generation == generation, read.investigation.unread.isEmpty else { return }
        let key = readKey.run
        if let known = kept[key], known.investigation.readAt > read.investigation.readAt { return }
        kept[key] = read
        while kept.count > Self.capacity,
              let oldest = kept.min(by: { $0.value.investigation.readAt < $1.value.investigation.readAt })?.key {
            kept[oldest] = nil
        }
    }
}
