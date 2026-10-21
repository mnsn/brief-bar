import Foundation
import Testing
@testable import TeamsCore
@testable import NotificationCenterDB
import BriefBarCore

@Suite struct NotificationDatabaseTests {
    @Test func readsOnlyTeamsRecords() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("db")
            let db = try TestDatabase(at: url)
            defer { db.close() }
            try db.addApp("com.apple.Mail", badge: 4)
            try db.add(Record.message(Chat.avery, title: "Avery Quinn", body: "Hi", at: t(0)), delivered: t(0))
            try db.add(Data("other app".utf8), delivered: t(1), app: "com.apple.Mail")
            try db.add(Record.message(Chat.sam, title: "Sam Rivera", body: "Hello", at: t(2)), delivered: t(2),
                       app: "com.microsoft.teams")

            let contents = try NotificationDatabase.load(at: url, bundleIdentifiers: TeamsBundle.identifiers)
            #expect(contents.records.count == 2)
            #expect(Set(contents.records.map(\.bundleIdentifier)) == ["com.microsoft.teams2", "com.microsoft.teams"])
            #expect(contents.appIdentifiers == ["com.microsoft.teams", "com.microsoft.teams2"])
            #expect(contents.records.allSatisfy { $0.uuid?.count == 16 && $0.recordID != nil })
            #expect(contents.records.map(\.deliveredDate).contains(t(2)))
            #expect(contents.badge == nil)
            #expect(contents.layout.has("record", "snooze_fire_date"))
        }
    }

    @Test func readsTheBadgeWhenThereIsOne() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("db")
            let db = try TestDatabase(at: url)
            defer { db.close() }
            try db.addApp("com.microsoft.teams2", badge: 3)
            #expect(try NotificationDatabase.load(at: url, bundleIdentifiers: TeamsBundle.identifiers).badge == 3)
        }
    }

    @Test func hasNoTeamsEntryBeforeTeamsPostsAnything() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("db")
            let db = try TestDatabase(at: url)
            defer { db.close() }
            try db.addApp("com.apple.Mail")
            let contents = try NotificationDatabase.load(at: url, bundleIdentifiers: TeamsBundle.identifiers)
            #expect(contents.appIdentifiers.isEmpty)
            #expect(contents.records.isEmpty)
        }
    }

    @Test func readsAlongsideTheWriter() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("db")
            let db = try TestDatabase(at: url)
            defer { db.close() }
            try db.add(Record.message(Chat.avery, title: "Avery Quinn", body: "Committed", at: t(0)), delivered: t(0))

            // Notification Center is mid-write: readers must neither wait for nor see the uncommitted row.
            try db.exec("BEGIN IMMEDIATE;")
            try db.add(Record.message(Chat.sam, title: "Sam Rivera", body: "Pending", at: t(1)), delivered: t(1))
            var during: DatabaseContents?
            let elapsed = try ContinuousClock().measure { during = try NotificationDatabase.load(at: url, bundleIdentifiers: TeamsBundle.identifiers) }
            #expect(during?.records.count == 1)
            #expect(elapsed < .seconds(1))

            try db.exec("COMMIT;")
            #expect(try NotificationDatabase.load(at: url, bundleIdentifiers: TeamsBundle.identifiers).records.count == 2)
        }
    }

    @Test func readsAWALDatabaseWhoseWriterClosedIt() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("db")
            let db = try TestDatabase(at: url)
            try db.add(Record.message(Chat.avery, title: "Avery Quinn", body: "Hi", at: t(0)), delivered: t(0))
            db.close()
            // SQLite removes the log and index when the last writer closes (Apple's build may leave an
            // empty log). Without them, a read-only connection can't open a WAL database normally.
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
            #expect(try NotificationDatabase.load(at: url, bundleIdentifiers: TeamsBundle.identifiers).records.count == 1)
        }
    }

    @Test func reportsAChangedLayoutInsteadOfGuessing() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("db")
            let db = try TestDatabase(at: url, schema: """
                CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR);
                CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, payload BLOB);
                """)
            defer { db.close() }
            #expect {
                try NotificationDatabase.load(at: url, bundleIdentifiers: TeamsBundle.identifiers)
            } throws: { error in
                guard case NotificationDatabaseError.layoutChanged(let missing, let layout) = error else { return false }
                return missing == ["record.data"] && layout.has("record", "payload")
            }
        }
    }

    @Test func doesWithoutOptionalColumns() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("db")
            let db = try TestDatabase(at: url, schema: """
                CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR);
                CREATE TABLE record (app_id INTEGER, data BLOB);
                """)
            defer { db.close() }
            try db.exec("INSERT INTO app (app_id, identifier) VALUES (1, 'com.microsoft.teams2');")
            let data = Record.message(Chat.avery, title: "Avery Quinn", body: "Hi", at: t(5))
            try db.exec("INSERT INTO record (app_id, data) VALUES (1, X'\(data.map { String(format: "%02x", $0) }.joined())');")

            let contents = try NotificationDatabase.load(at: url, bundleIdentifiers: TeamsBundle.identifiers)
            #expect(contents.records.count == 1)
            #expect(contents.records[0].deliveredDate == nil)
            // The plist's own date stands in for the missing column.
            let parsed = TeamsNotificationParser.parse(contents.records[0])
            #expect(parsed.item.message?.deliveredAt == t(5))
        }
    }

    @Test func checksAccessByOpeningTheFile() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("db")
            #expect(DatabaseAccess.check(url) == .missing)
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
            #expect(DatabaseAccess.check(url) == .granted)
            // Privacy protection fails the same way a permission does.
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            #expect(DatabaseAccess.check(url) == .denied)
        }
    }
}

