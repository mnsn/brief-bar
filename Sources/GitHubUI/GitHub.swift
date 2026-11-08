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
    /// - Parameter keepingActive: whether the GitHub CLI goes on using the account it used, rather than the one you sign in
    ///   to, as when you add one.
    static func signIn(ghPath: String?, keepingActive: Bool = false) {
        let script = signInScript(ghPath: ghPath, keepingActive: keepingActive)
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

    /// What Terminal runs to sign in: `gh auth login`; and, when `keepingActive`, `gh auth switch` back to the account the
    /// GitHub CLI used just before, which it reads as it starts, so that it's the one you use now, however you last chose
    /// it. Nothing switches when the GitHub CLI used none; when it can't switch back, it says so, and how to.
    nonisolated static func signInScript(ghPath: String?, keepingActive: Bool) -> String {
        let gh = ghPath.map(quoted) ?? "gh"
        var lines = [
            "#!/bin/zsh -l",
            "# Opened by BriefBar, which reads your GitHub pull requests with the GitHub CLI's sign-in.",
            "echo \"Signing in to the GitHub CLI for BriefBar, which reads every account it's signed in to.\"",
            "echo",
        ]
        if keepingActive {
            lines.append("active=\"$(\(gh) config get --host github.com user 2>/dev/null)\"")
        }
        lines += [
            "if \(gh) auth login --hostname github.com --web; then",
            "    echo",
        ]
        if keepingActive {
            lines += [
                "    if [[ -n \"$active\" ]]; then",
                "        if switched=\"$(\(gh) auth switch --hostname github.com --user \"$active\" 2>&1)\"; then",
                "            echo \"The GitHub CLI goes on using $active in Terminal: gh auth switch changes that.\"",
                "        else",
                "            print -r -- \"$switched\"",
                "            echo \"The GitHub CLI couldn't switch back to $active, so in Terminal it uses the account you signed in to.\"",
                "            echo \"To use $active again: gh auth switch --hostname github.com --user $active\"",
                "        fi",
                "    fi",
            ]
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
}
