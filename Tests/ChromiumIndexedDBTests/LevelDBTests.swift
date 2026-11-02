import Testing
@testable import ChromiumIndexedDB

@Suite struct CompressionTests {
    @Test func checksumsAsLevelDBDoes() {
        #expect(CRC32C.checksum(Array("123456789".utf8)) == 0xE306_9283)
        #expect(CRC32C.checksum(Array("56789".utf8), extending: CRC32C.checksum(Array("1234".utf8))) == 0xE306_9283)
        let crc = CRC32C.checksum(Array("made-up".utf8))
        #expect(CRC32C.mask(crc) != crc)
        #expect(CRC32C.unmask(CRC32C.mask(crc)) == crc)
    }

    @Test func decompressesLiteralsAndCopies() throws {
        // "ab", then 6 bytes copied from 2 back: a run.
        #expect(try Snappy.decompress([0x08, 0x04, 0x61, 0x62, 0x09, 0x02]) == Array("abababab".utf8))
        // "xyz", then 3 bytes from 3 back with a 2-byte offset.
        #expect(try Snappy.decompress([0x06, 0x08, 0x78, 0x79, 0x7A, 0x0A, 0x03, 0x00]) == Array("xyzxyz".utf8))
        // A 4-byte offset.
        #expect(try Snappy.decompress([0x04, 0x00, 0x71, 0x0B, 0x01, 0x00, 0x00, 0x00]) == Array("qqqq".utf8))
        let long = (0..<70_000).map { UInt8(truncatingIfNeeded: $0 * 7) }
        #expect(try Snappy.decompress(snappyLiterals(long)) == long)
    }

    @Test func refusesWhatIsntSnappy() {
        #expect(throws: FormatError.corrupt("Snappy copy")) { try Snappy.decompress([0x04, 0x09, 0x00]) }
        #expect(throws: FormatError.corrupt("Snappy copy")) { try Snappy.decompress([0x08, 0x04, 0x61, 0x62, 0x09, 0x03]) }
        #expect(throws: FormatError.corrupt("Snappy length")) { try Snappy.decompress([0x05, 0x04, 0x61, 0x62]) }
        #expect(throws: FormatError.corrupt("Snappy literal")) { try Snappy.decompress([0x05, 0x10, 0x61]) }
        #expect(throws: FormatError.truncated) { try Snappy.decompress([0x80]) }
    }
}

@Suite struct LevelDBLogTests {
    private let key = Array("made-up key".utf8)

    @Test func readsWritesAndDeletionsInOrder() {
        var log = LogWriter()
        log.add(LogWriter.batch(sequence: 7, [(key, Array("one".utf8)), (Array("other".utf8), nil)]))
        log.add(LogWriter.batch(sequence: 9, [(key, Array("two".utf8))]))
        let parsed = LevelDBLog.parse(log.bytes)
        #expect(parsed.entries == [
            LevelDBEntry(sequence: 7, key: key, value: Array("one".utf8)),
            LevelDBEntry(sequence: 8, key: Array("other".utf8), value: nil),
            LevelDBEntry(sequence: 9, key: key, value: Array("two".utf8)),
        ])
        #expect(parsed.end == log.bytes.count)
        #expect(parsed.corrupt == 0)
        #expect(LevelDBLog.parse(log.bytes, keep: { $0.elementsEqual(Array("other".utf8)) }).entries.map(\.sequence) == [8])
    }

    @Test func joinsBatchesSplitAcrossBlocks() {
        var log = LogWriter()
        log.add(LogWriter.batch(sequence: 1, [(key, [UInt8](repeating: 1, count: 32_740))]))
        let big = (0..<80_000).map { UInt8(truncatingIfNeeded: $0) }
        log.add(LogWriter.batch(sequence: 2, [(key, big)]))
        let parsed = LevelDBLog.parse(log.bytes)
        #expect(parsed.entries.map(\.sequence) == [1, 2])
        #expect(parsed.entries.last?.value == big)
        #expect(parsed.end == log.bytes.count)
    }

    @Test func stopsBeforeWhatIsntWrittenYetAndGoesOnLater() {
        var log = LogWriter()
        log.add(LogWriter.batch(sequence: 1, [(key, Array("first".utf8))]))
        let firstEnd = log.bytes.count
        log.add(LogWriter.batch(sequence: 2, [(key, [UInt8](repeating: 2, count: 50_000))]))
        // Mid-record, and mid-batch, with its first fragment complete.
        for cut in [firstEnd + 3, firstEnd + 100, 40_000] {
            let parsed = LevelDBLog.parse(Array(log.bytes.prefix(cut)))
            #expect(parsed.entries.map(\.sequence) == [1])
            #expect(parsed.end == firstEnd)
            #expect(parsed.corrupt == 0)
        }
        let rest = LevelDBLog.parse(Array(log.bytes[firstEnd...]), fileOffset: firstEnd)
        #expect(rest.entries.map(\.sequence) == [2])
        #expect(rest.end == log.bytes.count)
        // Space LevelDB hasn't written to yet.
        #expect(LevelDBLog.parse(log.bytes + [UInt8](repeating: 0, count: 100)).end == log.bytes.count)
    }

    @Test func skipsABlockWithABadChecksum() {
        var log = LogWriter()
        log.add(LogWriter.batch(sequence: 1, [(key, Array("lost".utf8))]))
        log.add(LogWriter.batch(sequence: 2, [(key, [UInt8](repeating: 0, count: 40_000))]))
        log.add(LogWriter.batch(sequence: 3, [(key, Array("kept".utf8))]))
        var bytes = log.bytes
        bytes[10] ^= 0xFF
        let parsed = LevelDBLog.parse(bytes)
        // The first block is dropped, so the batch that starts there is lost too.
        #expect(parsed.entries.map(\.sequence) == [3])
        #expect(parsed.corrupt >= 1)
        #expect(parsed.end == bytes.count)
    }
}

