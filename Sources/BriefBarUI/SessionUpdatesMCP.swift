import BriefBarCore
import Foundation

/// Updates from Copilot Sessions' tools, for agents through `--mcp`: a Copilot session tells BriefBar what it's working on
/// (`working_on`), and what it just changed in Azure DevOps with its own tools (`changed_in_azure_devops`), so that
/// BriefBar shows its session on them and reads them again sooner. They change only what BriefBar keeps of what sessions
/// told it (`SessionReports`, `RereadRequests`), never anything in Azure DevOps or on GitHub, and answer with only what the
/// agent told.
package enum SessionUpdatesMCP {
    /// What the tools answer while Updates from Copilot Sessions is off.
    static let refusal = """
        Updates from Copilot Sessions is off in BriefBar, so it keeps nothing sessions tell it. Only the user can turn it \
        on, in BriefBar's Settings, under Agents.
        """

    /// The tools, only while Updates from Copilot Sessions is on when `--mcp` starts, as it's off until you turn it on;
    /// each call checks again that it's on. The demo keeps what it's told in memory, with it on.
    /// - Parameters:
    ///   - defaults: the app's settings, or the demo's.
    ///   - sourcesOn: the sources that are on in the app, asked with each call.
    ///   - session: the Copilot session that started `--mcp`, the only one whose work it tells.
    ///   - id: this `--mcp`'s own, under which it keeps what it asks the app to read again.
    ///   - announce: tells the app that what sessions told changed.
    package static func tools(
        defaults: UserDefaults, demo: Bool, sourcesOn: @escaping @Sendable () -> Set<SourceID>, session: String?,
        id: String = UUID().uuidString.lowercased(), announce: @escaping @Sendable () -> Void = AgentChanges.post,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> [MCPTool] {
        guard demo || SessionUpdatesSetting.isOn(in: defaults) else { return [] }
        let keeper = SessionUpdatesKeeper(settings: OrderKeeper.Settings(defaults), demo: demo, id: id, announce: announce)
        let started = session.flatMap(ItemRef.session)
        return [
            MCPTool(
                name: "working_on",
                title: "Working On",
                description: """
                    Tells BriefBar the work items and pull requests your Copilot session is working on now, so that it \
                    shows the user your session on them: in its sprint, its lists and their details. Send the whole list \
                    each time it changes, and an empty one when you stop or hand them off. Name each by its link, or an \
                    Azure DevOps one by its number with organization. It changes nothing in Azure DevOps or on GitHub.
                    """,
                inputSchema: MCPSchema.object([
                    "work_items": array(
                        "The Azure DevOps work items you're working on: their links, or their numbers with organization"
                    ),
                    "pull_requests": array(
                        """
                        The pull requests you're working on: their links, in Azure DevOps or on GitHub, or Azure DevOps \
                        numbers with organization
                        """
                    ),
                    "organization": MCPSchema.string("The Azure DevOps organization of the numbers, such as contoso"),
                    "session": MCPSchema.string("Your Copilot session's ID, only when BriefBar can't tell which session you are"),
                ]),
                readOnly: false
            ) { arguments in
                try await workingOn(arguments, keeper: keeper, sourcesOn: sourcesOn(), started: started, now: now())
            },
            MCPTool(
                name: "changed_in_azure_devops",
                title: "Changed in Azure DevOps",
                description: """
                    Tells BriefBar what you just changed in Azure DevOps with your own tools, such as a pull request you \
                    opened, pushed to or replied on, or work items you created, changed or linked, so that it reads them \
                    again now rather than at its next refresh, and the user sees them. Say which pull requests you opened \
                    yourself, so that it shows them as your session's. BriefBar reads only what it shows anyway, and \
                    changes nothing in Azure DevOps.
                    """,
                inputSchema: MCPSchema.object([
                    "opened": array("Pull requests you opened yourself: their links, or their numbers with organization"),
                    "pull_requests": array("Other pull requests you changed: their links, or their numbers with organization"),
                    "work_items": array(
                        """
                        Work items you created, changed or linked to something: their links, or their numbers with \
                        organization. For many under one, such as a story's new tasks, the one they're under is enough
                        """
                    ),
                    "organization": MCPSchema.string("The Azure DevOps organization of the numbers, such as contoso"),
                    "session": MCPSchema.string("Your Copilot session's ID, only when BriefBar can't tell which session you are"),
                ]),
                readOnly: false
            ) { arguments in
                try await changed(arguments, keeper: keeper, sourcesOn: sourcesOn(), started: started, now: now())
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

    static func workingOn(
        _ arguments: JSONValue, keeper: SessionUpdatesKeeper, sourcesOn: Set<SourceID>, started: ItemRef?, now: Date
    ) async throws -> String {
        guard sourcesOn.contains(.copilot) else { throw MCPToolError(AgentAccess.refusal(source: "GitHub Copilot")) }
        let organization = arguments["organization"]?.string
        let workItems = try refs(arguments["work_items"], in: "work_items", as: [.workItem], organization: organization)
        let pullRequests = try refs(
            arguments["pull_requests"], in: "pull_requests", as: [.pullRequest, .gitHubPullRequest], organization: organization
        )
        try checkCount(workItems + pullRequests)
        guard let session = try session(arguments, started: started) else {
            throw MCPToolError("BriefBar can't tell which Copilot session you are: send session, your session's ID.")
        }
        let (shown, notShown) = split(workItems + pullRequests, sourcesOn: sourcesOn)
        let before = await keeper.report(session)
        let told = await keeper.change(session, now: now) { $0.setWorkingOn(shown, at: now) }
        let demo = keeper.demo ? " (The demo keeps it in memory.)" : ""
        var lines: [String]
        if told.workingOn.isEmpty {
            let stopped = before?.workingOn.isEmpty == false
            let opening = stopped ? "BriefBar no longer shows this session on anything." : "BriefBar shows this session on nothing."
            lines = [opening + demo]
        } else {
            lines = [
                "BriefBar shows this session on \(names(told.workingOn)) now.\(demo) Tell it again, with the whole list, "
                    + "whenever that changes, and with none when you stop.",
            ]
        }
        lines += notShown
        return lines.joined(separator: "\n")
    }

    static func changed(
        _ arguments: JSONValue, keeper: SessionUpdatesKeeper, sourcesOn: Set<SourceID>, started: ItemRef?, now: Date
    ) async throws -> String {
        guard sourcesOn.contains(.azureDevOps) else { throw MCPToolError(AgentAccess.refusal(source: "Azure DevOps")) }
        let organization = arguments["organization"]?.string
        let opened = try refs(arguments["opened"], in: "opened", as: [.pullRequest], organization: organization)
        let pullRequests = try refs(
            arguments["pull_requests"], in: "pull_requests", as: [.pullRequest], organization: organization
        )
        let workItems = try refs(arguments["work_items"], in: "work_items", as: [.workItem], organization: organization)
        var all: [ItemRef] = []
        for ref in opened + pullRequests + workItems where !all.contains(ref) {
            all.append(ref)
        }
        guard !all.isEmpty else {
            throw MCPToolError("""
                Name what you changed: the pull requests you opened, in opened; others, in pull_requests; work items, in \
                work_items.
                """)
        }
        try checkCount(all)
        let session = try session(arguments, started: started)
        await keeper.reread(all, now: now)
        let demo = keeper.demo ? " (The demo keeps it in memory.)" : ""
        var lines = ["BriefBar reads \(names(all)) again shortly, if it's running, rather than at its next refresh.\(demo)"]
        if !opened.isEmpty {
            if !sourcesOn.contains(.copilot) {
                lines.append("It can't show which session opened \(names(opened)): GitHub Copilot is off in BriefBar.")
            } else if let session {
                await keeper.change(session, now: now) { $0.addOpened(opened, at: now) }
                lines.append("It shows \(names(opened)) as opened by this session.")
            } else {
                lines.append("It can't tell which session opened \(names(opened)): send session, your session's ID.")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Reading what the agent sent

    /// The session the call tells for: the one that started `--mcp`, which `session` can only repeat; or, when BriefBar
    /// can't tell which that is, the one `session` names. A session tells only its own work: never a coordinator its
    /// children's.
    static func session(_ arguments: JSONValue, started: ItemRef?) throws -> ItemRef? {
        let text = arguments["session"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !text.isEmpty else { return started }
        guard let named = ItemRef.session(text) else {
            throw MCPToolError("“\(text)” isn't a Copilot session's ID: leave session out, and BriefBar uses yours.")
        }
        if let started, named != started {
            throw MCPToolError("""
                A session tells BriefBar only its own work, and you are session \(started.id): leave session out. A \
                session you coordinate tells its own.
                """)
        }
        return named
    }

    /// What a list names, each as `ItemRef.named` reads it.
    static func refs(
        _ value: JSONValue?, in field: String, as kinds: Set<ItemRef.Kind>, organization: String?
    ) throws -> [ItemRef] {
        let what = kinds.contains(.workItem) ? "work item" : "pull request"
        var refs: [ItemRef] = []
        for text in try texts(value, in: field, what: what) {
            if let ref = ItemRef.named(text, as: kinds, organization: organization) {
                if !refs.contains(ref) { refs.append(ref) }
                continue
            }
            if let other = ItemRef.from(link: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                if other.kind == .gitHubPullRequest {
                    throw MCPToolError("BriefBar reads only Azure DevOps again: leave \(name(other)) out of \(field).")
                }
                throw MCPToolError("\(name(other)) isn't a \(what): name it in the list for its kind.")
            }
            let number = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#!"))
            if Int(number) != nil, organization?.isEmpty != false {
                throw MCPToolError(
                    "Send organization with numbers, such as 5101: BriefBar can't tell organizations apart from a number."
                )
            }
            throw MCPToolError(
                "BriefBar can't read “\(text)” in \(field) as a \(what): send its link, or its number with organization."
            )
        }
        return refs
    }

    /// A list of strings, one on its own, or numbers.
    private static func texts(_ value: JSONValue?, in field: String, what: String) throws -> [String] {
        switch value {
        case nil, .null?: return []
        case .string(let text)?: return [text]
        case .int(let number)?: return [String(number)]
        case .array(let values)?:
            return try values.map { value in
                if let text = value.string { return text }
                if case .int(let number) = value { return String(number) }
                throw MCPToolError("Name each \(what) in \(field) by its link or its number.")
            }
        default:
            throw MCPToolError("Give \(field) as a list, by links or numbers.")
        }
    }

    private static func checkCount(_ refs: [ItemRef]) throws {
        guard refs.count <= SessionReports.mostItems else {
            throw MCPToolError("""
                Name at most \(SessionReports.mostItems) in all. For many work items under one, such as a story's tasks, \
                the one they're under is enough.
                """)
        }
    }

    /// What BriefBar can show, and a line for each it can't, as its source is off.
    private static func split(_ refs: [ItemRef], sourcesOn: Set<SourceID>) -> (shown: [ItemRef], notShown: [String]) {
        var shown: [ItemRef] = []
        var notShown: [String] = []
        for ref in refs {
            let source: (id: SourceID, name: String) =
                ref.kind == .gitHubPullRequest ? (.github, "GitHub") : (.azureDevOps, "Azure DevOps")
            if sourcesOn.contains(source.id) {
                shown.append(ref)
            } else {
                notShown.append("Not \(name(ref)): \(source.name) is off in BriefBar.")
            }
        }
        return (shown, notShown)
    }

    // MARK: Words

    /// "Work Item 5101", "Pull Request !4071", "Pull Request octo/app#12".
    static func name(_ ref: ItemRef) -> String {
        switch ref.kind {
        case .workItem: return "Work Item \(ref.id)"
        case .pullRequest: return "Pull Request !\(ref.id)"
        case .gitHubPullRequest: return "Pull Request \(ref.scope)#\(ref.id)"
        case .session: return "session \(ref.id)"
        }
    }

    /// "Work Items 5101 and 5124 and Pull Request !4071": each kind together, in kind order.
    static func names(_ refs: [ItemRef]) -> String {
        var parts: [String] = []
        let workItems = refs.filter { $0.kind == .workItem }
        if workItems.count == 1, let only = workItems.first { parts.append(name(only)) }
        if workItems.count > 1 { parts.append("Work Items " + joined(workItems.map(\.id))) }
        let pullRequests = refs.filter(\.kind.isPullRequest)
        if pullRequests.count == 1, let only = pullRequests.first { parts.append(name(only)) }
        if pullRequests.count > 1 {
            let numbers = pullRequests.map { name($0).replacingOccurrences(of: "Pull Request ", with: "") }
            parts.append("Pull Requests " + joined(numbers))
        }
        return joined(parts)
    }

    private static func joined(_ parts: [String]) -> String {
        guard parts.count > 1, let last = parts.last else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }

    private static func array(_ description: String) -> JSONValue {
        .object([
            "type": .string("array"), "description": .string(description), "items": .object(["type": .string("string")]),
        ])
    }
}

/// What sessions told, as `--mcp` reads and changes it: one change at a time, each session's report under its own key,
/// saved as the app saves its settings, and the app told at once (`AgentChanges`).
actor SessionUpdatesKeeper {
    private let defaults: UserDefaults
    let demo: Bool
    /// This `--mcp`'s own, under which it keeps what it asks the app to read again.
    private let id: String
    private let announce: @Sendable () -> Void

    init(settings: OrderKeeper.Settings, demo: Bool, id: String, announce: @escaping @Sendable () -> Void) {
        defaults = settings.defaults
        self.demo = demo
        self.id = id
        self.announce = announce
    }

    /// Whether Updates from Copilot Sessions is on, asked with each call: the demo's always is.
    var isOn: Bool {
        demo || SessionUpdatesSetting.isOn(in: defaults)
    }

    func report(_ session: ItemRef) -> SessionReport? {
        SessionReports.load(session, from: defaults)
    }

    /// Changes what a session told, and saves it, telling the app.
    @discardableResult
    func change(_ session: ItemRef, now: Date, _ body: @Sendable (inout SessionReport) -> Void) -> SessionReport {
        let report = SessionReports.change(session, in: defaults, now: now, body)
        if !demo { announce() }
        return report
    }

    /// Asks the app to read these again, telling it.
    func reread(_ refs: [ItemRef], now: Date) {
        RereadRequests.add(refs, id: id, to: defaults, now: now)
        if !demo { announce() }
    }
}
