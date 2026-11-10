import Foundation

/// A shell script read into its simple commands, as far as `PushCommand` needs to tell what it runs: every simple command
/// in it, at any depth, in substitutions, subshells and here-documents' expansions too, in one list, each with its words,
/// as the shell passes them, and what it reads from a here-document or a here-string. It reads quotes, single, double and
/// ANSI-C (`$'…'`, which `QuotedText.commandWord` writes a branch's name in when it has a character nobody sees),
/// backslashes, comments, `;`, `&&`, `||`, `|`, `&`, parentheses, redirections, `$(…)`, backticks, `<(…)` and
/// here-documents, but expands nothing: a word with a variable, a substitution, a pattern (`*`, `?`, or `[` with a `]`
/// after it), braces that expand (with a `,` or `..` in them) or `~` in it isn't literal (`PushCommand.Word.isLiteral`);
/// `[`, `[[` and `{}` on their own are.
struct ShellReader {
    struct Command {
        var words: [PushCommand.Word] = []
        /// What it reads on its standard input from a here-document or a here-string, as the shell gives it.
        var input: [PushCommand.Word] = []
    }

    /// How deep substitutions and scripts in scripts go before it gives up.
    static let deepest = 8
    /// Reserved words that a command, such as `case`, may come after on its line.
    private static let leading: Set<String> = ["!", "if", "then", "elif", "else", "do", "while", "until", "time"]

    /// A here-document whose body comes after its line.
    private struct Heredoc {
        var command: Int
        var delimiter: [UInt8]
        /// `<<-`: tabs at its lines' start go.
        var stripsTabs: Bool
        /// Its delimiter was quoted, so its body is as it's written; else its substitutions run.
        var isQuoted: Bool
    }

    private let bytes: [UInt8]
    private var index = 0
    /// How deep the script it reads is in another's.
    private let depth: Int
    /// How many substitutions it's in now, within its script.
    private var nesting = 0
    private(set) var commands: [Command] = []
    private var failed = false

    private init(bytes: [UInt8], depth: Int) {
        self.bytes = bytes
        self.depth = depth
    }

    /// The simple commands in `text`, at `depth` in another script, and whether it could read all of it: not with a quote,
    /// a substitution or braces that don't close, or scripts nested deeper than `deepest`. What it read before then is
    /// there all the same.
    static func read(_ text: String, depth: Int = 0) -> (commands: [Command], isReadable: Bool) {
        var reader = ShellReader(bytes: Array(text.utf8), depth: depth)
        let read = depth <= deepest && reader.script(closedByParenthesis: false)
        return (reader.commands.filter { !$0.words.isEmpty || !$0.input.isEmpty }, read && !reader.failed)
    }

    // MARK: Scripts

