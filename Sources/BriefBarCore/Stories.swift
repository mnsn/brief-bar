import Foundation

/// What BriefBar can tell about one thing beyond its row, in its own words, from what its source read: where it stands,
/// a few facts, the pipelines that ran on it, and what's been done, as the thing itself recorded it, such as a Copilot
/// session's checkpoints. No model writes any of it. A source tells it when a view asks, and it's kept in memory only.
public struct ItemStory: Sendable, Equatable {
    /// Where it stands, in a sentence in BriefBar's words, without its title, which its row shows: "Waiting for reviewers:
    /// Priya approved.", "Asks: Use a new table?". Empty when a source knows only what's been done, such as Copilot of a
    /// task Azure DevOps sent it, which says where that stands.
    public var sentence: String
    /// The sentence to share outside this Mac, such as with Copilot for a summary, when `sentence` says what only this Mac
    /// knows, such as who sent it to you in a chat: where it stands from what the thing says itself. Nil when `sentence`
    /// can be shared.
    public var sharedSentence: String?
    /// When what it says last changed.
    public var date: Date?
    /// A few facts, in the order they show: who reviews it, how its comments and its merge stand.
    public var facts: [Fact]
    /// Facts that say less, shown only when you ask for all of it: who wrote it, its branch, a session's project and mode.
    public var more: [Fact]
    /// The pipelines that ran on it, the one that needs you most first.
    public var runs: [Run]
    /// What's been done so far, as the thing recorded it: a Copilot session's checkpoints and last words.
    public var account: Account?
    /// Its longer texts, such as a work item's description and latest comments: for a summary of it, not for its row.
    public var notes: [Fact]
    /// What it doesn't say, and why: "BriefBar reads builds and comments only on your pull requests."
    public var footnote: String?
    /// Who it waits on, and for what: "you, to complete !4091", "Copilot, on 5103".
    public var waits: [Wait]

    public init(
        sentence: String, sharedSentence: String? = nil, date: Date? = nil, facts: [Fact] = [], more: [Fact] = [], runs: [Run] = [],
        account: Account? = nil, notes: [Fact] = [], footnote: String? = nil, waits: [Wait] = []
    ) {
        self.sentence = sentence
        self.sharedSentence = sharedSentence
        self.date = date
        self.facts = facts
        self.more = more
        self.runs = runs
        self.account = account
        self.notes = notes
        self.footnote = footnote
        self.waits = waits
    }

    /// Who something waits on, and for what.
    public struct Wait: Sendable, Equatable, Hashable {
        /// You first, then other people, then Copilot.
        public enum Who: Int, Sendable, Comparable {
            case you, people, copilot

            public static func < (lhs: Who, rhs: Who) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        public var who: Who
        /// Who, then what for: "you, to complete !4091", "reviewers of Sam Rivera's !4120", "Copilot, on 5103".
        public var text: String
        /// What waits, when two sources can tell of it in their own words, as a Copilot session: the work sent to Copilot
        /// in it, and the session itself. It's said once.
        public var about: ItemRef?

        public init(_ who: Who, _ text: String, about: ItemRef? = nil) {
            self.who = who
            self.text = text
            self.about = about
        }

        public static func you(_ text: String) -> Wait { Wait(.you, text) }
        public static func people(_ text: String) -> Wait { Wait(.people, text) }
        public static func copilot(_ text: String) -> Wait { Wait(.copilot, text) }

        /// Several things' waits, you first, then other people, then Copilot, each once, in the order they came: a thing
        /// that waits, by the first words for it.
        public static func ordered(_ waits: [Wait]) -> [Wait] {
            var said: Set<String> = []
            var told: Set<ItemRef> = []
            return waits.enumerated()
                .sorted { ($0.element.who, $0.offset) < ($1.element.who, $1.offset) }
                .map(\.element)
                .filter { wait in
                    if let about = wait.about, !told.insert(about).inserted { return false }
                    return said.insert(wait.text).inserted
                }
        }
    }

    /// A fact in a word or a few: "Reviewers": "Priya approved · Sam hasn't voted".
    public struct Fact: Sendable, Equatable, Hashable {
        public var label: String
        public var value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    /// A pipeline's run on it: a build that validates a pull request, or one that ran after it merged.
    public struct Run: Sendable, Equatable {
        /// The pipeline's name: "shop-web CI".
        public var name: String
        /// What it means for you: failing, running or done; nil for one that waits, didn't run or has to run again.
        public var state: ItemState?
        /// Where it stands, in a word or a few: "Passed", "Failed at Run tests", "Expired".
        public var status: String
        /// The first error, for one that failed.
        public var detail: String?
        /// Its page.
        public var url: URL?
        /// When it finished, or started.
        public var date: Date?

        public init(name: String, state: ItemState?, status: String, detail: String? = nil, url: URL? = nil, date: Date? = nil) {
            self.name = name
            self.state = state
            self.status = status
            self.detail = detail
            self.url = url
            self.date = date
        }
    }

    /// What's been done so far, as the thing recorded it, in plain text: a Copilot session's checkpoints, which Copilot
    /// writes as its work goes on, and what it said last.
    public struct Account: Sendable, Equatable {
        /// Where it comes from, for its caption: "Copilot's checkpoints", "Copilot's report".
        public var source: String
        /// When it was written.
        public var date: Date?
        /// The checkpoints' titles, oldest first: the story so far, a line each. The latest ones only, when there are many.
        public var milestones: [String]
        /// How many checkpoints there are, `milestones` or more.
        public var milestoneCount: Int
        /// The latest checkpoint's overview, or the summary it finished with.
        public var overview: String?
        /// What's been done, a line each.
        public var done: [String]
        /// What's next, a line each.
        public var next: [String]
        /// What it said last, when that came after the rest.
        public var lastMessage: String?

