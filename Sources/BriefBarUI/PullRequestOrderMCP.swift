import BriefBarCore
import Foundation

/// Pull Request Order's tools, for agents through `--mcp`: a Copilot session tells BriefBar the order the pull requests it
/// opened merge in, reads back the orders BriefBar keeps, and forgets one; and tells the stage of the pull requests it works
/// on. They change only BriefBar's own orders and what sessions set, never anything in Azure DevOps or on GitHub, and
/// answer with only what agents told BriefBar, and what the user set over it, by references and numbers.
package enum PullRequestOrderMCP {
    /// What the tools answer while Pull Request Order is off.
    static let refusal = """
        Pull Request Order is off in BriefBar, so it keeps no order of pull requests. Only the user can turn it on, in \
        BriefBar's Settings.
        """

    /// The stages a session sets, as `pull_request_stage` names them; nil clears what it set.
    static let stageNames: [(name: String, stage: PullRequestStage?)] = [
        ("in_progress", .inProgress), ("user_review", .yourReview), ("teammate_review", .teammateReview), ("clear", nil),
    ]

    /// Pull Request Order's tools, only while it's on when `--mcp` starts, as it's off until you turn it on; each call
    /// checks again that it's on. The demo keeps its orders, and the stages it's told, in memory, with Pull Request Order
    /// on.
    /// - Parameters:
    ///   - defaults: the app's settings, or the demo's.
    ///   - sourcesOn: the kinds of pull request whose source is on in the app, asked with each order told.
    ///   - session: the Copilot session that started `--mcp`, as the Copilot CLI says, whose order it is when the agent
    ///     doesn't say; `pull_request_stage` is there only with it, and sets only its stages, so never in VS Code or
    ///     Cursor, whose agents aren't Copilot sessions.
    ///   - stages: what Azure DevOps tells of its pull requests' stages, for `pull_request_stage`, which is there only with
    ///     it.
    ///   - copilotOn: whether GitHub Copilot is on in the app, asked with each stage set: what a session sets shows only
    ///     while the Copilot app lists it.
    ///   - announce: tells the app its orders, or what sessions set, changed.
    ///   - demoStages: where the demo keeps what sessions set, for Azure DevOps' tools to read.
    package static func tools(
        defaults: UserDefaults, demo: Bool, sourcesOn: @escaping @Sendable () -> Set<ItemRef.Kind>, session: String?,
        stages: MCPStages? = nil, copilotOn: @escaping @Sendable () -> Bool = { true },
        announce: @escaping @Sendable () -> Void = AgentChanges.post, now: @escaping @Sendable () -> Date = { Date() },
        demoStages: DemoSessionStages? = nil
    ) -> [MCPTool] {
        guard demo || PullRequestOrderSetting.isOn(in: defaults) else { return [] }
        let keeper = OrderKeeper(
            settings: OrderKeeper.Settings(defaults), demo: demo, announce: announce, demoStages: demo ? demoStages : nil
        )
        let session = session.flatMap(ItemRef.session)
        let reasons = ReviewReason.allCases.map(\.rawValue)
        var tools = [
            MCPTool(
                name: "order_pull_requests",
                title: "Order Pull Requests",
                description: """
                    Tells BriefBar the order pull requests that go together must merge in, such as those you opened for one \
                    piece of work, so that its Pull Requests pages show the user which can merge next and which wait, and \
                    for what. Name each by its link, with the ones in the list that must merge before it; leave those out \
                    for one that can merge any time. Optionally, say when to review one. A new order gets an ID and \
                    revision 1: keep them, and send the whole order again with them whenever it changes. The answer says \
                    what the user changed of it in BriefBar: keep that in what you send. With Show Links on, BriefBar puts \
                    the Azure DevOps pull requests of one story's tasks together by itself, in the tasks' backlog order: \
                    link each to its task as you open it, and tell an order only where they must merge in another order, \
                    or wait for one another. It changes nothing in Azure DevOps or on GitHub.
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
                    session that told it, a line for each pull request, and what the user changed of it. Read an order \
                    before you change it with order_pull_requests.
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
        ]
        if let stages, let session {
            tools.append(MCPTool(
                name: "pull_request_stage",
                title: "Pull Request Stage",
                description: """
                    Tells BriefBar what stage pull requests you work on are in, so that the user sees at a glance what's \
                    next for them: in_progress as you start writing or fixing the code of one of the user's own; \
                    user_review once you've pushed your work and it's the user's turn to review it; teammate_review \
                    once the user has reviewed it, as they told you or you reviewed it together, and it's their \
                    teammates' turn; clear to leave it to BriefBar. The latest stage set wins, whether the user set it \
                    or a session did, and BriefBar shows who. Azure DevOps pull requests only, for now. It changes \
                    nothing in Azure DevOps.
                    """,
                inputSchema: MCPSchema.object([
                    "pull_requests": array(
                        "The pull requests: their links, or their numbers with organization",
                        items: .object(["type": .string("string")])
                    ),
                    "stage": MCPSchema.string("Their stage", oneOf: stageNames.map(\.name)),
                    "organization": MCPSchema.string("The Azure DevOps organization of the numbers, such as contoso"),
                ], required: ["pull_requests", "stage"]),
                readOnly: false
            ) { arguments in
                try await setStage(
                    arguments, keeper: keeper, stages: stages, copilotOn: copilotOn, session: session, now: now
                )
            })
        }
        return tools.map { tool in
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
            let before = orders
            let plan = try orders.apply(asked, sourcesOn: kinds, now: now)
            return (plan: plan, before: before, after: orders)
        }
        let plan = told.value.plan
        let id = plan.id.uuidString.lowercased()
        let opening = switch (told.changed, asked.plan != nil) {
        case (false, _): "BriefBar keeps this order already, as order \(id) at revision \(plan.revision)."
        case (true, true): "BriefBar replaced order \(id), which is at revision \(plan.revision) now."
        case (true, false): "BriefBar keeps this order now, as order \(id) at revision \(plan.revision)."
        }
        let demo = keeper.demo ? " (The demo keeps it in memory.)" : ""
        var answer = """
            \(opening)\(demo) Send it again, whole, with its ID and revision whenever it changes.

            \(OrderText.lines(of: plan).map { "- \($0)" }.joined(separator: "\n"))
            """
        // The user's changes to it, which the app keeps and only the app writes: those this went against, and those that
        // hold.
        let changes = await keeper.userChanges
        let held = changes.holding(in: told.value.before)
        let holding = changes.holding(in: told.value.after)
        let overrode = held.values.filter { holding[$0.ref] == nil && OrderText.isAbout($0, plan) }.map(\.ref).sorted()
        if !overrode.isEmpty {
            answer += """


                You changed where \(labels(overrode)) \(overrode.count == 1 ? "goes" : "go") after the user had: BriefBar \
                shows yours now, and says so to the user.
                """
        }
        let lines = OrderText.userChanges(to: plan, holding: holding)
        if !lines.isEmpty {
            answer += "\n\n" + userChanges(lines) + "\n" + OrderText.keepUserChanges
        }
        return answer
    }

    /// The user's changes to an order, under their heading.
    private static func userChanges(_ lines: [String]) -> String {
        "The user changed this order in BriefBar:\n" + lines.map { "- \($0)" }.joined(separator: "\n")
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
        let holding = await keeper.userChanges.holding(in: orders)
        var changed = false
        var parts = plans.map { plan in
            let lines = OrderText.userChanges(to: plan, holding: holding)
            if !lines.isEmpty { changed = true }
            return describe(plan, session: session) + (lines.isEmpty ? "" : "\n\n" + userChanges(lines))
        }
        if changed { parts.append(OrderText.keepUserChanges) }
        return parts.joined(separator: "\n\n")
    }

    static func forget(_ arguments: JSONValue, keeper: OrderKeeper) async throws -> String {
        guard let text = arguments["order"]?.string else { throw MCPToolError("Give the order's ID, as BriefBar gave it.") }
        let revision = try revision(arguments["revision"])
        let forgotten = try await keeper.change { orders in
            try orders.forget(plan: text, revision: revision)
        }
        return "BriefBar forgot order \(forgotten.value.id.uuidString.lowercased())."
    }

    /// `pull_request_stage`: sets the stage of pull requests the session that started `--mcp` works on, as that
    /// session's, or clears what it set, as Azure DevOps reads them now, at the time it's read them. Refused, saying
    /// why, while GitHub Copilot is off, as what a session sets shows only while the Copilot app lists it; for GitHub's
    /// pull requests; for more than `SessionStages.mostAtOnce`; for another session; and for a session the Copilot app
    /// doesn't list, such as one run in a terminal, whose stages BriefBar wouldn't show. Whether it may is asked again
    /// just before it keeps anything, as reading Azure DevOps takes a while (`OrderKeeper.changeStages`). One BriefBar
    /// doesn't list, one that merged or closed, and someone else's to put in progress, which BriefBar never does, are
    /// left as they are, each with a line that says why. It says BriefBar shows what it set only where it can tell
    /// (`MCPStages.sessions`), and not where the user set a stage after it read the pull request, which shows as the
    /// later. Where it replaces a stage the user set that still stands, it says they can put theirs back while its own
    /// lasts, and that theirs goes once its own ends, but for a Your review of theirs under its In progress, which
    /// outlasts it and shows again (`StageMark.outlasts`). A Your review it sets where the user set a Your review
    /// before it read the pull request, which outlasts what sessions set since, keeps no votes, saying so: it lasts as
    /// theirs does, while theirs is there, rather than end theirs as someone else votes (`OrderKeeper.setStages`).
    static func setStage(
        _ arguments: JSONValue, keeper: OrderKeeper, stages: MCPStages, copilotOn: @escaping @Sendable () -> Bool,
        session: ItemRef, now: @Sendable () -> Date
    ) async throws -> String {
        let noCopilot = AgentAccess.refusal(source: "GitHub Copilot")
        guard copilotOn() else { throw MCPToolError(noCopilot) }
        let refusal: @Sendable () -> String? = { stages.refusal() ?? (copilotOn() ? nil : noCopilot) }
        let stage = try stage(arguments["stage"])
        let refs = try SessionUpdatesMCP.refs(
            arguments["pull_requests"], in: "pull_requests", as: [.pullRequest, .gitHubPullRequest],
            organization: arguments["organization"]?.string
        )
        if let gitHub = refs.first(where: { $0.kind == .gitHubPullRequest }) {
            throw MCPToolError(
                "Stages are for Azure DevOps' pull requests only, for now: leave \(SessionUpdatesMCP.name(gitHub)) out."
            )
        }
        guard !refs.isEmpty else {
            throw MCPToolError("Name the pull requests in pull_requests: their links, or their numbers with organization.")
        }
        guard refs.count <= SessionStages.mostAtOnce else {
            throw MCPToolError("Name at most \(SessionStages.mostAtOnce) pull requests at once.")
        }
        // Only its own: `session`, which it doesn't ask for, can only repeat it.
        _ = try SessionUpdatesMCP.session(arguments, started: session)
        let demo = keeper.demo ? " (The demo keeps it in memory.)" : ""
        guard let stage else {
            let (before, _) = try await keeper.changeStages(session, now: now(), unless: refusal) { set in
                for ref in refs { set.clear(ref) }
            }
            let cleared = refs.filter { before?.marks[$0] != nil }
            var lines: [String] = []
            if !cleared.isEmpty {
                lines.append(
                    "BriefBar no longer shows the stage this session set on \(labels(cleared)): it works it out again, or "
                        + "shows what the user set.\(demo)"
                )
            }
            let none = refs.filter { before?.marks[$0] == nil }
            if !none.isEmpty { lines.append("This session set no stage on \(labels(none)).") }
            return lines.joined(separator: "\n")
        }

        let read = try await stages.read(refs)
        // Set as it's read: what the app reads after this counts against it, and nothing it started reading before.
        let now = now()
        let sessions = await stages.sessions()
        if let sessions, !sessions.listed.contains(session) {
            throw MCPToolError("""
                The Copilot app doesn't list this session, as with one run in a terminal, and BriefBar shows only the \
                stages of sessions it lists: it kept none.
                """)
        }
        // Whether what the user set stands, as the app works it out, with the Copilot app's sessions on it too.
        let (facts, on) = (read.facts, sessions?.on ?? [:])
        let standing: (StageMark, ItemRef) -> Bool = { theirs, ref in
            guard let fact = facts[ref] else { return false }
            return StageRules.stands(theirs, facts: fact, sessions: PullRequestOrder.merged(fact.sessions, on[ref] ?? []))
        }
        var marks: [ItemRef: StageMark] = [:]
        var notSet: [String] = []
        for ref in refs {
            guard let facts = read.facts[ref], facts.isListed else {
                notSet.append("Not \(labels([ref])): BriefBar doesn't list it now.")
                continue
            }
            guard facts.state.isOpen else {
                notSet.append("Not \(labels([ref])): it \(facts.state == .merged ? "merged" : "was abandoned").")
                continue
            }
            guard stage != .inProgress || facts.isYours else {
                notSet.append(
                    "Not \(labels([ref])): it isn't the user's, and BriefBar puts only the user's own pull requests in "
                        + "progress."
                )
                continue
            }
            marks[ref] = StageRules.mark(stage, at: now, facts: facts, by: session)
        }
        guard !marks.isEmpty else { throw MCPToolError(notSet.joined(separator: "\n")) }
        let (yours, following, outlasting) = try await keeper.setStages(
            marks, of: session, account: read.account, listed: sessions?.listed, now: now, unless: refusal
        )
        let told = refs.filter { marks[$0] != nil }
        // What the user set after this session read them, the later, which shows rather than what it says.
        let later = Set(told.filter { yours[$0].map { $0.at > now } == true })
        let shown = told.filter { !later.contains($0) }
        var lines: [String] = []
        if !shown.isEmpty {
            let them = shown.count == 1 ? "it" : "them"
            let shows = if sessions == nil {
                "BriefBar keeps \(labels(shown)) in \(stage.title), set by this session, and shows \(them) while the "
                    + "Copilot app lists this session"
            } else {
                "BriefBar shows \(labels(shown)) in \(stage.title) now, set by this session"
            }
            lines.append("\(shows); the user sees who set it, and can change it.\(demo)")
        }
        // What the user set that this replaces, while it stands, which they can put back while this lasts, and which
        // goes once this ends, but a Your review of theirs that outlasts an In progress, which shows again; their Your
        // review that this follows, which it lasts as; or what they set since it read it, which shows.
        for ref in told {
            guard let theirs = yours[ref] else { continue }
            let on = told.count > 1 ? " on \(labels([ref]))" : ""
            let ago = StageText.agoWords(theirs.at, now: now)
            if later.contains(ref) {
                lines.append(
                    "The user set \(theirs.stage.title) on \(labels([ref])) \(ago), after this session read it: BriefBar "
                        + "shows theirs, the later."
                )
            } else if following.contains(ref) {
                lines.append(
                    "The user had set \(theirs.stage.title)\(on) \(ago) already; yours lasts as theirs does, and goes with "
                        + "it, rather than end once someone else votes."
                )
            } else if theirs.stage != stage, standing(theirs, ref) {
                let outlasts = outlasting.contains(ref)
                let (shows, once) = outlasts ? ("shows over it", "shows again") : ("replaces it", "goes too")
                lines.append(
                    "The user had set \(theirs.stage.title)\(on) \(ago); yours \(shows). They can put theirs back "
                        + "while yours lasts; once yours ends, theirs \(once)."
                )
            }
        }
        return (lines + notSet).joined(separator: "\n")
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

    /// The stage `pull_request_stage` names: nil to clear it. Can merge, Waits and Merged come only from what BriefBar
    /// sees.
    static func stage(_ value: JSONValue?) throws -> PullRequestStage? {
        let names = stageNames.map(\.name)
        let choices = names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
        guard let text = value?.string else { throw MCPToolError("Give stage: \(choices).") }
        let name = text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        if let named = stageNames.first(where: { $0.name == name }) { return named.stage }
        if ["can_merge", "waits", "merged"].contains(name) {
            throw MCPToolError("""
                BriefBar sets Can merge, Waits and Merged itself, from what Azure DevOps shows and the order: give stage \
                as \(choices).
                """)
        }
        throw MCPToolError("There's no stage “\(text)”: give stage as \(choices).")
    }

    // MARK: Words

    /// "!4093 in contoso", "!4093 and !4102 in contoso": each organization's together, in the order they're named.
    static func labels(_ refs: [ItemRef]) -> String {
        var organizations: [String] = []
        var numbers: [String: [String]] = [:]
        for ref in refs {
            if numbers[ref.scope] == nil { organizations.append(ref.scope) }
            numbers[ref.scope, default: []].append("!\(ref.id)")
        }
        return joined(organizations.map { joined(numbers[$0] ?? []) + " in \($0)" })
    }

    private static func joined(_ parts: [String]) -> String {
        guard parts.count > 1, let last = parts.last else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: Schemas

    private static func array(_ description: String, items: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "description": .string(description), "items": items])
    }

    private static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}

/// The orders BriefBar keeps, and the stages sessions set, as `--mcp` reads and changes them: one change at a time, saved
/// as the app saves them, and the app told at once. Two programs changing the orders at the very same moment can lose one
/// change, as the preferences have no transactions; an order's revision keeps an agent from replacing a newer one than it
/// read. Each session's stages are under its own key, which only its `--mcp` writes (`SessionStages`).
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
    /// Where the demo keeps what sessions set, for Azure DevOps' tools to read.
    private let demoStages: DemoSessionStages?

    init(settings: Settings, demo: Bool, announce: @escaping @Sendable () -> Void, demoStages: DemoSessionStages? = nil) {
        defaults = settings.defaults
        self.demo = demo
        self.announce = announce
        self.demoStages = demoStages
    }

    var orders: DeclaredOrders {
        DeclaredOrders.load(from: defaults)
    }

    /// The user's changes to missions, as the app keeps them: only the app writes them.
    var userChanges: OrderChanges {
        OrderChanges.load(from: defaults)
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

    /// The stages the user set on these pull requests, as the app keeps them for the account they were read with.
    private func userMarks(of refs: [ItemRef], account: String?) -> [ItemRef: StageMark] {
        guard let account else { return [:] }
        let marks = StageMarks.load(from: defaults)
        var found: [ItemRef: StageMark] = [:]
        for ref in refs {
            found[ref] = marks.mark(of: ref, for: account)
        }
        return found
    }

    /// What the sessions set on each of these pull requests, of those the Copilot app lists, or of all of them where
    /// `--mcp` can't tell, as their keys have them now.
    private func sessionMarks(on refs: [ItemRef], listed: Set<ItemRef>?, now: Date) -> [ItemRef: [StageMark]] {
        let stages = SessionStages.load(from: defaults, now: now)
        let refs = Set(refs)
        return stages.marks(listed: listed ?? Set(stages.sessions.keys), now: now).filter { refs.contains($0.key) }
    }

    /// Changes what a session set on its pull requests' stages, saving it under its own key, and tells the app when that
    /// changed it: what it had set before, but what's past its time, and what it sets now. Refused, changing nothing,
    /// while Pull Request Order is off, or `refusal` gives an answer, asked just before.
    @discardableResult
    func changeStages(
        _ session: ItemRef, now: Date, unless refusal: @Sendable () -> String? = { nil },
        _ body: @Sendable (inout SessionStage) -> Void
    ) throws -> (before: SessionStage?, after: SessionStage) {
        if let refusal = refusal() { throw MCPToolError(refusal) }
        guard isOn else { throw MCPToolError(PullRequestOrderMCP.refusal) }
        return keep(session, now: now, body)
    }

    /// Sets these stages as this session's. A Your review where the user set a Your review before the session read the
    /// pull request, which outlasts what every listed session set there since, this one too (`StageMark.outlasts`):
    /// only In progress, and Your reviews that followed theirs this way, keeps no votes (`StageMark.follows`): it lasts
    /// as theirs does, while theirs is there, rather than end as someone else votes, and theirs with it. One the user
    /// set as the session read the pull request came after what it says, so it keeps its votes, as anywhere. It decides
    /// as it keeps them, in one step, so that a call of this session's in between can't make it go stale. Refused,
    /// changing nothing, while Pull Request Order is off, or `refusal` gives an answer, asked just before.
    /// - Returns: the stages the user set on them, as it read them; those whose Your review follows theirs; and those
    ///   whose In progress shows over a Your review of theirs that outlasts it, what other sessions set there too.
    func setStages(
        _ marks: [ItemRef: StageMark], of session: ItemRef, account: String?, listed: Set<ItemRef>?, now: Date,
        unless refusal: @Sendable () -> String? = { nil }
    ) throws -> (yours: [ItemRef: StageMark], following: Set<ItemRef>, outlasting: Set<ItemRef>) {
        if let refusal = refusal() { throw MCPToolError(refusal) }
        guard isOn else { throw MCPToolError(PullRequestOrderMCP.refusal) }
        let refs = Array(marks.keys)
        let yours = userMarks(of: refs, account: account)
        let set = sessionMarks(on: refs, listed: listed, now: now)
        let following = Set(refs.filter { ref in
            guard var mark = marks[ref], let theirs = yours[ref] else { return false }
            mark.votes = nil
            return mark.follows(theirs) && theirs.outlasts(set[ref] ?? [])
        })
        // What this session set there before goes as this replaces it.
        let outlasting = Set(refs.filter { ref in
            guard marks[ref]?.stage == .inProgress, let theirs = yours[ref] else { return false }
            return theirs.outlasts((set[ref] ?? []).filter { $0.by != session })
        })
        keep(session, now: now) { kept in
            for (ref, mark) in marks {
                var mark = mark
                if following.contains(ref) { mark.votes = nil }
                kept.set(mark, of: ref)
            }
        }
        return (yours, following, outlasting)
    }

    /// Saves what a session set under its own key, and tells the app when that changed it.
    @discardableResult
    private func keep(
        _ session: ItemRef, now: Date, _ body: (inout SessionStage) -> Void
    ) -> (before: SessionStage?, after: SessionStage) {
        var before = SessionStages.load(session, from: defaults)
        before?.expire(now: now)
        let after = SessionStages.change(session, in: defaults, now: now, body)
        if after != before ?? SessionStage(session: session), !demo { announce() }
        demoStages?.keep(SessionStages.load(from: defaults, now: now))
        return (before, after)
    }
}
