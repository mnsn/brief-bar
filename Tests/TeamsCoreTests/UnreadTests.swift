import Foundation
import Testing
@testable import TeamsCore
@testable import NotificationCenterDB
import BriefBarCore

/// Builds the notifications Notification Center would hold, for the tracker.
private struct Store {
    var notifications: [ParsedNotification] = []

    @discardableResult
    mutating func message(
        _ conversation: String, _ name: String, _ text: String, at date: Date, key: String? = nil, messageID id: String? = nil
    ) -> ChatMessage {
        let kind = ConversationKind(chatID: conversation)
        let message = ChatMessage(
            conversationID: conversation, kind: kind, messageID: id ?? messageID(date), notificationKey: key ?? UUID().uuidString,
            deliveredAt: date, chatName: name, sender: kind == .oneOnOne ? name : "Jordan Lee", text: text
        )
        notifications.append(ParsedNotification(key: message.notificationKey, deliveredAt: date, item: .message(message)))
        return message
    }

    mutating func other(_ item: TeamsItem, key: String = UUID().uuidString, at date: Date) {
        notifications.append(ParsedNotification(key: key, deliveredAt: date, item: item))
    }

    mutating func remove(_ message: ChatMessage) {
        notifications.removeAll { $0.key == message.notificationKey }
    }

    mutating func removeOldest() {
        notifications.remove(at: notifications.indices.min { notifications[$0].deliveredAt! < notifications[$1].deliveredAt! }!)
    }
}

@Suite struct UnreadTrackerTests {
    private let settings = TrackerSettings(keepUnreadFor: 86_400)

    private func names(_ state: UnreadState, _ group: ChatGroup) -> [String] {
        state.unread(in: group).map(\.name)
    }

