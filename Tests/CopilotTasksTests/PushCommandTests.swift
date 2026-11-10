import Foundation
import Testing
@testable import CopilotTasks

/// How Push & Reply's check of each push reads a shell command Copilot is about to run: the pushes it runs, wherever they
/// are in it, and what each would do (`PushCommand`, `ShellReader`).
@Suite struct PushCommandTests {
    private let worktree = URL(fileURLWithPath: "/Users/robin/src/copilot-worktrees/shop-web/pr-4071", isDirectory: true)
    private let branch = "users/robin/fix-total"
    private let commit = "3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a"
    private var refspec: String { "\(commit):refs/heads/\(branch)" }

    private func forms(_ command: String, branch: String? = nil) -> [PushCommand.Push.Form] {
        PushCommand(command).pushes.map { $0.form(worktree: worktree, branch: branch ?? self.branch) }
    }

    /// The push the prompt asks for, wherever it is in a command: its form. Whether it's all of the command is `isAlone`.
    @Test func takesThePushThePromptAsksFor() {
        let exact = PushCommand.Push.Form.exact(commit: commit)
        let commands = [
            "git push origin \(refspec)",
            "git -C \(worktree.path) push origin \(refspec)",
            "git -C '\(worktree.path)/' push -q origin \(refspec)",
            "git push --porcelain --no-progress origin \(refspec) 2>&1 | tail -5",
            "git push origin \(refspec) > /tmp/push.log 2>&1 &",
            "cd \(worktree.path) && git push origin \(refspec)",
            "git add -A && git commit -m \"Cap the retries\" && git push -qv origin \(refspec)",
            "if git push origin \(refspec); then echo pushed; else echo \"couldn't push\"; fi",
            "(cd \(worktree.path) && git push origin \(refspec))",
            "{ git push origin \(refspec); }",
            "git push \\\n  origin \(refspec) # push the commit I checked",
            "git push origin \"\(commit)\":'refs/heads/users/robin/fix-total'",
            "sh -c 'git push origin \(refspec)'",
            "eval git push origin \(refspec)",
            "git push --no-follow-tags --no-recurse-submodules origin \(refspec)",
            "cd /tmp && git -C \(worktree.path) push origin \(refspec)",
        ]
        for command in commands {
            #expect(forms(command) == [exact], "\(command)")
            #expect(!PushCommand(command).isUnreadable, "\(command)")
        }
    }

    /// A push as a command of its own, with nothing else in it, at any depth: nothing that could change what it does before
    /// it runs, as a `cd`, even in a subshell, or `git config`.
    @Test func knowsWhetherThePushIsAllOfTheCommand() {
        for command in [
            "git push origin \(refspec)",
            "git -C \(worktree.path) push -q origin \(refspec) 2>&1",
            "git push origin \(refspec) > /tmp/push.log 2>&1 &",
            "git push \\\n  origin \(refspec) # push the commit I checked",
            "(git push origin \(refspec));",
            "{ git push origin \(refspec); }",
        ] {
            #expect(PushCommand(command).isAlone, "\(command)")
        }
        for command in [
            "cd \(worktree.path) && git push origin \(refspec)",
            "cd /Users/robin/src/shop-web; (cd \(worktree.path)); git push origin \(refspec)",
            "git config push.followTags true && git push origin \(refspec)",
            "GIT_DIR=/tmp/other.git; git push origin \(refspec)",
            "git status && git push origin \(refspec)",
            "git push origin \(refspec) 2>&1 | tail -5",
            "sh -c 'git push origin \(refspec)'",
            "eval git push origin \(refspec)",
            "git push origin \(refspec) > \"$(git config push.followTags true; echo /dev/null)\"",
            "git push origin \(refspec) <<EOF\n$(git config push.followTags true)\nEOF",
            "push() { git push origin \(refspec); }; push",
            "for remote in origin; do git push origin \(refspec); done",
        ] {
            #expect(!PushCommand(command).isAlone, "\(command)")
        }
    }

