import BriefBarCore
import Foundation

/// Pull Request Order's tools, for agents through `--mcp`: a Copilot session tells BriefBar the order the pull requests it
/// opened merge in, reads back the orders BriefBar keeps, and forgets one. They change only BriefBar's own orders, never
/// anything in Azure DevOps or on GitHub, and answer with only what agents told BriefBar.
package enum PullRequestOrderMCP {
    /// What the tools answer while Pull Request Order is off.
    static let refusal = """
        Pull Request Order is off in BriefBar, so it keeps no order of pull requests. Only the user can turn it on, in \
        BriefBar's Settings.
        """

    /// Pull Request Order's tools, only while it's on when `--mcp` starts, as it's off until you turn it on; each call
    /// checks again that it's on. The demo keeps its orders in memory, with Pull Request Order on.
    /// - Parameters:
    ///   - defaults: the app's settings, or the demo's.
    ///   - sourcesOn: the kinds of pull request whose source is on in the app, asked with each order told.
    ///   - session: the Copilot session that started `--mcp`, whose order it is when the agent doesn't say.
    ///   - announce: tells the app its orders changed.
    package static func tools(
        defaults: UserDefaults, demo: Bool, sourcesOn: @escaping @Sendable () -> Set<ItemRef.Kind>, session: String?,
        announce: @escaping @Sendable () -> Void = AgentChanges.post, now: @escaping @Sendable () -> Date = { Date() }
    ) -> [MCPTool] {
        guard demo || PullRequestOrderSetting.isOn(in: defaults) else { return [] }
        let keeper = OrderKeeper(settings: OrderKeeper.Settings(defaults), demo: demo, announce: announce)
        let session = session.flatMap(ItemRef.session)
        let reasons = ReviewReason.allCases.map(\.rawValue)
        return [
            MCPTool(
                name: "order_pull_requests",
                title: "Order Pull Requests",
                description: """
                    Tells BriefBar the order pull requests that go together must merge in, such as those you opened for one \
                    piece of work, so that its Pull Requests pages show the user which can merge next and which wait, and \
                    for what. Name each by its link, with the ones in the list that must merge before it; leave those out \
                    for one that can merge any time. Optionally, say when to review one. A new order gets an ID and \
                    revision 1: keep them, and send the whole order again with them whenever it changes. It changes \
                    nothing in Azure DevOps or on GitHub.
                    """,
                inputSchema: MCPSchema.object([
                    "pull_requests": array(
                        "The pull requests that go together, in the order they merge",
                        items: MCPSchema.object([
                            "link": MCPSchema.string("Its link, in Azure DevOps or on GitHub"),
                            "after": array(
                                """
                                The pull requests in this list that must merge before it: their links, or their numbers \
                                when only one in the list has that number. Leave it out when it can merge any time.
                                """,
                                items: .object(["type": .string("string")])
                            ),
                            "review": MCPSchema.object([
                                "when": MCPSchema.string("Now, or after others", oneOf: ["now", "after"]),
                                "after": array(
                                    "With after: the pull requests in this list to review before it",
                                    items: .object(["type": .string("string")])
                                ),
                                "reason": MCPSchema.string("With after: why", oneOf: reasons),
                            ], required: ["when"]),
                        ], required: ["link"])
                    ),
                    "order": MCPSchema.string("The ID BriefBar gave the order, to replace it; leave it out for a new one"),
                    "revision": integer("With order: its revision you last read"),
                    "session": MCPSchema.string("Your Copilot session's ID, when BriefBar can't tell which session you are"),
                ], required: ["pull_requests"]),
                readOnly: false
            ) { arguments in
                try await tell(arguments, keeper: keeper, sourcesOn: sourcesOn, session: session, now: now())
            },
            MCPTool(
                name: "pull_request_order",
                title: "Pull Request Orders",
                description: """
                    The orders sessions told BriefBar their pull requests merge in, each with its ID and revision, the \
                    session that told it, and a line for each pull request. Read an order before you change it with \
                    order_pull_requests.
                    """,
                inputSchema: MCPSchema.object([
                    "order": MCPSchema.string("An order's ID, for that order only"),
                ])
            ) { arguments in
                try await read(arguments, keeper: keeper, session: session)
            },
            MCPTool(
                name: "forget_pull_request_order",
                title: "Forget a Pull Request Order",
                description: """
                    Forgets an order BriefBar keeps, by the ID it gave, such as once its pull requests no longer go \
                    together. With the revision you last read, only if it hasn't changed since. The pull requests stay in \
                    BriefBar's lists, and nothing changes in Azure DevOps or on GitHub.
                    """,
                inputSchema: MCPSchema.object([
                    "order": MCPSchema.string("The order's ID"),
                    "revision": integer("Its revision you last read"),
                ], required: ["order"]),
                readOnly: false
            ) { arguments in
                try await forget(arguments, keeper: keeper)
            },
        ].map { tool in
            var tool = tool
            let run = tool.run
            tool.run = { arguments in
                guard await keeper.isOn else { throw MCPToolError(refusal) }
                return try await run(arguments)
            }
            return tool
        }
    }

    // MARK: The tools

    static func tell(
        _ arguments: JSONValue, keeper: OrderKeeper, sourcesOn: @Sendable () -> Set<ItemRef.Kind>, session: ItemRef?, now: Date
    ) async throws -> String {
        var request = try request(arguments)
        if request.session == nil { request.session = session?.id }
        let asked = request
        let kinds = sourcesOn()
        let told = try await keeper.change { orders in
            try orders.apply(asked, sourcesOn: kinds, now: now)
        }
        let id = told.value.id.uuidString.lowercased()
        let opening = switch (told.changed, asked.plan != nil) {
        case (false, _): "BriefBar keeps this order already, as order \(id) at revision \(told.value.revision)."
        case (true, true): "BriefBar replaced order \(id), which is at revision \(told.value.revision) now."
        case (true, false): "BriefBar keeps this order now, as order \(id) at revision \(told.value.revision)."
        }
        let demo = keeper.demo ? " (The demo keeps it in memory.)" : ""
        return """
            \(opening)\(demo) Send it again, whole, with its ID and revision whenever it changes.

            \(OrderText.lines(of: told.value).map { "- \($0)" }.joined(separator: "\n"))
            """
    }

    static func read(_ arguments: JSONValue, keeper: OrderKeeper, session: ItemRef?) async throws -> String {
        let orders = await keeper.orders
        var plans = orders.plans
        if let text = arguments["order"]?.string, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespaces)) else {
                throw MCPToolError(OrderPlanError.notAPlan(text).description)
            }
            guard let plan = orders.plan(id) else { throw MCPToolError(OrderPlanError.noSuchPlan(id).description) }
            plans = [plan]
        }
        guard !plans.isEmpty else { return "No session has told BriefBar an order of pull requests." }
        return plans.map { describe($0, session: session) }.joined(separator: "\n\n")
    }

    static func forget(_ arguments: JSONValue, keeper: OrderKeeper) async throws -> String {
        guard let text = arguments["order"]?.string else { throw MCPToolError("Give the order's ID, as BriefBar gave it.") }
        let revision = try revision(arguments["revision"])
        let forgotten = try await keeper.change { orders in
            try orders.forget(plan: text, revision: revision)
        }
        return "BriefBar forgot order \(forgotten.value.id.uuidString.lowercased())."
    }

    /// An order, as `pull_request_order` reads it.
    static func describe(_ plan: OrderPlan, session: ItemRef?) -> String {
        let teller = if let told = plan.declaredBy {
            told == session ? "Told by your session, \(told.id)" : "Told by session \(told.id)"
        } else {
            "Told without saying by which session"
        }
        return """
            ## Order \(plan.id.uuidString.lowercased()) at revision \(plan.revision)

            \(teller), last on \(day(plan.updatedAt)).

            \(OrderText.lines(of: plan).map { "- \($0)" }.joined(separator: "\n"))
            """
    }

    /// The day, where you are.
    private static func day(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }

    // MARK: Reading what the agent sent

    /// What the agent asked, before BriefBar checks it (`DeclaredOrders.apply`).
    static func request(_ arguments: JSONValue) throws -> OrderRequest {
        guard case .array(let values)? = arguments["pull_requests"] else {
            throw MCPToolError("Give pull_requests: a list of the pull requests that go together, each with its link.")
        }
        var entries: [OrderRequest.Entry] = []
        for value in values {
            if let link = value.string {
                entries.append(OrderRequest.Entry(link: link))
                continue
            }
            guard let link = value["link"]?.string else {
                throw MCPToolError("Give each pull request in pull_requests with its link: {\"link\": \"https://…\"}.")
            }
            entries.append(
                OrderRequest.Entry(link: link, after: try names(value["after"], in: "after"), review: try review(value["review"]))
            )
        }
        let plan = arguments["order"]?.string?.trimmingCharacters(in: .whitespaces)
        return OrderRequest(
            plan: plan?.isEmpty == false ? plan : nil, revision: try revision(arguments["revision"]),
            session: arguments["session"]?.string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
            entries: entries
        )
    }

    /// Pull requests named by their links or numbers: a list, or one on its own.
    static func names(_ value: JSONValue?, in field: String) throws -> [String] {
        switch value {
        case nil, .null?: return []
        case .string(let text)?: return [text]
        case .int(let number)?: return [String(number)]
        case .array(let values)?:
            return try values.map { value in
                if let text = value.string { return text }
                if case .int(let number) = value { return String(number) }
                throw MCPToolError("Name each pull request in \(field) by its link or its number.")
            }
        default:
            throw MCPToolError("Give \(field) as a list of pull requests, by their links or numbers.")
        }
    }

    static func review(_ value: JSONValue?) throws -> OrderRequest.Review? {
        switch value {
        case nil, .null?: return nil
        case .string(let text)? where text.trimmingCharacters(in: .whitespaces).lowercased() == "now": return .now
        case .object?: break
        default:
            throw MCPToolError(#"Give review as {"when": "now"}, or {"when": "after", "after": […], "reason": "…"}."#)
        }
        let when = value?["when"]?.string?.trimmingCharacters(in: .whitespaces).lowercased()
        let after = try names(value?["after"], in: "review's after")
        switch when {
        case "now":
            return .now
        case "after":
            break
        case nil where !after.isEmpty:
            break
        default:
            throw MCPToolError(#"Give review's when as "now" or "after"."#)
        }
        guard let reason = value?["reason"]?.string else {
            let reasons = ReviewReason.allCases.map(\.rawValue).joined(separator: ", ")
            throw MCPToolError("Say why to review it after them, with reason: one of \(reasons).")
        }
        return .after(after, reason: reason)
    }

    static func revision(_ value: JSONValue?) throws -> Int? {
        switch value {
        case nil, .null?: return nil
        case let value?:
            guard let revision = value.int, revision >= 1 else {
                throw MCPToolError("Give the revision as a whole number, as BriefBar gave it.")
            }
            return revision
        }
    }

    // MARK: Schemas

    private static func array(_ description: String, items: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "description": .string(description), "items": items])
    }

    private static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}

