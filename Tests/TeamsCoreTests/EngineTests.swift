import Foundation
import Testing
@testable import TeamsCore
@testable import NotificationCenterDB
import BriefBarCore

@Suite struct FormatCheckTests {
    private func notifications(messages: Int, unrecognized: Int) -> [ParsedNotification] {
        let message = ChatMessage(conversationID: Chat.avery, kind: .oneOnOne, messageID: nil, notificationKey: "n",
                                  deliveredAt: t(0), chatName: "", sender: nil, text: "")
        return Array(repeating: ParsedNotification(key: "m", deliveredAt: nil, item: .message(message)), count: messages)
            + Array(repeating: ParsedNotification(key: "u", deliveredAt: nil, item: .unrecognized(.missingType)), count: unrecognized)
    }

    @Test func judgesHowMuchItUnderstood() {
        #expect(FormatReport([]).verdict == .empty)
        #expect(FormatReport(notifications(messages: 10, unrecognized: 0)).verdict == .ok)
        #expect(FormatReport(notifications(messages: 9, unrecognized: 3)).verdict == .ok)
        #expect(FormatReport(notifications(messages: 6, unrecognized: 3)).verdict == .partlyUnreadable(unreadable: 3, total: 9))
        #expect(FormatReport(notifications(messages: 0, unrecognized: 4)).verdict == .unrecognized(total: 4))
    }

    @Test func countsEachKind() {
        let report = FormatReport([
            ParsedNotification(key: "a", deliveredAt: nil, item: .chatActivity(conversationID: Chat.avery, kind: .oneOnOne)),
            ParsedNotification(key: "b", deliveredAt: nil, item: .channelPost(channelID: nil)),
            ParsedNotification(key: "c", deliveredAt: nil, item: .otherNotification),
            ParsedNotification(key: "d", deliveredAt: nil, item: .unrecognized(.notPlist)),
        ])
        #expect(report.chatActivity == 1 && report.channelPosts == 1 && report.otherNotifications == 1)
        #expect(report.unrecognized == [.notPlist: 1])
        #expect(report.recognized == 3 && report.unreadable == 1)
    }

    @Test func doesNotMistakeOtherKindsForAFormatChange() {
        // Left alone after you clear Notification Center: a call is no sign that Teams changed.
        let call = ParsedNotification(key: "call", deliveredAt: nil, item: .otherNotification)
        #expect(FormatReport([call]).verdict == .ok)
    }
}

@Suite struct DiagnosticsTests {
    @Test func describesStructureWithoutNamesMessagesOrIDs() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = paths(in: directory)
        let db = try TestDatabase(at: paths.database)
        defer { db.close() }
        try db.add(Record.message(Chat.avery, title: "Avery Quinn", body: "The merger closes Friday", at: t(0)), delivered: t(0))
        try db.add(Record.message(Chat.launchCrew, title: "Launch crew & Ops", body: "Jordan Lee: Budget is 4M", at: t(1)), delivered: t(1))
        try db.add(Record.reaction(Chat.avery, title: "👍 Avery Quinn reacted to your message", at: t(2)), delivered: t(2))
        try db.add(Record.channelPost(title: "Sam Rivera posted a new message", body: "Q3 numbers", at: t(3)), delivered: t(3))

        let report = await Diagnostics.report(paths: paths, cache: nil, followsReadsInTeams: true, appVersion: "0.1.0")
        #expect(report.contains("Teams notifications: 4 (chat messages 2, chat activity 1, channel posts 1, other kinds 0, unrecognized 0)"))
        #expect(report.contains("Chats with messages: oneOnOne 1, group 1, meeting 0"))
        #expect(report.contains("default_id: "))
        #expect(report.contains("<oneOnOne ID>"))
        #expect(report.contains("json {actionType: quickReply, convId: <oneOnOne ID>, userContextId: <guid>}"))
        #expect(report.contains("record(rec_id, app_id, uuid, data"))
        for secret in ["Avery", "Quinn", "merger", "Friday", "Launch crew", "Jordan", "Budget", "Sam Rivera", "Q3",
                       "11111111-aaaa", "0123456789abcdef", Chat.userContext, "abcdefabcdef", "deep-link"] {
            #expect(!report.contains(secret), "The report contains \(secret)")
        }
    }

    @Test(arguments: [
        ("chats", "chats"), ("1792317600000", "<13-digit>"), ("42", "<number>"), ("", "\"\""),
        ("Avery Quinn", "<text>"), (Chat.launchCrew, "<group ID>"), (Chat.channel, "<channel ID>"),
        (Chat.userContext, "<guid>"), (#"{"messageId":1792317600000,"isSmsThread":false}"#, "json {isSmsThread: false, messageId: <13-digit>}"),
        (#"{"8:orgid:secret":"x"}"#, "json {<key>: <text>}"),
    ])
    func describesValueShapes(_ value: String, _ shape: String) {
        #expect(Diagnostics.shape(value) == shape)
    }

    @Test func saysWhenItHasNoAccess() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = await Diagnostics.report(paths: paths(in: directory), cache: nil, followsReadsInTeams: false, appVersion: "0.1.0")
        #expect(report.contains("access missing"))
        #expect(report.contains("Teams' dock badge, from lsappinfo: "))
    }
}

