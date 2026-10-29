import AppKit
import BriefBarCore
import Combine
import SwiftUI

/// What a source says about one of its things, for the links on other things' rows and in the picker.
package struct LinkedItem {
    package var ref: ItemRef
    /// Short, for a capsule: "5101", "!4071", "#12", or a session's name.
    package var label: String
    /// Its title, or a session's name.
    package var title: String
    package var symbol: String
    package var color: Color
    /// What it means for you now, so the one that needs you most shows first.
    package var state: ItemState?
    /// Where it stands, briefly: "Active", "Failing", "Waiting for your answer".
    package var status: String?
    /// Where it stands, briefly, to share outside this Mac, such as with Copilot for a summary, when `status` says what only
    /// this Mac knows, such as that it needs you because someone sent it to you in a chat. Nil when `status` can be shared.
    package var sharedStatus: String?
    /// Where it is: a repository or a project.
    package var place: String?
    /// What links it by branch, and helps suggest what goes with it.
    package var hint: BranchHint?
    /// When it last changed, for the newest first.
    package var date: Date?
    /// Opens it; nil when it can't be opened.
    package var open: (() -> Void)?
    /// Its own menu instead of opening it, such as a task's that you sent to Copilot.
    package var menu: (() -> AnyView)?
    /// A task you sent to Copilot: what for, and where from.
    package var sent: SentToCopilot?
    /// Its page on the web, for Copy Link, where its reference doesn't say it: an Azure DevOps pull request's or work item's.
    package var url: URL?
    /// How many parts it has that aren't linked to it, such as a story's or a bug's tasks: something to sum up besides
    /// what's linked to it.
    package var parts: Int

    package init(
        ref: ItemRef, label: String, title: String, symbol: String, color: Color, state: ItemState? = nil, status: String? = nil,
        sharedStatus: String? = nil, place: String? = nil, hint: BranchHint? = nil, date: Date? = nil, open: (() -> Void)? = nil,
        menu: (() -> AnyView)? = nil, sent: SentToCopilot? = nil, url: URL? = nil, parts: Int = 0
    ) {
        self.ref = ref
        self.label = label
        self.title = title
        self.symbol = symbol
        self.color = color
        self.state = state
        self.status = status
        self.sharedStatus = sharedStatus
        self.place = place
        self.hint = hint
        self.date = date
        self.open = open
        self.menu = menu
        self.sent = sent
        self.url = url
        self.parts = parts
    }

    /// Its link, for Copy Link: its page, or what its reference says, a GitHub pull request's page or a session's link in
    /// the GitHub Copilot app.
    package var link: URL? {
        if let url { return url }
        switch ref.kind {
        case .gitHubPullRequest: return URL(string: "https://github.com/\(ref.scope)/pull/\(ref.id)")
        case .session: return sent == nil ? URL(string: "ghapp://sessions/\(ref.id)") : nil
        case .workItem, .pullRequest: return nil
        }
    }

    /// "Work Item 5101 · Save items for later", "Pull Request !4071 · Add retry…", or a session's name, for menus.
    package var menuTitle: String {
        let name = label == title ? title : "\(label) · \(title)"
        return ref.kind == .session ? name : "\(ref.kind.title) \(name)"
    }

    /// Where it stands, briefly, to share outside this Mac: `sharedStatus`, or else `status`.
    package var statusToShare: String? {
        sharedStatus ?? status
    }

    /// What a session needs from you, in a word or two, for its capsule.
    var stateWord: String? {
        switch state {
        case .needsYou?: return "Needs you"
        case .failing?: return ref.kind == .session ? "Stopped" : "Failing"
        case .running?: return "Working"
        case .done?: return ref.kind == .session ? "Done" : "Ready"
        case nil: return nil
        }
    }
}

/// A task you sent to Copilot, as its row says it: what for, such as "Fix the Build", or nil for a work item's; and the
/// work item or pull request you sent it from.
package struct SentToCopilot: Equatable, Sendable {
    package var action: String?
    package var from: ItemRef?
    /// What it was sent from, by its number and its title, when known: "5112", "Round half up in the coupon service".
    package var label: String?
    package var title: String?

    package init(action: String? = nil, from: ItemRef?, label: String? = nil, title: String? = nil) {
        self.action = action
        self.from = from
        self.label = label
        self.title = title
    }
}