@Suite struct LevelDBTableTests {
    private func entries(_ count: Int) -> [TableWriter.Entry] {
        (0..<count).map { index in
            TableWriter.Entry(key: Array("key-\(100 + index)".utf8), sequence: UInt64(index + 1),
                              value: index == 3 ? nil : Array("value \(index)".utf8))
        }
    }

    @Test(arguments: [false, true])
    func readsEveryBlock(compressed: Bool) throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("000005.ldb")
            try write(TableWriter.table(entries(7), perBlock: 3, compress: compressed, restartInterval: 2), to: url)
            let read = try LevelDBTable.read(url)
            #expect(read.entries.map(\.key) == entries(7).map(\.key))
            #expect(read.entries.map(\.sequence) == Array(1...7))
            #expect(read.entries[3].value == nil)
            #expect(read.entries[6].value == Array("value 6".utf8))
            #expect(read.blocksRead == 3 && read.blocksSkipped == 0)
            #expect(read.separatorsExact == true)
        }
    }

    @Test func skipsBlocksOutsideTheRange() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("000005.ldb")
            try write(TableWriter.table(entries(7), perBlock: 3), to: url)
            var bounds: [(String?, String)] = []
            let read = try LevelDBTable.read(url, mayHold: { lower, upper in
                bounds.append((lower.map { String(decoding: $0, as: UTF8.self) }, String(decoding: upper, as: UTF8.self)))
                return lower != nil && upper != Array("key-106".utf8)
            })
            #expect(bounds.map(\.0) == [nil, "key-102", "key-105"])
            #expect(bounds.map(\.1) == ["key-102", "key-105", "key-106"])
            #expect(read.entries.map(\.sequence) == [4, 5, 6])
            #expect(read.blocksRead == 1 && read.blocksSkipped == 2)
        }
    }

    @Test func survivesHandlesThatWouldOverflow() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("000005.ldb")
            // Int.max / 2 for both the index block's offset and size.
            let huge: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x3F]
            var footer: [UInt8] = [0, 0] + huge + huge
            footer += [UInt8](repeating: 0, count: 40 - footer.count)
            try write([UInt8](repeating: 0, count: 100) + footer + littleEndian(LevelDBTable.magic, 8), to: url)
            #expect(throws: FormatError.corrupt("block handle")) { try LevelDBTable.read(url) }
        }
    }

    @Test func refusesKeysThatAddUpToFarMoreThanTheBlock() {
        // One long key, then many that share all of it: each a full copy.
        var block = varint(0) + varint(100_000) + varint(0) + [UInt8](repeating: 1, count: 100_000)
        for _ in 0..<10_000 {
            block += varint(100_000) + varint(1) + varint(0) + [2]
        }
        block += littleEndian(0, 4) + littleEndian(1, 4)
        #expect(throws: FormatError.corrupt("block keys")) { try LevelDBTable.blockEntries(block) }
    }

    @Test func refusesWhatIsntATable() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("000005.ldb")
            var table = TableWriter.table(entries(4))
            table[table.count - 1] ^= 0xFF
            try write(table, to: url)
            #expect(throws: FormatError.corrupt("table magic")) { try LevelDBTable.read(url) }
            table[table.count - 1] ^= 0xFF
            table[2] ^= 0xFF
            try write(table, to: url)
            #expect(throws: FormatError.corrupt("block checksum")) { try LevelDBTable.read(url) }
            try write([1, 2, 3], to: url)
            #expect(throws: FormatError.corrupt("table footer")) { try LevelDBTable.read(url) }
        }
    }
}