@Suite struct NotificationPathsTests {
    private let home = URL(fileURLWithPath: "/Users/someone")

    @Test func usesNotificationCentersDatabaseByDefault() {
        let paths = NotificationPaths.default(environment: [:], home: home)
        #expect(paths.database.path == "/Users/someone/Library/Group Containers/group.com.apple.usernoted/db2/db")
        #expect(paths.stateDirectory.path == "/Users/someone/Library/Application Support/BriefBar/Teams")
        #expect(paths.isSystemDatabase)
    }

    @Test func keepsTheStateOfAnotherDatabaseNextToIt() {
        let paths = NotificationPaths.default(environment: ["BRIEFBAR_TEAMS_DB": "/tmp/demo/db2/db"], home: home)
        #expect(paths.database.path == "/tmp/demo/db2/db")
        #expect(paths.stateDirectory.path == "/tmp/demo/db2/state")
        #expect(!paths.isSystemDatabase)
    }

    @Test func recognizesTheSameFileByAnotherPath() throws {
        try withTemporaryDirectory { directory in
            let real = directory.appendingPathComponent("db2/db")
            try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: real.path, contents: Data())
            let link = directory.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.deletingLastPathComponent())
            #expect(NotificationPaths.isSameFile(link.appendingPathComponent("db"), real))
            #expect(NotificationPaths.isSameFile(directory.appendingPathComponent("DB2/db"), real))
            #expect(!NotificationPaths.isSameFile(directory.appendingPathComponent("db2/other"), real))
        }
    }

    @Test func treatsOverridesThatStillReadTheRealDatabaseAsReal() {
        let stateOnly = NotificationPaths.default(environment: ["BRIEFBAR_TEAMS_STATE_DIR": "/tmp/state"], home: home)
        #expect(stateOnly.isSystemDatabase)
        #expect(stateOnly.stateDirectory.path == "/tmp/state")
        let explicit = NotificationPaths.default(
            environment: ["BRIEFBAR_TEAMS_DB": "/Users/someone/Library/Group Containers/group.com.apple.usernoted/db2/./db"],
            home: home
        )
        #expect(explicit.isSystemDatabase)
        #expect(explicit.stateDirectory.path == "/Users/someone/Library/Application Support/BriefBar/Teams")
    }
}

