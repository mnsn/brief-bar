import BriefBarCore
import Foundation

/// The pipelines that ran after you merged a pull request: its target branch's runs on its merge commit, and the runs
/// those started (pipeline-completion and resource triggers), and so on. Each pipeline's latest run is what counts: a
/// run that's retried, or queued again, replaces the one before.
public struct MergePipelines: Sendable, Equatable, Identifiable {
    public var pullRequest: PRKey
    public var title: String
    public var targetBranch: String
    public var mergedAt: Date
    /// The pull request's page.
    public var url: URL
    /// Each pipeline, its latest run first, in the order their first runs were queued.
    public var pipelines: [PipelineStatus]
    /// Still watched: runs may yet start, or some haven't finished.
    public var isFollowing: Bool

    public init(
        pullRequest: PRKey, title: String, targetBranch: String, mergedAt: Date, url: URL, pipelines: [PipelineStatus],
        isFollowing: Bool
    ) {
        self.pullRequest = pullRequest
        self.title = title
        self.targetBranch = targetBranch
        self.mergedAt = mergedAt
        self.url = url
        self.pipelines = pipelines
        self.isFollowing = isFollowing
    }

    public var id: String { pullRequest.description }

    /// How they stand together; nil until a run has been found.
    public var summary: MergeSummary? { MergeSummary(pipelines) }
}

/// How the pipelines after a merge stand together, for its pull request's row, its notifications and the brief.
public struct MergeSummary: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable {
        /// Some are queued or running, and none failed or waits.
        case running
        /// One waits for an approval or a check before a stage, and none failed.
        case waiting
        /// One's latest run failed.
        case failed
        /// They all finished, and none failed.
        case passed
    }

    public var outcome: Outcome
    /// How many pipelines ran.
    public var total: Int
    /// How many are queued or running.
    public var running: Int
    /// The pipeline that failed or waits.
    public var pipeline: String?
    /// The stage it waits for.
    public var stage: String?
    /// Where it failed, when its timeline says.
    public var failure: PipelineFailure?
    /// The run that failed or waits: a later one doing the same is news again.
    public var runId: Int?
    /// That run's page.
    public var runURL: URL?
    /// When it came to this: the run failed, or the last one finished.
    public var since: Date?

    public init(
        outcome: Outcome, total: Int, running: Int = 0, pipeline: String? = nil, stage: String? = nil, failure: PipelineFailure? = nil,
        runId: Int? = nil, runURL: URL? = nil, since: Date? = nil
    ) {
        self.outcome = outcome
        self.total = total
        self.running = running
        self.pipeline = pipeline
        self.stage = stage
        self.failure = failure
        self.runId = runId
        self.runURL = runURL
        self.since = since
    }

    /// Nil without any run. Something failed comes first, then something waiting, then something running.
    public init?(_ pipelines: [PipelineStatus]) {
        let latest = pipelines.compactMap { status in status.latest.map { (status, $0) } }
        guard !latest.isEmpty else { return nil }
        let running = latest.filter { !$0.1.status.isFinished }.count
        if let failed = latest.first(where: { $0.1.status == .failed }) {
            let (status, run) = failed
            self.init(outcome: .failed, total: latest.count, running: running, pipeline: status.pipeline.name,
                      stage: status.failure?.stage, failure: status.failure, runId: run.id, runURL: run.webURL, since: run.changedAt)
        } else if let waiting = latest.first(where: { !$0.1.status.isFinished && $0.0.stages.contains { $0.state == .waiting } }) {
            let (status, run) = waiting
            self.init(outcome: .waiting, total: latest.count, running: running, pipeline: status.pipeline.name,
                      stage: status.stages.first { $0.state == .waiting }?.name, runId: run.id, runURL: run.webURL,
                      since: run.startedAt ?? run.queuedAt)
        } else if running > 0 {
            self.init(outcome: .running, total: latest.count, running: running, since: latest.compactMap { $0.1.queuedAt }.max())
        } else {
            self.init(outcome: .passed, total: latest.count, since: latest.compactMap { $0.1.finishedAt }.max())
        }
    }
}

/// Finds a merge's runs among a branch's and a project's.
public enum MergeChain {
    /// How long after a merge runs may still start on it, such as a batched CI's.
    public static let startWindow: TimeInterval = 30 * 60
    /// How long after the last run finished a run it started may still show up.
    public static let triggerWindow: TimeInterval = 15 * 60
    /// Runs queued this long before the merge's time still count: its time and the runs' come from different clocks.
    public static let clockSlack: TimeInterval = 5 * 60

    /// The runs on the merge commit, except scheduled ones, which only happened to pick it up; then the runs they
    /// started, and the runs those started, and so on.
    public static func runs(onBranch: [ADOBuild], triggered: [ADOBuild], mergeCommit: String) -> [ADOBuild] {
        let commit = mergeCommit.lowercased()
        var chain = onBranch.filter { $0.sourceVersion?.lowercased() == commit && $0.reason != "schedule" }
        var ids = Set(chain.map(\.id))
        var added = true
        while added {
            added = false
            for build in triggered where !ids.contains(build.id) {
                guard let parent = build.triggeredByBuild?.id, ids.contains(parent) else { continue }
                chain.append(build)
                ids.insert(build.id)
                added = true
            }
        }
        return chain
    }

    /// Whether to keep looking for a merge's runs at `date`: right after it merged, while a run hasn't finished, and
    /// a little while after the last one finished.
    public static func isFollowing(mergedAt: Date, runs: [PipelineRun], at date: Date) -> Bool {
        if date.timeIntervalSince(mergedAt) < startWindow { return true }
        if runs.contains(where: { !$0.status.isFinished }) { return true }
        guard let last = runs.compactMap(\.finishedAt).max() else { return false }
        return date.timeIntervalSince(last) < triggerWindow
    }
}
