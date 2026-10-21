import BriefBarCore
import Foundation
import NotificationCenterDB

/// A chat as a menu-bar list shows it.
public struct ConversationSummary: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: ConversationKind
    public var group: ChatGroup
    public var name: String
    /// Unread messages, oldest first.
    public var unread: [ChatMessage]
    /// The newest messages BriefBar holds for this chat, oldest first.
    public var latestMessages: [ChatMessage]
    public var lastActivity: Date
    /// Where clicking it goes: the oldest unread message, else the newest message.
    public var link: URL?

    public var unreadCount: Int { unread.count }
    public var isUnread: Bool { !unread.isEmpty }
    public var latest: ChatMessage? { latestMessages.last }
}

public struct UnreadState: Sendable, Equatable {
    public var unread: [ChatGroup: [ConversationSummary]]
    public var recent: [ChatGroup: [ConversationSummary]]

    public init(unread: [ChatGroup: [ConversationSummary]] = [:], recent: [ChatGroup: [ConversationSummary]] = [:]) {
        self.unread = unread
        self.recent = recent
    }

    /// Chats with unread messages, the most recent message first.
    public func unread(in group: ChatGroup) -> [ConversationSummary] { unread[group] ?? [] }
    /// Read chats with activity in the recent window, newest first.
    public func recent(in group: ChatGroup) -> [ConversationSummary] { recent[group] ?? [] }
    /// The menu-bar count: chats with unread messages, as Teams counts them.
    public func count(_ group: ChatGroup) -> Int { unread(in: group).count }
}

/// An unread chat as BriefBar saves it, so it survives a restart after Notification Center
/// dropped its notifications.
public struct CachedConversation: Sendable, Equatable, Codable {
    public var id: String
    public var kind: ConversationKind
    public var name: String
    /// Its unread messages, oldest first.
    public var messages: [ChatMessage]

    public init(id: String, kind: ConversationKind, name: String, messages: [ChatMessage]) {
        self.id = id
        self.kind = kind
        self.name = name
        self.messages = messages
    }
}

/// What BriefBar knew when it started.
public struct LaunchContext: Sendable, Equatable {
    public var isFirstLaunch: Bool
    /// When it was last running, if it ever was.
    public var lastRunAt: Date?
    /// The unread chats it saved.
    public var cached: [CachedConversation]
    public var launchedAt: Date

    public init(isFirstLaunch: Bool, lastRunAt: Date?, cached: [CachedConversation] = [], launchedAt: Date) {
        self.isFirstLaunch = isFirstLaunch
        self.lastRunAt = lastRunAt
        self.cached = cached
        self.launchedAt = launchedAt
    }

    /// From BriefBar's saved state: without a record of it ever running, it's the first launch.
    public init(state: PulseState?, cached: [CachedConversation], launchedAt: Date) {
        self.init(isFirstLaunch: state?.lastRunAt == nil, lastRunAt: state?.lastRunAt, cached: cached,
                  launchedAt: launchedAt)
    }
}

public struct TrackerSettings: Sendable, Equatable {
    /// Unread messages older than this count as read; nil keeps them until they're read.
    public var keepUnreadFor: TimeInterval?
    /// How long read chats stay in Recent.
    public var recentWindow: TimeInterval
    public var recentLimit: Int
    /// At most this many unread messages per chat are saved.
    public var savedMessagesPerChat: Int
    /// At most this many of a chat's newest messages are kept in its summary.
    public var latestLimit: Int

    public init(
        keepUnreadFor: TimeInterval? = 86_400, recentWindow: TimeInterval = 86_400, recentLimit: Int = 10,
        savedMessagesPerChat: Int = 20, latestLimit: Int = 5
    ) {
        self.keepUnreadFor = keepUnreadFor
        self.recentWindow = recentWindow
        self.recentLimit = recentLimit
        self.savedMessagesPerChat = savedMessagesPerChat
        self.latestLimit = latestLimit
    }
}

/// Decides which chats are unread. Notification Center doesn't record what you've read, so:
///
/// - A message that arrives while BriefBar runs, or arrived while it didn't, is unread.
/// - Opening a chat from BriefBar, or marking it read, reads it.
/// - Notifications that leave Notification Center were clicked or cleared there, or withdrawn by
///   Teams: their chat is read up to them. Except when it's full and drops old notifications as new
///   ones arrive: those chats stay unread, kept here although Notification Center no longer has them.
/// - Unread messages older than `TrackerSettings.keepUnreadFor` count as read.
///
/// A value type with no clock or I/O of its own, so every rule is testable.
public struct UnreadTracker: Sendable {
    struct Tracked: Sendable, Equatable {
        var message: ChatMessage
        var isUnread: Bool
        /// Keys of the stored notifications for this message; empty once Notification Center dropped them.
        var stored: Set<String>
    }