/// The orders BriefBar keeps, as `--mcp` reads and changes them: one change at a time, saved as the app saves them, and
/// the app told at once. Two programs changing them at the very same moment can lose one change, as the preferences have
/// no transactions; an order's revision keeps an agent from replacing a newer one than it read.
actor OrderKeeper {
    /// The app's settings, which any thread can read and write.
    final class Settings: @unchecked Sendable {
        let defaults: UserDefaults

        init(_ defaults: UserDefaults) {
            self.defaults = defaults
        }
    }

    private let defaults: UserDefaults
    let demo: Bool
    private let announce: @Sendable () -> Void

    init(settings: Settings, demo: Bool, announce: @escaping @Sendable () -> Void) {
        defaults = settings.defaults
        self.demo = demo
        self.announce = announce
    }

    var orders: DeclaredOrders {
        DeclaredOrders.load(from: defaults)
    }

    /// Whether Pull Request Order is on, asked with each call: the demo's always is.
    var isOn: Bool {
        demo || PullRequestOrderSetting.isOn(in: defaults)
    }

    /// Changes the orders, and saves them when that changed them, telling the app.
    func change<Value: Sendable>(
        _ body: @Sendable (inout DeclaredOrders) throws -> Value
    ) throws -> (value: Value, changed: Bool) {
        var orders = DeclaredOrders.load(from: defaults)
        let before = orders
        let value = try body(&orders)
        guard orders != before else { return (value, false) }
        orders.save(to: defaults)
        if !demo { announce() }
        return (value, true)
    }
}
