import BriefBarCore
import Foundation

// What a pull request's details show of a build they look into (`BuildInvestigation`), in place, under its row: which
// builds can be looked into, the run's stages, where it failed or what it's doing, whether it's the change's doing, its
// tests and its log's end, and what couldn't be read.

extension PullRequestPanel {
    /// The build an item of what's left opens, as it takes you to the builds and checks: for builds that failed, the first
    /// required one that failed and can be looked into. Nil for anything else, such as builds that passed, run or expired, or
    /// a status check, which only take you there; and when no required build that failed can be looked into.
    public func build(openedBy item: PRReadiness.Item) -> CheckLine? {
        guard item.kind == .builds, item.state == .failing else { return nil }
        return checks.first { $0.isRequired && $0.canInvestigate && $0.run.state == .failing }
    }
}

extension PullRequestPanel.CheckLine {
    /// Whether the details can look into it: one of the pull request's builds, with a run, that failed or is still going.
    /// One that passed, expired or hasn't run has nothing to look into, and neither has a status check, which has no run;
    /// nor the pipelines after a merge, which built the target branch rather than the pull request.
    public var canInvestigate: Bool {
        guard let check, check.kind == .build, buildId != nil else { return false }
        switch check.state {
        case .failed, .running, .queued: return true
        case .passed, .expired, .notRun, .pending, .notApplicable: return false
        }
    }
}

extension BuildInvestigation {
    /// The most of its log's lines the details show at first: the rest of what was read shows when you ask.
    public static let logLinesShown = 20

    /// Its stages, or its jobs when it has none, as the Pipelines page draws a run's.
    public var stages: [PipelineStage] {
        steps.map { PipelineStage(id: $0.id, name: $0.name, state: $0.state, startedAt: $0.startedAt, finishedAt: $0.finishedAt) }
    }

    /// Where it failed first, by name, from the top: "Test", "Unit tests", "Run unit tests". A name isn't said twice in a
    /// row, as when a stage's only job has its name. From what its checks said (`failure`) when its steps don't say; empty
    /// when nothing failed.
    public var failurePlace: [String] {
        if let id = failedStepId {
            let path = path(to: id)
            if !path.isEmpty { return Self.names(path.map(\.name)) }
        }
        guard let failure else { return [] }
        return Self.names([failure.stage, failure.step].compactMap { $0 })
    }

    /// What it's doing while it's going: waiting in the queue, the steps that run now, from the top, or the stage that
    /// waits for an approval or a check before it starts. Nil once it finished.
    public var progress: Progress? {
        switch run.status {
        case .queued: return .queued
        case .running: break
        case .succeeded, .partiallySucceeded, .failed, .canceled: return nil
        }
        func running(_ steps: [BuildStep]) -> [BuildStep]? {
            for step in steps where step.state == .running {
                return [step] + (running(step.steps) ?? [])
            }
            return nil
        }
        if let path = running(steps) { return .running(Self.names(path.map(\.name))) }
        if let stage = steps.first(where: { $0.state == .waiting }) { return .waiting(stage.name) }
        return .running([])
    }

    /// What a run that's still going is doing.
    public enum Progress: Sendable, Equatable {
        /// It waits in the queue for an agent.
        case queued
        /// These steps run, from the top: its stage, job and task; none between two steps.
        case running([String])
        /// This stage waits for an approval or a check before it starts.
        case waiting(String)

        /// "Running Test › Unit tests › Run unit tests", "Waiting for approval to Production", "Queued: it hasn't started".
        public var sentence: String {
            switch self {
            case .queued: "Queued: it hasn't started"
            case .running(let place): place.isEmpty ? "Running" : "Running " + place.joined(separator: " › ")
            case .waiting(let stage): "Waiting for approval to \(stage)"
            }
        }
    }

    /// The step whose log's end `log` is.
    public var logStep: BuildStep? {
        log.flatMap { step($0.stepId) }
    }

    /// Its tests, on its run's page in Azure DevOps.
    public var testsPage: URL {
        ADOEndpoint.buildTestsPage(organization: run.organization, project: run.projectName, buildId: run.id)
    }

    /// What couldn't be read, in a sentence, for reading it again: "BriefBar couldn't read its log or main's latest runs.";
    /// nil when everything was.
    public var unreadSentence: String? {
        let parts = Part.allCases.filter { unread[$0] != nil }.map { part in
            switch part {
            case .steps: "all of its steps"
            case .log: "its log"
            case .tests: "all of its tests"
            case .targetBranch: "\(comparison.targetBranch)'s latest runs"
            case .earlierRuns: "its earlier runs"
            }
        }
        guard !parts.isEmpty else { return nil }
        return "BriefBar couldn't read \(Self.list(parts, joinedBy: "or"))."
    }

    /// Names without one said twice in a row.
    private static func names(_ names: [String]) -> [String] {
        names.reduce(into: []) { kept, name in
            if kept.last?.caseInsensitiveCompare(name) != .orderedSame { kept.append(name) }
        }
    }

    /// "a", "a or b", "a, b or c".
    private static func list(_ items: [String], joinedBy word: String) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " \(word) " + last
    }
}

