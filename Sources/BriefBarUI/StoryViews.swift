import AppKit
import BriefBarCore
import SwiftUI

/// Where a thing stands: the pull requests, their pipelines and the Copilot sessions linked to it, the one that needs you
/// most first, each saying where it stands in a sentence, with sessions under the pull request they're linked through.
/// Opening one shows a short preview of what its source knows of it (`ItemStory`), its actions first, and the rest on
/// request. While Show Links is off it reads nothing, and a line you can dismiss says how to see them.
package struct WhereItStandsSection: View {
    private let subject: ItemRef

    @EnvironmentObject private var services: AppServices

    package init(subject: ItemRef) {
        self.subject = subject
    }

    package var body: some View {
        StandingContent(subject: subject, links: services.links, stories: services.stories, defaults: services.defaults)
    }

    /// The preferences' key for the line that says how to see what's linked, once you dismissed it.
    static let hintHiddenKey = "links.whereItStandsHintHidden"
    /// How many groups show before "Show More".
    static let shownGroups = 4

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

    /// What's linked, each with what's linked to the subject only through it, such as a session on a pull request's
    /// branch: the group with what needs you most first, then the newest.
    static func groups(_ connections: [LinkConnection]) -> [StandingGroup] {
        let refs = Set(connections.map(\.item.ref))
        var children: [ItemRef: [LinkConnection]] = [:]
        var leads: [LinkConnection] = []
        for connection in connections {
            if let via = connection.via?.ref, refs.contains(via) {
                children[via, default: []].append(connection)
            } else {
                leads.append(connection)
            }
        }
        let groups = leads.map { StandingGroup(lead: $0, children: ordered(children[$0.item.ref] ?? [])) }
        return groups.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.date != rhs.date { return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast) }
            return lhs.lead.item.ref < rhs.lead.item.ref
        }
    }

    /// How many need you, went wrong, are running, and are done or ready, for five things or more, when the icons alone
    /// no longer add up at a glance; nil otherwise.
    static func tally(_ connections: [LinkConnection]) -> [(state: ItemState, text: String)]? {
        guard connections.count >= 5 else { return nil }
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

    /// What a row calls it: a pull request's or a work item's title, a session's name; a task you sent to Copilot by what
    /// it's for, "Sent to Copilot" or "Fix the Build with Copilot", and where it came from when that's elsewhere.
    static func name(of item: LinkedItem, subject: ItemRef, parent: ItemRef? = nil) -> String {
        guard let sent = item.sent else { return item.ref.kind == .session ? item.label : item.title }
        let what = sent.action.map { "\($0) with Copilot" } ?? "Sent to Copilot"
        return sent.from == subject || (parent != nil && sent.from == parent) ? what : "\(what): \(item.label)"
    }

    /// Why it's here, in a few words.
    static func reason(_ connection: LinkConnection, subject: ItemRef) -> String {
        if let via = connection.via { return "Linked through \(via.label)" }
        if let sent = connection.item.sent, sent.from == subject { return "You sent it from here" }
        switch connection.origins.first {
        case .azureDevOps?: return "Linked in Azure DevOps"
        case .copilot?: return "Linked by Copilot"
        case .branch?: return "On the same branch"
        case .you?: return "Linked by you"
        case nil: return ""
        }
    }

    /// A sentence's opening phrase, which takes its state's color, and the rest: "Ready to complete:" and "Approved by…".
    static func phrase(_ sentence: String) -> (lead: String, rest: String) {
        guard let colon = sentence.range(of: ": ") else { return (sentence, "") }
        return (String(sentence[..<colon.lowerBound]) + ":", String(sentence[colon.upperBound...]))
    }
}

/// Something linked to the subject, and what's linked to it only through it.
struct StandingGroup: Identifiable {
    var lead: LinkConnection
    var children: [LinkConnection]

    var id: ItemRef { lead.item.ref }
    var all: [LinkConnection] { [lead] + children }
    /// Where the group shows: by its most pressing member.
    var rank: Int { all.map { ItemState.rank($0.item.state) }.min() ?? ItemState.rank(nil) }
    var date: Date? { all.compactMap(\.item.date).max() }
}

