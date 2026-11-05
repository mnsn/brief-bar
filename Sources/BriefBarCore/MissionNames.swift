import Foundation

// What names a mission, first to last: the name you give it with Rename…, which BriefBar keeps; the one Apple
// Intelligence gives it on this Mac, from the titles of what it's made of, which BriefBar keeps in memory only; and the one
// it has without either (`OrderText.title`). Here are the names you give, and the question Apple Intelligence is asked.

// MARK: - Your names

/// The names you give missions with Rename…, in the preferences by the mission's key, which only the app writes: only what
/// you typed, never a name a source or Apple Intelligence gave, so no title BriefBar read gets there. A name goes once
/// BriefBar hasn't seen its mission for `forgottenAfter`, counting only while it could have: with Pull Request Order on,
/// and what makes that mission on too, such as Show Links for a story's. Forget All Orders… forgets them all, and turning a
/// source off those of its missions, as Focus. They're never logged, never in agents' answers, and never in what Apple
/// Intelligence is asked.
public struct MissionNames: Equatable, Sendable {
    public static let defaultsKey = "order.names"
    /// At most this many: at the cap, Rename… keeps none rather than drop one.
    public static let mostNames = 200
    /// A name is cut to this many characters.
    public static let mostCharacters = 80
    /// How long BriefBar keeps a name whose mission it could have seen, but didn't.
    public static let forgottenAfter: TimeInterval = 14 * 86_400

    public struct Entry: Equatable, Sendable {
        public var name: String
        /// How long BriefBar could have seen its mission without seeing it, since it last did.
        public var unseen: TimeInterval

        public init(name: String, unseen: TimeInterval = 0) {
            self.name = name
            self.unseen = unseen
        }
    }

    public private(set) var entries: [MissionKey: Entry]

    public init(entries: [MissionKey: Entry] = [:]) {
        self.entries = entries
    }

    /// The name you gave a mission, if you did.
    public func name(for key: MissionKey) -> String? {
        entries[key]?.name
    }

    public var isFull: Bool { entries.count >= Self.mostNames }

    /// What Rename… did.
    public enum Outcome: Equatable, Sendable {
        /// It keeps the name you typed.
        case named
        /// The mission has BriefBar's name again: you typed nothing, or BriefBar's own name.
        case cleared
        /// Nothing changed: you typed the name it had.
        case unchanged
        /// It keeps `mostNames` names already, so it kept none.
        case full
    }

    /// What you typed, as a name: on one line, without spaces around it, at most `mostCharacters` long.
    public static func cleaned(_ typed: String) -> String {
        let line = typed.components(separatedBy: .newlines).joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(line.prefix(mostCharacters)).trimmingCharacters(in: .whitespaces)
    }

    /// Rename…: what you typed becomes the mission's name, unless it's nothing, or the name BriefBar gives it now, which
    /// give it BriefBar's name again and keep nothing, or the name it has, which changes nothing. At the cap, it keeps none.
    /// - Parameter briefBarsName: the name the mission has without yours, as it shows now.
    public mutating func rename(_ key: MissionKey, to typed: String, briefBarsName: String) -> Outcome {
        let name = Self.cleaned(typed)
        if name.isEmpty || name == Self.cleaned(briefBarsName) {
            return entries.removeValue(forKey: key) == nil ? .unchanged : .cleared
        }
        if entries[key]?.name == name { return .unchanged }
        if entries[key] == nil, isFull { return .full }
        entries[key] = Entry(name: name)
        return .named
    }

    /// Use BriefBar's Name: forgets the name you gave it. Whether it had one.
    @discardableResult
    public mutating func clear(_ key: MissionKey) -> Bool {
        entries.removeValue(forKey: key) != nil
    }

    /// Counts `elapsed` against the names whose missions BriefBar could have seen, but didn't, and forgets those it hasn't
    /// seen for `forgottenAfter`. A name whose mission shows starts again from nothing; one whose mission BriefBar can't see
    /// now, as what makes it is off, waits as it is.
    /// - Parameters:
    ///   - shown: the missions shown now.
    ///   - canSee: whether BriefBar could see a mission now, if it were there.
    /// - Returns: whether it changed enough to keep: a name forgotten, a mission seen again, or another hour unseen.
    @discardableResult
    public mutating func account(shown: Set<MissionKey>, canSee: (MissionKey) -> Bool, elapsed: TimeInterval) -> Bool {
        var changed = false
        for (key, entry) in entries {
            if shown.contains(key) {
                if entry.unseen > 0 {
                    entries[key]?.unseen = 0
                    changed = true
                }
                continue
            }
            guard canSee(key), elapsed > 0 else { continue }
            let unseen = entry.unseen + elapsed
            if unseen >= Self.forgottenAfter {
                entries[key] = nil
                changed = true
            } else {
                entries[key]?.unseen = unseen
                if Int(unseen / 3_600) != Int(entry.unseen / 3_600) { changed = true }
            }
        }
        return changed
    }

