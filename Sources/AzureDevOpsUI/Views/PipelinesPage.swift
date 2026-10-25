import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// The Pipelines section's page, in a window or a popover: the pipelines that ran after your merges, and the pipelines
/// you pinned, with their latest run's stages and their recent runs.
struct PipelinesPage: View {
    @EnvironmentObject private var pipelines: PipelinesStore
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var services: AppServices
    @Environment(\.panelStyle) private var panelStyle

    @LocalState private var isAdding = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Pipelines", subtitle: subtitle) {
                PageRefreshStatus(page: .pipelines)
                Button {
                    add()
                } label: {
                    Label("Add Pipeline", systemImage: "plus")
                }
                .glassButtonStyle()
                .help("Pin pipelines to follow here and in widgets")
            }
            if pipelines.statuses.isEmpty && pipelines.problem == nil && store.merges.isEmpty {
                if pipelines.hasLoaded || pipelines.settings.pinnedPipelines.isEmpty {
                    EmptyPage(symbol: "point.3.connected.trianglepath.dotted", title: "Follow your pipelines",
                              message: "Pin the pipelines you care about to see their latest runs, and each run's stages, here and in widgets.") {
                        Button("Add Pipeline…") { add() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading your pipelines…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                PageScroll {
                    VStack(alignment: .leading, spacing: 12) {
                        if let problem = pipelines.problem {
                            ProblemView(problem: problem) { store.signIn() }
                        }
                        if !store.merges.isEmpty {
                            PipelinesTitle(symbol: "arrow.triangle.merge", title: "After Your Merges", count: store.merges.count)
                            ForEach(store.merges) { merge in
                                MergeCard(merge: merge, now: store.now)
                            }
                            if !pipelines.statuses.isEmpty {
                                PipelinesTitle(symbol: "pin.fill", title: "Pinned", count: pipelines.statuses.count)
                                    .padding(.top, 6)
                            }
                        }
                        ForEach(pipelines.statuses) { status in
                            PipelineCard(status: status, now: store.now)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isAdding) {
            AddPipelineSheet()
        }
    }

    /// Searches for pipelines to pin, in a sheet: in a window, since a popover can't hold one.
    private func add() {
        if panelStyle == .page {
            isAdding = true
        } else {
            services.openWindow(.azureDevOpsPipelines)
        }
    }

    private var subtitle: String {
        let statuses = pipelines.statuses
        let merges = store.merges.count
        guard !statuses.isEmpty || merges > 0 else { return "Pipelines you pin, at a glance" }
        let counts = pipelines.counts
        var parts: [String] = []
        if merges > 0 { parts.append(merges == 1 ? "1 merge" : "\(merges) merges") }
        if !statuses.isEmpty { parts.append("\(statuses.count) pinned") }
        if counts.failed > 0 { parts.append("\(counts.failed) failed") }
        if counts.running > 0 { parts.append("\(counts.running) running") }
        return parts.joined(separator: " · ")
    }
}

/// A group's title on the page, with how many are in it.
private struct PipelinesTitle: View {
    let symbol: String
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The pipelines that ran after you merged a pull request: the pull request, then each pipeline's latest run, with
/// where it failed or what it waits for.
private struct MergeCard: View {
    let merge: MergePipelines
    let now: Date

    @EnvironmentObject private var pipelines: PipelinesStore
    @LocalState private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(color.gradient)
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(merge.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(meta)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if merge.isFollowing {
                    ProgressView().controlSize(.small)
                        .help("BriefBar is still looking for runs after this merge")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { AzureDevOps.open(merge.url) }
            .help("Click to open the pull request in Azure DevOps")
            VStack(spacing: 6) {
                ForEach(merge.pipelines) { status in
                    MergeRunRow(status: status, now: now)
                }
            }
        }
        .padding(14)
        .background(GlassCard(cornerRadius: 20, isHovered: isHovered))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open Pull Request") { AzureDevOps.open(merge.url) }
            ForEach(merge.pipelines) { status in
                if let run = status.latest {
                    Button("Open \(status.pipeline.name) \(run.number)") { pipelines.open(run) }
                }
            }
        }
    }

    /// "Merged into main · 25m ago · 2 of 3 passed"
    private var meta: String {
        var parts = ["Merged into \(merge.targetBranch)"]
        let elapsed = Elapsed.short(since: merge.mergedAt, now: now)
        parts.append(elapsed == "now" ? "just now" : "\(elapsed) ago")
        if let summary = merge.summary {
            switch summary.outcome {
            case .failed: parts.append("\(summary.pipeline ?? "A pipeline") failed")
            case .waiting: parts.append("waiting for approval")
            case .running: parts.append(summary.running == 1 ? "1 running" : "\(summary.running) running")
            case .passed: parts.append(summary.total == 1 ? "passed" : "all \(summary.total) passed")
            }
        }
        return parts.joined(separator: " · ")
    }

    private var color: Color {
        switch merge.summary?.outcome {
        case .failed?: return .red
        case .waiting?: return .orange
        case .running?: return .blue
        case .passed?: return .green
        case nil: return Color(nsColor: .systemGray)
        }
    }
}

/// One pipeline that ran after a merge: its latest run's result, what it's doing or how it ended, and where it failed.
private struct MergeRunRow: View {
    let status: PipelineStatus
    let now: Date

    @EnvironmentObject private var pipelines: PipelinesStore
    @LocalState private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                RunStatusBadge(status: status.latest?.status, size: 20)
                Text(status.pipeline.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(status.headline)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(status.headlineColor)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let run = status.latest {
                    HStack(spacing: 10) {
                        MetaItem(symbol: "number", text: run.number)
                        if let duration = run.duration(now: now) {
                            MetaItem(symbol: "timer", text: RunDuration.short(duration))
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            if let failure = status.failure, status.latest?.status == .failed {
                FailureNote(failure: failure)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            if let run = status.latest { pipelines.open(run) } else { pipelines.open(status.pipeline) }
        }
        .help("Click to open the run in Azure DevOps")
        .accessibilityElement(children: .combine)
    }
}

/// One pipeline: how its latest run went, its stages, where it failed, and its recent runs.
private struct PipelineCard: View {
    let status: PipelineStatus
    let now: Date

    @EnvironmentObject private var pipelines: PipelinesStore
    @LocalState private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RunStatusBadge(status: status.latest?.status, size: 34)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.pipeline.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        meta
                    }
                    Spacer(minLength: 8)
                    RunHistory(runs: status.runs, now: now) { pipelines.open($0) }
                    Menu {
                        menuItems
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Branch, order and more")
                }
                if !status.stages.isEmpty {
                    StageFlow(stages: status.stages, now: now)
                }
                if let failure = status.failure, status.latest?.status == .failed {
                    FailureNote(failure: failure)
                }
            }
        }
        .padding(14)
        .background(GlassCard(cornerRadius: 20, isHovered: isHovered))
        .contentShape(Rectangle())
        .onTapGesture {
            if let latest = status.latest { pipelines.open(latest) } else { pipelines.open(status.pipeline) }
        }
        .onHover { isHovered = $0 }
        .contextMenu { menuItems }
        .help("Click to open the latest run in Azure DevOps")
    }

    @ViewBuilder
    private var menuItems: some View {
        if let latest = status.latest {
            Button("Open Run \(latest.number)") { pipelines.open(latest) }
        }
        Button("Open Pipeline") { pipelines.open(status.pipeline) }
        Divider()
        Menu("Show Runs From") {
            Toggle("All Branches", isOn: Binding(
                get: { status.pipeline.branch == nil },
                set: { _ in pipelines.setBranch(nil, for: status.pipeline) }
            ))
            ForEach(branches, id: \.self) { branch in
                Toggle(branch, isOn: Binding(
                    get: { status.pipeline.branch == branch },
                    set: { _ in pipelines.setBranch(branch, for: status.pipeline) }
                ))
            }
        }
        Button("Move Up") { pipelines.move(status.pipeline, by: -1) }
        Button("Move Down") { pipelines.move(status.pipeline, by: 1) }
        Divider()
        Button("Unpin") { pipelines.unpin(status.pipeline) }
    }

    /// The branches its recent runs were for, not counting pull requests'.
    private var branches: [String] {
        var seen: [String] = []
        for branch in status.runs.map(\.branch) + [status.pipeline.branch].compactMap({ $0 })
        where !branch.isEmpty && !branch.hasPrefix("!") && !seen.contains(branch) {
            seen.append(branch)
        }
        return seen
    }

    /// "Failed in Test · 20261021.3 · main · Robin Diaz · 1h ago · 6m 12s"
    private var meta: some View {
        HStack(spacing: 10) {
            Text(status.headline)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(status.headlineColor)
            if let run = status.latest {
                HStack(spacing: 10) {
                    MetaItem(symbol: "number", text: run.number)
                    if !run.branch.isEmpty {
                        MetaItem(symbol: run.branch.hasPrefix("!") ? "arrow.triangle.pull" : "arrow.triangle.branch", text: run.branch)
                    }
                    if let who = run.requestedFor ?? (run.trigger == .schedule ? "Scheduled" : nil) {
                        MetaItem(symbol: run.trigger.symbol, text: who)
                    }
                    if let at = run.changedAt {
                        MetaItem(symbol: "clock", text: Elapsed.short(since: at, now: now) == "now" ? "now" : "\(Elapsed.short(since: at, now: now)) ago")
                    }
                    if let duration = run.duration(now: now) {
                        MetaItem(symbol: "timer", text: RunDuration.short(duration))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}

extension PipelineRun.Trigger {
    var symbol: String {
        switch self {
        case .manual: return "person.fill"
        case .push: return "arrow.up.circle"
        case .pullRequest: return "arrow.triangle.pull"
        case .schedule: return "calendar.badge.clock"
        case .pipeline: return "link"
        case .other: return "bolt.fill"
        }
    }
}

private struct MetaItem: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .medium))
            Text(text)
                .monospacedDigit()
        }
        .fixedSize()
    }
}

/// The latest run's result: a white symbol on a circle of its color.
struct RunStatusBadge: View {
    let status: PipelineRun.Status?
    var size: CGFloat = 34

    var body: some View {
        let color = status?.color ?? Color(nsColor: .systemGray)
        ZStack {
            Circle().fill(color.gradient)
            Image(systemName: status?.symbol ?? "questionmark")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(0.35), radius: 4, y: 1)
        .accessibilityLabel(status?.title ?? "No runs")
    }
}

/// The recent runs, oldest to newest: a bar each, as tall as it took and colored by how it ended.
private struct RunHistory: View {
    let runs: [PipelineRun]
    let now: Date
    let open: (PipelineRun) -> Void

    private static let height: CGFloat = 28

    var body: some View {
        let shown = Array(runs.prefix(12).reversed())
        let longest = max(shown.compactMap { $0.duration(now: now) }.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(shown) { run in
                let duration = run.duration(now: now) ?? 0
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(run.status.color.opacity(run.status == .canceled || run.status == .queued ? 0.45 : 0.9).gradient)
                    .frame(width: 7, height: max(7, Self.height * CGFloat(duration / longest)))
                    .help("\(run.number) · \(run.status.title) · \(run.branch) · \(Elapsed.short(since: run.changedAt, now: now)) ago")
                    .onTapGesture { open(run) }
            }
        }
        .frame(height: Self.height, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recent runs: " + shown.reversed().prefix(5).map(\.status.title).joined(separator: ", "))
    }
}

/// The latest run's stages, in order, joined by lines.
private struct StageFlow: View {
    let stages: [PipelineStage]
    let now: Date

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    if index > 0 {
                        Rectangle()
                            .fill(stages[index - 1].state == .succeeded ? Color.green.opacity(0.5) : Color.primary.opacity(0.15))
                            .frame(width: 14, height: 1.5)
                    }
                    StagePill(stage: stage, now: now)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

private struct StagePill: View {
    let stage: PipelineStage
    let now: Date

    var body: some View {
        let quiet = stage.state == .pending || stage.state == .skipped || stage.state == .canceled
        HStack(spacing: 5) {
            Image(systemName: stage.state.symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(stage.state.color)
            Text(stage.name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(quiet ? .secondary : .primary)
            if let duration {
                Text(duration)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(stage.state.color.opacity(quiet ? 0.07 : 0.13)))
        .overlay(Capsule().strokeBorder(stage.state.color.opacity(quiet ? 0.18 : 0.30), lineWidth: 1))
        .fixedSize()
        .help("\(stage.name): \(stage.state.title)")
    }

    private var duration: String? {
        guard let start = stage.startedAt else { return stage.state == .waiting ? "Waiting" : nil }
        return RunDuration.short((stage.finishedAt ?? now).timeIntervalSince(start))
    }
}

/// Where the latest run failed, and the first error there.
private struct FailureNote: View {
    let failure: PipelineFailure

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            (Text(failure.step).fontWeight(.semibold) + Text(failure.message.map { ": \($0)" } ?? " failed"))
                .font(.system(size: 11.5))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.08)))
    }
}

/// Finds pipelines in a project by name or number, or by a link to one or to one of its runs, to pin them.
private struct AddPipelineSheet: View {
    @EnvironmentObject private var pipelines: PipelinesStore
    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var sprint: SprintStore
    @Environment(\.dismiss) private var dismiss

    @LocalState private var project: ProjectRef?
    @LocalState private var suggested: [ProjectRef] = []
    @LocalState private var others: [ProjectRef] = []
    @LocalState private var text = ""
    @LocalState private var results: [PipelineRef] = []
    @LocalState private var isSearching = false
    @LocalState private var error: String?
    @LocalState private var pending: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Pipelines")
                        .font(.system(size: 20, weight: .bold))
                    Text("Pin the pipelines to follow in the window and the widget. Search by name or number, or paste a link to a pipeline or a run.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 8) {
                projectMenu
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search by name or number, or paste a link", text: $text)
                        .textFieldStyle(.plain)
                        .onSubmit { search(after: 0) }
                    if isSearching {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            }
            list
        }
        .padding(20)
        .frame(width: 580, height: 500)
        .task { await loadProjects() }
        .onChange(of: text) { search(after: 0.35) }
        .onChange(of: project) { search(after: 0) }
    }

    private var projectMenu: some View {
        Menu {
            if !suggested.isEmpty {
                Section("Yours") {
                    ForEach(suggested) { item in
                        Button(title(item)) { project = item }
                    }
                }
            }
            if !others.isEmpty {
                Menu("All Projects") {
                    ForEach(others) { item in
                        Button(title(item)) { project = item }
                    }
                }
            }
        } label: {
            Label(project.map(title) ?? "Choose a Project", systemImage: "folder")
        }
        .fixedSize()
        .help("The project to search in")
    }

    private func title(_ project: ProjectRef) -> String {
        store.organizations.count > 1 ? "\(project.name) (\(project.organization))" : project.name
    }

    @ViewBuilder
    private var list: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if project == nil && link == nil {
            Text("Choose a project to search in.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty && !isSearching {
            Text(link != nil ? "No pipeline at that link." : noResults)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(results) { result in
                        ResultRow(pipeline: result, isPinned: pipelines.isPinned(result)) {
                            if pipelines.isPinned(result) { pipelines.unpin(result) } else { pipelines.pin(result) }
                        }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.03)))
        }
    }

    private var noResults: String {
        if text.isEmpty { return "No pipelines in this project." }
        return PipelineSearch.number(in: text) == nil ? "No pipelines named like “\(text)”." : "No pipelines numbered or named like “\(text)”."
    }

    private func loadProjects() async {
        suggested = pipelines.suggestedProjects(pullRequests: store.items, teams: sprint.teams)
        if project == nil { project = suggested.first }
        let all = await pipelines.allProjects()
        others = all.filter { candidate in
            !suggested.contains { $0.organization == candidate.organization && $0.name.caseInsensitiveCompare(candidate.name) == .orderedSame }
        }
        if project == nil { project = others.first }
    }

    /// A link to a pipeline or a run, pasted in place of a name.
    private var link: PipelineLink? { PipelineLink(text) }

    /// Searches once typing stops for a moment: the project for a name, or the pipeline a link is to.
    private func search(after delay: Double) {
        pending?.cancel()
        let link = self.link
        guard link != nil || project != nil else { return }
        let text = self.text
        let project = self.project
        pending = Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
            }
            isSearching = true
            let result: Result<[PipelineRef], ADOError>
            if let link {
                result = await pipelines.pipeline(for: link).map { [$0] }
            } else if let project {
                result = await pipelines.search(text, in: project)
            } else {
                isSearching = false
                return
            }
            if Task.isCancelled { return }
            isSearching = false
            switch result {
            case .success(let found):
                results = found
                error = nil
            case .failure(.notFound) where link != nil, .failure(.forbidden) where link != nil:
                // Says there's no pipeline there, in the list.
                results = []
                error = nil
            case .failure(let failure):
                results = []
                error = failure.description
            }
        }
    }
}

private struct ResultRow: View {
    let pipeline: PipelineRef
    let isPinned: Bool
    let toggle: () -> Void

    @LocalState private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: AzureDevOpsPage.pipelines.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AzureDevOpsPage.pipelines.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(pipeline.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(details)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: toggle) {
                Label(isPinned ? "Pinned" : "Pin", systemImage: isPinned ? "pin.fill" : "pin")
                    .frame(minWidth: 64)
            }
            .buttonStyle(.bordered)
            .tint(isPinned ? .accentColor : nil)
            .help(isPinned ? "Unpin it" : "Follow it in the window and the widget")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(isHovered ? 0.05 : 0)))
        .onHover { isHovered = $0 }
    }

    /// Its number, which finds it too, and its folder.
    private var details: String {
        let number = "#\(pipeline.definitionId)"
        return pipeline.folder.isEmpty ? number : "\(number) · \(pipeline.folder.replacingOccurrences(of: "\\", with: " › "))"
    }
}
