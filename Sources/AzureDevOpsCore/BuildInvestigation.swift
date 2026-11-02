import Foundation

/// What BriefBar can tell of one of a pull request's failed builds, read when you open it (`BuildInvestigator`), so it
/// can be looked into without Azure DevOps' page: the run's steps, where it failed and its first errors, the end of the
/// failed step's log, the tests that failed, and whether it's the change's doing at all.
public struct BuildInvestigation: Sendable, Equatable {
    /// What's read with requests of its own: when one can't be read, the rest still shows.
    public enum Part: String, Sendable, CaseIterable {
        /// The timeline: the steps, where it failed and its errors.
        case steps
        /// The end of the failed step's log.
        case log
        case tests
        /// The pipeline's latest run on the target branch.
        case targetBranch
        /// The pipeline's earlier runs on the pull request.
        case earlierRuns
    }

    /// The most errors `errors` lists.
    public static let errorLimit = 10

    public var pipeline: PipelineRef
    public var run: PipelineRun
    /// Its stages, each with its jobs and their tasks, in order; or its jobs, when it has no stages of its own.
    public var steps: [BuildStep]
    /// Where it failed first, and the first error there, as the pull request's checks say it.
    public var failure: PipelineFailure?
    /// The step that failed first, `failure`'s: a task, or a job or stage when no task failed. `log` is its log's end.
    public var failedStepId: String?
    /// Its errors, in the order they came, each once, at most `errorLimit`.
    public var errors: [BuildIssue]
    /// The end of the failed step's log; nil when it has none, or it couldn't be read.
    public var log: BuildLog?
    /// The tests it ran and published; nil when it published none.
    public var tests: BuildTests?
    /// The run compared with the pull request's latest commit, and with the pipeline's other runs: whether it's the
    /// change's doing.
    public var comparison: BuildComparison
    /// What couldn't be read, and why: reading it again may work. What isn't there, or may not be read, isn't here: it's
    /// just missing.
    public var unread: [Part: ADOError]
    public var readAt: Date

    public init(
        pipeline: PipelineRef, run: PipelineRun, steps: [BuildStep] = [], failure: PipelineFailure? = nil, failedStepId: String? = nil,
        errors: [BuildIssue] = [], log: BuildLog? = nil, tests: BuildTests? = nil, comparison: BuildComparison,
        unread: [Part: ADOError] = [:], readAt: Date
    ) {
        self.pipeline = pipeline
        self.run = run
        self.steps = steps
        self.failure = failure
        self.failedStepId = failedStepId
        self.errors = errors
        self.log = log
        self.tests = tests
        self.comparison = comparison
        self.unread = unread
        self.readAt = readAt
    }

    /// What the comparison says of the run, the most telling first.
    public var hints: [BuildHint] {
        comparison.hints(for: run)
    }

    /// The step that failed first.
    public var failedStep: BuildStep? {
        failedStepId.flatMap(step)
    }

    /// Every step, each one before the steps under it.
    public var allSteps: [BuildStep] {
        steps.flatMap(\.withSteps)
    }

    /// A step, wherever it is.
    public func step(_ id: String) -> BuildStep? {
        path(to: id).last
    }

    /// The step and the ones it's under, from the top: its stage, its job, then the step.
    public func path(to id: String) -> [BuildStep] {
        func find(_ steps: [BuildStep]) -> [BuildStep]? {
            for step in steps {
                if step.id == id { return [step] }
                if let rest = find(step.steps) { return [step] + rest }
            }
            return nil
        }
        return find(steps) ?? []
    }

    /// A step's log, on the run's page in Azure DevOps; the run's logs when the step isn't one of its.
    public func logPage(for id: String) -> URL {
        let path = path(to: id)
        let stage = path.last { $0.kind == .stage }
        let job = path.last { $0.kind == .job }
        let task = path.last { $0.kind == .task }
        return ADOEndpoint.buildLogPage(
            organization: run.organization, project: run.projectName, buildId: run.id,
            stage: job == nil ? stage?.id : nil, job: job?.id, task: task?.id
        )
    }
}

