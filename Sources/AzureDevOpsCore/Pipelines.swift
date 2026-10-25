import BriefBarCore
import Foundation

/// A pipeline you follow on the Pipelines page.
public struct PipelineRef: Sendable, Codable, Hashable, Identifiable {
    public var organization: String
    public var projectId: String
    public var projectName: String
    /// The build definition's ID.
    public var definitionId: Int
    public var name: String
    /// The folder it's in, without the leading backslash, such as `Storefront\CI`; empty at the top.
    public var folder: String
    /// Only runs of this branch (`main`), or every run when nil.
    public var branch: String?

    public init(
        organization: String, projectId: String, projectName: String, definitionId: Int, name: String, folder: String = "",
        branch: String? = nil
    ) {
        self.organization = organization
        self.projectId = projectId
        self.projectName = projectName
        self.definitionId = definitionId
        self.name = name
        self.folder = folder
        self.branch = branch
    }

    /// Nil when Azure DevOps didn't say which project it's in.
    public init?(organization: String, _ dto: ADOBuildDefinition) {
        guard let project = dto.project else { return nil }
        self.init(
            organization: organization, projectId: project.id, projectName: project.name, definitionId: dto.id,
            name: PlainText.singleLine(dto.name), folder: Self.folder(dto.path)
        )
    }

    public var id: String { "\(organization)/\(projectId)/\(definitionId)" }

    /// Its runs in Azure DevOps.
    public var webURL: URL {
        ADOEndpoint.url("https://dev.azure.com", [organization, projectName, "_build"], [("definitionId", String(definitionId))])
    }

    static func folder(_ path: String?) -> String {
        (path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
    }
}

/// One run of a pipeline.
public struct PipelineRun: Sendable, Codable, Equatable, Identifiable {
    public enum Status: String, Sendable, Codable {
        case queued, running, succeeded, partiallySucceeded, failed, canceled

        init(status: String?, result: String?) {
            switch status {
            case "completed":
                switch result {
                case "succeeded": self = .succeeded
                case "partiallySucceeded": self = .partiallySucceeded
                case "failed": self = .failed
                default: self = .canceled
                }
            case "inProgress", "cancelling": self = .running
            default: self = .queued
            }
        }

        public var isFinished: Bool {
            switch self {
            case .queued, .running: return false
            case .succeeded, .partiallySucceeded, .failed, .canceled: return true
            }
        }
    }

    /// What started it.
    public enum Trigger: String, Sendable, Codable {
        case manual, push, pullRequest, schedule, pipeline, other

        init(_ reason: String?) {
            switch reason {
            case "manual", "userCreated": self = .manual
            case "individualCI", "batchedCI": self = .push
            case "pullRequest", "validateShelveset": self = .pullRequest
            case "schedule": self = .schedule
            case "buildCompletion", "resourceTrigger", "triggered": self = .pipeline
            default: self = .other
            }
        }
    }

    public var id: Int
    public var organization: String
    public var projectName: String
    /// Its build number, such as `20261021.4`.
    public var number: String
    public var status: Status
    public var trigger: Trigger
    /// The branch, such as `main`, or `!123` for a pull request.
    public var branch: String
    /// Who started it, or whose push or pull request did.
    public var requestedFor: String?
    public var queuedAt: Date?
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: Int, organization: String, projectName: String, number: String, status: Status, trigger: Trigger, branch: String,
        requestedFor: String? = nil, queuedAt: Date? = nil, startedAt: Date? = nil, finishedAt: Date? = nil
    ) {
        self.id = id
        self.organization = organization
        self.projectName = projectName
        self.number = number
        self.status = status
        self.trigger = trigger
        self.branch = branch
        self.requestedFor = requestedFor
        self.queuedAt = queuedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public init(organization: String, projectName: String, _ dto: ADOBuild) {
        let requester = dto.requestedFor.map(Person.init)
        self.init(
            id: dto.id, organization: organization, projectName: dto.project?.name ?? projectName,
            number: dto.buildNumber ?? String(dto.id), status: Status(status: dto.status, result: dto.result),
            trigger: Trigger(dto.reason), branch: Self.branch(dto.sourceBranch),
            requestedFor: requester.flatMap { Self.isService($0) ? nil : $0.name },
            queuedAt: dto.queueTime, startedAt: dto.startTime, finishedAt: dto.finishTime
        )
    }

    /// Azure DevOps itself, a build service or a bot, rather than someone: scheduled runs are requested by
    /// `Microsoft.VisualStudio.Services.TFS`.
    static func isService(_ person: Person) -> Bool {
        let name = person.name
        return person.isBot || name.hasPrefix("Microsoft.VisualStudio.") || name.hasPrefix("Project Collection ")
            || !name.contains(" ") && name.contains(".")
    }

    /// `refs/heads/main` is `main`, and `refs/pull/123/merge` is `!123`.
    static func branch(_ ref: String?) -> String {
        guard let ref else { return "" }
        if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
        let parts = ref.split(separator: "/")
        if parts.count >= 3, parts[0] == "refs", parts[1] == "pull" { return "!\(parts[2])" }
        if ref.hasPrefix("refs/tags/") { return String(ref.dropFirst("refs/tags/".count)) }
        return ref
    }

    /// The run's page in Azure DevOps.
    public var webURL: URL {
        ADOEndpoint.url("https://dev.azure.com", [organization, projectName, "_build", "results"], [("buildId", String(id))])
    }

    /// How long it ran, or has been running.
    public func duration(now: Date) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }

