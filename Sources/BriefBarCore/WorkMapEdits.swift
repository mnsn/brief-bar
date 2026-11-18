import Foundation

// What you and Copilot sessions changed of My Work's Map: the lines they added between its cards and steps, or took away,
// and its steps, work with no pull request or work item yet, such as API tests or enabling it in production. Only the Map
// changes for them: no order, stage, Up Next slot, count or agent's other answer does. Yours are kept by the app
// (`order.map.edits`), what sessions tell by `--mcp` (`order.map.told`), each change with when it was made, so that where
// both changed the same line, or the same step's name or whether it's done, the latest shows. Kept by reference, a step's
// ID and dates; a step's name is what you typed, or what a session told, never a title BriefBar read.

// MARK: - Nodes

/// A node of My Work's Map: a card of the Board, or a step.
public enum MapNodeID: Hashable, Comparable, Sendable, CustomStringConvertible {
    case card(ItemRef)
    case step(UUID)

    /// Its reference, for a card.
    public var ref: ItemRef? {
        if case .card(let ref) = self { return ref }
        return nil
    }

    /// Its ID, for a step.
    public var stepID: UUID? {
        if case .step(let id) = self { return id }
        return nil
    }

    /// `pullRequest/contoso/4102`, `step/<id>`: what the preferences keep.
    public var description: String {
        switch self {
        case .card(let ref): ref.description
        case .step(let id): "step/" + id.uuidString.lowercased()
        }
    }

    /// The node a description names, checked: nil for anything else, a session too, which is no node.
    public init?(_ description: String) {
        if description.hasPrefix("step/") {
            guard let id = UUID(uuidString: String(description.dropFirst("step/".count))) else { return nil }
            self = .step(id)
        } else if let ref = ItemRef(description), ref.kind != .session {
            self = .card(ref)
        } else {
            return nil
        }
    }

    public static func < (lhs: MapNodeID, rhs: MapNodeID) -> Bool {
        switch (lhs, rhs) {
        case (.card(let left), .card(let right)): left < right
        case (.card, .step): true
        case (.step, .card): false
        case (.step(let left), .step(let right)): left.uuidString < right.uuidString
        }
    }
}

/// Who changed something of the Map: you, in BriefBar, or a session, through BriefBar's tools for agents.
public enum MapAuthor: Hashable, Sendable, CustomStringConvertible {
    case you
    /// A session, by its reference; nil for an agent that didn't say which, as in VS Code.
    case session(ItemRef?)

    /// `you`, `session/<id>`, `session`: what the preferences keep.
    public var description: String {
        switch self {
        case .you: "you"
        case .session(let ref?): "session/" + ref.id
        case .session(nil): "session"
        }
    }

    public init?(_ description: String) {
        switch description {
        case "you": self = .you
        case "session": self = .session(nil)
        default:
            guard description.hasPrefix("session/"), let ref = ItemRef.session(String(description.dropFirst("session/".count)))
            else { return nil }
            self = .session(ref)
        }
    }
}

/// A step on the Map: work with no pull request or work item, such as API tests, monitoring or enabling it in production,
/// with what it waits for, as a card does.
public struct MapStep: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var isDone: Bool
    /// The lane it was added in, By Mission, as your order of a lane keys it (`LaneOrderKey`); nil for none, as for one a
    /// session added, which shows where what it's joined to is.
    public var home: LaneOrderKey?
    public var addedBy: MapAuthor
    /// Who changed it last, its name or whether it's done, and when; or who added it, and when.
    public var changedBy: MapAuthor
    public var changedAt: Date

    public init(
        id: UUID, name: String, isDone: Bool = false, home: LaneOrderKey? = nil, addedBy: MapAuthor = .you,
        changedBy: MapAuthor? = nil, changedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.name = name
        self.isDone = isDone
        self.home = home
        self.addedBy = addedBy
        self.changedBy = changedBy ?? addedBy
        self.changedAt = changedAt
    }
}

// MARK: - The changes

