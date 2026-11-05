import Foundation

// What the Pull Requests pages show of the order, beside the rows they have: which view of By Mission you chose, a
// mission's title, which of its pull requests a page lists, and the capsule each row shows, with its tone. Only words and
// choices: the views draw them.

// MARK: - The view

/// By Mission's two views, which you switch between in the page's header, and which both pages remember as one choice.
public enum OrderView: String, CaseIterable, Sendable {
    /// One card for each mission, its rows with the graph beside them.
    case list
    /// Each mission a band, its pull requests in merge waves.
    case map

    public static let defaultsKey = "order.view"

    /// What you chose last, List until you choose.
    public static func load(from defaults: some SettingsStorage) -> OrderView {
        defaults.string(forKey: defaultsKey).flatMap(OrderView.init(rawValue:)) ?? .list
    }

    public func save(to defaults: some SettingsStorage) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    public var title: String {
        switch self {
        case .list: return "List"
        case .map: return "Map"
        }
    }
}

// MARK: - A row's capsule

/// How a row's order capsule stands out: quiet for what needs nothing; the tint for what can merge next; plain for what
/// waits; orange where completing it now would go against its order, or its order needs checking.
public enum OrderCapsuleTone: Equatable, Sendable {
    case quiet
    case next
    case waiting
    case warning
}

extension OrderText {
    /// A row's capsule's tone. One that waits for others turns orange when its source says it's ready to complete, so it
    /// isn't completed out of order.
    /// - Parameter isReady: its source says it's ready to complete.
    public static func tone(of step: OrderStep, isReady: Bool) -> OrderCapsuleTone {
        if step.standing.needsChecking { return .warning }
        if step.standing.waitsForOthers { return isReady ? .warning : .waiting }
        switch step.standing {
        case .next: return .next
        case .notVisible: return .waiting
        default: return .quiet
        }
    }

    /// What a row's capsule says in full, for its tooltip and for VoiceOver: where it stands in its order, why, and when its
    /// session suggests reviewing it. Nil for one in a group with no order.
    /// - Parameter isReady: its source says it's ready to complete.
    public static func sentence(of step: OrderStep, isReady: Bool = false) -> String? {
        var parts: [String] = []
        if let standing = standing(step) {
            parts.append(isReady && step.standing.waitsForOthers ? "\(standing) · completing it now would go against its order" : standing)
        }
        for note in step.notes {
            parts.append(Self.note(note, of: step.ref))
        }
        if let review = step.review {
            parts.append(Self.review(review, of: step.ref))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }
}

extension OrderBoard {
    /// The mission a pull request's capsule speaks for, and its step there: the first, as they're sorted, that has it in
    /// its order, else the first it's stacked with, or that has it for its story. Nil when it's in none, or only in a group
    /// of a session's pull requests, which has no capsule. A story's pull request with no order known has none either, but
    /// says what its notes say, and shows its mission.
    public static func step(for ref: ItemRef, in missions: [OrderMission]) -> (mission: OrderMission, step: OrderStep)? {
        for mission in missions where !mission.isFamily {
            if let step = mission.steps.first(where: { $0.ref == ref }) { return (mission, step) }
        }
        for mission in missions where !mission.isFamily {
            if let step = (mission.attached + mission.sameStory).first(where: { $0.ref == ref }) { return (mission, step) }
        }
        return nil
    }
}

// MARK: - A mission on a page

extension OrderMission {
    /// Its pull requests of these kinds, as a page of their source lists them, merged ones included.
    public func steps(of kinds: Set<ItemRef.Kind>) -> [OrderStep] {
        steps.filter { kinds.contains($0.ref.kind) }
    }

    /// Whether a page of these kinds shows it: it has one of their pull requests, in its order or stacked with it.
    public func shows(_ kinds: Set<ItemRef.Kind>) -> Bool {
        steps.contains { kinds.contains($0.ref.kind) } || attached.contains { kinds.contains($0.ref.kind) }
    }

