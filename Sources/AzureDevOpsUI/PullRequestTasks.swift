import AzureDevOpsCore
import CopilotTasks
import Foundation

extension PullRequestAction {
    /// It takes care of the comments that wait on you: sending it takes them off Needs You. Fix Comments addresses them,
    /// and Push & Reply answers them.
    var takesCareOfComments: Bool { self == .fixComments || self == .pushAndReply }

    /// Whether, while it works, it's Copilot's turn at something that's left of a pull request rather than yours: Fix
    /// Comments at its comments, Fix the Build at its builds, Resolve Conflicts at its conflicts, and Push & Reply, which
    /// ships what one of those changed, at any of them.
    func takesCare(of kind: PRReadiness.Item.Kind) -> Bool {
        switch self {
        case .fixComments: kind == .comments
        case .fixBuild: kind == .builds
        case .resolveConflicts: kind == .conflicts
        case .pushAndReply: kind == .comments || kind == .builds || kind == .conflicts
        case .review: false
        }
    }

    /// What a Push & Reply that fixes the comments it takes on first is called: a comment's Fix, or Fix All, sent with Push
    /// and Reply on (`TakenPart.fixes`).
    static let fixPushAndReplyTitle = "Fix, Push & Reply"

    /// What it's called for a task that takes on `parts`, what it does: "Push" for a Push & Reply that replies on no thread,
    /// as one that ships a build's fix alone; "Fix, Push & Reply" for one that fixes them first; else its own title, "Push &
    /// Reply".
    func title(taking parts: [PullRequestPart], fixing: Bool = false) -> String {
        guard self == .pushAndReply else { return title }
        if fixing { return Self.fixPushAndReplyTitle }
        return parts.contains(where: { $0.thread != nil }) ? title : "Push"
    }

    /// What a task of it is called, as its run keeps what it takes on (`CopilotRun.taken`): "Push" for a Push & Reply that
    /// replies on no thread, "Fix, Push & Reply" for one that fixes them first. One that doesn't record what it takes on
    /// replies on the threads Fix Comments lists, as it did.
    func title(taken: [TakenPart]?) -> String {
        guard let taken else { return title }
        let current = taken.filter { $0.ended == nil }
        return title(taking: current.map(\.part), fixing: current.contains { $0.fixes == true })
    }
}

extension PRReadiness.Item.Kind {
    /// What's left that something of a pull request is: its comments, its builds or its conflicts.
    init(_ part: PullRequestPart) {
        switch part {
        case .thread: self = .comments
        case .build: self = .builds
        case .conflicts: self = .conflicts
        }
    }
}

extension CopilotTaskEntry {
    /// What's left of its pull request that it's at while it works, for What's Left to say Copilot's on it: the kinds of what
    /// it took on and isn't done with (`taken`), such as the threads and builds a Push & Reply ships, not those an earlier
    /// task in its session took on; for a task that doesn't record what it takes on, whatever its action takes care of.
    /// Nothing once it's over.
    var kindsAtWork: Set<PRReadiness.Item.Kind> {
        guard status.phase.isActive, let action, onPullRequest != nil else { return [] }
        guard let taken else { return Set([PRReadiness.Item.Kind.comments, .builds, .conflicts].filter(action.takesCare(of:))) }
        return Set(taken.filter { $0.ended == nil }.map { PRReadiness.Item.Kind($0.part) })
    }

    /// What it does, by name: its action's title, "Push" for a Push & Reply that replies on no thread, "Fix, Push & Reply"
    /// for one that fixes them first; nil for a work item's.
    var actionTitle: String? {
        action.map { $0.title(taken: taken) }
    }

    /// A Push & Reply that fixes the threads it took on first, as a comment's Fix, or Fix All, sent with Push and Reply on
    /// does (`TakenPart.fixes`).
    var fixesFirst: Bool {
        action == .pushAndReply && taken?.contains { $0.ended == nil && $0.fixes == true } == true
    }

    /// For one that fixes them first, the commit the pull request's branch was at as it was sent (`TakenPart.head`).
    var fixingHead: String? {
        guard action == .pushAndReply else { return nil }
        return taken?.first { $0.ended == nil && $0.fixes == true }?.head
    }

    /// A Push & Reply that replies on no thread, as one that ships a build's fix alone: it only pushes.
    var onlyPushes: Bool {
        action == .pushAndReply && !fixesFirst && actionTitle != action?.title
    }
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

    /// What a task takes on, as its prompt does, for each to say what became of it: Fix Comments the threads it lists, Fix
    /// the Build the builds that failed, Resolve Conflicts the conflicts, and Push & Reply what it ships, with the threads
    /// its prompt lists; a review, nothing.
    /// - Parameter shipping: for Push & Reply, what the fixes it ships took on, such as one session's: their threads, which
    ///   its prompt lists alone, none for a build's fix alone, and their builds and conflicts. Nil for the threads Fix
    ///   Comments lists, as agents' Push & Reply has it.
    static func parts(_ action: PullRequestAction, for record: PRRecord, shipping: [PullRequestPart]? = nil) -> [PullRequestPart] {
        switch action {
        case .fixComments:
            return PullRequestPrompt.waitingThreads(record).prefix(PullRequestPrompt.threadLimit).map { .thread($0.id) }
        case .fixBuild:
            return failedBuilds(record).compactMap(\.part)
        case .resolveConflicts:
            return [.conflicts]
        case .pushAndReply:
            let threads = PullRequestPrompt.shippedThreads(record, only: shippedThreads(shipping)).prefix(PullRequestPrompt.threadLimit)
            return threads.map { .thread($0.id) } + (shipping ?? []).filter { $0.thread == nil }
        case .review:
            return []
        }
    }

