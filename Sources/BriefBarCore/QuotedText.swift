import Foundation

/// Text a prompt for Copilot quotes from where others write, such as a comment, a test's name, a file's path or a work
/// item's title, so that none of it reads as the prompt's own, whatever it says: on one of the prompt's lines (`oneLine`),
/// or in a fence nothing in it closes (`fenced`), with what controls how text reads, or hides text, written out as
/// escapes. A pull request's prompts and a work item's use it alike.
public enum QuotedText {
    /// Text quoted on one of a prompt's lines: its line breaks, and characters that control how text reads or hide text,
    /// written out as escapes, "\n", "\u{202E}" (`isControl`), so that all of it stays on that line, nothing in it starts a
    /// line of the prompt's own, and nothing in it is unseen. Nor does it start with a fence, three backticks or tildes or
    /// more, which would open one where it starts a line, as a name does before what its author said: the first is written
    /// out, "\u{60}".
    public static func oneLine(_ text: String) -> String {
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
        return withoutFenceAtStart(line)
    }

    /// Text quoted as it was written, line by line: in a fence nothing in it closes (`fence(for:)`), each line indented by
    /// `indent`, with its other characters that control how text reads, a carriage return among them, written out as
    /// escapes, so that all of it stays what was said, whatever it says. Tabs stay, which code has.
    public static func fenced(_ text: String, indent: String = "") -> [String] {
        let all = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        let lines = all.map { (line: Substring) -> String in
            var kept = ""
            for scalar in line.unicodeScalars {
                if scalar != "\t", isControl(scalar) {
                    kept += escaped(scalar)
                } else {
                    kept.unicodeScalars.append(scalar)
                }
            }
            return kept
        }
        let fence = indent + fence(for: lines.joined(separator: "\n"))
        var fenced = [fence]
        fenced += lines.map { (line: String) -> String in line.isEmpty ? "" : indent + line }
        fenced.append(fence)
        return fenced
    }

    /// A backtick fence that nothing in `text` closes, so all of it stays quoted, whatever it says: one longer than its
    /// longest run of backticks, and at least three, as CommonMark has it. A character with no width of its own between
    /// two backticks, such as a joiner, an accent or a variation selector, doesn't end their run, since nobody sees it, and
    /// a model may not either.
    public static func fence(for text: String) -> String {
        var longest = 0
        var run = 0
        for scalar in text.unicodeScalars {
            if scalar == "`" {
                run += 1
                longest = max(longest, run)
            } else if !hasNoWidth(scalar) {
                run = 0
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
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
    /// in single quotes when a shell would read something in it (`shellWord`), then on its line (`oneLine`). Quoted, it
    /// starts with its quote, which no fence starts with, so a name that starts with backticks, as Git allows, keeps them,
    /// and a command names that branch. Empty stays empty.
    public static func commandWord(_ text: String) -> String {
        text.isEmpty ? text : oneLine(shellWord(text))
    }

    /// A line that starts, after its spaces, with three backticks or tildes or more, as a fence does, those with no width
    /// between them too, with the first of them written out, so it opens none. Any other line as it is.
    private static func withoutFenceAtStart(_ line: String) -> String {
        let scalars = line.unicodeScalars
        guard let start = scalars.firstIndex(where: { $0 != " " }), scalars[start] == "`" || scalars[start] == "~" else { return line }
        let mark = scalars[start]
        var count = 0
        for scalar in scalars[start...] {
            if scalar == mark {
                count += 1
            } else if !hasNoWidth(scalar) {
                break
            }
        }
        guard count >= 3 else { return line }
        var kept = String.UnicodeScalarView(scalars[..<start])
        kept.append(contentsOf: escaped(mark).unicodeScalars)
        kept.append(contentsOf: scalars[scalars.index(after: start)...])
        return String(kept)
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