    /// When it last changed: finished, started or queued.
    public var changedAt: Date? { finishedAt ?? startedAt ?? queuedAt }
}

/// A stage of a run, or a job for a pipeline without stages.
public struct PipelineStage: Sendable, Codable, Equatable, Identifiable {
    public enum State: String, Sendable, Codable {
        case pending
        /// Waiting for an approval or a check before it starts.
        case waiting
        case running, succeeded
        /// Succeeded with issues.
        case warning
        case failed, canceled, skipped
    }

    public var id: String
    public var name: String
    public var state: State
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(id: String, name: String, state: State, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// The run's stages in order, or its jobs when it has no stages of its own (a pipeline without stages has
    /// one hidden stage, `__default`).
    public static func stages(from timeline: ADOTimeline, runFinished: Bool) -> [PipelineStage] {
        let records = timeline.records.elements
        let stages = records.filter { $0.type == "Stage" }
        var chosen = stages
        if stages.isEmpty || stages.count == 1 && (stages[0].identifier == "__default" || stages[0].name == "__default") {
            let parent = stages.first?.id
            chosen = records.filter { $0.type == "Phase" && (parent == nil || $0.parentId == parent) }
            if chosen.isEmpty {
                chosen = records.filter { $0.type == "Job" }
            }
        }
        let waiting = Set(records.filter { $0.type == "Checkpoint" && $0.state == "inProgress" }.compactMap(\.parentId))
        return chosen
            .sorted { ($0.order ?? .max, $0.startTime ?? .distantFuture) < ($1.order ?? .max, $1.startTime ?? .distantFuture) }
            .map { record in
                PipelineStage(
                    id: record.id, name: PlainText.singleLine(record.name ?? record.identifier ?? "Stage"),
                    state: state(record, waiting: waiting.contains(record.id), runFinished: runFinished),
                    startedAt: record.startTime, finishedAt: record.finishTime
                )
            }
    }

    static func state(_ record: ADOTimeline.Record, waiting: Bool, runFinished: Bool) -> State {
        switch record.state {
        case "completed":
            switch record.result {
            case "succeeded": return .succeeded
            case "succeededWithIssues": return .warning
            case "failed": return .failed
            case "canceled", "abandoned": return .canceled
            default: return .skipped
            }
        case "inProgress":
            return waiting ? .waiting : .running
        default:
            if runFinished { return .skipped }
            return waiting ? .waiting : .pending
        }
    }
}

/// Where a run failed first, and the first error there.
public struct PipelineFailure: Sendable, Codable, Equatable {
    /// The stage it failed in, when the pipeline has stages.
    public var stage: String?
    /// The task (or job) that failed.
    public var step: String
    public var message: String?

    public init(stage: String?, step: String, message: String?) {
        self.stage = stage
        self.step = step
        self.message = message
    }

    /// The step and its first error: "Run unit tests: 2 tests failed in CheckoutTests.", or "Run unit tests failed".
    public var summary: String {
        message.map { "\(step): \($0)" } ?? "\(step) failed"
    }

