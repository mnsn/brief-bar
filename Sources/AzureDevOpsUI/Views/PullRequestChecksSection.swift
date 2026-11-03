import AppKit
import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import SwiftUI

/// A pull request's builds and status checks, in its details, what failed first: where each stands and since when, where a
/// build failed and its first error, whether it's optional, what Copilot does about it, and ↗ to its run. A build that
/// failed, or is still going, opens under its row, to find out why without leaving BriefBar (`BuildInvestigationView`),
/// and to ask Copilot about it. A merged one's are the pipelines that ran after it merged.
struct PullRequestChecksSection: View {
    let item: PRSnapshot
    /// What the list read of it: a build is read, to open it, in its project.
    let pullRequest: PullRequest?
    let panel: PullRequestPanel
    /// Where the details are asked to go: a build there opens.
    let place: PullRequestDetailsStore.Place?
    /// The build or the check the details just went to, pointed out for a moment.
    let highlighted: PullRequestDetailsStore.Anchor?
    /// The composer in place that's open in the details, one at a time in them, so Esc, Return and the keyboard's focus are
    /// its own; and what you wrote in each.
    @Binding var composing: CopilotComposing?
    let drafts: CopilotDrafts

    @EnvironmentObject private var store: PRStore
    @EnvironmentObject private var investigations: BuildInvestigationStore

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
                        CheckRow(
                            line: line, item: item, pullRequest: pullRequest, now: store.now, isHighlighted: highlighted == anchor,
                            composing: $composing, drafts: drafts
                        )
                        .id(anchor)
                    }
                }
                .padding(.vertical, 3)
                .background(GlassCard(cornerRadius: 12, raised: true))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: place, initial: true) { open(place) }
        // A run that isn't listed any more, such as one a newer run replaced, goes, with what was read of it.
        .onChange(of: panel.checks.compactMap(\.buildId), initial: true) {
            investigations.retain(Set(panel.checks.compactMap(\.buildId)), of: item.key)
        }
        // What a composer sends is called off as the builds go, with the details, or for another pull request, file or page;
        // as it closes, or another opens, the details call it off.
        .onDisappear { drafts.callOffAll() }
    }

    /// Opens the build the details are asked to go to, as What's Left's failed build asks, or the Pipelines page, or a
    /// failing pull request opened from the menu bar. Asked to go to its builds and checks, they only scroll there.
    private func open(_ place: PullRequestDetailsStore.Place?) {
        guard let place, let pullRequest else { return }
        switch place {
        case .run, .check: break
        case .thread, .section, .files, .file, .top: return
        }
        guard let line = panel.checks.first(where: { PullRequestDetailsStore.Place.of($0) == place }), line.canInvestigate,
              let buildId = line.buildId
        else { return }
        investigations.expand(buildId, of: pullRequest, check: line.check)
    }
}

/// A build or a check: where it stands, as the Pipelines page draws it, why it failed, and what Copilot does about it. One
/// that failed or is still going opens with a click, or Space, to look into its run.
private struct CheckRow: View {
    let line: PullRequestPanel.CheckLine
    let item: PRSnapshot
    let pullRequest: PullRequest?
    let now: Date
    let isHighlighted: Bool
    /// The composer in place that's open in the builds and checks.
    @Binding var composing: CopilotComposing?
    let drafts: CopilotDrafts

    @EnvironmentObject private var investigations: BuildInvestigationStore
    @LocalState private var isHovered = false

    private var run: ItemStory.Run { line.run }

    /// Its run, when it can be looked into.
    private var investigable: (buildId: Int, pullRequest: PullRequest)? {
        guard line.canInvestigate, let buildId = line.buildId, let pullRequest else { return nil }
        return (buildId, pullRequest)
    }

    private var isExpanded: Bool {
        investigable.map { investigations.isExpanded($0.buildId, of: item.key) } ?? false
    }

    private var look: BuildInvestigationStore.Look? {
        investigable.flatMap { investigations.look($0.buildId, of: item.key) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if investigable != nil {
                    Button(action: toggle) {
                        heading
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovered = $0 }
                    .help("Click to \(isExpanded ? "hide" : "see") " + (run.state == .failing ? "why it failed" : "how it's going"))
                    .accessibilityLabel("\(run.name): \(status)")
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    .accessibilityHint(run.state == .failing ? "Shows why it failed" : "Shows how it's going")
                } else {
                    heading
                }
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
            if let detail = run.detail, !showsErrors {
                Text(detail)
                    .font(size: 11).monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
                    .padding(.top, 2)
            }
            // What Copilot does about it, open or not.
            BuildWorkLine(line: line, item: item, now: now)
            if isExpanded, let investigable {
                BuildInvestigationView(
                    line: line, item: item, pullRequest: investigable.pullRequest, buildId: investigable.buildId, look: look, now: now,
                    composing: $composing, drafts: drafts
                )
                .padding(.leading, 24)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(isHighlighted ? 0.14 : 0))
                .padding(.horizontal, 3)
        )
        .contextMenu { menuItems }
        // Its check, or its pull request, changed since what shows was read, as when the run finished or runs again, or
        // someone pushed or retargeted it, while it was open or off screen, such as under a page: it's asked for again.
        .onChange(of: investigable.map { BuildInvestigationStore.Stamp(check: line.check, pullRequest: $0.pullRequest) }, initial: true) {
            guard let investigable else { return }
            investigations.changed(investigable.buildId, of: investigable.pullRequest, check: line.check)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(run.name): \(status)" + (line.isRequired || line.check == nil ? "" : ", optional")
            + (run.detail.map { ". \($0)" } ?? ""))
    }

    /// Its symbol, name and status, and, when it opens, a chevron that says whether it's open.
    private var heading: some View {
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if investigable != nil {
                Image(systemName: "chevron.right")
                    .font(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isHovered && !isHighlighted ? 0.06 : 0))
                .padding(.horizontal, -6)
                .padding(.vertical, -4)
        )
    }

    @ViewBuilder
    private var menuItems: some View {
        if let investigable {
            Button((isExpanded ? "Hide " : "Show ") + (run.state == .failing ? "Why It Failed" : "How It's Going"), action: toggle)
            if isExpanded {
                Button("Read Again") {
                    investigations.read(investigable.buildId, of: investigable.pullRequest, check: line.check, again: true)
                }
                .disabled(look?.isReading == true)
            }
            Divider()
        }
        if let url = run.url {
            Button("Open Run in Azure DevOps") { NSWorkspace.shared.open(url) }
            if let investigation = look?.investigation, let log = investigation.log {
                Button("Open Log in Azure DevOps") { NSWorkspace.shared.open(investigation.logPage(for: log.stepId)) }
            }
            Button("Copy Link") { PullRequestDetailsPanel.copy(url.absoluteString) }
        }
        Button("Copy Name") { PullRequestDetailsPanel.copy(run.name) }
    }

    /// Open, its errors say what the first one does.
    private var showsErrors: Bool {
        isExpanded && look?.investigation?.errors.isEmpty == false
    }

    private func toggle() {
        guard let investigable else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            investigations.toggle(investigable.buildId, of: investigable.pullRequest, check: line.check)
        }
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