/// The changes one side made to the Map, you or the sessions: each line added or taken away, last, and each step's name,
/// whether it's done, and whether it's deleted, each with when. At most `mostLines` lines and `mostSteps` steps it added:
/// past them, those changed longest ago go; what it said of the other side's steps goes only as that side forgets them.
public struct MapEdits: Equatable, Sendable {
    /// Where the app keeps yours.
    public static let yoursKey = "order.map.edits"
    /// Where `--mcp` keeps what sessions tell.
    public static let toldKey = "order.map.told"
    public static let mostLines = 1_000
    public static let mostSteps = 300
    /// A step's name is cut to this many characters.
    public static let mostCharacters = 80
    /// How long a step stays once it's done, as an order whose pull requests all merged does.
    public static let doneStepsStay: TimeInterval = 14 * 86_400

    /// A line from what comes first to what waits for it.
    public struct Line: Hashable, Comparable, Sendable {
        public var before: MapNodeID
        public var after: MapNodeID

        public init(_ before: MapNodeID, _ after: MapNodeID) {
            self.before = before
            self.after = after
        }

        public static func < (lhs: Line, rhs: Line) -> Bool {
            (lhs.before, lhs.after) < (rhs.before, rhs.after)
        }
    }

    /// A line added, or taken away, by whom and when.
    public struct LineChange: Equatable, Sendable {
        public var isOn: Bool
        public var at: Date
        public var by: MapAuthor

        public init(isOn: Bool, at: Date, by: MapAuthor) {
            self.isOn = isOn
            self.at = at
            self.by = by
        }
    }

    /// What one side changed of a step, each with when: its name, whether it's done, that it's deleted, where it was added
    /// and by whom; and who changed it last.
    public struct StepChange: Equatable, Sendable {
        public var name: String?
        public var nameAt: Date?
        public var isDone: Bool?
        public var doneAt: Date?
        public var deletedAt: Date?
        public var home: LaneOrderKey?
        public var addedAt: Date?
        public var addedBy: MapAuthor?
        public var by: MapAuthor

        public init(by: MapAuthor) {
            self.by = by
        }

        /// When it last changed.
        public var latest: Date {
            [nameAt, doneAt, deletedAt, addedAt].compactMap { $0 }.max() ?? .distantPast
        }
    }

    public private(set) var lines: [Line: LineChange]
    public private(set) var steps: [UUID: StepChange]

    public init(lines: [Line: LineChange] = [:], steps: [UUID: StepChange] = [:]) {
        self.lines = lines
        self.steps = steps
    }

    public var isEmpty: Bool {
        lines.isEmpty && steps.isEmpty
    }

    /// What you typed, as a step's name: on one line, without spaces around it, at most `mostCharacters` long; nil for
    /// nothing.
    public static func name(_ typed: String) -> String? {
        let line = typed.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return String(line.prefix(mostCharacters))
    }

    // MARK: Changing

    /// Adds a line, or takes one away: what `after` waits for. Nothing from a node to itself.
    public mutating func set(_ line: Line, on: Bool, by author: MapAuthor, at date: Date) {
        guard line.before != line.after else { return }
        lines[line] = LineChange(isOn: on, at: date, by: author)
        trim()
    }

    /// Adds a step, by the ID it's given, with its name, and where it was added.
    public mutating func addStep(_ id: UUID, name: String, home: LaneOrderKey?, by author: MapAuthor, at date: Date) {
        var change = steps[id] ?? StepChange(by: author)
        change.name = name
        change.nameAt = date
        if change.addedAt == nil {
            change.addedAt = date
            change.addedBy = author
            change.home = home
        }
        change.by = author
        steps[id] = change
        trim()
    }

    public mutating func rename(_ id: UUID, to name: String, by author: MapAuthor, at date: Date) {
        var change = steps[id] ?? StepChange(by: author)
        change.name = name
        change.nameAt = date
        change.by = author
        steps[id] = change
        trim()
    }

    public mutating func setDone(_ id: UUID, _ isDone: Bool, by author: MapAuthor, at date: Date) {
        var change = steps[id] ?? StepChange(by: author)
        change.isDone = isDone
        change.doneAt = date
        change.by = author
        steps[id] = change
        trim()
    }

    /// Deletes a step, for good: the other side's changes to it count no more, and its lines go.
    public mutating func delete(_ id: UUID, by author: MapAuthor, at date: Date) {
        var change = steps[id] ?? StepChange(by: author)
        change.deletedAt = date
        change.by = author
        steps[id] = change
        for line in lines.keys where line.before == .step(id) || line.after == .step(id) {
            lines[line] = nil
        }
    }

