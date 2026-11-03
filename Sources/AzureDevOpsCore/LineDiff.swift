import Foundation

/// A line of a diff: in both versions of a file, or in only one of them.
public struct DiffLine: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case unchanged, added, removed
    }

    public var kind: Kind
    public var text: String
    /// Its number in the version before the change, from 1: nil for an added line.
    public var oldNumber: Int?
    /// Its number in the version after the change, from 1: nil for a removed line.
    public var newNumber: Int?

    public init(_ kind: Kind, _ text: String, old oldNumber: Int?, new newNumber: Int?) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

/// Changed lines with the unchanged ones around them, as a unified diff shows them under `@@ -12,7 +12,9 @@`.
public struct DiffHunk: Sendable, Equatable {
    /// Its first line in the version before the change, and how many lines of that version it has. Without any, as for
    /// lines added to a new file, it starts at the line before them: 0 at the top.
    public var oldStart: Int
    public var oldCount: Int
    /// The same in the version after the change.
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }

    /// "@@ -12,7 +12,9 @@"
    public var header: String { "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" }
}

/// Compares two versions of a text file a line at a time, as `git diff` does: with the fewest lines removed and added
/// (Myers' algorithm), and in each place that changed, the removed lines before the ones added.
public enum LineDiff {
    /// Past this many lines removed and added, besides the lines the two versions share at their starts and ends, it
    /// stops looking for the fewest. It lines the versions up at the lines each of them has only once instead, as many of
    /// those as come in the same order in both, as a patience diff does, and between those looks for the fewest again, up
    /// to as many, or else takes all of their lines as removed, then added. Its time and memory grow with that number, and
    /// its square: this keeps a file rewritten from end to end, which it shows that way anyway, from taking long.
    public static let maxChanges = 2_000

    /// What comparing two versions found: every line of both, in order, and whether they're lined up with the fewest
    /// lines removed and added.
    public struct Comparison: Sendable, Equatable {
        public var lines: [DiffLine]
        /// False past `maxChanges`, when they're lined up only at the lines each version has once: then they may remove
        /// and add more lines than changed, and fewer when the lines the versions have once moved.
        public var isLinedUp: Bool

        public init(lines: [DiffLine], isLinedUp: Bool = true) {
            self.lines = lines
            self.isLinedUp = isLinedUp
        }
    }

    /// A text's lines: split at each line feed, without a carriage return before it, and with no empty line after the
    /// last one.
    public static func lines(_ text: String) -> [Substring] {
        var lines: [Substring] = []
        let bytes = text.utf8
        var start = bytes.startIndex
        var index = start
        /// The line from `start` to `end`, without a carriage return that ends it. Neither splits a character: a line
        /// feed, and a carriage return before one, always end one.
        func add(_ end: String.Index) {
            var end = end
            if end > start, bytes[bytes.index(before: end)] == UInt8(ascii: "\r") { end = bytes.index(before: end) }
            lines.append(text[start..<end])
        }
        while index < bytes.endIndex {
            if bytes[index] == UInt8(ascii: "\n") {
                add(index)
                start = bytes.index(after: index)
            }
            index = bytes.index(after: index)
        }
        if start < bytes.endIndex { add(bytes.endIndex) }
        return lines
    }

    /// Every line of both versions, in order.
    public static func compare(_ old: String, _ new: String, maxChanges: Int = maxChanges) -> [DiffLine] {
        comparison(old, new, maxChanges: maxChanges).lines
    }

    /// Every line of both versions, in order.
    public static func compare(_ old: [Substring], _ new: [Substring], maxChanges: Int = maxChanges) -> [DiffLine] {
        comparison(old, new, maxChanges: maxChanges).lines
    }

    /// Every line of both versions, in order, and whether they're lined up with the fewest lines removed and added.
    public static func comparison(_ old: String, _ new: String, maxChanges: Int = maxChanges) -> Comparison {
        var old = old
        var new = new
        old.makeContiguousUTF8()
        new.makeContiguousUTF8()
        return comparison(lines(old), lines(new), maxChanges: maxChanges)
    }

