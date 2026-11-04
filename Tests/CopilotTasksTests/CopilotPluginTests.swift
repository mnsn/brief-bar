import BriefBarCore
import Darwin
import Foundation
import Testing
@testable import CopilotTasks

/// BriefBar's plugins for Copilot, as they are in `Resources/CopilotPlugin`: a marketplace on this Mac with two plugins in
/// the Agent Plugins 1.0 format. One has one skill, `/briefbar`, which names only BriefBar's tools and the app's that it
/// uses; the other, only BriefBar's extension for the app's sessions. The build adds BriefBar's version to them
/// (scripts/build-app.sh), and scripts/check-app.sh checks that.
@Suite struct CopilotPluginTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/CopilotPlugin", isDirectory: true)
    static let plugin = folder.appendingPathComponent("briefbar", isDirectory: true)
    static let skill = plugin.appendingPathComponent("skills/briefbar/SKILL.md")
    static let sessions = folder.appendingPathComponent("briefbar-sessions", isDirectory: true)
    /// The fields of a plugin's manifest that the CLI reads: it ignores anything else.
    static let manifestFields: Set<String> = [
        "$schema", "name", "version", "description", "author", "homepage", "repository", "license", "keywords", "extensions",
    ]

    /// What the skill may name besides BriefBar's tools, their arguments and values: the GitHub Copilot app's tools and
    /// what they take.
    static let appVocabulary: Set<String> = [
        "briefbar", "render_widget", "discover_widgets", "inbox", "list_repositories", "add_repository", "create_session",
        "project_id", "workspace_type", "worktree", "name", "kickoff", "mode", "interactive", "autopilot", "plan", "prompt",
        "coordinate_with_creator", "notify_on_idle", "once", "send_session_message", "fork_session", "list_sessions_and_chats",
        "navigate_to",
    ]

    /// Pull Request Order's tools, which `--demo --mcp` lists, as Pull Request Order is on there. They're for the sessions
    /// that open pull requests together, not for `/briefbar`, which leaves them out.
    static let orderTools: Set<String> = ["order_pull_requests", "pull_request_order", "forget_pull_request_order"]

    static func object(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "\(url.path) isn't a JSON object")
    }

    /// What's in a folder, without what Finder adds, such as .DS_Store, which the build leaves out.
    static func contents(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    @Test func marketplaceListsThePlugins() throws {
        let marketplace = try Self.object(Self.folder.appendingPathComponent("marketplace.json"))
        #expect(marketplace["name"] as? String == CopilotPluginRegistration.name)
        #expect((marketplace["owner"] as? [String: Any])?["name"] as? String == "BriefBar")
        let plugins = try #require(marketplace["plugins"] as? [[String: Any]])
        // BriefBar's, each in a folder of its own, at BriefBar's version, which the build sets.
        #expect(plugins.compactMap { $0["name"] as? String } == CopilotPluginRegistration.Plugin.allCases.map(\.rawValue))
        for plugin in plugins {
            let name = try #require(plugin["name"] as? String)
            #expect(plugin["source"] as? String == "./\(name)")
            #expect(plugin["version"] == nil, "\(name)")
            #expect(!((plugin["description"] as? String) ?? "").isEmpty, "\(name)")
        }
        #expect(Self.folder.lastPathComponent == CopilotPluginRegistration.folderName)
        #expect(try Self.contents(Self.folder) == ["briefbar", "briefbar-sessions", "marketplace.json"])
    }

    @Test func pluginFollowsAgentPlugins() throws {
        let manifest = try Self.object(Self.plugin.appendingPathComponent("plugin.json"))
        #expect(manifest["$schema"] as? String == "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json")
        #expect(manifest["name"] as? String == CopilotPluginRegistration.name)
        #expect(manifest["version"] == nil)
        #expect(!((manifest["description"] as? String) ?? "").isEmpty)
        // Its manifest is closed: the CLI ignores anything else.
        #expect(Set(manifest.keys).isSubset(of: Self.manifestFields), "\(Set(manifest.keys).subtracting(Self.manifestFields))")
        // Only the skill: BriefBar's MCP server is added on its own, when agents are turned on.
        #expect(try Self.contents(Self.plugin) == ["plugin.json", "skills"])
        #expect(try Self.contents(Self.plugin.appendingPathComponent("skills")) == ["briefbar"])
    }

    /// The other plugin holds only BriefBar's extension for the app's sessions, where the Copilot runtime finds it in an
    /// Agent Plugins 1.0 plugin: in the app's own folder, `com.github.copilot`, as it ignores `"extensions": "extensions"`
    /// there. Its tests are in Tests/CopilotPlugin, so they don't ship.
    @Test func sessionsPluginHoldsOnlyItsExtension() throws {
        let manifest = try Self.object(Self.sessions.appendingPathComponent("plugin.json"))
        #expect(manifest["$schema"] as? String == "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json")
        #expect(manifest["name"] as? String == CopilotPluginRegistration.Plugin.sessions.rawValue)
        #expect(manifest["version"] == nil)
        #expect(((manifest["description"] as? String) ?? "").contains(CopilotSessionPrompts.title))
        #expect(Set(manifest.keys).isSubset(of: Self.manifestFields), "\(Set(manifest.keys).subtracting(Self.manifestFields))")
        let extensions = try #require(manifest["extensions"] as? [String: Any])
        #expect(Array(extensions.keys) == ["com.github.copilot"])
        #expect(try Self.contents(Self.sessions) == ["com.github.copilot", "plugin.json"])
        let folder = Self.sessions.appendingPathComponent("com.github.copilot/extensions", isDirectory: true)
        #expect(try Self.contents(Self.sessions.appendingPathComponent("com.github.copilot")) == ["extensions"])
        #expect(try Self.contents(folder) == ["briefbar-sessions"])
        #expect(try Self.contents(folder.appendingPathComponent("briefbar-sessions")) == ["extension.mjs", "outbox.mjs"])
    }

    @Test func skillIsNamedForItsCommand() throws {
        let text = try String(contentsOf: Self.skill, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        #expect(lines.first == "---")
        let end = try #require(lines.dropFirst().firstIndex(of: "---"))
        let fields = Dictionary(lines[1..<end].compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { first, _ in first })
        #expect(fields["name"] == "briefbar")
        let description = try #require(fields["description"])
        #expect(!description.isEmpty && description.count <= 1024)
        // Plain YAML scalars: a colon followed by a space, or a space followed by #, would end them, and the skill
        // wouldn't load.
        for (field, value) in fields {
            #expect(!value.contains(": ") && !value.contains(" #"), "The skill's \(field) isn't a plain YAML scalar")
        }
    }

    /// The skill's points, each a line starting with "- " and the indented lines right after it.
    static func points(in text: String) -> [String] {
        var points: [String] = []
        var inPoint = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("- ") {
                points.append(String(line.dropFirst(2)))
                inPoint = true
            } else if inPoint, line.hasPrefix("  "), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                points[points.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                inPoint = false
            }
        }
        return points
    }

    /// A section of the skill, from its heading to the next.
    static func section(_ title: String, in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "## \(title)") else { return nil }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
        return lines[start..<end].joined(separator: "\n")
    }

    /// The agent asks BriefBar about a pull request before it starts a session for it or sends one a message, so that a
    /// refusal, such as agents being off, stops it before the app makes a session and a worktree for nothing.
    @Test func skillChecksThePullRequestBeforeAnySession() throws {
        let text = try String(contentsOf: Self.skill, encoding: .utf8)
        let section = try #require(Self.section("Working on a pull request", in: text))
        let check = try #require(
            section.components(separatedBy: "\n\n").first { $0.contains("call `pull_request` with it") },
            "The skill doesn't check the pull request first"
        )
        #expect(check.contains("refuses") && check.contains("start nothing"))
        let checked = try #require(section.range(of: "call `pull_request` with it"))
        for tool in ["`create_session`", "`send_session_message`", "`fork_session`", "`list_repositories`"] {
            let first = try #require(section.range(of: tool), "\(tool) isn't in the section")
            #expect(
                checked.lowerBound < first.lowerBound, "The skill reaches \(tool) before it checks the pull request"
            )
        }
    }

    /// The session `pull_request` names for a pull request is one place its work can go, beside a new session, and a fork
    /// of it when the agent talks in it: the agent asks unless the user said which, and does only that one. Wherever the
    /// work goes, its prompt is the same.
    @Test func skillOffersThePullRequestsSession() throws {
        let text = try String(contentsOf: Self.skill, encoding: .utf8)
        let section = try #require(Self.section("Working on a pull request", in: text))
        let choice = try #require(
            section.components(separatedBy: "\n\n").first { $0.contains("When `pull_request` names one of the Copilot app's sessions") },
            "The skill doesn't offer the session BriefBar names"
        )
        #expect(choice.contains("otherwise ask") && choice.contains("never both"))
        let points = Self.points(in: section)
        let its = try #require(points.first { $0.hasPrefix("**Its session.**") })
        #expect(its.contains("`send_session_message`") && its.contains("session ID"))
        // An agent's fork_session forks the session it talks in, and nothing else.
        let fork = try #require(points.first { $0.hasPrefix("**A fork of it.**") })
        #expect(fork.contains("`fork_session` forks only the session you're talking in"))
        #expect(fork.contains("`send_session_message`") && fork.contains("**Send to a Fork**"))
        let new = try #require(points.first { $0.hasPrefix("**A new session**") })
        #expect(new.contains("`create_session`") && new.contains("the prompt above"))
        #expect(section.components(separatedBy: "> Work on Azure DevOps pull request !NUMBER, LINK").count == 2)
    }

    /// When agents are off or paused, no tool of BriefBar's answers, so the agent stops. When only a source is off,
    /// `needs_me` still has the others, under their own headings, so the agent shows them.
    @Test func skillStopsOnlyWhenAgentsAreOff() throws {
        let points = Self.points(in: try String(contentsOf: Self.skill, encoding: .utf8)).map { $0.lowercased() }
        // What BriefBar answers, up to its first full stop: "Agents are off in BriefBar", "… is off in BriefBar".
        func lead(_ refusal: String) -> String {
            String(refusal.prefix { $0 != "." }).lowercased()
        }
        let agentsOff = lead(try #require(AgentAccess.refusal(.off)))
        let sourceOff = lead(String(AgentAccess.refusal(source: "Azure DevOps").dropFirst("Azure DevOps ".count)))
        #expect(agentsOff == "agents are off in briefbar")
        #expect(sourceOff == "is off in briefbar")

        let forAgents = try #require(points.first { $0.contains(agentsOff) }, "The skill doesn't say what to do when agents are off")
        #expect(forAgents.contains("stop"))
        let forASource = points.filter { $0.contains(sourceOff) }
        #expect(!forASource.isEmpty, "The skill doesn't say what to do when a source is off")
        for point in forASource {
            #expect(!point.contains("stop"), "The skill stops when only a source is off: \(point)")
            #expect(point.contains("`needs_me`"))
        }
    }

    // MARK: The tools it names

    /// Whether macOS says enough here to tell a program started plainly from one responsible for itself, which
    /// BriefBar's command-line modes refuse to run as.
    static var canTellProgramsApart: Bool {
        guard let responsible = Responsibility.responsible(for: getpid()) else { return false }
        return responsible.path != nil || responsible.pid != getpid()
    }

    /// The tools that the built `BriefBar --demo --mcp` lists to an agent, started plainly, as an agent starts it.
    static func listedTools() async throws -> [[String: Any]] {
        let binary = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("BriefBar")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "Build BriefBar first (swift build): \(binary.path)")
        let copilot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: copilot) }
        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"tests","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ]
        let answer = try await Self.runPlainly(
            binary, arguments: ["--demo", "--mcp"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": copilot.path, "BRIEFBAR_COPILOT_DIR": copilot.path],
            input: Data((messages.joined(separator: "\n") + "\n").utf8)
        )
        for line in answer.split(separator: 0x0A) {
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  message["id"] as? Int == 2, let result = message["result"] as? [String: Any]
            else { continue }
            return try #require(result["tools"] as? [[String: Any]])
        }
        Issue.record("BriefBar --demo --mcp didn't list its tools: \(String(decoding: answer, as: UTF8.self))")
        return []
    }

    /// Runs a program the usual way, attributed to this process, gives it `input`, and returns what it printed once it
    /// has ended. It's waited for on a thread of its own, never one of Swift's cooperative pool: on CI, the first run
    /// of a BriefBar just built takes 10 to 20 seconds, and a thread of the pool held that long holds up every other
    /// test, as `make test` runs them on a single one, until those waiting with a deadline give up.
    static func runPlainly(
        _ binary: URL, arguments: [String], environment: [String: String], input: Data
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = binary
                    process.arguments = arguments
                    process.environment = environment
                    let stdin = Pipe()
                    let stdout = Pipe()
                    process.standardInput = stdin
                    process.standardOutput = stdout
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    stdin.fileHandleForWriting.write(input)
                    try stdin.fileHandleForWriting.close()
                    let output = stdout.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(2)), .enabled(if: canTellProgramsApart, "macOS doesn't say enough here to tell"))
    func skillNamesOnlyRealTools() async throws {
        let tools = try await Self.listedTools()
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names.isSuperset(of: ["needs_me", "pull_request_prompt", "copilot_sessions"]))
        #expect(names.isSuperset(of: Self.orderTools))
        // Their arguments, and the values those take.
        var arguments: Set<String> = []
        for tool in tools {
            let properties = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: [String: Any]] ?? [:]
            for (name, schema) in properties {
                arguments.insert(name)
                arguments.formUnion(schema["enum"] as? [String] ?? [])
            }
        }
        let text = try String(contentsOf: Self.skill, encoding: .utf8)
        let named = Set(text.matches(of: /`([a-z][a-z0-9_]*)`/).map { String($0.output.1) })
        let unknown = named.subtracting(names).subtracting(arguments).subtracting(Self.appVocabulary)
        #expect(unknown.isEmpty, "The skill names what neither BriefBar nor the app has: \(unknown.sorted())")
        // And it tells agents about every tool but Pull Request Order's.
        let missing = names.subtracting(Self.orderTools).filter { !text.contains("`\($0)`") }
        #expect(missing.isEmpty, "The skill doesn't mention \(missing.sorted())")
    }
}

private final class Marker {}
