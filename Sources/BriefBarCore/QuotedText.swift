import Foundation

/// Text a prompt for Copilot quotes from where others write, such as a comment, a test's name, a file's path or a work
/// item's title, so that none of it reads as the prompt's own, whatever it says: on one of the prompt's lines (`oneLine`),
/// or in a fence nothing in it closes (`fenced`), with what controls how text reads, or hides text, written out as
/// escapes. A pull request's prompts and a work item's use it alike.
public enum QuotedText {
    /// Text quoted on one of a prompt's lines: its line breaks, and characters that control how text reads or hide text,
    /// written out as escapes (`inLine`), so that all of it stays on that line, nothing in it starts a line of the prompt's
    /// own, and nothing in it is unseen. Nor does it start with a fence, three backticks or tildes or more, which would open
    /// one where it starts a line, as a name does before what its author said, after a space or a joiner or not, or after
    /// a list's or a quote's marker, "- ```": the first is written out, "\u{60}" (`withoutFenceAtStart`).
    public static func oneLine(_ text: String) -> String {
        withoutFenceAtStart(inLine(text))
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
    /// such as a Greek varia (`fenceMark`), counts as one, and a character with no width of its own between two of them,
    /// such as a joiner, an accent or a variation selector, doesn't end their run, since nobody sees it, and a model may not
    /// either.
    public static func fence(for text: String) -> String {
        var longest = 0
        var run = 0
        for scalar in text.unicodeScalars {
            if fenceMark(scalar) == "`" {
                run += 1
                longest = max(longest, run)
            } else if !hasNoWidth(scalar) {
                run = 0
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
    /// brace once normalized, such as their fullwidth forms, as that. The numbers are read in one pass, whatever it says.
    private static func writingOut(for lines: [[Unicode.Scalar]]) -> (Unicode.Scalar) -> String {
        let read = lines.map { $0.filter { !hasNoWidth($0) && !isControl($0) }.map(asRead) }
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
    /// in single quotes when a shell would read something in it (`shellWord`), then on its line (`inLine`). Quoted, it
    /// starts with its quote, which no fence starts with, so a name that starts with backticks, as Git allows, keeps them,
    /// and a command names that branch. Empty stays empty.
    public static func commandWord(_ text: String) -> String {
        text.isEmpty ? text : inLine(shellWord(text))
    }

    /// A line that may open a fence (`fenceStart`), with the first of its fence's backticks or tildes written out, so it
    /// opens none. Any other line as it is.
    private static func withoutFenceAtStart(_ line: String) -> String {
        let scalars = line.unicodeScalars
        guard let start = fenceStart(in: scalars) else { return line }
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

    /// Where the fence a line may open starts: the first of three backticks or tildes or more, those with no width between
    /// them too, and what becomes a backtick or a tilde once text is normalized counted as one (`fenceMark`), as a model
    /// may read it. Before them may be anything that reads as space or isn't seen, a no-break space or a joiner, say, and
    /// what a list's or a quote's marker is made of, `>`, `-`, `+`, `*`, digits, `.` and `)`, as in "- ```" or "> 1. ~~~",
    /// which CommonMark reads as a fence in a list or a quote, or what becomes one once normalized, a fullwidth `＞` say.
    /// Nil when it may open none.
    private static func fenceStart<Line: BidirectionalCollection>(in line: Line) -> Line.Index? where Line.Element == Unicode.Scalar {
        let markers = ">-+*.)0123456789".unicodeScalars
        guard let start = line.firstIndex(where: { !$0.properties.isWhitespace && !hasNoWidth($0) && !markers.contains(asRead($0)) }),
              let mark = fenceMark(line[start])
        else { return nil }
        var count = 0
        for scalar in line[start...] {
            if fenceMark(scalar) == mark {
                count += 1
            } else if !hasNoWidth(scalar) {
                break
            }
        }
        return count >= 3 ? start : nil
    }

    /// The fence character a character is, or becomes once text is normalized, as a model may read it (`asRead`): a
    /// backtick for a backtick, a Greek varia (U+1FEF, which is one canonically) or a fullwidth grave accent (U+FF40); a
    /// tilde for a tilde or a fullwidth one (U+FF5E). Nil for any other.
    static func fenceMark(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
        let read = asRead(scalar)
        return read == "`" || read == "~" ? read : nil
    }

    /// A character as a model may read it: one that becomes a single ASCII character once text is normalized, such as a
    /// fullwidth digit or brace, or a Greek varia, a backtick canonically, as that character; any other as it is. Only a
    /// character outside ASCII that changes once normalized is looked up, so most text costs nothing.
    static func asRead(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard !scalar.isASCII, scalar.properties.changesWhenNFKCCaseFolded else { return scalar }
        let normalized = String(scalar).precomposedStringWithCompatibilityMapping.unicodeScalars
        guard normalized.count == 1, let only = normalized.first, only.isASCII else { return scalar }
        return only
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