@Suite struct DockBadgeTests {
    /// `lsappinfo info -only StatusLabel` without `-long`, on macOS 27: no `StatusLabel`, badge or not.
    static let macOS27ShortFormat = [
        "[ NULL ]  ASN:0x0-0x1234: ",
        "    bundleID=[ NULL ] ",
        "    bundle path=[ NULL ] ",
        "    executable path=[ NULL ] ",
        " !cgsConnection !signalled type=[ NULL ]  flavor=[ NULL ]  Version=[ NULL ]  Arch=!!none ",
        "",
    ].joined(separator: "\n") + "\n"

    @Test(arguments: [
        (#""StatusLabel"={ "label"="3" }"#, DockBadge.count(3)),
        (#""StatusLabel"={ "label"="" }"#, DockBadge.noBadge),
        (#""StatusLabel"={ "label"="•" }"#, DockBadge.mark),
        (#""StatusLabel"=[ NULL ]"#, DockBadge.noBadge),
        // With -long, on macOS 27: a badge, a zero, one taken away, and one never set.
        ("\"LSASN\"=ASN:0x0-0x1234:\n\"StatusLabel\"={ \"label\"=\"7\" }\n", DockBadge.count(7)),
        ("\"LSASN\"=ASN:0x0-0x1234:\n\"StatusLabel\"={ \"label\"=\"0\" }\n", DockBadge.count(0)),
        ("\"LSASN\"=ASN:0x0-0x1234:\n\"StatusLabel\"={ \"label\"=kCFNULL }\n", DockBadge.noBadge),
        ("\"LSASN\"=ASN:0x0-0x1234:\n", DockBadge.noBadge),
        (macOS27ShortFormat, nil),
        ("", nil),
        ("\n", nil),
    ] as [(String, DockBadge?)])
    func readsLsappinfoOutput(_ output: String, _ badge: DockBadge?) {
        #expect(DockBadge.parse(lsappinfo: output) == badge)
    }

    @Test func asksLsappinfoForTheLongFormat() async {
        #expect(DockBadge.lsappinfoArguments(bundleIdentifier: "com.microsoft.teams2")
            == ["info", "-long", "-only", "StatusLabel", "-app", "com.microsoft.teams2"])
        let badge = await DockBadge.read(bundleIdentifier: "com.example.teams-pulse-tests.not-running")
        #expect(badge == nil)
    }

    @Test func noticesOnlyABadgeThatStaysGoneInTheSameTeams() {
        var tracker = DockBadgeTracker(confirmation: 10)
        func updates(_ readings: [(DockBadge?, Int32, TimeInterval)]) -> [Date?] {
            readings.map { tracker.update($0.0, process: $0.1, at: t($0.2)) }
        }
        // No badge right after Teams starts, or no reading at all, says nothing. A badge that goes and stays
        // gone does, once, with when it was first seen gone.
        #expect(updates([(.noBadge, 10, 0), (nil, 10, 5), (.count(3), 10, 10), (.count(2), 10, 15), (.noBadge, 10, 20),
                         (.noBadge, 10, 25), (.noBadge, 10, 30), (.noBadge, 10, 35)])
            == [nil, nil, nil, nil, nil, nil, t(20), nil])
        // A badge that's back within the confirmation, as it might be while Teams reloads, says nothing.
        #expect(updates([(.count(1), 10, 40), (.noBadge, 10, 45), (.count(1), 10, 50), (.count(0), 10, 55),
                         (.count(0), 10, 64), (.count(0), 10, 65)])
            == [nil, nil, nil, nil, nil, t(55)])
        // A badge from an earlier Teams process says nothing about a new one.
        #expect(updates([(.mark, 10, 70), (.noBadge, 11, 75), (.noBadge, 11, 90)]) == [nil, nil, nil])
        // Teams quit (no reading), then started again without a badge.
        #expect(updates([(.count(1), 11, 95), (nil, 11, 100), (.noBadge, 11, 105), (.noBadge, 11, 120)])
            == [nil, nil, nil, nil])
        // Teams quit before the badge had been gone long enough.
        #expect(updates([(.count(4), 12, 125), (.noBadge, 12, 130), (nil, 12, 135), (.noBadge, 12, 145)])
            == [nil, nil, nil, nil])
        #expect(updates([(.count(4), 12, 150), (.noBadge, 12, 155)]) == [nil, nil])
        tracker.reset()
        #expect(updates([(.noBadge, 12, 165)]) == [nil])
    }

    @Test func clearsOnlyWithoutAnUnreadCount() {
        #expect(DockBadge.noBadge.isClear)
        #expect(DockBadge.count(0).isClear)
        #expect(!DockBadge.count(2).isClear)
        #expect(!DockBadge.mark.isClear)
    }
}

