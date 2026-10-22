import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// The Sprint section's page, in a window or a popover: your team's current sprint at a glance, how far along it
/// is, then its stories and bugs, each with its tasks, by where they stand.
struct SprintPage: View {
    @EnvironmentObject private var sprint: SprintStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: PRStore

    @LocalState private var showDone = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: sprint.board?.sprint.name ?? "Sprint", subtitle: subtitle) {
                controls
            }
            content
        }
    }

    private var subtitle: String {
        guard let board = sprint.board else { return "Your team's current sprint" }
        var parts = [board.team.name]
        if let start = board.sprint.start, let finish = board.sprint.finish {
            parts.append(SprintDates.range(start, finish))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var controls: some View {
        PageRefreshStatus(page: .sprint)

        Picker("Show", selection: $settings.sprintJustMine) {
            Text("Everyone").tag(false)
            Text("Just Mine").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Just Mine: your stories and bugs with all their tasks, and your tasks in anyone else's")

        if !sprint.teams.isEmpty {
            Menu {
                ForEach(sprint.teams) { team in
                    Button {
                        sprint.choose(team)
                    } label: {
                        if team.id == sprint.board?.team.id {
                            Label("\(team.name) (\(team.projectName))", systemImage: "checkmark")
                        } else {
                            Text("\(team.name) (\(team.projectName))")
                        }
                    }
                }
            } label: {
                Label(sprint.board?.team.name ?? "Choose a Team", systemImage: "person.3.fill")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 190)
            }
            .menuStyle(.button)
            .glassButtonStyle()
            .fixedSize()
            .help("Choose the team whose sprint to show")
        }

        CopilotRunsMenu()

        Button {
            sprint.openBoard()
        } label: {
            Image(systemName: "arrow.up.forward.app")
        }
        .glassButtonStyle()
        .help("Open the sprint's task board in Azure DevOps")
        .disabled(sprint.board == nil)
    }

    @ViewBuilder
    private var content: some View {
        if let board = sprint.board, let shown = sprint.shownBoard {
            PageScroll {
                VStack(alignment: .leading, spacing: 22) {
                    if let problem = sprint.problem {
                        ProblemView(problem: problem) { store.signIn() }
                    }
                    SprintHero(board: shown, mine: board, sprint: board.sprint, now: store.now)
                    if shown.rows.isEmpty {
                        EmptyPage(symbol: "person.crop.circle.badge.checkmark", title: "Nothing of yours in this sprint",
                                  message: "None of its stories, bugs or tasks are assigned to you.") {
                            Button("Show Everyone's") { settings.sprintJustMine = false }
                        }
                    } else {
                        sections(shown)
                    }
                }
            }
        } else if let problem = sprint.problem {
            PageScroll {
                ProblemView(problem: problem) { store.signIn() }
            }
        } else if sprint.isRefreshing || !sprint.hasLoaded {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading your sprint…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyPage(symbol: "calendar.badge.exclamationmark", title: sprint.teams.isEmpty ? "No team to show" : "No current sprint",
                      message: sprint.teams.isEmpty
                        ? "You're not on a team in the organizations BriefBar watches."
                        : "This team has no sprint with today's date. Choose another team, or set up sprints in Azure DevOps.") {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func sections(_ board: SprintBoard) -> some View {
        let stories = board.rows.filter { $0.parent != nil }
        ForEach([SprintBoard.Column.inProgress, .toDo]) { column in
            let rows = stories.filter { $0.progress == column }
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(column: column, title: column == .inProgress ? "In Progress" : "Not Started", count: rows.count)
                    MasonryLayout(minColumnWidth: 330, spacing: 14) {
                        ForEach(rows) { row in
                            StoryCard(row: row, me: board.me) { sprint.open($0) }
                        }
                    }
                }
            }
        }
        if let loose = board.rows.first(where: { $0.parent == nil }) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(symbol: "tray.full.fill", color: .secondary, title: "Not in a Story", count: loose.tasks.count)
                MasonryLayout(minColumnWidth: 330, spacing: 14) {
                    StoryCard(row: loose, me: board.me) { sprint.open($0) }
                }
            }
        }
        let done = stories.filter { $0.progress == .done }
        if !done.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { showDone.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        SectionTitle(column: .done, title: "Done", count: done.count)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showDone ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showDone ? "Hide the stories that are done" : "Show the stories that are done")
                if showDone {
                    MasonryLayout(minColumnWidth: 330, spacing: 14) {
                        ForEach(done) { row in
                            StoryCard(row: row, me: board.me) { sprint.open($0) }
                        }
                    }
                } else {
                    DoneStrip(rows: done) { sprint.open($0) }
                }
            }
        }
    }
}

enum SprintDates {
    /// "Oct 12 – Oct 25", in UTC, where Azure DevOps keeps a sprint's days.
    static func range(_ start: Date, _ finish: Date) -> String {
        let style = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).day()
        return "\(start.formatted(style)) – \(finish.formatted(style))"
    }
}