@Suite struct LevelDBFolderTests {
    @Test func takesTheNewestWriteOfEachKey() throws {
        try withTemporaryDirectory { directory in
            let older = [("a", 1, "a1"), ("b", 2, "b1"), ("c", 3, "c1")].map {
                TableWriter.Entry(key: Array($0.0.utf8), sequence: UInt64($0.1), value: Array($0.2.utf8))
            }
            try write(TableWriter.table(older), to: directory.appendingPathComponent("000004.ldb"))
            var log = LogWriter()
            log.add(LogWriter.batch(sequence: 5, [(Array("b".utf8), Array("b2".utf8)), (Array("c".utf8), nil)]))
            try write(log.bytes, to: directory.appendingPathComponent("000006.log"))
            // An older log, which a flush hasn't removed yet.
            var stale = LogWriter()
            stale.add(LogWriter.batch(sequence: 4, [(Array("a".utf8), Array("a0".utf8))]))
            try write(stale.bytes, to: directory.appendingPathComponent("000003.log"))

            let read = try LevelDBFolder(url: directory).read()
            #expect(read.values == [Array("a".utf8): Array("a0".utf8), Array("b".utf8): Array("b2".utf8)])
            #expect(read.latest[Array("c".utf8)]?.value == nil)
            #expect(read.tables == 1 && read.logs == 2)
            #expect(read.log?.url.lastPathComponent == "000006.log")
            #expect(read.log?.offset == log.bytes.count)
            #expect(read.unreadable.isEmpty)
        }
    }

    @Test func readsEveryBlockWhenIndexKeysArentTheLastKeys() throws {
        try withTemporaryDirectory { directory in
            let entries = (0..<6).map { TableWriter.Entry(key: [UInt8($0 * 10)], sequence: UInt64($0 + 1), value: [UInt8($0)]) }
            // Index keys past each block's last key, as a comparator that shortens them could leave: [15], [35], [55].
            let table = TableWriter.table(entries, perBlock: 2) { last in [last[0] + 5] + last.dropFirst() }
            try write(table, to: directory.appendingPathComponent("000004.ldb"))
            // Skips the second block by its index key alone.
            let read = try LevelDBFolder(url: directory).read(mayHold: { _, upper in upper != [35] })
            #expect(read.values.count == 6)
        }
    }

    @Test func reportsATableItCantRead() throws {
        try withTemporaryDirectory { directory in
            try write([0, 1, 2], to: directory.appendingPathComponent("000004.ldb"))
            var log = LogWriter()
            log.add(LogWriter.batch(sequence: 1, [([1], [2])]))
            try write(log.bytes, to: directory.appendingPathComponent("000005.log"))
            let read = try LevelDBFolder(url: directory).read()
            #expect(read.unreadable == ["000004.ldb": .corrupt("table footer")])
            #expect(read.values == [[1]: [2]])
        }
    }

