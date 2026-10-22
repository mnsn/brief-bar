import BriefBarCore
import ChromiumIndexedDB
import Foundation
import NotificationCenterDB

/// How far you've read a chat in Teams itself, as Teams keeps it: the newest message you've seen there.
public struct ReadMarker: Sendable, Equatable, Hashable {
    /// Teams' ID of the newest message read: when it arrived, in milliseconds since 1970.
    public var messageID: Int64
    /// When it was read, if Teams says.
    public var readAt: Date?

    public init(messageID: Int64, readAt: Date? = nil) {
        self.messageID = messageID
        self.readAt = readAt
    }

    /// Teams' `consumptionhorizon`: `<message ID>;<when it was read, in ms>;<client message ID>`. Nil for a chat never
    /// read (`0;0;0`), or without one (empty).
    public init?(consumptionHorizon text: String) {
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard let first = parts.first, first.allSatisfy(\.isASCIIDigit), let id = Int64(first), id > 0 else { return nil }
        messageID = id
        readAt = parts.dropFirst().first.flatMap { Int64($0) }.flatMap { $0 > 0 ? Date(milliseconds: $0) : nil }
    }

    /// When the newest message read arrived.
    public var messageDate: Date { Date(milliseconds: messageID) }

    /// Whether `message` is one of those read: by its ID, or without one, by when it was delivered.
    public func covers(_ message: ChatMessage) -> Bool {
        if let id = message.messageID.flatMap(Int64.init) {
            return id <= messageID
        }
        return message.deliveredAt <= messageDate
    }
}

