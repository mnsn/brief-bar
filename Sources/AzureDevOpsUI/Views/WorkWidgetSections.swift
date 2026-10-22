import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// The Sprint section's part of a desktop widget: your work in the current sprint, what's in progress first.
struct SprintWidgetSection: View {
    @EnvironmentObject private var sprint: SprintStore
    @EnvironmentObject private var store: PRStore
    let rows: Int
    /// In a widget, its header moves it; in a popover, it doesn't, and its title opens the Sprint page.
    var draggable = true

    private static let headerHeight: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .frame(height: Self.headerHeight)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture(), including: draggable ? .all : .subviews)
            content
                .frame(height: CGFloat(rows) * PRRowView.compactHeight, alignment: .top)
        }
        .frame(height: Self.height(rows: rows))
    }

    static func height(rows: Int) -> CGFloat {
        headerHeight + CGFloat(rows) * PRRowView.compactHeight
    }

    private var header: some View {
        HStack(spacing: 6) {
            PageLink(.azureDevOpsSprint, name: AzureDevOpsPage.sprint.title) {
                HStack(spacing: 6) {
                    Image(systemName: AzureDevOpsPage.sprint.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AzureDevOpsPage.sprint.color)
                    Text(sprint.board?.sprint.name ?? "Sprint")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let days = sprint.board?.sprint.daysLeft(now: store.now) {
                        Text(days == 1 ? "· last day" : "· \(days)d left")
                            .font(.system(size: 11))
                            .foregroundStyle(days <= 2 ? Color.orange : .secondary)
                            .fixedSize()
                    }
                }
            }
            if let problem = sprint.problem {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(problem.message)
            }
            Spacer(minLength: 4)
            if let board = sprint.board {
                let mine = board.myWork
                HStack(spacing: 8) {
                    chip(SprintBoard.Column.inProgress, mine.filter { $0.category.column == .inProgress }.count)
                    chip(SprintBoard.Column.toDo, mine.filter { $0.category.column == .toDo }.count)
                    chip(SprintBoard.Column.done, board.myDoneCount)
                }
                .help("Your work: in progress, to do and done")
            }
        }
    }

    private func chip(_ column: SprintBoard.Column, _ count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: column.symbol)
                .foregroundStyle(column.color)
            Text("\(count)")
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .semibold))
    }

    @ViewBuilder
    private var content: some View {
        let mine = sprint.board?.myWork ?? []
        if mine.isEmpty {
            WorkWidgetPlaceholder(text: sprint.board == nil
                ? (sprint.hasLoaded ? "No current sprint" : "Loading your sprint…")
                : "Nothing left for you in this sprint")
        } else {
            let visible = mine.count > rows ? Array(mine.prefix(rows - 1)) : mine
            VStack(spacing: 0) {
                ForEach(visible) { item in
                    WidgetWorkRow(item: item, parent: sprint.board?.rows.first { $0.tasks.contains(item) }?.parent) {
                        sprint.open(item)
                    }
                    .frame(height: PRRowView.compactHeight)
                }
                if mine.count > visible.count {
                    WorkWidgetMore(hidden: mine.count - visible.count)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
        }
    }
}

/// The Pipelines section's part of a desktop widget: each pinned pipeline's latest run.
struct PipelinesWidgetSection: View {
    @EnvironmentObject private var pipelines: PipelinesStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: PRStore
    let rows: Int
    /// In a widget, its header moves it; in a popover, it doesn't, and its title opens the Pipelines page.
    var draggable = true

    private static let headerHeight: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .frame(height: Self.headerHeight)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture(), including: draggable ? .all : .subviews)
            content
                .frame(height: CGFloat(rows) * PRRowView.compactHeight, alignment: .top)
        }
        .frame(height: Self.height(rows: rows))
    }

    static func height(rows: Int) -> CGFloat {
        headerHeight + CGFloat(rows) * PRRowView.compactHeight
    }

    private var header: some View {
        HStack(spacing: 6) {
            PageLink(.azureDevOpsPipelines, name: AzureDevOpsPage.pipelines.title) {
                HStack(spacing: 6) {
                    Image(systemName: AzureDevOpsPage.pipelines.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AzureDevOpsPage.pipelines.color)
                    Text(AzureDevOpsPage.pipelines.title)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            if let problem = pipelines.problem {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(problem.message)
            }
            Spacer()
            let counts = pipelines.counts
            HStack(spacing: 8) {
                if counts.failed > 0 { statusChip(.failed, counts.failed) }
                if counts.running > 0 { statusChip(.running, counts.running) }
                if counts.succeeded > 0 { statusChip(.succeeded, counts.succeeded) }
            }
        }
    }

    private func statusChip(_ status: PipelineRun.Status, _ count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: status == .running ? "arrow.triangle.2.circlepath.circle.fill" : status == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(status.color)
            Text("\(count)")
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .semibold))
        .help("\(count) \(status.title.lowercased())")
    }

    @ViewBuilder
    private var content: some View {
        let statuses = pipelines.statuses
        if statuses.isEmpty {
            WorkWidgetPlaceholder(text: settings.pinnedPipelines.isEmpty ? "Pin pipelines on the Pipelines page" : "Loading your pipelines…")
        } else {
            let visible = statuses.count > rows ? Array(statuses.prefix(rows - 1)) : statuses
            VStack(spacing: 0) {
                ForEach(visible) { status in
                    WidgetPipelineRow(status: status, now: store.now) {
                        if let latest = status.latest { pipelines.open(latest) } else { pipelines.open(status.pipeline) }
                    }
                    .frame(height: PRRowView.compactHeight)
                }
                if statuses.count > visible.count {
                    WorkWidgetMore(hidden: statuses.count - visible.count)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
        }
    }
}

private struct WorkWidgetPlaceholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WorkWidgetMore: View {
    let hidden: Int

    var body: some View {
        Text("+\(hidden) more")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 37)
            .padding(.top, 4)
    }
}