extension BuildHint {
    /// The run it names, to go to: the earlier one that passed, or the target branch's latest; nil for one that names none.
    public var run: PipelineRun? {
        switch self {
        case .olderCommit: nil
        case .passedBefore(let run), .passedBeforeTargetChanged(_, let run), .targetFails(_, let run), .targetPasses(_, let run): run
        }
    }

    /// Its state, for its color: a run on an older commit, or one that passed on the same commit before, asks you to look
    /// again before you fix anything; the target branch failing too is failing, and passing, done.
    public var state: ItemState {
        switch self {
        case .olderCommit, .passedBefore, .passedBeforeTargetChanged: .needsYou
        case .targetFails: .failing
        case .targetPasses: .done
        }
    }
}

extension BuildTests {
    /// How its tests went, in a few words, after "Tests": "2 of 320 failed"; "None of 320 failed"; "None ran". When they
    /// couldn't all be added up, "At least 2 failed", or "320 counted, none failed".
    public var summary: String {
        guard failed > 0 else {
            if isComplete { return total > 0 ? "None of \(total) failed" : "None ran" }
            return total > 0 ? "\(total) counted, none failed" : "None counted"
        }
        guard isComplete else { return "At least \(failed) failed" }
        return total >= failed ? "\(failed) of \(total) failed" : "\(failed) failed"
    }
}

extension BuildIssue {
    /// Where it is in the code: "src/Cart.cs:41:5", "src/Cart.cs:41", "src/Cart.cs"; nil when it doesn't say.
    public var place: String? {
        guard let file, !file.isEmpty else { return nil }
        guard let line else { return file }
        return column.map { "\(file):\(line):\($0)" } ?? "\(file):\(line)"
    }

    /// What its message doesn't say of it: where it is, its code, and the step that logged it, unless that's the step that
    /// failed, whose error it is: "src/Cart.cs:41:5 · CS1002 · Build". Nil when there's nothing more to say.
    public func context(besides failedStepId: String?) -> String? {
        let said = [
            saysItsPlace ? nil : place,
            code.flatMap { Self.names(message, $0) ? nil : $0 },
            stepId == failedStepId ? nil : step,
        ].compactMap { $0 }
        return said.isEmpty ? nil : said.joined(separator: " · ")
    }

    /// Its message starts with where it is, as a compiler writes it: the same file and line, and column when it has one.
    /// Naming the file elsewhere doesn't say where in it.
    private var saysItsPlace: Bool {
        guard let file, let said = Self.place(in: message), said.file == file else { return false }
        guard let line else { return true }
        return said.line == line && (column == nil || said.column == column)
    }

    /// Whether a text names a code, such as `CS1002`, as a word of its own, rather than as part of another, such as
    /// `CS10021`.
    private static func names(_ text: String, _ code: String) -> Bool {
        guard !code.isEmpty else { return false }
        func isWordCharacter(_ character: Character?) -> Bool {
            character.map { $0.isLetter || $0.isNumber } ?? false
        }
        var rest = text.startIndex..<text.endIndex
        while let found = text.range(of: code, range: rest) {
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            if !isWordCharacter(before), !isWordCharacter(after) { return true }
            rest = found.upperBound..<text.endIndex
        }
        return false
    }
}

extension FailedTest {
    /// Its class or module, from its full name: `DeliveryEstimateTests`; nil when its full name doesn't say.
    public var suite: String? {
        guard let fullName else { return nil }
        // Before its arguments, which may have dots of their own.
        let head = fullName.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(fullName)
        let parts = head.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return String(parts[parts.count - 2])
    }

    /// How long it ran: "14 ms", "3s", "1m 5s"; nil when it isn't known.
    public var durationText: String? {
        guard let duration else { return nil }
        return duration < 1 ? "\(Int((duration * 1_000).rounded())) ms" : RunDuration.short(duration)
    }
}

extension BuildLog {
    /// Its last `count` lines.
    public func last(_ count: Int) -> [BuildLogLine] {
        Array(lines.suffix(max(0, count)))
    }

    /// How many of the log's lines were read, from `firstLine` to its end, the ends of groups among them.
    public var linesRead: Int {
        max(0, lineCount - firstLine + 1)
    }

    /// What of it shows, when its last `shown` lines do, counted as the log numbers them, the ends of groups among them:
    /// "The last 20 of its 2412 lines", "Its 12 lines", "It's empty".
    public func extent(showing shown: Int) -> String {
        guard lineCount > 0 else { return "It's empty" }
        let showing = min(max(0, shown), lines.count)
        guard showing > 0 else { return "None of its \(lineCount) lines can be shown" }
        if showing == lines.count, !isCut { return lineCount == 1 ? "Its only line" : "Its \(lineCount) lines" }
        let from = lines[lines.count - showing].number
        let count = max(1, lineCount - from + 1)
        return count == 1 ? "The last of its \(lineCount) lines" : "The last \(count) of its \(lineCount) lines"
    }
}

extension ADOEndpoint {
    /// A run's tests, on its page.
    public static func buildTestsPage(organization: String, project: String, buildId: Int) -> URL {
        url("https://dev.azure.com", [organization, project, "_build", "results"],
            [("buildId", String(buildId)), ("view", "ms.vss-test-web.build-test-results-tab")])
    }
}
