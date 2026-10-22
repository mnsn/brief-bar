import Foundation
import Synchronization
import Testing
@testable import TeamsCore
import BriefBarCore
import NotificationCenterDB

// MARK: - Teams' data, made up

/// The IndexedDB that Microsoft Edge wrote with made-up data shaped like Teams' (Tests/Fixtures/ChromiumIndexedDB): the
/// first run wrote every conversation, the second read Avery's chat, added a message to Sam's and deleted the channel.
enum TeamsData {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ChromiumIndexedDB/IndexedDB", isDirectory: true)
    static let folderName = "http_teams.localhost_8766.indexeddb.leveldb"
    static let logName = "000003.log"
    /// Where the second run's writes start in the log.
    static let firstRunLength = 39_357
    /// 2026-10-18T10:00:00Z in milliseconds, which the made-up message IDs count from.
    static let base: Int64 = 1_792_317_600_000
    static let big = "19:bigbigbigbigbigbigbigbigbigbig12@thread.v2"
    static let wrapped = "19:wrapwrapwrapwrapwrapwrapwrapwrap@thread.v2"

    /// A copy laid out as Teams keeps its own (`EBWebView/WV2Profile_tfw/IndexedDB`), with only the first `logLength`
    /// bytes of the log if given. Returns where it is, and its log.
    static func copy(to directory: URL, logLength: Int? = nil) throws -> (TeamsCacheLocation, log: URL) {
        let root = directory.appendingPathComponent("EBWebView", isDirectory: true)
        let indexedDB = root.appendingPathComponent("WV2Profile_tfw/IndexedDB", isDirectory: true)
        try FileManager.default.createDirectory(at: indexedDB, withIntermediateDirectories: true)
        for name in [folderName, "http_teams.localhost_8766.indexeddb.blob"] {
            try FileManager.default.copyItem(at: fixture.appendingPathComponent(name), to: indexedDB.appendingPathComponent(name))
        }
        let log = indexedDB.appendingPathComponent(folderName).appendingPathComponent(logName)
        if let logLength {
            let bytes = try Data(contentsOf: log)
            try bytes.prefix(logLength).write(to: log)
        }
        return (TeamsCacheLocation(root: root, isTeamsOwn: false), log)
    }

    /// The log's bytes after the first run's.
    static func secondRun() throws -> Data {
        try Data(contentsOf: fixture.appendingPathComponent(folderName).appendingPathComponent(logName)).dropFirst(firstRunLength)
    }
}

func append(_ data: Data, to url: URL) throws {
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.seekToEnd()
    try file.write(contentsOf: data)
}

/// Collects the engine's publications (made on its queue) for async assertions.
final class MarkerCollector: Sendable {
    private let snapshots = Mutex<[ReadMarkerSnapshot]>([])

    func add(_ snapshot: ReadMarkerSnapshot) {
        snapshots.withLock { $0.append(snapshot) }
    }

    var latest: ReadMarkerSnapshot? {
        snapshots.withLock { $0.last }
    }

    @discardableResult
    func wait(_ what: String, timeout: Duration = .seconds(10), until predicate: (ReadMarkerSnapshot) -> Bool) async throws
        -> ReadMarkerSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let latest, predicate(latest) {
                return latest
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestError("Timed out waiting for \(what)")
    }
}

// MARK: - Tests

@Suite struct ReadMarkerTests {
    @Test func readsTeamsConsumptionHorizon() {
        let marker = ReadMarker(consumptionHorizon: "1792317605000;1792317605900;1792317605007")
        #expect(marker?.messageID == 1_792_317_605_000)
        #expect(marker?.readAt == Date(timeIntervalSince1970: 1_792_317_605.9))
        #expect(ReadMarker(consumptionHorizon: "1792317605000")?.readAt == nil)
        for never in ["0;0;0", "", "0;900;7", "-5;1;1", "abc;1;1", ";1792317605000;1"] {
            #expect(ReadMarker(consumptionHorizon: never) == nil, "\(never)")
        }
    }

    @Test func coversMessagesByIDOrElseByWhenTheyArrived() {
        let marker = ReadMarker(messageID: Int64(messageID(t(20)))!)
        func message(_ id: String?, at date: Date) -> ChatMessage {
            ChatMessage(conversationID: Chat.avery, kind: .oneOnOne, messageID: id, notificationKey: "n", deliveredAt: date,
                        chatName: "Avery Quinn", sender: nil, text: "Made-up")
        }
        #expect(marker.covers(message(messageID(t(20)), at: t(21))))
        #expect(!marker.covers(message(messageID(t(21)), at: t(21))))
        #expect(marker.covers(message(nil, at: t(19))))
        #expect(!marker.covers(message(nil, at: t(21))))
    }