    /// Of the tables and logs in the folder, the database's are those its MANIFEST lists. LevelDB removes the others once
    /// it no longer needs them, but one it couldn't remove yet holds writes that compaction has since dropped, deletions
    /// included: read, it would bring back a key that was deleted.
    @Test func readsOnlyTheTablesAndLogsTheManifestLists() throws {
        try withTemporaryDirectory { directory in
            // Log 3 wrote "a", "b" and "x", and a flush put them in table 5; log 6 then deleted "a" and "x" and wrote "c",
            // and a flush put that in table 7. Compaction merged tables 5 and 7 into table 9 and, at the last level,
            // dropped the deleted keys. Log 3 and table 5 are left behind; log 8 is the one LevelDB writes to now.
            var flushed = LogWriter()
            flushed.add(LogWriter.batch(sequence: 1, [
                (Array("a".utf8), Array("a1".utf8)), (Array("b".utf8), Array("b1".utf8)), (Array("x".utf8), Array("x1".utf8)),
            ]))
            try write(flushed.bytes, to: directory.appendingPathComponent("000003.log"))
            try write(TableWriter.table(Self.entries(("a", 1), ("b", 2), ("x", 3))), to: directory.appendingPathComponent("000005.ldb"))
            try write(TableWriter.table(Self.entries(("b", 2), ("c", 6))), to: directory.appendingPathComponent("000009.ldb"))
            var current = LogWriter()
            current.add(LogWriter.batch(sequence: 7, [(Array("d".utf8), Array("d1".utf8))]))
            try write(current.bytes, to: directory.appendingPathComponent("000008.log"))
            try ManifestWriter.save([
                ManifestWriter.edit(comparator: "idb_cmp1", logNumber: 3, nextFile: 4, lastSequence: 0),
                ManifestWriter.edit(logNumber: 6, nextFile: 7, lastSequence: 3, added: [5]),
                ManifestWriter.edit(logNumber: 8, nextFile: 9, lastSequence: 6, added: [7]),
                ManifestWriter.edit(logNumber: 8, nextFile: 10, lastSequence: 7, deleted: [5, 7], added: [9]),
            ], number: 2, in: directory)

            let read = try LevelDBFolder(url: directory).read()
            #expect(Self.texts(read) == ["b": "b1", "c": "c1", "d": "d1"])
            #expect(read.tables == 1 && read.logs == 1)
            #expect(read.unlisted == 2)
            #expect(read.log?.url.lastPathComponent == "000008.log")
            #expect(read.unreadable.isEmpty)
        }
    }

    /// LevelDB writes a table, then lists it: one it's still writing reads as broken, but isn't the database's yet.
    @Test func leavesOutATableLevelDBIsStillWriting() throws {
        try withTemporaryDirectory { directory in
            try write(TableWriter.table(Self.entries(("a", 1))), to: directory.appendingPathComponent("000005.ldb"))
            try write([UInt8](repeating: 7, count: 100), to: directory.appendingPathComponent("000007.ldb"))
            try ManifestWriter.save([ManifestWriter.edit(logNumber: 6, nextFile: 8, lastSequence: 1, added: [5])],
                                    number: 2, in: directory)

            let read = try LevelDBFolder(url: directory).read()
            #expect(Self.texts(read) == ["a": "a1"])
            #expect(read.tables == 1 && read.unlisted == 1)
            #expect(read.unreadable.isEmpty)
        }
    }

    /// Without the MANIFEST, it can't tell which files are the database's: it reads them all, and says the MANIFEST
    /// couldn't be read.
    @Test func readsEveryFileWhenTheManifestCantBeRead() throws {
        try withTemporaryDirectory { directory in
            try write(TableWriter.table(Self.entries(("a", 1))), to: directory.appendingPathComponent("000005.ldb"))
            try write(TableWriter.table(Self.entries(("b", 2))), to: directory.appendingPathComponent("000009.ldb"))
            // An edit LevelDB doesn't know, as a large value reference, which it no longer has.
            let name = try ManifestWriter.save([
                ManifestWriter.edit(logNumber: 6, nextFile: 10, lastSequence: 2, added: [9]), varint(8) + varint(1),
            ], number: 2, in: directory)
            let everything = ["a": "a1", "b": "b1"]

            let unknown = try LevelDBFolder(url: directory).read()
            #expect(unknown.unreadable == [name: .corrupt("version edit")])
            #expect(Self.texts(unknown) == everything)
            #expect(unknown.unlisted == 0)

            try write(Array("../\(name)\n".utf8), to: directory.appendingPathComponent("CURRENT"))
            let elsewhere = try LevelDBFolder(url: directory).read()
            #expect(elsewhere.unreadable == ["CURRENT": .corrupt("CURRENT")])
            #expect(Self.texts(elsewhere) == everything)

            // A MANIFEST that's gone, as one LevelDB replaced as the folder was read: it starts over, then reads them all.
            try write(Array("MANIFEST-000003\n".utf8), to: directory.appendingPathComponent("CURRENT"))
            let gone = try LevelDBFolder(url: directory).read()
            #expect(gone.unreadable.isEmpty)
            #expect(Self.texts(gone) == everything)
        }
    }

    /// Made-up writes, each key's value its name and "1".
    private static func entries(_ writes: (String, UInt64)...) -> [TableWriter.Entry] {
        writes.map { TableWriter.Entry(key: Array($0.0.utf8), sequence: $0.1, value: Array(($0.0 + "1").utf8)) }
    }

    private static func texts(_ read: LevelDBFolder.Read) -> [String: String] {
        Dictionary(uniqueKeysWithValues: read.values.map {
            (String(decoding: $0.key, as: UTF8.self), String(decoding: $0.value, as: UTF8.self))
        })
    }
}
