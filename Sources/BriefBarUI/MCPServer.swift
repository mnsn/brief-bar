import Foundation

/// A JSON value: a message of the Model Context Protocol, what an agent gives a tool, and a tool's schema.
package enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    package subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    package var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// A whole number, also when an agent writes it as a string.
    package var int: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return value.rounded() == value && abs(value) < 1e15 ? Int(value) : nil
        case .string(let value): return Int(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// A boolean, also when an agent writes it as a string.
    package var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let value): return ["true": true, "false": false][value.lowercased()]
        default: return nil
        }
    }
}

/// The JSON Schemas of what tools take.
package enum MCPSchema {
    /// A tool's arguments: an object, with these properties.
    package static func object(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    package static func string(_ description: String, oneOf values: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if !values.isEmpty { schema["enum"] = .array(values.map(JSONValue.string)) }
        return .object(schema)
    }

    package static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }
}

/// A tool an agent can call through `--mcp`.
package struct MCPTool: Sendable {
    /// What the agent calls it by, such as `pull_requests`.
    package var name: String
    /// What people read, such as “Pull Requests”.
    package var title: String
    /// What it's for, which is how the agent chooses it.
    package var description: String
    /// The JSON Schema of its arguments (`MCPSchema.object`).
    package var inputSchema: JSONValue
    /// It only reads: running it changes nothing, in BriefBar or anywhere else. The others change only BriefBar's own
    /// settings, the same way each time, and remove nothing.
    package var readOnly: Bool
    /// Its answer, in Markdown, to the arguments it's given. What it throws is what the agent reads went wrong.
    package var run: @Sendable (_ arguments: JSONValue) async throws -> String

    package init(
        name: String, title: String, description: String, inputSchema: JSONValue = MCPSchema.object(), readOnly: Bool = true,
        run: @escaping @Sendable (_ arguments: JSONValue) async throws -> String
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.run = run
    }

    /// The same tool, refused when `isAvailable` says no, with `refusal` as its answer.
    package func available(while isAvailable: @escaping @Sendable () -> Bool, refusal: String) -> MCPTool {
        guarded { isAvailable() ? nil : refusal }
    }

    /// The same tool, refused whenever `refusal` gives an answer instead, asked with each call.
    package func guarded(by refusal: @escaping @Sendable () -> String?) -> MCPTool {
        var tool = self
        let run = self.run
        tool.run = { arguments in
            if let refusal = refusal() { throw MCPToolError(refusal) }
            return try await run(arguments)
        }
        return tool
    }

    /// The same tool, which can ask these sources what they know of the things it names while it runs (`MCPRelated`).
    package func telling(_ tellers: [MCPRelated.Teller]) -> MCPTool {
        guard !tellers.isEmpty else { return self }
        var tool = self
        let run = self.run
        tool.run = { arguments in
            try await MCPRelated.$tellers.withValue(tellers) { try await run(arguments) }
        }
        return tool
    }

    /// How `tools/list` describes it.
    var listing: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(false),
                "idempotentHint": .bool(true),
            ]),
        ])
    }
}