    @Test func findsTeamsFoldersOnly() throws {
        try withTemporaryDirectory { directory in
            let root = directory.appendingPathComponent("EBWebView", isDirectory: true)
            for path in [
                "WV2Profile_tfw/IndexedDB/https_teams.microsoft.com_0.indexeddb.leveldb",
                "WV2Profile_tfw/IndexedDB/https_teams.cloud.microsoft_0.indexeddb.leveldb",
                "WV2Profile_tfw/IndexedDB/https_teams.microsoft.com_0.indexeddb.blob",
                "WV2Profile_tfw/IndexedDB/https_outlook.office.com_0.indexeddb.leveldb",
                "WV2Profile_tfl/IndexedDB/https_teams.live.com_0.indexeddb.leveldb",
                "Crashpad",
            ] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            let location = TeamsCacheLocation(root: root, isTeamsOwn: false)
            #expect(location.folders().map { $0.pathComponents.suffix(3).joined(separator: "/") } == [
                "WV2Profile_tfl/IndexedDB/https_teams.live.com_0.indexeddb.leveldb",
                "WV2Profile_tfw/IndexedDB/https_teams.cloud.microsoft_0.indexeddb.leveldb",
                "WV2Profile_tfw/IndexedDB/https_teams.microsoft.com_0.indexeddb.leveldb",
            ])
            #expect(location.access() == .granted)
            #expect(TeamsCacheLocation(root: directory.appendingPathComponent("nowhere"), isTeamsOwn: false).access() == .missing)
        }
    }

    @Test func isTeamsOwnUnlessAVariableSaysOtherwise() {
        let home = URL(fileURLWithPath: "/Users/made-up", isDirectory: true)
        let teams = TeamsCacheLocation.teams(home: home)
        #expect(teams.isTeamsOwn)
        #expect(teams.root.path
            == "/Users/made-up/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/EBWebView")
        #expect(TeamsCacheLocation.override(environment: [:]) == nil)
        #expect(TeamsCacheLocation.override(environment: [TeamsCacheLocation.variable: ""]) == nil)
        let other = TeamsCacheLocation.override(environment: [TeamsCacheLocation.variable: "/tmp/made-up/EBWebView"])
        #expect(other == TeamsCacheLocation(root: URL(fileURLWithPath: "/tmp/made-up/EBWebView", isDirectory: true), isTeamsOwn: false))
    }

    @Test func readsEachChatsMarker() throws {
        try withTemporaryDirectory { directory in
            let (location, _) = try TeamsData.copy(to: directory)
            let snapshot = ReadMarkerEngine.loadOnce(location: location)
            #expect(snapshot.access == .granted)
            // The channel was deleted, the meeting chat was never opened, and Teams' own notes have no chat ID.
            #expect(snapshot.markers == [
                Chat.avery: ReadMarker(messageID: TeamsData.base + 5000, readAt: Date(milliseconds: TeamsData.base + 5900)),
                Chat.sam: ReadMarker(messageID: TeamsData.base + 7000, readAt: Date(milliseconds: TeamsData.base + 7900)),
                Chat.launchCrew: ReadMarker(messageID: TeamsData.base + 2000, readAt: Date(milliseconds: TeamsData.base + 2900)),
                TeamsData.big: ReadMarker(messageID: TeamsData.base + 100, readAt: Date(milliseconds: TeamsData.base + 1000)),
                TeamsData.wrapped: ReadMarker(messageID: TeamsData.base + 300, readAt: Date(milliseconds: TeamsData.base + 1200)),
            ])
            let report = snapshot.report
            #expect(report.folders == 1 && report.stores == 1)
            #expect(report.conversations == 7 && report.withMarker == 5)
            #expect(report.formats == [
                "Blink 21, V8 16": 5, "Blink 21, V8 16, compressed": 1, "Blink 21, V8 16, from a blob file": 1,
            ])
            #expect(report.unreadable.isEmpty && report.unreadableFiles == 0)
            #expect(snapshot.problem == nil)
        }
    }

    @Test func hasNothingToSayWithoutTeamsData() throws {
        try withTemporaryDirectory { directory in
            let snapshot = ReadMarkerEngine.loadOnce(location: TeamsCacheLocation(root: directory.appendingPathComponent("EBWebView"),
                                                                                  isTeamsOwn: false))
            #expect(snapshot.access == .missing)
            #expect(snapshot.markers.isEmpty)
            #expect(snapshot.problem == nil)
        }
    }

    @Test func saysWhenTeamsDataCantBeUnderstood() {
        var report = ReadMarkerReport()
        #expect(report.problem == nil)
        report.folders = 1
        #expect(report.problem == .readMarkersChanged)
        report.stores = 1
        report.conversations = 10
        #expect(report.problem == .readMarkersChanged)
        report.withMarker = 8
        #expect(report.problem == nil)
        report.unreadable = ["corrupt property count": 1]
        #expect(report.problem == nil)
        report.unreadable = ["unsupported V8 tag 92": 4]
        #expect(report.problem == .readMarkersPartlyUnreadable)
        #expect(ReadMarkerSnapshot(access: .denied, report: report).problem == nil)
        #expect(PulseProblem.readMarkersChanged.isBlocking == false)
    }

    @Test func followsTheLogAsTeamsWritesIt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (location, log) = try TeamsData.copy(to: directory, logLength: TeamsData.firstRunLength)
        let collector = MarkerCollector()
        let engine = ReadMarkerEngine(location: location, reloadDelay: 0.05) { collector.add($0) }
        engine.start()
        defer { engine.stop() }
        try await collector.wait("the first read") { $0.markers[Chat.avery]?.messageID == TeamsData.base + 1000 }

        // Half a record: LevelDB is still writing it.
        let second = try TeamsData.secondRun()
        try append(second.prefix(100), to: log)
        try await Task.sleep(for: .milliseconds(400))
        #expect(collector.latest?.markers[Chat.avery]?.messageID == TeamsData.base + 1000)

        try append(second.dropFirst(100), to: log)
        let read = try await collector.wait("Avery's chat read in Teams") { $0.markers[Chat.avery]?.messageID == TeamsData.base + 5000 }
        #expect(read.markers[Chat.sam]?.messageID == TeamsData.base + 7000)
        #expect(read.report.conversations == 7)
    }

    @Test func followsANewLog() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (location, log) = try TeamsData.copy(to: directory)
        let collector = MarkerCollector()
        let engine = ReadMarkerEngine(location: location, reloadDelay: 0.05) { collector.add($0) }
        engine.start()
        defer { engine.stop() }
        try await collector.wait("the first read") { $0.markers[Chat.avery]?.messageID == TeamsData.base + 5000 }

        // LevelDB starts a new log, and drops the old one: here, one with only the first run's writes.
        let newLog = log.deletingLastPathComponent().appendingPathComponent("000009.log")
        let firstRun = try Data(contentsOf: log).prefix(TeamsData.firstRunLength)
        try FileManager.default.removeItem(at: log)
        try firstRun.write(to: newLog)
        try await collector.wait("the new log") { $0.markers[Chat.avery]?.messageID == TeamsData.base + 1000 }

        try append(try TeamsData.secondRun(), to: newLog)
        try await collector.wait("more written to it") { $0.markers[Chat.avery]?.messageID == TeamsData.base + 5000 }
    }

    @Test func describesTeamsDataWithoutIDs() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (location, _) = try TeamsData.copy(to: directory)
        let paths = paths(in: directory)
        let db = try TestDatabase(at: paths.database)
        defer { db.close() }
        // Avery's newest message was read in Teams; Sam's wasn't; Jordan's chat isn't in Teams' data.
        let jordan = "19:44444444-dddd-4ddd-8ddd-444444444444_99999999-ffff-4fff-8fff-999999999999@unq.gbl.spaces"
        for (chat, id) in [(Chat.avery, TeamsData.base + 5000), (Chat.sam, TeamsData.base + 8000), (jordan, TeamsData.base + 9000)] {
            let date = Date(milliseconds: id).addingTimeInterval(1)
            try db.add(Record.message(chat, title: "Made-up Name", body: "Made-up", at: date, messageID: String(id)), delivered: date)
        }
        let report = await Diagnostics.report(paths: paths, cache: location, followsReadsInTeams: true, appVersion: "0.1.0")
        #expect(report.contains("Teams' read markers: overridden by BRIEFBAR_TEAMS_CACHE, access granted"))
        #expect(report.contains("Folders: WV2Profile_tfw/http_teams.localhost_8766.indexeddb.leveldb"))
        #expect(report.contains("Conversation stores: 1, conversations: 7, chats with a read marker: 5"))
        #expect(report.contains("1 x Blink 21, V8 16, from a blob file"))
        #expect(report.contains("Verdict: OK"))
        #expect(report.contains("Chats in Notification Center: 3, with a read marker: 2, read in Teams up to their newest notification: 1"))
        for secret in ["11111111-aaaa", "0123456789abcdef", "meeting_", "bigbig", "wrapwrap", "1792317605000", "Made-up",
                       "99999999-ffff", "00000000-1111", "44444444"] {
            #expect(!report.contains(secret), "The report contains \(secret)")
        }
        let off = await Diagnostics.report(paths: paths, cache: location, followsReadsInTeams: false,
                                           appVersion: "0.1.0")
        #expect(off.contains("Teams' read markers: not read (Mark Chats Read When You Read Them in Teams is off)"))
    }
}