// MARK: - Steps

/// A stage, job or task of a run, with the steps under it.
public struct BuildStep: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case stage, job, task
    }

    /// Its timeline record's ID.
    public var id: String
    public var kind: Kind
    public var name: String
    /// Where it stands, as the Pipelines page shows a stage: pending, waiting for an approval or a check, running, or how
    /// it ended.
    public var state: PipelineStage.State
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Which try it is: 2 once it's been run again.
    public var attempt: Int
    /// Its errors and warnings, as many as the timeline lists.
    public var issues: [BuildIssue]
    /// How many errors and warnings it logged, which can be more than `issues` lists.
    public var errorCount: Int
    public var warningCount: Int
    /// Its log's ID, when it has a log.
    public var logId: Int?
    /// A stage's jobs, or a job's tasks, in order.
    public var steps: [BuildStep]

    public init(
        id: String, kind: Kind, name: String, state: PipelineStage.State, startedAt: Date? = nil, finishedAt: Date? = nil,
        attempt: Int = 1, issues: [BuildIssue] = [], errorCount: Int? = nil, warningCount: Int? = nil, logId: Int? = nil,
        steps: [BuildStep] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.attempt = attempt
        self.issues = issues
        self.errorCount = max(errorCount ?? 0, issues.filter { $0.kind == .error }.count)
        self.warningCount = max(warningCount ?? 0, issues.filter { $0.kind == .warning }.count)
        self.logId = logId
        self.steps = steps
    }

    /// The step, then every step under it.
    public var withSteps: [BuildStep] {
        [self] + steps.flatMap(\.withSteps)
    }

    /// How long it ran, or has been running.
    public func duration(now: Date) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }

    /// A run's steps, from its timeline: its stages, each with its jobs and their tasks; or its jobs, when it has no
    /// stages of its own (a pipeline without stages has one hidden stage, `__default`). A job that hasn't been set up
    /// yet, such as one of a stage that hasn't started, shows as its phase, without tasks. Records of other kinds, such
    /// as the checks before a stage, aren't steps: a stage that waits for one says so.
    public static func tree(from timeline: ADOTimeline, runFinished: Bool) -> [BuildStep] {
        let records = timeline.records.elements
        let children = Dictionary(grouping: records, by: \.parentId)
        let waiting = Set(records.filter { $0.type == "Checkpoint" && $0.state == "inProgress" }.compactMap(\.parentId))
        func sorted(_ records: [ADOTimeline.Record]) -> [ADOTimeline.Record] {
            records.sorted { one, other in
                (one.order ?? .max, one.startTime ?? .distantFuture, one.name ?? "")
                    < (other.order ?? .max, other.startTime ?? .distantFuture, other.name ?? "")
            }
        }
        func step(_ record: ADOTimeline.Record, _ kind: Kind, _ steps: [BuildStep]) -> BuildStep {
            let name = PlainText.singleLine(record.name ?? record.identifier ?? "")
            return BuildStep(
                id: record.id, kind: kind, name: name.isEmpty ? kind.rawValue.capitalized : name,
                state: PipelineStage.state(record, waiting: kind == .stage && waiting.contains(record.id), runFinished: runFinished),
                startedAt: record.startTime, finishedAt: record.finishTime, attempt: max(1, record.attempt ?? 1),
                issues: BuildIssue.issues(of: record), errorCount: record.errorCount, warningCount: record.warningCount,
                logId: record.log?.id, steps: steps
            )
        }
        func tasks(of job: ADOTimeline.Record) -> [BuildStep] {
            sorted(children[job.id, default: []].filter { $0.type == "Task" }).map { step($0, .task, []) }
        }
        /// The jobs under a stage, or at the top when nil: those of each phase, and any right under it.
        func jobs(under parent: String?) -> [BuildStep] {
            var jobs: [ADOTimeline.Record] = []
            for child in sorted(children[parent, default: []]) {
                switch child.type {
                case "Phase":
                    let phaseJobs = sorted(children[child.id, default: []].filter { $0.type == "Job" })
                    jobs += phaseJobs.isEmpty ? [child] : phaseJobs
                case "Job":
                    jobs.append(child)
                default:
                    break
                }
            }
            return jobs.map { step($0, .job, tasks(of: $0)) }
        }
        let stages = records.filter { $0.type == "Stage" }
        if stages.count == 1, stages[0].identifier == "__default" || stages[0].name == "__default" {
            return jobs(under: stages[0].id)
        }
        if stages.isEmpty {
            return jobs(under: nil)
        }
        return sorted(stages).map { step($0, .stage, jobs(under: $0.id)) }
    }
}