    /// Forgets steps altogether, with their lines: as they're done, or deleted, long enough ago (`pruned`).
    mutating func forget(steps ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        steps = steps.filter { !ids.contains($0.key) }
        lines = lines.filter { line, _ in
            !(line.before.stepID.map(ids.contains) ?? false) && !(line.after.stepID.map(ids.contains) ?? false)
        }
    }

    /// Past `mostLines` lines, or `mostSteps` steps this side added, those changed longest ago go. What it said of the other
    /// side's steps, such as that you deleted one a session added, or marked it done, stays until that side forgets the
    /// step (`prune`), lest the step come back: there are no more of those than that side has steps.
    private mutating func trim() {
        if lines.count > Self.mostLines {
            let kept = lines.sorted { ($0.value.at, $0.key) > ($1.value.at, $1.key) }.prefix(Self.mostLines)
            lines = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        let added = steps.filter { $0.value.addedAt != nil }
        if added.count > Self.mostSteps {
            let kept = added.sorted { ($0.value.latest, $0.key.uuidString) > ($1.value.latest, $1.key.uuidString) }.prefix(Self.mostSteps)
            let ids = Set(kept.map(\.key))
            forget(steps: Set(added.keys).subtracting(ids))
        }
    }

    /// Forgets what's about things of these kinds, as their source goes: everything, as Azure DevOps goes, since the Map is
    /// its My Work's, steps and lines alike; and, as Copilot goes, which session said what, as the orders forget which
    /// session told each. Whether anything went.
    @discardableResult
    public mutating func forget(_ kinds: Set<ItemRef.Kind>) -> Bool {
        let before = self
        guard kinds.isDisjoint(with: [.pullRequest, .workItem]) else {
            self = MapEdits()
            return self != before
        }
        func unnamed(_ author: MapAuthor) -> MapAuthor {
            if case .session(let ref?) = author, kinds.contains(ref.kind) { return .session(nil) }
            return author
        }
        lines = lines.mapValues { change in
            var change = change
            change.by = unnamed(change.by)
            return change
        }
        steps = steps.mapValues { change in
            var change = change
            change.by = unnamed(change.by)
            change.addedBy = change.addedBy.map(unnamed)
            return change
        }
        return self != before
    }

    /// Forgets the steps done more than `doneStepsStay` ago, as both sides' changes have them, and those deleted that long
    /// ago, with their lines: a finished feature's steps don't stay for good. Each side forgets its own, as only one writes
    /// each: the app yours, `--mcp` what sessions told. A step shows only while the side that added it keeps it, so that one
    /// side forgetting it before the other never brings it back: the other side keeps what it said of it until then, and
    /// forgets it after, with lines to steps neither side has. Whether anything went.
    public mutating func prune(with other: MapEdits, now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.doneStepsStay)
        // Done long enough ago that the Map no longer shows it, by when it was marked done, as `merged` says, however much
        // changed since, such as its name.
        let shown = Set(Self.merged([self, other], now: now).steps.map(\.id))
        let done = Self.merged([self, other], now: .distantPast).steps.filter { $0.isDone && !shown.contains($0.id) }
        let ended = Set(done.map(\.id)).union(
            [self, other].flatMap { edits in edits.steps.filter { $0.value.deletedAt.map { $0 < cutoff } == true }.map(\.key) }
        )
        var gone: Set<UUID> = []
        for (id, change) in steps {
            let added = change.addedAt != nil
            let addedThere = other.steps[id]?.addedAt != nil
            if (!added && !addedThere) || (ended.contains(id) && (added || !addedThere)) { gone.insert(id) }
        }
        let before = self
        forget(steps: gone)
        let known = Set(steps.keys).union(other.steps.keys)
        lines = lines.filter { line, _ in
            [line.before, line.after].allSatisfy { $0.stepID.map(known.contains) ?? true }
        }
        return self != before
    }

    // MARK: Both sides together

