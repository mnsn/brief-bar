import Foundation

/// Text a prompt for Copilot quotes from where others write, such as a comment, a test's name, a file's path or a work
/// item's title, so that none of it reads as the prompt's own, whatever it says: on one of the prompt's lines (`oneLine`),
/// or in a fence nothing in it closes (`fenced`), with what controls how text reads, or hides text, written out as
/// escapes. A pull request's prompts and a work item's use it alike.
public enum QuotedText {
    /// Text quoted on one of a prompt's lines: its line breaks, and characters that control how text reads or hide text,
    /// written out as escapes (`inLine`), so that all of it stays on that line, nothing in it starts a line of the prompt's
    /// own, and nothing in it is unseen. Nor does it start what would take the lines after it in where it starts a line, as
    /// a name does before what its author said: a fence, three backticks or tildes or more, or a block of HTML, such as a
    /// comment, "<!--", or a tag, "<div", which CommonMark reads until the comment closes or a blank line, a fence's line
    /// too; after a space or a joiner or not, or after a list's or a quote's marker, "- ```". The character that would
    /// start it is written out, "\u{60}" or "\u{3C}" (`withoutBlockAtStart`).
    public static func oneLine(_ text: String) -> String {
        withoutBlockAtStart(inLine(text))
    }

    /// Text quoted inside one of a prompt's lines, after what the prompt says first, such as a branch's name in a sentence:
    /// its line breaks, and characters that control how text reads or hide text, written out as escapes, "\n", "\u{202E}"
    /// (`isControl`), so that all of it stays on that line and nothing in it is unseen; but nothing else, so a name stays as
    /// it's written, backticks it starts with included.
    public static func inLine(_ text: String) -> String {
        var line = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": line += "\\n"
            case "\r": line += "\\r"
            case "\t": line += "\\t"
            default:
                if isControl(scalar) {
                    line += escaped(scalar)
                } else {
                    line.unicodeScalars.append(scalar)
                }
            }
        }
        return line
    }

    /// Text quoted as it was written, line by line: in a fence nothing in it closes (`fence(for:)`), each line indented by
    /// `indent`, with its other characters that control how text reads, a carriage return among them, written out as
    /// escapes that can be told from what was written (`writingOut`), so that all of it stays what was said, whatever it
    /// says, and can be had back as it was. Tabs stay, which code has.
    public static func fenced(_ text: String, indent: String = "") -> [String] {
        let scalars = lines(of: text)
        let writeOut = writingOut(for: scalars)
        let lines = scalars.map { (line: [Unicode.Scalar]) -> String in
            var kept = String.UnicodeScalarView()
            for scalar in line {
                if scalar != "\t", isControl(scalar) {
                    kept.append(contentsOf: writeOut(scalar).unicodeScalars)
                } else {
                    kept.append(scalar)
                }
            }
            return String(kept)
        }
        let fence = indent + fence(for: lines.joined(separator: "\n"))
        var fenced = [fence]
        fenced += lines.map { (line: String) -> String in line.isEmpty ? "" : indent + line }
        fenced.append(fence)
        return fenced
    }

    /// A backtick fence that nothing in `text` closes, so all of it stays quoted, whatever it says: one longer than its
    /// longest run of backticks, and at least three, as CommonMark has it. What becomes a backtick once text is normalized,
    /// such as a Greek varia (`asRead`), counts as one, and a character with no width of its own between two of them,
    /// such as a joiner, an accent or a variation selector, doesn't end their run, since nobody sees it, and a model may not
    /// either.
    public static func fence(for text: String) -> String {
        var longest = 0
        var run = 0
        for scalar in text.unicodeScalars where !hasNoWidth(scalar) {
            for read in asRead(scalar) {
                if read == "`" {
                    run += 1
                    longest = max(longest, run)
                } else {
                    run = 0
                }
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    /// The characters `fenced` writes out of `text` as escapes, each once, in the order they first come, as it writes them:
    /// "\u{200B}", or "⟦U+200B⟧" in text that spells out the first itself (`writingOut`). Empty when it writes none. Read
    /// from the same lines `fenced` writes (`lines(of:)`).
    public static func writtenOut(in text: String) -> [String] {
        let lines = lines(of: text)
        let writeOut = writingOut(for: lines)
        var seen: Set<Unicode.Scalar> = []
        var written: [String] = []
        for scalar in lines.joined() where scalar != "\t" && isControl(scalar) && seen.insert(scalar).inserted {
            written.append(writeOut(scalar))
        }
        return written
    }

    /// A text's lines, as a fence quotes them, by their scalars: split at each line feed, with a carriage return right
    /// before one taken as part of the break. Any other carriage return, such as a stray one before "\r\n", stays in its
    /// line, to be written out.
    private static func lines(of text: String) -> [[Unicode.Scalar]] {
        var lines: [[Unicode.Scalar]] = [[]]
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if lines[lines.count - 1].last == "\r" { lines[lines.count - 1].removeLast() }
                lines.append([])
            } else {
                lines[lines.count - 1].append(scalar)
            }
        }
        return lines
    }

    /// How `fenced` writes out a character nobody sees in its lines, so that what it wrote out can always be told from
    /// what was written, and the text had back from it: "\u{200B}", unless a line spells out "\u{" itself, as code that
    /// writes a character that way does; then "⟦U+200B⟧", or, when a line spells that out too, "⟦1U+200B⟧", "⟦2U+200B⟧"
    /// and on, with the first number none has. What a line spells out is what a model reads of it (`asRead`): without what
    /// nobody sees, such as a combining grapheme joiner after the brace, and with what becomes a backslash, a digit or a
    /// brace once normalized, such as their fullwidth forms, as that, a circled ten as "10", and a digit of another script
    /// as that digit. The numbers are read in one pass, whatever it says.
    private static func writingOut(for lines: [[Unicode.Scalar]]) -> (Unicode.Scalar) -> String {
        let read = lines.map { $0.filter { !hasNoWidth($0) && !isControl($0) }.flatMap(asRead) }
        guard read.contains(where: { spells(["\\", "u", "{"], in: $0) }) else { return escaped }
        // The numbers of the openings the lines spell out, each as its digits: "" for none.
        var taken: Set<String> = []
        for line in read {
            for open in line.indices where line[open] == "⟦" {
                var end = open + 1
                while end < line.count, ("0"..."9").contains(line[end]) { end += 1 }
                if line[end...].starts(with: ["U", "+"]) {
                    taken.insert(String(String.UnicodeScalarView(line[(open + 1)..<end])))
                }
            }
        }
        var number = 0
        while taken.contains(number == 0 ? "" : String(number)) { number += 1 }
        let opening = "⟦" + (number == 0 ? "" : String(number)) + "U+"
        return { opening + String($0.value, radix: 16, uppercase: true) + "⟧" }
    }

    /// Whether `line` has `word` in it, scalar for scalar.
    private static func spells(_ word: [Unicode.Scalar], in line: [Unicode.Scalar]) -> Bool {
        guard line.count >= word.count else { return false }
        return (0...(line.count - word.count)).contains { line[$0..<($0 + word.count)].elementsEqual(word) }
    }

    /// A word for a shell, as a command in a prompt holds it, such as a branch's name: as it is when it's only ASCII
    /// letters, digits and `_./+@,:-`, which no shell reads as anything else, or else in single quotes, so that a command
    /// written with it, by the prompt or by whoever follows it, runs nothing it says, such as `$(…)`. In a word, as in
    /// `origin/'a$(b)'`, it stays one argument.
    public static func shellWord(_ text: String) -> String {
        let plain = !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || "_./+@,:-".unicodeScalars.contains(scalar)
        }
        return plain ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A word a prompt writes in a sentence or in a command, such as a branch's name, which whoever made the branch chose:
    /// in single quotes when a shell would read something in it (`shellWord`). Quoted, it starts with its quote, which no
    /// fence starts with, so a name that starts with backticks, as Git allows, keeps them, and a command names that branch.
    /// One with a character that `inLine` writes out, one nobody sees or that breaks a line, such as a zero-width space,
    /// which Git allows in a branch's name too, is in ANSI-C quotes instead, with that character as its bytes in hex,
    /// `$'fix\xE2\x80\x8B'` (`ansiCWord`): all of it is seen, on its line, and a shell reads it back as the name itself,
    /// so a command names that branch all the same. Empty stays empty.
    public static func commandWord(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text.unicodeScalars.contains(where: isControl) ? ansiCWord(text) : shellWord(text)
    }

    /// A word in ANSI-C quotes, `$'…'`, as `commandWord` writes one with a character nobody sees: that character as its
    /// UTF-8 bytes in hex, `\xE2\x80\x8B`, which bash, macOS's 3.2 too (it has no `\u` there), zsh and sh read back byte
    /// for byte; a backslash and a quote escaped, `\\` and `\'`; anything else as it is, which nothing in these quotes
    /// runs, `$(…)` and backticks included. But NUL, which no shell can pass in a word, so that it would cut the name short
    /// there, "main\0x" naming main: it's written out as text, `\u{0}`, as `inLine` writes it, which no branch's name can
    /// hold, so a command made with it names no branch at all.
    private static func ansiCWord(_ text: String) -> String {
        var word = "$'"
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": word += "\\\\"
            case "'": word += "\\'"
            case "\0": word += "\\\\u{0}"
            default:
                if isControl(scalar) {
                    word += String(scalar).utf8.map { String(format: "\\x%02X", $0) }.joined()
                } else {
                    word.unicodeScalars.append(scalar)
                }
            }
        }
        return word + "'"
    }

    /// A line that may open a fence (`fenceStart`) or a block of HTML (`htmlStart`), with the character that would open it
    /// written out, so it opens none. Any other line as it is.
    private static func withoutBlockAtStart(_ line: String) -> String {
        let scalars = line.unicodeScalars
        guard let start = fenceStart(in: scalars) ?? htmlStart(in: scalars) else { return line }
        var kept = String.UnicodeScalarView(scalars[..<start])
        kept.append(contentsOf: escaped(scalars[start]).unicodeScalars)
        kept.append(contentsOf: scalars[scalars.index(after: start)...])
        return String(kept)
    }

    /// Whether a line may open a fence, as CommonMark reads one in a list or a quote, or as a model may read it
    /// (`fenceStart`): a reader that goes by what's outside a prompt's fences can stop there, whatever pairs it with what.
    public static func mayOpenFence(_ line: some StringProtocol) -> Bool {
        fenceStart(in: line.unicodeScalars) != nil
    }

    /// Where the fence a line may open starts: the character that starts three backticks or tildes or more, with what has
    /// no width between them too, as a model may read them (`reading`), a Greek varia as a backtick, say. Nil when it may
    /// open none.
    private static func fenceStart<Line: BidirectionalCollection>(in line: Line) -> Line.Index? where Line.Element == Unicode.Scalar {
        var characters = reading(line).makeIterator()
        guard let first = characters.next(), first.read == "`" || first.read == "~" else { return nil }
        var count = 1
        while let next = characters.next(), next.read == first.read { count += 1 }
        return count >= 3 ? first.index : nil
    }

    /// Where the block of HTML a line may open starts: a `<` before `!`, `?`, `/` or a letter, as a comment, "<!--", a
    /// declaration, "<!DOCTYPE", CDATA, a processing instruction, "<?", or a tag, "<div" or "</p", starts one, which
    /// CommonMark reads until the comment closes or a blank line, a fence's line in it too, as a model may read it
    /// (`reading`): "＜!--" too. Any other `<` stays, as in "<3" or "<= 5". Nil when it may open none.
    private static func htmlStart<Line: BidirectionalCollection>(in line: Line) -> Line.Index? where Line.Element == Unicode.Scalar {
        var characters = reading(line).makeIterator()
        guard let first = characters.next(), first.read == "<", let next = characters.next() else { return nil }
        let opens = "!?/".unicodeScalars.contains(next.read) || ("a"..."z").contains(next.read) || ("A"..."Z").contains(next.read)
        return opens ? first.index : nil
    }

    /// A line as a model may read it (`asRead`), from where a fence or a block of HTML may start: past what reads as space
    /// or isn't seen, a no-break space or a joiner, say, and what a list's or a quote's marker is made of, `>`, `-`, `+`,
    /// `*`, digits, `.` and `)`, as in "- ```" or "> 1. <!--", where CommonMark reads either in a list or a quote, read the
    /// same way: "＞ ```", "⒈ ~~~" ("1. ~~~") or "⑩) ```". Each character it reads, with where it is in the line; what has
    /// no width is left out, so that what's on either side of it reads as one.
    private static func reading<Line: BidirectionalCollection>(_ line: Line) -> some Sequence<(index: Line.Index, read: Unicode.Scalar)>
    where Line.Element == Unicode.Scalar {
        line.indices.lazy
            .filter { !hasNoWidth(line[$0]) }
            .flatMap { index in asRead(line[index]).lazy.map { (index: index, read: $0) } }
            .drop { $0.read.properties.isWhitespace || ">-+*.)0123456789".unicodeScalars.contains($0.read) }
    }

    /// A character as a model may read it: what it becomes once text is normalized, when that's ASCII, a character or
    /// more, such as a fullwidth digit, brace or tilde, a Greek varia (a backtick canonically), "⒈" ("1.") or "⑩" ("10");
    /// a digit of another script as that digit, "١" as "1"; any other as it is. Only a character outside ASCII is looked
    /// up, and normalized only when that changes it, so most text costs little.
    static func asRead(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        guard !scalar.isASCII else { return [scalar] }
        let properties = scalar.properties
        if properties.numericType == .decimal, let value = properties.numericValue, (0...9).contains(value) {
            return [Unicode.Scalar(UInt8(48 + Int(value)))]
        }
        guard properties.changesWhenNFKCCaseFolded else { return [scalar] }
        let normalized = String(scalar).precomposedStringWithCompatibilityMapping.unicodeScalars
        guard normalized.allSatisfy(\.isASCII) else { return [scalar] }
        return Array(normalized)
    }

    /// A character written out as an escape: "\u{202E}".
    private static func escaped(_ scalar: Unicode.Scalar) -> String {
        "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
    }

    /// A character that controls how text reads, or hides text, rather than being seen: a control character, a line or
    /// paragraph separator, and an invisible one that formats text, such as a mark, override or isolate of the direction
    /// text reads in, or a tag, which a model may read as text that nobody sees ("ASCII smuggling"); but not the joiners
    /// words and emoji are written with. And the variation selectors past those of emoji, which can hide text the same way.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        case .format: return scalar != "\u{200C}" && scalar != "\u{200D}"
        default: return (0xE0000...0xE007F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value)
        }
    }

    /// A character drawn with no width of its own: a mark on the one before it, an invisible one that formats text, or one
    /// Unicode says to ignore where it can't be shown.
    private static func hasNoWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return true
        default: return scalar.properties.isDefaultIgnorableCodePoint
        }
    }
}
