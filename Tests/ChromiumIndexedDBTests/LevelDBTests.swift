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
}
