import AppKit
import BriefBarCore
import SwiftUI

/// Where a thing stands: what's linked to it, the pull requests, their pipelines and the Copilot sessions, the one that
/// needs you most first, each with where it stands in a sentence; and, once you open one, what its source tells about it
/// (`ItemStory`): a few facts, the pipelines that ran on it, and what's been done. While Show Links is off it reads
/// nothing, and says how to see them.
package struct WhereItStandsSection: View {
    private let subject: ItemRef

    @EnvironmentObject private var services: AppServices

    package init(subject: ItemRef) {
        self.subject = subject
    }

    package var body: some View {
        StandingContent(subject: subject, links: services.links, stories: services.stories) { [services] in
            services.openSettings(.general)
        }
    }

    /// The order they show in: what needs you first, then what's wrong, what's at work, what's done or ready, then the
    /// rest; the newest first in each.
    static func ordered(_ connections: [LinkConnection]) -> [LinkConnection] {
        connections.sorted { lhs, rhs in
            let (left, right) = (ItemState.rank(lhs.item.state), ItemState.rank(rhs.item.state))
            if left != right { return left < right }
            if lhs.item.date != rhs.item.date { return (lhs.item.date ?? .distantPast) > (rhs.item.date ?? .distantPast) }
            return lhs.item.ref < rhs.item.ref
        }
    }

    /// How many need you, went wrong, are running, and are done or ready, for two things or more: nil for fewer, or when
    /// none of them is in a state.
    static func tally(_ connections: [LinkConnection]) -> [(state: ItemState, text: String)]? {
        guard connections.count >= 2 else { return nil }
        var counts = StateCounts()
        for connection in connections {
            if let state = connection.item.state { counts[state] += 1 }
        }
        let parts = ItemState.allCases.compactMap { state -> (state: ItemState, text: String)? in
            let count = counts[state]
            guard count > 0 else { return nil }
            return (state, "\(count) \(state == .needsYou && count == 1 ? "needs you" : state.countLabel)")
        }
        return parts.isEmpty ? nil : parts
    }
}

private struct StandingContent: View {
    let subject: ItemRef
    @ObservedObject var links: Links
    @ObservedObject var stories: ItemStories
    let openSettings: () -> Void

    @LocalState private var expanded: Set<ItemRef> = []
    @Environment(\.isRendering) private var isRendering

    var body: some View {
        let connections = WhereItStandsSection.ordered(links.connections(of: subject))
        VStack(alignment: .leading, spacing: 8) {
            header(count: connections.count)
            if !links.isOn {
                off
            } else if connections.isEmpty {
                Text("Nothing's linked to it yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
            } else {
                if let tally = WhereItStandsSection.tally(connections) {
                    TallyLine(parts: tally)
                }
                VStack(spacing: 2) {
                    ForEach(Array(connections.enumerated()), id: \.element.id) { index, connection in
                        let ref = connection.item.ref
                        StoryRow(
                            subject: subject, connection: connection, story: stories.story(for: ref),
                            isTelling: stories.isTelling(ref) && !stories.hasTold(ref),
                            // Offscreen, the first one open, to show what's in it.
                            isExpanded: expanded.contains(ref) || (isRendering && index == 0),
                            links: links
                        ) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                if expanded.contains(ref) { expanded.remove(ref) } else { expanded.insert(ref) }
                            }
                        }
                    }
                }
                .padding(.horizontal, -6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // As it shows, and whenever what's linked changes or how one of them stands: their stories, as they are now.
        .onChange(of: connections.map { "\($0.item.ref)#\(ItemStories.version(of: $0.item))" }, initial: true) {
            for connection in connections { stories.request(connection.item) }
        }
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Where It Stands")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if count > 0 {
                Text(String(count))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .accessibilityLabel("\(count) linked")
            }
            Spacer(minLength: 8)
            if links.isOn {
                Button {
                    links.pick(for: subject)
                } label: {
                    Label("Link…", systemImage: "link")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.borderless)
                .help(LinkPickerView.buttonTitle(for: subject.kind))
            }
        }
    }