/// What the views compare to tell whether a thing changed: everything but what clicking it does.
extension LinkedItem: Equatable {
    package static func == (lhs: LinkedItem, rhs: LinkedItem) -> Bool {
        lhs.ref == rhs.ref && lhs.label == rhs.label && lhs.title == rhs.title && lhs.symbol == rhs.symbol
            && lhs.color == rhs.color && lhs.state == rhs.state && lhs.status == rhs.status && lhs.sharedStatus == rhs.sharedStatus
            && lhs.place == rhs.place && lhs.hint == rhs.hint && lhs.date == rhs.date && (lhs.menu == nil) == (rhs.menu == nil)
            && (lhs.open == nil) == (rhs.open == nil) && lhs.sent == rhs.sent && lhs.url == rhs.url && lhs.parts == rhs.parts
    }
}

extension ItemRef.Kind {
    /// "Work Item", "Pull Request", "Copilot Session".
    package var title: String {
        switch self {
        case .workItem: return "Work Item"
        case .pullRequest, .gitHubPullRequest: return "Pull Request"
        case .session: return "Copilot Session"
        }
    }

    /// "work items", for sentences.
    package var plural: String {
        switch self {
        case .workItem: return "work items"
        case .pullRequest, .gitHubPullRequest: return "pull requests"
        case .session: return "Copilot sessions"
        }
    }

    /// What a source turned off takes with it.
    static func of(_ source: SourceID) -> Set<ItemRef.Kind> {
        switch source {
        case .azureDevOps: return [.workItem, .pullRequest]
        case .github: return [.gitHubPullRequest]
        case .copilot: return [.session]
        case .teams: return []
        }
    }
}

/// Something linked to a thing, as its row shows it.
package struct LinkConnection: Identifiable {
    package var item: LinkedItem
    /// Why, the most telling first; empty for one linked through a pull request.
    package var origins: [LinkOrigin]
    /// The pull request it's linked through.
    package var via: LinkedItem?
    package var isHidden: Bool
    /// Taking it away only hides it in BriefBar: something other than you links them.
    package var isKnownElsewhere: Bool

    package var id: ItemRef { item.ref }

    /// "Linked in Azure DevOps", "Through !4071".
    package var reason: String {
        if let via { return "Through \(via.label)" }
        return origins.map(\.title).joined(separator: ", ")
    }
}

