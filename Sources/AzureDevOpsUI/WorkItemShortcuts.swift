import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import Foundation

/// What a work item on the Sprint page opens a click away, from its menus and its details, as BriefBar knows it now, reading
/// nothing more for it: its Copilot sessions, each opened in Copilot, or, for a task BriefBar runs with the Copilot CLI, gone
/// on with in Terminal, as a pull request's session is (`SessionOpening`); and its pull requests, each shown over its details,
/// as Where It Stands shows them.
struct WorkItemShortcuts {
    /// The tasks you sent it to Copilot, the newest first, while Send Work to Copilot is on; then the other sessions Show
    /// Links links to it, directly or through one of its pull requests, the one that needs you most first: each as available
    /// as it is now (`CopilotTasksStore.availability`). BriefBar's tasks only while their worktrees are still there, as a
    /// pull request's are (`CopilotTasksStore.taskChoices(for:)`).
    var sessions: [SessionChoice]
    /// The pull requests Show Links links to it, the one that needs you most first.
    var pullRequests: [LinkedItem]

    @MainActor
    static func of(_ item: WorkItem, links: Links, copilot: CopilotTasksStore) -> WorkItemShortcuts {
        var sessions: [SessionChoice] = []
        var seen: Set<String> = []
        if copilot.isOn {
            for choice in copilot.taskChoices(for: .workItem(item.copilotTask)) where seen.insert(choice.id).inserted {
                sessions.append(choice)
            }
        }
        let connections = links.connections(of: item.linkRef)
        for connection in connections where connection.item.ref.kind == .session {
            let linked = connection.item
            guard seen.insert(linked.ref.id).inserted else { continue }
            if copilot.isOn, let entry = copilot.entries.first(where: { $0.id == linked.ref.id }), let run = entry.run, run.isValid {
                // A task BriefBar sent, such as one on its pull request: as the task, which goes on in Terminal when it runs with
                // the Copilot CLI, while its worktree is still there, as a pull request's tasks are. Once it's gone, Terminal
                // would have nowhere to go on with it, and it isn't one of the Copilot app's sessions either.
                guard FileManager.default.fileExists(atPath: run.worktree.path) else { continue }
                sessions.append(task(entry, run: run, reason: .linked, copilot: copilot))
            } else if linked.sent == nil {
                // One of the Copilot app's, or the Copilot CLI's, as Copilot's source tells it; not a task BriefBar sent that
                // hasn't started.
                let session = AppSession(
                    id: linked.ref.id, name: linked.label, branch: linked.hint?.branch,
                    isRunning: linked.state == .running || linked.state == .needsYou, lastActive: linked.date
                )
                sessions.append(SessionChoice(
                    kind: .app(session), name: linked.label, place: linked.place, lastActive: linked.date, reasons: [.linked]
                ))
            }
        }
        let pullRequests = connections.map(\.item).filter { $0.ref.kind.isPullRequest }
        return WorkItemShortcuts(sessions: copilot.availability(of: sessions), pullRequests: pullRequests)
    }

    /// A task BriefBar sent, as a session to open.
    @MainActor
    private static func task(
        _ entry: CopilotTaskEntry, run: CopilotRun, reason: SessionChoice.Reason, copilot: CopilotTasksStore
    ) -> SessionChoice {
        SessionChoice(
            kind: .task(run), name: copilot.name(of: entry), place: run.onPullRequest?.repository ?? run.repository.lastPathComponent,
            lastActive: entry.status.since ?? entry.startedAt, reasons: [reason], isBusy: entry.status.phase.isActive
        )
    }

    /// A session in Open in Copilot's menu, among two or more: its name, cut short, and how it stands, as its task or Copilot
    /// says: "‘Fix the coupon rounding’ — Working"; and, for one that goes on in Terminal, that it does.
    @MainActor
    static func title(of choice: SessionChoice, links: Links, copilot: CopilotTasksStore) -> String {
        let name = PullRequestSession.name(of: choice)
        // The app's sessions can have names a paragraph long.
        var title = "‘\(name.count > 60 ? String(name.prefix(59)) + "…" : name)’"
        let standing: String? = if let entry = copilot.entries.first(where: { $0.id == choice.id }) {
            entry.sentence(now: nil)
        } else {
            ItemRef.session(choice.id).flatMap { links.isDescribed($0) ? links.describe($0).status : nil }
        }
        if let standing, !standing.isEmpty { title += " — \(standing)" }
        if SessionOpening.way(of: choice) == .terminal { title += " (in Terminal)" }
        return title
    }

    /// A pull request in Show Pull Request's menu, among two or more: "!4091 · Round half up in the coupon service — Active".
    static func title(of pullRequest: LinkedItem) -> String {
        let name = pullRequest.label == pullRequest.title ? pullRequest.title : "\(pullRequest.label) · \(pullRequest.title)"
        return pullRequest.status.map { "\(name) — \($0)" } ?? name
    }

    /// Shows a pull request over the work item's details where there's somewhere to (`navigation`), as Where It Stands does;
    /// else in BriefBar's window, for one that shows there, such as one of yours; else where it lives.
    @MainActor
    static func show(_ pullRequest: LinkedItem, navigation: ItemNavigation?) {
        if navigation?.open(pullRequest.ref) == true { return }
        if pullRequest.show?() == true { return }
        pullRequest.open?()
    }
}