    /// The earliest failed task, or job or stage when no task failed.
    public static func first(in timeline: ADOTimeline) -> PipelineFailure? {
        let records = timeline.records.elements
        let byId = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func earliest(_ type: String) -> ADOTimeline.Record? {
            records
                .filter { $0.type == type && $0.result == "failed" }
                .min { ($0.finishTime ?? .distantFuture, $0.order ?? .max) < ($1.finishTime ?? .distantFuture, $1.order ?? .max) }
        }
        guard let failed = earliest("Task") ?? earliest("Job") ?? earliest("Stage") else { return nil }
        var stage: String?
        var parent = failed.parentId.flatMap { byId[$0] }
        while let record = parent {
            if record.type == "Stage", record.identifier != "__default", record.name != "__default" {
                stage = record.name
            }
            parent = record.parentId.flatMap { byId[$0] }
        }
        let message = failed.issues?.elements.first { $0.type == "error" }?.message.map(Self.clean)
        let step = PlainText.singleLine(failed.name ?? "A step")
        return PipelineFailure(stage: stage.map(PlainText.singleLine), step: step, message: message?.isEmpty == false ? message : nil)
    }

    /// One line, without the log's `##[error]` prefix, at most 300 characters.
    static func clean(_ message: String) -> String {
        var text = PlainText.singleLine(message)
        if text.hasPrefix("##[error]") { text = String(text.dropFirst("##[error]".count)) }
        return text.count > 300 ? String(text.prefix(299)) + "…" : text
    }
}

/// A pipeline as the Pipelines page shows it: its recent runs, and the latest one's stages.
public struct PipelineStatus: Sendable, Equatable, Identifiable {
    public var pipeline: PipelineRef
    /// Newest first.
    public var runs: [PipelineRun]
    /// The latest run's stages; empty until its timeline has been read.
    public var stages: [PipelineStage]
    /// Where the latest run failed, when it did.
    public var failure: PipelineFailure?

    public init(pipeline: PipelineRef, runs: [PipelineRun], stages: [PipelineStage] = [], failure: PipelineFailure? = nil) {
        self.pipeline = pipeline
        self.runs = runs
        self.stages = stages
        self.failure = failure
    }

    public var id: String { pipeline.id }
    public var latest: PipelineRun? { runs.first }

    /// Its state, the same for every source, as `PipelineCounts` counts it: something's wrong when its latest run
    /// failed, and running while it runs or waits in the queue. One that succeeded, or was canceled, isn't in any.
    public var state: ItemState? {
        switch latest?.status {
        case .failed?: return .failing
        case .running?, .queued?: return .running
        default: return nil
        }
    }

    /// A brief's line: “shop-web CI” failed in Test.
    public var briefSentence: String {
        let headline = headline
        return "“\(pipeline.name)” \(headline.prefix(1).lowercased() + headline.dropFirst())."
    }

    /// The stage that's running, waiting, or failed first.
    public var currentStage: PipelineStage? {
        stages.first { $0.state == .running } ?? stages.first { $0.state == .waiting } ?? stages.first { $0.state == .failed }
    }

    /// What the latest run is doing, or how it ended: "Failed in Test", "Running Deploy to staging".
    public var headline: String {
        guard let latest else { return "No runs yet" }
        switch latest.status {
        case .queued: return "Queued"
        case .running:
            if let stage = stages.first(where: { $0.state == .running }) { return "Running \(stage.name)" }
            if let stage = stages.first(where: { $0.state == .waiting }) { return "Waiting for approval to \(stage.name)" }
            return "Running"
        case .succeeded: return "Succeeded"
        case .partiallySucceeded: return "Succeeded with issues"
        case .failed:
            if let stage = failure?.stage ?? stages.first(where: { $0.state == .failed })?.name { return "Failed in \(stage)" }
            return "Failed"
        case .canceled: return "Canceled"
        }
    }
}

/// Counts for the pinned pipelines' latest runs.
public struct PipelineCounts: Sendable, Equatable {
    public var failed = 0
    public var running = 0
    public var succeeded = 0

    public init(_ statuses: [PipelineStatus]) {
        for status in statuses {
            switch status.latest?.status {
            case .failed?: failed += 1
            case .running?, .queued?: running += 1
            case .succeeded?, .partiallySucceeded?: succeeded += 1
            default: break
            }
        }
    }

    /// By state, for an item that adds them up across sources: a failed pipeline is something wrong, and one
    /// that's running or queued is running. One that succeeded isn't counted.
    public var states: StateCounts { StateCounts(failing: failed, running: running) }
}

public enum RunDuration {
    /// `45s`, `6m 12s`, `1h 5m`.
    public static func short(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 {
            let rest = total % 60
            return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
        }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
    }
}