    /// The threads a Push & Reply of these fixes ships, which its prompt lists and replies on: theirs, none for a build's
    /// fix alone; nil, for those Fix Comments lists, without a scope.
    static func shippedThreads(_ shipping: [PullRequestPart]?) -> [Int]? {
        shipping?.compactMap(\.thread)
    }

    /// The pull request, as a task sent to Copilot knows it.
    static func task(for record: PRRecord) -> TaskPullRequest {
        let pr = record.pullRequest
        return TaskPullRequest(
            organization: pr.key.organization, project: pr.projectName, repository: pr.repositoryName, id: pr.key.number,
            title: pr.title, url: pr.webURL, sourceBranch: pr.sourceBranch, targetBranch: pr.targetBranch,
            projectId: pr.projectId, repositoryId: pr.repositoryId
        )
    }

    /// The prompt for an action. For a failed build, each build's errors are read first, one GET each, with `client`;
    /// without one, it has only what BriefBar read already.
    static func prompt(
        _ action: PullRequestAction, for record: PRRecord, client: ADOClient?, workplace: PullRequestPrompt.Workplace = .worktree
    ) async -> String {
        let failures = action == .fixBuild ? await reports(for: record, client: client) : []
        return prompt(action, for: record, failures: failures, workplace: workplace)
    }

    /// The prompt an agent gets for an action, as `pull_request_prompt` and `--wait` give it: written for wherever the
    /// agent works, and ending, as BriefBar's own do, by asking for the pull request's stage once it pushed, while Pull
    /// Request Order is on (`PromptTemplate.stageLine`), but for a review.
    static func agentPrompt(
        _ action: PullRequestAction, for record: PRRecord, client: ADOClient?, ordersPullRequests: Bool
    ) async -> String {
        let prompt = await prompt(action, for: record, client: client, workplace: .agent)
        return PromptTemplate.ending(prompt, asksForStage: ordersPullRequests && action.asksForStage)
    }

    /// The prompts for an action, for both places Copilot may work: a worktree of BriefBar's, for a new session or an
    /// earlier task's; and wherever a session that's there already works, such as one of the Copilot app's. A failed
    /// build's errors are read once, for both.
    /// - Parameters:
    ///   - threads: for Push & Reply, the threads the fixes it ships took on, which it replies on alone.
    ///   - investigations: what the pull request's details read of its builds, by run, which Fix the Build quotes.
    ///   - conflicts: for Resolve Conflicts, the files that conflict, as its details read them, which it lists.
    static func prompts(
        _ action: PullRequestAction, for record: PRRecord, client: ADOClient?, threads: [Int]? = nil,
        investigations: [Int: BuildInvestigation] = [:], conflicts: MergeConflicts? = nil
    ) async -> (worktree: String, session: String) {
        let failures = action == .fixBuild ? await reports(for: record, client: client, investigations: investigations) : []
        return (
            prompt(action, for: record, failures: failures, workplace: .worktree, threads: threads, conflicts: conflicts),
            prompt(action, for: record, failures: failures, workplace: .agent, threads: threads, conflicts: conflicts)
        )
    }

    private static func prompt(
        _ action: PullRequestAction, for record: PRRecord, failures: [FailedBuildReport], workplace: PullRequestPrompt.Workplace,
        threads: [Int]? = nil, conflicts: MergeConflicts? = nil
    ) -> String {
        switch action {
        case .fixComments: return PullRequestPrompt.fixComments(record, workplace: workplace)
        case .fixBuild: return PullRequestPrompt.fixBuild(record, failures: failures, workplace: workplace)
        case .resolveConflicts: return PullRequestPrompt.resolveConflicts(record, workplace: workplace, conflicts: conflicts)
        case .review: return PullRequestPrompt.review(record, workplace: workplace)
        case .pushAndReply: return PullRequestPrompt.pushAndReply(record, workplace: workplace, threads: threads)
        }
    }

    /// Where each failed build of a pull request failed, and its errors: as its details read it, once it was opened there
    /// (`BuildInvestigation`), with the tests that failed and the end of its log; else from the run's timeline, one GET each.
    /// - Parameter investigations: what the details read of its builds, by run.
    static func reports(
        for record: PRRecord, client: ADOClient?, investigations: [Int: BuildInvestigation] = [:]
    ) async -> [FailedBuildReport] {
        let pr = record.pullRequest
        var reports: [FailedBuildReport] = []
        for check in failedBuilds(record) {
            guard let buildId = check.buildId else { continue }
            if let investigation = investigations[buildId], investigation.run.id == buildId, investigation.run.status == .failed {
                reports.append(FailedBuildReport(investigation, name: check.name))
                continue
            }
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
