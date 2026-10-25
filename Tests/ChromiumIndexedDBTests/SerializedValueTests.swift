import Testing
@testable import ChromiumIndexedDB

@Suite struct SerializedValueTests {
    private func decode(_ bytes: [UInt8]) throws -> JSValue {
        guard case .value(let value, _) = try SerializedValue.decode(bytes) else { throw FormatError.corrupt("not a value") }
        return value
    }

    @Test func readsPlainValues() throws {
        let bytes = V8Writer.serialized { writer in
            writer.object([
                ("text", { $0.string("Made-up") }),
                ("snowman", { $0.string("two-byte ☃") }),
                ("negative", { $0.int(-3) }),
                ("fraction", { $0.double(2.5) }),
                ("yes", { $0.tag("T") }),
                ("nothing", { $0.tag("0") }),
                ("missing", { $0.tag("_") }),
                ("list", { $0.array([{ $0.int(1) }, { $0.tag("-") }, { $0.string("x") }]) }),
                ("nested", { $0.object([("id", { $0.string("1792317600000") })]) }),
            ])
        }
        let value = try decode(bytes)
        #expect(value["text"] == .string("Made-up"))
        #expect(value["snowman"] == .string("two-byte ☃"))
        #expect(value["negative"] == .number(-3))
        #expect(value["fraction"] == .number(2.5))
        #expect(value["yes"] == .bool(true))
        #expect(value["nothing"] == .null)
        #expect(value["missing"] == .undefined)
        #expect(value["list"] == .array([.number(1), .undefined, .string("x")]))
        #expect(value["nested"]?["id"]?.string == "1792317600000")
        guard case .value(_, let format) = try SerializedValue.decode(bytes) else { return }
        #expect(format == SerializedValue.Format(blink: 21, v8: 16, compressed: false))
    }

    @Test func readsReferencesDatesMapsSetsAndOthers() throws {
        var body: [UInt8] = [0xFF, 21, 0xFE] + [UInt8](repeating: 0, count: 12) + [0xFF, 15]
        body += Array("o".utf8) + [0x22, 1]
        body += Array("a".utf8) + Array("o{".utf8) + [0] // a: {}
        body += [0x22, 1] + Array("b".utf8)
        body += Array("^".utf8) + [1] // b: the same object, by reference
        body += [0x22, 1] + Array("d".utf8) + Array("D".utf8)
        body += littleEndian(1_792_317_600_000.0.bitPattern, 8)
        body += [0x22, 1] + Array("m".utf8) + Array(";".utf8)
        body += [0x22, 1] + Array("k".utf8) + Array("I".utf8)
        body += [2] + Array(":".utf8) + [2]
        body += [0x22, 1] + Array("s".utf8) + Array("'".utf8)
        body += [0x22, 1] + Array("a".utf8)
        body += Array(",".utf8) + [1]
        body += [0x22, 1] + Array("r".utf8) + Array("R".utf8)
        body += [0x22, 2] + Array("a+".utf8) + [3]
        body += [0x22, 1] + Array("z".utf8)
        body += Array("Z".utf8) + [3, 0x05] // -5n
        body += [0x22, 1] + Array("u".utf8) + Array("S".utf8)
        body += [3] + Array("é!".utf8)
        body += [0x22, 1] + Array("v".utf8) + Array("B".utf8)
        body += [4, 1, 2, 3, 4] + Array("V".utf8)
        body += Array("B".utf8) + [1, 2, 0]
        body += [0x22, 1] + Array("e".utf8) + Array("r".utf8)
        body += Array("T".utf8) + Array("m".utf8) + [0x22, 2]
        body += Array("no".utf8) + Array(".".utf8)
        body += Array("{".utf8) + [10]
        let value = try decode(body)
        #expect(value["b"] == .object([:]))
        #expect(value["d"] == .date(1_792_317_600_000))
        #expect(value["m"] == .map([JSPair(key: .string("k"), value: .number(1))]))
        #expect(value["s"] == .set([.string("a")]))
        #expect(value["r"] == .regExp(pattern: "a+", flags: 3))
        #expect(value["z"] == .bigInt(negative: true, magnitude: [0x05]))
        #expect(value["u"] == .string("é!"))
        #expect(value["v"] == .bytes([2, 3]))
        #expect(value["e"] == .error(message: "no"))
    }

    @Test func readsCompressedValuesAndOlderEnvelopes() throws {
        let plain = V8Writer.serialized { $0.object([("id", { $0.string("19:made-up@thread.v2") })]) }
        let compressed = [0xFF, 0x11, 0x02] + snappyLiterals(plain)
        guard case .value(let value, let format) = try SerializedValue.decode(compressed) else {
            Issue.record("Not a value")
            return
        }
        #expect(value["id"]?.string == "19:made-up@thread.v2")
        #expect(format.compressed)
        // Blink 15: one version for both formats.
        #expect(try decode([0xFF, 0x0F] + Array("T".utf8)) == .bool(true))
        // Blink 18: its own version, then V8's, without a trailer offset.
        #expect(try decode([0xFF, 18, 0xFF, 15] + Array("F".utf8)) == .bool(false))
        // A trailer after the value.
        var trailed: [UInt8] = [0xFF, 21, 0xFE] + littleEndian(0, 4)
        trailed += [0, 0, 0, 18, 0, 0, 0, 3, 0xFF, 16]
        trailed += Array("T".utf8) + [9, 9, 9]
        #expect(try decode(trailed) == .bool(true))
    }

    @Test func pointsToBlobFiles() throws {
        #expect(try SerializedValue.decode([0xFF, 0x11, 0x01] + varint(70_814) + [0]) == .inBlobFile(size: 70_814, index: 0))
    }

    @Test func refusesWhatItDoesntRead() throws {
        let header: [UInt8] = [0xFF, 21, 0xFE] + [UInt8](repeating: 0, count: 12) + [0xFF, 16]
        #expect(throws: FormatError.unsupported("V8 tag 92")) { try decode(header + Array("\\".utf8)) }
        #expect(throws: FormatError.unsupported("V8 version")) { try decode([0xFF, 21, 0xFE] + [UInt8](repeating: 0, count: 12) + [0xFF, 12, 0x54]) }
        #expect(throws: FormatError.truncated) { try decode(header + Array("o".utf8) + [0x22, 9] + Array("short".utf8)) }
        #expect(throws: FormatError.corrupt("property count")) { try decode(header + Array("o{".utf8) + [3]) }
        #expect(throws: FormatError.corrupt("object reference")) { try decode(header + Array("^".utf8) + [0]) }
        var nested = header + [UInt8](repeating: UInt8(ascii: "o"), count: 300)
        for _ in 0..<300 {
            nested += [UInt8(ascii: "{"), 0]
        }
        #expect(throws: FormatError.unsupported("nesting")) { try decode(nested) }
        // Sparse arrays' lengths aren't bounded by their bytes: a value has a budget for them.
        var sparse = Array("a".utf8) + varint(40_000)
        sparse += Array("@".utf8) + varint(0) + varint(40_000)
        var twoSparse = header + Array("o".utf8) + [0x22, 1]
        twoSparse += Array("a".utf8) + sparse + [0x22, 1]
        twoSparse += Array("b".utf8) + sparse
        twoSparse += Array("{".utf8) + [2]
        #expect(throws: FormatError.unsupported("sparse array length")) { try decode(twoSparse) }
        #expect(try decode(header + sparse) == .array([JSValue](repeating: .undefined, count: 40_000)))
    }
}
