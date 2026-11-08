import AppKit
import BriefBarCore
import BriefBarUI

/// Opening GitHub pages, and signing in to the GitHub CLI.
@MainActor
enum GitHub {
    static let installCLIPage = URL(string: "https://cli.github.com")!
    /// Your open pull requests, on GitHub.
    static let pullRequestsPage = URL(string: "https://github.com/pulls")!

    /// Opens a GitHub page in the browser: only a web address, never another kind of link.
    static func open(_ url: URL) {
        guard url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens Terminal running `gh auth login`, which signs in through the browser: to the GitHub CLI, or to another of
    /// your accounts, whose pull requests BriefBar reads too. BriefBar picks the sign-in up on its next refresh, within a
    /// minute.
    /// - Parameter active: the account the GitHub CLI uses now, which it goes on using after, rather than the one you sign
    ///   in to; nil to use that one, as when it's signed in to none.
    static func signIn(ghPath: String?, keepingActive active: String? = nil) {
        let script = signInScript(ghPath: ghPath, keepingActive: active)
        do {
            let directory = UserHome.url.appendingPathComponent("Library/Caches", isDirectory: true)
                .appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("Sign in to GitHub CLI.command")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            Log.app.error("Couldn't start gh auth login: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What Terminal runs to sign in: `gh auth login`, then, when `active` names the account the GitHub CLI used, `gh auth
    /// switch` back to it.
    nonisolated static func signInScript(ghPath: String?, keepingActive active: String?) -> String {
        let gh = ghPath.map(quoted) ?? "gh"
        var lines = [
            "#!/bin/zsh -l",
            "# Opened by BriefBar, which reads your GitHub pull requests with the GitHub CLI's sign-in.",
            "echo \"Signing in to the GitHub CLI for BriefBar, which reads every account it's signed in to.\"",
            "echo",
            "if \(gh) auth login --hostname github.com --web; then",
            "    echo",
        ]
        if let active {
            lines.append(
                "    \(gh) auth switch --hostname github.com --user \(quoted(active)) >/dev/null 2>&1"
                    + " && echo \"The GitHub CLI goes on using \(active.filter(isLoginCharacter)) in Terminal: gh auth switch changes that.\""
            )
        }
        lines += [
            "    echo \"Signed in. You can close this window: BriefBar will refresh within a minute.\"",
            "fi",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// `text` in single quotes, for zsh to take as it is.
    nonisolated static func quoted(_ text: String) -> String {
        "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// What a GitHub login is made of, which an echo can say unquoted: letters, digits, `-`, and `_` for a managed user.
    nonisolated private static func isLoginCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
    }
}
