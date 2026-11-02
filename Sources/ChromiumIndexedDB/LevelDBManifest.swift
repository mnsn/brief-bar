/// LevelDB's MANIFEST, which CURRENT names: the version edits that made the database what it is, as the records of a
/// log (`LevelDBLog`). Applied in order, they say which tables the database holds, and which logs it hasn't put in a
/// table yet: the files LevelDB reads as it opens the database. It removes the others once it no longer needs them, but
/// one it couldn't remove yet holds writes that compaction has since dropped, deletions included.
public enum LevelDBManifest {
    public static let currentFile = "CURRENT"

    /// The database as the MANIFEST says it is: the numbers of the tables it holds, and the log it replays from, the
    /// oldest it hasn't put in a table yet, with an older one it may still need (0 when there's none).
    public struct Version: Sendable, Equatable {
        public var tables: Set<UInt64>
        public var logNumber: UInt64
        public var prevLogNumber: UInt64

        /// Whether the log `number` is one LevelDB replays as it opens the database, and so keeps.
        public func isLiveLog(_ number: UInt64) -> Bool {
            number >= logNumber || number == prevLogNumber
        }
    }

    private static let namePrefix = Array("MANIFEST-".utf8)
    /// LevelDB's levels, 0 to 6.
    private static let levels: UInt32 = 7

    private enum Tag {
        static let comparator: UInt32 = 1
        static let logNumber: UInt32 = 2
        static let nextFileNumber: UInt32 = 3
        static let lastSequence: UInt32 = 4
        static let compactPointer: UInt32 = 5
        static let deletedFile: UInt32 = 6
        static let newFile: UInt32 = 7
        static let prevLogNumber: UInt32 = 9
    }

    /// A table at a level, as an edit adds or removes it.
    private struct File: Hashable {
        var level: UInt32
        var number: UInt64
    }

    /// The MANIFEST's name from CURRENT, which holds it then a newline. Throws `FormatError` for anything but
    /// `MANIFEST-<number>`, which LevelDB writes, so that it can't name a file elsewhere.
    public static func name(current: [UInt8]) throws -> String {
        guard current.last == UInt8(ascii: "\n") else { throw FormatError.corrupt("CURRENT") }
        let name = current.dropLast()
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        guard name.count > namePrefix.count, name.starts(with: namePrefix),
              name.dropFirst(namePrefix.count).allSatisfy({ digits.contains($0) })
        else { throw FormatError.corrupt("CURRENT") }
        return String(decoding: name, as: UTF8.self)
    }

    /// The version that `bytes`, a MANIFEST, leaves the database at. An edit at the end that isn't all there yet, as
    /// one LevelDB is still writing, is left out. Throws `FormatError` where LevelDB would refuse to open the database:
    /// for a damaged record, the last one included, an edit it doesn't understand, or no log, next file or last
    /// sequence number.
    public static func parse(_ bytes: [UInt8]) throws -> Version {
        var files: Set<File> = []
        var logNumber: UInt64?
        var prevLogNumber: UInt64 = 0
        var hasNextFile = false
        var hasLastSequence = false
        // As LevelDB does, a damaged last record counts as one, rather than one that may still be being written: going
        // by the version before it would read tables that edit removed, perhaps only some of them. One LevelDB is still
        // writing changes as it finishes it, so a later read gets past it.
        let (_, corrupt) = try LevelDBLog.records(bytes, damagedEndIsCorrupt: true) { record in
            var edit = ByteReader(Array(record))
            var deleted: [File] = []
            var added: [File] = []
            while !edit.isAtEnd {
                switch try edit.varint32() {
                case Tag.comparator:
                    try edit.skip(edit.count())
                case Tag.logNumber:
                    logNumber = try edit.varint()
                case Tag.nextFileNumber:
                    _ = try edit.varint()
                    hasNextFile = true
                case Tag.lastSequence:
                    _ = try edit.varint()
                    hasLastSequence = true
                case Tag.compactPointer:
                    _ = try readLevel(&edit)
                    try skipInternalKey(&edit)
                case Tag.deletedFile:
                    let level = try readLevel(&edit)
                    let number = try edit.varint()
                    deleted.append(File(level: level, number: number))
                case Tag.newFile:
                    let level = try readLevel(&edit)
                    let number = try edit.varint()
                    _ = try edit.varint() // Its size,
                    try skipInternalKey(&edit) // its smallest key
                    try skipInternalKey(&edit) // and its largest.
                    added.append(File(level: level, number: number))
                case Tag.prevLogNumber:
                    prevLogNumber = try edit.varint()
                default:
                    throw FormatError.corrupt("version edit")
                }
            }
            // Deletions first, then additions, as LevelDB applies an edit: a table moved to the next level is both.
            files.subtract(deleted)
            files.formUnion(added)
        }
        guard corrupt == 0, let logNumber, hasNextFile, hasLastSequence else { throw FormatError.corrupt("manifest") }
        return Version(tables: Set(files.map(\.number)), logNumber: logNumber, prevLogNumber: prevLogNumber)
    }

    private static func readLevel(_ edit: inout ByteReader) throws -> UInt32 {
        let level = try edit.varint32()
        guard level < levels else { throw FormatError.corrupt("version edit") }
        return level
    }

    /// A key with its sequence number and kind, which LevelDB requires not to be empty.
    private static func skipInternalKey(_ edit: inout ByteReader) throws {
        let count = try edit.count()
        guard count > 0 else { throw FormatError.corrupt("version edit") }
        try edit.skip(count)
    }
}