    /// Reads commands until the end, or, in a substitution, until the parenthesis that closes it, which it reads too. False
    /// when it can't.
    private mutating func script(closedByParenthesis: Bool) -> Bool {
        var current = begin()
        var heredocs: [Heredoc] = []
        var parentheses = 0
        // `case` statements begun and not ended yet, whose patterns end with a `)` that closes nothing.
        var cases = 0
        while index < bytes.count {
            switch bytes[index] {
            case .space, .tab:
                index += 1
            case .backslash where index + 1 < bytes.count && bytes[index + 1] == .newline:
                // A line that goes on.
                index += 2
            case .newline:
                index += 1
                if !heredocs.isEmpty {
                    guard readBodies(heredocs) else { return false }
                    heredocs = []
                }
                current = begin()
            case .semicolon, .pipe:
                // ;, ;;, ;&, |, ||, |&: the next command.
                index += 1
                while index < bytes.count, [.semicolon, .pipe, .ampersand].contains(bytes[index]), !startsRedirection(at: index) {
                    index += 1
                }
                current = begin()
            case .ampersand where startsRedirection(at: index):
                // &> and &>>: output and errors to a file.
                guard redirection(into: current, heredocs: &heredocs) else { return false }
            case .ampersand:
                index += 1
                if index < bytes.count, bytes[index] == .ampersand { index += 1 }
                current = begin()
            case .openParenthesis:
                index += 1
                parentheses += 1
                current = begin()
            case .closeParenthesis:
                index += 1
                if parentheses == 0 {
                    // The end of the substitution it's in: not one whose here-document's body hasn't come yet, nor in a
                    // `case`, where it may end a pattern, as in `$(case $x in y) git push;; esac)`, which BriefBar doesn't
                    // read. Anywhere else, a parenthesis that closes nothing, which a shell refuses.
                    return closedByParenthesis && heredocs.isEmpty && cases == 0
                }
                parentheses -= 1
                current = begin()
            case .hash:
                // A comment, to the end of its line.
                while index < bytes.count, bytes[index] != .newline { index += 1 }
            case let byte:
                if (byte == .less || byte == .greater) && !startsProcessSubstitution(at: index) {
                    guard redirection(into: current, heredocs: &heredocs) else { return false }
                } else if (byte == .openBrace || byte == .closeBrace) && endsWord(at: index + 1)
                            && commands[current].words.allSatisfy({ $0.isLiteral && Self.leading.contains($0.value) }) {
                    // `{` and `}` on their own, where a command starts, group commands; elsewhere, as in
                    // `git push origin main {`, they're words like any other.
                    index += 1
                    current = begin()
                } else if let descriptor = descriptorEnd(at: index) {
                    // 2>&1: a redirection of a descriptor, by its number.
                    index = descriptor
                    guard redirection(into: current, heredocs: &heredocs) else { return false }
                } else {
                    guard let word = readWord() else { return false }
                    if !word.isQuoted, word.word.isLiteral, commands[current].words.allSatisfy({ $0.isLiteral && Self.leading.contains($0.value) }) {
                        if word.word.value == "case" { cases += 1 }
                        if word.word.value == "esac", cases > 0 { cases -= 1 }
                    }
                    commands[current].words.append(word.word)
                }
            }
        }
        // A substitution that doesn't close can't be read. A here-document still to come has no body, as a shell reads it.
        return !closedByParenthesis
    }

    /// A new simple command, in the list: its place there.
    private mutating func begin() -> Int {
        commands.append(Command())
        return commands.count - 1
    }

    /// A substitution, `$(…)` or `<(…)`, past its opening parenthesis: its commands, up to the one that closes it.
    private mutating func substitution() -> Bool {
        guard depth + nesting < Self.deepest else {
            failed = true
            return false
        }
        nesting += 1
        defer { nesting -= 1 }
        return script(closedByParenthesis: true)
    }

    /// A script of its own, such as one in backticks once its escapes are read: its commands, in this list.
    private mutating func nestedScript(_ script: [UInt8]) -> Bool {
        guard depth + nesting < Self.deepest else {
            failed = true
            return false
        }
        var reader = ShellReader(bytes: script, depth: depth + nesting + 1)
        let read = reader.script(closedByParenthesis: false)
        commands += reader.commands
        return read && !reader.failed
    }

    // MARK: Redirections

    /// A redirection, at its `<`, `>` or `&>`, past any descriptor's number before it: the file it names, which isn't an
    /// argument; a here-string, which is the command's input; or a here-document, whose body comes after its line.
    private mutating func redirection(into command: Int, heredocs: inout [Heredoc]) -> Bool {
        if bytes[index] == .ampersand { index += 1 }
        let first = bytes[index]
        index += 1
        if first == .less, index < bytes.count, bytes[index] == .less {
            index += 1
            if index < bytes.count, bytes[index] == .less {
                // <<< word
                index += 1
                skipBlanks()
                guard !endsWord(at: index), let word = readWord() else { return false }
                commands[command].input.append(word.word)
                return true
            }
            // << or <<-, then the delimiter.
            let stripsTabs = index < bytes.count && bytes[index] == .minus
            if stripsTabs { index += 1 }
            skipBlanks()
            guard !endsWord(at: index), let delimiter = readWord() else { return false }
            heredocs.append(Heredoc(
                command: command, delimiter: Array(delimiter.word.value.utf8), stripsTabs: stripsTabs, isQuoted: delimiter.isQuoted
            ))
            return true
        }
        // <&, <>, >>, >|, >&
        if index < bytes.count {
            let next = bytes[index]
            if next == .ampersand || (first == .greater && (next == .greater || next == .pipe)) || (first == .less && next == .greater) {
                index += 1
            }
        }
        skipBlanks()
        guard !endsWord(at: index) || startsProcessSubstitution(at: index), readWord() != nil else { return false }
        return true
    }