    @Test func countsNothingAlreadyStoredOnTheFirstLaunch() {
        var store = Store()
        store.message(Chat.avery, "Avery Quinn", "Old news", at: t(-600))
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: true, lastRunAt: nil, launchedAt: t(0)))
        tracker.apply(store.notifications, now: t(0))
        var state = tracker.state(now: t(0), settings: settings)
        #expect(state.count(.chats) == 0)
        #expect(state.recent(in: .chats).map(\.name) == ["Avery Quinn"])

        store.message(Chat.avery, "Avery Quinn", "Lunch?", at: t(10))
        store.message(Chat.launchCrew, "Launch crew", "Shipping at 5", at: t(20))
        tracker.apply(store.notifications, now: t(21))
        state = tracker.state(now: t(21), settings: settings)
        #expect(names(state, .chats) == ["Avery Quinn"])
        #expect(names(state, .groups) == ["Launch crew"])
        #expect(state.unread(in: .chats)[0].unread.map(\.text) == ["Lunch?"])
        #expect(state.unread(in: .chats)[0].latestMessages.map(\.text) == ["Old news", "Lunch?"])
        #expect(state.recent(in: .chats).isEmpty)
    }

    @Test func countsWhatArrivedWhileItWasNotRunning() {
        var store = Store()
        store.message(Chat.avery, "Avery Quinn", "Before", at: t(-100))
        store.message(Chat.sam, "Sam Rivera", "While away", at: t(100))
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: false, lastRunAt: t(0), launchedAt: t(200)))
        tracker.apply(store.notifications, now: t(200))
        let state = tracker.state(now: t(200), settings: settings)
        #expect(names(state, .chats) == ["Sam Rivera"])
        #expect(state.recent(in: .chats).map(\.name) == ["Avery Quinn"])
    }

    @Test func restoresSavedUnreadChatsThatNotificationCenterDropped() {
        let saved = ChatMessage(conversationID: Chat.launchCrew, kind: .group, messageID: messageID(t(-5_000)),
                                notificationKey: "gone", deliveredAt: t(-5_000), chatName: "Launch crew",
                                sender: "Jordan Lee", text: "Still unread")
        var store = Store()
        store.message(Chat.avery, "Avery Quinn", "Read before quitting", at: t(-4_000))
        let launch = LaunchContext(
            isFirstLaunch: false, lastRunAt: t(-1_000),
            cached: [CachedConversation(id: Chat.launchCrew, kind: .group, name: "Launch crew", messages: [saved])],
            launchedAt: t(0)
        )
        var tracker = UnreadTracker(launch: launch)
        tracker.apply(store.notifications, now: t(0))
        let state = tracker.state(now: t(0), settings: settings)
        #expect(names(state, .groups) == ["Launch crew"])
        #expect(state.unread(in: .groups)[0].unread == [saved])
        #expect(state.count(.chats) == 0)
    }

    @Test func readsAChatWhenYouOpenItOrMarkItRead() {
        var store = Store()
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: true, lastRunAt: nil, launchedAt: t(0)))
        tracker.apply(store.notifications, now: t(0))
        store.message(Chat.avery, "Avery Quinn", "One", at: t(10))
        store.message(Chat.avery, "Avery Quinn", "Two", at: t(11))
        store.message(Chat.sam, "Sam Rivera", "Hi", at: t(12))
        store.message(Chat.launchCrew, "Launch crew", "Go", at: t(13))
        tracker.apply(store.notifications, now: t(14))

        tracker.markRead(conversationID: Chat.avery, at: t(20))
        var state = tracker.state(now: t(20), settings: settings)
        #expect(names(state, .chats) == ["Sam Rivera"])
        #expect(state.recent(in: .chats).map(\.name) == ["Avery Quinn"])

        // A notification for an already-read message that shows up late stays read.
        store.message(Chat.avery, "Avery Quinn", "Late", at: t(19))
        tracker.apply(store.notifications, now: t(21))
        #expect(tracker.state(now: t(21), settings: settings).count(.chats) == 1)

        tracker.markAllRead(.chats, at: t(30))
        state = tracker.state(now: t(30), settings: settings)
        #expect(state.count(.chats) == 0)
        #expect(names(state, .groups) == ["Launch crew"])

        store.message(Chat.avery, "Avery Quinn", "New", at: t(40))
        tracker.apply(store.notifications, now: t(40))
        #expect(names(tracker.state(now: t(40), settings: settings), .chats) == ["Avery Quinn"])
    }

    @Test func keepsChatsThatNotificationCenterDropsToMakeRoom() {
        var store = Store()
        let first = store.message(Chat.avery, "Avery Quinn", "Unread and old", at: t(1))
        for index in 0..<4 {
            store.message(Chat.sam, "Sam Rivera", "Filler \(index)", at: t(Double(2 + index)))
        }
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: false, lastRunAt: t(0), launchedAt: t(10)))
        tracker.apply(store.notifications, now: t(10))
        #expect(tracker.state(now: t(10), settings: settings).count(.chats) == 2)

        // Full: one arrives, the oldest goes.
        store.removeOldest()
        store.message(Chat.launchCrew, "Launch crew", "New", at: t(20))
        tracker.apply(store.notifications, now: t(20))
        let state = tracker.state(now: t(20), settings: settings)
        #expect(Set(names(state, .chats)) == ["Avery Quinn", "Sam Rivera"])
        #expect(state.unread(in: .chats).first { $0.id == Chat.avery }?.unread == [first])
        #expect(names(state, .groups) == ["Launch crew"])
    }

    @Test func readsAChatWhoseNotificationsYouClickedOrCleared() {
        var store = Store()
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: true, lastRunAt: nil, launchedAt: t(0)))
        tracker.apply(store.notifications, now: t(0))
        store.message(Chat.avery, "Avery Quinn", "Older", at: t(10))
        let newest = store.message(Chat.avery, "Avery Quinn", "Newest", at: t(11))
        store.message(Chat.sam, "Sam Rivera", "Hi", at: t(12))
        tracker.apply(store.notifications, now: t(13))

        // Clicking the newest banner removes it; the chat is read up to it, the older one included.
        store.remove(newest)
        tracker.apply(store.notifications, now: t(14))
        let state = tracker.state(now: t(14), settings: settings)
        #expect(names(state, .chats) == ["Sam Rivera"])
    }

    @Test func countsAMessageOnceWhenTeamsPostsItAgain() {
        var store = Store()
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: true, lastRunAt: nil, launchedAt: t(0)))
        tracker.apply(store.notifications, now: t(0))
        store.message(Chat.avery, "Avery Quinn", "Edited", at: t(10), key: "first", messageID: "1792317610000")
        store.message(Chat.avery, "Avery Quinn", "Edited!", at: t(11), key: "second", messageID: "1792317610000")
        tracker.apply(store.notifications, now: t(12))
        #expect(tracker.state(now: t(12), settings: settings).unread(in: .chats).first?.unreadCount == 1)
    }

    @Test func letsOldUnreadMessagesExpire() {
        var store = Store()
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: true, lastRunAt: nil, launchedAt: t(0)))
        tracker.apply(store.notifications, now: t(0))
        store.message(Chat.avery, "Avery Quinn", "Hi", at: t(10))
        tracker.apply(store.notifications, now: t(10))

        let hour = TrackerSettings(keepUnreadFor: 3_600)
        #expect(tracker.state(now: t(3_000), settings: hour).count(.chats) == 1)
        #expect(tracker.state(now: t(4_000), settings: hour).count(.chats) == 0)
        #expect(tracker.state(now: t(4_000), settings: TrackerSettings(keepUnreadFor: nil)).count(.chats) == 1)
        tracker.expire(now: t(4_000), settings: hour)
        #expect(tracker.state(now: t(4_000), settings: TrackerSettings(keepUnreadFor: nil)).count(.chats) == 0)
    }

    @Test func readsEverythingWhenTeamsSaysNothingIsUnread() {
        var store = Store()
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: true, lastRunAt: nil, launchedAt: t(0)))
        tracker.apply(store.notifications, now: t(0))
        store.message(Chat.avery, "Avery Quinn", "Hi", at: t(10))
        store.message(Chat.launchCrew, "Launch crew", "Go", at: t(11))
        tracker.apply(store.notifications, now: t(12))
        tracker.markEverythingRead(at: t(12))
        let state = tracker.state(now: t(12), settings: settings)
        #expect(state.count(.chats) == 0 && state.count(.groups) == 0)
    }

    @Test func ignoresReactionsAndChannels() {
        var store = Store()
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: true, lastRunAt: nil, launchedAt: t(0)))
        tracker.apply(store.notifications, now: t(0))
        store.other(.chatActivity(conversationID: Chat.avery, kind: .oneOnOne), at: t(10))
        store.other(.channelPost(channelID: Chat.channel), at: t(11))
        store.other(.otherNotification, at: t(12))
        store.other(.unrecognized(.missingType), at: t(13))
        tracker.apply(store.notifications, now: t(13))
        let state = tracker.state(now: t(13), settings: settings)
        #expect(state.count(.chats) == 0 && state.count(.groups) == 0)
        #expect(state.recent(in: .chats).isEmpty)
    }

    @Test func sortsNewestFirstAndLinksToTheOldestUnreadMessage() throws {
        var store = Store()
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: true, lastRunAt: nil, launchedAt: t(0)))
        tracker.apply(store.notifications, now: t(0))
        let first = store.message(Chat.launchCrew, "Launch crew", "First", at: t(10))
        store.message(Chat.weeklySync, "Weekly sync", "Notes", at: t(20))
        store.message(Chat.launchCrew, "Launch crew", "Second", at: t(30))
        tracker.apply(store.notifications, now: t(31))
        let groups = tracker.state(now: t(31), settings: settings).unread(in: .groups)
        #expect(groups.map(\.name) == ["Launch crew", "Weekly sync"])
        #expect(groups[0].unreadCount == 2)
        #expect(groups[0].link == DeepLink.message(conversationID: Chat.launchCrew, messageID: try #require(first.messageID)))
        #expect(groups[1].kind == .meeting)
    }

    @Test func savesOnlyUnreadChatsWithTheirNewestMessages() {
        var store = Store()
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: true, lastRunAt: nil, launchedAt: t(0)))
        tracker.apply(store.notifications, now: t(0))
        for index in 0..<5 {
            store.message(Chat.avery, "Avery Quinn", "Message \(index)", at: t(Double(10 + index)))
        }
        store.message(Chat.sam, "Sam Rivera", "Read", at: t(20))
        tracker.apply(store.notifications, now: t(21))
        tracker.markRead(conversationID: Chat.sam, at: t(22))

        let saved = tracker.savedConversations(now: t(22), settings: TrackerSettings(savedMessagesPerChat: 3))
        #expect(saved.map(\.id) == [Chat.avery])
        #expect(saved[0].name == "Avery Quinn")
        #expect(saved[0].messages.map(\.text) == ["Message 2", "Message 3", "Message 4"])
    }

    @Test func keepsRecentChatsWithinTheWindowAndLimit() {
        var store = Store()
        store.message(Chat.avery, "Avery Quinn", "Yesterday", at: t(-90_000))
        store.message(Chat.sam, "Sam Rivera", "Today", at: t(-100))
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: true, lastRunAt: nil, launchedAt: t(0)))
        tracker.apply(store.notifications, now: t(0))
        #expect(tracker.state(now: t(0), settings: settings).recent(in: .chats).map(\.name) == ["Sam Rivera"])
        #expect(tracker.state(now: t(0), settings: TrackerSettings(recentLimit: 0)).recent(in: .chats).isEmpty)
    }

    @Test func restoresSavedChatsLoadedLateUnlessReadSince() {
        func saved(_ conversation: String, _ name: String, at seconds: TimeInterval) -> CachedConversation {
            let message = ChatMessage(conversationID: conversation, kind: ConversationKind(chatID: conversation),
                                      messageID: messageID(t(seconds)), notificationKey: "saved-\(seconds)",
                                      deliveredAt: t(seconds), chatName: name, sender: name, text: "Saved")
            return CachedConversation(id: conversation, kind: message.kind, name: name, messages: [message])
        }
        var store = Store()
        store.message(Chat.sam, "Sam Rivera", "Hi", at: t(-50))
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: false, lastRunAt: t(-100), launchedAt: t(0)))
        tracker.apply(store.notifications, now: t(0))
        tracker.markRead(conversationID: Chat.avery, at: t(5))
        tracker.restore([saved(Chat.avery, "Avery Quinn", at: -200), saved(Chat.launchCrew, "Launch crew", at: -300)])
        let state = tracker.state(now: t(10), settings: settings)
        #expect(names(state, .chats) == ["Sam Rivera"])
        #expect(names(state, .groups) == ["Launch crew"])
    }

    @Test func restoresSavedChatsNotificationCenterStillHolds() {
        // The saved chat's message is still stored, but older than the last run, so the launch counted it
        // as read before the saved chats could be loaded.
        var store = Store()
        let kept = store.message(Chat.avery, "Avery Quinn", "Still unread", at: t(-50))
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: false, lastRunAt: t(0), launchedAt: t(10)))
        tracker.apply(store.notifications, now: t(10))
        #expect(tracker.state(now: t(10), settings: settings).count(.chats) == 0)

        tracker.restore([CachedConversation(id: Chat.avery, kind: .oneOnOne, name: "Avery Quinn", messages: [kept])])
        let state = tracker.state(now: t(70), settings: settings)
        #expect(names(state, .chats) == ["Avery Quinn"])
        #expect(state.unread(in: .chats)[0].unreadCount == 1)
    }

    @Test func keepsRestoredChatsReadAfterTeamsSaidEverythingWas() {
        let saved = ChatMessage(conversationID: Chat.sam, kind: .oneOnOne, messageID: messageID(t(-50)),
                                notificationKey: "gone", deliveredAt: t(-50), chatName: "Sam Rivera",
                                sender: "Sam Rivera", text: "Saved")
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: false, lastRunAt: t(0), launchedAt: t(10)))
        tracker.apply([], now: t(10))
        tracker.markEverythingRead(at: t(20))
        tracker.restore([CachedConversation(id: Chat.sam, kind: .oneOnOne, name: "Sam Rivera", messages: [saved])])
        #expect(tracker.state(now: t(70), settings: settings).count(.chats) == 0)
    }

    @Test func forgetsOldReadMessagesNotificationCenterNoLongerHas() {
        var store = Store()
        let old = store.message(Chat.avery, "Avery Quinn", "Old", at: t(0))
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: true, lastRunAt: nil, launchedAt: t(1)))
        tracker.apply(store.notifications, now: t(1))
        store.remove(old)
        tracker.apply(store.notifications, now: t(3 * 86_400))
        #expect(tracker.tracked.isEmpty)
    }
}

