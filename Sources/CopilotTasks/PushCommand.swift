import Foundation

/// The pushes in a shell command, as Push & Reply's check of each push reads them (`PushGuard`): the command Copilot is
/// about to run with its `bash` tool, read as a shell would (`ShellReader`), as far as telling whether it runs `git push`,
/// and how. It expands nothing and runs nothing, so what a variable, an alias, a script, or another language's code would
/// push is out of its reach; but a command it can't read that says `push`, as one whose quotes don't close, or that runs a
/// variable, a shell's script that comes through a pipe, or words `xargs` fills in, may push (`isUnreadable`). It reads
/// in the substitutions, subshells and here-documents a command has, the script of `sh -c`, `sh -s`, `eval`, `trap` and
/// `source /dev/stdin`, and what `env`, `xargs` and other such programs run; and a program it doesn't know that names git
/// or a shell may run it. Program names go as macOS finds them, whatever their letter case: `GIT` runs git.
public struct PushCommand: Sendable, Equatable {
    /// A word as the shell passes it: its quotes and escapes taken out.
    public struct Word: Sendable, Equatable {
        public var value: String
        /// Nothing in it expands, no variable, substitution, pattern, braces or `~`, so `value` is what the program gets.
        public var isLiteral: Bool

        public init(value: String, isLiteral: Bool = true) {
            self.value = value
            self.isLiteral = isLiteral
        }
    }

    /// A `git push` it runs, or another of git's ways to push: `git subtree push`, `git send-pack`, `git-push`.
    public struct Push: Sendable, Equatable {
        /// git's own options, before `push`: `-C <folder>`, `-c <name>=<value>` and the others, each word as it is.
        public var options: [Word]
        /// What follows `push`.
        public var arguments: [Word]
        /// It runs as written, a `git push` itself: not after `NAME=value`, not through another program, such as `env` or
        /// `xargs`, not by git's path, nor another way of git's to push.
        public var isPlain: Bool

        public init(options: [Word] = [], arguments: [Word], isPlain: Bool = true) {
            self.options = options
            self.arguments = arguments
            self.isPlain = isPlain
        }
    }

    /// The pushes it runs, as far as it can tell.
    public var pushes: [Push] = []
    /// It says `push` somewhere it can't read, so it may push otherwise.
    public var isUnreadable = false
    /// It's one simple command, with nothing else in it, at any depth: no other command before, after or around it, in
    /// a list, a pipeline, a substitution or a script it runs. Push & Reply's check lets a push through only alone, so
    /// that nothing in the same command changes what it does first, such as the folder it runs in or git's
    /// configuration.
    public var isAlone: Bool { commands == 1 }
    /// How many simple commands it has, at any depth.
    private var commands = 0

    public init(_ command: String) {
        // The shell drops the NUL bytes in what it reads, as bash does: `git pu<NUL>sh` pushes.
        var scalars = command.unicodeScalars
        scalars.removeAll { $0.value == 0 }
        read(String(scalars), depth: 0, says: false, wrapped: false)
    }

    // MARK: Reading

