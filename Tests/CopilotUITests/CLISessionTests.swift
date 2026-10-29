import BriefBarCore
import BriefBarUI
import CopilotCore
import Foundation
import Testing
@testable import CopilotUI

/// Opening a session with the Copilot CLI on a Mac without the app, from the click to Terminal, with what that does
/// beyond BriefBar stood in for. One test at a time: they share what's being opened.
@MainActor
@Suite(.serialized) struct CLISessionTests {
    private let id = "5d2e8a90-1f3b-4e7c-8a26-7b9c0d4e5f02"
    private let paths = CopilotPaths(root: URL(fileURLWithPath: "/Users/robin/.copilot", isDirectory: true))

    /// Your login shell, which answers when the test says.
    @MainActor private final class Shell {
        private var waiting: CheckedContinuation<[String: String], Never>?

        func environment() async -> [String: String] {
            await withCheckedContinuation { waiting = $0 }
        }

        /// Until the session being opened asks.
        func asked() async {
            while waiting == nil { await Task.yield() }
        }

        func answer() {
            waiting?.resume(returning: ["PATH": "/usr/bin:/bin"])
            waiting = nil
        }
    }

    /// What opening a session did beyond BriefBar.
    @MainActor private final class Outside {
        var read: [String] = []
        var launched: [URL] = []
        var said: [String] = []
        var opens = true
    }

    private func standIn(_ shell: Shell, _ outside: Outside) -> CLISession.Effects {
        CLISession.Effects(
            environment: { await shell.environment() },
            holder: { _ in
                outside.read.append("lock")
                return nil
            },
            folder: { _, _ in
                outside.read.append("folder")
                return URL(fileURLWithPath: "/Users/robin/shop", isDirectory: true)
            },
            locate: { _ in URL(fileURLWithPath: "/opt/homebrew/bin/copilot") },
            launch: { _, file in
                outside.launched.append(file)
                return outside.opens
            },
            show: { _ in outside.read.append("show") },
            say: { message, _ in outside.said.append(message) }
        )
    }

    /// Turning Copilot off while a session waits for your login shell, to find `copilot`, opens nothing once the shell
    /// answers: nothing more of the session is read, and no script is written or opened.
    @Test(.timeLimit(.minutes(1)))
    func turningCopilotOffWhileItFindsTheCLIOpensNothing() async throws {
        let shell = Shell()
        let outside = Outside()
        CLISession.stop()
        CLISession.effects = standIn(shell, outside)
        defer {
            CLISession.effects = CLISession.Effects()
            CLISession.stop()
        }
        let source = CopilotSource(services: AppServices(defaults: MemoryDefaults(), isDemo: false))

        let stopped = try #require(CLISession.open(id, paths: paths))
        await shell.asked()
        #expect(outside.read == ["lock"])
        source.stop()
        shell.answer()
        await stopped.value
        #expect(outside.read == ["lock"])
        #expect(outside.launched.isEmpty)
        #expect(outside.said.isEmpty)

        // Left on, the same click opens it.
        let opened = try #require(CLISession.open(id, paths: paths))
        await shell.asked()
        shell.answer()
        await opened.value
        #expect(outside.read == ["lock", "lock", "lock", "folder"])
        #expect(outside.launched == [CLISession.script(for: id)])
        #expect(outside.said.isEmpty)
        // It's starting in Terminal: another click starts nothing more.
        #expect(CLISession.open(id, paths: paths) == nil)
    }

    /// A script nothing opened says so, with the command to run instead, and the next click tries again.
    @Test(.timeLimit(.minutes(1)))
    func aScriptNothingOpenedLetsTheNextClickTryAgain() async throws {
        let shell = Shell()
        let outside = Outside()
        outside.opens = false
        CLISession.stop()
        CLISession.effects = standIn(shell, outside)
        defer {
            CLISession.effects = CLISession.Effects()
            CLISession.stop()
        }

        let first = try #require(CLISession.open(id, paths: paths))
        await shell.asked()
        shell.answer()
        await first.value
        #expect(outside.launched.count == 1)
        #expect(outside.said == ["The session didn't open in Terminal"])

        outside.opens = true
        let again = try #require(CLISession.open(id, paths: paths))
        await shell.asked()
        shell.answer()
        await again.value
        #expect(outside.launched.count == 2)
        #expect(outside.said.count == 1)
    }

    /// The command to open a session yourself names its Copilot folder only when your shell's is another.
    @Test func tellsYouTheCommandForItsCopilotFolder() {
        let home = URL(fileURLWithPath: "/Users/robin", isDirectory: true)
        let plain = "copilot --resume \(id)"
        #expect(CLISession.manualCommand(id, home: home.appendingPathComponent(".copilot"), environment: [:], userHome: home) == plain)
        #expect(CLISession.manualCommand(
            id, home: URL(fileURLWithPath: "/Volumes/work/copilot"), environment: ["COPILOT_HOME": "/Volumes/work/copilot"], userHome: home
        ) == plain)
        #expect(CLISession.manualCommand(id, home: URL(fileURLWithPath: "/Users/robin/Robin's copilot"), environment: [:], userHome: home)
            == "COPILOT_HOME='/Users/robin/Robin'\\''s copilot' \(plain)")
        #expect(CLISession.manualCommand(
            id, home: home.appendingPathComponent(".copilot"), environment: ["COPILOT_HOME": "/Volumes/work/copilot"], userHome: home
        ) == "COPILOT_HOME='/Users/robin/.copilot' \(plain)")
    }
}