@Suite struct UnreadCacheTests {
    private func conversation(_ text: String = "Hi") -> CachedConversation {
        let message = ChatMessage(conversationID: Chat.avery, kind: .oneOnOne, messageID: "1792317600000",
                                  notificationKey: "n", deliveredAt: t(0), chatName: "Avery Quinn",
                                  sender: "Avery Quinn", text: text)
        return CachedConversation(id: Chat.avery, kind: .oneOnOne, name: "Avery Quinn", messages: [message])
    }

    @Test func sealsAndOpensTheUnreadChats() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("state/unread")
            let keys = MemoryKeyStore()
            let cache = UnreadCache(url: url, keyStore: keys)
            try cache.save([conversation("Secret plans")], at: t(0))

            let sealed = try Data(contentsOf: url)
            #expect(sealed.starts(with: Data("TPU1".utf8)))
            #expect(sealed.range(of: Data("Secret plans".utf8)) == nil)
            #expect(sealed.range(of: Data("Avery".utf8)) == nil)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? Int) == 0o600)
            let folder = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            #expect((folder[.posixPermissions] as? Int) == 0o700)
            #expect(try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

            #expect(cache.load() == .loaded([conversation("Secret plans")]))
        }
    }

    @Test func deletesTheFileWhenNothingIsUnread() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("unread")
            let cache = UnreadCache(url: url, keyStore: MemoryKeyStore())
            try cache.save([conversation()], at: t(0))
            try cache.save([], at: t(1))
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(cache.load() == .loaded([]))
        }
    }

    @Test func discardsWhatItCannotOpen() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("unread")
            let keys = MemoryKeyStore()
            try UnreadCache(url: url, keyStore: keys).save([conversation()], at: t(0))

            // Another key, as after the keychain item was removed: the file is useless, so it goes.
            let other = UnreadCache(url: url, keyStore: MemoryKeyStore(key: Data(repeating: 7, count: 32)))
            #expect(other.load() == .loaded([]))
            #expect(!FileManager.default.fileExists(atPath: url.path))

            try UnreadCache(url: url, keyStore: keys).save([conversation()], at: t(0))
            var tampered = try Data(contentsOf: url)
            tampered[tampered.count - 1] ^= 0xFF
            try tampered.write(to: url)
            #expect(UnreadCache(url: url, keyStore: keys).load() == .loaded([]))
            #expect(try keys.loadKey() == nil)
        }
    }

    @Test func keepsTheFileWhenTheKeyIsUnavailableForNow() throws {
        struct LockedKeychain: KeyStore {
            func loadKey() throws -> Data? { throw CocoaError(.fileReadNoPermission) }
            func saveKey(_ key: Data) throws {}
            func deleteKey() throws {}
        }
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("unread")
            try UnreadCache(url: url, keyStore: MemoryKeyStore()).save([conversation()], at: t(0))
            #expect(UnreadCache(url: url, keyStore: LockedKeychain()).load() == .keyUnavailable)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func remembersWhenItLastRan() throws {
        try withTemporaryDirectory { directory in
            let store = StateStore(url: directory.appendingPathComponent("state.json"))
            #expect(store.load() == nil)
            let state = PulseState(firstLaunchAt: t(0), lastRunAt: t(60), hadAccess: true)
            try store.save(state)
            #expect(store.load() == state)
            #expect(LaunchContext(state: nil, cached: [], launchedAt: t(0)).isFirstLaunch)
            #expect(!LaunchContext(state: state, cached: [], launchedAt: t(0)).isFirstLaunch)
        }
    }

    @Test func keepsDemoKeysInAFile() throws {
        try withTemporaryDirectory { directory in
            let keys = FileKeyStore(url: directory.appendingPathComponent("key"))
            #expect(try keys.loadKey() == nil)
            try keys.saveKey(Data(repeating: 1, count: 32))
            #expect(try keys.loadKey() == Data(repeating: 1, count: 32))
            try keys.deleteKey()
            #expect(try keys.loadKey() == nil)
        }
    }
}
