import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// "Updated 2m ago" for an Azure DevOps page, a spinner while it refreshes, and a button to refresh it now.
struct PageRefreshStatus: View {
    let page: AzureDevOpsPage
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var sprint: SprintStore
    @EnvironmentObject private var pipelines: PipelinesStore

    var body: some View {
        let (isRefreshing, refreshedAt): (Bool, Date?) = switch page {
        case .pullRequests: (store.isRefreshing, store.refreshedAt)
        case .sprint: (sprint.isRefreshing, sprint.refreshedAt)
        case .pipelines: (pipelines.isRefreshing, pipelines.refreshedAt)
        }
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
