import BriefBarCore
import Foundation

/// A LevelDB database's folder, read as it is, without taking its lock: LevelDB never changes a table once written and
/// only appends to its log, so taking, for each key, the write with the highest sequence number gives the database as
/// it was when the read ended. Nothing is written, and nothing copied.
public struct LevelDBFolder: Sendable {
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
    /// `mayHold` doesn't rule out (see `LevelDBTable.read`). A table that compaction removes while it's read makes it
    /// start over, since its keys are in a new table then.
    public func read(
        mayHold: ([UInt8]?, [UInt8]) -> Bool = { _, _ in true },
        keep: (ArraySlice<UInt8>) -> Bool = { _ in true }
    ) throws -> Read {
        var read = Read()
        for _ in 0..<3 {
            var vanished = false
            (read, vanished) = try attempt(mayHold: mayHold, keep: keep)
            if !vanished { break }
        }
        return read
    }

    private func attempt(
        mayHold: ([UInt8]?, [UInt8]) -> Bool, keep: (ArraySlice<UInt8>) -> Bool
    ) throws -> (Read, vanished: Bool) {
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        var read = Read()
        var vanished = false
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
        for name in names.sorted() where name.hasSuffix(".ldb") || name.hasSuffix(".sst") {
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
        let logs = names.compactMap { name -> (number: UInt64, name: String)? in
            guard name.hasSuffix(".log"), let number = UInt64(name.dropLast(4)) else { return nil }
            return (number, name)
        }.sorted { $0.number < $1.number }
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
