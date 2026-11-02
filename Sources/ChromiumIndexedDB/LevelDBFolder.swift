import BriefBarCore
import Foundation

/// A LevelDB database's folder, read as it is, without taking its lock: LevelDB never changes a table once written and
/// only appends to its log, so taking, for each key, the write with the highest sequence number gives the database as
/// it was when the read ended. Only the tables and logs its MANIFEST lists are read (`LevelDBManifest`). Nothing is
/// written, and nothing copied.
public struct LevelDBFolder: Sendable {
    /// How many times a read starts over when files vanish as it reads them.
    private static let attempts = 3

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Where reading the newest log stopped, to go on from there as LevelDB appends to it.
    public struct LogPosition: Sendable, Equatable {
        public var url: URL
        public var file: FileInfo.ID
        public var offset: Int
    }

    public struct Read: Sendable {
        /// The newest write to each key read: a value, or nil once the key was deleted.
        public var latest: [[UInt8]: LevelDBEntry] = [:]
        public var tables = 0
        public var logs = 0
        public var blocksRead = 0
        public var blocksSkipped = 0
        public var corruptLogRecords = 0
        /// Tables and logs left unread because the MANIFEST doesn't list them: ones LevelDB no longer needs and hasn't
        /// removed yet, or a table it's still writing.
        public var unlisted = 0
        /// Files that couldn't be read, by name, and why.
        public var unreadable: [String: FormatError] = [:]
        public var log: LogPosition?

        /// The keys that have a value, with it.
        public var values: [[UInt8]: [UInt8]] {
            latest.compactMapValues(\.value)
        }

        mutating func take(_ entries: [LevelDBEntry]) {
            for entry in entries where (latest[entry.key]?.sequence).map({ entry.sequence >= $0 }) ?? true {
                latest[entry.key] = entry
            }
        }
    }

    /// Reads the folder's tables and logs, keeping the writes to keys that `keep` accepts, from the table blocks that
    /// `mayHold` doesn't rule out (see `LevelDBTable.read`). A table that compaction removes while it's read, or adds,
    /// makes it start over, since its keys are in another table then, up to three times. Where there's no CURRENT, as
    /// in made-up data, it reads every table and log; so it does when the MANIFEST can't be read, or LevelDB would
    /// refuse it, which it says: as when, at the last attempt, CURRENT still names a MANIFEST that isn't there, or the
    /// MANIFEST a table that isn't.
    public func read(
        mayHold: ([UInt8]?, [UInt8]) -> Bool = { _, _ in true },
        keep: (ArraySlice<UInt8>) -> Bool = { _ in true }
    ) throws -> Read {
        var read = Read()
        for attemptNumber in 1...Self.attempts {
            var vanished = false
            (read, vanished) = try attempt(mayHold: mayHold, keep: keep, isLastAttempt: attemptNumber == Self.attempts)
            if !vanished { break }
        }
        return read
    }

