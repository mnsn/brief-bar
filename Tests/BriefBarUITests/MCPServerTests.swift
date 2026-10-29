import BriefBarCore
import BriefBarUI
import Foundation
import Synchronization
import Testing

/// What a server wrote, line by line.
private final class Output: Sendable {
    private let lines = Mutex<[Data]>([])

    func add(_ data: Data) {
        lines.withLock { $0.append(data) }
    }

    /// Each message, decoded.
    var messages: [JSONValue] {
        lines.withLock { $0 }.map { line in
            #expect(line.last == 0x0A)
            #expect(line.dropLast().contains(0x0A) == false)
            return (try? JSONDecoder().decode(JSONValue.self, from: line)) ?? .null
        }
    }

    func reply(to id: Int) -> JSONValue? {
        messages.first { $0["id"] == .int(id) }
    }
}

@Suite struct MCPServerTests {
    private let identity = MCPServer.Identity(name: "briefbar", title: "BriefBar", version: "1.0", instructions: "Start with needs_me.")

    private func server(_ tools: [MCPTool], output: Output) -> MCPServer {
        MCPServer(identity: identity, tools: tools) { output.add($0) }
    }

    private func line(_ text: String) -> Data { Data(text.utf8) }

    private func request(_ id: Int, _ method: String, _ params: String = "{}") -> Data {
        line(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#)
    }

    private var echo: MCPTool {
        MCPTool(name: "echo", title: "Echo", description: "Says what it's given",
                inputSchema: MCPSchema.object(["text": MCPSchema.string("What to say")], required: ["text"])) { arguments in
            guard let text = arguments["text"]?.string else { throw MCPToolError("Say something.") }
            return text
        }
    }

    // MARK: JSON

    @Test func decodesEveryKindOfValue() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: line(#"{"a":1,"b":1.5,"c":true,"d":"x","e":null,"f":[1,"2"]}"#))
        #expect(value["a"] == .int(1))
        #expect(value["b"] == .double(1.5))
        #expect(value["c"] == .bool(true))
        #expect(value["d"] == .string("x"))
        #expect(value["e"] == .null)
        #expect(value["f"] == .array([.int(1), .string("2")]))
        #expect(value["missing"] == nil)
    }

    @Test func readsNumbersAndBooleansAgentsWriteAsStrings() {
        #expect(JSONValue.string(" 4088 ").int == 4088)
        #expect(JSONValue.double(12).int == 12)
        #expect(JSONValue.double(1.5).int == nil)
        #expect(JSONValue.string("!4088").int == nil)
        #expect(JSONValue.string("TRUE").bool == true)
        #expect(JSONValue.string("no").bool == nil)
    }

    @Test func splitsLinesHoweverTheyArrive() {
        var splitter = LineSplitter()
        #expect(splitter.append(line("{\"a\"")).isEmpty)
        #expect(splitter.append(line(":1}\r\n{\"b\":2}\n{\"c\"")) == [line("{\"a\":1}"), line("{\"b\":2}")])
        #expect(splitter.finish() == line("{\"c\""))
        #expect(splitter.finish() == nil)
    }

    // MARK: Messages

    @Test func answersInTheVersionTheClientAsksForWhenItKnowsIt() async throws {
        let output = Output()
        let server = server([echo], output: output)
        await server.receive(request(1, "initialize", #"{"protocolVersion":"2025-03-26","capabilities":{}}"#))
        await server.receive(request(2, "initialize", #"{"protocolVersion":"1999-01-01"}"#))
        let first = try #require(output.reply(to: 1)?["result"])
        #expect(first["protocolVersion"] == .string("2025-03-26"))
        #expect(first["serverInfo"]?["name"] == .string("briefbar"))
        #expect(first["instructions"] == .string("Start with needs_me."))
        #expect(first["capabilities"]?["tools"] != nil)
        #expect(output.reply(to: 2)?["result"]?["protocolVersion"] == .string(MCPServer.protocolVersions[0]))
    }

    @Test func listsItsToolsInOrderWithTheirSchemas() async throws {
        let output = Output()
        let other = MCPTool(name: "watch", title: "Watch", description: "Changes a setting", readOnly: false) { _ in "" }
        let server = server([echo, other], output: output)
        await server.receive(request(1, "tools/list"))
        guard case .array(let tools)? = output.reply(to: 1)?["result"]?["tools"] else {
            Issue.record("No tools")
            return
        }
        #expect(tools.map { $0["name"] } == [.string("echo"), .string("watch")])
        #expect(tools[0]["inputSchema"]?["required"] == .array([.string("text")]))
        #expect(tools[0]["annotations"]?["readOnlyHint"] == .bool(true))
        #expect(tools[1]["annotations"]?["readOnlyHint"] == .bool(false))
        #expect(tools[1]["annotations"]?["destructiveHint"] == .bool(false))
    }

    @Test func callsATool() async throws {
        let output = Output()
        let server = server([echo], output: output)
        await server.receive(request(1, "tools/call", #"{"name":"echo","arguments":{"text":"Hi\nthere"}}"#))
        await server.receive(request(2, "tools/call", #"{"name":"echo","arguments":{}}"#))
        await server.finish()
        let answer = try #require(output.reply(to: 1)?["result"])
        #expect(answer["content"] == .array([.object(["type": .string("text"), "text": .string("Hi\nthere")])]))
        #expect(answer["isError"] == nil)
        // What a tool throws is its answer, for the agent to read.
        let failure = try #require(output.reply(to: 2)?["result"])
        #expect(failure["isError"] == .bool(true))
        #expect(failure["content"] == .array([.object(["type": .string("text"), "text": .string("Say something.")])]))
    }

    @Test func refusesWhatItDoesntKnow() async {
        let output = Output()
        let server = server([echo], output: output)
        await server.receive(request(1, "tools/call", #"{"name":"nope"}"#))
        await server.receive(request(2, "tools/call", #"{}"#))
        await server.receive(request(3, "resources/list"))
        await server.receive(line(#"{"id":4,"method":"ping"}"#))
        await server.receive(line("not json"))
        await server.receive(line("[]"))
        #expect(output.reply(to: 1)?["error"]?["code"] == .int(-32602))
        #expect(output.reply(to: 2)?["error"]?["code"] == .int(-32602))
        #expect(output.reply(to: 3)?["error"]?["code"] == .int(-32601))
        #expect(output.reply(to: 4)?["error"]?["code"] == .int(-32600))
        let rest = output.messages.filter { $0["id"] == .null }
        #expect(rest.map { $0["error"]?["code"] } == [.int(-32700), .int(-32600)])
    }

    @Test func answersNoNotificationOrResponse() async {
        let output = Output()
        let server = server([echo], output: output)
        await server.receive(line(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        await server.receive(line(#"{"jsonrpc":"2.0","id":9,"result":{}}"#))
        await server.receive(line("  \n"))
        await server.receive(request(1, "ping"))
        #expect(output.messages == [.object(["jsonrpc": .string("2.0"), "id": .int(1), "result": .object([:])])])
    }

    @Test func answersABatchAtOnce() async throws {
        let output = Output()
        let server = server([echo], output: output)
        await server.receive(line(#"""
            [{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},
             {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"a"}}}]
            """#.replacingOccurrences(of: "\n", with: "")))
        await server.finish()
        guard case .array(let replies)? = output.messages.first, output.messages.count == 1 else {
            Issue.record("Expected one batch, got \(output.messages)")
            return
        }
        #expect(replies.map { $0["id"] } == [.int(1), .int(2)])
    }

    @Test func aCancelledCallGetsNoAnswer() async {
        let output = Output()
        let slow = MCPTool(name: "slow", title: "Slow", description: "Takes its time") { _ in
            try await Task.sleep(for: .seconds(30))
            return "done"
        }
        let server = server([slow, echo], output: output)
        await server.receive(request(1, "tools/call", #"{"name":"slow"}"#))
        await server.receive(request(2, "tools/call", #"{"name":"echo","arguments":{"text":"b"}}"#))
        await server.receive(line(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#))
        await server.finish()
        #expect(output.reply(to: 1) == nil)
        #expect(output.reply(to: 2) != nil)
    }

    // MARK: Sources

    @Test func aSourceThatsOffSaysSo() async throws {
        let isOn = Mutex(true)
        let source = MCPSource(name: "Azure DevOps", tools: [echo]) { "Two need you." }
            .available(while: { isOn.withLock { $0 } }, refusal: "Azure DevOps is off in BriefBar.")
        #expect(try await source.tools[0].run(.object(["text": .string("x")])) == "x")
        #expect(try await source.needsYou() == "Two need you.")
        isOn.withLock { $0 = false }
        await #expect(throws: MCPToolError("Azure DevOps is off in BriefBar.")) {
            try await source.tools[0].run(.object(["text": .string("x")]))
        }
        await #expect(throws: MCPToolError("Azure DevOps is off in BriefBar.")) { try await source.needsYou() }
    }

    @Test func everyToolWaitsForAgentsToBeOn() async throws {
        let refusal = Mutex<String?>("Agents are off in BriefBar.")
        let sources = [MCPSource(name: "Azure DevOps", tools: [echo]) { "Two need you." }]
        let tools = MCPSource.tools(sources) { refusal.withLock { $0 } }
        #expect(tools.map(\.name) == ["needs_me", "echo"])
        for tool in tools {
            await #expect(throws: MCPToolError("Agents are off in BriefBar.")) { try await tool.run(.object(["text": .string("x")])) }
        }
        refusal.withLock { $0 = nil }
        #expect(try await tools[1].run(.object(["text": .string("x")])) == "x")
        #expect(try await tools[0].run(.object([:])).contains("Two need you."))
    }

    /// A source that's off answers so under its own heading, and the others still answer: the skill relies on that, and
    /// stops only when agents are off.
    @Test func needsMeAnswersForTheSourcesThatAreOn() async throws {
        let sources = [
            MCPSource(name: "Azure DevOps", tools: [echo]) { "- !1 needs you" }
                .available(while: { false }, refusal: AgentAccess.refusal(source: "Azure DevOps")),
            MCPSource(name: "GitHub Copilot", tools: []) { "- “Add dark mode” waits for your answer" },
        ]
        let text = try await MCPSource.tools(sources)[0].run(.object([:]))
        #expect(text == """
            ## Azure DevOps

            Azure DevOps is off in BriefBar. Turn it on in BriefBar's Settings to use it here.

            ## GitHub Copilot

            - “Add dark mode” waits for your answer
            """)
    }

    @Test func needsMeHasEverySourceInOrder() async throws {
        let sources = [
            MCPSource(name: "Azure DevOps", tools: []) { "- !1 needs you" },
            MCPSource(name: "GitHub Copilot", tools: []) { nil },
            MCPSource(name: "Broken", tools: []) { throw MCPToolError("Sign in with az login.") },
        ]
        let text = try await MCPSource.needsYouTool(sources).run(.object([:]))
        #expect(text == """
            ## Azure DevOps

            - !1 needs you

            ## GitHub Copilot

            Nothing needs you.

            ## Broken

            Sign in with az login.
            """)
    }

    // MARK: What the sources know of each other's things

    private static let pullRequest = ItemRef.pullRequest(organization: "contoso", number: 4120)

    /// A tool that asks the other sources about a pull request, and says what each told, or why it couldn't.
    private var asking: MCPTool {
        MCPTool(name: "work_item", title: "Work Item", description: "Asks about a pull request") { _ in
            let query = MCPRelated.Query(
                items: [Self.pullRequest],
                branches: [Self.pullRequest: BranchHint(branch: "saved-items", target: "main", repositories: ["shop-web"])]
            )
            let parts = await MCPRelated.ask(query)
            return parts.map { part in
                "\(part.title): " + (part.problem ?? part.items.map { "\($0.title) (\($0.links.map(\.reason).joined()))" }.joined(separator: ", "))
            }.joined(separator: "\n")
        }
    }

    /// Tells of a session on the pull request's branch, as the Copilot source does.
    private static let sessions = MCPRelated.Teller(title: "Copilot sessions") { query in
        query.branches.keys.map { ref in
            MCPRelated.Item(
                ref: ItemRef.session("c3e8f1a2-6b4d-4e97-a1c5-2f7d9b0e8a11")!, title: "Save items for later", status: "finished 2h ago",
                links: [MCPRelated.Link(item: ref, reason: "on !\(ref.id)'s branch")]
            )
        }
    }

    @Test func aToolAsksTheOtherSourcesWhatTheyKnowOfWhatItNames() async throws {
        let sources = [
            MCPSource(name: "Azure DevOps", tools: [asking]) { nil },
            MCPSource(name: "GitHub Copilot", tools: [], related: Self.sessions) { nil },
        ]
        let tools = MCPSource.tools(sources)
        #expect(try await tools[1].run(.object([:])) == "Copilot sessions: Save items for later (on !4120's branch)")
        // Run on its own, a tool has no source to ask.
        #expect(try await asking.run(.object([:])) == "")
        // Nor does one whose sources tell nothing.
        #expect(try await MCPSource.tools([MCPSource(name: "Azure DevOps", tools: [asking]) { nil }])[1].run(.object([:])) == "")
    }

    /// A source that's off in the app tells nothing, and says so: that's no reason for the tool that asks to fail.
    @Test func aSourceThatsOffTellsNothingAndSaysSo() async throws {
        let isOn = Mutex(false)
        let sources = [
            MCPSource(name: "Azure DevOps", tools: [asking]) { nil },
            MCPSource(name: "GitHub Copilot", tools: [], related: Self.sessions) { nil }
                .available(while: { isOn.withLock { $0 } }, refusal: AgentAccess.refusal(source: "GitHub Copilot")),
        ]
        let tool = MCPSource.tools(sources)[1]
        #expect(try await tool.run(.object([:])) == """
            Copilot sessions: GitHub Copilot is off in BriefBar. Turn it on in BriefBar's Settings to use it here.
            """)
        isOn.withLock { $0 = true }
        #expect(try await tool.run(.object([:])) == "Copilot sessions: Save items for later (on !4120's branch)")
    }

    @Test func asksEverySourceInTheirOrder() async {
        let slow = MCPRelated.Teller(title: "Slow") { _ in
            try await Task.sleep(for: .milliseconds(50))
            return []
        }
        let broken = MCPRelated.Teller(title: "Broken") { _ in throw MCPToolError("Couldn't read the sessions.") }
        let parts = await MCPRelated.ask([slow, broken, Self.sessions], MCPRelated.Query(items: [Self.pullRequest]))
        #expect(parts.map(\.title) == ["Slow", "Broken", "Copilot sessions"])
        #expect(parts[0] == MCPRelated.Part(title: "Slow"))
        #expect(parts[1].problem == "Couldn't read the sessions.")
        #expect(await MCPRelated.ask([], MCPRelated.Query(items: [Self.pullRequest])).isEmpty)
    }
}
