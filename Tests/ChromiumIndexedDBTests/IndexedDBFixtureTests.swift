import Foundation
import Testing
@testable import ChromiumIndexedDB

/// Reads the IndexedDB that Microsoft Edge wrote (Tests/Fixtures/ChromiumIndexedDB).
@Suite struct IndexedDBFixtureTests {
    private let folder = IndexedDBFolder(url: Fixture.leveldb)

    @Test func readsTheCatalog() throws {
        let (catalog, read) = try folder.catalog()
        #expect(Set(catalog.databases.values) == [Fixture.conversationsDatabase, Fixture.replyChainsDatabase])
        let conversations = catalog.stores { $0 == Fixture.conversationsDatabase && $1 == "conversations" }
        #expect(conversations.count == 1)
        #expect(Set(catalog.objectStores.values) == ["conversations", "conversations-internal-data", "replychains"])
        #expect(read.logs == 1 && read.unreadable.isEmpty && read.corruptLogRecords == 0)
        #expect(read.log?.offset == (try FileManager.default.attributesOfItem(atPath: Fixture.log.path)[.size] as? Int))
    }

    private func conversations() throws -> [String: IndexedDBFolder.Value] {
        let (catalog, _) = try folder.catalog()
        let stores = catalog.stores { $0 == Fixture.conversationsDatabase && $1 == "conversations" }
        let records = try folder.records(in: stores)
        #expect(records.unreadableKeys == 0)
        var values: [String: IndexedDBFolder.Value] = [:]
        for (key, raw) in records.values {
            values[try #require(key.key.string)] = try folder.value(of: raw, key: key,
                                                                     externalObjects: records.externalObjects[key])
        }
        return values
    }

    @Test func readsEachConversationAsItIsNow() throws {
        let values = try conversations()
        #expect(Set(values.keys) == [Fixture.avery, Fixture.sam, Fixture.crew, Fixture.sync, Fixture.big, Fixture.wrapped, "48:notes"])
        func horizon(_ id: String) -> String? { values[id]?.value["properties"]?["consumptionhorizon"]?.string }
        // The second run read Avery's chat, and Sam sent another message.
        #expect(horizon(Fixture.avery) == "\(Fixture.base + 5000);\(Fixture.base + 5900);\(Fixture.base + 5007)")
        #expect(values[Fixture.sam]?.value["lastMessage"]?["id"]?.string == String(Fixture.base + 8000))
        #expect(horizon(Fixture.sync) == "0;900;7")
        #expect(horizon(Fixture.big) == "\(Fixture.base + 100);\(Fixture.base + 1000);\(Fixture.base + 107)")
        #expect(horizon(Fixture.wrapped) == "\(Fixture.base + 300);\(Fixture.base + 1200);\(Fixture.base + 307)")
        #expect(values[Fixture.avery]?.format == SerializedValue.Format(blink: 21, v8: 16, compressed: false))
        #expect(values[Fixture.big]?.format.compressed == true)
        #expect(values[Fixture.wrapped]?.fromBlobFile == true)
        #expect(values.values.filter(\.fromBlobFile).count == 1)
    }

    @Test func readsNestedValues() throws {
        let nested = try #require(try conversations()[Fixture.crew]?.value["nested"])
        #expect(nested["list"] == .array([.number(1), .number(2.5), .number(-3), .bool(true), .null, .string("two-byte ☃")]))
        #expect(nested["when"] == .date(Double(Fixture.base)))
        #expect(nested["set"] == .set([.string("a")]))
        #expect(nested["map"] == .map([JSPair(key: .string("k"), value: .number(1))]))
        guard case .array(let members)? = try conversations()[Fixture.crew]?.value["members"] else {
            Issue.record("No members")
            return
        }
        #expect(members.count == 40)
    }

    @Test func skipsWhatItDoesntNeedInATable() throws {
        // A table of the fixture's newest writes: metadata, two object stores' records, their exists entries and more.
        try withTemporaryDirectory { directory in
            let read = try LevelDBFolder(url: Fixture.leveldb).read()
            let entries = read.latest.values
                .sorted { a, b in
                    let (pa, pb) = (KeyPrefix(a.key)!, KeyPrefix(b.key)!)
                    return pa != pb ? pa < pb : a.key.lexicographicallyPrecedes(b.key)
                }
                .map { TableWriter.Entry(key: $0.key, sequence: $0.sequence, value: $0.value) }
            let leveldb = directory.appendingPathComponent("made_up.indexeddb.leveldb", isDirectory: true)
            try write(TableWriter.table(entries, perBlock: 4, compress: true), to: leveldb.appendingPathComponent("000009.ldb"))
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("made_up.indexeddb.blob"),
                                                       withDestinationURL: folder.blobFolder)
            let copy = IndexedDBFolder(url: leveldb)
            let (catalog, catalogRead) = try copy.catalog()
            #expect(catalog == (try folder.catalog()).0)
            #expect(catalogRead.blocksSkipped > 0)
            let stores = catalog.stores { $1 == "conversations" }
            let records = try copy.records(in: stores)
            #expect(records.values.count == 7)
            #expect(records.read.blocksSkipped > 10 * records.read.blocksRead)
            let wrapped = IndexedDBFolder.RecordKey(store: stores.first!, key: .string(Fixture.wrapped))
            let value = try copy.value(of: records.values[wrapped]!, key: wrapped, externalObjects: records.externalObjects[wrapped])
            #expect(value.fromBlobFile)
        }
    }

    @Test func goesOnReadingTheLogWhereItStopped() throws {
        let (bytes, _) = try LevelDBFolder.contents(of: Fixture.log)
        let first = LevelDBLog.parse(Array(bytes.prefix(Fixture.firstRunLength)))
        #expect(first.end == Fixture.firstRunLength)
        #expect(first.corrupt == 0)
        let (rest, _) = try LevelDBFolder.contents(of: Fixture.log, from: first.end)
        let second = LevelDBLog.parse(rest, fileOffset: first.end)
        #expect(second.end == bytes.count)
        let records = second.entries.compactMap { entry -> (String, Bool)? in
            guard case .record(_, _, let key)? = try? IndexedDBKey(entry.key), let id = key.string else { return nil }
            return (id, entry.value != nil)
        }
        #expect(records.map(\.0) == [Fixture.avery, Fixture.sam, Fixture.channel])
        #expect(records.map(\.1) == [true, true, false])
    }
}
