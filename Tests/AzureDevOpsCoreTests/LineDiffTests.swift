import Foundation
import Testing
@testable import AzureDevOpsCore

@Suite struct LineDiffTests {
    /// A diff's lines as `git diff` writes them: " a", "-b", "+c".
    private func unified(_ lines: [DiffLine]) -> [String] {
        lines.map { line in
            switch line.kind {
            case .unchanged: return " " + line.text
            case .removed: return "-" + line.text
            case .added: return "+" + line.text
            }
        }
    }

    @Test func splitsLinesAsGitDoes() {
        #expect(LineDiff.lines("") == [])
        #expect(LineDiff.lines("one") == ["one"])
        #expect(LineDiff.lines("one\ntwo\n") == ["one", "two"])
        #expect(LineDiff.lines("one\r\ntwo\r\n") == ["one", "two"])
        #expect(LineDiff.lines("one\n\n\ntwo") == ["one", "", "", "two"])
        #expect(LineDiff.lines("\n") == [""])
        // A carriage return alone doesn't end a line; one at the very end is dropped.
        #expect(LineDiff.lines("one\rtwo\r") == ["one\rtwo"])
        #expect(LineDiff.lines("naïve 🙂\r\nzwölf") == ["naïve 🙂", "zwölf"])
    }

    @Test func numbersEachLineInTheVersionsItsIn() {
        let lines = LineDiff.compare("a\nb\nc\nd\n", "a\nc\nX\nd\ne\n")
        #expect(unified(lines) == [" a", "-b", " c", "+X", " d", "+e"])
        #expect(lines.map(\.oldNumber) == [1, 2, 3, nil, 4, nil])
        #expect(lines.map(\.newNumber) == [1, nil, 2, 3, 4, 5])
    }

    @Test func removesLinesBeforeItAddsThoseInTheirPlace() {
        let lines = LineDiff.compare("keep\nold one\nold two\nkeep too", "keep\nnew one\nnew two\nnew three\nkeep too")
        #expect(unified(lines) == [" keep", "-old one", "-old two", "+new one", "+new two", "+new three", " keep too"])
    }

    @Test func comparesWholeFilesAddedOrRemoved() {
        #expect(unified(LineDiff.compare("", "one\ntwo")) == ["+one", "+two"])
        #expect(unified(LineDiff.compare("one\ntwo", "")) == ["-one", "-two"])
        #expect(LineDiff.compare("", "").isEmpty)
        #expect(unified(LineDiff.compare("same\n", "same\n")) == [" same"])
    }

    @Test func aLineEndingsChangeIsntAChange() {
        #expect(unified(LineDiff.compare("one\r\ntwo\r\n", "one\ntwo\n")) == [" one", " two"])
    }

    @Test(arguments: 0..<300)
    func findsTheFewestChanges(seed: Int) {
        var random = SeededRandom(seed: UInt64(seed))
        let old = (0..<Int.random(in: 0...12, using: &random)).map { _ in String(Int.random(in: 0...4, using: &random)) }
        let new = (0..<Int.random(in: 0...12, using: &random)).map { _ in String(Int.random(in: 0...4, using: &random)) }
        let lines = LineDiff.compare(old.map { Substring($0) }, new.map { Substring($0) })
        // It takes the old version to the new one, line by line, in order.
        #expect(lines.filter { $0.kind != .added }.map(\.text) == old)
        #expect(lines.filter { $0.kind != .removed }.map(\.text) == new)
        #expect(lines.compactMap(\.oldNumber) == Array(1..<(old.count + 1)))
        #expect(lines.compactMap(\.newNumber) == Array(1..<(new.count + 1)))
        // With as few changes as can be: all the lines but the longest common subsequence.
        let changes = lines.filter { $0.kind != .unchanged }.count
        #expect(changes == old.count + new.count - 2 * Self.longestCommonSubsequence(old, new))
    }