    /// A mission's key changed, as a chain's does when its earliest pull request leaves, or its pull requests went to their
    /// story's mission: its name goes with it, unless the other has one of yours already.
    @discardableResult
    public mutating func follow(_ old: MissionKey, to new: MissionKey) -> Bool {
        guard old != new, entries[new] == nil, let entry = entries.removeValue(forKey: old) else { return false }
        entries[new] = Entry(name: entry.name)
        return true
    }

    /// Forgets the names of the missions of things whose source you turned off, and of the orders BriefBar no longer
    /// keeps, as Focus. Whether it forgot any.
    @discardableResult
    public mutating func forget(_ kinds: Set<ItemRef.Kind>, keepingPlans plans: Set<UUID>? = nil) -> Bool {
        let before = entries.count
        entries = entries.filter { key, _ in
            if case .plan(let id) = key { return plans?.contains(id) ?? true }
            return key.kinds.isDisjoint(with: kinds)
        }
        return entries.count != before
    }

    // MARK: Saving

    private struct Record: Codable {
        var key: String
        var name: String
        /// Whole seconds.
        var unseen: Int?
    }

    /// The names that were saved, without what can't be read, such as what another program wrote.
    public static func load(from defaults: some SettingsStorage) -> MissionNames {
        guard let data = defaults.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([NameLossy<Record>].self, from: data)
        else { return MissionNames() }
        var entries: [MissionKey: Entry] = [:]
        for record in records.compactMap(\.value) {
            guard entries.count < mostNames, let key = MissionKey(record.key), entries[key] == nil else { continue }
            let name = cleaned(record.name)
            guard !name.isEmpty else { continue }
            entries[key] = Entry(name: name, unseen: TimeInterval(max(record.unseen ?? 0, 0)))
        }
        return MissionNames(entries: entries)
    }

    public func save(to defaults: some SettingsStorage) {
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        let records = entries.map { Record(key: $0.key.description, name: $0.value.name, unseen: Int($0.value.unseen)) }
            .sorted { $0.key < $1.key }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(records) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Whether BriefBar could see a mission now, if it were there, for the time that counts against its name: a session's
    /// order while BriefBar keeps it; any other while what makes it is on: Azure DevOps or GitHub for a chain, GitHub for
    /// its stack, Copilot for a session's pull requests, and Azure DevOps with Show Links for a story's.
    /// - Parameters:
    ///   - kindsOn: the kinds of thing whose source is on.
    ///   - readsStories: a source reads the stories its pull requests are for.
    public static func canSee(_ key: MissionKey, plans: Set<UUID>, kindsOn: Set<ItemRef.Kind>, readsStories: Bool) -> Bool {
        switch key {
        case .plan(let id): return plans.contains(id)
        case .story: return readsStories && kindsOn.contains(.pullRequest)
        case .stack, .chain, .family: return key.kinds.isSubset(of: kindsOn)
        }
    }
}

/// A record that may not decode, such as one another program wrote: nil then, rather than failing them all.
private struct NameLossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - Apple Intelligence's names

/// What Apple Intelligence names a mission from: titles from Azure DevOps and from Copilot's sessions only, never GitHub's
/// (decision 11), and never a name you gave a mission. The same inputs ask the same question, so, with the likeliest words,
/// they get the same name, today and after a restart.
public struct MissionNameInputs: Hashable, Sendable {
    /// The name BriefBar gives it without Apple Intelligence, to keep unless it no longer fits: never yours, nor a title
    /// from GitHub.
    public var current: String?
    /// Its story's title.
    public var story: String?
    /// Its pull requests' work items' titles, such as their tasks'.
    public var workItems: [String]
    /// Its Azure DevOps pull requests' titles.
    public var pullRequests: [String]
    /// The titles of the Copilot sessions that told its order, opened its pull requests or work on them.
    public var sessions: [String]