    /// Reads the bodies of the here-documents its line started, after that line, each to its delimiter's line, or to the end,
    /// as a shell does, with a warning: the command's input, as is when its delimiter was quoted, else with its substitutions
    /// read as commands.
    private mutating func readBodies(_ heredocs: [Heredoc]) -> Bool {
        for heredoc in heredocs {
            var body: [UInt8] = []
            while index < bytes.count {
                var line: [UInt8] = []
                while true {
                    let end = bytes[index...].firstIndex(of: .newline) ?? bytes.count
                    line += bytes[index..<end]
                    index = min(end + 1, bytes.count)
                    // An unquoted one's line goes on past a backslash at its end that no other escapes, as bash joins them
                    // before it looks for the delimiter: `EO\` and `F` make `EOF`.
                    guard !heredoc.isQuoted, end < bytes.count, Self.endsInEscape(line) else { break }
                    line.removeLast()
                }
                if heredoc.stripsTabs { line = Array(line.drop { $0 == .tab }) }
                if line.elementsEqual(heredoc.delimiter) { break }
                body += line
                body.append(.newline)
            }
            if heredoc.isQuoted {
                commands[heredoc.command].input.append(PushCommand.Word(value: String(decoding: body, as: UTF8.self), isLiteral: true))
            } else {
                guard let expanded = expanded(body) else { return false }
                commands[heredoc.command].input.append(expanded)
            }
        }
        return true
    }

    /// An unquoted here-document's body, as a shell expands it: its substitutions run, so they're read as commands of
    /// their own; its variables make it not literal.
    private mutating func expanded(_ body: [UInt8]) -> PushCommand.Word? {
        guard depth + nesting < Self.deepest else {
            failed = true
            return nil
        }
        var reader = ShellReader(bytes: body, depth: depth + nesting + 1)
        var value: [UInt8] = []
        var literal = true
        while reader.index < reader.bytes.count {
            let byte = reader.bytes[reader.index]
            switch byte {
            case .backslash where reader.index + 1 < reader.bytes.count
                && [.dollar, .backtick, .backslash, .newline].contains(reader.bytes[reader.index + 1]):
                let next = reader.bytes[reader.index + 1]
                if next != .newline { value.append(next) }
                reader.index += 2
            case .dollar:
                var quoted = true
                guard reader.dollar(&value, &literal, &quoted, inDoubleQuotes: true) else { return nil }
            case .backtick:
                guard reader.backticks(&value, inDoubleQuotes: false) else { return nil }
                literal = false
            default:
                value.append(byte)
                reader.index += 1
            }
        }
        commands += reader.commands
        guard !reader.failed else { return nil }
        return PushCommand.Word(value: String(decoding: value, as: UTF8.self), isLiteral: literal)
    }
}

extension ShellReader {
    // MARK: Words