    @Test func stopsLookingForTheFewestPastTheLimit() {
        let old = (1...50).map { "old \($0)" }.joined(separator: "\n")
        let new = (1...50).map { "new \($0)" }.joined(separator: "\n")
        // Shared lines at both ends stay, and everything between is removed, then added.
        let lines = LineDiff.compare("first\n" + old + "\nshared\n" + old + "\nlast", "first\n" + new + "\nshared\n" + new + "\nlast",
                                     maxChanges: 10)
        #expect(lines.first == DiffLine(.unchanged, "first", old: 1, new: 1))
        #expect(lines.last == DiffLine(.unchanged, "last", old: 103, new: 103))
        #expect(lines.filter { $0.kind == .removed }.count == 101)
        #expect(lines.filter { $0.kind == .added }.count == 101)
        #expect(lines.dropFirst().prefix(101).allSatisfy { $0.kind == .removed })
        // Under the limit, the shared line between is found.
        let found = LineDiff.compare("first\n" + old + "\nshared\n" + old + "\nlast", "first\n" + new + "\nshared\n" + new + "\nlast")
        #expect(found.contains(DiffLine(.unchanged, "shared", old: 52, new: 52)))
    }

    @Test func comparesLargeFilesWithAFewChangesQuickly() {
        let old = (1...20_000).map { "line \($0) of a long file" }
        var new = old
        new[100] = "changed near the top"
        new.insert("added in the middle", at: 10_000)
        new.remove(at: 19_000)
        let start = ContinuousClock.now
        let lines = LineDiff.compare(old.map { Substring($0) }, new.map { Substring($0) })
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(lines.filter { $0.kind != .unchanged }.count == 4)
    }

    @Test func groupsChangesIntoHunksWithContext() {
        let old = (1...20).map(String.init).joined(separator: "\n")
        var lines = (1...20).map(String.init)
        lines[1] = "two"
        lines[3] = "four"
        lines[17] = "eighteen"
        let hunks = LineDiff.hunks(LineDiff.compare(old, lines.joined(separator: "\n")), context: 2)
        #expect(hunks.count == 2)
        // Changes on lines 2 and 4 share a hunk; line 18's has one of its own.
        #expect(hunks[0].header == "@@ -1,6 +1,6 @@")
        #expect(unified(hunks[0].lines) == [" 1", "-2", "+two", " 3", "-4", "+four", " 5", " 6"])
        #expect(hunks[1].header == "@@ -16,5 +16,5 @@")
        #expect(unified(hunks[1].lines) == [" 16", " 17", "-18", "+eighteen", " 19", " 20"])
        #expect(LineDiff.hunks(LineDiff.compare("same", "same")).isEmpty)
    }

    @Test func startsAHunkWithoutOldLinesAtTheLineBefore() {
        #expect(LineDiff.hunks(LineDiff.compare("", "one\ntwo")).map(\.header) == ["@@ -0,0 +1,2 @@"])
        #expect(LineDiff.hunks(LineDiff.compare("one\ntwo", "")).map(\.header) == ["@@ -1,2 +0,0 @@"])
        let inserted = LineDiff.hunks(LineDiff.compare("a\nb\nc\nd\ne\nf\ng\nh", "a\nb\nc\nd\ne\nf\ng\nh\ni"), context: 0)
        #expect(inserted.map(\.header) == ["@@ -8,0 +9,1 @@"])
    }

    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> Int {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        return table[0][0]
    }
}

@Suite struct ThreadExcerptWindowTests {
    /// Ten lines, where the change removed lines 4 and 5 and added three in their place, and removed the last line.
    private let diff = LineDiff.compare(
        (1...10).map { "line \($0)" }.joined(separator: "\n"),
        ((1...3).map { "line \($0)" } + ["new a", "new b", "new c"] + (6...9).map { "line \($0)" }).joined(separator: "\n")
    )

    private func text(_ window: ThreadExcerpt.Window?) -> [String] {
        (window?.lines ?? []).map { line in
            let mark = switch line.kind {
            case .unchanged: " "
            case .removed: "-"
            case .added: "+"
            }
            return (line.isCommented ? ">" : "") + mark + line.text
        }
    }