    private func attempt(
        mayHold: ([UInt8]?, [UInt8]) -> Bool, keep: (ArraySlice<UInt8>) -> Bool, isLastAttempt: Bool
    ) throws -> (Read, vanished: Bool) {
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        var read = Read()
        let manifest = manifestVersion(names, read: &read, isLastAttempt: isLastAttempt)
        var vanished = manifest.vanished
        var tables: [String: LevelDBTable.Read] = [:]
        func readTable(_ name: String, skipping: Bool) {
            do {
                tables[name] = try LevelDBTable.read(
                    url.appendingPathComponent(name), mayHold: { lower, upper in !skipping || mayHold(lower, upper) }, keep: keep
                )
            } catch let error as FormatError {
                read.unreadable[name] = error
            } catch where Self.isGone(error) {
                vanished = true
            } catch {
                read.unreadable[name] = .unsupported("file")
            }
        }
        var tableNames = names.sorted().filter(Self.isTable)
        var logs = names.compactMap { name -> (number: UInt64, name: String)? in
            guard name.hasSuffix(".log"), let number = Self.number(name) else { return nil }
            return (number, name)
        }.sorted { $0.number < $1.number }
        if let version = manifest.version {
            let liveTables = tableNames.filter { name in Self.number(name).map { version.tables.contains($0) } == true }
            let liveLogs = logs.filter { version.isLiveLog($0.number) }
            read.unlisted = tableNames.count - liveTables.count + logs.count - liveLogs.count
            (tableNames, logs) = (liveTables, liveLogs)
        }
        for name in tableNames {
            readTable(name, skipping: true)
        }
        // Skipping blocks relies on index keys being the blocks' last keys. Where one isn't, read every block.
        if tables.values.contains(where: { $0.separatorsExact == false }) {
            for (name, table) in tables where table.blocksSkipped > 0 {
                readTable(name, skipping: false)
            }
        }
        for table in tables.values {
            read.tables += 1
            read.blocksRead += table.blocksRead
            read.blocksSkipped += table.blocksSkipped
            read.take(table.entries)
        }
        for (position, log) in logs.enumerated() {
            let fileURL = url.appendingPathComponent(log.name)
            do {
                let (bytes, file) = try Self.contents(of: fileURL)
                let parsed = LevelDBLog.parse(bytes, keep: keep)
                read.logs += 1
                read.corruptLogRecords += parsed.corrupt
                read.take(parsed.entries)
                if position == logs.count - 1 {
                    read.log = LogPosition(url: fileURL, file: file, offset: parsed.end)
                }
            } catch where Self.isGone(error) {
                vanished = true
            } catch {
                read.unreadable[log.name] = .unsupported("file")
            }
        }
        return (read, vanished)
    }

    /// What the folder's MANIFEST says the database is, and whether files vanished as it was read: the MANIFEST that
    /// CURRENT names, as when LevelDB replaced it, or a table it lists that the folder didn't have as it was listed, as
    /// when LevelDB wrote one since. Nil, to read every table and log, when the folder has no CURRENT, or when the
    /// MANIFEST can't be read or LevelDB would refuse it, which `read` says: as when, at the last attempt, either is
    /// still missing, since LevelDB refuses a database with files missing.
    private func manifestVersion(
        _ names: [String], read: inout Read, isLastAttempt: Bool
    ) -> (version: LevelDBManifest.Version?, vanished: Bool) {
        guard names.contains(LevelDBManifest.currentFile) else { return (nil, false) }
        var file = LevelDBManifest.currentFile
        do {
            let (current, _) = try Self.contents(of: url.appendingPathComponent(file))
            file = try LevelDBManifest.name(current: current)
            let (manifest, _) = try Self.contents(of: url.appendingPathComponent(file))
            let version = try LevelDBManifest.parse(manifest)
            let tables = names.filter(Self.isTable).compactMap(Self.number)
            if version.tables.isSubset(of: tables) { return (version, false) }
            if !isLastAttempt { return (version, true) }
            read.unreadable[file] = .corrupt("manifest")
        } catch let error as FormatError {
            read.unreadable[file] = error
        } catch where Self.isGone(error) {
            if !isLastAttempt { return (nil, true) }
            read.unreadable[LevelDBManifest.currentFile] = .corrupt(LevelDBManifest.currentFile)
        } catch {
            read.unreadable[file] = .unsupported("file")
        }
        return (nil, false)
    }

    /// Whether the file named `name`, or at that path, is one of LevelDB's tables.
    public static func isTable(_ name: String) -> Bool {
        name.hasSuffix(".ldb") || name.hasSuffix(".sst")
    }

    /// The number LevelDB named a table or a log with, as `000005.ldb`; nil for a name without one.
    static func number(_ name: String) -> UInt64? {
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let stem = name[..<dot]
        guard !stem.isEmpty, stem.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return UInt64(stem)
    }

    /// A file's bytes from `offset` to its end, and which file they came from, from one descriptor, so a file put in
    /// its place meanwhile can't mix in.
    public static func contents(of url: URL, from offset: Int = 0) throws -> ([UInt8], FileInfo.ID) {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let info = FileInfo(descriptor: file.fileDescriptor) else { throw CocoaError(.fileReadUnknown) }
        guard offset <= Int(info.size) else { return ([], info.id) }
        try file.seek(toOffset: UInt64(offset))
        let data = try file.readToEnd() ?? Data()
        return ([UInt8](data), info.id)
    }

    static func isGone(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            return error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
        }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }
}