    private(set) var tracked: [String: Tracked] = [:]
    private var storedKeys: Set<String> = []
    private var messageKeyByNotification: [String: String] = [:]
    /// The most notifications seen at once: the store's limit, once it has been reached.
    private var highWater = 0
    private var readThrough: [String: Date] = [:]
    private var allReadThrough: Date
    /// Set only by `markEverythingRead`, unlike the launch baseline in `allReadThrough`: what was read
    /// since launch, which saved chats restored late must respect.
    private var everythingReadThrough: Date?
    private var hasBaseline = false

    /// Read messages that Notification Center no longer has are forgotten after this.
    static let retention: TimeInterval = 2 * 86_400
    static let maxTracked = 5_000

    public init(launch: LaunchContext) {
        // On the very first launch, what's already stored counts as read, so the counts are never
        // wrong on day one. Later, what arrived while BriefBar wasn't running is unread, and what
        // it saved as unread still is.
        allReadThrough = launch.isFirstLaunch ? launch.launchedAt : launch.lastRunAt ?? launch.launchedAt
        for conversation in launch.cached {
            for message in conversation.messages {
                tracked[message.key] = Tracked(message: message, isUnread: true, stored: [])
            }
        }
    }

    /// Adds saved unread chats that could only be loaded after launch (the keychain was locked). Their
    /// messages are unread again, including those Notification Center still holds, which the launch
    /// baseline counted as read; except what was read since launch, per chat or all at once.
    public mutating func restore(_ conversations: [CachedConversation]) {
        for message in conversations.flatMap(\.messages) {
            let readUntil = max(readThrough[message.conversationID] ?? .distantPast, everythingReadThrough ?? .distantPast)
            guard message.deliveredAt > readUntil else { continue }
            if tracked[message.key] != nil {
                tracked[message.key]?.isUnread = true
            } else {
                tracked[message.key] = Tracked(message: message, isUnread: true, stored: [])
            }
        }
    }

    /// Takes in every Teams notification Notification Center has stored now.
    public mutating func apply(_ notifications: [ParsedNotification], now: Date) {
        let keys = Set(notifications.map(\.key))
        if hasBaseline {
            let removed = storedKeys.subtracting(keys)
            let arrived = keys.subtracting(storedKeys)
            let evicted = notifications.count >= highWater && arrived.count >= removed.count
            if !removed.isEmpty, !evicted {
                var through: [String: Date] = [:]
                for key in removed {
                    guard let messageKey = messageKeyByNotification[key], let message = tracked[messageKey]?.message
                    else { continue }
                    through[message.conversationID] = max(through[message.conversationID] ?? .distantPast, message.deliveredAt)
                }
                for (conversation, date) in through {
                    markRead(conversationID: conversation, through: date)
                }
            }
        }
        highWater = max(highWater, notifications.count)

        for key in tracked.keys {
            tracked[key]?.stored = []
        }
        var messageKeys: [String: String] = [:]
        for notification in notifications {
            guard let message = notification.item.message else { continue }
            messageKeys[notification.key] = message.key
            if var existing = tracked[message.key] {
                existing.stored.insert(notification.key)
                if !message.chatName.isEmpty { existing.message.chatName = message.chatName }
                tracked[message.key] = existing
            } else {
                let readUntil = max(readThrough[message.conversationID] ?? .distantPast, allReadThrough)
                tracked[message.key] = Tracked(
                    message: message, isUnread: message.deliveredAt > readUntil, stored: [notification.key]
                )
            }
        }
        storedKeys = keys
        messageKeyByNotification = messageKeys
        hasBaseline = true
        prune(now: now)
    }

    /// Reads a chat: you opened it or marked it read.
    public mutating func markRead(conversationID: String, at date: Date) {
        let newest = tracked.values.filter { $0.message.conversationID == conversationID }.map(\.message.deliveredAt).max()
        markRead(conversationID: conversationID, through: max(date, newest ?? date))
    }

    public mutating func markAllRead(_ group: ChatGroup, at date: Date) {
        let conversations = Set(tracked.values.filter { $0.isUnread && $0.message.kind.chatGroup == group }
            .map(\.message.conversationID))
        for conversation in conversations {
            markRead(conversationID: conversation, at: date)
        }
    }

    /// Reads everything delivered up to `date`, for example when Teams says nothing is unread.
    public mutating func markEverythingRead(at date: Date) {
        allReadThrough = max(allReadThrough, date)
        everythingReadThrough = max(everythingReadThrough ?? .distantPast, date)
        for (key, item) in tracked where item.isUnread && item.message.deliveredAt <= date {
            tracked[key]?.isUnread = false
        }
    }