/// What a tool says went wrong, in words for the agent: a pull request it doesn't know, a source that's off.
package struct MCPToolError: Error, CustomStringConvertible, Equatable {
    package var description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// What a source gives agents through `--mcp`: its tools, its part of `needs_me`, and what it knows of the other sources'
/// things, for their tools.
package struct MCPSource: Sendable {
    /// Its name in `needs_me`, such as “Azure DevOps”.
    package var name: String
    package var tools: [MCPTool]
    /// What it tells of the things the other sources' tools name, such as the Copilot sessions on a pull request's branch;
    /// nil when it tells nothing.
    package var related: MCPRelated.Teller?
    /// What needs you in it now, in Markdown; nil when nothing does.
    package var needsYou: @Sendable () async throws -> String?

    package init(
        name: String, tools: [MCPTool], related: MCPRelated.Teller? = nil,
        needsYou: @escaping @Sendable () async throws -> String?
    ) {
        self.name = name
        self.tools = tools
        self.related = related
        self.needsYou = needsYou
    }

    /// The same source, whose tools, part of `needs_me` and what it tells the others' tools are refused when
    /// `isAvailable` says no, such as once it's turned off in the app.
    package func available(while isAvailable: @escaping @Sendable () -> Bool, refusal: String) -> MCPSource {
        let needsYou = self.needsYou
        let related = self.related.map { teller in
            MCPRelated.Teller(title: teller.title) { query in
                guard isAvailable() else { throw MCPToolError(refusal) }
                return try await teller.tell(query)
            }
        }
        return MCPSource(name: name, tools: tools.map { $0.available(while: isAvailable, refusal: refusal) }, related: related) {
            guard isAvailable() else { throw MCPToolError(refusal) }
            return try await needsYou()
        }
    }

    /// One source's part of `needs_me`, by its place among them.
    private struct Part: Sendable {
        var index: Int
        var text: String
    }

    /// Every tool agents get from the sources: `needs_me`, then each source's own, each refused whenever `refusal` gives
    /// an answer instead, such as while agents are off in BriefBar. While one runs, it can ask every source what it knows
    /// of the things it names (`MCPRelated.ask`).
    package static func tools(_ sources: [MCPSource], refusal: @escaping @Sendable () -> String? = { nil }) -> [MCPTool] {
        let tellers = sources.compactMap(\.related)
        return ([needsYouTool(sources)] + sources.flatMap(\.tools)).map { $0.guarded(by: refusal).telling(tellers) }
    }

    /// `needs_me`: what needs you in every source, each under its name, read at the same time.
    package static func needsYouTool(_ sources: [MCPSource]) -> MCPTool {
        MCPTool(
            name: "needs_me",
            title: "What Needs Me",
            description: """
                What needs the user now, as BriefBar's menu bar counts it, in each of its sources that's on: Azure DevOps \
                pull requests that need them, are failing or are ready to complete, pinned pipelines that failed, and \
                GitHub Copilot sessions waiting for them. Start here when the user asks what to do next or what's going on.
                """
        ) { _ in
            let checks = sources.map(\.needsYou)
            let parts = await withTaskGroup(of: Part.self) { group in
                for index in checks.indices {
                    let check = checks[index]
                    group.addTask {
                        do {
                            return Part(index: index, text: try await check() ?? "Nothing needs you.")
                        } catch {
                            return Part(index: index, text: String(describing: error))
                        }
                    }
                }
                var parts: [Int: String] = [:]
                for await part in group { parts[part.index] = part.text }
                return parts
            }
            return sources.indices.map { "## \(sources[$0].name)\n\n\(parts[$0] ?? "")" }.joined(separator: "\n\n")
        }
    }
}

/// A Model Context Protocol server, for `--mcp`: JSON-RPC 2.0 messages, one a line, the way agents run a local server
/// on its standard input and output. It offers tools, and none of the protocol's other features.
package actor MCPServer {
    package struct Identity: Sendable {
        package var name: String
        package var title: String
        package var version: String
        /// What the agent reads about the server as a whole.
        package var instructions: String

        package init(name: String, title: String, version: String, instructions: String) {
            self.name = name
            self.title = title
            self.version = version
            self.instructions = instructions
        }
    }

    /// The versions of the protocol it speaks, newest first. It answers in the one the client asks for when it knows
    /// it, and otherwise in its newest.
    package static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let identity: Identity
    private let tools: [String: MCPTool]
    private let order: [String]
    private let send: @Sendable (Data) -> Void
    /// The tool calls under way, by their requests' IDs, so that the client can cancel them.
    private var calls: [JSONValue: Task<Void, Never>] = [:]
    /// Batches whose tool calls are under way.
    private var batches: [UUID: Task<Void, Never>] = [:]

    /// - Parameter send: writes a line to the client: a message, newline included.
    package init(identity: Identity, tools: [MCPTool], send: @escaping @Sendable (Data) -> Void) {
        self.identity = identity
        self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        order = tools.map(\.name)
        self.send = send
    }

    /// One line from the client: a message, or a batch of them. It's answered at once, except for tool calls, which
    /// are answered when they're done, without holding up the lines after them.
    package func receive(_ line: Data) {
        guard line.contains(where: { !Self.isWhitespace($0) }) else { return }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            write(Self.error(id: .null, code: -32700, message: "Parse error"))
            return
        }
        guard case .array(let messages) = message else {
            switch handle(message) {
            case .none:
                break
            case .now(let reply):
                write(reply)
            case .later(let id, let call):
                calls[id] = Task { [weak self] in
                    let reply = await call()
                    await self?.finish(id: id, reply: reply)
                }
            }
            return
        }
        guard !messages.isEmpty else {
            write(Self.error(id: .null, code: -32600, message: "Invalid Request"))
            return
        }
        let handled = messages.map(handle)
        let batch = UUID()
        batches[batch] = Task { [weak self] in
            var replies: [JSONValue] = []
            for reply in handled {
                switch reply {
                case .none: break
                case .now(let reply): replies.append(reply)
                case .later(_, let call): replies.append(await call())
                }
            }
            await self?.finish(batch: batch, replies: replies)
        }
    }

    /// Waits for the tool calls under way: once the client has closed its end, before the server stops.
    package func finish() async {
        while let task = calls.values.first ?? batches.values.first {
            await task.value
        }
    }

    // MARK: Messages

    private enum Reply {
        /// A notification, or a response from the client: nothing to answer.
        case none
        case now(JSONValue)
        /// A tool call, answered once it's done.
        case later(JSONValue, @Sendable () async -> JSONValue)
    }

    private func handle(_ message: JSONValue) -> Reply {
        guard case .object(let fields) = message, fields["jsonrpc"] == .string("2.0") else {
            return .now(Self.error(id: message["id"] ?? .null, code: -32600, message: "Invalid Request"))
        }
        guard let method = fields["method"]?.string else {
            // A response, which the server never asks for, or something that isn't a message.
            return fields["result"] != nil || fields["error"] != nil
                ? .none : .now(Self.error(id: fields["id"] ?? .null, code: -32600, message: "Invalid Request"))
        }
        let params = fields["params"] ?? .object([:])
        guard let id = fields["id"] else {
            if method == "notifications/cancelled", let request = params["requestId"] {
                calls.removeValue(forKey: request)?.cancel()
            }
            return .none
        }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.string ?? ""
            return .now(Self.result(id: id, .object([
                "protocolVersion": .string(Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object([
                    "name": .string(identity.name), "title": .string(identity.title), "version": .string(identity.version),
                ]),
                "instructions": .string(identity.instructions),
            ])))
        case "ping":
            return .now(Self.result(id: id, .object([:])))
        case "tools/list":
            return .now(Self.result(id: id, .object(["tools": .array(order.compactMap { tools[$0]?.listing })])))
        case "tools/call":
            guard let name = params["name"]?.string else {
                return .now(Self.error(id: id, code: -32602, message: "Invalid params: name the tool to call"))
            }
            guard let tool = tools[name] else {
                return .now(Self.error(id: id, code: -32602, message: "Unknown tool: \(name)"))
            }
            let arguments = params["arguments"] ?? .object([:])
            return .later(id, { await Self.call(tool, arguments: arguments, id: id) })
        default:
            return .now(Self.error(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    private static func call(_ tool: MCPTool, arguments: JSONValue, id: JSONValue) async -> JSONValue {
        let text: String
        let failed: Bool
        do {
            text = try await tool.run(arguments)
            failed = false
        } catch {
            text = String(describing: error)
            failed = true
        }
        var result: [String: JSONValue] = ["content": .array([.object(["type": .string("text"), "text": .string(text)])])]
        if failed { result["isError"] = .bool(true) }
        return Self.result(id: id, .object(result))
    }

    /// A call is done: its answer goes out, unless the client cancelled it, which needs none.
    private func finish(id: JSONValue, reply: JSONValue) {
        guard calls.removeValue(forKey: id) != nil else { return }
        write(reply)
    }

    private func finish(batch: UUID, replies: [JSONValue]) {
        batches[batch] = nil
        if !replies.isEmpty { write(.array(replies)) }
    }

    private func write(_ message: JSONValue) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(message) else { return }
        data.append(0x0A)
        send(data)
    }

    private static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .int(code), "message": .string(message)])])
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}