private struct StandingContent: View {
    let subject: ItemRef
    @ObservedObject var links: Links
    @ObservedObject var stories: ItemStories
    let defaults: UserDefaults

    @LocalState private var expanded: Set<ItemRef> = []
    @LocalState private var showsEverything = false
    @LocalState private var hintHidden: Bool?
    @LocalState private var showsSetting = false
    @Environment(\.isRendering) private var isRendering

    private var isHintHidden: Bool {
        hintHidden ?? defaults.bool(forKey: WhereItStandsSection.hintHiddenKey)
    }

    var body: some View {
        let connections = WhereItStandsSection.ordered(links.connections(of: subject))
        let groups = WhereItStandsSection.groups(connections)
        if links.isOn || !isHintHidden {
            VStack(alignment: .leading, spacing: 8) {
                header(count: connections.count)
                if !links.isOn {
                    off
                } else if groups.isEmpty {
                    HStack(spacing: 8) {
                        Text("No pull requests or Copilot sessions yet.")
                            .foregroundStyle(.secondary)
                        Button("Link…") { links.pick(for: subject) }
                            .buttonStyle(.borderless)
                            .help(LinkPickerView.buttonTitle(for: subject.kind))
                    }
                    .font(.system(size: 12))
                } else {
                    if let tally = WhereItStandsSection.tally(connections) {
                        TallyLine(parts: tally)
                    }
                    card(groups)
                    footer(hiddenOf: groups.count)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // As it shows, and whenever what's linked changes or how one of them stands: their stories, as they are now.
            .onChange(of: connections.map { "\($0.item.ref)#\(ItemStories.version(of: $0.item))" }, initial: true) {
                request(connections)
            }
            // And each minute while it shows, for what changes without its row changing, such as a vote or a checkpoint.
            .background {
                TimelineView(.periodic(from: .distantPast, by: ItemStories.freshFor)) { context in
                    Color.clear.onChange(of: context.date) { request(connections) }
                }
            }
        }
    }

    private func request(_ connections: [LinkConnection]) {
        for connection in connections { stories.request(connection.item) }
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
        }
    }

    /// While Show Links is off: a line that says how to see what goes with it, until you turn it on or dismiss it.
    private var off: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("See its pull requests and Copilot sessions here.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn On…") { showsSetting = true }
                .buttonStyle(.borderless)
                .popover(isPresented: $showsSetting, arrowEdge: .bottom) {
                    LinksSetting(links: links)
                        .padding(16)
                        .frame(width: 380)
                }
            Spacer(minLength: 4)
            Button {
                defaults.set(true, forKey: WhereItStandsSection.hintHiddenKey)
                hintHidden = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Don't show this again: Show Links is in Settings › General")
            .accessibilityLabel("Dismiss")
        }
        .font(.system(size: 12))
    }