@Suite struct RecordDecoderTests {
    @Test func decodesATeamsNotification() throws {
        let data = Record.message(Chat.avery, title: "Avery Quinn", body: "Lunch?", at: t(0), identifier: "id-1")
        let raw = try RecordDecoder.decode(StoredRecord(recordID: 7, data: data, deliveredDate: t(3))).get()
        #expect(raw.key == "id-1")
        #expect(raw.identifier == "id-1")
        #expect(raw.title == "Avery Quinn")
        #expect(raw.body == "Lunch?")
        #expect(raw.bundleIdentifier == "com.microsoft.teams2")
        #expect(raw.deliveredAt == t(3))
        #expect(raw.userInfoState == .decoded)
        #expect(raw.userInfo["default_id"] == Chat.avery)
        #expect(raw.userInfo["default_type"] == "chats")
        #expect(raw.userInfoKeys.contains("textInputsend_options"))
    }

    @Test func decodesARecordThatIsItselfAKeyedArchive() throws {
        let data = Record.data(title: "Sam Rivera", body: "Hi", identifier: "id-2",
                               userInfo: Record.chatInfo(Chat.sam, messageID: "1792317600000"), date: t(9), keyedArchive: true)
        let raw = try RecordDecoder.decode(StoredRecord(data: data)).get()
        #expect(raw.title == "Sam Rivera")
        #expect(raw.deliveredAt == t(9))
        #expect(raw.userInfo["default_id"] == Chat.sam)
    }

    @Test func keepsNumbersAndBooleansAsText() throws {
        let data = Record.data(title: "", body: "", userInfo: ["count": 3, "flag": true, "nested": ["a": 1]], date: t(0))
        let raw = try RecordDecoder.decode(StoredRecord(data: data)).get()
        #expect(raw.userInfo["count"] == "3")
        #expect(raw.userInfo["flag"] == "true")
        #expect(raw.userInfo["nested"] == nil)
        #expect(raw.userInfoKeys == ["count", "flag", "nested"])
    }

    @Test func refusesArchivedClassesOutsideThePlistTypes() throws {
        let archive = try NSKeyedArchiver.archivedData(
            withRootObject: ["link": NSURL(string: "https://example.com")!] as NSDictionary, requiringSecureCoding: true
        )
        let data = Record.data(title: "", body: "", userInfo: nil, date: t(0), usda: archive)
        let raw = try RecordDecoder.decode(StoredRecord(data: data)).get()
        #expect(raw.userInfoState == .unreadable)
    }

    @Test func reportsWhatItCouldNotDecode() throws {
        #expect(RecordDecoder.decode(StoredRecord(data: nil)) == .failure(.noData))
        #expect(RecordDecoder.decode(StoredRecord(data: Data("not a plist".utf8))) == .failure(.notPlist))
        let noRequest = try PropertyListSerialization.data(fromPropertyList: ["app": "x"], format: .binary, options: 0)
        #expect(RecordDecoder.decode(StoredRecord(data: noRequest)) == .failure(.noRequest))

        let noUserInfo = try RecordDecoder.decode(StoredRecord(data: Record.data(title: "t", body: "b", userInfo: nil, date: t(0)))).get()
        #expect(noUserInfo.userInfoState == .missing)
        let garbage = Record.data(title: "t", body: "b", userInfo: nil, date: t(0), usda: Data("garbage".utf8))
        #expect(try RecordDecoder.decode(StoredRecord(data: garbage)).get().userInfoState == .unreadable)
    }

    @Test func fallsBackToTheUUIDForItsKey() throws {
        let uuid = Data([0xab, 0xcd])
        let data = Record.data(title: "", body: "", identifier: "", userInfo: [:], date: t(0))
        #expect(try RecordDecoder.decode(StoredRecord(recordID: 3, uuid: uuid, data: data)).get().key == "abcd")
    }
}

@Suite struct TeamsNotificationParserTests {
    private func parse(_ data: Data, delivered: Date = t(0)) -> TeamsItem {
        TeamsNotificationParser.parse(StoredRecord(recordID: 1, data: data, deliveredDate: delivered)).item
    }