    /// Unread messages older than the setting count as read from now on.
    public mutating func expire(now: Date, settings: TrackerSettings) {
        guard let keep = settings.keepUnreadFor else { return }
        let cutoff = now.addingTimeInterval(-keep)
        for (key, item) in tracked where item.isUnread && item.message.deliveredAt < cutoff {
            tracked[key]?.isUnread = false
        }
    }

    public func state(now: Date, settings: TrackerSettings) -> UnreadState {
        let cutoff = settings.keepUnreadFor.map { now.addingTimeInterval(-$0) } ?? .distantPast
        let recentCutoff = now.addingTimeInterval(-settings.recentWindow)
        var state = UnreadState()
        for (id, items) in Dictionary(grouping: tracked.values, by: \.message.conversationID) {
            let sorted = items.sorted { Self.chronological($0.message, $1.message) }
            guard let latest = sorted.last?.message, let group = latest.kind.chatGroup else { continue }
            let messages = sorted.map(\.message)
            let unread = sorted.filter { $0.isUnread && $0.message.deliveredAt >= cutoff }.map(\.message)
            let summary = ConversationSummary(
                id: id, kind: latest.kind, group: group, name: Self.name(of: messages), unread: unread,
                latestMessages: Array(messages.suffix(settings.latestLimit)), lastActivity: latest.deliveredAt,
                link: Self.link(unread: unread, messages: messages)
            )
            if summary.isUnread {
                state.unread[group, default: []].append(summary)
            } else if summary.lastActivity >= recentCutoff {
                state.recent[group, default: []].append(summary)
            }
        }
        for group in ChatGroup.allCases {
            state.unread[group]?.sort {
                ($0.unread.last?.deliveredAt ?? $0.lastActivity, $0.id) > ($1.unread.last?.deliveredAt ?? $1.lastActivity, $1.id)
            }
            state.recent[group] = state.recent[group].map {
                Array($0.sorted { ($0.lastActivity, $0.id) > ($1.lastActivity, $1.id) }.prefix(settings.recentLimit))
            }
        }
        return state
    }

    /// The unread chats to save, with at most `savedMessagesPerChat` messages each.
    public func savedConversations(now: Date, settings: TrackerSettings) -> [CachedConversation] {
        let state = state(now: now, settings: settings)
        return ChatGroup.allCases.flatMap { state.unread(in: $0) }
            .map { CachedConversation(id: $0.id, kind: $0.kind, name: $0.name,
                                      messages: Array($0.unread.suffix(settings.savedMessagesPerChat))) }
            .sorted { $0.id < $1.id }
    }

    // MARK: - Private

    private mutating func markRead(conversationID: String, through date: Date) {
        readThrough[conversationID] = max(readThrough[conversationID] ?? .distantPast, date)
        for (key, item) in tracked
        where item.isUnread && item.message.conversationID == conversationID && item.message.deliveredAt <= date {
            tracked[key]?.isUnread = false
        }
    }

    private mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        tracked = tracked.filter { $0.value.isUnread || !$0.value.stored.isEmpty || $0.value.message.deliveredAt >= cutoff }
        if tracked.count > Self.maxTracked {
            let oldestRead = tracked.filter { !$0.value.isUnread && $0.value.stored.isEmpty }
                .sorted { $0.value.message.deliveredAt < $1.value.message.deliveredAt }
                .prefix(tracked.count - Self.maxTracked)
            for (key, _) in oldestRead {
                tracked[key] = nil
            }
        }
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        readThrough = readThrough.filter { $0.value >= weekAgo }
    }

    static func chronological(_ a: ChatMessage, _ b: ChatMessage) -> Bool {
        if a.deliveredAt != b.deliveredAt { return a.deliveredAt < b.deliveredAt }
        let first = Int64(a.messageID ?? "") ?? 0
        let second = Int64(b.messageID ?? "") ?? 0
        if first != second { return first < second }
        return a.key < b.key
    }

    private static func name(of messages: [ChatMessage]) -> String {
        if let name = messages.reversed().lazy.map(\.chatName).first(where: { !$0.isEmpty }) { return name }
        if let sender = messages.reversed().lazy.compactMap(\.sender).first(where: { !$0.isEmpty }) { return sender }
        return "Untitled chat"
    }

    private static func link(unread: [ChatMessage], messages: [ChatMessage]) -> URL? {
        let target = unread.first { $0.messageID != nil } ?? unread.first
            ?? messages.last { $0.messageID != nil } ?? messages.last
        return target.flatMap(DeepLink.link(to:))
    }
}