    private func card(_ groups: [StandingGroup]) -> some View {
        let shown = showsEverything ? groups : Array(groups.prefix(WhereItStandsSection.shownGroups))
        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, group in
                if index > 0 {
                    Divider()
                        .opacity(0.6)
                        .padding(.leading, 34)
                }
                VStack(spacing: 0) {
                    row(group.lead, isFirst: index == 0, parent: nil)
                    ForEach(group.children) { child in
                        row(child, isFirst: false, parent: group.lead.item.ref)
                            .padding(.leading, 22)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .background(GlassCard(cornerRadius: 12, raised: true))
    }

    private func row(_ connection: LinkConnection, isFirst: Bool, parent: ItemRef?) -> some View {
        let ref = connection.item.ref
        return StoryRow(
            subject: subject, parent: parent, connection: connection, story: stories.story(for: ref),
            isTelling: stories.isTelling(ref) && !stories.hasTold(ref),
            // Offscreen, the first one open, to show what's in it.
            isExpanded: expanded.contains(ref) || (isRendering && isFirst),
            links: links
        ) {
            withAnimation(.easeOut(duration: 0.15)) {
                if expanded.contains(ref) { expanded.remove(ref) } else { expanded.insert(ref) }
            }
        }
    }

    /// Linking more, what you hid, and the rest of a long list.
    private func footer(hiddenOf count: Int) -> some View {
        let hidden = links.connections(of: subject, includingHidden: true).filter(\.isHidden)
        return HStack(spacing: 12) {
            Button {
                links.pick(for: subject)
            } label: {
                Label("Link…", systemImage: "link")
            }
            .buttonStyle(.borderless)
            .help(LinkPickerView.buttonTitle(for: subject.kind))
            if !hidden.isEmpty {
                Menu("\(hidden.count) Hidden") {
                    ForEach(hidden) { connection in
                        Button("Show \(connection.item.menuTitle)") { links.showAgain(subject, connection.item.ref) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Links you hid here")
            }
            Spacer(minLength: 8)
            if count > WhereItStandsSection.shownGroups {
                Button(showsEverything ? "Show Fewer" : "Show \(count - WhereItStandsSection.shownGroups) More") {
                    withAnimation(.easeOut(duration: 0.15)) { showsEverything.toggle() }
                }
                .buttonStyle(.borderless)
            }
        }
        .font(.system(size: 11.5))
    }
}

/// "✋ 1 needs you · ⚡ 1 running", under the section's title.
private struct TallyLine: View {
    let parts: [(state: ItemState, text: String)]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(parts, id: \.state) { part in
                HStack(spacing: 3) {
                    Image(systemName: part.state.symbol)
                        .foregroundStyle(part.state.color)
                        .accessibilityHidden(true)
                    Text(part.text)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// One thing linked to it: its state, what it is, where it stands in a sentence and since when. A click opens a short
/// preview of what's known of it.
private struct StoryRow: View {
    let subject: ItemRef
    /// The pull request it's linked through, when it shows under it.
    let parent: ItemRef?
    let connection: LinkConnection
    let story: ItemStory?
    let isTelling: Bool
    let isExpanded: Bool
    @ObservedObject var links: Links
    let toggle: () -> Void

    @LocalState private var isHovered = false

    private var item: LinkedItem { connection.item }
    private var isChild: Bool { parent != nil }
    private var name: String { WhereItStandsSection.name(of: item, subject: subject, parent: parent) }

    /// Where it stands: as its source tells it, or its row's status until then.
    private var sentence: String {
        if let sentence = story?.sentence, !sentence.isEmpty { return sentence }
        return item.status ?? ""
    }

    /// The state, as the lists by state draw it; a session of the app's own, by what it waits for; without a state, what
    /// kind of thing it is.
    private var symbol: (name: String, color: Color) {
        if item.ref.kind == .session, item.sent == nil { return (item.symbol, item.state?.color ?? item.color) }
        if let state = item.state {
            return (state == .done && item.ref.kind.isPullRequest ? "arrow.triangle.merge" : state.symbol, state.color)
        }
        return (Self.kindSymbol(of: item), .secondary)
    }

    static func kindSymbol(of item: LinkedItem) -> String {
        switch item.ref.kind {
        case .pullRequest, .gitHubPullRequest: return "arrow.triangle.pull"
        case .session: return item.sent != nil ? "paperplane" : "waveform.path.ecg"
        case .workItem: return "doc.text"
        }
    }

    private var kindName: String {
        item.sent != nil ? "Task sent to Copilot" : item.ref.kind.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(symbol.color)
                        .frame(width: 16)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            kindMarker
                            Text(name)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if !sentence.isEmpty {
                            sentenceText
                                .font(.system(size: 11.5))
                                .lineLimit(isChild ? 1 : 2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let date = item.date {
                        Text(Self.ago(date))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help(date.formatted(date: .abbreviated, time: .shortened))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
                        .padding(.horizontal, 3)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) { quickOpen }
            .onHover { isHovered = $0 }
            .help(help)
            .accessibilityLabel("\(kindName), \(name). \(sentence)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides what's known of it" : "Shows what's known of it")
            .accessibilityAction(named: "Open") { open() }
            .accessibilityAction(named: connection.isKnownElsewhere ? "Hide Link" : "Unlink") { links.unlink(subject, item.ref) }
            if isExpanded {
                StoryPreview(subject: subject, connection: connection, story: story, isTelling: isTelling)
                    .padding(.leading, 34)
                    .padding(.trailing, 12)
                    .padding(.top, 1)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .contextMenu { menu }
    }

    /// A pull request's or a work item's number; a glyph for a session of the app's, or a task you sent.
    @ViewBuilder
    private var kindMarker: some View {
        switch item.ref.kind {
        case .pullRequest, .gitHubPullRequest, .workItem:
            Text(item.label)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        case .session:
            Image(systemName: item.sent != nil ? "paperplane" : "waveform.path.ecg")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    /// The sentence, its opening phrase in its state's color.
    private var sentenceText: Text {
        let (lead, rest) = WhereItStandsSection.phrase(sentence)
        let color = item.state?.color
        let opening = Text(lead).foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        return rest.isEmpty ? opening : opening + Text(" " + rest).foregroundStyle(.secondary)
    }

    /// Opens it in one click, where it needs you or went wrong, or while you point at it; a task you sent opens from its
    /// actions instead.
    @ViewBuilder
    private var quickOpen: some View {
        if item.menu == nil, item.open != nil, isHovered || item.state == .needsYou || item.state == .failing {
            Button(action: open) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(item.state.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, item.date == nil ? 26 : 62)
            .help(StoryPreview.openTitle(for: item.ref.kind))
            .accessibilityLabel(StoryPreview.openTitle(for: item.ref.kind))
        }
    }

    private func open() {
        item.open?()
    }

    @ViewBuilder
    private var menu: some View {
        if let menu = item.menu {
            menu()
        } else if let open = item.open {
            Button(StoryPreview.openTitle(for: item.ref.kind), action: open)
        }
        Divider()
        Button(isExpanded ? "Hide Details" : "Show Details", action: toggle)
        Button(connection.isKnownElsewhere ? "Hide Link" : "Unlink") { links.unlink(subject, item.ref) }
    }

    private var help: String {
        var lines = [item.menuTitle]
        if !sentence.isEmpty { lines.append(sentence) }
        lines.append(WhereItStandsSection.reason(connection, subject: subject))
        return lines.joined(separator: "\n")
    }

    /// "now", "41m", "20h", "3d": since when, in one unit.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        switch minutes {
        case 0: return "now"
        case ..<60: return "\(minutes)m"
        case ..<(24 * 60): return "\(minutes / 60)h"
        default: return "\(minutes / (24 * 60))d"
        }
    }
}

/// What's known of one thing, in short: what to do with it first, what it said last when it's at work or waits for you,
/// a few facts, its pipelines, Copilot's own notes and what's next; then, when you ask, everything else.
private struct StoryPreview: View {
    let subject: ItemRef
    let connection: LinkConnection
    let story: ItemStory?
    let isTelling: Bool

    @LocalState private var showsAll = false

    private var item: LinkedItem { connection.item }
    private var account: ItemStory.Account? { story?.account.flatMap { $0.isEmpty ? nil : $0 } }
    /// What it said last comes first while it's at work or waits for you: it's what it's doing now.
    private var lastWordsFirst: Bool { item.state == .needsYou || item.state == .running }
    private static let previewRuns = 3
    private static let previewNext = 3

    private var hasMore: Bool {
        guard let story else { return false }
        let account = self.account
        return !story.more.isEmpty || story.runs.count > Self.previewRuns || !(account?.done.isEmpty ?? true)
            || (account?.milestones.count ?? 0) > 1 || (account?.next.count ?? 0) > Self.previewNext
            || (account?.lastMessage != nil && !lastWordsFirst)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            actions
            if let story {
                if lastWordsFirst, let last = account?.lastMessage {
                    CopilotWords(caption: "What it said last") {
                        ClampedText(text: last, lines: 2)
                    }
                }
                if !story.facts.isEmpty {
                    FactsGrid(facts: story.facts)
                }
                if !story.runs.isEmpty {
                    RunsView(runs: showsAll ? story.runs : Array(story.runs.prefix(Self.previewRuns)))
                }
                if let account {
                    notes(account)
                }
                if let footnote = story.footnote {
                    Text(footnote)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showsAll, !story.more.isEmpty {
                    FactsGrid(facts: story.more)
                }
                if hasMore {
                    Button(showsAll ? "Show Less" : "Show All") {
                        withAnimation(.easeOut(duration: 0.15)) { showsAll.toggle() }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            } else if isTelling {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Reading what's known of it…")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11.5))
            }
        }
    }

    /// Opening it, or its own actions, and why it's here.
    private var actions: some View {
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
            Text(WhereItStandsSection.reason(connection, subject: subject))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .controlSize(.small)
    }

    /// Copilot's notes, as it wrote them: its overview, what's next, and, when you ask, what it did, the story so far a
    /// line a checkpoint, and what it said last.
    private func notes(_ account: ItemStory.Account) -> some View {
        CopilotWords(caption: caption(account)) {
            VStack(alignment: .leading, spacing: 8) {
                if let overview = account.overview, !overview.isEmpty {
                    ClampedText(text: overview, lines: 3)
                }
                if !account.next.isEmpty {
                    StoryList(title: "What's next", lines: showsAll ? account.next : Array(account.next.prefix(Self.previewNext)), symbol: "arrow.right")
                }
                if showsAll {
                    if !account.done.isEmpty {
                        StoryList(title: "What it did", lines: account.done, symbol: "checkmark")
                    }
                    if account.milestones.count > 1 {
                        Milestones(account: account)
                    }
                    if !lastWordsFirst, let last = account.lastMessage {
                        VStack(alignment: .leading, spacing: 3) {
                            StoryCaption(text: "What it said last")
                            ClampedText(text: last, lines: 4)
                        }
                    }
                }
            }
        }
    }

    /// "Copilot's notes · 3h ago".
    private func caption(_ account: ItemStory.Account) -> String {
        guard let date = account.date else { return account.source }
        let elapsed = Elapsed.short(since: date, now: Date())
        return "\(account.source) · \(elapsed == "now" ? "just now" : "\(elapsed) ago")"
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

/// Facts, their labels on the left.
private struct FactsGrid: View {
    let facts: [ItemStory.Fact]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(facts, id: \.self) { fact in
                GridRow {
                    Text(fact.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
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
}

/// What Copilot wrote, set apart by a thin rule along its edge, so its words read as its own, not BriefBar's.
private struct CopilotWords<Content: View>: View {
    let caption: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StoryCaption(text: caption)
            content()
        }
        .padding(.leading, 9)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 2)
        }
    }
}

/// Text that shows a few lines, and "Show More" only when it has more than that.
private struct ClampedText: View {
    let text: String
    let lines: Int

    @LocalState private var isExpanded = false
    @LocalState private var shownHeight: CGFloat = 0
    @LocalState private var fullHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text)
                .lineLimit(isExpanded ? nil : lines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
                .background(alignment: .topLeading) {
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
                .textSelection(.enabled)
            if isExpanded || fullHeight > shownHeight + 1 {
                Button(isExpanded ? "Show Less" : "Show More") {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
        }
        .font(.system(size: 12))
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
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(status)
                        .font(.system(size: 11.5))
                        .foregroundStyle(run.state == .failing ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
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

    /// As the Pipelines page draws them.
    private var symbol: String {
        switch run.state {
        case .done?: return "checkmark.circle.fill"
        case .failing?: return "xmark.circle.fill"
        case .running?: return "arrow.triangle.2.circlepath"
        case .needsYou?: return "hand.raised.fill"
        case nil: return run.status.hasPrefix("Waiting") ? "pause.circle" : "circle.dashed"
        }
    }

    private var color: Color { run.state?.color ?? .secondary }
}

/// The checkpoints' titles, the story so far, numbered as Copilot numbers them, the latest one stronger.
private struct Milestones: View {
    let account: ItemStory.Account

    var body: some View {
        let first = account.milestoneCount - account.milestones.count + 1
        VStack(alignment: .leading, spacing: 2) {
            StoryCaption(text: "The story so far")
            if first > 1 {
                Text("\(first - 1) earlier")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(account.milestones.enumerated()), id: \.offset) { index, title in
                let isLatest = index == account.milestones.count - 1
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(first + index))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 14, alignment: .trailing)
                    Text(title)
                        .font(.system(size: 12, weight: isLatest ? .medium : .regular))
                        .foregroundStyle(isLatest ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("The story so far: " + account.milestones.joined(separator: ", "))
    }
}

/// A list under a caption, a line each: "What's next", "What it did".
private struct StoryList: View {
    let title: String
    let lines: [String]
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            StoryCaption(text: title)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text(line)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// A part's title in what's known of a thing: "Pipelines", "What's next".
private struct StoryCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