/// One of your tasks in the widget: its state, title and hours left, and the story it's for; and how its send to
/// Copilot stands, if you sent it.
private struct WidgetWorkRow: View {
    let item: WorkItem
    let parent: WorkItem?
    let action: () -> Void

    @EnvironmentObject private var copilot: CopilotTasksStore
    @LocalState private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: item.stateSymbol)
                    .font(.system(size: 15))
                    .foregroundStyle(item.stateColor)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if copilot.isOn, let entry = copilot.latest(for: item) {
                            let phase = entry.status.phase
                            Image(systemName: phase == .finished && entry.pullRequest != nil ? "arrow.triangle.pull" : phase.symbol)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(phase.color)
                                .help("Copilot: \(entry.sentence(now: Date()))")
                        }
                        if let remaining = item.remainingText {
                            Text(remaining)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                    Text([item.state, parent?.title].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(item.type) \(item.id): \(item.title)\nClick to open in Azure DevOps")
        .contextMenu {
            Button("Open in Azure DevOps", action: action)
            CopilotSendMenuItems(item: item)
        }
    }
}

/// A pinned pipeline in the widget, and in a list by state: how its latest run went, and its stages as dots.
struct WidgetPipelineRow: View {
    let status: PipelineStatus
    let now: Date
    let action: () -> Void

    @LocalState private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                RunStatusBadge(status: status.latest?.status, size: 17)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(status.pipeline.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Elapsed.short(since: status.latest?.changedAt, now: now))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    HStack(spacing: 6) {
                        Text(status.headline)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(status.headlineColor)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        HStack(spacing: 3) {
                            ForEach(status.stages.prefix(8)) { stage in
                                Circle()
                                    .fill(stage.state.color.opacity(stage.state == .pending || stage.state == .skipped ? 0.35 : 1))
                                    .frame(width: 6, height: 6)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(status.pipeline.name): \(status.headline)\nClick to open the latest run in Azure DevOps")
    }
}