extension Date {
    init(milliseconds: Int64) {
        self.init(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

/// Where Teams keeps its web app's data: a folder per WebView profile (`WV2Profile_tfw` for work and school accounts),
/// each with Chromium's `IndexedDB` folder, where the Teams site's databases keep how far you've read each chat.
public struct TeamsCacheLocation: Sendable, Equatable {
    public var root: URL
    /// Whether it's Teams' own, rather than one `BRIEFBAR_TEAMS_CACHE` names, such as made-up data.
    public var isTeamsOwn: Bool

    /// Points BriefBar at other data than Teams', laid out the same way.
    public static let variable = "BRIEFBAR_TEAMS_CACHE"

    public init(root: URL, isTeamsOwn: Bool) {
        self.root = root
        self.isTeamsOwn = isTeamsOwn
    }

    /// New Teams' (`com.microsoft.teams2`), in its container, which macOS protects: reading it needs Full Disk Access.
    public static func teams(home: URL = UserHome.url) -> TeamsCacheLocation {
        TeamsCacheLocation(
            root: home.appendingPathComponent(
                "Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/EBWebView",
                isDirectory: true
            ),
            isTeamsOwn: true
        )
    }

    /// What `BRIEFBAR_TEAMS_CACHE` names, only while BriefBar has the permissions of the app that started it
    /// (`Attribution.environment`).
    public static func override(environment: [String: String] = Attribution.environment) -> TeamsCacheLocation? {
        guard let path = environment[variable], !path.isEmpty else { return nil }
        return TeamsCacheLocation(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true),
                                  isTeamsOwn: false)
    }

    public func access() -> AccessStatus {
        DatabaseAccess.check(root)
    }

    /// The Teams site's IndexedDB folders: `<profile>/IndexedDB/https_teams.<domain>_0.indexeddb.leveldb`.
    public func folders() -> [URL] {
        let files = FileManager.default
        guard let profiles = try? files.contentsOfDirectory(atPath: root.path) else { return [] }
        return profiles.sorted().flatMap { profile -> [URL] in
            let indexedDB = root.appendingPathComponent(profile, isDirectory: true).appendingPathComponent("IndexedDB", isDirectory: true)
            let names = (try? files.contentsOfDirectory(atPath: indexedDB.path)) ?? []
            return names.sorted().filter(Self.isTeamsFolder).map { indexedDB.appendingPathComponent($0, isDirectory: true) }
        }
    }

    static func isTeamsFolder(_ name: String) -> Bool {
        name.wholeMatch(of: /https?_teams\.[A-Za-z0-9.\-]+_[0-9]+\.indexeddb\.leveldb/) != nil
    }
}

/// How much of Teams' data BriefBar could read: counts and formats, never names, messages or IDs.
public struct ReadMarkerReport: Sendable, Equatable {
    /// The Teams site's IndexedDB folders.
    public var folders = 0
    /// Their databases with conversations (`Teams:conversation-manager:…`, object store `conversations`).
    public var stores = 0
    /// Conversations: chats, channels and Teams' own threads.
    public var conversations = 0
    /// Chats with a read marker.
    public var withMarker = 0
    /// Values read, by format.
    public var formats: [String: Int] = [:]
    /// Values that couldn't be read, by why.
    public var unreadable: [String: Int] = [:]
    public var unreadableFiles = 0
    public var corruptLogRecords = 0
    public var blocksRead = 0
    public var blocksSkipped = 0

    public init() {}

    public var unreadableCount: Int { unreadable.values.reduce(0, +) }

    /// Teams' data was found but not understood, as after an update that changed it. Nothing found says nothing:
    /// Teams may not be signed in.
    public var problem: PulseProblem? {
        let total = conversations + unreadableCount
        if folders > 0, stores == 0 { return .readMarkersChanged }
        if total > 0, withMarker == 0 { return .readMarkersChanged }
        if unreadableCount * 4 > total || unreadableFiles > 0 { return .readMarkersPartlyUnreadable }
        return nil
    }

    mutating func add(_ other: ReadMarkerReport) {
        folders += other.folders
        stores += other.stores
        conversations += other.conversations
        withMarker += other.withMarker
        formats.merge(other.formats, uniquingKeysWith: +)
        unreadable.merge(other.unreadable, uniquingKeysWith: +)
        unreadableFiles += other.unreadableFiles
        corruptLogRecords += other.corruptLogRecords
        blocksRead += other.blocksRead
        blocksSkipped += other.blocksSkipped
    }
}

/// One of Teams' IndexedDB folders as BriefBar read it: which object stores hold conversations, each conversation's
/// read marker, and where reading the log stopped, to read on from there.
struct TeamsCacheFolder {
    /// A conversation record, as read.
    struct Conversation: Equatable {
        var id: String?
        var marker: ReadMarker?
        var format: String?
        var unreadable: String?
    }

    let folder: IndexedDBFolder
    private(set) var catalog = IndexedDBFolder.Catalog()
    private(set) var stores: Set<IndexedDBFolder.StoreID> = []
    private(set) var conversations: [IndexedDBFolder.RecordKey: Conversation] = [:]
    private var externalObjects: [IndexedDBFolder.RecordKey: [ExternalObject]] = [:]
    /// The raw values of records in a blob file: Chromium writes their blob entry after them, often in a later batch,
    /// so they're read again when it arrives.
    private var inBlobFiles: [IndexedDBFolder.RecordKey: [UInt8]] = [:]
    private(set) var log: LevelDBFolder.LogPosition?
    /// Tables that couldn't be read, as they were then. LevelDB writes a table where it'll stay, so one being written
    /// reads as broken until it's done.
    private(set) var unreadableTables: [String: FileInfo] = [:]
    private var files = (corruptLogRecords: 0, blocksRead: 0, blocksSkipped: 0)

    init(_ url: URL) {
        folder = IndexedDBFolder(url: url)
    }

    static func isConversations(database: String, objectStore: String) -> Bool {
        database.hasPrefix("Teams:conversation-manager:") && objectStore == "conversations"
    }

    /// Reads the folder: its catalog, then only its conversations.
    mutating func scan() throws {
        let (catalog, catalogRead) = try folder.catalog()
        self.catalog = catalog
        stores = catalog.stores(where: Self.isConversations)
        let records = try folder.records(in: stores)
        externalObjects = records.externalObjects
        inBlobFiles = records.values.filter { IndexedDBFolder.isInBlobFile($0.value) }
        conversations = [:]
        for (key, raw) in records.values {
            conversations[key] = read(raw, key: key)
        }
        log = records.read.log ?? catalogRead.log
        unreadableTables = [:]
        for name in Set(catalogRead.unreadable.keys).union(records.read.unreadable.keys) {
            unreadableTables[name] = FileInfo(path: folder.url.appendingPathComponent(name).path)
        }
        files = (
            corruptLogRecords: records.read.corruptLogRecords,
            blocksRead: catalogRead.blocksRead + records.read.blocksRead,
            blocksSkipped: catalogRead.blocksSkipped + records.read.blocksSkipped
        )
    }

    enum LogRead: Equatable {
        /// Nothing new about conversations.
        case unchanged
        case changed
        /// The log was replaced, or databases or object stores changed: scan the folder again.
        case rescan
    }

    /// Reads what LevelDB appended to the log since the last read.
    mutating func readLog() -> LogRead {
        guard let log else { return .rescan }
        let newest = Self.newestLog(in: folder.url)
        guard newest == log.url.lastPathComponent else { return .rescan }
        let bytes: [UInt8]
        do {
            let (read, file) = try LevelDBFolder.contents(of: log.url, from: log.offset)
            guard file == log.file else { return .rescan }
            bytes = read
        } catch {
            return .rescan
        }
        guard !bytes.isEmpty else { return .unchanged }
        let stores = stores
        let parsed = LevelDBLog.parse(bytes, fileOffset: log.offset) { key in
            guard let prefix = KeyPrefix(key) else { return false }
            return IndexedDBFolder.isMetadata(key)
                || stores.contains(IndexedDBFolder.StoreID(database: prefix.database, objectStore: prefix.objectStore))
        }
        self.log?.offset = parsed.end
        files.corruptLogRecords += parsed.corrupt
        var catalog = catalog
        var records: [(IndexedDBFolder.RecordKey, [UInt8]?)] = []
        var newBlobEntries: Set<IndexedDBFolder.RecordKey> = []
        for entry in parsed.entries {
            guard let key = try? IndexedDBKey(entry.key) else { continue }
            switch key {
            case .databaseName, .objectStoreName:
                if catalog.take(key, value: entry.value) { return .rescan }
            case .record(let database, let objectStore, let id):
                records.append((IndexedDBFolder.RecordKey(store: .init(database: database, objectStore: objectStore), key: id),
                                entry.value))
            case .blobEntry(let database, let objectStore, let id):
                let record = IndexedDBFolder.RecordKey(store: .init(database: database, objectStore: objectStore), key: id)
                externalObjects[record] = entry.value.flatMap { try? IndexedDBKey.externalObjects($0) }
                newBlobEntries.insert(record)
            case .otherMetadata, .other:
                break
            }
        }
        // Each record as it is now, with its blob entry as it is now: those come later than their record.
        var changed = false
        func take(_ record: IndexedDBFolder.RecordKey, _ raw: [UInt8]?) {
            inBlobFiles[record] = raw.flatMap { IndexedDBFolder.isInBlobFile($0) ? $0 : nil }
            let conversation = raw.map { read($0, key: record) }
            if conversations[record] != conversation {
                conversations[record] = conversation
                changed = true
            }
        }
        for (record, raw) in records {
            take(record, raw)
            newBlobEntries.remove(record)
        }
        for record in newBlobEntries {
            if let raw = inBlobFiles[record] {
                take(record, raw)
            }
        }
        return changed ? .changed : .unchanged
    }

    /// Each chat's read marker, by conversation ID.
    var markers: [String: ReadMarker] {
        var markers: [String: ReadMarker] = [:]
        for conversation in conversations.values {
            guard let id = conversation.id, let marker = conversation.marker else { continue }
            markers[id] = markers[id].map { $0.messageID >= marker.messageID ? $0 : marker } ?? marker
        }
        return markers
    }

    var report: ReadMarkerReport {
        var report = ReadMarkerReport()
        report.folders = 1
        report.stores = stores.count
        for conversation in conversations.values {
            if let reason = conversation.unreadable {
                report.unreadable[reason, default: 0] += 1
                continue
            }
            report.conversations += 1
            if conversation.marker != nil, conversation.id.map(Self.isChat) == true {
                report.withMarker += 1
            }
            if let format = conversation.format {
                report.formats[format, default: 0] += 1
            }
        }
        report.unreadableFiles = unreadableTables.count
        report.corruptLogRecords = files.corruptLogRecords
        report.blocksRead = files.blocksRead
        report.blocksSkipped = files.blocksSkipped
        return report
    }

    static func isChat(_ id: String) -> Bool {
        ConversationID.isValid(id) && !id.lowercased().hasSuffix("@thread.tacv2")
    }

    /// The conversation a record holds: Teams' `conversations` records are keyed by their `id`, and keep how far
    /// they were read in `properties.consumptionhorizon`.
    private func read(_ raw: [UInt8], key: IndexedDBFolder.RecordKey) -> Conversation {
        do {
            let value = try folder.value(of: raw, key: key, externalObjects: externalObjects[key])
            let id = value.value["id"]?.string ?? key.key.string
            let marker = value.value["properties"]?["consumptionhorizon"]?.string.flatMap(ReadMarker.init(consumptionHorizon:))
            let format = value.format.description + (value.fromBlobFile ? ", from a blob file" : "")
            return Conversation(id: id.flatMap { ConversationID.isValid($0) ? $0 : nil }, marker: marker, format: format)
        } catch let error as FormatError {
            return Conversation(unreadable: error.description)
        } catch {
            return Conversation(unreadable: "blob file unreadable")
        }
    }

    /// The log LevelDB writes to now: the one with the highest number.
    static func newestLog(in folder: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> (UInt64, String)? in
            guard name.hasSuffix(".log"), let number = UInt64(name.dropLast(4)) else { return nil }
            return (number, name)
        }.max { $0.0 < $1.0 }?.1
    }
}