    /// A branch's name as the prompt writes it in a command (`QuotedText.commandWord`): in single quotes when a shell would
    /// read something in it, or in ANSI-C quotes when it has a character nobody sees.
    @Test func readsBranchNamesAsThePromptQuotesThem() {
        let dollar = "users/robin/$fix"
        #expect(forms("git push origin \(commit):refs/heads/'users/robin/$fix'", branch: dollar) == [.exact(commit: commit)])
        let unseen = "fix\u{200B}total"
        #expect(forms("git push origin \(commit):refs/heads/$'fix\\xE2\\x80\\x8Btotal'", branch: unseen) == [.exact(commit: commit)])
        #expect(forms("git push origin \(commit):refs/heads/$'fix\\xE2\\x80\\x8Btotal'", branch: "fixtotal") == [.other])
        // The other escapes, as bash and zsh read them.
        #expect(PushCommand("git push origin $'a\\tb\\'c\\\\d\\101\\x41\\cA'").pushes.first?.arguments.last
            == PushCommand.Word(value: "a\tb'c\\dAA\u{01}"))
        // \u, which macOS's bash 3.2 doesn't read: not known.
        #expect(PushCommand("git push origin $'\\u0041'").pushes.first?.arguments.last?.isLiteral == false)
    }

    /// What ANSI-C quotes say ends at a NUL they make, and a NUL in the command itself is dropped, as bash does both: the
    /// push that's left is read.
    @Test func readsNULsAsBashDoes() {
        for word in [
            #"$'push\0ignored'"#, #"$'push\x00ignored'"#, #"$'push\x0ignored'"#, #"$'push\000ignored'"#, #"$'push\00ignored'"#,
            #"$'push\400ignored'"#, #"$'push\c@ignored'"#, #"$'push\c ignored'"#, #"$'push\c`ignored'"#, #"$'pu\0x'sh"#, "pu\u{0}sh",
        ] {
            #expect(forms("git \(word) --force origin main") == [.unsafe(.force)], "\(word)")
        }
        // What's before the NUL stays as it was, literal.
        #expect(PushCommand(#"git push origin $'a\0b'c"#).pushes.first?.arguments.last == PushCommand.Word(value: "ac"))
        // \01 isn't a NUL.
        #expect(forms(#"git $'push\01' --force origin main"#).isEmpty)
    }

    /// Any other push: Copilot can try again, in the form the prompt asks for.
    @Test func takesAnyOtherPushForAnother() {
        let commands = [
            "git push",
            "git push origin",
            "git push origin HEAD:refs/heads/\(branch)",
            "git push origin \(branch)",
            "git push origin \(commit)",
            "git push origin \(commit):\(branch)",
            "git push origin \(commit):refs/heads/main",
            "git push origin 3f2a1b0:refs/heads/\(branch)",
            "git push origin \(commit.uppercased()):refs/heads/\(branch)",
            "git push upstream \(refspec)",
            "git push https://dev.azure.com/contoso/Storefront/_git/shop-web \(refspec)",
            "git push -u origin \(refspec)",
            "git push --set-upstream origin \(refspec)",
            "git push --follow-tags origin \(refspec)",
            "git push --no-verify origin \(refspec)",
            "git push -o ci.skip origin \(refspec)",
            "git push --repo=origin \(refspec)",
            "git push origin \(refspec) refs/tags/v1",
            "git push -- origin \(refspec)",
            "git push origin $(git rev-parse HEAD):refs/heads/\(branch)",
            "git push origin \"$SHA\":refs/heads/\(branch)",
            "git push origin \(commit):refs/heads/users/robin/fix-*",
            "git -C /Users/robin/src/shop-web push origin \(refspec)",
            "git -C pr-4071 push origin \(refspec)",
            "git -C \(worktree.path) -C . push origin \(refspec)",
            "git -c push.default=current push origin \(refspec)",
            "git --git-dir=/tmp/other.git push origin \(refspec)",
            "GIT_TERMINAL_PROMPT=0 git push origin \(refspec)",
            "GIT_DIR=/tmp/other.git git push origin \(refspec)",
            "/usr/bin/git push origin \(refspec)",
            "command git push origin \(refspec)",
            "env git push origin \(refspec)",
            "env -i HOME=/tmp git push origin \(refspec)",
            "nohup git push origin \(refspec)",
            "time git push origin \(refspec)",
            "timeout 60 git push origin \(refspec)",
            "echo \(refspec) | xargs git push origin",
            "env bash -c 'git push origin \(refspec)'",
            "git subtree push --prefix=docs origin gh-pages",
            "git send-pack origin \(refspec)",
            "/usr/libexec/git-core/git-push origin \(refspec)",
        ]
        for command in commands {
            #expect(forms(command) == [.other], "\(command)")
        }
    }

    /// A push that would rewrite or delete what's on the remote, or push more than a branch.
    @Test func tellsWhatWouldRewriteDeleteOrPushMore() {
        let cases: [(String, PushCommand.Push.Unsafe)] = [
            ("git push --force origin \(refspec)", .force),
            ("git push -f origin \(refspec)", .force),
            ("git push -qf origin \(refspec)", .force),
            ("git push -uf origin \(branch)", .force),
            ("git push --force-with-lease origin \(refspec)", .force),
            ("git push --force-with-lease=refs/heads/\(branch):\(commit) origin \(refspec)", .force),
            ("git push --force-if-includes origin \(refspec)", .force),
            ("git push origin +\(refspec)", .force),
            ("git push origin \(refspec) +HEAD:refs/heads/main", .force),
            ("git push --delete origin \(branch)", .delete),
            ("git push -d origin \(branch)", .delete),
            ("git push origin :refs/heads/\(branch)", .delete),
            ("git push --prune origin 'refs/heads/*:refs/heads/*'", .delete),
            ("git push --mirror origin", .more),
            ("git push --all origin", .more),
            ("git push --branches origin", .more),
            ("git push --tags origin", .more),
            ("nohup git push --force origin main &", .force),
            ("timeout 60 git push -f", .force),
            ("bash -lc \"git push --force origin main\"", .force),
            ("echo $(git push --force origin main)", .force),
            ("echo `git push -d origin main`", .delete),
            ("git commit -am wip && git push origin \(refspec) && git push --tags", .more),
        ]
        for (command, unsafe) in cases {
            let forms = forms(command)
            #expect(forms.contains(.unsafe(unsafe)), "\(command): \(forms)")
        }
        // ":" alone pushes the branches the remote has too: not this form, but no deletion.
        #expect(forms("git push origin :") == [.other])
    }

    /// A dry run, or git's help, pushes nothing.
    @Test func aDryRunPushesNothing() {
        #expect(forms("git push --dry-run origin \(refspec)") == [.dryRun])
        #expect(forms("git push -n --force origin main") == [.dryRun])
        #expect(forms("git push --help") == [.dryRun])
        #expect(PushCommand("git --help push").pushes.isEmpty)
        #expect(PushCommand("git help push").pushes.isEmpty)
        #expect(PushCommand("git --version").pushes.isEmpty)
    }

    /// Unless an option BriefBar doesn't know may undo it: the last of `-n` and `--no-dry-run` wins, git takes an
    /// abbreviation, and an option takes the word after it as its value.
    @Test func aDryRunAnotherOptionMayUndoIsntOne() {
        let cases: [(String, PushCommand.Push.Form)] = [
            ("git push -n --no-dry-run --force origin main", .unsafe(.force)),
            ("git push -n --no-dr origin :refs/heads/main", .unsafe(.delete)),
            ("git push --rep -n origin +HEAD:refs/heads/main", .unsafe(.force)),
            ("X=--repo; git push $X -n origin +HEAD:refs/heads/main", .unsafe(.force)),
            ("echo -- --no-dry-run --force origin main | xargs git push -n", .other),
            ("git push -n -u origin \(refspec)", .other),
            ("env git push --dry-run origin \(refspec)", .other),
        ]
        for (command, form) in cases {
            #expect(forms(command) == [form], "\(command)")
        }
    }

    /// Variables set for a command after the words that start it, as in a loop that tries again.
    @Test func readsVariablesSetAfterTheWordsThatStartACommand() {
        let cases: [(String, PushCommand.Push.Form)] = [
            ("for i in 1 2 3; do GIT_TERMINAL_PROMPT=0 git push origin HEAD && break; sleep 5; done", .other),
            ("if ! GIT_TERMINAL_PROMPT=0 git push --force origin HEAD:refs/heads/main; then echo failed; fi", .unsafe(.force)),
            ("for i in 1; do ! GIT_TERMINAL_PROMPT=0 git push --delete origin main; done", .unsafe(.delete)),
            ("while A=1 B=2 ! git push --tags origin; do sleep 1; done", .unsafe(.more)),
            ("until GIT_TERMINAL_PROMPT=0 git push origin \(refspec); do sleep 5; done", .other),
        ]
        for (command, form) in cases {
            #expect(forms(command) == [form], "\(command)")
        }
    }

    /// What a program fills in from its input, or a shell reads from it, as the command runs it: here-documents and
    /// here-strings are read; what comes otherwise, as through a pipe, isn't known.
    @Test func readsWhatComesFromACommandsInput() {
        let unsafe: [(String, PushCommand.Push.Unsafe)] = [
            ("bash -s -- main <<'EOF'\ngit push --force origin \"$1\"\nEOF", .force),
            ("bash - <<'EOF'\ngit push -d origin main\nEOF", .delete),
            ("bash /dev/stdin <<< 'git push --force origin main'", .force),
            ("sh /dev/fd/0 <<'EOF'\ngit push --mirror origin\nEOF", .more),
            (". /dev/stdin <<< 'git push --force origin main'", .force),
            ("source /dev/stdin <<'EOF'\ngit push --force origin main\nEOF", .force),
            ("trap 'git push --force origin main' DEBUG; true", .force),
            ("trap -- 'git push -d origin main' EXIT", .delete),
        ]
        for (command, form) in unsafe {
            #expect(forms(command).contains(.unsafe(form)), "\(command): \(forms(command))")
        }
        let unreadable = [
            "echo push --force origin main | xargs git",
            "echo push | xargs git -C \(worktree.path)",
            "printf 'git push --force origin main' | xargs -0 sh -c",
            "echo push | xargs -I X git X --force origin main",
            "echo push | xargs -J % git % --force origin main",
            "find push -maxdepth 0 -exec git {} --force origin main \\;",
            "echo 'git push --force origin main' | xargs -I {} sh -c {}",
            "echo push | parallel git {1} --force origin main",
            "source <(echo git push --force origin main)",
            "trap \"$push_it\" EXIT",
            "cat push.sh | bash -s",
        ]
        for command in unreadable {
            #expect(PushCommand(command).isUnreadable, "\(command)")
        }
        // What a program fills in elsewhere, or a script in a file, which BriefBar doesn't read.
        for command in ["git ls-files -m | xargs git add && git commit -m wip # then push", "source ./push.sh", "trap -p",
                        "find . -name '*.swift' -exec grep -n push {} +"] {
            let read = PushCommand(command)
            #expect(read.pushes.isEmpty && !read.isUnreadable, "\(command)")
        }
    }

    /// Backticks in double quotes take `\"` for a quote, as bash does; in a here-document, they don't.
    @Test func readsBackticksAsBashDoes() {
        #expect(forms("echo \"`git \\\"push\\\" --force origin main`\"") == [.unsafe(.force)])
        #expect(forms("echo \"${X:-`git \\\"push\\\" -d origin main`}\"") == [.unsafe(.delete)])
        #expect(PushCommand("cat <<EOF\n`git \\\"push\\\" --force`\nEOF").pushes.isEmpty)
        // A parameter's default in double quotes: a single quote there is only itself, so what it has runs; outside
        // them, it quotes.
        #expect(forms("echo \"${X:-'$(git push --force origin main)'}\"") == [.unsafe(.force)])
        #expect(PushCommand("echo ${X:-'$(git push --force origin main)'}").pushes.isEmpty)
    }

    /// Programs as macOS finds them, whatever the case of their names; others that run git or a shell they name.
    @Test func readsProgramsAsMacOSFindsThem() {
        let cases: [(String, PushCommand.Push.Form)] = [
            ("GIT push --force origin main", .unsafe(.force)),
            ("/usr/bin/Git push -d origin main", .unsafe(.delete)),
            ("ENV GIT_TRACE=1 git push --force origin main", .unsafe(.force)),
            ("BASH -c 'git push --mirror origin'", .unsafe(.more)),
            ("Git push origin \(refspec)", .other),
            ("xcrun git push --force origin main", .unsafe(.force)),
            ("ssh-agent bash -c 'ssh-add -q && git push --force origin main'", .unsafe(.force)),
            ("exec -a git bash -c 'git push --force origin main'", .unsafe(.force)),
        ]
        for (command, form) in cases {
            #expect(forms(command).contains(form), "\(command): \(forms(command))")
        }
        for command in ["mytool git push --force origin main", "unknown-wrapper /usr/bin/git push", "op run -- sh -c 'git push'",
                        "git --config-env=alias.p=ALIAS p origin main && echo pushed", "git --config-env alias.p=ALIAS p # push"] {
            #expect(PushCommand(command).isUnreadable, "\(command)")
        }
        // Where it's only named, or a program that runs none of its words.
        for command in ["command -v git && echo push", "which git; type -a git # then push", "echo Pushing with git push",
                        "printf '%s\\n' git push", "cd /tmp/git && ls # push", "help push"] {
            let read = PushCommand(command)
            #expect(read.pushes.isEmpty && !read.isUnreadable, "\(command)")
        }
        #expect(forms("command -v git >/dev/null && git push origin \(refspec)") == [.exact(commit: commit)])
    }

    /// `[`, `[[` and `{}` on their own are what they say, so a test, or `find`'s `{}`, beside the push the prompt asks for
    /// leaves it that push; a pattern and braces that expand aren't known.
    @Test func takesBracketsAndBracesForWhatTheyAre() {
        let exact = PushCommand.Push.Form.exact(commit: commit)
        for command in [
            "if [ -n \"$(git status --porcelain)\" ]; then git commit -am fix; fi; git push origin \(refspec)",
            "[[ -z \"$(git status --porcelain)\" ]] && git push origin \(refspec)",
            "test -d .git && git push origin \(refspec)",
            "find . -name '*.orig' -exec rm {} + && git push origin \(refspec)",
        ] {
            #expect(forms(command) == [exact], "\(command)")
            #expect(!PushCommand(command).isUnreadable, "\(command)")
        }
        for command in ["[ -x .git/hooks/pre-push ] && cat .git/hooks/pre-push", "[[ $branch == *push* ]] && echo yes"] {
            let read = PushCommand(command)
            #expect(read.pushes.isEmpty && !read.isUnreadable, "\(command)")
        }
        func last(_ command: String) -> PushCommand.Word? { PushCommand(command).pushes.first?.arguments.last }
        #expect(last("git push origin HEAD@{1}")?.isLiteral == true)
        #expect(last("git push origin {}")?.isLiteral == true)
        #expect(last("git push origin x[1]")?.isLiteral == false)
        #expect(last("git push origin {a,b}")?.isLiteral == false)
        #expect(last("git push origin v{1..3}")?.isLiteral == false)
        #expect(last("git push origin 'x[1]'")?.isLiteral == true)
    }

    /// What only looks like a push, or says it, isn't one.
    @Test func findsNoPushInWhatOnlySaysPush() {
        let commands = [
            "git stash push -m 'before the push'",
            "git log --oneline --grep push",
            "echo push",
            "echo git push --force origin main",
            "printf 'git push origin %s\\n' \(refspec)",
            "grep -rn \"git push\" docs",
            "git commit -m \"Don't push empty totals\"",
            "git remote set-url --push origin https://example.com/x.git",
            "gh pr view 4071 --json title # before the push",
            "cat notes.md | grep push",
            "node -e 'items.push(1)'",
            "git config --get remote.origin.pushurl",
        ]
        for command in commands {
            let read = PushCommand(command)
            #expect(read.pushes.isEmpty && !read.isUnreadable, "\(command)")
        }
    }

    /// Here-documents: a quoted one is the command's input as written; an unquoted one's substitutions run; a shell that
    /// reads one runs it.
    @Test func readsHereDocuments() {
        // A commit's message from a here-document, in a substitution, as models write them.
        let message = """
            git commit -m "$(cat <<'EOF'
            Don't push empty totals (fixes the push of #4071)
            EOF
            )" && git push origin \(refspec)
            """
        #expect(forms(message) == [.exact(commit: commit)])
        #expect(!PushCommand(message).isUnreadable)
        let script = """
            cat > cart.js <<'EOF'
            items.push(total)
            const quote = 'it's';
            EOF
            node cart.js
            """
        #expect(PushCommand(script).pushes.isEmpty && !PushCommand(script).isUnreadable)
        let tabs = "cat <<-EOF\n\tgit push --force\n\tEOF\necho done"
        #expect(PushCommand(tabs).pushes.isEmpty && !PushCommand(tabs).isUnreadable)
        // Its body's substitutions run.
        #expect(forms("cat <<EOF\nPushed: $(git push --force origin main)\nEOF") == [.unsafe(.force)])
        // A shell that reads it runs it, and so with a here-string.
        #expect(forms("bash <<'EOF'\ngit push --force origin main\nEOF") == [.unsafe(.force)])
        #expect(forms("bash -s <<'EOF'\ngit push origin \(refspec)\nEOF") == [.exact(commit: commit)])
        #expect(forms("sh <<< 'git push -d origin main'") == [.unsafe(.delete)])
        // Its variables leave it unknown.
        #expect(PushCommand("bash <<EOF\ngit push origin $SHA:refs/heads/x\nEOF").isUnreadable)
    }

    /// What it can't read, when it says push: unbalanced quotes, a variable for a command, a shell's script through a pipe.
    @Test func takesWhatItCantReadForAPushWhenItSaysPush() {
        let unreadable = [
            "git push origin '\(refspec)",
            "git push origin \"\(refspec)",
            "echo $(git push origin \(refspec)",
            "$GIT push origin \(refspec)",
            "\"$(which git)\" push origin \(refspec)",
            "C=push; git $C origin \(refspec)",
            "git $(echo push) origin \(refspec)",
            "echo 'git push --force' | sh",
            "git -c alias.p=push p origin \(refspec)",
            "git --some-new-option push origin \(refspec)",
            "env -S 'git push origin x'",
            "nohup \"$GIT\" push",
            String(repeating: "$(", count: 12) + "git push" + String(repeating: ")", count: 12),
        ]
        for command in unreadable {
            #expect(PushCommand(command).isUnreadable, "\(command)")
        }
        // That doesn't say push.
        for command in ["echo 'unbalanced", "$EDITOR notes.md", "git $(echo status)", "echo hi | sh"] {
            let read = PushCommand(command)
            #expect(!read.isUnreadable && read.pushes.isEmpty, "\(command)")
        }
    }

    /// Several pushes in one command, each as it is.
    @Test func findsEveryPush() {
        let command = "git push origin \(refspec) && git -C /tmp/other push origin main; (git push origin \(refspec))"
        #expect(forms(command) == [.exact(commit: commit), .other, .exact(commit: commit)])
    }
}