    /// How many of its pull requests are of other kinds than a page's: "+1 on GitHub".
    public func count(outside kinds: Set<ItemRef.Kind>) -> Int {
        steps.filter { !kinds.contains($0.ref.kind) }.count
    }

    /// The merged and closed ones, which fold into one line.
    public var folded: [OrderStep] {
        steps.filter { $0.status == .merged || $0.status == .closed }
    }
}

extension OrderText {
    /// A mission's title as BriefBar names it without Apple Intelligence or you: the name of the session that told its
    /// order, or that its pull requests were opened under; a story's title, or else "Work Item 5101"; else its first pull
    /// request's title, or else its label.
    /// - Parameter name: what a source calls a session, a work item or a pull request, when it says.
    public static func title(of mission: OrderMission, name: (ItemRef) -> String?) -> String {
        switch mission.kind {
        case .declared(_, _, let declaredBy, _):
            if let declaredBy, let session = name(declaredBy) { return session }
        case .family(let session):
            if let session = name(session) { return session }
        case .story(let story):
            return name(story) ?? "Work Item \(story.id)"
        case .stack:
            break
        }
        let first = mission.steps.first { $0.status != .merged && $0.status != .closed } ?? mission.steps.first
        guard let first else { return "Pull requests" }
        return name(first.ref) ?? first.ref.fullOrderLabel
    }

    /// What kind of group a mission is, after its title and its story: "GitHub stack 41", "Stacked branches", "No order
    /// known" for a session's pull requests or a story's; nil for a session's order, whose header says who told it.
    public static func kind(of mission: OrderMission) -> String? {
        switch mission.key {
        case .plan: return nil
        case .stack(_, let number): return "GitHub stack \(number)"
        case .chain: return "Stacked branches"
        case .family, .story: return "No order known"
        }
    }

    /// The story a mission is for, after its title, "User Story 5101": nil for one that isn't for one story, or when its
    /// title says it already, as "Work Item 5101" does while BriefBar can't read the story.
    public static func story(of mission: OrderMission, title: String) -> String? {
        guard let story = mission.story else { return nil }
        let label = Self.story(story)
        return label == title ? nil : label
    }

    /// What a story's mission says of itself: "Its story: ‘Checkout redesign’. Listed in the order of its tasks in the
    /// backlog. Nothing says which merges first." Stacked ones among them say how they're stacked on their rows.
    /// - Parameter title: the story's title, when BriefBar read it.
    public static func storyHelp(_ mission: OrderMission, title: String?) -> String? {
        guard mission.isStory, let story = mission.story else { return nil }
        let its = title.map { "Its story: ‘\($0)’." } ?? "Its story: \(Self.story(story))."
        return "\(its) Listed in the order of its tasks in the backlog. Nothing says which merges first."
    }

    /// The head of the part of a session's order with the pull requests for its story it doesn't name.
    public static let sameStory = "Same story · not in this order"

    /// At By Mission's foot while Show Links is off, as stories need it.
    public static let storiesNeedShowLinks = "Turn on Show Links to put each story's pull requests together."

    /// Who named a mission, in its header's help.
    public static let namedByYou = "You named it"
    public static let namedByAppleIntelligence = "Named by Apple Intelligence from its pull requests, work items and sessions"

    /// The session a session's pull requests' mission was opened under, in its help once it has another name than that
    /// session's: "Opened under ‘Cart’".
    public static func openedUnder(_ mission: OrderMission, name: (ItemRef) -> String?) -> String? {
        guard case .family(let session) = mission.kind, let named = name(session) else { return nil }
        return "Opened under ‘\(named)’"
    }

    /// What Rename… says at the cap, keeping none.
    public static let namesAtTheCap = """
        BriefBar keeps up to \(MissionNames.mostNames) names you give missions. Use BriefBar's Name on one you no longer need \
        first.
        """

    /// Who told a session's order, and when: "Told by ‘Ship the cart’ · revision 3"; nil for any other mission.
    public static func told(_ mission: OrderMission, name: (ItemRef) -> String?) -> String? {
        guard case .declared(_, let revision, let declaredBy, _) = mission.kind else { return nil }
        let who = declaredBy.flatMap(name).map { "Told by ‘\($0)’" } ?? "Told by a session"
        return revision > 1 ? "\(who) · revision \(revision)" : who
    }

