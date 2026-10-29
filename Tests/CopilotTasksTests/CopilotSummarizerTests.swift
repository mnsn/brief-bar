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
        let failing = FakeRunner { _ in .failure("\u{1B}[31mError: Something broke.\u{1B}[0m\nTry again later.\n", status: 1) }
        #expect(await summarizer(failing, folder: folder).summarize("Sum it up", options: options)
            == .failure(.failed("Error: Something broke. Try again later.")))
        let silent = FakeRunner { _ in .ok("  \n") }
        #expect(await summarizer(silent, folder: folder).summarize("Sum it up", options: options) == .failure(.empty))
        let none = FakeRunner { _ in .ok("Never runs") }
        #expect(await summarizer(none, folder: folder, finds: false).summarize("Sum it up", options: options) == .failure(.noCLI))
        #expect(none.arguments.isEmpty)
    }

    /// What the CLI says when it fails often, made up after its own words: a sentence each, and what it said for its
    /// tooltip.
    @Test func itSaysWhatFailedInASentence() async {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        func failure(_ stderr: String) async -> CopilotSummarizer.Failure? {
            let runner = FakeRunner { _ in .failure(stderr, status: 1) }
            guard case .failure(let failure) = await summarizer(runner, folder: folder).summarize("Sum it up", options: options) else {
                return nil
            }
            return failure
        }
        let signedOut = await failure("Error: No authentication information found.\n\nCopilot can be authenticated with GitHub using an OAuth Token or a Fine-Grained Personal Access Token.\n")
        #expect(signedOut == .notSignedIn(
            "Error: No authentication information found. Copilot can be authenticated with GitHub using an OAuth Token or a Fine-Grained Personal Access Token."
        ))
        #expect(signedOut?.message(model: "Claude Haiku 5.5") == "The Copilot CLI isn't signed in. Run copilot in Terminal once.")
        #expect(await failure("Could not obtain an authentication token. Please log out and log in again with /login.")
            == .notSignedIn("Could not obtain an authentication token. Please log out and log in again with /login."))

        let model = await failure("\u{1B}[31mError: Model \"claude-haiku-5.5\" from --model flag is not available.\u{1B}[0m\n")
        #expect(model == .modelUnavailable("Error: Model \"claude-haiku-5.5\" from --model flag is not available."))
        #expect(model?.message(model: "Claude Haiku 5.5") == "Claude Haiku 5.5 isn't on your Copilot plan.")
        #expect(model?.detail == "Error: Model \"claude-haiku-5.5\" from --model flag is not available.")

        for spent in [
            "Error: You have exceeded your premium request allowance for this month.",
            "Error: 402 Payment Required: quota exceeded",
            "Error: You're out of AI credits until your plan renews.",
        ] {
            let failure = await failure(spent)
            #expect(failure == .outOfRequests(spent))
            #expect(failure?.message(model: "Claude Haiku 5.5") == "You're out of premium requests this month.")
        }

        // Anything else, in its own words.
        let other = await failure("Error: 429 Too Many Requests: rate limit exceeded")
        #expect(other == .failed("Error: 429 Too Many Requests: rate limit exceeded"))
        #expect(other?.message(model: "Claude Haiku 5.5") == "Copilot couldn't write it: Error: 429 Too Many Requests: rate limit exceeded")
        #expect(other?.detail == nil)
        #expect(CopilotSummarizer.Failure.noCLI.message(model: "Claude Haiku 5.5")
            == "BriefBar can't find the Copilot CLI. Install it, or open the GitHub Copilot app once.")
    }

    @Test func itTellsWhetherTheCLIIsThere() async {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = FakeRunner { _ in .ok("Never runs") }
        #expect(await summarizer(runner, folder: folder).findsCLI() == true)
        #expect(await summarizer(runner, folder: folder, finds: false).findsCLI() == false)
        #expect(runner.arguments.isEmpty)
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

    @Test func cancelledWhileYourEnvironmentLoadsItStartsNothing() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let loads = Mutex(0)
        let gate = Gate()
        let copilot = self.copilot
        let runner = FakeRunner { _ in .ok("HEADLINE: Done.") }
        let summarizer = CopilotSummarizer(
            runner: runner, folder: folder,
            loadEnvironment: {
                loads.withLock { $0 += 1 }
                await gate.wait()
                return ["PATH": "/opt/homebrew/bin:/usr/bin"]
            },
            locate: { _ in copilot }
        )
        let options = self.options
        let summary = Task { await summarizer.summarize("Sum it up", options: options) }
        for _ in 0..<200 where !gate.isWaiting {
            try await Task.sleep(for: .milliseconds(5))
        }
        summary.cancel()
        gate.open()
        #expect(await summary.value == .failure(.cancelled))
        #expect(runner.arguments.isEmpty)
        // What the shell said by then isn't kept: it's asked again.
        #expect(await summarizer.summarize("Sum it up", options: options) == .success("HEADLINE: Done."))
        #expect(loads.withLock { $0 } == 2)
        #expect(runner.arguments.count == 1)
    }

    @Test func cancelledWhileCopilotWritesItSaysSo() async {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copilot = self.copilot
        let summarizer = CopilotSummarizer(
            runner: CancelledRunner(), folder: folder, loadEnvironment: { [:] }, locate: { _ in copilot }
        )
        #expect(await summarizer.summarize("Sum it up", options: options) == .failure(.cancelled))
    }

    /// Stopped, as `ProcessRunner` is once its task is cancelled.
    private struct CancelledRunner: ProcessRunning {
        func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval) async throws -> ProcessResult {
            throw CancellationError()
        }
    }

    /// Holds what waits until it's let go.
    private final class Gate: Sendable {
        private let state = Mutex<(opened: Bool, waiting: CheckedContinuation<Void, Never>?)>((false, nil))

        var isWaiting: Bool { state.withLock { $0.waiting != nil } }

        func wait() async {
            await withCheckedContinuation { continuation in
                let open = state.withLock { state in
                    if state.opened { return true }
                    state.waiting = continuation
                    return false
                }
                if open { continuation.resume() }
            }
        }

        func open() {
            let waiting = state.withLock { state in
                state.opened = true
                defer { state.waiting = nil }
                return state.waiting
            }
            waiting?.resume()
        }
    }
}
