import BriefBarCore
import Darwin
import Foundation
import Testing
@testable import CopilotTasks

/// BriefBar's plugins for Copilot, as they are in `Resources/CopilotPlugin`: a marketplace on this Mac with three plugins
/// in the Agent Plugins 1.0 format. One has one skill, `/briefbar`, which names only BriefBar's tools and the app's that it
/// uses; another, only BriefBar's extension for the app's sessions; the third, only Pull Request Order's skill, which names
/// only its tools. The build adds BriefBar's version to them (scripts/build-app.sh), and scripts/check-app.sh checks that.
@Suite struct CopilotPluginTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/CopilotPlugin", isDirectory: true)
    static let plugin = folder.appendingPathComponent("briefbar", isDirectory: true)
    static let skill = plugin.appendingPathComponent("skills/briefbar/SKILL.md")
    static let sessions = folder.appendingPathComponent("briefbar-sessions", isDirectory: true)
    static let order = folder.appendingPathComponent("briefbar-pr-order", isDirectory: true)
    static let orderSkill = order.appendingPathComponent("skills/briefbar-pr-order/SKILL.md")
    static let updates = folder.appendingPathComponent("briefbar-updates", isDirectory: true)
    static let updatesSkill = updates.appendingPathComponent("skills/briefbar-updates/SKILL.md")
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

    /// Pull Request Order's tools, which `--demo --mcp` lists, as Pull Request Order is on there. Its own skill tells
    /// agents about them, not `/briefbar`, which leaves them out.
    static let orderTools: Set<String> = [
        "order_pull_requests", "pull_request_order", "forget_pull_request_order", "pull_request_stage",
    ]

    /// What Pull Request Order's skill may name besides its tools, their arguments and values: the todos with dependencies
    /// that a session keeps.
    static let orderVocabulary: Set<String> = ["briefbar", "todo_deps", "todo_id", "depends_on"]

    /// Updates from Copilot Sessions' tools, which `--demo --mcp` lists, as it's on there. Its own skill tells agents about
    /// them, not `/briefbar`, which leaves them out.
    static let updateTools: Set<String> = ["working_on", "changed_in_azure_devops"]

    /// What Updates from Copilot Sessions' skill may name besides its tools, their arguments and values: Pull Request
    /// Order's tools, which it doesn't replace.
    static let updatesVocabulary: Set<String> = ["briefbar", "order_pull_requests", "pull_request_stage"]

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
        #expect(try Self.contents(Self.folder) == [
            "briefbar", "briefbar-pr-order", "briefbar-sessions", "briefbar-updates", "marketplace.json",
        ])
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
        #expect(try Self.contents(folder.appendingPathComponent("briefbar-sessions")) == ["extension.mjs", "outbox.mjs", "turn.mjs"])
    }

    @Test func skillsAreNamedForTheirCommands() throws {
        for (skill, name) in [(Self.skill, "briefbar"), (Self.orderSkill, "briefbar-pr-order"), (Self.updatesSkill, "briefbar-updates")] {
            let text = try String(contentsOf: skill, encoding: .utf8)
            let lines = text.components(separatedBy: "\n")
            #expect(lines.first == "---")
            let end = try #require(lines.dropFirst().firstIndex(of: "---"))
            let fields = Dictionary(lines[1..<end].compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }, uniquingKeysWith: { first, _ in first })
            #expect(fields["name"] == name)
            let description = try #require(fields["description"])
            #expect(!description.isEmpty && description.count <= 1024)
            // Plain YAML scalars: a colon followed by a space, or a space followed by #, would end them, and the skill
            // wouldn't load.
            for (field, value) in fields {
                #expect(!value.contains(": ") && !value.contains(" #"), "\(name)'s \(field) isn't a plain YAML scalar")
            }
        }
    }

    /// Pull Request Order's plugin holds only its skill, which BriefBar installs only once you turn Pull Request Order on:
    /// until then, no session sees it.
    @Test func orderPluginHoldsOnlyItsSkill() throws {
        let manifest = try Self.object(Self.order.appendingPathComponent("plugin.json"))
        #expect(manifest["$schema"] as? String == "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json")
        #expect(manifest["name"] as? String == CopilotPluginRegistration.Plugin.order.rawValue)
        #expect(manifest["version"] == nil)
        #expect(((manifest["description"] as? String) ?? "").contains("when you turn on Pull Request Order"))
        #expect(Set(manifest.keys).isSubset(of: Self.manifestFields), "\(Set(manifest.keys).subtracting(Self.manifestFields))")
        #expect(try Self.contents(Self.order) == ["plugin.json", "skills"])
        #expect(try Self.contents(Self.order.appendingPathComponent("skills")) == ["briefbar-pr-order"])
    }

    /// Without its tools, as when Pull Request Order or agents are off, the skill does nothing, and never asks the user to
    /// turn it on; when they refuse, it stops; and it says BriefBar has an order only once BriefBar said so.
    @Test func orderSkillDoesNothingWithoutItsTools() throws {
        let points = Self.points(in: try String(contentsOf: Self.orderSkill, encoding: .utf8)).map { $0.lowercased() }
        let absent = try #require(points.first { $0.contains("`order_pull_requests` isn't there") })
        #expect(absent.contains("do nothing more") && absent.contains("never ask them to"))
        #expect(absent.contains("never change briefbar's settings or files"))
        let refused = try #require(points.first { $0.contains("pull request order is off in briefbar") })
        #expect(refused.contains("stop there"))
        let told = try #require(points.first { $0.contains("best effort") })
        #expect(told.contains("only once `order_pull_requests` answered"))
    }

    /// The skill tells sessions to keep BriefBar current without being asked: the session that did the work tells its pull
    /// requests' stages, as it pushes and as the user says they reviewed one, never Approved, Can merge, Waits or Merged;
    /// only the session that owns the plan tells an order; what the user set is kept, unless they decided otherwise
    /// together; and a story's pull requests go together by themselves, so sessions link each to its task and tell only a
    /// real order.
    @Test func orderSkillTellsStagesAndKeepsWhatTheUserSet() throws {
        let text = try String(contentsOf: Self.orderSkill, encoding: .utf8)
        let description = try #require(text.components(separatedBy: "\n").first { $0.hasPrefix("description: ") })
        #expect(description.contains("without being asked") && description.contains("each one's stage"))
        let points = Self.points(in: text).map { $0.lowercased() }
        #expect(points.contains { $0.hasPrefix("`user_review` at the end of a turn that pushed the work") })
        #expect(points.contains { $0.hasPrefix("`in_progress` as you start fixing it again") })
        #expect(points.contains { $0.hasPrefix("`teammate_review` once the user tells you they've reviewed it") })
        #expect(points.contains { $0.hasPrefix("only the session that did the work") && $0.contains("azure devops' pull requests only") })
        #expect(points.contains { $0.hasPrefix("never claim a pull request is approved, can merge, waits or merged") })
        let owner = try #require(points.first { $0.hasPrefix("only the session that owns the plan tells it") })
        #expect(owner.contains("never tells an order"))
        let kept = try #require(points.first { $0.contains("what the user changed") })
        #expect(kept.contains("keep it") && kept.contains("unless you and the user decided otherwise"))
        // A story's pull requests go together by themselves: sessions link each to its task, and tell only a real order.
        let stories = try #require(points.first { $0.contains("one story's tasks together") })
        #expect(stories.contains("link each pull request to its task"))
        #expect(points.contains { $0.hasPrefix("tell an order for them only where they must merge in another order") })
    }

    /// Updates from Copilot Sessions' plugin holds only its skill, which BriefBar installs only once you turn it on: until
    /// then, no session sees it.
    @Test func updatesPluginHoldsOnlyItsSkill() throws {
        let manifest = try Self.object(Self.updates.appendingPathComponent("plugin.json"))
        #expect(manifest["$schema"] as? String == "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json")
        #expect(manifest["name"] as? String == CopilotPluginRegistration.Plugin.updates.rawValue)
        #expect(manifest["version"] == nil)
        #expect(((manifest["description"] as? String) ?? "").contains("when you turn on Updates from Copilot Sessions"))
        #expect(Set(manifest.keys).isSubset(of: Self.manifestFields), "\(Set(manifest.keys).subtracting(Self.manifestFields))")
        #expect(try Self.contents(Self.updates) == ["plugin.json", "skills"])
        #expect(try Self.contents(Self.updates.appendingPathComponent("skills")) == ["briefbar-updates"])
    }

    /// Without its tools, the skill does nothing and never asks the user to turn them on; when they refuse, it stops; only
    /// the session doing the work tells it, never a coordinator its sessions'; and it changes Azure DevOps with the
    /// session's own tools, never through BriefBar.
    @Test func updatesSkillDoesNothingWithoutItsToolsAndTellsOnlyItsOwnWork() throws {
        let text = try String(contentsOf: Self.updatesSkill, encoding: .utf8)
        let points = Self.points(in: text).map { $0.lowercased() }
        let absent = try #require(points.first { $0.contains("`changed_in_azure_devops` aren't there") })
        #expect(absent.contains("do nothing more") && absent.contains("never ask them to"))
        #expect(absent.contains("never change briefbar's settings or files"))
        let refused = try #require(points.first { $0.contains("updates from copilot sessions is off in briefbar") })
        #expect(refused.contains("stop there"))
        let effort = try #require(points.first { $0.contains("best effort") })
        #expect(effort.contains("briefbar changes nothing in azure devops"))
        let who = try #require(points.first { $0.contains("only the session doing the work") })
        #expect(who.contains("doesn't claim their"))
        let session = try #require(points.first { $0.contains("leave `session` out") })
        #expect(session.contains("only your own session's id"))
        #expect(points.contains { $0.hasPrefix("`opened`: only the pull requests you opened yourself") })
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

    /// Once it pushed, the agent ends its turn rather than waiting on a pipeline, which can run an hour: BriefBar tells the
    /// user. It waits only on a short build, with the command `pull_request` gives and a timeout, and never again on its own.
    @Test func skillWaitsOnlyOnAShortBuild() throws {
        let text = try String(contentsOf: Self.skill, encoding: .utf8)
        let section = try #require(Self.section("Waiting on a pull request", in: text))
        let paragraphs = section.components(separatedBy: "\n\n").map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let ends = try #require(paragraphs.firstIndex { $0.contains("don't wait for its pipeline") }, "The skill waits on pipelines")
        #expect(paragraphs[ends].contains("end your turn") && paragraphs[ends].contains("Fix with Copilot…"))
        let waits = try #require(paragraphs.firstIndex { $0.contains("`pull_request` gives the command") })
        #expect(ends < waits)
        let how = paragraphs[waits]
        #expect(how.contains("only when your next step needs a short build's result"))
        #expect(how.contains("in the background") && how.contains("`--timeout`") && how.contains("120 at most"))
        #expect(how.contains("data") && how.contains("don't start it again unless the user asks"))
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

    /// The tools that the built `BriefBar --demo --mcp` lists to an agent, started plainly, as the Copilot CLI starts it.
    static func listedTools() async throws -> [[String: Any]] {
        try await demoServer().tools
    }

    /// The demo's "Add dark mode to settings" session, as the Copilot CLI names the session that starts `--mcp`.
    static let demoSession = "0b6c1f44-6a1e-4c55-9d0e-3f0a6f1c2a01"

    /// What the built `BriefBar --demo --mcp` tells an agent as it starts, started plainly, as an agent starts it: its
    /// instructions, and the tools it lists.
    /// - Parameter session: the Copilot session that starts it, as the Copilot CLI says; nil as VS Code or Cursor start it.
    static func demoServer(session: String? = demoSession) async throws -> (instructions: String, tools: [[String: Any]]) {
        let binary = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("BriefBar")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "Build BriefBar first (swift build): \(binary.path)")
        let copilot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: copilot) }
        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"tests","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ]
        var environment = ["PATH": "/usr/bin:/bin", "HOME": copilot.path, "BRIEFBAR_COPILOT_DIR": copilot.path]
        environment["COPILOT_AGENT_SESSION_ID"] = session
        let answer = try await Self.runPlainly(
            binary, arguments: ["--demo", "--mcp"], environment: environment,
            input: Data((messages.joined(separator: "\n") + "\n").utf8)
        )
        var instructions: String?
        var tools: [[String: Any]]?
        for line in answer.split(separator: 0x0A) {
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let result = message["result"] as? [String: Any]
            else { continue }
            switch message["id"] as? Int {
            case 1: instructions = result["instructions"] as? String
            case 2: tools = result["tools"] as? [[String: Any]]
            default: break
            }
        }
        guard let instructions, let tools else {
            Issue.record("BriefBar --demo --mcp didn't start and list its tools: \(String(decoding: answer, as: UTF8.self))")
            return ("", [])
        }
        return (instructions, tools)
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

    @Test(.timeLimit(.minutes(5)), .enabled(if: canTellProgramsApart, "macOS doesn't say enough here to tell"))
    func skillNamesOnlyRealTools() async throws {
        let tools = try await Self.listedTools()
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names.isSuperset(of: ["needs_me", "pull_request_prompt", "copilot_sessions"]))
        #expect(names.isSuperset(of: Self.orderTools))
        // Their arguments, and the values those take.
        let arguments = tools.reduce(into: Set<String>()) { $0.formUnion(Self.vocabulary(of: $1["inputSchema"])) }
        let text = try String(contentsOf: Self.skill, encoding: .utf8)
        let named = Set(text.matches(of: /`([a-z][a-z0-9_]*)`/).map { String($0.output.1) })
        let unknown = named.subtracting(names).subtracting(arguments).subtracting(Self.appVocabulary)
        #expect(unknown.isEmpty, "The skill names what neither BriefBar nor the app has: \(unknown.sorted())")
        // And it tells agents about every tool but Pull Request Order's and Updates from Copilot Sessions'.
        let missing = names.subtracting(Self.orderTools).subtracting(Self.updateTools).filter { !text.contains("`\($0)`") }
        #expect(missing.isEmpty, "The skill doesn't mention \(missing.sorted())")
    }

    /// `--mcp`'s instructions, while Pull Request Order's tools are listed, as in the demo, tell sessions to keep BriefBar
    /// current without being asked, a pull request's stage once they've pushed its work included; and that a story's pull
    /// requests go together by themselves, so they link each to its task and tell only a real order.
    @Test(.timeLimit(.minutes(5)), .enabled(if: canTellProgramsApart, "macOS doesn't say enough here to tell"))
    func instructionsAskForStagesAndTellOfStories() async throws {
        let instructions = try await Self.demoServer().instructions
        #expect(instructions.contains("Keep BriefBar current on your pull requests without being asked"))
        #expect(instructions.contains("after you push a pull request's work, tell its stage with pull_request_stage, user_review"))
        #expect(instructions.contains(
            "one story's tasks together by itself, in the tasks' backlog order: link each to its task as you open it, and tell "
                + "an order only where they must merge in another order, or wait for one another."
        ))
    }

    /// Started as VS Code or Cursor start it, with no Copilot session, `--mcp` lists no `pull_request_stage`, whose stages
    /// would show as another session's or never, and its instructions ask for no stage; the orders' tools stay.
    @Test(.timeLimit(.minutes(5)), .enabled(if: canTellProgramsApart, "macOS doesn't say enough here to tell"))
    func withoutACopilotSessionThereAreNoStagesToTell() async throws {
        let server = try await Self.demoServer(session: nil)
        let names = Set(server.tools.compactMap { $0["name"] as? String })
        #expect(names.isSuperset(of: Self.orderTools.subtracting(["pull_request_stage"])))
        #expect(!names.contains("pull_request_stage"))
        #expect(!server.instructions.contains("pull_request_stage"))
        #expect(server.instructions.contains("When you open pull requests that must merge in an order, tell BriefBar"))
    }

    /// Pull Request Order's skill names only its tools, what they take, a session's todos and the tools that tell a story,
    /// which BriefBar lists too, and tells agents about every one of its tools.
    @Test(.timeLimit(.minutes(5)), .enabled(if: canTellProgramsApart, "macOS doesn't say enough here to tell"))
    func orderSkillNamesOnlyItsTools() async throws {
        let listed = try await Self.listedTools()
        let tools = listed.filter { Self.orderTools.contains($0["name"] as? String ?? "") }
        #expect(Set(tools.compactMap { $0["name"] as? String }) == Self.orderTools)
        let arguments = tools.reduce(into: Set<String>()) { $0.formUnion(Self.vocabulary(of: $1["inputSchema"])) }
        let text = try String(contentsOf: Self.orderSkill, encoding: .utf8)
        let named = Set(text.matches(of: /`([a-z][a-z0-9_]*)`/).map { String($0.output.1) })
        let storyTools: Set<String> = ["pull_request", "work_item"]
        #expect(storyTools.isSubset(of: Set(listed.compactMap { $0["name"] as? String })))
        let unknown = named.subtracting(Self.orderTools).subtracting(arguments).subtracting(Self.orderVocabulary)
            .subtracting(storyTools)
        #expect(unknown.isEmpty, "Pull Request Order's skill names what its tools don't have: \(unknown.sorted())")
        let missing = Self.orderTools.filter { !text.contains("`\($0)`") }
        #expect(missing.isEmpty, "Pull Request Order's skill doesn't mention \(missing.sorted())")
    }

    /// Pull Request Order's skill has a session add reviewers in Azure DevOps only when the user asks it to, never because
    /// they named someone, since that asks a teammate for work; and says what `pull_request_stage` refuses: someone
    /// else's in progress, and a session the Copilot app doesn't list, which then leaves stages to BriefBar.
    @Test func orderSkillAddsReviewersOnlyWhenAsked() throws {
        let text = try String(contentsOf: Self.orderSkill, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(text.contains("If they ask you to add reviewers, add them in Azure DevOps with your own tools"))
        #expect(!text.contains("If they name reviewers"))
        #expect(text.contains("`in_progress` as you start fixing it again, on the user's own pull requests only"))
        #expect(text.contains("once it answers that the Copilot app doesn't list this session"))
    }

    /// Updates from Copilot Sessions' skill names only its tools, what they take, and Pull Request Order's tool, and tells
    /// agents about every one of its tools.
    @Test(.timeLimit(.minutes(5)), .enabled(if: canTellProgramsApart, "macOS doesn't say enough here to tell"))
    func updatesSkillNamesOnlyItsTools() async throws {
        let tools = try await Self.listedTools().filter { Self.updateTools.contains($0["name"] as? String ?? "") }
        #expect(Set(tools.compactMap { $0["name"] as? String }) == Self.updateTools)
        let arguments = tools.reduce(into: Set<String>()) { $0.formUnion(Self.vocabulary(of: $1["inputSchema"])) }
        let text = try String(contentsOf: Self.updatesSkill, encoding: .utf8)
        let named = Set(text.matches(of: /`([a-z][a-z0-9_]*)`/).map { String($0.output.1) })
        let unknown = named.subtracting(Self.updateTools).subtracting(arguments).subtracting(Self.updatesVocabulary)
        #expect(unknown.isEmpty, "Updates from Copilot Sessions' skill names what its tools don't have: \(unknown.sorted())")
        let missing = Self.updateTools.filter { !text.contains("`\($0)`") }
        #expect(missing.isEmpty, "Updates from Copilot Sessions' skill doesn't mention \(missing.sorted())")
    }

    /// The names of a tool's arguments, at any depth, and the values they take.
    static func vocabulary(of schema: Any?) -> Set<String> {
        guard let schema = schema as? [String: Any] else { return [] }
        var names = Set(schema["enum"] as? [String] ?? [])
        for (name, property) in schema["properties"] as? [String: Any] ?? [:] {
            names.insert(name)
            names.formUnion(vocabulary(of: property))
        }
        return names.union(vocabulary(of: schema["items"]))
    }
}

private final class Marker {}
