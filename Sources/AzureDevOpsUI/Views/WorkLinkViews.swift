import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

extension PRKey {
    /// The pull request, for Show Links.
    var linkRef: ItemRef { .pullRequest(organization: organization, number: number) }
}

extension WorkItem {
    /// The work item, for Show Links.
    var linkRef: ItemRef { .workItem(organization: organization, id: id) }
}

/// A pull request's links on its row, but for the task Copilot is doing on it, which its own capsule shows.
struct PullRequestLinks: View {
    let key: PRKey
    var opensMenu = false

    @EnvironmentObject private var copilot: CopilotTasksStore

    var body: some View {
        LinkCapsules(key.linkRef, excluding: Self.session(of: copilot.isOn ? copilot.latest(forPullRequest: key) : nil), opensMenu: opensMenu)
    }

    static func session(of entry: CopilotTaskEntry?) -> Set<ItemRef> {
        entry.flatMap { ItemRef.session($0.id) }.map { [$0] } ?? []
    }
}

/// A work item's links, on its card or its line, but for its latest task sent to Copilot, and the pull request that task
/// opened, which the task's own capsule shows.
struct WorkItemLinks: View {
    let item: WorkItem
    var opensMenu = true

    @EnvironmentObject private var copilot: CopilotTasksStore

    var body: some View {
        LinkCapsules(item.linkRef, excluding: Self.shown(by: copilot.isOn ? copilot.latest(for: item) : nil), opensMenu: opensMenu)
    }

    /// What a task's capsule shows already: its session, and the pull request it opened once it's done.
    static func shown(by entry: CopilotTaskEntry?) -> Set<ItemRef> {
        guard let entry else { return [] }
        var shown = PullRequestLinks.session(of: entry)
        if entry.opensPullRequest, let opened = entry.pullRequest.flatMap({ ItemRef.from(link: $0.absoluteString) }) {
            shown.insert(opened)
        }
        return shown
    }
}
