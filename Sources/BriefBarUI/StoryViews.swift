import AppKit
import BriefBarCore
import SwiftUI

/// Where a thing stands: the pull requests, their pipelines and the Copilot sessions linked to it, the one that needs you
/// most first, each saying where it stands in a sentence, with sessions under the pull request they're linked through.
/// Opening one shows a short preview of what its source knows of it (`ItemStory`), its actions first, and the rest on
/// request. While Show Links is off it reads nothing, and a line you can dismiss says how to see them.
package struct WhereItStandsSection: View {
    private let subject: ItemRef
    private let excluding: Set<ItemRef>
    private let title: String
    private let hidesWhenEmpty: Bool
    private let showsSummary: Bool

    @EnvironmentObject private var services: AppServices

    /// - Parameters:
    ///   - excluding: what it leaves out, such as, on a page, the work item and the pages you came from.
    ///   - hidesWhenEmpty: whether it shows nothing at all while nothing's linked, as on a page.
    ///   - showsSummary: whether ✨ Summarize with Copilot and its summary are here, rather than, on a page, under its
    ///     heading; and whether it says who it all waits on, and folds to that.
    package init(
        subject: ItemRef, excluding: Set<ItemRef> = [], title: String = "Where It Stands", hidesWhenEmpty: Bool = false,
        showsSummary: Bool = true
    ) {
        self.subject = subject
        self.excluding = excluding
        self.title = title
        self.hidesWhenEmpty = hidesWhenEmpty
        self.showsSummary = showsSummary
    }

    package var body: some View {
        StandingContent(
            subject: subject, excluding: excluding, title: title, hidesWhenEmpty: hidesWhenEmpty, showsSummary: showsSummary,
            links: services.links, stories: services.stories, summaries: services.summaries, defaults: services.defaults
        )
    }

    /// The preferences' key for Where It Stands folded to who it waits on.
    static let foldedKey = "links.whereItStandsFolded"

    /// Who it all waits on: the thing's own, such as Copilot at work on a story's task, and what's linked to it; you first,
    /// then other people, then Copilot, each once, as they're said on it (`ItemStory.Wait.said`).
    static func waits(of story: ItemStory?, _ connections: [ItemStory?], on subject: ItemRef) -> [ItemStory.Wait] {
        ItemStory.Wait.said(ItemStory.Wait.ordered((story?.waits ?? []) + connections.flatMap { $0?.waits ?? [] }), on: subject)
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
    /// branch, or a task you sent to Copilot from it: the group with what needs you most first, then the newest.
    static func groups(_ connections: [LinkConnection]) -> [StandingGroup] {
        let refs = Set(connections.map(\.item.ref))
        var children: [ItemRef: [LinkConnection]] = [:]
        var leads: [LinkConnection] = []
        for connection in connections {
            if let via = connection.via?.ref, refs.contains(via) {
                children[via, default: []].append(connection)
            } else if let from = connection.item.sent?.from, from != connection.item.ref, refs.contains(from) {
                children[from, default: []].append(connection)
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
        // Sent from something else, which its marker numbers: that thing's title.
        guard !isSentFromHere(sent, subject: subject, parent: parent), let title = sent.title else { return what }
        return sent.action.map { "\($0): \(title)" } ?? title
    }

    /// Whether a task was sent from the subject, or from the pull request it shows under.
    static func isSentFromHere(_ sent: SentToCopilot, subject: ItemRef, parent: ItemRef?) -> Bool {
        sent.from == subject || (parent != nil && sent.from == parent)
    }

    /// A row's sentence, as it reads where it shows: "Opened !4091" is "Opened this pull request" on !4091's page.
    static func sentence(_ sentence: String, on subject: ItemRef) -> String {
        guard subject.kind == .pullRequest, sentence == "Opened !\(subject.id)" else { return sentence }
        return "Opened this pull request"
    }

    /// How a page's thing is linked to what you opened it from, as its first fact: "In Azure DevOps, to Bug 5110".
    static func linkFact(_ connection: LinkConnection, from subject: LinkedItem) -> ItemStory.Fact {
        let what = switch subject.ref.kind {
        case .workItem: "work item \(subject.label)"
        case .pullRequest, .gitHubPullRequest: subject.label
        case .session: "“\(subject.label)”"
        }
        let value: String
        if let via = connection.via {
            value = "To \(what), through \(via.label)"
        } else if let sent = connection.item.sent, sent.from == subject.ref {
            value = "Sent to Copilot from \(what)"
        } else {
            switch connection.origins.first {
            case .azureDevOps?: value = "In Azure DevOps, to \(what)"
            case .copilot?: value = "By Copilot, to \(what)"
            case .branch?: value = subject.ref.kind.isPullRequest ? "On \(what)'s branch" : "On the same branch as \(what)"
            case .you?: value = "By you, to \(what)"
            case nil: value = "To \(what)"
            }
        }
        return ItemStory.Fact("Linked", value)
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

    /// A sentence, its opening phrase in its state's color for words, the rest gray.
    static func sentenceText(_ sentence: String, state: ItemState?) -> Text {
        let (lead, rest) = phrase(sentence)
        let opening = Text(lead).foregroundStyle(state.map { AnyShapeStyle($0.textColor) } ?? AnyShapeStyle(.secondary))
        return rest.isEmpty ? opening : opening + Text(" " + rest).foregroundStyle(.secondary)
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

/// Opens a linked thing where the details show, rather than its preview in place: a work item's details, or a pull
/// request's or a Copilot session's page, to come back from. False when it can't, and the row opens its preview then.
package struct ItemNavigation {
    /// What shows, from the work item to the page on top: what a page's own links leave out, since you came from there.
    package var trail: [ItemRef]
    package var open: @MainActor (ItemRef) -> Bool

    package init(trail: [ItemRef] = [], open: @escaping @MainActor (ItemRef) -> Bool) {
        self.trail = trail
        self.open = open
    }
}

private struct ItemNavigationKey: EnvironmentKey {
    static var defaultValue: ItemNavigation? { nil }
}

private struct WhereItStandsFoldedKey: EnvironmentKey {
    static var defaultValue: Bool? { nil }
}

extension EnvironmentValues {
    /// Where a linked thing opens, when there's somewhere: the Sprint page's details.
    package var itemNavigation: ItemNavigation? {
        get { self[ItemNavigationKey.self] }
        set { self[ItemNavigationKey.self] = newValue }
    }

    /// Whether Where It Stands is folded, whatever you left it at: for a picture of it.
    package var whereItStandsFolded: Bool? {
        get { self[WhereItStandsFoldedKey.self] }
        set { self[WhereItStandsFoldedKey.self] = newValue }
    }
}

private struct StandingContent: View {
    let subject: ItemRef
    let excluding: Set<ItemRef>
    let title: String
    let hidesWhenEmpty: Bool
    let showsSummary: Bool
    @ObservedObject var links: Links
    @ObservedObject var stories: ItemStories
    @ObservedObject var summaries: StorySummaries
    let defaults: UserDefaults

    @LocalState private var expanded: Set<ItemRef> = []
    @LocalState private var showsEverything = false
    @LocalState private var hintHidden: Bool?
    @LocalState private var folded: Bool?
    @LocalState private var showsSetting = false
    @Environment(\.isRendering) private var isRendering
    @Environment(\.itemNavigation) private var navigation
    @Environment(\.whereItStandsFolded) private var foldedToShow

    private var isHintHidden: Bool {
        hintHidden ?? defaults.bool(forKey: WhereItStandsSection.hintHiddenKey)
    }

    /// Folded to who it waits on, as you left it; never where it doesn't say that.
    private var isFolded: Bool {
        showsSummary && (folded ?? foldedToShow ?? defaults.bool(forKey: WhereItStandsSection.foldedKey))
    }

    var body: some View {
        let connections = WhereItStandsSection.ordered(links.connections(of: subject).filter { !excluding.contains($0.item.ref) })
        let groups = WhereItStandsSection.groups(connections)
        let rows = connections.map { "\($0.item.ref)#\(ItemStories.version(of: $0.item))" }
        if (links.isOn || !isHintHidden) && !(hidesWhenEmpty && groups.isEmpty) {
            VStack(alignment: .leading, spacing: 8) {
                let story = stories.story(for: subject)
                let told = connections.map { stories.story(for: $0.item.ref) }
                let waits = WhereItStandsSection.waits(of: story, told, on: subject)
                // Who it waits on, under the title, as its subtitle; that no one does only once all of it has said where it
                // stands, and never while something can't.
                VStack(alignment: .leading, spacing: 3) {
                    header(count: connections.count, canSummarize: showsSummary && !groups.isEmpty && !isFolded)
                    if links.isOn, showsSummary, !waits.isEmpty || (isFolded && story != nil && !told.contains(nil)) {
                        WaitingLine(waits: waits)
                    }
                }
                if links.isOn, showsSummary, !isFolded {
                    SummaryCard(subject: subject, summaries: summaries, rows: rows, waitsAbove: waits)
                }
                if !links.isOn {
                    off
                } else if isFolded {
                    EmptyView()
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
            .onChange(of: rows, initial: true) {
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
        // Its own, for who it waits on, such as Copilot at work on one of its tasks.
        if showsSummary { stories.request(links.describe(subject)) }
        for connection in connections { stories.request(connection.item) }
    }

    private func header(count: Int, canSummarize: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if showsSummary, links.isOn {
                // The chevron, the title and the count fold it. To VoiceOver, the chevron is the disclosure button and
                // the title stays a heading: an element has one role.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button(action: toggleFolded) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isFolded ? 0 : 90))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle().inset(by: -3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    .accessibilityValue((isFolded ? "Collapsed" : "Expanded") + (count > 0 ? ", \(count) linked" : ""))
                    .accessibilityHint(isFolded ? "Shows what's linked" : "Shows only who it waits on")
                    titleAndCount(count)
                }
                .contentShape(Rectangle().inset(by: -3))
                .onTapGesture(perform: toggleFolded)
                .help(isFolded ? "Show what's linked" : "Show only who it waits on")
            } else {
                titleAndCount(count)
            }
            Spacer(minLength: 8)
            if links.isOn, canSummarize {
                SummarizeButton(subject: subject, summaries: summaries)
            }
        }
    }

    private func toggleFolded() {
        let fold = !isFolded
        withAnimation(.easeOut(duration: 0.15)) { folded = fold }
        defaults.set(fold, forKey: WhereItStandsSection.foldedKey)
    }

    @ViewBuilder
    private func titleAndCount(_ count: Int) -> some View {
        Text(title)
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
                    LinksSetting(links: links, isBrief: true)
                        .padding(16)
                        .frame(width: 320)
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
            // Offscreen, the first one open, to show what's in it, where rows open in place rather than as pages.
            isExpanded: expanded.contains(ref) || (isRendering && isFirst && navigation == nil),
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

/// "Waiting on: you, to complete !4091 · Copilot, on task 5103", what waits on you in bold; or "Waiting on: no one".
private struct WaitingLine: View {
    /// None: no one.
    let waits: [ItemStory.Wait]

    var body: some View {
        // What waits on you stands out by its weight: a color could clash with its row's, such as a ready pull request's.
        let parts = waits.isEmpty ? [Text("no one").foregroundStyle(.secondary)] : waits.enumerated().map { index, wait in
            // A short one doesn't break: the line does, after a "·".
            let text = wait.text.count > 32 ? wait.text : wait.text.replacingOccurrences(of: " ", with: "\u{00A0}")
            return (index > 0 ? Text(" · ").foregroundStyle(.secondary) : Text(""))
                + (wait.who == .you ? Text(text).fontWeight(.semibold) : Text(text))
        }
        (parts.reduce(Text("Waiting on: ").fontWeight(.semibold).foregroundStyle(.secondary)) { $0 + $1 })
            .font(.system(size: 12))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            // Each says who, then what for, after a comma: they're told apart by semicolons.
            .accessibilityLabel(waits.isEmpty ? "Waiting on no one" : "Waiting on " + waits.map(\.text).joined(separator: "; "))
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
    @Environment(\.itemNavigation) private var navigation

    private var item: LinkedItem { connection.item }
    private var isChild: Bool { parent != nil }
    /// A click opens its page, where there's one, rather than its preview.
    private var navigates: Bool { navigation != nil }
    private var name: String { WhereItStandsSection.name(of: item, subject: subject, parent: parent) }

    /// Where it stands: as its source tells it, or its row's status until then.
    private var sentence: String {
        let sentence = story?.sentence.isEmpty == false ? story?.sentence ?? "" : item.status ?? ""
        return WhereItStandsSection.sentence(sentence, on: subject)
    }

    /// The state, as the lists by state draw it; a session of the app's own, by what it waits for; a work item by its type,
    /// as its details do; without a state, what kind of thing it is.
    private var symbol: (name: String, color: Color) {
        if item.ref.kind == .session, item.sent == nil { return (item.symbol, item.state?.color ?? item.color) }
        if let state = item.state {
            return (state == .done && item.ref.kind.isPullRequest ? "arrow.triangle.merge" : state.symbol, state.color)
        }
        if item.ref.kind == .workItem { return (item.symbol, item.color) }
        return (Self.kindSymbol(of: item), .secondary)
    }

    static func kindSymbol(of item: LinkedItem) -> String {
        switch item.ref.kind {
        case .pullRequest, .gitHubPullRequest: return "arrow.triangle.pull"
        case .session: return item.sent != nil ? "paperplane" : "waveform.path.ecg"
        case .workItem: return "doc.text"
        }
    }

    /// What a task you sent was sent from, by its number, when that isn't the subject or the pull request it shows under.
    private var sentFrom: String? {
        guard let sent = item.sent, !WhereItStandsSection.isSentFromHere(sent, subject: subject, parent: parent) else { return nil }
        return sent.label
    }

    private var kindName: String {
        guard item.sent != nil else { return item.ref.kind.title }
        return "Task sent to Copilot" + (sentFrom.map { " from \($0)" } ?? "")
    }

    /// Whether it opens where it lives from its row; a task you sent opens from its actions instead.
    private var canOpen: Bool { item.menu == nil && item.open != nil }
    /// Needing you or gone wrong, it opens in one click from a button before its time.
    private var opensAtOnce: Bool { canOpen && (item.state == .needsYou || item.state == .failing) }
    /// Otherwise the button shows in its time's place while you point at it.
    private var opensOnHover: Bool { canOpen && !opensAtOnce && isHovered }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: click) {
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
                    if opensAtOnce {
                        Color.clear
                            .frame(width: 22, height: 14)
                            .anchorPreference(key: QuickOpenSpot.self, value: .bounds) { $0 }
                    }
                    if let date = item.date {
                        Text(Self.ago(date))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .opacity(opensOnHover ? 0 : 1)
                            .anchorPreference(key: QuickOpenSpot.self, value: .bounds) { opensOnHover ? $0 : nil }
                            .help(date.formatted(date: .abbreviated, time: .shortened))
                    } else if opensOnHover {
                        Color.clear
                            .frame(width: 22, height: 14)
                            .anchorPreference(key: QuickOpenSpot.self, value: .bounds) { $0 }
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded && !navigates ? 90 : 0))
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
            .overlayPreferenceValue(QuickOpenSpot.self) { spot in
                if let spot {
                    GeometryReader { proxy in
                        quickOpen.position(x: proxy[spot].midX, y: proxy[spot].midY)
                    }
                }
            }
            .onHover { isHovered = $0 }
            .help(help)
            .accessibilityLabel("\(kindName), \(name). \(sentence)")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(navigates ? "Shows its page" : isExpanded ? "Hides what's known of it" : "Shows what's known of it")
            .accessibilityAction(named: "Open") { open() }
            .accessibilityAction(named: connection.isKnownElsewhere ? "Hide Link" : "Unlink") { links.unlink(subject, item.ref) }
            // To come back to it from its page.
            .id(item.ref)
            if isExpanded {
                StoryDetails(
                    item: item, story: story, isTelling: isTelling, mode: .preview
                )
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
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: item.sent != nil ? "paperplane" : "waveform.path.ecg")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if let sentFrom {
                    Text(sentFrom)
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
    }

    /// Whether its details show, where they show in place, and since when it says what it says.
    private var accessibilityValue: String {
        var parts: [String] = []
        if !navigates { parts.append(isExpanded ? "Expanded" : "Collapsed") }
        if let date = item.date { parts.append("Updated " + date.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: ", ")
    }

    /// The sentence, its opening phrase in its state's color.
    private var sentenceText: Text {
        WhereItStandsSection.sentenceText(sentence, state: item.state)
    }

    /// Opens it where it lives in one click: in the spot its row keeps for it (`QuickOpenSpot`).
    private var quickOpen: some View {
        Button(action: open) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(item.state.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(StoryDetails.openTitle(for: item.ref.kind))
        .accessibilityLabel(StoryDetails.openTitle(for: item.ref.kind))
    }

    private func open() {
        item.open?()
    }

    /// Its page, where there's one; else its preview, in place.
    private func click() {
        if let navigation, navigation.open(item.ref) { return }
        toggle()
    }

    @ViewBuilder
    private var menu: some View {
        if let menu = item.menu {
            menu()
        } else if let open = item.open {
            Button(StoryDetails.openTitle(for: item.ref.kind), action: open)
        }
        Divider()
        if navigates {
            Button("Show Details", action: click)
        } else {
            Button(isExpanded ? "Hide Details" : "Show Details", action: toggle)
        }
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

/// What's known of one thing. As a preview, in short: what to do with it first, what it said last when it's at work or
/// waits for you, a few facts, its pipelines, Copilot's own notes and what's next; then, when you ask, everything else. On
/// its page, what it said last while it's at work or waits for you, all its facts in a card, then its pipelines, its
/// actions being in the page's heading, and Copilot's notes after what's linked to it (`StoryNotesSection`).
struct StoryDetails: View {
    enum Mode {
        case preview, page
    }

    let item: LinkedItem
    let story: ItemStory?
    let isTelling: Bool
    let mode: Mode
    /// On a page, how it's linked to what you opened it from, its first fact.
    var linkFact: ItemStory.Fact?

    @LocalState private var showsMore = false

    private var showsAll: Bool { mode == .page || showsMore }
    private var account: ItemStory.Account? { story?.account.flatMap { $0.isEmpty ? nil : $0 } }
    private static let previewRuns = 3
    private static let previewNext = 3

    /// Whether it's at work or waits for you.
    static func isActive(_ item: LinkedItem) -> Bool {
        item.state == .needsYou || item.state == .running
    }

    /// What it said after its last checkpoint comes first: while it's at work or waits for you, it's what it's doing now;
    /// once it stopped, how it ended.
    static func lastWordsCaption(_ item: LinkedItem) -> String {
        isActive(item) ? "What it said last" : "How it ended"
    }

    /// Once it stopped, saying something after its last checkpoint, that checkpoint's next steps are what it planned then,
    /// not what's next.
    static func nextIsStale(_ item: LinkedItem, _ account: ItemStory.Account) -> Bool {
        !isActive(item) && account.lastMessage != nil
    }

    private var hasMore: Bool {
        guard mode == .preview, let story else { return false }
        let account = self.account
        return !story.more.isEmpty || story.runs.count > Self.previewRuns || !(account?.done.isEmpty ?? true)
            || (account?.milestones.count ?? 0) > 1 || (account?.next.count ?? 0) > Self.previewNext
            || (account.map { Self.nextIsStale(item, $0) && !$0.next.isEmpty } ?? false)
    }

    var body: some View {
        switch mode {
        case .preview: preview
        case .page: page
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            actions
            if let story {
                if let last = account?.lastMessage {
                    CopilotWords(caption: Self.lastWordsCaption(item)) {
                        ClampedText(text: last, lines: 2)
                    }
                }
                if !story.facts.isEmpty || (showsAll && !story.more.isEmpty) {
                    FactsGrid(facts: story.facts + (showsAll ? story.more : []))
                }
                if !story.runs.isEmpty {
                    RunsView(runs: showsAll ? story.runs : Array(story.runs.prefix(Self.previewRuns)))
                }
                if let account {
                    notes(account)
                }
                footnote(story)
                if hasMore {
                    Button(showsMore ? "Show Less" : "Show All") {
                        withAnimation(.easeOut(duration: 0.15)) { showsMore.toggle() }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            } else if isTelling {
                reading
            }
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let story {
                if let last = account?.lastMessage {
                    CopilotWords(caption: Self.lastWordsCaption(item)) {
                        ClampedText(text: last, lines: 4)
                    }
                }
                let facts = pageFacts(story)
                if !facts.isEmpty {
                    PageFacts(facts: facts)
                }
                if !story.runs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        PageSectionHeader(title: "Pipelines", count: story.runs.count)
                        RunsView(runs: story.runs, showsCaption: false)
                    }
                }
                footnote(story)
            } else if isTelling {
                reading
            } else if let linkFact {
                PageFacts(facts: [linkFact])
            }
        }
    }

    /// All its facts, how it's linked first, but where it is, which the page's heading says.
    private func pageFacts(_ story: ItemStory) -> [ItemStory.Fact] {
        let place = item.place.map(Self.plain)
        return (linkFact.map { [$0] } ?? []) + (story.facts + story.more).filter { Self.plain($0.value) != place }
    }

    /// "shop-web · saved-items" and "shop-web saved-items" alike.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "·", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    @ViewBuilder
    private func footnote(_ story: ItemStory) -> some View {
        if let footnote = story.footnote {
            Text(footnote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var reading: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("Reading what's known of it…")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11.5))
    }

    /// Opening it, or its own actions; why it's here is in its row's tooltip.
    private var actions: some View {
        StoryActions(item: item)
            .controlSize(.small)
    }

    /// Copilot's notes, as it wrote them: its overview, what's next, and, when you ask, what it did, the story so far a
    /// line a checkpoint, and what it said last.
    private func notes(_ account: ItemStory.Account) -> some View {
        CopilotWords(caption: Self.caption(account)) {
            VStack(alignment: .leading, spacing: 8) {
                if let overview = account.overview, !overview.isEmpty {
                    ClampedText(text: overview, lines: 3)
                }
                let stale = Self.nextIsStale(item, account)
                if !account.next.isEmpty, !stale {
                    StoryList(title: "What's next", lines: showsAll ? account.next : Array(account.next.prefix(Self.previewNext)), symbol: "arrow.right")
                }
                if showsAll {
                    if !account.next.isEmpty, stale {
                        StoryList(title: "Planned at its last checkpoint", lines: account.next, symbol: "arrow.right")
                    }
                    if !account.done.isEmpty {
                        StoryList(title: "What it did", lines: account.done, symbol: "checkmark")
                    }
                    if account.milestones.count > 1 {
                        Milestones(account: account)
                    }
                }
            }
        }
    }

    /// "Copilot's notes · 3h ago".
    static func caption(_ account: ItemStory.Account) -> String {
        guard let date = account.date else { return account.source }
        return "\(account.source) · \(StoryTime.ago(date))"
    }

    /// "Open in Azure DevOps", for what opens a thing of this kind.
    static func openTitle(for kind: ItemRef.Kind) -> String {
        kind.openTitle
    }
}

extension ItemRef.Kind {
    /// "Open in Azure DevOps", for what opens a thing of this kind where it lives.
    package var openTitle: String {
        switch self {
        case .workItem, .pullRequest: return "Open in Azure DevOps"
        case .gitHubPullRequest: return "Open on GitHub"
        case .session: return "Open in Copilot"
        }
    }
}

/// Copilot's notes on a page, after what's linked to it: its overview and what's next, and, when you ask, what it did,
/// the story so far and what it said last.
struct StoryNotesSection: View {
    let item: LinkedItem
    let account: ItemStory.Account

    @LocalState private var showsAll = false

    private static let shownNext = 3

    /// What it said after its last checkpoint shows at the top of the page; once it stopped, that checkpoint's next steps
    /// are what it planned then.
    private var nextIsStale: Bool { StoryDetails.nextIsStale(item, account) }

    private var hasMore: Bool {
        (nextIsStale ? !account.next.isEmpty : account.next.count > Self.shownNext) || !account.done.isEmpty
            || account.milestones.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PageSectionHeader(title: Self.title(account.source), trailing: account.date.map { StoryTime.ago($0) })
            CopilotWords(caption: nil) {
                VStack(alignment: .leading, spacing: 8) {
                    if let overview = account.overview, !overview.isEmpty {
                        ClampedText(text: overview, lines: 3)
                    }
                    if !account.next.isEmpty, !nextIsStale {
                        let next = showsAll ? account.next : Array(account.next.prefix(Self.shownNext))
                        StoryList(title: "What's next", lines: next, symbol: "arrow.right")
                    }
                    if showsAll {
                        if !account.next.isEmpty, nextIsStale {
                            StoryList(title: "Planned at its last checkpoint", lines: account.next, symbol: "arrow.right")
                        }
                        if !account.done.isEmpty {
                            StoryList(title: "What it did", lines: account.done, symbol: "checkmark")
                        }
                        if account.milestones.count > 1 {
                            Milestones(account: account)
                        }
                    }
                    if hasMore {
                        Button(showsAll ? "Show Less" : "Show All Notes") {
                            withAnimation(.easeOut(duration: 0.15)) { showsAll.toggle() }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }
                }
            }
        }
    }

    /// "Copilot's notes" as a heading: "Copilot's Notes".
    static func title(_ source: String) -> String {
        source.split(separator: " ").map { word in word.prefix(1).uppercased() + word.dropFirst() }.joined(separator: " ")
    }
}

/// A part's heading on a page, as the work item's details have them: "Pipelines 2", "Copilot's Notes   3h ago".
struct PageSectionHeader: View {
    let title: String
    var count: Int?
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let count {
                Text(String(count))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            if let trailing {
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A page's facts, as the work item's details show its fields: labels on the right of their column, in a card.
private struct PageFacts: View {
    let facts: [ItemStory.Fact]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 9) {
            ForEach(facts, id: \.self) { fact in
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
        .font(.system(size: 12.5))
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassCard(cornerRadius: 12, raised: true))
    }
}

/// When something happened, in one unit: "just now", "41m ago", "3h ago", "2d ago".
enum StoryTime {
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let short = StoryRow.ago(date, now: now)
        return short == "now" ? "just now" : "\(short) ago"
    }
}

/// What opens a thing: its own actions, for a task you sent to Copilot; or a button that opens it where it lives.
struct StoryActions: View {
    let item: LinkedItem

    var body: some View {
        if let menu = item.menu {
            Menu {
                menu()
            } label: {
                if item.sent != nil {
                    Label("Copilot", systemImage: "paperplane")
                } else {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
            .menuStyle(.button)
            .fixedSize()
        } else if let open = item.open {
            Button(action: open) {
                Label(StoryDetails.openTitle(for: item.ref.kind), systemImage: "arrow.up.forward.app")
            }
            .fixedSize()
        }
    }
}

/// Where a row keeps its open button: before its time, or in its time's place while you point at it.
private struct QuickOpenSpot: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
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
    let caption: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption {
                StoryCaption(text: caption)
            }
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
struct ClampedText: View {
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
    /// Whether it says what it is, where no heading does.
    var showsCaption = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsCaption {
                StoryCaption(text: runs.count == 1 ? "Pipeline" : "Pipelines")
            }
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
        // One with a page opens it; one without reads as text, not as a button that's off.
        if let url = run.url {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                content(opens: true)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help("Open \(run.name)'s run")
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Opens its run")
        } else {
            content(opens: false)
                .help(run.name)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
        }
    }

    private func content(opens: Bool) -> some View {
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
                    .foregroundStyle(run.state == .failing ? AnyShapeStyle(ItemState.failing.textColor) : AnyShapeStyle(.secondary))
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
            if opens {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(opens && isHovered ? 0.06 : 0))
        )
        .contentShape(Rectangle())
    }

    private var accessibilityText: String {
        "\(run.name): \(status)" + (run.detail.map { ". \($0)" } ?? "")
    }

    /// "Failed at Run tests · 12m ago".
    private var status: String {
        guard let date = run.date, run.state != .running else { return run.status }
        return "\(run.status) · \(StoryTime.ago(date))"
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
struct StoryCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