    private var off: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Turn on Show Links to see the pull requests, their pipelines and the Copilot sessions that go with it, and where each one stands.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings…", action: openSettings)
                .buttonStyle(.borderless)
                .font(.system(size: 11.5))
        }
    }
}

/// "✋ 1 needs you · ⚡ 1 running", under the section's title.
private struct TallyLine: View {
    let parts: [(state: ItemState, text: String)]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(parts, id: \.state) { part in
                Label {
                    Text(part.text)
                } icon: {
                    Image(systemName: part.state.symbol)
                        .foregroundStyle(part.state.color)
                }
                .labelStyle(TightLabel())
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

/// One thing linked to it: what it is, and where it stands in a sentence. A click opens what's known of it.
private struct StoryRow: View {
    let subject: ItemRef
    let connection: LinkConnection
    let story: ItemStory?
    let isTelling: Bool
    let isExpanded: Bool
    @ObservedObject var links: Links
    let toggle: () -> Void

    @LocalState private var isHovered = false

    private var item: LinkedItem { connection.item }
    private var tint: Color { item.state?.color ?? item.color }

    /// Where it stands: as its source tells it, or its row's status until then.
    private var sentence: String {
        if let sentence = story?.sentence, !sentence.isEmpty { return sentence }
        return item.status ?? ""
    }

    /// A pull request's or a work item's number, before its title.
    private var showsNumber: Bool { item.ref.kind != .session }

    /// A session's name, or what a task was sent for: its label. A pull request's or a work item's title.
    private var name: String { showsNumber ? item.title : item.label }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: 16)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            if showsNumber {
                                Text(item.label)
                                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                            Text(name)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if !sentence.isEmpty {
                            Text(sentence)
                                .font(.system(size: 11.5))
                                .foregroundStyle(item.state == .needsYou || item.state == .failing ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.07 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(help)
            .accessibilityLabel("\(item.menuTitle). \(sentence)")
            .accessibilityHint(isExpanded ? "Hides what's known of it" : "Shows what's known of it")
            if isExpanded {
                StoryDetail(connection: connection, story: story, isTelling: isTelling)
                    .padding(.leading, 30)
                    .padding(.trailing, 6)
                    .padding(.top, 3)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .contextMenu { menu }
    }

    @ViewBuilder
    private var menu: some View {
        if let menu = item.menu {
            menu()
        } else if let open = item.open {
            Button(StoryDetail.openTitle(for: item.ref.kind), action: open)
        }
        Divider()
        Button(isExpanded ? "Hide Details" : "Show Details", action: toggle)
        Button(connection.isKnownElsewhere ? "Hide Here" : "Unlink") { links.unlink(subject, item.ref) }
    }

    private var help: String {
        var lines = [item.menuTitle]
        if !sentence.isEmpty { lines.append(sentence) }
        lines.append(connection.reason)
        lines.append(isExpanded ? "Click to hide what's known of it" : "Click to see what's known of it")
        return lines.joined(separator: "\n")
    }
}

/// What's known of one thing: its facts, the pipelines that ran on it, what's been done, and what opens it.
private struct StoryDetail: View {
    let connection: LinkConnection
    let story: ItemStory?
    let isTelling: Bool

    private var item: LinkedItem { connection.item }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let story, !story.facts.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                    ForEach(story.facts, id: \.self) { fact in
                        GridRow {
                            Text(fact.label)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                                .lineLimit(1)
                            Text(fact.value)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.system(size: 12))
                .textSelection(.enabled)
            }
            if let runs = story?.runs, !runs.isEmpty {
                RunsView(runs: runs)
            }
            if let account = story?.account, !account.isEmpty {
                AccountView(account: account)
            }
            if story == nil, isTelling {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Reading what's known of it…")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11.5))
            }
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let menu = item.menu {
                Menu {
                    menu()
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.button)
                .fixedSize()
            } else if let open = item.open {
                Button(Self.openTitle(for: item.ref.kind), action: open)
            }
            Spacer(minLength: 8)
            Text(connection.reason)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help("Why it's here: \(connection.reason)")
        }
        .controlSize(.small)
    }

    /// "Open in Azure DevOps", for what opens a thing of this kind.
    static func openTitle(for kind: ItemRef.Kind) -> String {
        switch kind {
        case .workItem, .pullRequest: return "Open in Azure DevOps"
        case .gitHubPullRequest: return "Open on GitHub"
        case .session: return "Open in Copilot"
        }
    }
}

/// The pipelines that ran on a pull request, the one that needs you most first: a click opens its run.
private struct RunsView: View {
    let runs: [ItemStory.Run]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StoryCaption(text: runs.count == 1 ? "Pipeline" : "Pipelines")
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    RunRow(run: run)
                }
            }
            .padding(.horizontal, -6)
        }
    }
}