    /// A word, from where it starts to the first blank or operator outside quotes: its value, with quotes and escapes
    /// taken out, whether it's literal, and whether any of it was quoted, which makes a here-document's body as written.
    /// Nil when it can't be read, as with a quote that doesn't close.
    private mutating func readWord() -> (word: PushCommand.Word, isQuoted: Bool)? {
        var value: [UInt8] = []
        var literal = true
        var quoted = false
        // Where an unquoted `[` or `{` is in its value, if there is one: a pattern once a `]` follows the `[`, braces that
        // expand once a `}` follows the `{` with a `,` or `..` between them.
        var bracket: Int?
        var brace: Int?
        // `~` at its start is a home folder.
        if index < bytes.count, bytes[index] == .tilde { literal = false }
        scanning: while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case .space, .tab, .newline, .semicolon, .ampersand, .pipe, .openParenthesis, .closeParenthesis:
                break scanning
            case .less, .greater:
                guard startsProcessSubstitution(at: index) else { break scanning }
                // <(…) or >(…): a command whose output, or input, is a file named here.
                let start = index
                index += 2
                guard substitution() else { return nil }
                value += bytes[start..<index]
                literal = false
            case .backslash:
                if index + 1 >= bytes.count {
                    value.append(byte)
                    index += 1
                } else if bytes[index + 1] == .newline {
                    // A line that goes on.
                    index += 2
                } else {
                    value.append(bytes[index + 1])
                    index += 2
                    quoted = true
                }
            case .singleQuote:
                guard let end = bytes[(index + 1)...].firstIndex(of: .singleQuote) else { return nil }
                value += bytes[(index + 1)..<end]
                index = end + 1
                quoted = true
            case .doubleQuote:
                index += 1
                quoted = true
                guard doubleQuoted(&value, &literal) else { return nil }
            case .dollar:
                guard dollar(&value, &literal, &quoted, inDoubleQuotes: false) else { return nil }
            case .backtick:
                guard backticks(&value, inDoubleQuotes: false) else { return nil }
                literal = false
            case .asterisk, .questionMark:
                // A pattern, which may match files' names.
                value.append(byte)
                index += 1
                literal = false
            case .openBracket, .openBrace:
                if byte == .openBracket { bracket = bracket ?? value.count } else { brace = brace ?? value.count }
                value.append(byte)
                index += 1
            default:
                value.append(byte)
                index += 1
            }
        }
        if let bracket, value[bracket...].contains(.closeBracket) { literal = false }
        if let brace, let close = value[brace...].lastIndex(of: .closeBrace) {
            let inside = value[brace..<close]
            if inside.contains(.comma) || zip(inside, inside.dropFirst()).contains(where: { $0 == .period && $1 == .period }) {
                literal = false
            }
        }
        return (PushCommand.Word(value: String(decoding: value, as: UTF8.self), isLiteral: literal), quoted)
    }

    /// What's in double quotes, past the one that opens them, up to the one that closes them: false when none does.
    private mutating func doubleQuoted(_ value: inout [UInt8], _ literal: inout Bool) -> Bool {
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case .doubleQuote:
                index += 1
                return true
            case .backslash:
                guard index + 1 < bytes.count else { return false }
                let next = bytes[index + 1]
                if next == .newline {
                    index += 2
                } else if [.dollar, .backtick, .doubleQuote, .backslash].contains(next) {
                    value.append(next)
                    index += 2
                } else {
                    value.append(byte)
                    index += 1
                }
            case .dollar:
                var quoted = true
                guard dollar(&value, &literal, &quoted, inDoubleQuotes: true) else { return false }
            case .backtick:
                guard backticks(&value, inDoubleQuotes: true) else { return false }
                literal = false
            default:
                value.append(byte)
                index += 1
            }
        }
        return false
    }

    /// What a `$` starts: ANSI-C quotes, `$'…'`, read to what they say; a translated string, `$"…"`, read as double
    /// quotes; a substitution, `$(…)` or `$((…))`, whose commands are read; a parameter, `${…}` or `$name`, which isn't
    /// literal; or else a `$` as it is.
    private mutating func dollar(_ value: inout [UInt8], _ literal: inout Bool, _ quoted: inout Bool, inDoubleQuotes: Bool) -> Bool {
        let start = index
        guard index + 1 < bytes.count else {
            value.append(.dollar)
            index += 1
            return true
        }
        let next = bytes[index + 1]
        switch next {
        case .singleQuote where !inDoubleQuotes:
            index += 2
            quoted = true
            return ansiC(&value, &literal)
        case .doubleQuote where !inDoubleQuotes:
            index += 1
            return true
        case .openParenthesis:
            index += 2
            guard substitution() else { return false }
        case .openBrace:
            index += 2
            guard braced(inDoubleQuotes: inDoubleQuotes) else { return false }
        default:
            if Self.isNameStart(next) {
                index += 2
                while index < bytes.count, Self.isNameStart(bytes[index]) || Self.isDigit(bytes[index]) { index += 1 }
            } else if Self.isDigit(next) || Array("@*#?$!-".utf8).contains(next) {
                index += 2
            } else {
                value.append(.dollar)
                index += 1
                return true
            }
        }
        value += bytes[start..<index]
        literal = false
        return true
    }

    /// A parameter's braces, past `${`, to the one that closes them, with what's quoted or substituted in them.
    private mutating func braced(inDoubleQuotes: Bool) -> Bool {
        var depth = 1
        var scratch: [UInt8] = []
        var literal = true
        var quoted = false
        while index < bytes.count {
            switch bytes[index] {
            case .backslash:
                index += 2
            case .singleQuote where inDoubleQuotes:
                // In double quotes, as `"${X:-'$(…)'}"`, a single quote is only itself: what's after it is read, and runs.
                index += 1
            case .singleQuote:
                guard let end = bytes[(index + 1)...].firstIndex(of: .singleQuote) else { return false }
                index = end + 1
            case .doubleQuote:
                index += 1
                guard doubleQuoted(&scratch, &literal) else { return false }
            case .dollar:
                // In double quotes still, as a default in a default: `"${X:-${Y:-'$(…)'}}"`.
                guard dollar(&scratch, &literal, &quoted, inDoubleQuotes: inDoubleQuotes) else { return false }
            case .backtick:
                guard backticks(&scratch, inDoubleQuotes: inDoubleQuotes) else { return false }
            case .openBrace:
                depth += 1
                index += 1
            case .closeBrace:
                depth -= 1
                index += 1
                if depth == 0 { return true }
            default:
                index += 1
            }
        }
        return false
    }

    /// ANSI-C quotes, past `$'`, to the quote that closes them, with their escapes read as bash and zsh read them,
    /// macOS's bash 3.2 too: `\xE2`, octal, `\n` and the others. `\u` and `\U`, which that bash doesn't read, leave the
    /// word not literal. What they say ends at a NUL they make, as `\0`, `\x00` or `\c@`, as a shell's strings do:
    /// `$'push\0…'` is `push`.
    private mutating func ansiC(_ word: inout [UInt8], _ literal: inout Bool) -> Bool {
        var value: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == .singleQuote {
                index += 1
                word += value.prefix { $0 != 0 }
                return true
            }
            guard byte == .backslash else {
                value.append(byte)
                index += 1
                continue
            }
            guard index + 1 < bytes.count else { return false }
            let escape = bytes[index + 1]
            index += 2
            switch escape {
            case UInt8(ascii: "a"): value.append(0x07)
            case UInt8(ascii: "b"): value.append(0x08)
            case UInt8(ascii: "e"), UInt8(ascii: "E"): value.append(0x1B)
            case UInt8(ascii: "f"): value.append(0x0C)
            case UInt8(ascii: "n"): value.append(0x0A)
            case UInt8(ascii: "r"): value.append(0x0D)
            case UInt8(ascii: "t"): value.append(0x09)
            case UInt8(ascii: "v"): value.append(0x0B)
            case .backslash, .singleQuote, .doubleQuote, .questionMark: value.append(escape)
            case UInt8(ascii: "x"):
                var number = 0
                var digits = 0
                while digits < 2, index < bytes.count, let digit = Self.hexValue(bytes[index]) {
                    number = number * 16 + digit
                    digits += 1
                    index += 1
                }
                if digits == 0 {
                    value += [.backslash, escape]
                } else {
                    value.append(UInt8(number))
                }
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var number = Int(escape - UInt8(ascii: "0"))
                var digits = 1
                while digits < 3, index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(bytes[index]) {
                    number = number * 8 + Int(bytes[index] - UInt8(ascii: "0"))
                    digits += 1
                    index += 1
                }
                value.append(UInt8(truncatingIfNeeded: number))
            case UInt8(ascii: "c"):
                guard index < bytes.count else { return false }
                value.append(bytes[index] & 0x1F)
                index += 1
            case UInt8(ascii: "u"), UInt8(ascii: "U"):
                value += [.backslash, escape]
                literal = false
            default:
                value += [.backslash, escape]
            }
        }
        return false
    }

    /// A substitution in backticks, at the first: its commands, once the escapes in it are read, as a script of its own.
    /// A backslash escapes `$`, a backtick and itself there, and, in double quotes, a double quote too, as bash reads it.
    private mutating func backticks(_ value: inout [UInt8], inDoubleQuotes: Bool) -> Bool {
        let start = index
        index += 1
        var script: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == .backtick {
                index += 1
                value += bytes[start..<index]
                return nestedScript(script)
            }
            if byte == .backslash, index + 1 < bytes.count,
               [.dollar, .backtick, .backslash].contains(bytes[index + 1]) || (inDoubleQuotes && bytes[index + 1] == .doubleQuote) {
                script.append(bytes[index + 1])
                index += 2
                continue
            }
            script.append(byte)
            index += 1
        }
        return false
    }

    // MARK: Where things start and end

    private mutating func skipBlanks() {
        while index < bytes.count, [.space, .tab].contains(bytes[index]) { index += 1 }
    }

    /// A line ends in a backslash that no other escapes: an odd number of them.
    private static func endsInEscape(_ line: [UInt8]) -> Bool {
        line.reversed().prefix { $0 == .backslash }.count % 2 == 1
    }

    /// Nothing at `position` goes on a word: the end, a blank, or an operator that isn't a process substitution.
    private func endsWord(at position: Int) -> Bool {
        guard position < bytes.count else { return true }
        return [.space, .tab, .newline, .semicolon, .ampersand, .pipe, .openParenthesis, .closeParenthesis,
                .less, .greater].contains(bytes[position])
    }

    /// `&>` at `position`.
    private func startsRedirection(at position: Int) -> Bool {
        bytes[position] == .ampersand && position + 1 < bytes.count && bytes[position + 1] == .greater
    }

    /// `<(` or `>(` at `position`.
    private func startsProcessSubstitution(at position: Int) -> Bool {
        position + 1 < bytes.count && (bytes[position] == .less || bytes[position] == .greater)
            && bytes[position + 1] == .openParenthesis
    }

    /// Where a descriptor's number that starts a redirection ends, as `2` in `2>&1`: nil when `position` starts none.
    private func descriptorEnd(at position: Int) -> Int? {
        var end = position
        while end < bytes.count, Self.isDigit(bytes[end]) { end += 1 }
        guard end > position, end < bytes.count, bytes[end] == .less || bytes[end] == .greater,
              !startsProcessSubstitution(at: end) else { return nil }
        return end
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func isNameStart(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || byte == UInt8(ascii: "_")
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): Int(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): Int(byte - UInt8(ascii: "A")) + 10
        default: nil
        }
    }
}

fileprivate extension UInt8 {
    static let tab = UInt8(ascii: "\t")
    static let newline = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let semicolon = UInt8(ascii: ";")
    static let pipe = UInt8(ascii: "|")
    static let ampersand = UInt8(ascii: "&")
    static let openParenthesis = UInt8(ascii: "(")
    static let closeParenthesis = UInt8(ascii: ")")
    static let less = UInt8(ascii: "<")
    static let greater = UInt8(ascii: ">")
    static let hash = UInt8(ascii: "#")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let openBracket = UInt8(ascii: "[")
    static let closeBracket = UInt8(ascii: "]")
    static let comma = UInt8(ascii: ",")
    static let period = UInt8(ascii: ".")
    static let backslash = UInt8(ascii: "\\")
    static let singleQuote = UInt8(ascii: "'")
    static let doubleQuote = UInt8(ascii: "\"")
    static let dollar = UInt8(ascii: "$")
    static let backtick = UInt8(ascii: "`")
    static let asterisk = UInt8(ascii: "*")
    static let questionMark = UInt8(ascii: "?")
    static let tilde = UInt8(ascii: "~")
    static let minus = UInt8(ascii: "-")
}