    /// Words that start a command without being it: `if git push …; then`.
    private static let prefixes: Set<String> = ["!", "if", "then", "elif", "else", "do", "while", "until"]
    /// Words that start what isn't a command: a loop's list, a case's word, a function's name, a test.
    private static let notCommands: Set<String> = ["for", "select", "case", "esac", "in", "function", "[[", "fi", "done"]
    /// Shells, whose `-c` runs a script, or which read one from their input.
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "csh", "tcsh"]
    /// Programs that run another, named after their own options: what they run is looked for in their words.
    private static let wrappers: Set<String> = [
        "command", "builtin", "exec", "env", "nohup", "time", "nice", "timeout", "gtimeout", "sudo", "doas", "xargs",
        "find", "caffeinate", "stdbuf", "ionice", "chronic", "watch", "unbuffer", "script", "coproc", "arch", "flock",
        "parallel", "direnv", "taskpolicy", "sandbox-exec", "xcrun", "ssh-agent",
    ]
    /// Those of them that fill in the words of what they run from their input: their own, or in place of `{}`.
    private static let fillers: Set<String> = ["xargs", "parallel", "find"]
    /// Those of them that may run a string they're given through a shell, rather than the words after it.
    private static let runStrings: Set<String> = ["parallel", "flock", "watch", "sudo", "doas", "script"]
    /// What those may run that BriefBar reads: git, its ways to push, shells and `eval`.
    private static let runners: Set<String> = shells.union(["git", "git-push", "git-send-pack", "eval"])
    /// Those of them that run the shell's own commands too, as `builtin source /dev/stdin` does, not only programs.
    private static let runBuiltins: Set<String> = ["builtin", "command", "time", "coproc"]
    /// The shell's own commands, besides `eval`, that run a script they're given, which those may run too.
    private static let scriptBuiltins: Set<String> = ["source", ".", "trap"]
    /// Variables a command git runs comes from, as `-c core.editor` gives it: an editor, a pager, ssh, a password's.
    private static let commandVariables: Set<String> = [
        "GIT_EDITOR", "GIT_SEQUENCE_EDITOR", "EDITOR", "VISUAL", "GIT_PAGER", "PAGER", "GIT_SSH_COMMAND", "GIT_SSH",
        "GIT_ASKPASS", "SSH_ASKPASS", "GIT_EXTERNAL_DIFF", "GIT_PROXY_COMMAND",
    ]
    /// Options of git's commands that take a command to run, by the command they're for: `git rebase --exec`'s, after
    /// each commit, `git difftool --extcmd`'s, for each file, and `git filter-branch`'s filters, at each commit.
    private static let commandOptions: [String: [String]] = [
        "rebase": ["-x", "--exec"],
        "difftool": ["-x", "--extcmd"],
        "filter-branch": [
            "--setup", "--env-filter", "--tree-filter", "--index-filter", "--parent-filter", "--msg-filter",
            "--commit-filter", "--tag-name-filter",
        ],
    ]
    /// Programs that only print, test or look up what they're given, and run none of it (not `man`, whose `-P` does).
    private static let runNothing: Set<String> = [
        "echo", "printf", ":", "true", "false", "test", "[", "cd", "pushd", "popd", "which", "type", "whereis", "whence",
        "help", "ls", "cat", "grep", "head", "tail", "wc",
    ]
    /// The files a shell, or `source`, reads its standard input from by.
    private static let standardInput: Set<String> = ["/dev/stdin", "/dev/fd/0"]
    /// git's options that print and stop, rather than run the command after them.
    private static let gitStops: Set<String> = ["--help", "-h", "--version", "-v", "--html-path", "--man-path", "--info-path"]
    /// git's options that take the word after them, unless they have it after `=`.
    private static let gitOptionsWithValue: Set<String> = [
        "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix", "--attr-source",
    ]
    /// git's options on their own.
    private static let gitFlags: Set<String> = [
        "-p", "--paginate", "-P", "--no-pager", "--no-replace-objects", "--no-lazy-fetch", "--no-optional-locks",
        "--no-advice", "--bare", "--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs", "--icase-pathspecs",
    ]

    /// Reads a script, at `depth` in the command, into the pushes: those it finds `wrapped` in another program aren't plain.
    /// `says`: the script it's in says `push`.
    private mutating func read(_ script: String, depth: Int, says: Bool, wrapped: Bool) {
        var says = says || script.contains("push")
        // Scripts nested deeper than BriefBar reads, which a shell runs all the same: what's in them isn't known,
        // whatever it says, as with `git pu''sh` after them.
        guard depth <= ShellReader.deepest else {
            isUnreadable = true
            return
        }
        let before = pushes.count
        let (read, isReadable, isTooDeep) = ShellReader.read(script, depth: depth)
        // What its words say once read, too: `$'pu\x73h'` is `push`.
        says = says || read.contains { command in (command.words + command.input).contains { $0.value.contains("push") } }
        if !isReadable, says || isTooDeep { isUnreadable = true }
        // git's settings from the environment, which may name an alias or turn on autocorrect, set anywhere in it; and
        // a command git runs from the environment, such as an editor, that says push.
        let setsCommands = read.contains { command in
            command.words.contains { Self.setsGitConfiguration($0) || Self.setsCommandThatPushes($0) }
        }
        if setsCommands { isUnreadable = true }
        commands += read.count
        for command in read {
            var words = command.words[...]
            var assigns = false
            // `if ! GIT_TERMINAL_PROMPT=0 git push …`: words that start a command, and the variables set for it, in any order.
            while let first = words.first {
                if Self.isAssignment(first) {
                    assigns = true
                } else if !(first.isLiteral && Self.prefixes.contains(first.value)) {
                    break
                }
                words = words.dropFirst()
            }
            guard let first = words.first, !(first.isLiteral && Self.notCommands.contains(first.value)) else { continue }
            run(Array(words), input: command.input, plain: !assigns, depth: depth, says: says)
        }
        if wrapped {
            for index in before..<pushes.count { pushes[index].isPlain = false }
        }
    }

    /// `GIT_CONFIG_COUNT=…`, `GIT_CONFIG_KEY_<n>=…`, `GIT_CONFIG_VALUE_<n>=…` or `GIT_CONFIG_PARAMETERS=…`, or `+=`:
    /// git's settings, from the environment, as `-c` gives them.
    private static func setsGitConfiguration(_ word: Word) -> Bool {
        word.value.range(of: #"^GIT_CONFIG_(COUNT|KEY_[0-9]+|VALUE_[0-9]+|PARAMETERS)\+?="#, options: .regularExpression) != nil
    }

    /// `GIT_EDITOR=…` or another of `commandVariables` set to a command that says push, like `-c core.editor=…`.
    private static func setsCommandThatPushes(_ word: Word) -> Bool {
        guard let equals = word.value.firstIndex(of: "=") else { return false }
        var name = word.value[..<equals]
        if name.hasSuffix("+") { name = name.dropLast() }
        return commandVariables.contains(String(name)) && word.value[equals...].contains("push")
    }

    /// What a command runs, by its first word. `filled`: the words that program fills in from its input, in place of
    /// which it runs this (`xargs -I {}`): `{}` and any other it names; nil when it fills in none.
    private mutating func run(_ words: [Word], input: [Word], plain: Bool, depth: Int, says: Bool, filled: Set<String>? = nil) {
        guard let first = words.first else { return }
        guard first.isLiteral else {
            // A variable or a substitution for the command: what it runs isn't known.
            if says { isUnreadable = true }
            return
        }
        let name = Self.programName(first.value)
        switch name {
        case "git":
            git(words, plain: plain && first.value == "git", depth: depth, says: says, filled: filled)
        case "git-push", "git-send-pack":
            pushes.append(Push(arguments: Array(words.dropFirst()), isPlain: false))
        case "eval":
            evaluate(Array(words.dropFirst()), plain: plain, depth: depth, says: says)
        case "trap":
            // `trap '<script>' EXIT`: its script runs later, as `eval` would run it. After `--`, it's the script
            // whatever it starts with, as in `trap -- '-x || git push' DEBUG`; before, a word that starts with `-` is
            // an option.
            var script = words.dropFirst()
            let ended = script.first?.value == "--"
            if ended { script = script.dropFirst() }
            guard let action = script.first, ended || !action.value.hasPrefix("-") || !action.isLiteral else { return }
            evaluate([action], plain: plain, depth: depth, says: says)
        case "source", ".":
            // A script, read in this shell: from its input, by /dev/stdin; a file, BriefBar doesn't read.
            var file = words.dropFirst()
            if file.first?.value == "--" { file = file.dropFirst() }
            guard let script = file.first else { return }
            guard script.isLiteral else {
                if says { isUnreadable = true }
                return
            }
            if Self.standardInput.contains(script.value) { readInput(input, plain: plain, depth: depth, says: says) }
        case _ where Self.shells.contains(name):
            shell(words, input: input, plain: plain, depth: depth, says: says, filled: filled)
        case _ where Self.wrappers.contains(name):
            // `command -v git` only says where it is.
            if name == "command", words.dropFirst().prefix(while: { $0.value.hasPrefix("-") }).contains(where: {
                $0.value != "--" && ($0.value.contains("v") || $0.value.contains("V"))
            }) {
                return
            }
            let fills: Set<String>? = Self.fillers.contains(name) ? Self.placeholders(words) : filled
            // Each word it may run, as `exec -a git bash -c '…'` runs bash, under the name git; and, for one that runs
            // the shell's own commands too, those that run a script, as `builtin source /dev/stdin <<< '…'` does.
            let starts = words.indices.dropFirst().filter { index in
                let word = words[index]
                return word.isLiteral && (Self.runners.contains(Self.programName(word.value))
                    || (Self.runBuiltins.contains(name) && Self.scriptBuiltins.contains(word.value)))
            }
            for start in starts {
                run(Array(words[start...]), input: input, plain: false, depth: depth, says: says, filled: fills)
            }
            // One that runs a string of its own through a shell, as `parallel '<command>' ::: …`, `flock <file> -c
            // '<command>'` or `watch '<command>'` do: its words with blanks in them, before what it runs, if anything, as
            // scripts.
            if Self.runStrings.contains(name) {
                for word in words[1..<(starts.first ?? words.count)] where word.isLiteral && word.value.contains(where: \.isWhitespace) {
                    read(word.value, depth: depth + 1, says: says, wrapped: true)
                }
            }
            if starts.isEmpty, says, words.dropFirst().contains(where: { !$0.isLiteral })
                || (name == "env" && words.contains(where: { $0.value.hasPrefix("-S") || $0.value.hasPrefix("--split-string") })) {
                // What it runs may be in a variable, or in env's string of words.
                isUnreadable = true
            }
        case _ where Self.runNothing.contains(name):
            return
        default:
            // A program BriefBar doesn't know, such as another that runs a program, named after it: what it runs isn't known
            // when that's git or a shell.
            if says, words.dropFirst().contains(where: { $0.isLiteral && Self.runners.contains(Self.programName($0.value)) }) {
                isUnreadable = true
            }
        }
    }

    /// `eval`'s words, as the script they make together: when they're known.
    private mutating func evaluate(_ words: [Word], plain: Bool, depth: Int, says: Bool) {
        guard words.allSatisfy(\.isLiteral) else {
            if says { isUnreadable = true }
            return
        }
        read(words.map(\.value).joined(separator: " "), depth: depth + 1, says: says, wrapped: !plain)
    }

    /// The words `xargs` puts what it reads in place of: `{}`, as `find -exec` and `parallel` have it too, and the one its
    /// `-I`, `-J`, `-i` or `--replace` names. Any word with a brace counts, for `parallel`'s others, such as `{1}`.
    private static func placeholders(_ words: [Word]) -> Set<String> {
        var names: Set<String> = ["{}"]
        for (index, word) in words.enumerated() where word.isLiteral {
            let value = word.value
            for option in ["-I", "-J"] where value.hasPrefix(option) {
                let attached = String(value.dropFirst(option.count))
                if !attached.isEmpty {
                    names.insert(attached)
                } else if index + 1 < words.count {
                    names.insert(words[index + 1].value)
                }
            }
            if value.hasPrefix("--replace=") { names.insert(String(value.dropFirst("--replace=".count))) }
            if value.hasPrefix("-i"), value.count > 2, !value.hasPrefix("-i-") { names.insert(String(value.dropFirst(2))) }
        }
        return names
    }

    /// A word a program that fills in words, `filled`, may put something else in place of, or in: one with any of them
    /// in it, as `xargs -I X` puts what it reads in place of X wherever it is, `sh -c 'git X'` too, or with a brace.
    private static func isPlaceholder(_ word: Word, _ filled: Set<String>?) -> Bool {
        guard let filled else { return false }
        return !word.isLiteral || word.value.contains("{") || filled.contains { !$0.isEmpty && word.value.contains($0) }
    }

    /// git, past its own options: a push, with them and what follows it; or a command of git's that runs one it's given,
    /// read as a script.
    private mutating func git(_ words: [Word], plain: Bool, depth: Int, says: Bool, filled: Set<String>?) {
        var index = 1
        var options: [Word] = []
        while index < words.count {
            let word = words[index]
            guard word.isLiteral else {
                if says { isUnreadable = true }
                return
            }
            let option = word.value
            guard option.hasPrefix("-") else { break }
            if Self.gitStops.contains(option) || (option.hasPrefix("--exec-path") && !option.contains("="))
                || option.hasPrefix("--list-cmds") {
                return
            }
            if Self.gitOptionsWithValue.contains(option) {
                guard index + 1 < words.count else { return }
                options += [word, words[index + 1]]
                index += 2
            } else if Self.gitFlags.contains(option) || option.hasPrefix("--exec-path=")
                        || Self.gitOptionsWithValue.contains(where: { option.hasPrefix("\($0)=") }) {
                options.append(word)
                index += 1
            } else {
                // An option git may have since, which may take the word after it: where its command is isn't known.
                if says { isUnreadable = true }
                return
            }
        }
        // No command: one may come from what runs git, as `xargs git` reads it.
        guard index < words.count else {
            if says { isUnreadable = true }
            return
        }
        let command = words[index]
        guard command.isLiteral, !Self.isPlaceholder(command, filled) else {
            if says { isUnreadable = true }
            return
        }
        // Settings set right there that may have git run another command than the one it names (`redirects`), or whose
        // value says push.
        let settings = zip(options, options.dropFirst()).compactMap { option, value in
            option.value == "-c" || option.value == "--config-env" ? value.value : nil
        } + options.compactMap { $0.value.hasPrefix("--config-env=") ? String($0.value.dropFirst("--config-env=".count)) : nil }
        for setting in settings {
            let parts = setting.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if Self.redirects(String(parts[0])) || (parts.count > 1 && parts[1].contains("push")) {
                isUnreadable = true
                return
            }
        }
        let rest = Array(words[(index + 1)...])
        switch command.value {
        case "push":
            pushes.append(Push(options: options, arguments: rest, isPlain: plain))
        case "send-pack":
            pushes.append(Push(options: options, arguments: rest, isPlain: false))
        case "subtree":
            // `git subtree [--prefix=<folder>] push …`: its options come first.
            if let push = rest.firstIndex(of: Word(value: "push")) {
                pushes.append(Push(options: options, arguments: Array(rest[(push + 1)...]), isPlain: false))
            } else if says, rest.contains(where: { !$0.isLiteral }) {
                isUnreadable = true
            }
        case "submodule":
            // `git submodule foreach '<command>'`, which runs it in each submodule.
            var at = rest.drop { $0.isLiteral && $0.value.hasPrefix("-") }
            guard at.first == Word(value: "foreach") else { return }
            at = at.dropFirst().drop { $0.isLiteral && ["--recursive", "-q", "--quiet", "--"].contains($0.value) }
            evaluate(Array(at), plain: false, depth: depth, says: says)
        case let subcommand where Self.commandOptions[subcommand] != nil:
            // `git rebase --exec '<command>'` and others of git's that run the command an option gives.
            for script in Self.values(of: Self.commandOptions[subcommand] ?? [], in: rest) {
                evaluate([script], plain: false, depth: depth, says: says)
            }
        case "bisect" where rest.first == Word(value: "run"):
            // `git bisect run <command>`, which runs it at each commit it tries.
            evaluate(Array(rest.dropFirst()), plain: false, depth: depth, says: says)
        case "config":
            // The same settings, in git's configuration, for the commands after it: `git config alias.p push`, a key in
            // any of its words; or a value, a word that says push and isn't a setting's name, as a pager's that pushes.
            if rest.contains(where: { word in
                Self.redirects(word.value) || (word.value.contains("push") && !Self.isSettingName(word.value)) || (says && !word.isLiteral)
            }) {
                isUnreadable = true
            }
        default:
            return
        }
    }

    /// A setting that may have git run another command than the one it names: an alias, whatever the case of its name, as
    /// git reads them; autocorrect, which runs the command closest to a typo, such as `psuh`; or an include, of a file's
    /// settings.
    private static func redirects(_ key: String) -> Bool {
        let key = key.lowercased()
        return key.hasPrefix("alias.") || key == "help.autocorrect" || key.hasPrefix("include.") || key.hasPrefix("includeif.")
    }

    /// A setting's name, `<section>.<name>` or `<section>.<subsection>.<name>`, as `push.default` or `remote.origin.push`.
    private static func isSettingName(_ word: String) -> Bool {
        word.range(of: #"^[A-Za-z][A-Za-z0-9-]*(\.\S+)?\.[A-Za-z][A-Za-z0-9-]*$"#, options: .regularExpression) != nil
    }

    /// The values `words` give `options`, those of a command of git's that take one, as git reads them: `-x <value>`,
    /// `-x<value>`, or after other short options, as `-qx <value>`; `--exec <value>` or `--exec=<value>`, and the long
    /// ones shortened, as git takes them, `--ex=<value>`. Up to `--`, after which nothing is an option.
    private static func values(of options: [String], in words: [Word]) -> [Word] {
        var values: [Word] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1
            let text = word.value
            if text == "--" { break }
            var attached: Substring?
            if text.hasPrefix("--") {
                let name = text.prefix { $0 != "=" }
                guard name.count > 3, options.contains(where: { $0.hasPrefix("--") && $0.hasPrefix(name) }) else {
                    continue
                }
                if let equals = text.firstIndex(of: "=") { attached = text[text.index(after: equals)...] }
            } else if text.hasPrefix("-"), text.count > 1 {
                let letters = text.dropFirst()
                guard let letter = letters.firstIndex(where: { options.contains("-\($0)") }) else { continue }
                let rest = letters[letters.index(after: letter)...]
                if !rest.isEmpty { attached = rest }
            } else {
                continue
            }
            if let attached {
                values.append(Word(value: String(attached), isLiteral: word.isLiteral))
            } else if index < words.count {
                values.append(words[index])
                index += 1
            }
        }
        return values
    }

    /// A shell: the script its `-c` runs, or, with `-s`, or no script file, or /dev/stdin for one, the one it reads from a
    /// here-document or here-string. One from anywhere else, as through a pipe, can't be read.
    private mutating func shell(_ words: [Word], input: [Word], plain: Bool, depth: Int, says: Bool, filled: Set<String>?) {
        var index = 1
        var runsArgument = false
        var readsInput = false
        while index < words.count {
            let word = words[index]
            guard word.isLiteral, !Self.isPlaceholder(word, filled) else {
                if says { isUnreadable = true }
                return
            }
            let option = word.value
            // `-` ends the options, as `--` does.
            if option == "--" || option == "-" {
                index += 1
                break
            }
            if option.hasPrefix("--") {
                index += option == "--rcfile" || option == "--init-file" ? 2 : 1
                continue
            }
            guard option.count > 1, option.hasPrefix("-") || option.hasPrefix("+") else { break }
            let letters = option.dropFirst()
            if letters.contains("c") { runsArgument = true }
            if letters.contains("s") { readsInput = true }
            // -o and +o take an option's name.
            index += letters.contains("o") || letters.contains("O") ? 2 : 1
        }
        if runsArgument {
            // No script: one may come from what runs the shell, as `xargs sh -c` reads it.
            guard index < words.count else {
                if says { isUnreadable = true }
                return
            }
            let script = words[index]
            guard script.isLiteral, !Self.isPlaceholder(script, filled) else {
                if says { isUnreadable = true }
                return
            }
            read(script.value, depth: depth + 1, says: says, wrapped: !plain)
        } else if readsInput || index >= words.count || Self.standardInput.contains(words[index].value) {
            readInput(input, plain: plain, depth: depth, says: says)
        }
        // Else a script file, which BriefBar doesn't read.
    }

    /// The script a shell reads from its input: a here-document or here-string. One from anywhere else, as through a pipe,
    /// can't be read.
    private mutating func readInput(_ input: [Word], plain: Bool, depth: Int, says: Bool) {
        guard !input.isEmpty else {
            if says { isUnreadable = true }
            return
        }
        for script in input {
            if script.isLiteral {
                read(script.value, depth: depth + 1, says: says, wrapped: !plain)
            } else if says || script.value.contains("push") {
                isUnreadable = true
            }
        }
    }

    /// `NAME=value`, or `NAME+=value`, before a command: for it alone, as `GIT_DIR` would point git elsewhere.
    private static func isAssignment(_ word: Word) -> Bool {
        guard let equals = word.value.firstIndex(of: "=") else { return false }
        var name = word.value[..<equals]
        if name.hasSuffix("+") { name = name.dropLast() }
        guard let first = name.first, first == "_" || (first.isASCII && first.isLetter) else { return false }
        return name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }

    /// A program's name, without the folder it's in, in lowercase, as macOS finds it whatever its case: `git` for
    /// `/usr/bin/git`, and for `GIT`.
    private static func programName(_ word: String) -> String {
        (word.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? word).lowercased()
    }
}

