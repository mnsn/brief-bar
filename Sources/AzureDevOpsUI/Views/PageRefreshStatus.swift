import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// "Updated 2m ago" for an Azure DevOps page, a spinner while it refreshes, and a button to refresh it now.
struct PageRefreshStatus: View {
    let page: AzureDevOpsPage
    /// The sprint too, which My Work shows with your pull requests with + Sprint Tasks: it refreshes both, and says when the
    /// one read longer ago was.
    var withSprint = false
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var sprint: SprintStore
    @EnvironmentObject private var pipelines: PipelinesStore

    var body: some View {
        let (pageIsRefreshing, pageRefreshedAt): (Bool, Date?) = switch page {
        case .pullRequests: (store.isRefreshing, store.refreshedAt)
        case .sprint: (sprint.isRefreshing, sprint.refreshedAt)
        case .pipelines: (pipelines.isRefreshing, pipelines.refreshedAt)
        }
        let isRefreshing = pageIsRefreshing || withSprint && sprint.isRefreshing
        let refreshedAt = withSprint ? [pageRefreshedAt, sprint.refreshedAt].compactMap { $0 }.min() : pageRefreshedAt
        HStack(spacing: 6) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
            } else if let refreshedAt, store.mode == .live {
                let elapsed = Elapsed.short(since: refreshedAt, now: store.now)
                Text(elapsed == "now" ? "Updated now" : "Updated \(elapsed) ago")
                    .foregroundStyle(.secondary)
                    .font(size: 11)
            }
            if store.mode == .live {
                Button {
                    switch page {
                    case .pullRequests: store.refresh()
                    case .sprint: sprint.refresh()
                    case .pipelines: pipelines.refresh()
                    }
                    if withSprint, page != .sprint { sprint.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help("Refresh now")
            }
        }
    }
}