    /// What both sides' changes make of the Map, the latest change winning: each line's last change, and each step's
    /// latest name and whether it's done, but those deleted, with no name, or done more than `doneStepsStay` before
    /// `now`, whose lines go too. Steps in the order they were added.
    public static func merged(_ sides: [MapEdits], now: Date = Date()) -> MapState {
        var lines: [Line: LineChange] = [:]
        for side in sides {
            for (line, change) in side.lines where lines[line].map({ $0.at < change.at }) ?? true {
                lines[line] = change
            }
        }
        struct Folded {
            var name: String?
            var nameAt = Date.distantPast
            var isDone = false
            var doneAt = Date.distantPast
            var isDeleted = false
            var home: LaneOrderKey?
            var addedAt = Date.distantFuture
            var addedBy: MapAuthor = .you
            var changedBy: MapAuthor = .you
            var changedAt = Date.distantPast
        }
        var folded: [UUID: Folded] = [:]
        for side in sides {
            for (id, change) in side.steps {
                var step = folded[id] ?? Folded()
                if let name = change.name, let at = change.nameAt, at >= step.nameAt {
                    step.name = name
                    step.nameAt = at
                }
                if let isDone = change.isDone, let at = change.doneAt, at >= step.doneAt {
                    step.isDone = isDone
                    step.doneAt = at
                }
                if change.deletedAt != nil { step.isDeleted = true }
                if let at = change.addedAt, at < step.addedAt {
                    step.addedAt = at
                    step.addedBy = change.addedBy ?? change.by
                    step.home = change.home
                }
                if change.latest >= step.changedAt {
                    step.changedAt = change.latest
                    step.changedBy = change.by
                }
                folded[id] = step
            }
        }
        let cutoff = now.addingTimeInterval(-doneStepsStay)
        // A step shows only while the side that added it keeps it (`prune`).
        let steps = folded.compactMap { id, step -> MapStep? in
            guard let name = step.name, !step.isDeleted, step.addedAt != .distantFuture, !(step.isDone && step.doneAt < cutoff)
            else { return nil }
            return MapStep(
                id: id, name: name, isDone: step.isDone, home: step.home, addedBy: step.addedBy, changedBy: step.changedBy,
                changedAt: step.changedAt
            )
        }
        .sorted { (folded[$0.id]?.addedAt ?? .distantPast, $0.id.uuidString) < (folded[$1.id]?.addedAt ?? .distantPast, $1.id.uuidString) }
        let kept = Set(steps.map(\.id))
        let isKept = { (node: MapNodeID) in node.stepID.map(kept.contains) ?? true }
        return MapState(lines: lines.filter { isKept($0.key.before) && isKept($0.key.after) }, steps: steps)
    }

    // MARK: Kept

    private struct Stored: Codable {
        var lines: [StoredLine]?
        var steps: [StoredStep]?
    }

    private struct StoredLine: Codable {
        var before: String
        var after: String
        var on: Bool
        var at: Double
        var by: String
    }

    private struct StoredStep: Codable {
        var id: String
        var name: String?
        var nameAt: Double?
        var done: Bool?
        var doneAt: Double?
        var deletedAt: Double?
        var home: String?
        var addedAt: Double?
        var addedBy: String?
        var by: String
    }

    /// What one side's key keeps, without what this build can't read, such as what another program wrote.
    public static func load(from defaults: some SettingsStorage, key: String) -> MapEdits {
        guard let data = defaults.data(forKey: key), let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return MapEdits()
        }
        let date = { (seconds: Double?) in seconds.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil } }
        var edits = MapEdits()
        for line in stored.lines ?? [] {
            guard let before = MapNodeID(line.before), let after = MapNodeID(line.after), before != after,
                  let author = MapAuthor(line.by), let at = date(line.at) else { continue }
            edits.lines[Line(before, after)] = LineChange(isOn: line.on, at: at, by: author)
        }
        for step in stored.steps ?? [] {
            guard let id = UUID(uuidString: step.id), let author = MapAuthor(step.by) else { continue }
            var change = StepChange(by: author)
            change.name = step.name.flatMap(Self.name)
            change.nameAt = change.name == nil ? nil : date(step.nameAt)
            change.isDone = step.done
            change.doneAt = step.done == nil ? nil : date(step.doneAt)
            change.deletedAt = date(step.deletedAt)
            change.home = step.home.flatMap(LaneOrderKey.init)
            change.addedAt = date(step.addedAt)
            change.addedBy = step.addedBy.flatMap(MapAuthor.init)
            edits.steps[id] = change
        }
        edits.trim()
        return edits
    }

    public func save(to defaults: some SettingsStorage, key: String) {
        guard !isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        let seconds = { (date: Date?) in date.map(\.timeIntervalSince1970) }
        let stored = Stored(
            lines: lines.sorted { $0.key < $1.key }.map { line, change in
                StoredLine(
                    before: line.before.description, after: line.after.description, on: change.isOn,
                    at: change.at.timeIntervalSince1970, by: change.by.description
                )
            },
            steps: steps.sorted { $0.key.uuidString < $1.key.uuidString }.map { id, change in
                StoredStep(
                    id: id.uuidString.lowercased(), name: change.name, nameAt: seconds(change.nameAt), done: change.isDone,
                    doneAt: seconds(change.doneAt), deletedAt: seconds(change.deletedAt), home: change.home?.description,
                    addedAt: seconds(change.addedAt), addedBy: change.addedBy?.description, by: change.by.description
                )
            }
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: key)
    }
}

