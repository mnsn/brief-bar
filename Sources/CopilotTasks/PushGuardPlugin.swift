import Foundation

/// The plugin that has the Copilot CLI ask BriefBar about each shell command of one of BriefBar's Push & Reply tasks
/// before it runs it (`PushGuard`): a `preToolUse` hook for `bash` that runs `BriefBar --push-guard` with the task's pull
/// request, worktree and branches. It's a folder of its own for each run, `<run id>.guard`, beside what the run prints,
/// which the CLI loads with `--plugin-dir` for that run alone: never installed, so it runs in no other session, and goes
/// with the run's output, when you clear the task or turn Azure DevOps off. It's in the CLI's legacy layout, `plugin.json`
/// and `hooks.json` at its root, with the hook's `bash` command, which every CLI with `--plugin-dir` (0.0.421) reads.
public enum PushGuardPlugin {
    public static let name = "briefbar-push-guard"
    /// BriefBar's command-line mode the hook runs, with the pull request's link, and its options, each with its value in
    /// the same word: no branch, even one named `--help`, is then a word BriefBar's command line takes for another option.
    public static let flag = "--push-guard"
    public static let worktreeOption = "--worktree="
    public static let sourceOption = "--source-branch="
    public static let targetOption = "--target-branch="
    /// The oldest Copilot CLI it goes with: one where a hook that fails, or crashes, denies the call, rather than letting it
    /// through (1.0.57), and that honors the hook's `matcher` (1.0.36).
    static let oldest = CopilotServer.Version("1.0.57")!
    /// The hook's limit, in seconds: a hook that takes longer lets the call through, so the check answers first
    /// (`PushGuard.limit`).
    static let timeout = 300

    /// Its folder for a run.
    public static func folder(in outputFolder: URL, id: String) -> URL {
        outputFolder.appendingPathComponent("\(id).guard", isDirectory: true)
    }

    /// BriefBar's executable, for the hook to run, when it has one that stays: not while BriefBar runs from where macOS
    /// moved it for now (App Translocation), as with an app opened where it was downloaded.
    public static func executable(_ url: URL?) -> URL? {
        guard let url, url.isFileURL, url.path.hasPrefix("/"), !CopilotPluginRegistration.isTemporary(url) else { return nil }
        return url
    }

    /// The command the hook runs, each word in single quotes, for the shell the CLI runs it with.
    public static func command(executable: URL, pullRequest: TaskPullRequest, worktree: URL) -> String {
        [
            executable.path, flag, pullRequest.url.absoluteString, worktreeOption + worktree.path,
            sourceOption + pullRequest.sourceBranch, targetOption + pullRequest.targetBranch,
        ].map(CopilotCommand.quoted).joined(separator: " ")
    }

    /// Writes its folder for a run, afresh, in place of what's there, a link included, without following it: the folder
    /// only you can open, each file only you can read, written whole under a dot name, then renamed. Throws when it can't.
    /// - Parameter version: BriefBar's, for the plugin's; one that isn't three numbers, as a build from source's, is 0.0.0.
    public static func write(
        in outputFolder: URL, id: String, executable: URL, pullRequest: TaskPullRequest, worktree: URL, version: String?
    ) throws -> URL {
        let folder = folder(in: outputFolder, id: id)
        remove(in: outputFolder, id: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let numbers = version?.split(separator: ".", omittingEmptySubsequences: false) ?? []
        let isRelease = numbers.count == 3 && numbers.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCIINumber) }
        let manifest: [String: Any] = [
            "name": name,
            "description": "BriefBar's check of each push in one of its Push & Reply tasks, as Copilot makes it",
            "version": isRelease ? version! : "0.0.0",
        ]
        let hook: [String: Any] = [
            "type": "command", "bash": command(executable: executable, pullRequest: pullRequest, worktree: worktree),
            "matcher": "bash", "timeoutSec": timeout,
        ]
        let hooks: [String: Any] = ["version": 1, "hooks": ["preToolUse": [hook]]]
        do {
            try write(manifest, as: "plugin.json", in: folder)
            try write(hooks, as: "hooks.json", in: folder)
        } catch {
            remove(in: outputFolder, id: id)
            throw error
        }
        return folder
    }

    private static func write(_ object: [String: Any], as name: String, in folder: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let temporary = folder.appendingPathComponent(".\(name)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, folder.appendingPathComponent(name).path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
    }

    /// Deletes a run's folder, if it has one: a link goes, not what it leads to.
    public static func remove(in outputFolder: URL, id: String) {
        try? FileManager.default.removeItem(at: folder(in: outputFolder, id: id))
    }
}

private extension Character {
    var isASCIINumber: Bool { isASCII && isNumber }
}