    /// Every line of both versions, in order, and whether they're lined up with the fewest lines removed and added.
    public static func comparison(_ old: [Substring], _ new: [Substring], maxChanges: Int = maxChanges) -> Comparison {
        // Each different line as a number, so that lines compare as numbers do, by their bytes: lines that only look
        // alike, such as with an accent written as one character or as two, differ.
        var ids: [Bytes: Int] = [:]
        func id(_ line: Substring) -> Int {
            let bytes = Bytes(line)
            if let id = ids[bytes] { return id }
            ids[bytes] = ids.count
            return ids.count - 1
        }
        let a = old.map(id)
        let b = new.map(id)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let oldMiddle = a[prefix..<(a.count - suffix)]
        let newMiddle = b[prefix..<(b.count - suffix)]
        let fewest = edits(oldMiddle, newMiddle, limit: maxChanges)
        let middle = fewest ?? aligned(oldMiddle, newMiddle, limit: maxChanges)

        var lines: [DiffLine] = []
        lines.reserveCapacity(max(old.count, new.count))
        var i = 0
        var j = 0
        var removed: [DiffLine] = []
        var added: [DiffLine] = []
        func unchanged(_ count: Int) {
            lines += removed
            lines += added
            removed = []
            added = []
            for _ in 0..<count {
                lines.append(DiffLine(.unchanged, String(new[j]), old: i + 1, new: j + 1))
                i += 1
                j += 1
            }
        }
        unchanged(prefix)
        for edit in middle {
            switch edit {
            case .equal:
                unchanged(1)
            case .delete:
                removed.append(DiffLine(.removed, String(old[i]), old: i + 1, new: nil))
                i += 1
            case .insert:
                added.append(DiffLine(.added, String(new[j]), old: nil, new: j + 1))
                j += 1
            }
        }
        unchanged(suffix)
        return Comparison(lines: lines, isLinedUp: fewest != nil)
    }

    /// The changes, each with `context` unchanged lines on either side, or fewer at the file's ends. Changes closer than
    /// that share a hunk.
    public static func hunks(_ lines: [DiffLine], context: Int = 3) -> [DiffHunk] {
        let context = max(0, context)
        let changed = lines.indices.filter { lines[$0].kind != .unchanged }
        guard let first = changed.first else { return [] }
        var ranges: [ClosedRange<Int>] = []
        var start = max(0, first - context)
        var end = min(lines.count - 1, first + context)
        for index in changed.dropFirst() {
            if index - context <= end + 1 {
                end = min(lines.count - 1, index + context)
            } else {
                ranges.append(start...end)
                start = index - context
                end = min(lines.count - 1, index + context)
            }
        }
        ranges.append(start...end)
        return ranges.map { range in
            let slice = lines[range]
            /// Where it starts in one version: its first line there, or the line before, without any.
            func start(_ number: (DiffLine) -> Int?) -> Int {
                if let first = slice.lazy.compactMap(number).first { return first }
                return lines[..<range.lowerBound].lazy.reversed().compactMap(number).first ?? 0
            }
            return DiffHunk(
                oldStart: start(\.oldNumber), oldCount: slice.filter { $0.oldNumber != nil }.count,
                newStart: start(\.newNumber), newCount: slice.filter { $0.newNumber != nil }.count, lines: Array(slice)
            )
        }
    }

    /// A line that compares and hashes as its UTF-8 bytes, where strings compare as what they look like.
    private struct Bytes: Hashable {
        let line: Substring

        init(_ line: Substring) {
            self.line = line
        }

        static func == (lhs: Bytes, rhs: Bytes) -> Bool {
            lhs.line.utf8.elementsEqual(rhs.line.utf8)
        }

        func hash(into hasher: inout Hasher) {
            let hashed: Void? = line.utf8.withContiguousStorageIfAvailable { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
            if hashed == nil { Array(line.utf8).withUnsafeBytes { hasher.combine(bytes: $0) } }
        }
    }

    // MARK: Myers' algorithm

    enum Edit: Equatable {
        /// The next line of each version is the same.
        case equal
        /// The next line of the old version was removed.
        case delete
        /// The next line of the new version was added.
        case insert
    }

    /// The fewest edits that turn `a` into `b`, in order, as Myers' "An O(ND) Difference Algorithm and Its Variations"
    /// (1986) finds them; nil when that takes more than `limit` lines removed and added.
    static func edits(_ a: ArraySlice<Int>, _ b: ArraySlice<Int>, limit: Int) -> [Edit]? {
        let n = a.count
        let m = b.count
        if n == 0 { return Array(repeating: .insert, count: m) }
        if m == 0 { return Array(repeating: .delete, count: n) }
        let maxD = min(n + m, max(0, limit))
        // How far along `a` the furthest path on each diagonal k = x - y reaches: at `offset + k`.
        let offset = maxD + 1
        var reach = [Int](repeating: 0, count: 2 * offset + 1)
        // The reach after each round d, on its diagonals -d, -d + 2 ... d, at (k + d) / 2: to find the way back.
        var trace: [[Int32]] = []
        for d in 0...maxD {
            var round = [Int32](repeating: 0, count: d + 1)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && reach[offset + k - 1] < reach[offset + k + 1]) {
                    x = reach[offset + k + 1]
                } else {
                    x = reach[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[a.startIndex + x] == b[b.startIndex + y] {
                    x += 1
                    y += 1
                }
                reach[offset + k] = x
                round[(k + d) / 2] = Int32(x)
                if x >= n, y >= m {
                    trace.append(round)
                    return path(trace, n: n, m: m)
                }
            }
            trace.append(round)
        }
        return nil
    }