/// What both sides' changes make of the Map (`MapEdits.merged`): each line's last change, and the steps.
public struct MapState: Equatable, Sendable {
    public var lines: [MapEdits.Line: MapEdits.LineChange]
    /// In the order they were added.
    public var steps: [MapStep]

    public init(lines: [MapEdits.Line: MapEdits.LineChange] = [:], steps: [MapStep] = []) {
        self.lines = lines
        self.steps = steps
    }

    public func step(_ id: UUID) -> MapStep? {
        steps.first { $0.id == id }
    }
}

// MARK: - What sessions tell

/// What a session tells of My Work's Map through `tell_dependencies`, as it sent it, before BriefBar reads its names: a pull
/// request by its link, or as `!4102` with the organization; a work item by its link, or by its ID with the organization; a
/// step as `step:` and its name or ID.
public struct MapRequest: Sendable {
    /// One thing and what it waits for, or no longer does.
    public struct Wait: Sendable {
        public var item: String
        public var waitsFor: [String]

        public init(item: String, waitsFor: [String]) {
            self.item = item
            self.waitsFor = waitsFor
        }
    }

    /// A step to add, rename, mark done or not, or delete.
    public struct Step: Sendable {
        /// The step it changes, by its name or ID; nil to add one called `name`, or change the one called so.
        public var step: String?
        public var name: String?
        public var done: Bool?
        public var delete: Bool

        public init(step: String? = nil, name: String? = nil, done: Bool? = nil, delete: Bool = false) {
            self.step = step
            self.name = name
            self.done = done
            self.delete = delete
        }
    }

    public var dependencies: [Wait]
    public var remove: [Wait]
    public var steps: [Step]
    /// The Azure DevOps organization of the numbers it names.
    public var organization: String?

    /// How many lines and steps one call can change.
    public static let mostChanges = 200

    public init(dependencies: [Wait] = [], remove: [Wait] = [], steps: [Step] = [], organization: String? = nil) {
        self.dependencies = dependencies
        self.remove = remove
        self.steps = steps
        self.organization = organization
    }
}

/// Why BriefBar didn't take what a session told of the Map: it changes nothing then.
public enum MapRequestError: Error, Equatable, CustomStringConvertible {
    case nothing
    case tooMany
    case unreadable(String)
    case noOrganization(String)
    case notOnTheMap(String)
    case noSuchStep(String)
    case unnamedStep
    case itself(String)

    public var description: String {
        switch self {
        case .nothing:
            "Give dependencies, remove or steps: what waits for what, what no longer does, or steps to add or change."
        case .tooMany:
            "Tell at most \(MapRequest.mostChanges) dependencies and steps at once."
        case .unreadable(let text):
            """
            BriefBar can't tell what “\(text)” is: name a pull request or a work item by its link, or as !1234 or 5103 with \
            organization, and a step as step: and its name or ID.
            """
        case .noOrganization(let text):
            "Give organization, the Azure DevOps organization of “\(text)”, such as contoso, or name it by its link."
        case .notOnTheMap(let text):
            "My Work's Map has Azure DevOps pull requests, work items and steps only: “\(text)” is none of them."
        case .noSuchStep(let text):
            """
            BriefBar's Map has no step “\(text)” that you can name so: name a step it has by its ID, step: and the ID that \
            work_map gives; step: and a name adds a new step.
            """
        case .unnamedStep:
            "Give a step's name, or the step to change, by its name or ID."
        case .itself(let text):
            "“\(text)” can't wait for itself."
        }
    }
}