    @Test func showsTheThreadsLinesWithTheChangesAmongThem() throws {
        // On the new file's line 5, "new b", with two of its lines on either side, and the lines removed between them.
        let window = ThreadExcerpt.window(of: diff, side: .right, lines: 5...5, context: 2)
        #expect(text(window) == [" line 3", "-line 4", "-line 5", "+new a", ">+new b", "+new c", " line 6"])
        let lines = try #require(window?.lines)
        #expect(lines.map(\.newNumber) == [3, nil, nil, 4, 5, 6, 7])
        #expect(lines.map(\.oldNumber) == [3, 4, 5, nil, nil, nil, 6])
        #expect(window?.reachesStart == false && window?.reachesEnd == false)
    }

    @Test func countsItsContextInTheThreadsSideOnly() {
        // On the old file's line 3, around which the old file's lines 1 to 5 show, with nothing added between them.
        let window = ThreadExcerpt.window(of: diff, side: .left, lines: 3...3, context: 2)
        #expect(text(window) == [" line 1", " line 2", "> line 3", "-line 4", "-line 5"])
        #expect(window?.reachesStart == true)
    }

    @Test func showsWhatsRemovedAtTheTopAndBottomOfTheFile() {
        let removedFirst = LineDiff.compare("gone\nkept\nnext", "kept\nnext")
        let top = ThreadExcerpt.window(of: removedFirst, side: .right, lines: 1...1, context: 1)
        #expect(text(top) == ["-gone", "> kept", " next"])
        #expect(top?.reachesStart == true && top?.reachesEnd == true)

        // The new file's last line, after which the old file's last line was removed.
        let bottom = ThreadExcerpt.window(of: diff, side: .right, lines: 10...10, context: 1)
        #expect(text(bottom) == [" line 8", "> line 9", "-line 10"])
        #expect(bottom?.reachesEnd == true && bottom?.reachesStart == false)
    }

    @Test func isOnRemovedLinesOnTheLeft() {
        let window = ThreadExcerpt.window(of: diff, side: .left, lines: 4...5, context: 1)
        #expect(text(window) == [" line 3", ">-line 4", ">-line 5", "+new a", "+new b", "+new c", " line 6"])
    }

    @Test func showsTheLastOfALongThreadsLines() {
        let long = LineDiff.compare("", (1...40).map { "line \($0)" }.joined(separator: "\n"))
        let window = ThreadExcerpt.window(of: long, side: .right, lines: 5...35, context: 2, maxCommented: 10)
        #expect(window?.hiddenCommentedLines == 21)
        #expect(window?.lines.first?.newNumber == 24)
        #expect(window?.lines.filter(\.isCommented).map { $0.newNumber ?? 0 } == Array(26...35))
        #expect(window?.lines.last?.newNumber == 37)
    }

    @Test func endsAtTheFilesEndWhenTheThreadGoesPastIt() {
        let window = ThreadExcerpt.window(of: diff, side: .right, lines: 9...14, context: 3)
        #expect(window?.lines.filter(\.isCommented).map { $0.newNumber ?? 0 } == [9, 10])
        #expect(window?.reachesEnd == true)
    }

    @Test func hasNoWindowForLinesTheFileDoesntHave() {
        #expect(ThreadExcerpt.window(of: diff, side: .right, lines: 11...11) == nil)
        #expect(ThreadExcerpt.window(of: diff, side: .left, lines: 0...1) == nil)
        #expect(ThreadExcerpt.window(of: LineDiff.compare("gone", ""), side: .right, lines: 1...1) == nil)
        #expect(ThreadExcerpt.window(of: [], side: .left, lines: 1...1) == nil)
    }

    @Test func cutsLongLines() throws {
        let window = ThreadExcerpt.window(of: LineDiff.compare("", String(repeating: "x", count: 5_000)), side: .right, lines: 1...1)
        let line = try #require(window?.lines.first)
        #expect(line.text.count == ThreadExcerpt.maxLineLength)
        #expect(line.text.hasSuffix("…"))
    }
}

/// The same numbers for the same seed, so that a failing case fails again.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