        public init(
            source: String, date: Date? = nil, milestones: [String] = [], milestoneCount: Int? = nil, overview: String? = nil,
            done: [String] = [], next: [String] = [], lastMessage: String? = nil
        ) {
            self.source = source
            self.date = date
            self.milestones = milestones
            self.milestoneCount = max(milestoneCount ?? milestones.count, milestones.count)
            self.overview = overview
            self.done = done
            self.next = next
            self.lastMessage = lastMessage
        }

        /// Whether it says nothing.
        public var isEmpty: Bool {
            milestones.isEmpty && (overview ?? "").isEmpty && done.isEmpty && next.isEmpty && (lastMessage ?? "").isEmpty
        }
    }

    /// Where it stands, in a sentence to share outside this Mac: `sharedSentence`, or else `sentence`.
    public var sentenceToShare: String {
        sharedSentence ?? sentence
    }

    /// The two told together, as two sources tell about the same thing, such as a task Azure DevOps sent to Copilot and
    /// what Copilot recorded of it: the first sentence that says something, with what of it may be shared, and the first
    /// footnote, both's facts, runs and notes, without a fact or a note told twice, the first account that says something,
    /// unless only the other has checkpoints, and the newer date.
    public func merged(with other: ItemStory) -> ItemStory {
        var merged = self
        if merged.sentence.isEmpty, !other.sentence.isEmpty {
            merged.sentence = other.sentence
            merged.sharedSentence = other.sharedSentence
        }
        if merged.footnote == nil { merged.footnote = other.footnote }
        let told = { (label: String) in merged.facts.contains { $0.label == label } || merged.more.contains { $0.label == label } }
        for fact in other.facts where !told(fact.label) {
            merged.facts.append(fact)
        }
        for fact in other.more where !told(fact.label) {
            merged.more.append(fact)
        }
        let runs = other.runs.filter { run in !merged.runs.contains(run) }
        merged.runs += runs
        if let account = other.account, !account.isEmpty {
            switch merged.account.flatMap({ $0.isEmpty ? nil : $0 }) {
            case nil:
                merged.account = account
            case let mine? where mine.milestones.isEmpty && !account.milestones.isEmpty:
                merged.account = account.ending(with: mine)
            case let mine? where !mine.milestones.isEmpty && account.milestones.isEmpty:
                merged.account = mine.ending(with: account)
            default:
                break
            }
        }
        merged.notes += other.notes.filter { note in !self.notes.contains { $0.label == note.label } }
        merged.waits = Wait.ordered(merged.waits + other.waits)
        if let date = other.date { merged.date = max(merged.date ?? date, date) }
        return merged
    }

    /// Whether it says nothing more than its row.
    public var isEmpty: Bool {
        sentence.isEmpty && facts.isEmpty && more.isEmpty && runs.isEmpty && (account?.isEmpty ?? true) && notes.isEmpty
            && footnote == nil
    }
}

extension ItemStory.Account {
    /// Its checkpoints, with a report written after them, such as what Copilot printed when a task ended, as what it said
    /// last, unless it says something later already.
    func ending(with report: ItemStory.Account) -> ItemStory.Account {
        guard lastMessage == nil, let words = report.overview ?? report.lastMessage, !words.isEmpty else { return self }
        if let written = report.date, let checkpoint = date, written < checkpoint { return self }
        var account = self
        account.lastMessage = words
        return account
    }
}

extension ItemStory.Run {
    /// What needs you most first: failed, then running, then the rest, then passed; the newest first.
    public static func showsFirst(_ lhs: ItemStory.Run, _ rhs: ItemStory.Run) -> Bool {
        func rank(_ run: ItemStory.Run) -> Int {
            switch run.state {
            case .failing?: return 0
            case .needsYou?: return 1
            case .running?: return 2
            case nil: return 3
            case .done?: return 4
            }
        }
        if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
        if lhs.date != rhs.date { return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast) }
        return lhs.name < rhs.name
    }
}

extension ItemState {
    /// Where it shows among others: what needs you first, then what's wrong, what's at work, and what's done or ready.
    /// Things without a state, such as a pull request waiting on others, come after all of them.
    public static func rank(_ state: ItemState?) -> Int {
        state.flatMap { allCases.firstIndex(of: $0) } ?? allCases.count
    }
}

/// Text cut to fit a story: one line, or a paragraph, at most so long.
public enum StoryText {
    /// One line of at most `limit` characters, with an ellipsis when it's cut.
    public static func line(_ text: String, limit: Int = 160) -> String {
        clip(text.split(whereSeparator: \.isNewline).joined(separator: " "), limit: limit)
    }

    /// Paragraphs, their lines kept, of at most `limit` characters all told.
    public static func paragraph(_ text: String, limit: Int = 700) -> String {
        let paragraphs = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .reduce(into: [String]()) { kept, line in
                // One blank line between paragraphs at most.
                if line.isEmpty, kept.last?.isEmpty ?? true { return }
                kept.append(line)
            }
        return clip(paragraphs.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), limit: limit)
    }

    private static func clip(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return trimmed }
        let cut = trimmed.prefix(max(limit - 1, 0))
        // At a word's end, when there's one near.
        let atWord = cut.lastIndex(where: \.isWhitespace).map { cut[..<$0] }.flatMap { $0.count > limit * 3 / 4 ? $0 : nil } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }
}