    /// Edits that turn `a` into `b` once finding the fewest takes too long: lined up at the lines each of them has only
    /// once, as many of those as come in the same order in both, as Bram Cohen's patience diff does; between those, the
    /// fewest edits, up to `limit` of them, or else all of their lines removed, then all added.
    static func aligned(_ a: ArraySlice<Int>, _ b: ArraySlice<Int>, limit: Int) -> [Edit] {
        var script: [Edit] = []
        script.reserveCapacity(a.count + b.count)
        var x = 0
        var y = 0
        func between(_ endX: Int, _ endY: Int) {
            let gapA = a[(a.startIndex + x)..<(a.startIndex + endX)]
            let gapB = b[(b.startIndex + y)..<(b.startIndex + endY)]
            script += edits(gapA, gapB, limit: limit)
                ?? Array(repeating: .delete, count: gapA.count) + Array(repeating: .insert, count: gapB.count)
        }
        for anchor in anchors(a, b) {
            between(anchor.x, anchor.y)
            script.append(.equal)
            x = anchor.x + 1
            y = anchor.y + 1
        }
        between(a.count, b.count)
        return script
    }

    /// Where the lines that `a` and `b` each have only once are in each, by their offsets: the most of them that come in
    /// the same order in both, in that order.
    static func anchors(_ a: ArraySlice<Int>, _ b: ArraySlice<Int>) -> [(x: Int, y: Int)] {
        var inA: [Int: Int] = [:]
        for line in a { inA[line, default: 0] += 1 }
        // Of the lines `a` has once, where `b` has each: -1 for one it has more than once.
        var inB: [Int: Int] = [:]
        for (y, line) in b.enumerated() where inA[line] == 1 {
            inB[line] = inB[line] == nil ? y : -1
        }
        var pairs: [(x: Int, y: Int)] = []
        for (x, line) in a.enumerated() {
            if let y = inB[line], y >= 0 { pairs.append((x, y)) }
        }
        // The longest run of them whose places in `b` go up, by patience sorting: `ends[k]` is the one that ends the run of
        // k + 1 of them found so far whose last place in `b` is lowest, and `before` the one before each in its run.
        var ends: [Int] = []
        var before = [Int](repeating: -1, count: pairs.count)
        for index in pairs.indices {
            var low = 0
            var high = ends.count
            while low < high {
                let middle = (low + high) / 2
                if pairs[ends[middle]].y < pairs[index].y {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            if low > 0 { before[index] = ends[low - 1] }
            if low == ends.count {
                ends.append(index)
            } else {
                ends[low] = index
            }
        }
        var run: [(x: Int, y: Int)] = []
        var index = ends.last ?? -1
        while index >= 0 {
            run.append(pairs[index])
            index = before[index]
        }
        return run.reversed()
    }

    /// The edits along the path that reached the end, from its last round back to its first.
    private static func path(_ trace: [[Int32]], n: Int, m: Int) -> [Edit] {
        var edits: [Edit] = []
        var x = n
        var y = m
        for d in stride(from: trace.count - 1, through: 1, by: -1) {
            let k = x - y
            let before = trace[d - 1]
            func reach(_ k: Int) -> Int { Int(before[(k + d - 1) / 2]) }
            let down = k == -d || (k != d && reach(k - 1) < reach(k + 1))
            let previous = down ? k + 1 : k - 1
            let previousX = reach(previous)
            // The lines the path went along unchanged after its edit, then the edit.
            let editX = down ? previousX : previousX + 1
            while x > editX {
                edits.append(.equal)
                x -= 1
                y -= 1
            }
            edits.append(down ? .insert : .delete)
            x = previousX
            y = previousX - previous
        }
        while x > 0, y > 0 {
            edits.append(.equal)
            x -= 1
            y -= 1
        }
        return edits.reversed()
    }
}