    public init(current: String? = nil, story: String? = nil, workItems: [String] = [], pullRequests: [String] = [], sessions: [String] = []) {
        self.current = current
        self.story = story
        self.workItems = workItems
        self.pullRequests = pullRequests
        self.sessions = sessions
    }
}

/// Asking Apple Intelligence for a mission's name: which missions it names, from what, the question, and the answer made
/// one short line. `MissionNamer` asks, on this Mac.
public enum MissionNaming {
    /// At most this many titles of each kind go in the question, each at most `mostCharacters` long.
    public static let mostTitles = 12
    public static let mostSessions = 6
    public static let mostCharacters = 120
    /// What an answer is cut to.
    public static let mostWords = 8
    public static let mostAnswerCharacters = 60

    public static let instructions = """
        You name a mission: a group of related pull requests in a developer's app. Answer with the name only: two to six \
        words, in sentence case, that say what the work is now, from the titles you're given. Keep the current name when it \
        still fits the work. No quotes, no punctuation at the end, no numbers, and no people's names.
        """

    /// What it's asked to name a mission from, or nil for one it doesn't name: one with no Azure DevOps pull request.
    /// - Parameters:
    ///   - stories: the stories each of its pull requests is for, as the sources read them.
    ///   - name: what a source calls a session, a work item or a pull request, when it says.
    public static func inputs(
        for mission: OrderMission, stories: (ItemRef) -> [OrderStory], name: (ItemRef) -> String?
    ) -> MissionNameInputs? {
        let pullRequests = mission.steps.map(\.ref).filter { $0.kind == .pullRequest }
        guard !pullRequests.isEmpty else { return nil }
        var workItems: [ItemRef] = []
        for ref in pullRequests {
            for story in stories(ref) {
                let item = story.task ?? story.ref
                if item != mission.story?.ref, !workItems.contains(item) { workItems.append(item) }
            }
        }
        let withoutGitHub = { (ref: ItemRef) in ref.kind == .gitHubPullRequest ? nil : name(ref) }
        let current = OrderText.title(of: mission, name: withoutGitHub)
        let titles = Set([mission.story?.ref].compactMap { $0 } + pullRequests + mission.sessions).compactMap(name)
        return MissionNameInputs(
            current: titles.contains(current) ? current : nil, story: mission.story.flatMap { name($0.ref) },
            workItems: workItems.compactMap(name), pullRequests: pullRequests.compactMap(name),
            sessions: mission.sessions.compactMap(name)
        )
    }

    /// The question: its current name, then what it's made of, each title on a line of its own.
    public static func prompt(_ inputs: MissionNameInputs) -> String {
        func line(_ title: String) -> String {
            let flat = title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return String(flat.prefix(mostCharacters))
        }
        func list(_ heading: String, _ titles: [String], most: Int) -> String? {
            var seen: Set<String> = []
            let lines = titles.map(line).filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(most)
            return lines.isEmpty ? nil : ([heading] + lines.map { "- \($0)" }).joined(separator: "\n")
        }
        let parts: [String?] = [
            inputs.current.map { "Current name: \(line($0))" },
            inputs.story.map { "Story: \(line($0))" },
            list("Work items:", inputs.workItems, most: mostTitles),
            list("Pull requests:", inputs.pullRequests, most: mostTitles),
            list("Copilot sessions:", inputs.sessions, most: mostSessions),
        ]
        return parts.compactMap { $0 }.joined(separator: "\n") + "\n\nThe mission's name:"
    }

    /// The answer as a name: its first line, without quotes, labels, markdown or the full stop, of a few words; nil when
    /// that leaves nothing a name could be.
    public static func clean(_ answer: String) -> String? {
        var line = answer.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        for label in ["Name:", "Mission name:", "The mission's name:", "Mission:", "Title:"]
        where line.lowercased().hasPrefix(label.lowercased()) {
            line = String(line.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        line = line.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("- ") { line = String(line.dropFirst(2)) }
        while let first = line.first, "\"“'‘".contains(first) { line.removeFirst() }
        while let last = line.last, "\"”'’.!:;,".contains(last) { line.removeLast() }
        line = line.trimmingCharacters(in: .whitespaces)
        let words = line.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty, line.count >= 3 else { return nil }
        var name = words.prefix(mostWords).joined(separator: " ")
        if name.count > mostAnswerCharacters {
            name = String(name.prefix(mostAnswerCharacters)).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// Whether what a mission is named from is all read: Show Links, while a source reads stories, has read the work items
    /// of each of its Azure DevOps pull requests.
    public static func isSettled(_ mission: OrderMission, facts: OrderFacts) -> Bool {
        guard facts.readsStories else { return true }
        return mission.steps.allSatisfy { step in
            step.ref.kind != .pullRequest || facts.pullRequests[step.ref].map { $0.stories != nil } ?? true
        }
    }
}