extension PushCommand.Push {
    /// What a push would do, by its options and refspecs.
    public enum Form: Sendable, Equatable {
        /// `git [-C <worktree>] push
        /// [-q|-v|--porcelain|--progress|--no-progress|--no-follow-tags|--no-recurse-submodules] origin
        /// <commit>:refs/heads/<branch>`, plain, with the commit's full ID: the one way Push & Reply's prompt asks for,
        /// with the options that keep it to that branch. Its check lets it through only as a command of its own
        /// (`PushCommand.isAlone`).
        case exact(commit: String)
        /// It pushes otherwise: another remote, branch or refspec, more than one, or with other options.
        case other
        /// It would rewrite or delete what's on the remote, or push more than a branch.
        case unsafe(Unsafe)
        /// `--dry-run`, or `--help`, with no option BriefBar doesn't know, such as `--no-dry-run`, or an abbreviation,
        /// that could undo it: it pushes nothing.
        case dryRun

        public var unsafe: Unsafe? {
            if case .unsafe(let unsafe) = self { return unsafe }
            return nil
        }
    }

    public enum Unsafe: Sendable, Equatable {
        /// `--force`, `-f`, `--force-with-lease`, `--force-if-includes`, or a refspec with `+`.
        case force
        /// `--delete`, `-d`, `--prune`, or a refspec with nothing before its `:`.
        case delete
        /// `--mirror`, `--all`, `--branches` or `--tags`.
        case more
    }