    @Test func readsA1To1Message() throws {
        let data = Record.message(Chat.avery, title: "Avery Quinn", body: "Are we still on for 3?", at: t(0),
                                  identifier: "n-1", messageID: "1792317600123")
        let message = try #require(parse(data).message)
        #expect(message == ChatMessage(
            conversationID: Chat.avery, kind: .oneOnOne, messageID: "1792317600123", notificationKey: "n-1",
            deliveredAt: t(0), chatName: "Avery Quinn", sender: "Avery Quinn", text: "Are we still on for 3?"
        ))
        #expect(message.key == "\(Chat.avery)/1792317600123")
    }

    @Test func splitsTheSenderOffGroupMessages() throws {
        let data = Record.message(Chat.launchCrew, title: "Launch crew & Ops / Design", body: "Jordan Lee: Shipping at 5: ok?", at: t(0))
        let message = try #require(parse(data).message)
        #expect(message.kind == .group)
        #expect(message.chatName == "Launch crew & Ops / Design")
        #expect(message.sender == "Jordan Lee")
        #expect(message.text == "Shipping at 5: ok?")
    }

    @Test func classifiesConversations() {
        #expect(ConversationKind(chatID: Chat.avery) == .oneOnOne)
        #expect(ConversationKind(chatID: Chat.launchCrew) == .group)
        #expect(ConversationKind(chatID: Chat.oldGroup) == .group)
        #expect(ConversationKind(chatID: Chat.weeklySync) == .meeting)
        #expect(ConversationKind.oneOnOne.chatGroup == .chats)
        #expect(ConversationKind.meeting.chatGroup == .groups)
        #expect(ConversationKind.channel.chatGroup == nil)
    }

    @Test func treatsMeetingChatsAsGroups() throws {
        let data = Record.message(Chat.weeklySync, title: "Weekly sync", body: "Sam Rivera: Notes are up", at: t(0))
        let message = try #require(parse(data).message)
        #expect(message.kind == .meeting)
        #expect(message.kind.chatGroup == .groups)
        #expect(message.sender == "Sam Rivera")
    }

    @Test func tellsReactionsFromMessagesByTheReplyBox() {
        let data = Record.reaction(Chat.avery, title: "👍 Avery Quinn reacted to your message", at: t(0))
        #expect(parse(data) == .chatActivity(conversationID: Chat.avery, kind: .oneOnOne))
    }

    @Test func recognizesChannelPosts() {
        let data = Record.channelPost(title: "Sam Rivera posted a new message", body: "Release notes", at: t(0))
        #expect(parse(data) == .channelPost(channelID: Chat.channel))
    }

    @Test func setsAsideOtherKindsOfNotification() {
        let call = Record.data(title: "Missed call", body: "", userInfo: ["default_type": "calls", "source": "tmpcore_work"], date: t(0))
        #expect(parse(call) == .otherNotification)
    }

    @Test func flagsChatsWhoseTypeWasRenamed() {
        // A Teams update renaming "chats" must show up as a format change, not as other notifications.
        var info = Record.chatInfo(Chat.avery, messageID: "1792317600000")
        info["default_type"] = "chat"
        #expect(parse(Record.data(title: "Avery Quinn", body: "Hi", userInfo: info, date: t(0))) == .unrecognized(.unknownChatType))
        var noReply = Record.chatInfo(Chat.launchCrew, messageID: "1792317600000", reply: false)
        noReply["default_type"] = "conversation"
        #expect(parse(Record.data(title: "Launch crew", body: "", userInfo: noReply, date: t(0))) == .unrecognized(.unknownChatType))
        let channelLike = ["default_type": "teamsActivity", "default_id": Chat.channel]
        #expect(parse(Record.data(title: "", body: "", userInfo: channelLike, date: t(0))) == .otherNotification)

        let renamed = (0..<5).map { index -> ParsedNotification in
            var info = Record.chatInfo(Chat.sam, messageID: messageID(t(Double(index))))
            info["default_type"] = "chat"
            return TeamsNotificationParser.parse(StoredRecord(data: Record.data(title: "Sam", body: "Hi", userInfo: info, date: t(0))))
        }
        #expect(FormatReport(renamed).verdict == .unrecognized(total: 5))
    }

    @Test func usesTheReplyBoxConversationWhenTheDefaultOneIsMissing() throws {
        var info = Record.chatInfo(Chat.sam, messageID: "1792317600000")
        info["default_id"] = "not an id"
        let message = try #require(parse(Record.data(title: "Sam Rivera", body: "Hi", userInfo: info, date: t(0))).message)
        #expect(message.conversationID == Chat.sam)
    }

    @Test func reportsWhatItDoesNotUnderstand() {
        var info = Record.chatInfo(Chat.sam, messageID: "1792317600000")
        info["default_id"] = "x"
        info["textInputsend_options"] = "{}"
        #expect(parse(Record.data(title: "", body: "", userInfo: info, date: t(0))) == .unrecognized(.invalidConversationID))

        #expect(parse(Record.data(title: "", body: "", userInfo: ["source": "tmpcore_work"], date: t(0))) == .unrecognized(.missingType))
        #expect(parse(Record.data(title: "", body: "", userInfo: nil, date: t(0))) == .unrecognized(.noUserInfo))
        #expect(parse(Data("junk".utf8)) == .unrecognized(.notPlist))
    }

    @Test func readsMessageIDsGivenAsTextOrMissing() throws {
        var info = Record.chatInfo(Chat.avery, messageID: nil)
        #expect(try #require(parse(Record.data(title: "A", body: "b", userInfo: info, date: t(0))).message).messageID == nil)
        info["default_options"] = Record.json(["messageId": "1792317600999"])
        #expect(try #require(parse(Record.data(title: "A", body: "b", userInfo: info, date: t(0))).message).messageID == "1792317600999")
        info["default_options"] = Record.json(["messageId": "12ab"])
        #expect(try #require(parse(Record.data(title: "A", body: "b", userInfo: info, date: t(0))).message).messageID == nil)
    }

    @Test(arguments: [
        ("Jordan Lee: hi", "Jordan Lee", "hi"),
        ("Ana: a: b", "Ana", "a: b"),
    ])
    func splitsSenders(_ body: String, _ sender: String, _ text: String) throws {
        let split = try #require(TeamsNotificationParser.splitSender(body))
        #expect(split.sender == sender)
        #expect(split.text == text)
    }

    @Test(arguments: ["no separator", ": starts with it", "line\nbreak: text", String(repeating: "x", count: 81) + ": text"])
    func leavesBodiesWithoutASenderWhole(_ body: String) {
        #expect(TeamsNotificationParser.splitSender(body) == nil)
    }
}