/// Show Links: which work items, pull requests and Copilot sessions go together, on their rows. Each source tells it what
/// it knows, and what it lists; you add links and hide them here, in BriefBar only. It's off until you turn it on, and
/// shows nothing then, while the sources read nothing more for it.
@MainActor
package final class Links: ObservableObject {
    package static let enabledKey = "links.enabled"

    /// Show Links. Sources read what links need only while it's on.
    @Published package private(set) var isOn: Bool
    @Published package private(set) var graph = LinkGraph()
    /// The sources that stop, as each does, once what they said is gone: what was made of it, such as a summary, goes too.
    package let withdrawn = PassthroughSubject<SourceID, Never>()

    private let defaults: UserDefaults
    private var edits: LinkEdits
    private var facts: [SourceID: Set<ItemLink>] = [:]
    private var described: [SourceID: [ItemRef: LinkedItem]] = [:]

    /// - Parameter isDemo: the demo shows links, in preferences that are thrown away.
    package init(defaults: UserDefaults, isDemo: Bool) {
        self.defaults = defaults
        isOn = isDemo || defaults.bool(forKey: Self.enabledKey)
        edits = LinkEdits.load(from: defaults)
        let kept = edits
        edits.forget(before: Date().addingTimeInterval(-LinkEdits.lifetime))
        if edits != kept { edits.save(to: defaults) }
        rebuild()
    }

    package func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        defaults.set(on, forKey: Self.enabledKey)
        Log.app.info("Show Links \(on ? "on" : "off", privacy: .public)")
        rebuild()
    }

    // MARK: What the sources know

    /// What a source knows now: the links it read, and its things that links can show. It replaces what it said before.
    package func publish(_ source: SourceID, links: [ItemLink], items: [LinkedItem]) {
        var byRef: [ItemRef: LinkedItem] = [:]
        for item in items where byRef[item.ref] == nil {
            byRef[item.ref] = item
        }
        let links = Set(links)
        guard facts[source] != links || described[source] != byRef else { return }
        facts[source] = links
        described[source] = byRef
        rebuild()
    }

    /// A source stopped: what it said goes with it.
    package func withdraw(_ source: SourceID) {
        guard facts[source] != nil || described[source] != nil else { return }
        facts[source] = nil
        described[source] = nil
        rebuild()
        withdrawn.send(source)
    }

    /// Forgets the links you added or hid that involve a source's things, when you turn it off.
    package func forget(_ source: SourceID) {
        let kinds = ItemRef.Kind.of(source)
        guard !kinds.isEmpty else { return }
        edits.forget(kinds)
        save()
        let said = facts[source] != nil || described[source] != nil
        facts[source] = nil
        described[source] = nil
        rebuild()
        if said { withdrawn.send(source) }
    }

    private func rebuild() {
        let items = described.values.flatMap(\.values)
        var sessions: [ItemRef: BranchHint] = [:]
        var pullRequests: [ItemRef: BranchHint] = [:]
        for item in items {
            guard let hint = item.hint else { continue }
            if item.ref.kind == .session { sessions[item.ref] = hint }
            if item.ref.kind.isPullRequest { pullRequests[item.ref] = hint }
        }
        let byBranch = BranchLinks.links(sessions: sessions, pullRequests: pullRequests)
        graph = LinkGraph(links: facts.values.flatMap { $0 } + byBranch, edits: edits)
    }

    // MARK: What rows show

    /// What a thing is linked to, as its row shows them: work items, pull requests, then sessions, each the one that needs
    /// you most first, then the newest. Nothing while Show Links is off.
    package func connections(of ref: ItemRef, includingHidden: Bool = false) -> [LinkConnection] {
        guard isOn else { return [] }
        return graph.connections(of: ref)
            .filter { includingHidden || !$0.isHidden }
            .map { connection in
                LinkConnection(
                    item: describe(connection.item), origins: connection.origins, via: connection.via.map(describe),
                    isHidden: connection.isHidden, isKnownElsewhere: connection.isKnownElsewhere
                )
            }
            .sorted(by: Self.showsFirst)
    }

    static func showsFirst(_ lhs: LinkConnection, _ rhs: LinkConnection) -> Bool {
        let (left, right) = (lhs.item, rhs.item)
        if left.ref.kind.family != right.ref.kind.family { return left.ref.kind < right.ref.kind }
        if lhs.isHidden != rhs.isHidden { return !lhs.isHidden }
        let urgency = { (item: LinkedItem) in item.state.map { ItemState.allCases.firstIndex(of: $0) ?? 9 } ?? 9 }
        if urgency(left) != urgency(right) { return urgency(left) < urgency(right) }
        if left.date != right.date { return (left.date ?? .distantPast) > (right.date ?? .distantPast) }
        return left.ref < right.ref
    }

    /// A thing, as the source that lists it says it, or what its reference alone says.
    package func describe(_ ref: ItemRef) -> LinkedItem {
        for source in SourceID.allCases {
            if let item = described[source]?[ref] { return item }
        }
        return Self.fallback(ref)
    }

    /// Whether a source says what it is, rather than only its reference.
    package func isDescribed(_ ref: ItemRef) -> Bool {
        SourceID.allCases.contains { described[$0]?[ref] != nil }
    }

    /// Things in links that no source describes, of these kinds.
    package func unknown(_ kinds: Set<ItemRef.Kind>) -> Set<ItemRef> {
        guard isOn else { return [] }
        let known = Set(described.values.flatMap(\.keys))
        return graph.items.filter { kinds.contains($0.kind) && !known.contains($0) }
    }

    /// Everything in a link of these kinds, hidden or not, described or not: for a source to tell what it lists from what
    /// it should look up. Nothing while Show Links is off.
    package func linked(_ kinds: Set<ItemRef.Kind>) -> Set<ItemRef> {
        guard isOn else { return [] }
        return graph.items.filter { kinds.contains($0.kind) }
    }

    /// What only its reference says: a GitHub pull request or a session can still be opened.
    static func fallback(_ ref: ItemRef) -> LinkedItem {
        switch ref.kind {
        case .workItem:
            return LinkedItem(ref: ref, label: ref.id, title: "Work item \(ref.id)", symbol: "doc.text", color: .secondary)
        case .pullRequest:
            return LinkedItem(ref: ref, label: "!\(ref.id)", title: "Pull request \(ref.id)", symbol: "arrow.triangle.pull", color: .secondary)
        case .gitHubPullRequest:
            let url = URL(string: "https://github.com/\(ref.scope)/pull/\(ref.id)")
            return LinkedItem(
                ref: ref, label: "#\(ref.id)", title: "\(ref.scope)#\(ref.id)", symbol: "arrow.triangle.pull", color: .secondary,
                place: ref.scope, open: url.map { url in { NSWorkspace.shared.open(url) } }
            )
        case .session:
            let url = URL(string: "ghapp://sessions/\(ref.id)")
            return LinkedItem(
                ref: ref, label: "Session", title: "Copilot session", symbol: "waveform.path.ecg", color: .secondary,
                open: url.map { url in { NSWorkspace.shared.open(url) } }
            )
        }
    }

    // MARK: Your links

    /// Links two things, in BriefBar only.
    package func link(_ lhs: ItemRef, _ rhs: ItemRef) {
        guard ItemRef.canLink(lhs, rhs) else { return }
        edits.link(lhs, rhs)
        save()
        rebuild()
    }

    /// Takes away a link you added; one a source knows is hidden here instead, until you show it again.
    package func unlink(_ lhs: ItemRef, _ rhs: ItemRef) {
        let connection = graph.connections(of: lhs).first { $0.item == rhs }
        edits.unlink(lhs, rhs, hides: connection?.isKnownElsewhere ?? false)
        save()
        rebuild()
    }

    package func showAgain(_ lhs: ItemRef, _ rhs: ItemRef) {
        edits.showAgain(lhs, rhs)
        save()
        rebuild()
    }

    /// Whether two things show as linked.
    package func isLinked(_ lhs: ItemRef, _ rhs: ItemRef) -> Bool {
        graph.visibleConnections(of: lhs).contains { $0.item == rhs }
    }

    private func save() {
        edits.save(to: defaults)
    }

    // MARK: The picker

    /// Everything a thing could be linked to, from every source that's on.
    package func candidates(for ref: ItemRef) -> [LinkedItem] {
        var seen: Set<ItemRef> = []
        var all: [LinkedItem] = []
        for source in SourceID.allCases {
            for item in (described[source] ?? [:]).values where ItemRef.canLink(ref, item.ref) && seen.insert(item.ref).inserted {
                all.append(item)
            }
        }
        return all.sorted { lhs, rhs in
            if lhs.ref.kind.family != rhs.ref.kind.family { return lhs.ref.kind.family < rhs.ref.kind.family }
            if lhs.date != rhs.date { return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast) }
            return lhs.ref < rhs.ref
        }
    }

    /// The candidates likeliest to go with a thing.
    package func suggestions(for ref: ItemRef, among candidates: [LinkedItem]) -> [ItemRef] {
        let subject = describe(ref)
        return LinkSuggestions.rank(
            candidates.filter { !isLinked(ref, $0.ref) }.map { LinkCandidate(ref: $0.ref, title: $0.title, hint: $0.hint, date: $0.date) },
            for: LinkCandidate(ref: ref, title: subject.title, hint: subject.hint, date: subject.date)
        )
    }

    /// Opens the window that links a thing to others.
    package func pick(for ref: ItemRef) {
        LinkPicker.shared.show(for: ref, links: self)
    }
}

extension ItemRef.Kind {
    /// Pull requests from either service show together.
    var family: Int {
        switch self {
        case .workItem: return 0
        case .pullRequest, .gitHubPullRequest: return 1
        case .session: return 2
        }
    }
}
