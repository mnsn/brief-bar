import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// The Pipelines page: runs after your merges, pinned pipelines, and validation runs grouped by your active PRs.
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
            if pipelines.statuses.isEmpty && pipelines.pullRequests.isEmpty && pipelines.problem == nil && store.merges.isEmpty {
                if pipelines.hasLoaded || pipelines.settings.pinnedPipelines.isEmpty {
                    EmptyPage(symbol: "point.3.connected.trianglepath.dotted", title: "Follow your pipelines",
                              message: "Pin pipelines to follow their runs here and in widgets. Your active pull requests' pipelines also appear here, grouped by pull request.") {
                        Button("Add Pipeline…") { add() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading your pipelines…").font(style: .body).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                PageScroll {
                    VStack(alignment: .leading, spacing: 12) {
                        if let problem = pipelines.problem {
                            ProblemView(problem: problem) { store.signIn(for: problem) }
                        }
                        if !store.merges.isEmpty {
                            PipelinesTitle(symbol: "arrow.triangle.merge", title: "After Your Merges", count: store.merges.count)
                            ForEach(store.merges) { merge in
                                MergeCard(merge: merge, now: store.now)
                            }
                        }
                        if !pipelines.statuses.isEmpty && (!store.merges.isEmpty || !pipelines.pullRequests.isEmpty) {
                            PipelinesTitle(symbol: "pin.fill", title: "Pinned", count: pipelines.statuses.count)
                                .padding(.top, 6)
                        }
                        ForEach(pipelines.statuses) { status in
                            PipelineCard(status: status, now: store.now)
                        }
                        if !pipelines.pullRequests.isEmpty {
                            PipelinesTitle(symbol: "arrow.triangle.pull", title: "Your Pull Requests", count: pipelines.pullRequests.count)
                                .padding(.top, 6)
                            ForEach(pipelines.pullRequests) { pr in
                                PullRequestPipelinesCard(pullRequest: pr, now: store.now)
                            }
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
        let prs = pipelines.pullRequests.count
        guard !statuses.isEmpty || merges > 0 || prs > 0 else { return "Pinned pipelines and your pull requests" }
        let counts = pipelines.counts
        var parts: [String] = []
        if merges > 0 { parts.append(merges == 1 ? "1 merge" : "\(merges) merges") }
        if !statuses.isEmpty { parts.append("\(statuses.count) pinned") }
        if prs > 0 { parts.append(prs == 1 ? "1 pull request" : "\(prs) pull requests") }
        if counts.failed > 0 { parts.append("\(counts.failed) failed") }
        if counts.running > 0 { parts.append("\(counts.running) running") }
        return parts.joined(separator: " · ")
    }
}

/// One of your active pull requests, with the latest run of each pipeline that validates it. Its title shows its details on
/// the Pull Requests page, at the first run that failed, or else at its builds and checks; a run shows them at that run.
/// Without a window that has that page, they open in Azure DevOps.
private struct PullRequestPipelinesCard: View {
    let pullRequest: PullRequestPipelines
    let now: Date

    @EnvironmentObject private var details: PullRequestDetailsStore
    @EnvironmentObject private var pipelines: PipelinesStore
    @EnvironmentObject private var store: PRStore
    @LocalState private var isExpanded = false
    @LocalState private var isHovered = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if pullRequest.pipelines.isEmpty {
                    Text(pullRequest.headline)
                        .font(size: 12)
                        .foregroundStyle(.secondary)
                }
                ForEach(pullRequest.pipelines) { status in
                    VStack(alignment: .leading, spacing: 4) {
                        switch pullRequest.revision(of: status) {
                        case .outdated:
                            Label("Outdated - built an earlier commit", systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(.orange)
                        case .unknown:
                            Label("Commit not verified", systemImage: "questionmark.circle")
                                .foregroundStyle(.secondary)
                        case .current:
                            EmptyView()
                        }
                        MergeRunRow(status: status, now: now, opensDetails: canShow ? status.latest.map { run in { show(at: .run(run.id)) } } : nil)
                        if !status.stages.isEmpty {
                            StageFlow(stages: status.stages, now: now)
                        }
                    }
                    .font(size: 11)
                }
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    show(at: firstFailure.map { .run($0.id) } ?? .section(.checks))
                } label: {
                    Text(pullRequest.pullRequest.title)
                        .font(size: 14, weight: .semibold)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(canShow ? "Show its details, at its builds and checks" : "Open the pull request in Azure DevOps")
                Text("\(pullRequest.pullRequest.repositoryName) · !\(pullRequest.id.number) · \(pullRequest.headline)")
                    .font(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .background(GlassCard(cornerRadius: 20, isHovered: isHovered))
        .onHover { isHovered = $0 }
        .contextMenu {
            if canShow {
                Button("Show Details") { show(at: firstFailure.map { .run($0.id) } ?? .section(.checks)) }
            }
            Button("Open in Azure DevOps") { AzureDevOps.open(pullRequest.url) }
            if let run = firstFailure {
                Button("Open Run \(run.number) in Azure DevOps") { pipelines.open(run) }
            }
        }
    }

    /// Whether its details can show, on the Pull Requests page: while the list has it, which it does while it's open.
    private var canShow: Bool {
        details.hasPage() && store.items.contains { $0.key == pullRequest.id }
    }

    /// The latest run that failed, of a pipeline that built its latest commit, or of any.
    private var firstFailure: PipelineRun? {
        let failed = pullRequest.pipelines.compactMap(\.latest).filter { $0.status == .failed }
        return failed.first { run in pullRequest.revisions[run.id] == .current } ?? failed.first
    }

    /// Its details on the Pull Requests page, at a place in them, which sees it; Azure DevOps, which does too, when they
    /// can't show there.
    private func show(at place: PullRequestDetailsStore.Place) {
        if details.reveal(pullRequest.id, at: place) { return }
        AzureDevOps.open(pullRequest.url)
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
                .font(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(title)
                .font(size: 14, weight: .semibold)
            Text("\(count)")
                .font(size: 12, weight: .semibold).monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The pipelines that ran after you merged a pull request: the pull request, then each pipeline's latest run, with
/// where it failed or what it waits for. The pull request shows its details on the Pull Requests page, at the run that
/// failed or waits, while the list has it; each run opens in Azure DevOps.
private struct MergeCard: View {
    let merge: MergePipelines
    let now: Date

    @EnvironmentObject private var pipelines: PipelinesStore
    @EnvironmentObject private var details: PullRequestDetailsStore
    @EnvironmentObject private var store: PRStore
    @LocalState private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(color.gradient)
                    Image(systemName: "arrow.triangle.merge")
                        .font(size: 13, weight: .bold)
                        .foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(merge.title)
                        .font(size: 14, weight: .semibold)
                        .lineLimit(1)
                    Text(meta)
                        .font(size: 11)
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
            .onTapGesture(perform: show)
            .help(canShow ? "Click to see the pull request's details" : "Click to open the pull request in Azure DevOps")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(canShow ? "Shows the pull request's details" : "Opens the pull request in Azure DevOps")
            .accessibilityAction { show() }
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
            if canShow {
                Button("Show Details", action: show)
            }
            Button("Open in Azure DevOps") { AzureDevOps.open(merge.url) }
            ForEach(merge.pipelines) { status in
                if let run = status.latest {
                    Button("Open \(status.pipeline.name) \(run.number)") { pipelines.open(run) }
                }
            }
        }
    }

    /// Whether its details can show, on the Pull Requests page: while the list has it, which Done does for a while.
    private var canShow: Bool {
        details.hasPage() && store.items.contains { $0.key == merge.pullRequest }
    }

    /// Its details, at the run that failed, waits or was canceled, or else at their top; Azure DevOps when they can't show.
    private func show() {
        if details.reveal(merge.pullRequest, at: merge.summary?.runId.map { .run($0) }) { return }
        AzureDevOps.open(merge.url)
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
            case .canceled: parts.append("\(summary.pipeline ?? "A pipeline") was canceled")
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
        case .canceled?, nil: return Color(nsColor: .systemGray)
        }
    }
}

/// One pipeline that ran after a merge, or that validates a pull request: its latest run's result, what it's doing or how
/// it ended, and where it failed. A click opens the run in Azure DevOps, or, for a pull request's, shows that run in its
/// details.
private struct MergeRunRow: View {
    let status: PipelineStatus
    let now: Date
    /// Shows the run in its pull request's details, which a click does then; nil where a click opens it in Azure DevOps.
    var opensDetails: (() -> Void)? = nil

    @EnvironmentObject private var pipelines: PipelinesStore
    @LocalState private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                RunStatusBadge(status: status.latest?.status, size: 20)
                Text(status.pipeline.name)
                    .font(size: 12.5, weight: .semibold)
                    .lineLimit(1)
                Text(status.headline)
                    .font(size: 12, weight: .medium)
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
                    .font(size: 11)
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
        .onTapGesture(perform: opensDetails ?? openRun)
        .help(opensDetails == nil ? "Click to open the run in Azure DevOps" : "Click to see the run in the pull request's details")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(opensDetails == nil ? "Opens the run in Azure DevOps" : "Shows the run in the pull request's details")
        .accessibilityAction { (opensDetails ?? openRun)() }
        .accessibilityActions {
            if opensDetails != nil {
                Button("Open in Azure DevOps", action: openRun)
            }
        }
        // Right-clicking it, rather than its card, which names only the run that failed first.
        .modifier(RunMenu(showDetails: opensDetails, openTitle: openTitle, openRun: openRun))
        .rowActions(for: status.pipeline.name, openTitle: opensDetails == nil ? "Open in Azure DevOps" : "Show Details",
                    open: opensDetails ?? openRun) {
            if opensDetails != nil {
                Button("Open in Azure DevOps", action: openRun)
            }
        }
    }

    /// "Open Run 20261025.2 in Azure DevOps".
    private var openTitle: String {
        status.latest.map { "Open Run \($0.number) in Azure DevOps" } ?? "Open in Azure DevOps"
    }

    private func openRun() {
        if let run = status.latest { pipelines.open(run) } else { pipelines.open(status.pipeline) }
    }
}

/// A pull request's run's own menu, where a click shows it in the pull request's details: that, and opening the run in
/// Azure DevOps. A run after a merge, which a click opens, keeps its card's menu.
private struct RunMenu: ViewModifier {
    let showDetails: (() -> Void)?
    let openTitle: String
    let openRun: () -> Void

    func body(content: Content) -> some View {
        if let showDetails {
            content.contextMenu {
                Button("Show Details", action: showDetails)
                Button(openTitle, action: openRun)
            }
        } else {
            content
        }
    }
}

/// One pipeline: how its latest run went, its stages, where it failed, and its recent runs.
private struct PipelineCard: View {
    let status: PipelineStatus
    let now: Date

    @EnvironmentObject private var pipelines: PipelinesStore
    @LocalState private var isHovered = false
    @Environment(\.interfaceOptions) private var options
    @Environment(\.textScale) private var textScale

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RunStatusBadge(status: status.latest?.status, size: 34)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.pipeline.name)
                            .font(size: 14, weight: .semibold)
                            .lineLimit(1)
                        meta
                    }
                    Spacer(minLength: 8)
                    RunHistory(runs: status.runs, now: now) { pipelines.open($0) }
                    Menu {
                        menuItems
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(size: 14)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: options.visibleActions ? 28 : nil, minHeight: options.visibleActions ? 28 : nil)
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

    /// "Failed in Test · 20261021.3 · main · Robin Diaz · 1h ago · 6m 12s": the run's details beside the headline, or under
    /// it, on as many lines as they need, when they'd leave it too little room, as bigger text can.
    private var meta: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                // With less room, it would wrap a few letters at a time.
                headline
                    .frame(idealWidth: 80 * textScale)
                if let run = status.latest {
                    HStack(spacing: 10) {
                        details(of: run)
                    }
                    .font(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                headline
                if let run = status.latest {
                    FlowLayout(spacing: 10, lineSpacing: 3) {
                        details(of: run)
                    }
                    .font(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
        }
    }

    private var headline: some View {
        Text(status.headline)
            .font(size: 12, weight: .semibold)
            .foregroundStyle(status.headlineColor)
    }

    @ViewBuilder
    private func details(of run: PipelineRun) -> some View {
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
                .font(size: 9.5, weight: .medium)
            Text(text)
                .monospacedDigit()
        }
        .fixedSize()
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
    /// When signing in fixes it, in an organization's directory or to the Azure CLI: a way to.
    @LocalState private var signInProblem: PulseProblem?
    /// When some organizations' projects couldn't be listed for want of a sign-in to their directory.
    @LocalState private var projectsProblem: PulseProblem?
    @LocalState private var pending: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Pipelines")
                        .font(size: 20, weight: .bold)
                    Text("Pin the pipelines to follow in the window and the widget. Search by name or number, or paste a link to a pipeline or a run.")
                        .font(size: 12)
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
            if let projectsProblem {
                // Some organizations' projects aren't in the menu, whichever project is chosen: they wait on a sign-in to
                // their directory.
                HStack(spacing: 8) {
                    Label(projectsProblem.message, systemImage: "exclamationmark.triangle")
                        .font(size: 11.5)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Sign In…") { store.signIn(for: projectsProblem) }
                    Button("Try Again") { Task { await loadProjects() } }
                }
                .controlSize(.small)
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
            VStack(spacing: 10) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(style: .body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let signInProblem {
                        Button(signInProblem == .cliNotFound ? "Install the Azure CLI…" : "Sign In…") { store.signIn(for: signInProblem) }
                            .buttonStyle(.borderedProminent)
                    }
                    // Once signed in there, or back online, the projects and the same search again.
                    Button("Try Again") {
                        Task {
                            await loadProjects()
                            search(after: 0)
                        }
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if project == nil && link == nil {
            Text("Choose a project to search in.")
                .font(style: .body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty && !isSearching {
            Text(link != nil ? "No pipeline at that link." : noResults)
                .font(style: .body)
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
        let (all, problem) = await pipelines.allProjects()
        projectsProblem = problem
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
                signInProblem = nil
            case .failure(.notFound) where link != nil, .failure(.forbidden) where link != nil:
                // Says there's no pipeline there, in the list.
                results = []
                error = nil
                signInProblem = nil
            case .failure(let failure):
                results = []
                // One that signing in fixes comes with a way to: one in a directory to sign in to names its
                // organization, and your own directory wanting you to sign in again signs in there.
                let problem = PulseProblem.from(failure)
                signInProblem = problem.offersSignIn ? problem : nil
                error = PulseProblem.isOtherDirectory(failure) ? problem.message : failure.description
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
                .font(size: 12, weight: .semibold)
                .foregroundStyle(AzureDevOpsPage.pipelines.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(pipeline.name)
                    .font(size: 13, weight: .medium)
                    .lineLimit(1)
                Text(details)
                    .font(size: 11)
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
