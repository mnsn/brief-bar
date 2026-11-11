import BriefBarCore
import Foundation
import Testing
@testable import CopilotTasks

@Suite struct PushGuardPluginTests {
    private let pullRequest = TaskPullRequest(
        organization: "contoso", project: "Storefront", repository: "checkout", id: 4071, title: "Fix the checkout total",
        url: URL(string: "https://dev.azure.com/contoso/Storefront/_git/checkout/pullrequest/4071")!,
        sourceBranch: "users/robin/it's-total", targetBranch: "main"
    )
    private let id = "8c3a2f4e-5d0f-4f1a-9d6b-4a5b6c7d8e9f"

    private func json(_ file: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    private func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    /// A folder only you can open, with the CLI's legacy layout: its manifest, and the hook for `bash` alone, in time for
    /// the check's limit, each file only you can read; nothing else there.
    @Test func writesTheRunsOwnPlugin() throws {
        let output = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        let worktree = URL(fileURLWithPath: "/Users/robin/copilot-worktrees/checkout/pr-4071", isDirectory: true)
        let folder = try PushGuardPlugin.write(
            in: output, id: id, executable: URL(fileURLWithPath: "/Applications/BriefBar.app/Contents/MacOS/BriefBar"),
            pullRequest: pullRequest, worktree: worktree, version: "1.4.2"
        )
        #expect(folder == PushGuardPlugin.folder(in: output, id: id))
        #expect(folder.lastPathComponent == "\(id).guard")
        #expect(try mode(folder) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["hooks.json", "plugin.json"])
        for file in ["hooks.json", "plugin.json"] {
            #expect(try mode(folder.appendingPathComponent(file)) == 0o600)
        }
        let manifest = try json(folder.appendingPathComponent("plugin.json"))
        #expect(manifest["name"] as? String == "briefbar-push-guard")
        #expect(manifest["version"] as? String == "1.4.2")
        let hooks = try json(folder.appendingPathComponent("hooks.json"))
        #expect(hooks["version"] as? Int == 1)
        let entries = try #require((hooks["hooks"] as? [String: Any])?["preToolUse"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries[0]["type"] as? String == "command")
        #expect(entries[0]["matcher"] as? String == "bash")
        #expect(entries[0]["timeoutSec"] as? Int == 300)
        #expect(TimeInterval(PushGuardPlugin.timeout) > PushGuard.limit)
        #expect(entries[0]["bash"] as? String == """
            '/Applications/BriefBar.app/Contents/MacOS/BriefBar' '--push-guard' \
            'https://dev.azure.com/contoso/Storefront/_git/checkout/pullrequest/4071' \
            '--worktree=/Users/robin/copilot-worktrees/checkout/pr-4071' '--source-branch=users/robin/it'\\''s-total' \
            '--target-branch=main'
            """)
    }

    /// A build that isn't a release, as one from source, is 0.0.0 to the CLI.
    @Test(arguments: [nil, "1.4", "1.4.2-beta", "1.4.x", "1..2"])
    func versionsOnlyARelease(_ version: String?) throws {
        let output = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        let folder = try PushGuardPlugin.write(
            in: output, id: id, executable: URL(fileURLWithPath: "/B/BriefBar"), pullRequest: pullRequest,
            worktree: URL(fileURLWithPath: "/w"), version: version
        )
        #expect(try json(folder.appendingPathComponent("plugin.json"))["version"] as? String == "0.0.0")
    }

    /// Written afresh in place of what's there, a link included, which goes, not what it leads to; and removed the same way.
    @Test func replacesWhatsThereWithoutFollowingALink() throws {
        let output = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        let elsewhere = output.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: elsewhere.appendingPathComponent("hooks.json"))
        let folder = PushGuardPlugin.folder(in: output, id: id)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)

        _ = try PushGuardPlugin.write(
            in: output, id: id, executable: URL(fileURLWithPath: "/B/BriefBar"), pullRequest: pullRequest,
            worktree: URL(fileURLWithPath: "/w"), version: nil
        )
        #expect(!LocalFile.isLink(folder))
        #expect(try String(contentsOf: elsewhere.appendingPathComponent("hooks.json"), encoding: .utf8) == "kept")

        PushGuardPlugin.remove(in: output, id: id)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)
        PushGuardPlugin.remove(in: output, id: id)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)) == nil)
        #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("hooks.json").path))
    }

    /// Where it can't write, it throws, and leaves nothing.
    @Test func throwsWhereItCantWrite() throws {
        let output = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path)
            try? FileManager.default.removeItem(at: output)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: output.path)
        #expect(throws: (any Error).self) {
            try PushGuardPlugin.write(
                in: output, id: id, executable: URL(fileURLWithPath: "/B/BriefBar"), pullRequest: pullRequest,
                worktree: URL(fileURLWithPath: "/w"), version: nil
            )
        }
        #expect(!FileManager.default.fileExists(atPath: PushGuardPlugin.folder(in: output, id: id).path))
    }

    /// BriefBar's executable, unless it runs from where macOS moved it for now.
    @Test func givesTheHookOnlyAnExecutableThatStays() {
        let installed = URL(fileURLWithPath: "/Applications/BriefBar.app/Contents/MacOS/BriefBar")
        #expect(PushGuardPlugin.executable(installed) == installed)
        #expect(PushGuardPlugin.executable(nil) == nil)
        #expect(PushGuardPlugin.executable(URL(string: "https://example.com/BriefBar")) == nil)
        let translocated = URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/0A1B/d/BriefBar.app/Contents/MacOS/BriefBar")
        #expect(PushGuardPlugin.executable(translocated) == nil)
    }

    /// The version `copilot --version` says, in its words.
    @Test func readsTheCLIsVersion() {
        #expect(CopilotLauncher.version(in: "GitHub Copilot CLI 1.0.108.\nRun 'copilot update' to check for updates.\n")
            == CopilotServer.Version("1.0.108"))
        #expect(CopilotLauncher.version(in: "1.0.57") == CopilotServer.Version("1.0.57"))
        #expect(CopilotLauncher.version(in: "GitHub Copilot CLI") == nil)
        #expect(CopilotServer.Version("1.0.56")! < PushGuardPlugin.oldest)
        #expect(CopilotServer.Version("1.0.57-0")! < PushGuardPlugin.oldest)
        #expect(CopilotServer.Version("1.1.0")! >= PushGuardPlugin.oldest)
    }

    /// Each plugin for the run alone, before the session's ID.
    @Test func loadsThePluginForTheRunAlone() {
        let arguments = CopilotCommand.arguments(
            prompt: "Push", options: CopilotModel.standard, sessionId: "s", name: nil, directory: URL(fileURLWithPath: "/w"),
            plugins: [URL(fileURLWithPath: "/o/s.guard", isDirectory: true)]
        )
        #expect(arguments.joined(separator: " ").contains("--no-ask-user --plugin-dir /o/s.guard --session-id s"))
    }
}
