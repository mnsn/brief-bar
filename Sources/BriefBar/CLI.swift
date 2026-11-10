import BriefBarCore
import BriefBarUI
import Foundation

/// Command-line modes, mainly for checking what the menu bar would show.
@MainActor
enum CLI {
    static var usage: String {
        var lines = [
            "BriefBar: what needs you, from the apps you choose, in the macOS menu bar.",
            "",
            "Usage: BriefBar [--source <name>]… [option]",
            "  (no option)        Run the menu-bar app",
            "  --dump             Print what each source shows",
            "  --json             Print the same as JSON, by source, each with its counts",
            "  --watch            Print changes as they happen (Ctrl-C to stop)",
            "  --mcp              Serve agents, such as the Copilot CLI, over the Model Context Protocol on",
            "                     standard input and output: what needs you, your pull requests, pipelines,",
            "                     sprint and Copilot sessions, from Azure DevOps and Copilot, never Teams or",
            "                     GitHub; with Pull Request Order on, the orders sessions tell it; and with",
            "                     Updates from Copilot Sessions on, what sessions tell it they work on and changed.",
            "                     It answers only once you let agents use BriefBar, in its Settings, under Agents",
            "  --render <dir>     Draw the menu bar with each list open, the widgets, the window and Settings",
            "                     into PNGs (light and dark)",
            "  --part <n>         With --render, draw only the n-th hundred of those pictures, as make screenshots",
            "                     does, a process for each: it exits with 3 when another part follows",
            "  --window           Run the app, and open its window",
            "  --source <name>    Only this source: teams, ado, copilot or github (repeatable). Without it, the modes",
            "                     cover the sources that are on in the app.",
            "  --demo             Use made-up data for every source, with any of the above or the app",
            "  --check-updater    Start the updater as the app does, and show that macOS doesn't let it use",
            "                     BriefBar's privacy permissions",
            "  --help             Show this help",
        ]
        for commandLine in SourceCatalog.commandLines where !commandLine.usage.isEmpty {
            lines.append("")
            lines.append(commandLine.usage)
        }
        lines += [
            "",
            "Letting agents use BriefBar adds it to the Copilot CLI's MCP servers. To add it yourself:",
            "  copilot mcp add briefbar -- \(Bundle.main.executablePath ?? "BriefBar") --mcp",
            "",
            "Their output shows your own names, messages and titles, so keep it to yourself: --mcp gives",
            "them to the agent, whose model may run in the cloud. They run only",
            "from a shell, such as Terminal's, with its permissions: started as an app (by open, say),",
            "BriefBar has its own Full Disk Access, so it refuses them, all but --help and --check-updater.",
        ]
        return lines.joined(separator: "\n")
    }

