import BriefBarCore
import Foundation
import Synchronization
import Testing
@testable import CopilotTasks

/// BriefBar among the Copilot CLI's MCP servers, through `copilot mcp get`, `add` and `remove`, against a made-up CLI.
@Suite struct CopilotMCPRegistrationTests {
    private static let briefBar = "/Applications/BriefBar.app/Contents/MacOS/BriefBar"

    private static func server(command: String = briefBar, args: [String] = ["--mcp"], enabled: Bool = true) -> String {
        let json = try! JSONSerialization.data(withJSONObject: [
            "briefbar": ["type": "local", "command": command, "args": args, "tools": ["*"], "source": "user", "enabled": enabled],
        ])
        return String(decoding: json, as: UTF8.self)
    }

    private static let notFound = ProcessResult.failure("Error: Server \"briefbar\" not found.\n\nAvailable servers:\n  github-mcp-server\n", status: 1)

    /// A CLI that keeps one server named briefbar, or none, and changes it as asked.
    final class CLI: Sendable {
        let runner: FakeRunner

        init(_ server: String?) {
            let stored = Mutex<String?>(server)
            runner = FakeRunner { arguments in
                switch Array(arguments.prefix(2)) {
                case ["mcp", "get"]:
                    return stored.withLock { $0 }.map { .ok($0) } ?? CopilotMCPRegistrationTests.notFound
                case ["mcp", "add"]:
                    return stored.withLock { current in
                        guard current == nil else { return .failure("Error: Server \"briefbar\" already exists.", status: 1) }
                        let command = arguments[arguments.firstIndex(of: "--")! + 1]
                        current = CopilotMCPRegistrationTests.server(command: command, args: Array(arguments.suffix(1)))
                        return .ok("Added")
                    }
                case ["mcp", "remove"]:
                    return stored.withLock { current in
                        guard current != nil else { return CopilotMCPRegistrationTests.notFound }
                        current = nil
                        return .ok("Removed server \"briefbar\"")
                    }
                default:
                    return .failure("unexpected", status: 2)
                }
            }
        }

        var registration: CopilotMCPRegistration {
            CopilotMCPRegistration(
                cli: URL(fileURLWithPath: "/opt/homebrew/bin/copilot"), environment: [:],
                executable: CopilotMCPRegistrationTests.briefBar, runner: runner
            )
        }
    }

    @Test func readsWhatTheCLISays() {
        let executable = Self.briefBar
        #expect(CopilotMCPRegistration.status(of: Data(Self.server().utf8), executable: executable) == .added(enabled: true))
        #expect(CopilotMCPRegistration.status(of: Data(Self.server(enabled: false).utf8), executable: executable) == .added(enabled: false))
        #expect(CopilotMCPRegistration.status(of: Data(Self.server(command: "/tmp/build/BriefBar").utf8), executable: executable)
            == .addedElsewhere("/tmp/build/BriefBar"))
        #expect(CopilotMCPRegistration.status(of: Data(Self.server(command: "/usr/local/bin/node", args: ["brief.js"]).utf8), executable: executable)
            == .taken)
        #expect(CopilotMCPRegistration.status(of: Data(Self.server(args: ["--json"]).utf8), executable: executable) == .taken)
        // Whatever it printed before its answer.
        #expect(CopilotMCPRegistration.status(of: Data(("A newer version is out.\n" + Self.server()).utf8), executable: executable)
            == .added(enabled: true))
        if case .failed = CopilotMCPRegistration.status(of: Data("nope".utf8), executable: executable) {} else {
            Issue.record("Read an answer that isn't one")
        }
    }

    @Test func addsBriefBarWhenItsAbsent() async {
        let cli = CLI(nil)
        #expect(await cli.registration.status() == .absent)
        #expect(await cli.registration.add() == .added(enabled: true))
        #expect(cli.runner.arguments.contains(["mcp", "add", "briefbar", "--", Self.briefBar, "--mcp"]))
        // Once is enough.
        let calls = cli.runner.arguments.count
        #expect(await cli.registration.add() == .added(enabled: true))
        #expect(cli.runner.arguments.count == calls + 1)
    }

    @Test func replacesAnotherCopyOfBriefBar() async {
        let cli = CLI(Self.server(command: "/Users/me/briefbar/.build/debug/BriefBar"))
        #expect(await cli.registration.add() == .added(enabled: true))
        #expect(cli.runner.arguments.map { Array($0.prefix(2)) } == [["mcp", "get"], ["mcp", "remove"], ["mcp", "add"], ["mcp", "get"]])
    }

    @Test func leavesAServerByItsNameThatIsntBriefBar() async {
        let other = Self.server(command: "/usr/local/bin/node", args: ["briefbar.js"])
        let cli = CLI(other)
        #expect(await cli.registration.add() == .taken)
        #expect(await cli.registration.remove() == .taken)
        #expect(!cli.runner.arguments.contains { $0.prefix(2) == ["mcp", "add"] || $0.prefix(2) == ["mcp", "remove"] })
    }

    @Test func removesWhicheverCopyItRuns() async {
        let cli = CLI(Self.server(command: "/tmp/other/BriefBar"))
        #expect(await cli.registration.remove() == .absent)
        #expect(await cli.registration.remove() == .absent)
        #expect(cli.runner.arguments.filter { $0.prefix(2) == ["mcp", "remove"] }.count == 1)
    }

    @Test func saysWhyTheCLICouldnt() async {
        let runner = FakeRunner { _ in .failure("Error: Couldn't read the configuration.\nDetails follow", status: 1) }
        let registration = CopilotMCPRegistration(
            cli: URL(fileURLWithPath: "/opt/homebrew/bin/copilot"), environment: [:], executable: Self.briefBar, runner: runner
        )
        #expect(await registration.status() == .failed("Couldn't read the configuration."))
        #expect(await registration.add() == .failed("Couldn't read the configuration."))
    }
}
