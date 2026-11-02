import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// A pull request's builds and status checks, in its details, what failed first: where each stands and since when, where a
/// build failed and its first error, whether it's optional, and ↗ to its run. A merged one's are the pipelines that ran
/// after it merged.
struct PullRequestChecksSection: View {
    let panel: PullRequestPanel
    /// The build or the check the details just went to, pointed out for a moment.
    let highlighted: PullRequestDetailsStore.Anchor?

    @EnvironmentObject private var store: PRStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PageSectionHeader(title: "Builds and Checks", count: panel.checks.isEmpty ? nil : panel.checks.count)
            if panel.checksUnknown {
                Label("Its project doesn't let you read its policies, so BriefBar can't tell how its builds and checks stand.",
                      systemImage: "lock")
                    .font(size: 12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if panel.checks.isEmpty {
                Text(panel.hasDetails ? "No builds or checks"
                    : panel.isClosed ? "BriefBar reads a pull request's builds and checks only while it's open."
                    : "BriefBar hasn't read its builds and checks.")
                    .font(size: 12.5)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(panel.checks.enumerated()), id: \.element.id) { index, line in
                        if index > 0 {
                            Divider()
                                .opacity(0.6)
                                .padding(.leading, 34)
                        }
                        // Its own, which no other row has, whatever their names.
                        let anchor = PullRequestDetailsStore.Anchor.check(line.id)
                        CheckRow(line: line, now: store.now, isHighlighted: highlighted == anchor)
                            .id(anchor)
                    }
                }
                .padding(.vertical, 3)
                .background(GlassCard(cornerRadius: 12, raised: true))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A build or a check: where it stands, as the Pipelines page draws it, and why it failed.
private struct CheckRow: View {
    let line: PullRequestPanel.CheckLine
    let now: Date
    let isHighlighted: Bool

    @LocalState private var isHovered = false

    private var run: ItemStory.Run { line.run }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(size: 12, weight: .semibold)
                .foregroundStyle(run.state?.color ?? .secondary)
                .frame(width: 16)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(run.name)
                        .font(size: 12.5, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !line.isRequired, line.check != nil {
                        Chip(text: "Optional")
                            .help("It doesn't hold the pull request up")
                    }
                }
                Text(status)
                    .font(size: 11.5)
                    .foregroundStyle(run.state == .failing ? AnyShapeStyle(ItemState.failing.textColor) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                if let detail = run.detail {
                    Text(detail)
                        .font(size: 11).monospaced()
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let url = run.url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(size: 11.5, weight: .medium)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Open \(run.name)'s run in Azure DevOps")
                .accessibilityLabel("Open its run in Azure DevOps")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(isHighlighted ? 0.14 : 0))
                .padding(.horizontal, 3)
        )
        .contextMenu {
            if let url = run.url {
                Button("Open Run in Azure DevOps") { NSWorkspace.shared.open(url) }
                Button("Copy Link") { PullRequestDetailsPanel.copy(url.absoluteString) }
            }
            Button("Copy Name") { PullRequestDetailsPanel.copy(run.name) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(run.name): \(status)" + (line.isRequired || line.check == nil ? "" : ", optional")
            + (run.detail.map { ". \($0)" } ?? ""))
    }

    /// "Failed at Run unit tests · 12m ago".
    private var status: String {
        guard let date = run.date, run.state != .running else { return run.status }
        return "\(run.status) · \(WorkItemDetailsPanel.ago(date, now: now))"
    }

    /// As the Pipelines page draws them.
    private var symbol: String {
        switch run.state {
        case .done?: "checkmark.circle.fill"
        case .failing?: "xmark.circle.fill"
        case .running?: "arrow.triangle.2.circlepath"
        case .needsYou?: "hand.raised.fill"
        case nil: run.status.hasPrefix("Waiting") ? "pause.circle" : "circle.dashed"
        }
    }
}
