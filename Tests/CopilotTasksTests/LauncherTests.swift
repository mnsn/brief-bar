import BriefBarCore
import CopilotCore
import Foundation
import Synchronization
import Testing
@testable import CopilotTasks

/// A whole send, with a real repository and a made-up `copilot` that writes a session log as the real one does.
@Suite struct CopilotLauncherTests {
    /// Records its arguments, writes a short session log, and prints the pull request it "opened".
    static let fakeCopilot = """
        #!/bin/sh
        printf '%s\\n' "$@" > "$FAKE_COPILOT_ARGUMENTS"
        while [ $# -gt 0 ]; do
          case "$1" in
            --session-id) id="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        log="$COPILOT_HOME/session-state/$id/events.jsonl"
        mkdir -p "$(dirname "$log")"
        cat > "$log" <<'EOF'
        \(Line.userMessage())
        \(Line.taskComplete("Opened https://dev.azure.com/contoso/Storefront/_git/web/pullrequest/77", at: 20))
        \(Line.event("session.shutdown", data: ["shutdownType": "routine"], at: 21))
        EOF
        echo "Pull request: https://dev.azure.com/contoso/Storefront/_git/web/pullrequest/77"
        """

    @Test(.timeLimit(.minutes(1)))
    func preparesAWorktreeAndStartsCopilotInIt() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        let copilot = fixture.folder.appendingPathComponent("bin/copilot")
        try FileManager.default.createDirectory(at: copilot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.fakeCopilot.write(to: copilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copilot.path)
        let copilotHome = fixture.folder.appendingPathComponent("copilot-home")
        let argumentsFile = fixture.folder.appendingPathComponent("arguments")
        var environment = fixture.environment
        environment["COPILOT_HOME"] = copilotHome.path
        environment["FAKE_COPILOT_ARGUMENTS"] = argumentsFile.path
        let launchEnvironment = environment

        let outputFolder = fixture.folder.appendingPathComponent("output")
        let launcher = CopilotLauncher(outputFolder: outputFolder, environment: { launchEnvironment }, locate: { _ in copilot })
        let (exits, exitSink) = AsyncStream.makeStream(of: Int32.self)
        let request = CopilotLauncher.Request(
            // As the composer shows it: the work item filled in, and the base branch left for the repository to say.
            workItem: sampleItem, prompt: PromptTemplate.render("Fix {id} from {baseBranch}", item: sampleItem),
            options: CopilotModel.quick, repository: fixture.checkout, worktreesFolder: nil
        )
        let id = "5f0e6a1c-2b7d-4c8e-9a3f-1d2c3b4a5e6f"
        let run = try await launcher.launch(request, id: id) { status in
            exitSink.yield(status)
            exitSink.finish()
        }
        var iterator = exits.makeAsyncIterator()
        #expect(await iterator.next() == 0)

        let worktree = fixture.folder.appendingPathComponent("copilot-worktrees/checkout/wi-4217")
        #expect(run.id == id)
        #expect(run.worktree.path == worktree.path)
        #expect(run.repository.path == fixture.checkout.path)
        #expect(run.workItem == sampleItem.reference)
        let events = run.events(in: copilotHome)
        #expect(FileManager.default.fileExists(atPath: events.path))
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("README.md").path))

        let arguments = try String(contentsOf: argumentsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(arguments.prefix(6) == ["-p", "Fix 4217 from main", "--model", "claude-sonnet-5.5", "--reasoning-effort", "medium"])
        #expect(arguments.contains("--session-id") && arguments.contains(id))
        #expect(arguments.suffix(3) == ["-C", worktree.path, "--silent"])
        // Its own repository isn't in a folder that Copilot's config trusts.
        #expect(!arguments.contains("--trust-folder"))

        let log = await RunMonitor().log(id: run.id, events: events)
        let status = RunStatus.derive(log: log, isRunning: DetachedProgram.isRunning(run.process), exitStatus: 0, stoppedByYou: false, output: nil)
        #expect(status.phase == .finished)
        #expect(RunTranscript.pullRequest(in: status.detail ?? "")?.absoluteString == "https://dev.azure.com/contoso/Storefront/_git/web/pullrequest/77")
        let output = run.output(in: outputFolder)
        #expect(try String(contentsOf: output, encoding: .utf8).contains("pullrequest/77"))
        let permissions = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    /// A session's ID names its files, so it has to be one.
    @Test func takesOnlyASessionsIDAsOne() async throws {
        let launcher = CopilotLauncher(outputFolder: URL(fileURLWithPath: "/nonexistent"), environment: { [:] }, locate: { _ in nil })
        let request = CopilotLauncher.Request(workItem: sampleItem, prompt: "Fix it", options: CopilotModel.standard, repository: URL(fileURLWithPath: "/"), worktreesFolder: nil)
        await #expect(throws: LaunchError.couldntStart("a session's ID is a lowercase UUID")) {
            try await launcher.launch(request, id: "../../Library/Messages/chat") { _ in }
        }
    }

    /// A repository you trust gives its worktree the same trust, so Copilot loads its skills and MCP servers.
    @Test(.timeLimit(.minutes(1)))
    func trustsTheWorktreeOfATrustedRepository() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        let copilotHome = fixture.folder.appendingPathComponent("copilot-home")
        try FileManager.default.createDirectory(at: copilotHome, withIntermediateDirectories: true)
        try Data(#"{"trustedFolders": ["\#(fixture.checkout.path)"]}"#.utf8).write(to: copilotHome.appendingPathComponent("config.json"))
        let argumentsFile = fixture.folder.appendingPathComponent("arguments")
        var environment = fixture.environment
        environment["COPILOT_HOME"] = copilotHome.path
        environment["FAKE_COPILOT_ARGUMENTS"] = argumentsFile.path
        let launchEnvironment = environment
        let copilot = fixture.folder.appendingPathComponent("copilot")
        try Self.fakeCopilot.write(to: copilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copilot.path)

        let launcher = CopilotLauncher(outputFolder: fixture.folder.appendingPathComponent("output"), environment: { launchEnvironment }, locate: { _ in copilot })
        let (exits, exitSink) = AsyncStream.makeStream(of: Int32.self)
        let request = CopilotLauncher.Request(workItem: sampleItem, prompt: "Fix it", options: CopilotModel.standard, repository: fixture.checkout, worktreesFolder: nil)
        _ = try await launcher.launch(request) { exitSink.yield($0) }
        var iterator = exits.makeAsyncIterator()
        _ = await iterator.next()
        let arguments = try String(contentsOf: argumentsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(arguments.contains("--trust-folder"))
    }

    @Test func needsTheCopilotCLIBeforeTouchingTheRepository() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        let environment = fixture.environment
        let launcher = CopilotLauncher(outputFolder: fixture.folder, environment: { environment }, locate: { _ in nil })
        let request = CopilotLauncher.Request(workItem: sampleItem, prompt: "Fix it", options: CopilotModel.standard, repository: fixture.checkout, worktreesFolder: nil)
        await #expect(throws: LaunchError.copilotNotFound) { try await launcher.launch(request) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("copilot-worktrees").path))
    }

    @Test func refusesAFolderThatIsntARepository() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = ["PATH": "/usr/bin:/bin", "HOME": folder.path]
        let launcher = CopilotLauncher(outputFolder: folder, environment: { environment }, locate: { _ in URL(fileURLWithPath: "/usr/bin/true") })
        let request = CopilotLauncher.Request(workItem: sampleItem, prompt: "Fix it", options: CopilotModel.standard, repository: folder, worktreesFolder: nil)
        await #expect(throws: LaunchError.git(.notARepository(folder.path))) { try await launcher.launch(request) { _ in } }
    }
}