    /// What it would do, in the worktree `worktree`, to the pull request's branch, `branch`.
    public func form(worktree: URL, branch: String) -> Form {
        var unsafe: Unsafe?
        var dryRun = false
        var other = !isPlain
        var positional: [PushCommand.Word] = []
        var optionsEnded = false
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            guard word.isLiteral else {
                // What a variable says isn't known: it isn't this form.
                other = true
                continue
            }
            let value = word.value
            if optionsEnded || !value.hasPrefix("-") || value == "-" {
                positional.append(word)
                continue
            }
            if value == "--" {
                optionsEnded = true
                other = true
                continue
            }
            if value.hasPrefix("--") {
                let name = value.split(separator: "=", maxSplits: 1).first.map(String.init) ?? value
                switch name {
                case "--force", "--force-with-lease", "--force-if-includes": unsafe = unsafe ?? .force
                case "--delete", "--prune": unsafe = unsafe ?? .delete
                case "--mirror", "--all", "--branches", "--tags": unsafe = unsafe ?? .more
                case "--dry-run", "--help": dryRun = true
                case "--quiet", "--verbose", "--porcelain", "--progress", "--no-progress", "--no-follow-tags", "--no-recurse-submodules":
                    break
                case "--repo", "--receive-pack", "--exec", "--push-option":
                    other = true
                    if !value.contains("=") { index += 1 }
                default: other = true
                }
                continue
            }
            // Short options, which may share a dash: -qv, -fu.
            var letters = value.dropFirst()
            while let letter = letters.first {
                letters = letters.dropFirst()
                switch letter {
                case "f": unsafe = unsafe ?? .force
                case "d": unsafe = unsafe ?? .delete
                case "n", "h": dryRun = true
                case "q", "v": break
                case "o":
                    // -o <option>, or -o<option>.
                    other = true
                    if letters.isEmpty { index += 1 }
                    letters = ""
                default: other = true
                }
            }
        }
        for refspec in positional.dropFirst() {
            if refspec.value.hasPrefix("+") {
                unsafe = unsafe ?? .force
            } else if refspec.value.hasPrefix(":"), refspec.value != ":" {
                unsafe = unsafe ?? .delete
            }
        }
        // A dry run, unless another option, or a word that isn't known, may undo it: `--no-dry-run`, an abbreviation git
        // takes, as `--no-dr`, or an option whose value it would be, as `--rep -n`.
        if dryRun, !other { return .dryRun }
        if let unsafe { return .unsafe(unsafe) }
        guard !other, positional.count == 2, positional[0].value == "origin", runsIn(worktree) else { return .other }
        let parts = positional[1].value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, Git.isCommit(String(parts[0])), parts[1] == "refs/heads/\(branch)" else { return .other }
        return .exact(commit: String(parts[0]))
    }

    /// Its only option of git's is none, or `-C` with the worktree's path, in full. Without it, it runs where the shell
    /// is, which an earlier command may have moved: the CLI's `cwd` is the session's.
    private func runsIn(_ worktree: URL) -> Bool {
        switch options.count {
        case 0:
            return true
        case 2:
            let folder = options[1]
            guard options[0].value == "-C", folder.isLiteral, folder.value.hasPrefix("/") else { return false }
            return URL(fileURLWithPath: folder.value).standardizedFileURL.resolvingSymlinksInPath().path
                == worktree.standardizedFileURL.resolvingSymlinksInPath().path
        default:
            return false
        }
    }
}