private struct RunRow: View {
    let run: ItemStory.Run

    @LocalState private var isHovered = false

    var body: some View {
        Button {
            if let url = run.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 14)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(run.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(status)
                            .font(.system(size: 11.5))
                            .foregroundStyle(run.state == .failing ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                    if let detail = run.detail {
                        Text(detail)
                            .font(.system(size: 11).monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovered && run.url != nil ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(run.url == nil)
        .onHover { isHovered = $0 }
        .help(run.url == nil ? run.name : "Open \(run.name)'s run")
        .accessibilityLabel("\(run.name): \(status)" + (run.detail.map { ". \($0)" } ?? ""))
    }

    /// "Failed at Run tests · 12m ago".
    private var status: String {
        guard let date = run.date, run.state != .running else { return run.status }
        let elapsed = Elapsed.short(since: date, now: Date())
        return "\(run.status) · \(elapsed == "now" ? "just now" : "\(elapsed) ago")"
    }

    private var symbol: String {
        switch run.state {
        case .done?: return "checkmark.circle.fill"
        case .failing?: return "xmark.circle.fill"
        case .running?: return "clock.fill"
        case .needsYou?: return "hand.raised.fill"
        case nil: return "circle.dashed"
        }
    }

    private var color: Color { run.state?.color ?? .secondary }
}

/// What's been done, as the thing recorded it: the story so far in a line each, the latest overview, what's done and
/// what's next, and what it said last.
private struct AccountView: View {
    let account: ItemStory.Account

    @LocalState private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StoryCaption(text: caption)
            if account.milestones.count > 1 {
                milestones
            }
            if let overview = account.overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 12))
                    .lineLimit(showsAll ? nil : 5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if overview.count > 320 {
                    Button(showsAll ? "Show Less" : "Show More") {
                        withAnimation(.easeOut(duration: 0.15)) { showsAll.toggle() }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            }
            if !account.done.isEmpty {
                list("Done", account.done, symbol: "checkmark")
            }
            if !account.next.isEmpty {
                list("Next", account.next, symbol: "arrow.right")
            }
            if let last = account.lastMessage, !last.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    StoryCaption(text: "What it said last")
                    Text(last)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// "Copilot's checkpoints · 2h ago".
    private var caption: String {
        guard let date = account.date else { return account.source }
        let elapsed = Elapsed.short(since: date, now: Date())
        return "\(account.source) · \(elapsed == "now" ? "just now" : "\(elapsed) ago")"
    }

    /// The checkpoints' titles, the latest one stronger, numbered as Copilot numbers them.
    private var milestones: some View {
        let first = account.milestoneCount - account.milestones.count + 1
        return VStack(alignment: .leading, spacing: 2) {
            if first > 1 {
                Text("\(first - 1) earlier")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(account.milestones.enumerated()), id: \.offset) { index, title in
                let isLatest = index == account.milestones.count - 1
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(first + index))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 14, alignment: .trailing)
                    Text(title)
                        .font(.system(size: 12, weight: isLatest ? .medium : .regular))
                        .foregroundStyle(isLatest ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Checkpoints: " + account.milestones.joined(separator: ", "))
    }

    private func list(_ title: String, _ lines: [String], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            StoryCaption(text: title)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                    Text(line)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// A part's title in what's known of a thing: "Pipelines", "Done".
private struct StoryCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