    /// "1 session", "3 sessions".
    public static func sessions(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }

    /// "+1 on GitHub", "+2 on Azure DevOps", for a mission's pull requests another page lists.
    public static func elsewhere(_ count: Int, on source: String) -> String {
        "+\(count) on \(source)"
    }

    /// The line its merged and closed ones fold into: "1 merged", "2 merged · 1 closed", "1 closed".
    public static func folded(_ steps: [OrderStep]) -> String {
        let merged = steps.filter { $0.status == .merged }.count
        let closed = steps.filter { $0.status == .closed }.count
        return [merged > 0 ? "\(merged) merged" : nil, closed > 0 ? "\(closed) closed" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// What a page says of a mission that hasn't changed for a month.
    public static let stale = "Not updated for 30 days"

    /// What a quiet row says of a pull request a page's source doesn't list: "!4118 · Can't see it".
    public static func placeholder(_ step: OrderStep) -> String {
        let label = step.ref.shortOrderLabel
        switch step.status {
        case .merged: return "\(label) · Merged"
        case .closed: return "\(label) · Closed without merging"
        case .unknown(.sourceOff): return "\(label) · \(source(of: step.ref)) is off"
        default: return "\(label) · Can't see it"
        }
    }
}

// MARK: - What the Map doesn't draw

extension OrderMap {
    /// Of the pull requests a page lists, how many the Map doesn't draw: those in no mission, and those stacked with a
    /// mission's pull requests but not in its order, which List shows under it. A mission too big for the Map shows its
    /// list instead, with them all.
    public static func undrawn(_ refs: [ItemRef], in missions: [OrderMission]) -> (inNoMission: Int, notInOrder: Int) {
        var shown: Set<ItemRef> = []
        for mission in missions {
            shown.formUnion(mission.steps.map(\.ref))
            if mission.steps.count > mostPullRequests { shown.formUnion((mission.attached + mission.sameStory).map(\.ref)) }
        }
        var counts = (inNoMission: 0, notInOrder: 0)
        for ref in Set(refs) where !shown.contains(ref) {
            if missions.contains(where: { $0.contains(ref) }) {
                counts.notInOrder += 1
            } else {
                counts.inNoMission += 1
            }
        }
        return counts
    }
}

extension OrderText {
    /// What the Map says of a page's pull requests it doesn't draw: "3 pull requests aren't in a mission. List shows
    /// them.", "1 pull request isn't in its mission's order. List shows it.", or both. Nil when it draws them all.
    public static func notOnTheMap(inNoMission: Int, notInOrder: Int) -> String? {
        switch (inNoMission, notInOrder) {
        case (0, 0):
            return nil
        case (_, 0):
            return notInAMission(inNoMission)
        case (0, 1):
            return "1 pull request isn't in its mission's order. List shows it."
        case (0, _):
            return "\(notInOrder) pull requests aren't in their mission's order. List shows them."
        default:
            let none = inNoMission == 1 ? "1 pull request isn't" : "\(inNoMission) pull requests aren't"
            let order = notInOrder == 1 ? "1 isn't in its" : "\(notInOrder) aren't in their"
            return "\(none) in a mission, and \(order) mission's order. List shows them."
        }
    }
}

// MARK: - Paths

extension OrderLine {
    /// What hovering a pull request lights up: it, what goes before it and what comes after it, by these lines, directly or
    /// through others.
    public static func related(to ref: ItemRef, by lines: [OrderLine]) -> Set<ItemRef> {
        var related: Set<ItemRef> = [ref]
        for forward in [true, false] {
            var frontier = [ref]
            while let current = frontier.popLast() {
                for line in lines {
                    let (from, to) = forward ? (line.edge.before, line.edge.after) : (line.edge.after, line.edge.before)
                    if from == current, related.insert(to).inserted { frontier.append(to) }
                }
            }
        }
        return related
    }
}
