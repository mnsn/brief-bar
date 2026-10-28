import BriefBarCore
import Darwin
import Foundation
import Testing
@testable import CopilotTasks

/// BriefBar's plugin for Copilot, as it is in `Resources/CopilotPlugin`: a marketplace on this Mac with one plugin in
/// the Agent Plugins 1.0 format, whose one skill, `/briefbar`, names only BriefBar's tools and the app's that it uses.
/// The build adds BriefBar's version to it (scripts/build-app.sh), and scripts/check-app.sh checks that.
@Suite struct CopilotPluginTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/CopilotPlugin", isDirectory: true)
    static let plugin = folder.appendingPathComponent("briefbar", isDirectory: true)
    static let skill = plugin.appendingPathComponent("skills/briefbar/SKILL.md")

    /// What the skill may name besides BriefBar's tools, their arguments and values: the GitHub Copilot app's tools and
    /// what they take.
    static let appVocabulary: Set<String> = [
        "briefbar", "render_widget", "discover_widgets", "inbox", "list_repositories", "add_repository", "create_session",
        "project_id", "workspace_type", "worktree", "name", "kickoff", "mode", "interactive", "autopilot", "plan", "prompt",
        "coordinate_with_creator", "notify_on_idle", "once", "send_session_message", "list_sessions_and_chats", "navigate_to",
    ]

    static func object(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "\(url.path) isn't a JSON object")
    }

    @Test func marketplaceListsThePlugin() throws {
        let marketplace = try Self.object(Self.folder.appendingPathComponent("marketplace.json"))
        #expect(marketplace["name"] as? String == CopilotPluginRegistration.name)
        #expect((marketplace["owner"] as? [String: Any])?["name"] as? String == "BriefBar")
        let plugins = try #require(marketplace["plugins"] as? [[String: Any]])
        #expect(plugins.count == 1)
        #expect(plugins.first?["name"] as? String == CopilotPluginRegistration.name)
        #expect(plugins.first?["source"] as? String == "./briefbar")
        // The build sets it to BriefBar's.
        #expect(plugins.first?["version"] == nil)
        #expect(Self.folder.lastPathComponent == CopilotPluginRegistration.folderName)
    }

    @Test func pluginFollowsAgentPlugins() throws {
        let manifest = try Self.object(Self.plugin.appendingPathComponent("plugin.json"))
        #expect(manifest["$schema"] as? String == "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json")
        #expect(manifest["name"] as? String == CopilotPluginRegistration.name)
        #expect(manifest["version"] == nil)
        #expect(!((manifest["description"] as? String) ?? "").isEmpty)
        // Its manifest is closed: the CLI ignores anything else.
        let fields: Set<String> = ["$schema", "name", "version", "description", "author", "homepage", "repository", "license", "keywords", "extensions"]
        #expect(Set(manifest.keys).isSubset(of: fields), "\(Set(manifest.keys).subtracting(fields))")
        // Only the skill: BriefBar's MCP server is added on its own, when agents are turned on.
        let contents = try FileManager.default.contentsOfDirectory(atPath: Self.plugin.path).sorted()
        #expect(contents == ["plugin.json", "skills"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: Self.plugin.appendingPathComponent("skills").path) == ["briefbar"])
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
    }

    /// The skill's points, each a line starting with "- " and the indented lines after it.
    static func points(in text: String) -> [String] {
        var points: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("- ") {
                points.append(String(line.dropFirst(2)))
            } else if line.hasPrefix("  "), !points.isEmpty {
                points[points.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            }
        }
        return points
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
    static func listedTools() throws -> [[String: Any]] {
        let binary = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("BriefBar")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "Build BriefBar first (swift build): \(binary.path)")
        let copilot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: copilot) }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--demo", "--mcp"]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": copilot.path, "BRIEFBAR_COPILOT_DIR": copilot.path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"tests","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ]
        input.fileHandleForWriting.write(Data((messages.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let answer = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for line in answer.split(separator: 0x0A) {
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  message["id"] as? Int == 2, let result = message["result"] as? [String: Any]
            else { continue }
            return try #require(result["tools"] as? [[String: Any]])
        }
        Issue.record("BriefBar --demo --mcp didn't list its tools: \(String(decoding: answer, as: UTF8.self))")
        return []
    }

    @Test(.timeLimit(.minutes(2)), .enabled(if: canTellProgramsApart, "macOS doesn't say enough here to tell"))
    func skillNamesOnlyRealTools() throws {
        let tools = try Self.listedTools()
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names.isSuperset(of: ["needs_me", "pull_request_prompt", "copilot_sessions"]))
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
        // And it tells agents about every tool.
        let missing = names.filter { !text.contains("`\($0)`") }
        #expect(missing.isEmpty, "The skill doesn't mention \(missing.sorted())")
    }
}

private final class Marker {}