@Suite struct NotificationEngineTests {
    @Test func publishesChangesAsNotificationCenterWritesThem() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = paths(in: directory)
        let db = try TestDatabase(at: paths.database)
        defer { db.close() }
        try db.add(Record.message(Chat.avery, title: "Avery Quinn", body: "First", at: t(0)), delivered: t(0))

        let collector = SnapshotCollector()
        let engine = NotificationEngine(paths: paths, reloadDelay: 0.05, onChange: collector.add)
        engine.start()
        defer { engine.stop() }

        let first = try await collector.wait("the first read") { $0.notifications?.count == 1 }
        #expect(first.access == .granted)
        #expect(first.problem == nil)
        #expect(first.notifications?.first?.raw == nil)

        // Notification Center keeps its connection open; only the write-ahead log changes.
        let row = try db.add(Record.message(Chat.launchCrew, title: "Launch crew", body: "Jordan Lee: Go", at: t(1)), delivered: t(1))
        let second = try await collector.wait("the new message") { $0.notifications?.count == 2 }
        #expect(second.notifications?.compactMap(\.item.message).map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.group, .oneOnOne])

        try db.remove(row)
        try await collector.wait("the removal") { $0.notifications?.count == 1 }
    }

    @Test func waitsForTheDatabaseAndPicksItUp() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = paths(in: directory)
        let collector = SnapshotCollector()
        let engine = NotificationEngine(paths: paths, reloadDelay: 0.05, accessIntervals: (0.1, 0.1), onChange: collector.add)
        engine.start()
        defer { engine.stop() }

        let missing = try await collector.wait("no database") { $0.access == .missing }
        #expect(missing.notifications == nil)
        #expect(missing.problem == .databaseMissing(path: paths.database.path))

        let db = try TestDatabase(at: paths.database)
        defer { db.close() }
        try db.add(Record.message(Chat.avery, title: "Avery Quinn", body: "Hi", at: t(0)), delivered: t(0))
        try await collector.wait("the database") { $0.access == .granted && $0.notifications?.count == 1 }
    }

    @Test func reportsAChangedFormat() throws {
        try withTemporaryDirectory { directory in
            let paths = paths(in: directory)
            let db = try TestDatabase(at: paths.database)
            defer { db.close() }
            try db.add(Data("not a plist".utf8), delivered: t(0))
            try db.add(Record.data(title: "", body: "", userInfo: ["default_id": Chat.avery], date: t(1)), delivered: t(1))
            let snapshot = NotificationEngine.loadOnce(paths: paths)
            #expect(snapshot.problem == .formatChanged(total: 2))
            #expect(snapshot.notifications?.count == 2)
        }
    }

    @Test func timesSuccessfulReadsWithoutCountingThemAsChanges() throws {
        try withTemporaryDirectory { directory in
            let paths = paths(in: directory)
            #expect(NotificationEngine.loadOnce(paths: paths).readAt == nil)
            let db = try TestDatabase(at: paths.database)
            defer { db.close() }
            let before = Date()
            let first = NotificationEngine.loadOnce(paths: paths)
            let second = NotificationEngine.loadOnce(paths: paths)
            #expect(try #require(first.readAt) >= before.addingTimeInterval(-1))
            #expect(first == second)
        }
    }

    @Test func reportsAChangedLayout() throws {
        try withTemporaryDirectory { directory in
            let paths = paths(in: directory)
            let db = try TestDatabase(at: paths.database, schema: "CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR);")
            defer { db.close() }
            let snapshot = NotificationEngine.loadOnce(paths: paths)
            #expect(snapshot.problem == .layoutChanged(missing: ["record.app_id", "record.data"]))
            #expect(snapshot.notifications == nil)
        }
    }
}
