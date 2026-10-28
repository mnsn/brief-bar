import Foundation

/// What BriefBar notified you of lately, from every source, the newest first: the Notifications page in its window,
/// so you can see what you missed, even what macOS didn't show. It's kept in memory only, for as long as you choose.
/// Each entry keeps what its source needs to open what it's about, as its notification does.
public struct NotificationHistory: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        /// The notification's own. Posting the same one again replaces it.
        public var id: String
        public var source: SourceID
        /// What it means for you, such as a build that failed, for its symbol. Nil for news in no state.
        public var state: ItemState?
        public var title: String
        public var subtitle: String?
        public var body: String
        /// When BriefBar posted it.
        public var date: Date
        /// What its source needs to open what it's about.
        public var userInfo: [String: String]
        /// You've seen it: on the page, or by clicking it, there or in Notification Center.
        public var isSeen: Bool

        public init(
            id: String, source: SourceID, state: ItemState? = nil, title: String, subtitle: String? = nil, body: String,
            date: Date, userInfo: [String: String] = [:], isSeen: Bool = false
        ) {
            self.id = id
            self.source = source
            self.state = state
            self.title = title
            self.subtitle = subtitle
            self.body = body
            self.date = date
            self.userInfo = userInfo
            self.isSeen = isSeen
        }
    }

    /// The newest first.
    public private(set) var entries: [Entry] = []

    /// At most this many, a very busy day's worth: the oldest go first.
    public static let limit = 200
    /// How long entries stay, in hours, unless you choose otherwise: a day.
    public static let defaultKeepHours = 24
    /// What you can choose, in hours.
    public static let keepHoursChoices = [4, 24, 72]

    public init(entries: [Entry] = []) {
        for entry in entries { add(entry) }
    }

    /// One of the choices: what's saved, or a day for anything else.
    public static func keepHours(_ saved: Int) -> Int {
        keepHoursChoices.contains(saved) ? saved : defaultKeepHours
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// How many you haven't seen yet.
    public var unseenCount: Int {
        entries.filter { !$0.isSeen }.count
    }

    /// Adds a notification where its date puts it, after those from the same time, in place of one with the same ID,
    /// which it's news again: notifications posted together, the newest first, stay in that order.
    public mutating func add(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        let index = entries.firstIndex { $0.date < entry.date } ?? entries.endIndex
        entries.insert(entry, at: index)
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
    }

    /// Drops what was posted `keepHours` ago or longer. True when it dropped any.
    @discardableResult
    public mutating func prune(now: Date, keepHours: Int) -> Bool {
        let cutoff = now.addingTimeInterval(-Double(keepHours) * 3600)
        let count = entries.count
        entries.removeAll { $0.date <= cutoff }
        return entries.count != count
    }

    public mutating func markSeen(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isSeen = true
    }

    /// Everything posted up to `date` is seen: what the page showed, until you left it.
    public mutating func markSeen(through date: Date) {
        for index in entries.indices where entries[index].date <= date {
            entries[index].isSeen = true
        }
    }

    public mutating func remove(_ id: String) {
        entries.removeAll { $0.id == id }
    }

    /// What a source posted, when it's turned off.
    public mutating func removeAll(from source: SourceID) {
        entries.removeAll { $0.source == source }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