// MARK: - Issues

/// An error or a warning that a step logged, and where in the code it is, when it says.
public struct BuildIssue: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case error, warning
    }

    /// The most characters a message keeps.
    public static let messageLimit = 1_000

    public var kind: Kind
    /// On one line, without the log's `##[error]` or `##[warning]`.
    public var message: String
    /// The file, from the repository's root when it's in the run's sources folder: `src/Cart.cs`.
    public var file: String?
    public var line: Int?
    public var column: Int?
    /// Its code, such as `CS1002`.
    public var code: String?
    /// The line of the step's log it was logged on.
    public var logLine: Int?
    /// The step that logged it, and its name.
    public var stepId: String
    public var step: String

    public init(
        kind: Kind, message: String, file: String? = nil, line: Int? = nil, column: Int? = nil, code: String? = nil,
        logLine: Int? = nil, stepId: String, step: String
    ) {
        self.kind = kind
        self.message = message
        self.file = file
        self.line = line
        self.column = column
        self.code = code
        self.logLine = logLine
        self.stepId = stepId
        self.step = step
    }

    /// Nil for an issue that's neither an error nor a warning, or says nothing. The file and line come from the issue's
    /// data or, without a file there, from the start of its message, as compilers write it: `src/Cart.cs(41,5): error
    /// CS1002: ; expected` or `Sources/Cart.swift:41:5: error: …`.
    init?(_ issue: ADOTimeline.Record.Issue, of record: ADOTimeline.Record) {
        guard let kind = issue.type.flatMap({ Kind(rawValue: $0.lowercased()) }) else { return nil }
        let message = Self.clean(issue.message ?? "")
        guard !message.isEmpty else { return nil }
        let data = issue.data
        var file = data["sourcepath"].flatMap(Self.path)
        var line = data["linenumber"].flatMap(Self.number)
        var column = data["columnnumber"].flatMap(Self.number)
        if file == nil, let place = Self.place(in: message) {
            file = place.file
            line = place.line
            column = place.column
        }
        let code = data["code"]?.trimmingCharacters(in: .whitespaces)
        let name = PlainText.singleLine(record.name ?? record.identifier ?? "")
        self.init(
            kind: kind, message: message, file: file, line: line, column: line == nil ? nil : column,
            code: code?.isEmpty == false ? code : nil, logLine: data["logFileLineNumber"].flatMap(Self.number),
            stepId: record.id, step: name.isEmpty ? "A step" : name
        )
    }

    /// A record's errors and warnings, in the order it logged them.
    static func issues(of record: ADOTimeline.Record) -> [BuildIssue] {
        (record.issues?.elements ?? []).compactMap { BuildIssue($0, of: record) }
    }

    /// A run's errors, the first of each message, in the order its steps finished, at most `limit`.
    static func errors(in timeline: ADOTimeline, limit: Int) -> [BuildIssue] {
        var seen: Set<String> = []
        var errors: [BuildIssue] = []
        let records = timeline.records.elements
            .filter { $0.result == "failed" || $0.issues?.elements.contains { $0.type?.lowercased() == "error" } == true }
            .sorted { ($0.finishTime ?? .distantFuture, $0.order ?? .max) < ($1.finishTime ?? .distantFuture, $1.order ?? .max) }
        for record in records {
            for issue in issues(of: record) where issue.kind == .error && seen.insert(issue.message).inserted {
                errors.append(issue)
                if errors.count == limit { return errors }
            }
        }
        return errors
    }

    /// One line, as a terminal shows it, without the log's `##[error]` or `##[warning]`, at most `messageLimit` characters.
    static func clean(_ message: String) -> String {
        var text = PlainText.terminalLine(message)
        for prefix in ["##[error]", "##[warning]"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return text.count > messageLimit ? String(text.prefix(messageLimit - 1)) + "…" : text
    }

    /// A line or column number: 0, which the agent writes when it doesn't know, is none.
    static func number(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }

    /// The path with forward slashes, from the repository's root when it's in the run's sources folder, `$(Build.
    /// SourcesDirectory)`, which agents keep at `<work folder>/<n>/s`: `D:\a\1\s\src\Cart.cs` is `src/Cart.cs`.
    static func path(_ text: String) -> String? {
        var path = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        if let match = path.firstMatch(of: sourcesFolder) {
            path = String(path[match.range.upperBound...])
        }
        while path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        return path.isEmpty ? nil : path
    }

    /// Where a compiler's message says it is.
    static func place(in message: String) -> (file: String, line: Int, column: Int?)? {
        guard let match = message.prefixMatch(of: msbuildPlace) ?? message.prefixMatch(of: compilerPlace),
              let file = path(String(match.output.1)), let line = number(String(match.output.2))
        else { return nil }
        return (file, line, match.output.3.flatMap { number(String($0)) })
    }

    nonisolated(unsafe) private static let sourcesFolder = /^(?:[A-Za-z]:)?\/(?:[^\/]*\/)*?\d+\/s\//
    /// `src/Cart.cs(41,5): error CS1002: …`, as MSBuild, the C# compiler and TypeScript write it, after MSBuild's node
    /// number (`3>`) when there is one.
    nonisolated(unsafe) private static let msbuildPlace =
        /\s*(?:\d+>)?([^\s(][^(]*?)\((\d+)(?:,(\d+))?(?:,\d+,\d+)?\)\s*:\s*(?:[A-Za-z ]+\s)?(?:error|warning)\b/
    /// `Sources/Cart.swift:41:5: error: …`, as Clang, GCC and Swift write it, with a drive first on Windows: `C:\a\1\s\…`.
    nonisolated(unsafe) private static let compilerPlace =
        /((?:[A-Za-z]:[\\\/])?[^\s:][^:]*):(\d+):(?:(\d+):)?\s*(?:fatal\s+)?(?:error|warning)\b/
}

// MARK: - The log

/// The end of a step's log, without the timestamps and colors.
public struct BuildLog: Sendable, Equatable {
    /// The step's, and its ID.
    public var stepId: String
    public var logId: Int
    /// Its last lines, at most `BuildInvestigationReader.logLines`, without the ends of groups.
    public var lines: [BuildLogLine]
    /// How many lines the whole log has.
    public var lineCount: Int
    /// The number of the first line read: the ones before it were left out.
    public var firstLine: Int

    public init(stepId: String, logId: Int, lines: [BuildLogLine], lineCount: Int, firstLine: Int = 1) {
        self.stepId = stepId
        self.logId = logId
        self.lines = lines
        self.lineCount = lineCount
        self.firstLine = firstLine
    }

    /// The last `keep` of the lines that end a log of `lineCount` lines, as Azure DevOps keeps them: nil for one that
    /// couldn't be read, which keeps its number but doesn't show.
    init(stepId: String, logId: Int, lineCount: Int, lines raw: [String?], keep: Int) {
        let kept = raw.suffix(keep)
        let count = max(lineCount, raw.count)
        let first = count - kept.count + 1
        self.init(
            stepId: stepId, logId: logId,
            lines: kept.enumerated().compactMap { index, line in line.flatMap { BuildLogLine(raw: $0, number: first + index) } },
            lineCount: count, firstLine: first
        )
    }

    /// Lines before these were left out.
    public var isCut: Bool {
        firstLine > 1
    }
}

/// A line of a log.
public struct BuildLogLine: Sendable, Equatable, Identifiable {
    /// What the line is, as the log's `##[…]` marker says.
    public enum Kind: String, Sendable {
        case plain, error, warning
        /// `##[section]`: a step starts or finishes.
        case section
        /// `##[command]`: the command a step runs.
        case command
        /// `##[group]`: the title of lines grouped under it.
        case group
        case debug
    }

    /// The most characters a line keeps.
    public static let limit = 500

    /// Its number in the log, from 1.
    public var number: Int
    public var kind: Kind
    public var text: String

    public var id: Int { number }

    public init(number: Int, kind: Kind = .plain, text: String) {
        self.number = number
        self.kind = kind
        self.text = text
    }

    /// A line as Azure DevOps keeps it, `2026-10-18T10:00:00.1234567Z ##[error]Something failed`, without its timestamp,
    /// its colors and other control characters, and what a carriage return wrote over, at most `limit` characters. Its
    /// `##[…]` marker becomes its kind. Nil for the end of a group, which shows nothing.
    init?(raw: String, number: Int) {
        var text = Substring(raw)
        if text.first == "\u{FEFF}" { text = text.dropFirst() }
        if let stamp = text.prefixMatch(of: Self.timestamp) { text = text[stamp.range.upperBound...] }
        var line = PlainText.terminal(text)
        var kind = Kind.plain
        if line.hasPrefix("##["), let end = line.firstIndex(of: "]") {
            let marker = line[line.index(line.startIndex, offsetBy: 3)..<end].lowercased()
            if marker == "endgroup" { return nil }
            if let known = Kind(rawValue: marker), known != .plain {
                kind = known
                line = String(line[line.index(after: end)...])
            }
        }
        while line.last?.isWhitespace == true { line.removeLast() }
        if line.count > Self.limit { line = String(line.prefix(Self.limit - 1)) + "…" }
        self.init(number: number, kind: kind, text: line)
    }

    nonisolated(unsafe) private static let timestamp = /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z ?/
}

extension PlainText {
    /// What a terminal shows of a line a program wrote: what the last carriage return that writes something wrote, without
    /// escape sequences (colors, cursor moves, character sets, titles, links) or other control characters but tabs.
    /// Carriage returns are found scalar by scalar: Swift takes a carriage return and a line feed for one character.
    static func terminal(_ text: Substring) -> String {
        var shown = ""
        for part in text.unicodeScalars.split(separator: "\r", omittingEmptySubsequences: false) {
            let written = withoutControls(part)
            if written.contains(where: { !$0.isWhitespace }) { shown = written }
        }
        return shown
    }

    /// What a program wrote, such as a build's error, on one line, as a terminal shows each of its lines. Lines end at
    /// each line feed, scalar by scalar, so a carriage return before one, or two (`\r\r\n`), ends a line too.
    static func terminalLine(_ text: String) -> String {
        singleLine(text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { terminal(Substring($0)) }.joined(separator: " "))
    }

    /// The scalars without escape sequences, or control characters but tabs.
    private static func withoutControls(_ scalars: Substring.UnicodeScalarView) -> String {
        enum State {
            case text
            /// After ESC.
            case escape
            /// After ESC and characters from space to `/`, until one from `0` to `~`: `ESC ( B`.
            case escapeIntermediates
            /// A control sequence, `ESC [`, until a character from `@` to `~`: `ESC [ 1 ; 31 m`.
            case sequence
            /// A string, such as a title or a link, until BEL or `ESC \`.
            case string
            case stringEscape
        }
        var state = State.text
        var result = String.UnicodeScalarView()
        func handle(_ scalar: Unicode.Scalar) {
            let value = scalar.value
            switch state {
            case .text:
                switch value {
                case 0x1B: state = .escape
                case 0x9B: state = .sequence
                case 0x09: result.append(scalar)
                case 0x00...0x1F, 0x7F...0x9F: break
                default: result.append(scalar)
                }
            case .escape:
                switch value {
                case 0x5B: state = .sequence
                case 0x5D, 0x50, 0x58, 0x5E, 0x5F: state = .string
                case 0x20...0x2F: state = .escapeIntermediates
                case 0x30...0x7E: state = .text
                default:
                    state = .text
                    handle(scalar)
                }
            case .escapeIntermediates:
                switch value {
                case 0x20...0x2F: break
                case 0x30...0x7E: state = .text
                default:
                    state = .text
                    handle(scalar)
                }
            case .sequence:
                if (0x40...0x7E).contains(value) { state = .text }
            case .string:
                if value == 0x07 { state = .text } else if value == 0x1B { state = .stringEscape }
            case .stringEscape:
                // `ESC \` ends the string; ESC and anything else starts another sequence.
                state = value == 0x5C ? .text : .escape
                if value != 0x5C { handle(scalar) }
            }
        }
        for scalar in scalars {
            handle(scalar)
        }
        return String(result)
    }
}

// MARK: - Tests

/// The tests a run published, added up across its test runs, and the first that failed.
public struct BuildTests: Sendable, Equatable {
    public var total: Int
    public var passed: Int
    public var failed: Int
    /// How many test runs it published.
    public var runs: Int
    /// The first tests that failed, from the first test runs with failures: at most
    /// `BuildInvestigationReader.failedTestsListed`.
    public var failures: [FailedTest]
    /// Whether the totals count all its test runs: not when it has more than `BuildInvestigationReader.testRunsCounted`,
    /// whose totals count that many.
    public var countsAllRuns: Bool

    public init(total: Int, passed: Int, failed: Int, runs: Int, failures: [FailedTest], countsAllRuns: Bool = true) {
        self.total = total
        self.passed = passed
        self.failed = failed
        self.runs = runs
        self.failures = failures
        self.countsAllRuns = countsAllRuns
    }

    /// Neither passed nor failed: skipped, not run, inconclusive…
    public var other: Int {
        max(0, total - passed - failed)
    }

    /// The tests that failed and aren't in `failures`.
    public var unlisted: Int {
        max(0, failed - failures.count)
    }

    /// Outcomes that count as failed.
    static let failedOutcomes = ["Failed", "Error", "Timeout", "Aborted"]

    init(runs: [ADOTestRun], failures: [FailedTest], countsAllRuns: Bool = true) {
        self.init(
            total: runs.reduce(0) { $0 + max(0, $1.totalTests ?? 0) }, passed: runs.reduce(0) { $0 + max(0, $1.passedTests ?? 0) },
            failed: runs.reduce(0) { $0 + Self.failed(in: $1) }, runs: runs.count, failures: failures, countsAllRuns: countsAllRuns
        )
    }

    /// The tests that failed in a test run: its count by outcome when it has one, or the failures nobody looked into.
    static func failed(in run: ADOTestRun) -> Int {
        let statistics = run.runStatistics?.elements ?? []
        guard !statistics.isEmpty else { return max(0, run.unanalyzedTests ?? 0) }
        return statistics
            .filter { statistic in failedOutcomes.contains { $0.caseInsensitiveCompare(statistic.outcome ?? "") == .orderedSame } }
            .reduce(0) { $0 + max(0, $1.count ?? 0) }
    }
}

/// A test that failed, with what it said.
public struct FailedTest: Sendable, Equatable, Identifiable {
    /// The most characters a message, and a stack trace, keep, and the most lines a stack trace does.
    public static let messageLimit = 2_000
    public static let stackTraceLimit = 3_000
    public static let stackTraceLines = 30

    /// Its test run's ID and its own: `1234/100001`.
    public var id: String
    /// Its short name: `EstimateSkipsWeekends`.
    public var name: String
    /// Its full name: `Storefront.Tests.DeliveryEstimateTests.EstimateSkipsWeekends`.
    public var fullName: String?
    /// Where it is, such as its assembly: `Storefront.Tests.dll`.
    public var container: String?
    /// Its test run's name.
    public var run: String?
    /// `Failed`, `Error`, `Timeout` or `Aborted`.
    public var outcome: String
    public var message: String?
    public var stackTrace: String?
    public var duration: TimeInterval?
    /// When it started failing, and in which run, when Azure DevOps knows.
    public var failingSince: Date?
    public var failingSinceBuildId: Int?

    public init(
        id: String, name: String, fullName: String? = nil, container: String? = nil, run: String? = nil, outcome: String = "Failed",
        message: String? = nil, stackTrace: String? = nil, duration: TimeInterval? = nil, failingSince: Date? = nil,
        failingSinceBuildId: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.container = container
        self.run = run
        self.outcome = outcome
        self.message = message
        self.stackTrace = stackTrace
        self.duration = duration
        self.failingSince = failingSince
        self.failingSinceBuildId = failingSinceBuildId
    }

    init(_ result: ADOTestResult, run: ADOTestRun) {
        let fullName = Self.text(result.automatedTestName).map(PlainText.singleLine)
        let title = Self.text(result.testCaseTitle).map(PlainText.singleLine)
        let short = fullName.map { name in
            // The method, after its namespace and class; a name with arguments keeps them.
            let head = name.split(separator: "(", maxSplits: 1).first.map(String.init) ?? name
            return head.split(separator: ".").last.map { String($0) + name.dropFirst(head.count) } ?? name
        }
        self.init(
            id: "\(run.id)/\(result.id)", name: title ?? short ?? "Test \(result.id)", fullName: fullName,
            container: Self.text(result.automatedTestStorage).map(PlainText.singleLine), run: Self.text(run.name).map(PlainText.singleLine),
            outcome: Self.text(result.outcome).map(PlainText.singleLine) ?? "Failed",
            message: Self.text(result.errorMessage).map { Self.cap(Self.lines($0), Self.messageLimit) },
            stackTrace: Self.text(result.stackTrace).map {
                Self.cap(Self.lines($0).split(separator: "\n", omittingEmptySubsequences: false).prefix(Self.stackTraceLines)
                    .joined(separator: "\n"), Self.stackTraceLimit)
            },
            duration: result.durationInMs.flatMap { $0 >= 0 ? $0 / 1_000 : nil },
            failingSince: result.failingSince?.date, failingSinceBuildId: result.failingSince?.build?.id
        )
    }

    /// The text, or nil when it's blank.
    private static func text(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// Lines ending with `\n` only, without trailing spaces, blank lines around them, or control characters but tabs.
    private static func lines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var line = PlainText.terminal(line)
                while line.last?.isWhitespace == true { line.removeLast() }
                return line
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    private static func cap(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

// MARK: - Is it this change?

/// A pull request's failed build compared with the pull request's latest commit, and with the pipeline's other runs, to
/// tell whether the failure is the change's doing: whether it built that commit, how the pipeline does on the target
/// branch, and whether it passed on the same commit before.
public struct BuildComparison: Sendable, Equatable {
    /// Whether it built the pull request's latest commit.
    public var revision: PullRequestPipelines.Revision
    /// The pull request's target branch, such as `main`.
    public var targetBranch: String
    /// The pipeline's latest run there that passed or failed; nil when it has none, or it couldn't be read.
    public var targetRun: PipelineRun?
    /// The latest of the pipeline's earlier runs on the pull request that passed on the same commit, one that built the
    /// very same code first; nil when none did, or they couldn't be read.
    public var earlierPass: EarlierPass?

    /// An earlier run of the pipeline on the pull request that passed on the same commit.
    public struct EarlierPass: Sendable, Equatable {
        public var run: PipelineRun
        /// It built the very same commit, such as the same merge of the pull request into its target branch, which makes
        /// a failure now look flaky. Otherwise it built the merge of the pull request's same commit before the target branch
        /// changed: the target's changes since may be why it fails now.
        public var builtTheSame: Bool

        public init(run: PipelineRun, builtTheSame: Bool) {
            self.run = run
            self.builtTheSame = builtTheSame
        }
    }

    public init(
        revision: PullRequestPipelines.Revision, targetBranch: String, targetRun: PipelineRun? = nil, earlierPass: EarlierPass? = nil
    ) {
        self.revision = revision
        self.targetBranch = targetBranch
        self.targetRun = targetRun
        self.earlierPass = earlierPass
    }

    /// What they say of `run`, the most telling first. Only a run that failed is asked whether the failure is the change's
    /// doing: of one running again, or that passed since, they say only whether it built the latest commit.
    public func hints(for run: PipelineRun) -> [BuildHint] {
        var hints: [BuildHint] = []
        if revision == .outdated { hints.append(.olderCommit) }
        guard run.status == .failed else { return hints }
        if let earlierPass {
            hints.append(earlierPass.builtTheSame
                ? .passedBefore(earlierPass.run) : .passedBeforeTargetChanged(branch: targetBranch, run: earlierPass.run))
        }
        if let targetRun {
            switch targetRun.status {
            case .failed: hints.append(.targetFails(branch: targetBranch, run: targetRun))
            case .succeeded, .partiallySucceeded: hints.append(.targetPasses(branch: targetBranch, run: targetRun))
            case .queued, .running, .canceled: break
            }
        }
        return hints
    }

    /// Whether a run passed, or failed: one that was canceled, or hasn't finished, says neither.
    static func hasVerdict(_ build: ADOBuild) -> Bool {
        build.status == "completed" && ["succeeded", "partiallySucceeded", "failed"].contains(build.result ?? "")
    }

    /// The latest of `runs`, the pipeline's on the pull request, that passed before `build` on the same commit, and whether
    /// it built the very same one: the latest that built the same commit as `build`, such as the same merge, or else the
    /// latest that built a merge of the pull request's same source commit.
    static func earlierPass(of build: ADOBuild, among runs: [ADOBuild]) -> (build: ADOBuild, builtTheSame: Bool)? {
        func same(_ one: String?, _ other: String?) -> Bool {
            guard let one, let other, !one.isEmpty else { return false }
            return one.caseInsensitiveCompare(other) == .orderedSame
        }
        func latest(_ runs: [ADOBuild]) -> ADOBuild? {
            runs.max { ($0.queueTime ?? .distantPast, $0.id) < ($1.queueTime ?? .distantPast, $1.id) }
        }
        let passed = runs.filter { run in
            run.id != build.id && run.definition.id == build.definition.id && run.result == "succeeded"
                && (build.sourceBranch == nil || run.sourceBranch == build.sourceBranch) && isEarlier(run, than: build)
        }
        if let run = latest(passed.filter({ same($0.sourceVersion, build.sourceVersion) })) { return (run, true) }
        if let run = latest(passed.filter({ same($0.triggerInfo?["pr.sourceSha"], build.triggerInfo?["pr.sourceSha"]) })) {
            return (run, false)
        }
        return nil
    }

    /// Queued before: by when they were queued, or by ID, which grows, when either doesn't say.
    private static func isEarlier(_ run: ADOBuild, than build: ADOBuild) -> Bool {
        if let queued = run.queueTime, let other = build.queueTime, queued != other { return queued < other }
        return run.id < build.id
    }
}

/// Something about a failed build that tells whether it's the change's doing.
public enum BuildHint: Sendable, Equatable {
    /// It built an older commit than the pull request's latest.
    case olderCommit
    /// It passed on the very same commit before: it may be flaky.
    case passedBefore(PipelineRun)
    /// It passed on the pull request's same commit before the target branch changed: the target's changes may be why.
    case passedBeforeTargetChanged(branch: String, run: PipelineRun)
    /// The pipeline's latest run on the target branch failed too: it may not be the change.
    case targetFails(branch: String, run: PipelineRun)
    /// The pipeline passes on the target branch.
    case targetPasses(branch: String, run: PipelineRun)

    /// It, in a sentence: “main's latest run failed too: it may not be this change.”
    public var sentence: String {
        switch self {
        case .olderCommit: "It built an older commit than the pull request's latest."
        case .passedBefore(let run): "It passed on the same commit in \(run.number): it may be flaky."
        case .passedBeforeTargetChanged(let branch, let run): "It passed on this commit in \(run.number), before \(branch) changed."
        case .targetFails(let branch, _): "\(branch)'s latest run failed too: it may not be this change."
        case .targetPasses(let branch, _): "\(branch)'s latest run passed."
        }
    }
}