@Suite struct DeepLinkTests {
    @Test func linksToAMessageInAChat() {
        let url = DeepLink.message(conversationID: Chat.launchCrew, messageID: "1792317600123")
        #expect(url?.absoluteString
            == "msteams:/l/message/19%3A0123456789abcdef0123456789abcdef%40thread.v2/1792317600123?context=%7B%22contextType%22%3A%22chat%22%7D")
    }

    @Test func linksToAChatWithoutAMessage() {
        #expect(DeepLink.chat(conversationID: Chat.avery)?.absoluteString.hasPrefix("msteams:/l/chat/19%3A11111111-aaaa") == true)
        let message = ChatMessage(conversationID: Chat.avery, kind: .oneOnOne, messageID: nil, notificationKey: "n",
                                  deliveredAt: t(0), chatName: "Avery Quinn", sender: nil, text: "")
        #expect(DeepLink.link(to: message) == DeepLink.chat(conversationID: Chat.avery))
    }

    @Test func refusesWhatIsNotAnIDOrAMessageNumber() {
        #expect(DeepLink.message(conversationID: "19:x@thread.v2/../evil", messageID: "1") == nil)
        #expect(DeepLink.message(conversationID: Chat.avery, messageID: "12a") == nil)
        #expect(DeepLink.chat(conversationID: "https://example.com") == nil)
    }
}
