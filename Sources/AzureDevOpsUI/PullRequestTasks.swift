import AzureDevOpsCore
import CopilotTasks
import Foundation

extension PullRequestAction {
    /// It takes care of the comments that wait on you: sending it takes them off Needs You. Fix Comments addresses them,
    /// and Push & Reply answers them.
    var takesCareOfComments: Bool { self == .fixComments || self == .pushAndReply }
}

/// What Copilot can do with a pull request, and the prompt that asks it to: for the pull requests' rows, and for agents
/// through `--mcp`.
enum PullRequestTasks {
    /// What Copilot can do with a pull request now. On yours: fix its unresolved comments, its failed build or its
    /// conflicts, and push and reply with what a finished task changed, in its session. On one you review: review it.
    /// - Parameter canShip: there are changes to push, such as those of a finished task.
    static func actions(for record: PRRecord, canShip: Bool) -> [PullRequestAction] {
        guard record.pullRequest.status == .active else { return [] }
        switch record.role {
        case .author:
            var actions: [PullRequestAction] = []
            if !PullRequestPrompt.waitingThreads(record).isEmpty { actions.append(.fixComments) }
            if !failedBuilds(record).isEmpty { actions.append(.fixBuild) }
            if record.pullRequest.hasConflicts { actions.append(.resolveConflicts) }
            if canShip { actions.append(.pushAndReply) }
            return actions
        case .reviewer, .linked:
            return [.review]
        }
    }

    /// The builds that failed and block it.
    static func failedBuilds(_ record: PRRecord) -> [Check] {
        (record.details?.checks ?? []).filter { $0.kind == .build && $0.state == .failed && $0.isBlocking }
    }

    /// The prompt for an action. For a failed build, each build's errors are read first, one GET each, with `client`;
    /// without one, it has only what BriefBar read already.
    static func prompt(
        _ action: PullRequestAction, for record: PRRecord, client: ADOClient?, workplace: PullRequestPrompt.Workplace = .worktree
    ) async -> String {
        let failures = action == .fixBuild ? await reports(for: record, client: client) : []
        return prompt(action, for: record, failures: failures, workplace: workplace)
    }

    /// The prompts for an action, for both places Copilot may work: a worktree of BriefBar's, for a new session or an
    /// earlier task's; and wherever a session that's there already works, such as one of the Copilot app's. A failed
    /// build's errors are read once, for both.
    static func prompts(_ action: PullRequestAction, for record: PRRecord, client: ADOClient?) async -> (worktree: String, session: String) {
        let failures = action == .fixBuild ? await reports(for: record, client: client) : []
        return (prompt(action, for: record, failures: failures, workplace: .worktree), prompt(action, for: record, failures: failures, workplace: .agent))
    }

    private static func prompt(
        _ action: PullRequestAction, for record: PRRecord, failures: [FailedBuildReport], workplace: PullRequestPrompt.Workplace
    ) -> String {
        switch action {
        case .fixComments: return PullRequestPrompt.fixComments(record, workplace: workplace)
        case .fixBuild: return PullRequestPrompt.fixBuild(record, failures: failures, workplace: workplace)
        case .resolveConflicts: return PullRequestPrompt.resolveConflicts(record, workplace: workplace)
        case .review: return PullRequestPrompt.review(record, workplace: workplace)
        case .pushAndReply: return PullRequestPrompt.pushAndReply(record, workplace: workplace)
        }
    }

    /// Where each failed build of a pull request failed, and its errors, from the runs' timelines.
    static func reports(for record: PRRecord, client: ADOClient?) async -> [FailedBuildReport] {
        let pr = record.pullRequest
        var reports: [FailedBuildReport] = []
        for check in failedBuilds(record) {
            guard let buildId = check.buildId else { continue }
            var failure = check.failure
            var errors = failure?.message.map { [$0] } ?? []
            if let client, let timeline = try? await client.get(
                ADOEndpoint.timeline(organization: pr.key.organization, projectId: pr.projectId, buildId: buildId), as: ADOTimeline.self
            ) {
                failure = failure ?? PipelineFailure.first(in: timeline)
                let all = PipelineFailure.errors(in: timeline)
                if !all.isEmpty { errors = all }
            }
            reports.append(FailedBuildReport(
                name: check.name, buildId: buildId,
                url: ADOEndpoint.buildPage(organization: pr.key.organization, project: pr.projectName, buildId: buildId),
                failure: failure, errors: errors
            ))
        }
        return reports
    }
}