extension MapEdits {
    /// Applies what a session told to what sessions told, as `tell_dependencies` does, against what both sides have now:
    /// its steps first, then the lines it adds, then those it takes away. A step it names that the Map doesn't have is added.
    /// Throws, changing nothing, for anything it can't read.
    /// - Returns: what changed, a line each, and where it went against what the user said, which it shows over now.
    public mutating func apply(_ request: MapRequest, yours: MapEdits, by author: MapAuthor, now: Date) throws -> [String] {
        let count = request.steps.count + (request.dependencies + request.remove).reduce(0) { $0 + max($1.waitsFor.count, 1) }
        guard count > 0 else { throw MapRequestError.nothing }
        guard count <= MapRequest.mostChanges else { throw MapRequestError.tooMany }
        var edits = self
        var steps = Self.merged([yours, self], now: now).steps
        var lines: [String] = []
        /// The steps this call added, which the rest of it can name by name.
        var added: [UUID] = []

        func isCalled(_ step: MapStep, _ name: String) -> Bool {
            step.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        /// A step by its ID, whatever follows it, such as its name; or by the name of one this call added; or, where it may
        /// add one, a new step of that name. Never another step by its name: two missions' steps can share one, such as API
        /// tests, and a name that found the other's would join their graphs.
        func step(_ text: String, adding: Bool) throws -> UUID {
            var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // As work_map and the prompt name it, step: and its ID, or as a bare ID.
            if text.lowercased().hasPrefix("step:") { text = String(text.dropFirst("step:".count)).trimmingCharacters(in: .whitespaces) }
            if let id = UUID(uuidString: String(text.prefix(36))) {
                guard steps.contains(where: { $0.id == id }) else { throw MapRequestError.noSuchStep(text) }
                return id
            }
            guard let name = Self.name(text) else { throw MapRequestError.unnamedStep }
            if let id = added.first(where: { id in steps.first { $0.id == id }.map { isCalled($0, name) } ?? false }) {
                return id
            }
            guard adding else { throw MapRequestError.noSuchStep(text) }
            let id = UUID()
            // Each a moment after the one before, so that they keep the order they were told in.
            let at = now.addingTimeInterval(Double(steps.count) / 1_000)
            let others = steps.filter { isCalled($0, name) }
            edits.addStep(id, name: name, home: nil, by: author, at: at)
            steps.append(MapStep(id: id, name: name, addedBy: author, changedAt: at))
            added.append(id)
            var said = "Added step “\(name)” (step:\(id.uuidString.lowercased()))."
            if !others.isEmpty {
                let ids = Self.list(others.map { "step:" + $0.id.uuidString.lowercased() })
                said += " The Map has another step called so, \(ids), which this isn't: name that one by its ID where you mean it."
            }
            lines.append(said)
            return id
        }
        func node(_ text: String) throws -> MapNodeID {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("step:") {
                return .step(try step(String(trimmed.dropFirst("step:".count)), adding: true))
            }
            if let ref = ItemRef.from(link: trimmed) {
                guard ref.kind == .pullRequest || ref.kind == .workItem else { throw MapRequestError.notOnTheMap(trimmed) }
                return .card(ref)
            }
            let isPullRequest = trimmed.hasPrefix("!")
            let digits = isPullRequest || trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
            guard let number = ItemRef.number(digits) else { throw MapRequestError.unreadable(trimmed) }
            guard let organization = request.organization?.trimmingCharacters(in: .whitespaces).lowercased(),
                  ItemRef.isOrganization(organization)
            else { throw MapRequestError.noOrganization(trimmed) }
            return .card(isPullRequest ? .pullRequest(organization: organization, number: number) : .workItem(organization: organization, id: number))
        }
        func name(_ node: MapNodeID) -> String {
            Self.label(node, steps: steps)
        }

        for change in request.steps {
            guard let named = change.step ?? change.name else { throw MapRequestError.unnamedStep }
            let id = try step(named, adding: change.step == nil && !change.delete)
            let was = name(.step(id))
            if change.delete {
                edits.delete(id, by: author, at: now)
                steps.removeAll { $0.id == id }
                lines.append("Deleted step \(was).")
                continue
            }
            if change.step != nil, let renamed = change.name.flatMap(Self.name), renamed != steps.first(where: { $0.id == id })?.name {
                edits.rename(id, to: renamed, by: author, at: now)
                if let index = steps.firstIndex(where: { $0.id == id }) { steps[index].name = renamed }
                lines.append("Renamed step \(was) to “\(renamed)”.")
            }
            if let done = change.done {
                edits.setDone(id, done, by: author, at: now)
                lines.append("Marked step \(name(.step(id))) \(done ? "done" : "not done").")
            }
        }
        for (waits, on) in request.dependencies.map({ ($0, true) }) + request.remove.map({ ($0, false) }) {
            let later = try node(waits.item)
            var earlier: [MapNodeID] = []
            for text in waits.waitsFor {
                let before = try node(text)
                guard before != later else { throw MapRequestError.itself(text.trimmingCharacters(in: .whitespaces)) }
                earlier.append(before)
                let line = Line(before, later)
                edits.set(line, on: on, by: author, at: now)
                if let theirs = yours.lines[line], theirs.isOn != on {
                    lines.append(
                        "The user had \(on ? "taken away" : "drawn") the line from \(name(before)) to \(name(later)); yours shows "
                            + "over theirs now, until they change it again."
                    )
                }
            }
            guard !earlier.isEmpty else { continue }
            let list = Self.list(earlier.map(name))
            lines.append(on ? "\(name(later)) waits for \(list)." : "\(name(later)) no longer waits for \(list).")
        }
        self = edits
        return lines
    }

    /// What a node is called in what agents read: "!4105 in contoso", "work item 5104 in contoso", "“API tests”
    /// (step:<id>)".
    static func label(_ node: MapNodeID, steps: [MapStep]) -> String {
        switch node {
        case .card(let ref):
            switch ref.kind {
            case .pullRequest: "!\(ref.id) in \(ref.scope)"
            case .workItem: "work item \(ref.id) in \(ref.scope)"
            case .gitHubPullRequest: "\(ref.scope)#\(ref.id)"
            case .session: "session \(ref.id)"
            }
        case .step(let id):
            "“\(steps.first { $0.id == id }?.name ?? "a deleted step")” (step:\(id.uuidString.lowercased()))"
        }
    }

    static func list(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// What `work_map` answers: the Map's steps and the lines the user and sessions added or took away, with who and when.
    /// - Parameter session: the session that asks, which reads its own as yours.
    public static func describe(yours: MapEdits, told: MapEdits, now: Date, session: ItemRef?) -> String {
        let state = merged([yours, told], now: now)
        guard !state.steps.isEmpty || !state.lines.isEmpty else {
            return """
                Neither the user nor any session has added a step or a dependency to BriefBar's Map yet: the pull \
                requests' merge orders draw its lines (pull_request_order). Tell what waits for what with tell_dependencies.
                """
        }
        func who(_ author: MapAuthor) -> String {
            switch author {
            case .you: "the user"
            case .session(let ref?): ref == session ? "your session" : "session \(ref.id)"
            case .session(nil): "an agent"
            }
        }
        func day(_ date: Date) -> String {
            date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        }
        var parts: [String] = []
        if !state.steps.isEmpty {
            parts.append("## Steps\n\n" + state.steps.map { step in
                let changed = step.changedBy == step.addedBy ? "" : " Last changed by \(who(step.changedBy)) on \(day(step.changedAt))."
                return "- \(label(.step(step.id), steps: state.steps)): \(step.isDone ? "done" : "to do"). Added by \(who(step.addedBy)).\(changed)"
            }.joined(separator: "\n"))
        }
        if !state.lines.isEmpty {
            let sorted = state.lines.sorted { ($0.key.after, $0.key.before) < ($1.key.after, $1.key.before) }
            parts.append(
                """
                ## What waits for what

                These come on top of the pull requests' merge orders (pull_request_order); where one takes a line away, the \
                Map doesn't draw it, whatever the orders say.

                """ + sorted.map { line, change in
                    let (later, earlier) = (label(line.after, steps: state.steps), label(line.before, steps: state.steps))
                    let what = change.isOn ? "\(later) waits for \(earlier)" : "\(later) doesn't wait for \(earlier)"
                    return "- \(what): \(change.isOn ? "said" : "taken away") by \(who(change.by)) on \(day(change.at))."
                }.joined(separator: "\n")
            )
        }
        return parts.joined(separator: "\n\n")
    }
}
