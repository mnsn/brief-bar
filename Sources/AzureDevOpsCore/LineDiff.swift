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
    /// stops looking for the fewest, and the lines between those are all removed, then all added. Its time and memory grow
    /// with that number, and its square: this keeps a file rewritten from end to end, which it shows that way anyway,
    /// from taking long.
    public static let maxChanges = 2_000

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
        compare(lines(old), lines(new), maxChanges: maxChanges)
    }

    /// Every line of both versions, in order.
    public static func compare(_ old: [Substring], _ new: [Substring], maxChanges: Int = maxChanges) -> [DiffLine] {
        // Each different line as a number, so that lines compare as numbers do.
        var ids: [Substring: Int] = [:]
        func id(_ line: Substring) -> Int {
            if let id = ids[line] { return id }
            ids[line] = ids.count
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
        let middle = edits(oldMiddle, newMiddle, limit: maxChanges)
            ?? Array(repeating: .delete, count: oldMiddle.count) + Array(repeating: .insert, count: newMiddle.count)

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
        return lines
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