private struct SectionTitle: View {
    var symbol: String
    var color: Color
    let title: String
    let count: Int

    init(column: SprintBoard.Column, title: String, count: Int) {
        symbol = column.symbol
        color = column.color
        self.title = title
        self.count = count
    }

    init(symbol: String, color: Color, title: String, count: Int) {
        self.symbol = symbol
        self.color = color
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
        .padding(.leading, 2)
    }
}

/// The sprint at a glance: how much is done, how much time is left, and where your own work stands.
private struct SprintHero: View {
    let board: SprintBoard
    /// The whole board, for your own counts whatever's shown.
    let mine: SprintBoard
    let sprint: Sprint
    let now: Date

    var body: some View {
        HStack(spacing: 0) {
            done
                .frame(maxWidth: .infinity, alignment: .leading)
            divider
            time
                .frame(maxWidth: .infinity, alignment: .leading)
            divider
            yours
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .background(GlassCard(cornerRadius: 20))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 52)
            .padding(.horizontal, 18)
    }

    private var done: some View {
        let total = board.tasks.count
        let doneCount = board.count(in: .done)
        let fraction = total == 0 ? 0 : Double(doneCount) / Double(total)
        return HStack(spacing: 14) {
            ProgressRing(value: fraction, colors: [Color(red: 0.20, green: 0.78, blue: 0.55), Color(red: 0.15, green: 0.68, blue: 0.35)]) {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(total == 0 ? "No tasks" : "\(doneCount) of \(total) \(total == 1 ? "task" : "tasks") done")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(board.count(in: .inProgress)) in progress · \(board.count(in: .toDo)) to do")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if board.remainingWork > 0 {
                    Text("\(Hours.text(board.remainingWork)) of work left")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var time: some View {
        let left = sprint.daysLeft(now: now)
        let urgent = (left ?? 99) <= 2
        return HStack(spacing: 14) {
            ProgressRing(
                value: sprint.elapsed(now: now) ?? 0,
                colors: urgent ? [.orange, Color(red: 0.95, green: 0.35, blue: 0.25)]
                    : [Color(red: 0.45, green: 0.50, blue: 1.0), Color(red: 0.30, green: 0.40, blue: 0.95)]
            ) {
                VStack(spacing: -2) {
                    Text(left.map(String.init) ?? "–")
                        .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                    Text(left == 1 ? "day" : "days")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(daysLeft(left))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(urgent ? Color.orange : .primary)
                if let day = sprint.day(now: now), let length = sprint.length {
                    Text("Day \(day) of \(length)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                if let start = sprint.start, let finish = sprint.finish {
                    Text(SprintDates.range(start, finish))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func daysLeft(_ days: Int?) -> String {
        guard let days else { return "No dates" }
        switch days {
        case 0: return "Sprint is over"
        case 1: return "Last day"
        default: return "\(days) days left"
        }
    }

    private var yours: some View {
        let work = mine.myWork
        let inProgress = work.filter { $0.category.column == .inProgress }.count
        let toDo = work.filter { $0.category.column == .toDo }.count
        let hours = work.compactMap(\.remainingWork).reduce(0, +)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Avatar(name: DisplayName.me(in: mine), size: 18, isMe: true)
                Text("Your work")
                    .font(.system(size: 13, weight: .semibold))
            }
            HStack(spacing: 14) {
                stat(.inProgress, inProgress)
                stat(.toDo, toDo)
                stat(.done, mine.myDoneCount)
            }
            if hours > 0 {
                Text("\(Hours.text(hours)) left for you")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ column: SprintBoard.Column, _ count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: column.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(column.color)
            Text("\(count)")
                .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
        }
        .help("\(count) \(column.title.lowercased())")
    }

}

enum DisplayName {
    /// Your name, from the work assigned to you.
    static func me(in board: SprintBoard) -> String? {
        (board.tasks + board.rows.compactMap(\.parent)).first { $0.isAssigned(to: board.me) }?.assignedTo?.name
    }
}

/// A story or bug: what it is, where it stands and who has it, how far along its tasks are, and the tasks.
private struct StoryCard: View {
    let row: SprintBoard.Row
    let me: String
    let open: (WorkItem) -> Void

    @LocalState private var isHovered = false
    @LocalState private var showAll = false

    private static let shownTasks = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !row.tasks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SegmentedProgress(
                        done: row.tasks(in: .done).count, inProgress: row.tasks(in: .inProgress).count, toDo: row.tasks(in: .toDo).count
                    )
                    HStack {
                        Text("\(row.doneCount) of \(row.tasks.count) \(row.tasks.count == 1 ? "task" : "tasks") done")
                        Spacer()
                        let hours = row.tasks.filter { !$0.isDone }.compactMap(\.remainingWork).reduce(0, +)
                        if hours > 0 {
                            Label(Hours.text(hours), systemImage: "clock")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                VStack(spacing: 1) {
                    let ordered = row.tasksInWorkOrder
                    let shown = showAll ? ordered : Array(ordered.prefix(Self.shownTasks))
                    ForEach(shown) { task in
                        TaskLine(task: task, isMine: task.isAssigned(to: me)) { open(task) }
                    }
                    if ordered.count > Self.shownTasks {
                        Button(showAll ? "Show Fewer" : "Show \(ordered.count - Self.shownTasks) More") {
                            withAnimation(.easeOut(duration: 0.15)) { showAll.toggle() }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, -6)
            } else if row.parent != nil {
                Text("No tasks yet")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(GlassCard(cornerRadius: 18, isHovered: isHovered))
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var header: some View {
        if let parent = row.parent {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    TypeBadge(item: parent, size: 20)
                    Text(String(parent.id))
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    CopilotTaskControl(item: parent, isHovered: isHovered)
                    Chip(text: parent.state, color: parent.stateColor)
                }
                Button { open(parent) } label: {
                    Text(parent.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(parent.isDone ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(parent.type) \(parent.id): \(parent.title)\nClick to open in Azure DevOps")
                .contextMenu {
                    Button("Open in Azure DevOps") { open(parent) }
                    CopilotSendMenuItems(item: parent)
                }
                HStack(spacing: 6) {
                    Avatar(name: parent.assignedTo?.name, size: 18, isMe: parent.isAssigned(to: me))
                    Text(parent.assignedTo?.name ?? "Unassigned")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text("Tasks without a story")
                    .font(.system(size: 14.5, weight: .semibold))
                Text("Their story isn't in this sprint, or they don't have one")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A task in its story's card: where it stands, what it is, the hours left and who has it; and, with Send Work to
/// Copilot on, a button that sends it to Copilot, or how its send stands.
private struct TaskLine: View {
    let task: WorkItem
    let isMine: Bool
    let open: () -> Void

    @EnvironmentObject private var copilot: CopilotTasksStore
    @LocalState private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: task.stateSymbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(task.stateColor)
                        .frame(width: 16)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    if task.type.lowercased() != "task" {
                        Image(systemName: task.typeSymbol)
                            .font(.system(size: 10))
                            .foregroundStyle(task.typeColor)
                            .help(task.type)
                    }
                    Text(task.title)
                        .font(.system(size: 12.5, weight: task.category.column == .inProgress ? .medium : .regular))
                        .foregroundStyle(task.isDone ? .secondary : .primary)
                        .strikethrough(task.isDone, color: .secondary.opacity(0.6))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let remaining = task.remainingText {
                        Text(remaining)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(task.type) \(task.id): \(task.title)\n\(task.state) · \(task.assignedTo?.name ?? "Unassigned")\nClick to open in Azure DevOps")
            .accessibilityLabel("\(task.title), \(task.state), \(task.assignedTo?.name ?? "unassigned")")
            let entry = copilot.isOn ? copilot.latest(for: task) : nil
            if let entry {
                CopilotRunBadge(entry: entry)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            // The send button takes the avatar's place while you point at the row, so nothing moves.
            let showsSend = copilot.isOn && entry == nil && isHovered
            ZStack {
                Avatar(name: task.assignedTo?.name, size: 18, isMe: isMine)
                    .opacity(showsSend ? 0 : 1)
                    .onTapGesture(perform: open)
                if showsSend {
                    CopilotSendButton(item: task)
                }
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open in Azure DevOps", action: open)
            CopilotSendMenuItems(item: task)
        }
    }
}

/// The stories that are done, while they're folded away: one line each.
private struct DoneStrip: View {
    let rows: [SprintBoard.Row]
    let open: (WorkItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if let parent = row.parent {
                    if index > 0 {
                        Divider().padding(.leading, 40)
                    }
                    Button { open(parent) } label: {
                        HStack(spacing: 9) {
                            TypeBadge(item: parent, size: 18)
                            Text(parent.title)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if !row.tasks.isEmpty {
                                Text("\(row.tasks.count) \(row.tasks.count == 1 ? "task" : "tasks")")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            Avatar(name: parent.assignedTo?.name, size: 18)
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(GlassCard(cornerRadius: 16))
    }
}

/// Cards in columns, each going in the shortest column so far: no gaps under short cards.
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat = 320
    var spacing: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minColumnWidth * 2 + spacing
        return CGSize(width: width, height: arrange(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let count = max(1, Int((width + spacing) / (minColumnWidth + spacing)))
        let columnWidth = (width - CGFloat(count - 1) * spacing) / CGFloat(count)
        var heights = Array(repeating: CGFloat(0), count: count)
        var frames: [CGRect] = []
        for subview in subviews {
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            frames.append(CGRect(x: CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth, height: height))
            heights[column] += height + spacing
        }
        return (frames, max(0, (heights.max() ?? 0) - spacing))
    }
}
