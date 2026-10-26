import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// The Sprint section's part of a desktop widget: your work in the current sprint, what's in progress first.
struct SprintWidgetSection: View {
    @EnvironmentObject private var sprint: SprintStore
    @EnvironmentObject private var store: PRStore
    let rows: Int
    @Environment(\.interfaceOptions) private var options
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
                .frame(height: CGFloat(rows) * options.compactRowHeight, alignment: .top)
        }
        .frame(height: Self.height(rows: rows, options: options))
    }

    static func height(rows: Int, options: InterfaceOptions = InterfaceOptions()) -> CGFloat {
        headerHeight + CGFloat(rows) * options.compactRowHeight
    }

    private var header: some View {
        HStack(spacing: 6) {
            PageLink(.azureDevOpsSprint, name: AzureDevOpsPage.sprint.title) {
                HStack(spacing: 6) {
                    Image(systemName: AzureDevOpsPage.sprint.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(options.quietAppearance ? Color.secondary : AzureDevOpsPage.sprint.color)
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
                if options.clearerStates {
                    Text("\(mine.count) left")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        chip(SprintBoard.Column.inProgress, mine.filter { $0.category.column == .inProgress }.count)
                        chip(SprintBoard.Column.toDo, mine.filter { $0.category.column == .toDo }.count)
                        chip(SprintBoard.Column.done, board.myDoneCount)
                    }
                    .help("Your work: in progress, to do and done")
                }
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
                    .frame(height: options.compactRowHeight)
                }
                if mine.count > visible.count {
                    WidgetMore(hidden: mine.count - visible.count, total: mine.count, section: .azureDevOpsSprint)
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
    @Environment(\.interfaceOptions) private var options
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
                .frame(height: CGFloat(rows) * options.compactRowHeight, alignment: .top)
        }
        .frame(height: Self.height(rows: rows, options: options))
    }

    static func height(rows: Int, options: InterfaceOptions = InterfaceOptions()) -> CGFloat {
        headerHeight + CGFloat(rows) * options.compactRowHeight
    }

    private var header: some View {
        HStack(spacing: 6) {
            PageLink(.azureDevOpsPipelines, name: AzureDevOpsPage.pipelines.title) {
                HStack(spacing: 6) {
                    Image(systemName: AzureDevOpsPage.pipelines.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(options.quietAppearance ? Color.secondary : AzureDevOpsPage.pipelines.color)
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
            if options.clearerStates {
                AttentionSummary(states: StateCounts(failing: counts.failed))
            } else {
                HStack(spacing: 8) {
                    if counts.failed > 0 { statusChip(.failed, counts.failed) }
                    if counts.running > 0 { statusChip(.running, counts.running) }
                    if counts.succeeded > 0 { statusChip(.succeeded, counts.succeeded) }
                }
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
                    .frame(height: options.compactRowHeight)
                }
                if statuses.count > visible.count {
                    WidgetMore(hidden: statuses.count - visible.count, total: statuses.count, section: .azureDevOpsPipelines)
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

/// One of your tasks in the widget: its state, title and hours left, and the story it's for; and how its send to
/// Copilot stands, if you sent it.
private struct WidgetWorkRow: View {
    let item: WorkItem
    let parent: WorkItem?
    let action: () -> Void

    @EnvironmentObject private var copilot: CopilotTasksStore
    @LocalState private var isHovered = false
    @Environment(\.interfaceOptions) private var options

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: options.readableRows ? 10 : 9) {
                Image(systemName: item.stateSymbol)
                    .font(.system(size: 15))
                    .foregroundStyle(item.stateColor)
                    .frame(width: options.rowIconWidth, height: 20)
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
                        .font(.system(size: options.rowDetailSize))
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
        .rowActions(for: item.title, openTitle: "Open in Azure DevOps", open: action) {
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
    @Environment(\.interfaceOptions) private var options

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: options.readableRows ? 10 : 9) {
                RunStatusBadge(status: status.latest?.status, size: 17)
                    .frame(width: options.rowIconWidth, height: 20)
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
                            .font(.system(size: options.rowDetailSize, weight: .medium))
                            .foregroundStyle(options.quietAppearance ? Color.secondary : status.headlineColor)
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
        .rowActions(for: status.pipeline.name, openTitle: "Open in Azure DevOps", open: action) { EmptyView() }
    }
}
