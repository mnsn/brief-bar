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

    /// Opens Terminal running `gh auth login`, which signs in through the browser. BriefBar picks the sign-in up
    /// on its next refresh, within a minute.
    static func signIn(ghPath: String?) {
        let gh = ghPath.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" } ?? "gh"
        let script = """
            #!/bin/zsh -l
            # Opened by BriefBar, which reads your GitHub pull requests with the GitHub CLI's sign-in.
            echo "Signing in to the GitHub CLI for BriefBar."
            echo
            \(gh) auth login --hostname github.com --web && echo && echo "Signed in. You can close this window: BriefBar will refresh within a minute."
            """
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
}
