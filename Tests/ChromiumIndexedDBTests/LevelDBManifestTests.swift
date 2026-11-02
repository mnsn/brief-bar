import Foundation
import Testing
@testable import ChromiumIndexedDB

/// Which tables and logs LevelDB's MANIFEST says the database has, as LevelDB reads it.
@Suite struct LevelDBManifestTests {
    @Test func appliesEachEditInOrder() throws {
        // Log 3 flushed to table 5, then log 6 to table 7; compaction merged both into table 9, then moved it a level
        // down.
        let manifest = ManifestWriter.manifest([
            ManifestWriter.edit(comparator: "idb_cmp1", logNumber: 3, nextFile: 4, lastSequence: 0),
            ManifestWriter.edit(logNumber: 6, nextFile: 7, lastSequence: 3, added: [5]),
            ManifestWriter.edit(logNumber: 8, nextFile: 9, lastSequence: 6, added: [7]),
            ManifestWriter.edit(nextFile: 10, lastSequence: 7, deleted: [5, 7], added: [9]),
            ManifestWriter.edit(deleted: [9]) + ManifestWriter.edit(added: [9], level: 1),
        ])
        let version = try LevelDBManifest.parse(manifest)
        #expect(version.tables == [9])
        #expect(version.logNumber == 8 && version.prevLogNumber == 0)
    }

    /// LevelDB applies an edit's deletions, then its additions, whatever their order in it.
    @Test func removesAnEditsTablesBeforeAddingItsOwn() throws {
        let manifest = ManifestWriter.manifest([
            ManifestWriter.edit(logNumber: 1, nextFile: 6, lastSequence: 1, added: [4, 5]),
            ManifestWriter.edit(added: [5]) + ManifestWriter.edit(deleted: [4, 5]),
        ])
        #expect(try LevelDBManifest.parse(manifest).tables == [5])
    }

    /// The logs LevelDB replays as it opens the database: from its log number on, and the older one it may still need.
    @Test func keepsTheLogsLevelDBReplays() throws {
        let manifest = ManifestWriter.manifest([
            ManifestWriter.edit(logNumber: 8, nextFile: 10, lastSequence: 1) + varint(9) + varint(6),
        ])
        let version = try LevelDBManifest.parse(manifest)
        #expect(version.prevLogNumber == 6)
        let logs: [UInt64] = [5, 6, 7, 8, 9]
        #expect(logs.map { version.isLiveLog($0) } == [false, true, false, true, true])
    }

    /// LevelDB writes an edit as one record, at the end: one that isn't all there yet is one it's still writing.
    @Test func leavesOutAnEditStillBeingWritten() throws {
        let first = ManifestWriter.edit(comparator: "idb_cmp1", logNumber: 3, nextFile: 6, lastSequence: 0, added: [5])
        let whole = ManifestWriter.manifest([
            first, ManifestWriter.edit(logNumber: 7, nextFile: 9, lastSequence: 4, deleted: [5], added: [8]),
        ])
        let firstRecord = ManifestWriter.manifest([first]).count
        for cut in [firstRecord + 3, whole.count - 1] {
            let version = try LevelDBManifest.parse(Array(whole.prefix(cut)))
            #expect(version.tables == [5])
            #expect(version.logNumber == 3)
        }
    }

    /// What LevelDB refuses to open the database with, BriefBar doesn't go by either.
    @Test func refusesWhatLevelDBRefuses() {
        let complete = ManifestWriter.edit(comparator: "idb_cmp1", logNumber: 3, nextFile: 6, lastSequence: 0)
        let refused: [[[UInt8]]] = [
            // An edit it doesn't know, as a large value reference, which LevelDB no longer has.
            [complete, varint(8) + varint(1)],
            [ManifestWriter.edit(nextFile: 6, lastSequence: 0)],
            [ManifestWriter.edit(logNumber: 3, lastSequence: 0)],
            [ManifestWriter.edit(logNumber: 3, nextFile: 6)],
            [complete, ManifestWriter.edit(added: [5], level: 7)],
            // A table without its keys, all in one record.
            [complete, Array(ManifestWriter.edit(added: [5]).dropLast(4))],
        ]
        for edits in refused {
            #expect(throws: FormatError.self) { try LevelDBManifest.parse(ManifestWriter.manifest(edits)) }
        }
        // A record whose checksum doesn't match, with another after it.
        var damaged = ManifestWriter.manifest([complete, ManifestWriter.edit(added: [5]), ManifestWriter.edit(added: [6])])
        damaged[LevelDBLog.headerSize + complete.count + LevelDBLog.headerSize + 1] ^= 0xFF
        #expect(throws: FormatError.corrupt("manifest")) { try LevelDBManifest.parse(damaged) }
    }

    /// Microsoft Edge's, in the fixture: as LevelDB creates a database, with no tables, and its log number 0, which
    /// keeps every log.
    @Test func readsTheFixturesManifest() throws {
        let current = try Data(contentsOf: Fixture.leveldb.appendingPathComponent(LevelDBManifest.currentFile))
        let name = try LevelDBManifest.name(current: Array(current))
        let manifest = try Data(contentsOf: Fixture.leveldb.appendingPathComponent(name))
        let version = try LevelDBManifest.parse(Array(manifest))
        #expect(name == "MANIFEST-000001")
        #expect(version.tables.isEmpty)
        #expect(version.isLiveLog(3))
    }

    @Test func readsOnlyAManifestsNameFromCurrent() throws {
        #expect(try LevelDBManifest.name(current: Array("MANIFEST-000012\n".utf8)) == "MANIFEST-000012")
        for current in ["", "MANIFEST-000012", "MANIFEST-000012\r\n", "MANIFEST-\n", "MANIFEST-12a\n", "../MANIFEST-000012\n",
                        "LOG\n"] {
            #expect(throws: FormatError.corrupt("CURRENT")) { try LevelDBManifest.name(current: Array(current.utf8)) }
        }
    }
}