    /// Returns an exit code for command-line modes, or nil to launch the app.
    static func run(_ arguments: [String], attribution: Attribution = .current) -> Int32? {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        // A diagnostic that reads nothing of yours, and starts no source, so it takes no other option either.
        if arguments.contains("--check-updater") {
            guard arguments == ["--check-updater"] else {
                fputs("--check-updater takes no other option.\n", stderr)
                return 2
            }
            return UpdaterCheck.run()
        }
        let commandLines = SourceCatalog.commandLines
        let ownFlags = commandLines.flatMap { $0.flags }
        let modes = ["--dump", "--json", "--watch", "--mcp"]
        guard arguments.contains(where: { modes.contains($0) || ownFlags.contains($0) }) else { return nil }
        if let refusal = CommandLineAccess.refusal(attribution) {
            fputs("\(refusal)\n", stderr)
            return 1
        }
        let options = CommandLineOptions(arguments: arguments, demo: arguments.contains("--demo"))

        // A source's own modes imply that source.
        for commandLine in commandLines where commandLine.flags.contains(where: arguments.contains) {
            if let code = commandLine.run(options) { return code }
        }

        let named: [SourceID]
        do {
            named = try sources(named: arguments)
        } catch {
            fputs("\(error)\n", stderr)
            return 2
        }
        if arguments.contains("--mcp") {
            return serveAgents(named: named, options: options)
        }
        let selected = commandLines.filter { commandLine in
            if !named.isEmpty { return named.contains(commandLine.source) }
            if options.demo { return true }
            return isOnInTheApp(commandLine)
        }
        guard !selected.isEmpty else {
            fputs("Nothing is on in BriefBar. Choose a source with --source teams, ado, copilot or github.\n", stderr)
            return 1
        }

        if arguments.contains("--json") {
            var output: [String: Any] = [:]
            var status: Int32 = 0
            for commandLine in selected {
                if let object = commandLine.json(options) {
                    output[commandLine.source.rawValue] = object
                } else {
                    status = 1
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) else {
                return 1
            }
            FileHandle.standardOutput.write(data)
            print()
            return status
        }
        if arguments.contains("--dump") {
            var status: Int32 = 0
            for (index, commandLine) in selected.enumerated() {
                if selected.count > 1 {
                    if index > 0 { print() }
                    print("== \(name(of: commandLine.source)) ==")
                }
                status = max(status, commandLine.dump(options))
            }
            return status
        }
        // --watch
        var keepsWatching = false
        for commandLine in selected {
            keepsWatching = commandLine.watch(options) || keepsWatching
        }
        guard keepsWatching else { return 0 }
        dispatchMain()
    }

    struct UnknownSource: Error, CustomStringConvertible {
        var name: String
        var description: String { "Unknown source \"\(name)\": use teams, ado, copilot or github." }
    }

    /// The sources that `--source` names.
    static func sources(named arguments: [String]) throws -> [SourceID] {
        var names: [SourceID] = []
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--source" {
                guard index + 1 < arguments.count else { throw UnknownSource(name: "") }
                let name = arguments[index + 1]
                switch name.lowercased() {
                case "teams": names.append(.teams)
                case "ado", "azuredevops", "azure-devops", "devops": names.append(.azureDevOps)
                case "copilot": names.append(.copilot)
                case "github", "gh": names.append(.github)
                default: throw UnknownSource(name: name)
                }
                index += 1
            }
            index += 1
        }
        return names
    }

    /// Whether the source is on in the installed app.
    private static func isOnInTheApp(_ commandLine: any SourceCommandLine.Type) -> Bool {
        isOnInTheApp(commandLine.source, version: commandLine.descriptionVersion)
    }

    private nonisolated static func isOnInTheApp(_ source: SourceID, version: Int) -> Bool {
        guard let defaults = AppIdentity.installedAppDefaults else { return false }
        return SourceChoices.load(from: defaults).state(of: source, version: version) == .on
    }

    /// `--mcp`: the sources' tools, for an agent, until it closes standard input. Each call checks, as it comes, that you
    /// still let agents use BriefBar, and that its source is still on: `--source` narrows the sources, and never adds one
    /// that's off. With Pull Request Order on when it starts, its tools too, and Updates from Copilot Sessions' with that
    /// on, each call checking that it's still on. The demo answers with made-up data, whatever the app's settings.
    private static func serveAgents(named: [SourceID], options: CommandLineOptions) -> Int32 {
        var sources: [MCPSource] = []
        for commandLine in SourceCatalog.commandLines where named.isEmpty || named.contains(commandLine.source) {
            guard var source = commandLine.mcp(options) else { continue }
            if !options.demo {
                let id = commandLine.source
                let version = commandLine.descriptionVersion
                source = source.available(
                    while: { isOnInTheApp(id, version: version) },
                    refusal: AgentAccess.refusal(source: source.name)
                )
            }
            sources.append(source)
        }
        guard !sources.isEmpty else {
            fputs("Agents can use Azure DevOps and Copilot, never Teams or GitHub.\n", stderr)
            return 2
        }
        let demo = options.demo
        let consent: @Sendable () -> String? = {
            demo ? nil : AgentAccess.refusal(AppIdentity.installedAppDefaults.map { AgentAccess.state(in: $0) } ?? .off)
        }
        let orderTools = orderTools(options, stages: sources.lazy.compactMap(\.stages).first?.guarded(by: consent))
        let updateTools = updateTools(options)
        // Pull Request Order's tools can ask the sources what they know too, such as which sessions the app lists.
        let tellers = sources.compactMap(\.related)
        let tools = MCPSource.tools(sources, refusal: consent)
            + orderTools.map { $0.guarded(by: consent).telling(tellers) } + updateTools.map { $0.guarded(by: consent) }
        let tellsStages = orderTools.contains { $0.name == "pull_request_stage" }
        var changes = ["the pull requests it watches", "the pipelines it pins"]
        if !orderTools.isEmpty {
            changes.append(
                tellsStages ? "the orders and stages sessions tell it of their pull requests" : "the orders sessions tell it their pull requests merge in"
            )
        }
        if !updateTools.isEmpty { changes.append("what sessions tell it they work on and opened") }
        var ordering = ""
        if tellsStages {
            ordering = """
                 Keep BriefBar current on your pull requests without being asked: when you open pull requests that go \
                together, tell their order with order_pull_requests as each opens; after you push a pull request's work, \
                tell its stage with pull_request_stage, user_review; when the user says they've reviewed it, \
                teammate_review. What you tell shows as yours; the user can change it. \(Self.stories)
                """
        } else if !orderTools.isEmpty {
            ordering = """
                 When you open pull requests that must merge in an order, tell BriefBar with order_pull_requests, and again \
                whenever that order changes. \(Self.stories)
                """
        }
        if !updateTools.isEmpty {
            ordering += """
                 Tell BriefBar what you work on with working_on, and what you just changed in Azure DevOps with \
                changed_in_azure_devops.
                """
        }
        let changed = changes.dropLast().joined(separator: ", ") + " and " + (changes.last ?? "")
        let identity = MCPServer.Identity(
            name: "briefbar", title: AppIdentity.name, version: AppIdentity.version,
            instructions: """
                BriefBar is the user's macOS menu-bar app for what needs them: \(sources.map(\.name).joined(separator: " and ")). \
                Start with needs_me. Its answers speak to the user, as BriefBar does: "you" is the user. It reads Azure \
                DevOps with the user's Azure CLI sign-in and only reads there; the only things it changes are BriefBar's \
                own lists, \(changed). To work on a pull request, follow the prompt pull_request_prompt gives.\(ordering)
                """
        )
        MCPStandardIO.serve(identity: identity, tools: tools)
    }

    /// What `--mcp`'s instructions tell sessions of stories, with Pull Request Order's tools (plan §7.4.6).
    static let stories = """
        With Show Links on, BriefBar puts the Azure DevOps pull requests of one story's tasks together by itself, in the \
        tasks' backlog order: link each to its task as you open it, and tell an order only where they must merge in another \
        order, or wait for one another.
        """

    /// Pull Request Order's tools, while it's on in the app, as it's off until you turn it on; the demo's always are, and
    /// keep their orders, and the stages they're told, in memory, the stages where Azure DevOps' tools read them
    /// (`CommandLineOptions.demoStages`). An order says which Copilot session told it: the one that started `--mcp`, as
    /// the Copilot CLI says, unless the agent names another. `pull_request_stage` is there only where the Copilot CLI
    /// says which session that is, never in VS Code or Cursor, and sets only that session's stages.
    /// - Parameter stages: what Azure DevOps tells of its pull requests' stages, with it among the sources, for
    ///   `pull_request_stage`, which is there only with it.
    private static func orderTools(_ options: CommandLineOptions, stages: MCPStages?) -> [MCPTool] {
        let demo = options.demo
        guard let defaults = demo ? MemoryDefaults() : AppIdentity.installedAppDefaults else { return [] }
        let versions = Dictionary(
            SourceCatalog.commandLines.map { ($0.source, $0.descriptionVersion) }, uniquingKeysWith: { first, _ in first }
        )
        let sourcesOn: @Sendable () -> Set<ItemRef.Kind> = {
            func isOn(_ source: SourceID) -> Bool {
                demo || versions[source].map { isOnInTheApp(source, version: $0) } == true
            }
            var kinds: Set<ItemRef.Kind> = []
            if isOn(.azureDevOps) { kinds.insert(.pullRequest) }
            if isOn(.github) { kinds.insert(.gitHubPullRequest) }
            return kinds
        }
        let copilotOn: @Sendable () -> Bool = {
            demo || versions[.copilot].map { isOnInTheApp(.copilot, version: $0) } == true
        }
        return PullRequestOrderMCP.tools(
            defaults: defaults, demo: demo, sourcesOn: sourcesOn, session: Attribution.environment["COPILOT_AGENT_SESSION_ID"],
            stages: stages, copilotOn: copilotOn, demoStages: options.demoStages
        )
    }

    /// Updates from Copilot Sessions' tools, while it's on in the app, as it's off until you turn it on; the demo's always
    /// are, and keep what they're told in memory. They tell only the work of the Copilot session that started `--mcp`, as
    /// the Copilot CLI says.
    private static func updateTools(_ options: CommandLineOptions) -> [MCPTool] {
        let demo = options.demo
        guard let defaults = demo ? MemoryDefaults() : AppIdentity.installedAppDefaults else { return [] }
        let versions = Dictionary(
            SourceCatalog.commandLines.map { ($0.source, $0.descriptionVersion) }, uniquingKeysWith: { first, _ in first }
        )
        let sourcesOn: @Sendable () -> Set<SourceID> = {
            Set(SourceID.allCases.filter { source in demo || versions[source].map { isOnInTheApp(source, version: $0) } == true })
        }
        return SessionUpdatesMCP.tools(
            defaults: defaults, demo: demo, sourcesOn: sourcesOn, session: Attribution.environment["COPILOT_AGENT_SESSION_ID"]
        )
    }

    private static func name(of source: SourceID) -> String {
        switch source {
        case .teams: return "Microsoft Teams"
        case .azureDevOps: return "Azure DevOps"
        case .copilot: return "GitHub Copilot"
        case .github: return "GitHub"
        }
    }
}
