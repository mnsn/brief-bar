import BriefBarCore
import Foundation

/// The latest run of each pipeline validating one of your active pull requests.
public struct PullRequestPipelines: Sendable, Equatable, Identifiable {
    public enum Revision: Sendable, Equatable {
        case current, outdated, unknown
    }

    public var pullRequest: PullRequest
    public var pipelines: [PipelineStatus]
    public var revisions: [Int: Revision]
    public var hasLoaded: Bool

    public var id: PRKey { pullRequest.key }

    public init(pullRequest: PullRequest, pipelines: [PipelineStatus], revisions: [Int: Revision], hasLoaded: Bool = true) {
        self.pullRequest = pullRequest
        self.pipelines = pipelines
        self.revisions = revisions
        self.hasLoaded = hasLoaded
    }

    public init(pullRequest: PullRequest, builds: [ADOBuild]?, statuses: (PipelineRef, [PipelineRun]) -> PipelineStatus) {
        self.pullRequest = pullRequest
        hasLoaded = builds != nil
        let builds = (builds ?? []).filter { $0.sourceBranch == "refs/pull/\(pullRequest.key.number)/merge" }
        let groups = Dictionary(grouping: builds, by: \.definition.id)
        pipelines = groups.values.compactMap { builds in
            let sorted = builds.sorted { ($0.queueTime ?? .distantPast, $0.id) > ($1.queueTime ?? .distantPast, $1.id) }
            guard let latest = sorted.first else { return nil }
            let ref = PipelineRef(
                organization: pullRequest.key.organization, projectId: pullRequest.projectId, projectName: pullRequest.projectName,
                definitionId: latest.definition.id, name: PlainText.singleLine(latest.definition.name ?? "Pipeline \(latest.definition.id)"),
                folder: PipelineRef.folder(latest.definition.path)
            )
            return statuses(ref, sorted.map { PipelineRun(organization: ref.organization, projectName: ref.projectName, $0) })
        }.sorted { ($0.pipeline.name, $0.pipeline.definitionId) < ($1.pipeline.name, $1.pipeline.definitionId) }
        revisions = builds.reduce(into: [:]) { $0[$1.id] = Self.revision(of: $1, for: pullRequest) }
    }

    public var url: URL {
        ADOEndpoint.pullRequestPage(
            organization: pullRequest.key.organization, project: pullRequest.projectName,
            repository: pullRequest.repositoryName, id: pullRequest.key.number
        )
    }

    public func revision(of status: PipelineStatus) -> Revision {
        status.latest.flatMap { revisions[$0.id] } ?? .unknown
    }

    public var headline: String {
        guard hasLoaded else { return "Loading pipeline runs..." }
        guard !pipelines.isEmpty else { return "No pipeline runs yet" }
        let current = pipelines.filter { revision(of: $0) == .current }
        let counts = PipelineCounts(current)
        var parts: [String] = []
        if counts.failed > 0 { parts.append("\(counts.failed) failed") }
        if counts.running > 0 { parts.append("\(counts.running) running") }
        let passed = current.filter { $0.latest?.status == .succeeded }.count
        if passed > 0 { parts.append("\(passed) passed") }
        let warnings = current.filter { $0.latest?.status == .partiallySucceeded }.count
        if warnings > 0 { parts.append("\(warnings) succeeded with issues") }
        let canceled = current.filter { $0.latest?.status == .canceled }.count
        if canceled > 0 { parts.append("\(canceled) canceled") }
        let outdated = pipelines.filter { revision(of: $0) == .outdated }.count
        if outdated > 0 { parts.append("\(outdated) outdated") }
        let unknown = pipelines.filter { revision(of: $0) == .unknown }.count
        if unknown > 0 { parts.append("\(unknown) commit unverified") }
        return parts.joined(separator: " · ")
    }

    static func revision(of build: ADOBuild, for pr: PullRequest) -> Revision {
        if let source = build.triggerInfo?["pr.sourceSha"], let current = pr.sourceCommit,
           source.lowercased() != current.lowercased() { return .outdated }
        guard pr.mergeStatus == "succeeded" else { return .unknown }
        // PR validation builds normally build the synthetic merge commit, not the source branch's SHA.
        if let version = build.sourceVersion, let merge = pr.mergeCommit {
            return version.lowercased() == merge.lowercased() ? .current : .outdated
        }
        if let source = build.triggerInfo?["pr.sourceSha"], let current = pr.sourceCommit {
            return source.lowercased() == current.lowercased() ? .current : .outdated
        }
        return .unknown
    }
}
