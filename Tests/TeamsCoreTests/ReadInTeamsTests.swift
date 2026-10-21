import Foundation
import Testing
@testable import TeamsCore
@testable import NotificationCenterDB
import BriefBarCore

/// Reading a chat in Teams itself leaves its notifications in Notification Center (Teams 26276 on
/// macOS 27), so only Teams' dock badge tells: it drops as you read, and goes when nothing is unread.
/// These replay that with a made-up database, and `lsappinfo`'s output on macOS 27.
@Suite struct ReadInTeamsTests {
    private let settings = TrackerSettings(keepUnreadFor: 86_400)
    private static let teams: Int32 = 4_242

    /// `lsappinfo info -long -only StatusLabel -app com.microsoft.teams2`, with a badge or without.
    private static func lsappinfo(_ label: String?) -> String {
        "\"LSASN\"=ASN:0x0-0x1234:\n\"StatusLabel\"={ \"label\"=\(label.map { "\"\($0)\"" } ?? "kCFNULL") }\n"
    }

    /// Notification Center's database, as BriefBar reads it, and what it does with Teams' badge.
    private struct Pulse {
        let paths: NotificationPaths
        var tracker = UnreadTracker(launch: LaunchContext(isFirstLaunch: false, lastRunAt: t(-60), launchedAt: t(0)))
        var badge = DockBadgeTracker()

        mutating func read(at seconds: TimeInterval, settings: TrackerSettings) throws -> UnreadState {
            tracker.apply(try #require(NotificationEngine.loadOnce(paths: paths).notifications), now: t(seconds))
            return tracker.state(now: t(seconds), settings: settings)
        }

        /// As `ConversationStore.dockBadgeChanged` does with a reading.
        mutating func badgeReading(_ output: String, at seconds: TimeInterval) {
            if let cleared = badge.update(DockBadge.parse(lsappinfo: output), process: ReadInTeamsTests.teams,
                                          at: t(seconds)) {
                tracker.markEverythingRead(at: cleared)
            }
        }
    }

    /// Twelve unread messages in a 1:1 chat, among channel posts and a reaction.
    private func makeDatabase(at paths: NotificationPaths) throws -> TestDatabase {
        let db = try TestDatabase(at: paths.database)
        for index in 0..<12 {
            let date = t(Double(10 + index))
            try db.add(Record.message(Chat.avery, title: "Avery Quinn", body: "Message \(index)", at: date), delivered: date)
        }
        try db.add(Record.channelPost(title: "Sam Rivera posted a new message", body: "Q3 plan", at: t(30)), delivered: t(30))
        try db.add(Record.reaction(Chat.sam, title: "👍 Sam Rivera reacted to your message", at: t(31)), delivered: t(31))
        return db
    }

    @Test func readsEveryChatOnceTeamsBadgeStaysGone() throws {
        try withTemporaryDirectory { directory in
            let paths = paths(in: directory)
            let db = try makeDatabase(at: paths)
            defer { db.close() }
            var pulse = Pulse(paths: paths)
            var state = try pulse.read(at: 40, settings: settings)
            #expect(state.count(.chats) == 1)
            #expect(state.unread(in: .chats).first?.unreadCount == 12)

            // You read the chat in Teams, then the rest: the notifications all stay, and the badge drops.
            for (label, seconds) in [("4", 40.0), ("3", 45), ("2", 50), ("1", 55)] {
                pulse.badgeReading(Self.lsappinfo(label), at: seconds)
            }
            state = try pulse.read(at: 56, settings: settings)
            #expect(state.unread(in: .chats).first?.unreadCount == 12)

            // The badge goes. A few seconds later it's still gone, so nothing in Teams is unread.
            pulse.badgeReading(Self.lsappinfo(nil), at: 60)
            pulse.badgeReading(Self.lsappinfo(nil), at: 65)
            #expect(try pulse.read(at: 66, settings: settings).count(.chats) == 1)
            pulse.badgeReading(Self.lsappinfo(nil), at: 70)
            state = try pulse.read(at: 71, settings: settings)
            #expect(state.count(.chats) == 0 && state.count(.groups) == 0)
            #expect(state.recent(in: .chats).map(\.name) == ["Avery Quinn"])
            #expect(pulse.tracker.savedConversations(now: t(71), settings: settings).isEmpty)

            // The next message is unread again.
            try db.add(Record.message(Chat.avery, title: "Avery Quinn", body: "One more thing", at: t(80)), delivered: t(80))
            pulse.badgeReading(Self.lsappinfo("1"), at: 81)
            state = try pulse.read(at: 82, settings: settings)
            #expect(state.unread(in: .chats).first?.unread.map(\.text) == ["One more thing"])
        }
    }

    @Test func keepsChatsUnreadWhileTheBadgeIsBackSoon() throws {
        try withTemporaryDirectory { directory in
            let paths = paths(in: directory)
            let db = try makeDatabase(at: paths)
            defer { db.close() }
            var pulse = Pulse(paths: paths)
            for (label, seconds) in [("1", 40.0), (nil, 45), ("1", 50), (nil, 55), ("1", 60)] as [(String?, TimeInterval)] {
                pulse.badgeReading(Self.lsappinfo(label), at: seconds)
            }
            #expect(try pulse.read(at: 70, settings: settings).unread(in: .chats).first?.unreadCount == 12)
        }
    }
}
