import BriefBarCore
import Foundation
import Synchronization
import Testing
@testable import CopilotTasks

/// A summary from the Copilot CLI: with no tools at all, in a folder of BriefBar's own, and what it answered or why it
/// didn't.
@Suite struct CopilotSummarizerTests {
    private let options = CopilotRunOptions(model: "claude-haiku-5.5", effort: "low")
    private let copilot = URL(fileURLWithPath: "/opt/homebrew/bin/copilot")

    private func summarizer(_ runner: FakeRunner, folder: URL, finds: Bool = true) -> CopilotSummarizer {
        let copilot = self.copilot
        return CopilotSummarizer(
            runner: runner, folder: folder, loadEnvironment: { ["PATH": "/opt/homebrew/bin:/usr/bin"] },
            locate: { _ in finds ? copilot : nil }
        )
    }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("summaries-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func itRunsWithNoToolsAtAllAndNothingOfYours() {
        let folder = URL(fileURLWithPath: "/Users/robin/Library/Application Support/BriefBar/Copilot/Summaries")
        let arguments = CopilotSummarizer.arguments(prompt: "Sum it up", options: options, folder: folder)
        #expect(arguments == [
            "-p", "Sum it up", "--model", "claude-haiku-5.5", "--reasoning-effort", "low",
            // A tool nobody has: the model gets none. An empty list would leave it every tool.
            "--available-tools=briefbar_no_tools", "--deny-tool", "shell", "--deny-tool", "write",
            "--disable-builtin-mcps", "--no-custom-instructions", "--no-ask-user", "--no-color", "--silent",
            "--name", "BriefBar summary", "-C", folder.path,
        ])
        #expect(!arguments.contains("--allow-all-tools"))
        #expect(!arguments.contains("--autopilot"))
        #expect(CopilotSummarizer.arguments(prompt: "x", options: CopilotRunOptions(model: "auto", effort: nil), folder: folder)
            .contains("--reasoning-effort") == false)
    }

    @Test func itAnswersWhatCopilotPrinted() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = FakeRunner { _ in .ok("HEADLINE: Waiting for review.\nNEXT: Nothing\n") }
        let answer = await summarizer(runner, folder: folder).summarize("Sum it up", options: options)
        #expect(answer == .success("HEADLINE: Waiting for review.\nNEXT: Nothing"))
        #expect(runner.arguments.count == 1)
        // Its folder is BriefBar's own, and only you can read it.
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func itSaysWhyThereIsNoSummary() async {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let failing = FakeRunner { _ in .failure("\u{1B}[31mError: Model \"x\" is not available.\u{1B}[0m\nTry another one.\n", status: 1) }
        #expect(await summarizer(failing, folder: folder).summarize("Sum it up", options: options)
            == .failure(.failed("Error: Model \"x\" is not available. Try another one.")))
        let silent = FakeRunner { _ in .ok("  \n") }
        #expect(await summarizer(silent, folder: folder).summarize("Sum it up", options: options) == .failure(.empty))
        let none = FakeRunner { _ in .ok("Never runs") }
        #expect(await summarizer(none, folder: folder, finds: false).summarize("Sum it up", options: options) == .failure(.noCLI))
        #expect(none.arguments.isEmpty)
    }

    @Test func itAsksForYourShellsEnvironmentOnce() async {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let loads = Mutex(0)
        let copilot = self.copilot
        let summarizer = CopilotSummarizer(
            runner: FakeRunner { _ in .ok("HEADLINE: Done.") }, folder: folder,
            loadEnvironment: {
                loads.withLock { $0 += 1 }
                return [:]
            },
            locate: { _ in copilot }
        )
        _ = await summarizer.summarize("One", options: options)
        _ = await summarizer.summarize("Two", options: options)
        #expect(loads.withLock { $0 } == 1)
    }
}