extension JSONValue: Hashable {}

/// Splits what arrives on standard input into lines, however it's cut up.
package struct LineSplitter: Sendable {
    private var pending = Data()

    package init() {}

    /// The lines `data` completes, without their line breaks.
    package mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let end = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<end]
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(Data(line))
            pending = Data(pending[pending.index(after: end)...])
        }
        return lines
    }

    /// What's left once the input ends: a last line without a line break.
    package mutating func finish() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }
}

/// Runs an `MCPServer` on standard input and output.
package enum MCPStandardIO {
    /// Serves until standard input closes, then lets the calls under way finish, and exits. Only the protocol's
    /// messages go to standard output: anything else printed goes to standard error.
    @MainActor
    package static func serve(identity: MCPServer.Identity, tools: [MCPTool]) -> Never {
        // A client that has gone makes writing fail, rather than end the process with a signal.
        signal(SIGPIPE, SIG_IGN)
        fflush(stdout)
        let messages = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let output = FileHandle(fileDescriptor: messages, closeOnDealloc: true)
        // In order, and off the concurrency pool's threads, which a client slow to read would otherwise hold up.
        let writer = DispatchQueue(label: "BriefBar.mcp.output")
        let server = MCPServer(identity: identity, tools: tools) { data in
            writer.async {
                do {
                    try output.write(contentsOf: data)
                } catch {
                    exit(0)
                }
            }
        }
        // Read on a thread of its own, which waits for input however it comes: from a pipe, as agents send it, or a file.
        let lines = AsyncStream<Data> { continuation in
            let reader = Thread {
                var splitter = LineSplitter()
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let count = read(STDIN_FILENO, &buffer, buffer.count)
                    if count > 0 {
                        for line in splitter.append(Data(buffer[0..<count])) { continuation.yield(line) }
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                if let last = splitter.finish() { continuation.yield(last) }
                continuation.finish()
            }
            reader.name = "BriefBar.mcp.input"
            reader.start()
        }
        Task {
            for await line in lines {
                await server.receive(line)
            }
            await server.finish()
            // Once the last answers are written.
            writer.async { exit(0) }
        }
        dispatchMain()
    }
}
