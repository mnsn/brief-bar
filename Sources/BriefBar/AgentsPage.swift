import AppKit
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// Whether agents may use BriefBar (`BriefBar --mcp`), and BriefBar among the Copilot CLI's MCP servers. Agents are off
/// until you turn them on, like a source: turning them on adds BriefBar to the Copilot CLI, and turning them off
/// removes it. BriefBar's plugin for Copilot, which gives the GitHub Copilot app and the CLI `/briefbar`, is installed
/// only when you ask, once agents are on, and turning them off removes it too. If the CLI can't remove either, the page
/// says so while agents are off, and tries again when you ask. Other agents' apps, such as VS Code, get
/// BriefBar only when you install it in them, with their own install links, and keep it until you remove it there. The
/// demo and `--render` never run the CLI or open another app, and show what the CLI would say.
@MainActor
final class AgentsModel: ObservableObject {
    /// BriefBar among the Copilot CLI's servers, as the CLI last said.
    enum Registration: Equatable {
        case unknown
        /// Asking the CLI, or changing what it has.
        case working
        case known(CopilotMCPRegistration.Status)
    }

    /// BriefBar's plugin among the Copilot CLI's, as the CLI last said.
    enum Plugin: Equatable {
        case unknown
        /// Asking the CLI, or changing what it has.
        case working
        case known(CopilotPluginRegistration.Status)
    }

    @Published private(set) var state: SourceState
    /// BriefBar's server and plugin in the CLI: working until the last check or change asked for is done, so that an
    /// earlier one's answer isn't shown while a later one is still to come (`CopilotCLIProgress`).
    @Published private var serverProgress = CopilotCLIProgress<CopilotMCPRegistration.Status>()
    @Published private var pluginProgress = CopilotCLIProgress<CopilotPluginRegistration.Status>()

    var registration: Registration {
        if serverProgress.isWorking { return .working }
        return serverProgress.status.map(Registration.known) ?? .unknown
    }

    var plugin: Plugin {
        if pluginProgress.isWorking { return .working }
        return pluginProgress.status.map(Plugin.known) ?? .unknown
    }

    private let defaults: UserDefaults
    private let isLive: Bool
    /// BriefBar's binary, which agents start with `--mcp`.
    let executable: String
    /// The marketplace in BriefBar.app that holds its plugin, or nil in a build without it.
    private let pluginMarketplace: URL?
    /// The CLI, once found with your login shell's environment.
    private var cli: CopilotMCPRegistration?
    /// The last change, which the next one waits for, so they reach the CLI in the order you made them.
    private var last: Task<Void, Never>?
    private var checkedAt: Date?
    private var pluginCheckedAt: Date?

    init(
        defaults: UserDefaults, isLive: Bool, executable: String = Bundle.main.executablePath ?? AppIdentity.name,
        pluginMarketplace: URL? = CopilotPluginRegistration.marketplace()
    ) {
        self.defaults = defaults
        self.isLive = isLive
        self.executable = executable
        self.pluginMarketplace = pluginMarketplace
        state = AgentAccess.state(in: defaults)
    }

    /// What an agent runs, to copy.
    var command: String { "\(Self.quoted(executable)) --mcp" }

    /// The agents' apps that BriefBar can be installed in: those on this Mac, or all of them in the demo and `--render`.
    var apps: [AgentApp] {
        guard isLive else { return AgentApp.allCases }
        return AgentApp.allCases.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil }
    }

    /// Installs BriefBar in an agent's app: in GitHub Copilot through the Copilot CLI, whose MCP servers its sessions
    /// use, and in the others with their own install link, which asks you first. The demo opens no other app.
    func install(in app: AgentApp) {
        if app == .gitHubCopilot {
            addToCopilotCLI()
            return
        }
        guard isLive, let link = app.installLink(server: CopilotMCPRegistration.name, command: executable, arguments: ["--mcp"]),
              let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier)
        else { return }
        Log.app.info("Asked \(app.rawValue, privacy: .public) to install BriefBar")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([link], withApplicationAt: application, configuration: configuration)
    }

    /// The Copilot CLI has this BriefBar, turned on there or not.
    var isInCopilotCLI: Bool {
        if case .known(.added) = registration { return true }
        return false
    }

    /// BriefBar can add itself to the Copilot CLI: not while it asks, nor once it's there, without the CLI, or where
    /// another server has its name.
    var canAddToCopilotCLI: Bool {
        switch registration {
        case .unknown:
            return true
        case .working:
            return false
        case .known(let status):
            switch status {
            case .absent, .addedElsewhere, .failed: return true
            case .added, .noCLI, .taken: return false
            }
        }
    }

    /// With your consent to what agents get now. The first time, BriefBar adds itself to the Copilot CLI too, and asks
    /// whether its plugin is there, which it never installs by itself; Keep Them On, after an update, leaves the CLI as
    /// it was.
    func turnOn() {
        guard state != .on else { return }
        let wasOff = state == .off
        AgentAccess.turnOn(in: defaults)
        state = .on
        Log.app.info("Turned on agents")
        if wasOff {
            change(demo: .added(enabled: true)) { await $0.add() }
            refreshPlugin(force: true)
        } else {
            refresh(force: true)
        }
    }

    /// `--mcp` refuses from now on, and BriefBar and its plugin leave the Copilot CLI.
    func turnOff() {
        guard state != .off else { return }
        AgentAccess.turnOff(in: defaults)
        state = .off
        Log.app.info("Turned off agents")
        change(demo: .absent) { await $0.remove() }
        changePlugin(demo: .absent) { await $0.remove() }
    }

    /// Asks the Copilot CLI whether it has BriefBar and its plugin: when the page shows, unless it asked a moment ago.
    func refresh(force: Bool = false) {
        guard state == .on else { return }
        if registration != .working, force || checkedAt.map({ Date().timeIntervalSince($0) >= 30 }) ?? true {
            change(demo: .added(enabled: true)) { await $0.status() }
        }
        refreshPlugin(force: force)
    }

    func addToCopilotCLI() {
        change(demo: .added(enabled: true)) { await $0.add() }
    }

    func removeFromCopilotCLI() {
        change(demo: .absent) { await $0.remove() }
    }

    // MARK: Turned off

    /// While agents are off, what turning them off couldn't remove from the Copilot CLI; nil while BriefBar is still
    /// removing it, once it has, or when agents are on.
    var leftovers: AgentCleanup? {
        guard state == .off else { return nil }
        return AgentCleanup.left(server: serverProgress, plugin: pluginProgress)
    }

    /// While agents are off, BriefBar is removing itself, or its plugin, from the Copilot CLI.
    var isLeaving: Bool { state == .off && (registration == .working || plugin == .working) }

    /// Removes again what turning agents off couldn't.
    func removeLeftovers() {
        guard let leftovers else { return }
        Log.app.info("Removing what turning agents off left in the Copilot CLI")
        if leftovers.server != nil { change(demo: .absent) { await $0.remove() } }
        if leftovers.plugin != nil { changePlugin(demo: .absent) { await $0.remove() } }
    }

    // MARK: The plugin

    /// This copy of BriefBar has its plugin to install: BriefBar.app does, a build from `swift build` doesn't.
    var hasPlugin: Bool { !isLive || pluginMarketplace != nil }

    /// Installs BriefBar's plugin among the Copilot CLI's, or turns it back on there, in place of another copy's: only
    /// when you ask.
    func installPlugin() {
        guard hasPlugin else { return }
        changePlugin(demo: .installed(enabled: true)) { await $0.install() }
    }

    func removePlugin() {
        changePlugin(demo: .absent) { await $0.remove() }
    }

    private func refreshPlugin(force: Bool) {
        guard plugin != .working else { return }
        if !force, let pluginCheckedAt, Date().timeIntervalSince(pluginCheckedAt) < 30 { return }
        // The demo has only what you did on this page.
        var demo = CopilotPluginRegistration.Status.absent
        if case .known(let status) = plugin { demo = status }
        changePlugin(demo: demo) { await $0.status() }
    }

    // MARK: The CLI

    private func change(
        demo: CopilotMCPRegistration.Status, _ action: @escaping @Sendable (CopilotMCPRegistration) async -> CopilotMCPRegistration.Status
    ) {
        guard isLive else {
            serverProgress = CopilotCLIProgress(status: demo)
            return
        }
        let request = serverProgress.ask()
        withCLI { [weak self] cli in
            let status: CopilotMCPRegistration.Status
            if let cli {
                status = await action(cli)
            } else {
                status = .noCLI
            }
            guard let self else { return }
            serverProgress.answer(request, with: status)
            checkedAt = Date()
            Log.app.info("Agents in the Copilot CLI: \(status.kind, privacy: .public)")
        }
    }

    private func changePlugin(
        demo: CopilotPluginRegistration.Status,
        _ action: @escaping @Sendable (CopilotPluginRegistration) async -> CopilotPluginRegistration.Status
    ) {
        guard isLive else {
            pluginProgress = CopilotCLIProgress(status: demo)
            return
        }
        let request = pluginProgress.ask()
        let marketplace = pluginMarketplace
        withCLI { [weak self] cli in
            let status: CopilotPluginRegistration.Status
            if let cli {
                status = await action(CopilotPluginRegistration(
                    cli: cli, marketplace: marketplace, bundleIdentifier: AppIdentity.bundleIdentifier
                ))
            } else {
                status = .noCLI
            }
            guard let self else { return }
            pluginProgress.answer(request, with: status)
            pluginCheckedAt = Date()
            Log.app.info("BriefBar's plugin in the Copilot CLI: \(status.kind, privacy: .public)")
        }
    }

    /// Runs `body` with the Copilot CLI, or nil without one, once the changes asked for before are done. The CLI is
    /// found once, with your login shell's environment.
    private func withCLI(_ body: @escaping @MainActor @Sendable (CopilotMCPRegistration?) async -> Void) {
        let previous = last
        let executable = executable
        last = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if cli == nil { cli = await CopilotMCPRegistration.find(executable: executable) }
            await body(cli)
        }
    }

    /// For `--render`: agents on, BriefBar added to the Copilot CLI and its plugin not installed yet, or as they were,
    /// without saving any of it.
    func useForRendering(on: Bool) {
        state = on ? .on : AgentAccess.state(in: defaults)
        serverProgress = CopilotCLIProgress(status: on ? .added(enabled: true) : nil)
        pluginProgress = CopilotCLIProgress(status: on ? .absent : nil)
    }

    /// For `--render`: agents just turned off, and the Copilot CLI couldn't remove the plugin, without saving either.
    func useForRenderingLeftovers() {
        state = .off
        serverProgress = CopilotCLIProgress(status: .absent)
        pluginProgress = CopilotCLIProgress(
            status: .failed("Couldn't save the settings: another Copilot process is writing them.")
        )
    }

    /// A path as a shell reads it.
    static func quoted(_ path: String) -> String {
        let plain = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+@".contains($0) }
        return plain ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension CopilotMCPRegistration.Status {
    /// For the log, without paths or messages.
    var kind: String {
        switch self {
        case .noCLI: return "no CLI"
        case .absent: return "absent"
        case .added(let enabled): return enabled ? "added" : "added, turned off"
        case .addedElsewhere: return "another copy"
        case .taken: return "name taken"
        case .failed: return "failed"
        }
    }
}

extension CopilotPluginRegistration.Status {
    /// For the log, without paths or messages.
    var kind: String {
        switch self {
        case .noCLI: return "no CLI"
        case .absent: return "absent"
        case .installed(let enabled): return enabled ? "installed" : "installed, turned off"
        case .installedElsewhere: return "another copy"
        case .taken: return "name taken"
        case .failed: return "failed"
        }
    }
}

// MARK: - The page

enum AgentsText {
    static let symbol = "sparkles"
    static let summary = "The Copilot CLI and other agents can ask BriefBar what needs you"
    /// The plugin's command, which a line never breaks after its slash (a word joiner).
    static let command = "/\u{2060}briefbar"
}

struct AgentsPage: View {
    @ObservedObject var agents: AgentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: AgentsText.symbol)
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agents")
                        .font(.title2.weight(.semibold))
                    Text(AgentsText.summary)
                        .foregroundStyle(.secondary)
                }
            }

            switch agents.state {
            case .off:
                AgentsLeftoversRow(agents: agents)
                AgentsDescriptionBox()
                Button("Let Agents Use BriefBar") { agents.turnOn() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                Text("""
                    Turning them on adds BriefBar to the Copilot CLI's MCP servers, which the GitHub Copilot app's \
                    sessions use too. Then you can install its Copilot plugin, which adds \(AgentsText.command) \
                    there. Turning agents off, at any time, removes both.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .needsReview:
                Label("""
                    Agents are paused: since you let them use BriefBar, an update gave them more. Here's what they get now.
                    """, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                AgentsDescriptionBox()
                HStack {
                    Button("Keep Them On") { agents.turnOn() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                    Button("Turn Them Off") { agents.turnOff() }
                }
            case .on:
                VStack(alignment: .leading, spacing: 0) {
                    CopilotCLIRow(agents: agents)
                        .padding(.vertical, 10)
                    Divider()
                    CopilotPluginRow(agents: agents)
                        .padding(.vertical, 10)
                    Divider()
                    OtherAgentsRow(agents: agents)
                        .padding(.vertical, 10)
                }
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                DisclosureGroup("What agents get") {
                    AgentsDescriptionBox()
                        .padding(.top, 6)
                }
                Button("Turn Off Agents") { agents.turnOff() }
            }
        }
        .onAppear { agents.refresh() }
    }
}

/// While agents are off: BriefBar leaving the Copilot CLI, and what it couldn't remove there, with Try Again.
private struct AgentsLeftoversRow: View {
    @ObservedObject var agents: AgentsModel

    var body: some View {
        if agents.isLeaving {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Removing BriefBar from the Copilot CLI…")
                    .foregroundStyle(.secondary)
            }
        } else if let leftovers = agents.leftovers {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text("BriefBar couldn't leave the Copilot CLI")
                        .font(.headline)
                    if let server = leftovers.server {
                        Text("Its MCP server, \(CopilotMCPRegistration.name): \(server)")
                    }
                    if let plugin = leftovers.plugin {
                        Text("Its Copilot plugin: \(plugin)")
                    }
                    Text("Agents are off either way: BriefBar's tools answer that they are.")
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Try Again") { agents.removeLeftovers() }
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// What agents get, where it goes, and what they can change.
struct AgentsDescriptionBox: View {
    var body: some View {
        DescriptionBox(entries: [
            .init(title: "What agents get", symbol: "text.bubble", text: """
                What needs you, from the sources that are on: your pull requests, one at a time with its comment threads \
                word for word, your pipelines and sprint, a work item with its description, latest comments, the pull \
                requests linked to it and the Copilot sessions on those, with what Copilot recorded of their work, the work \
                BriefBar sent to Copilot, and your Copilot sessions. Never your Teams chats or your pull requests on GitHub.
                """),
            .init(title: "Where it goes", symbol: "network", text: """
                To the agent that asks, and its model, which may run in the cloud. Titles, comments and Copilot's notes \
                come word for word from whoever wrote them, and an agent may act on what they say.
                """),
            .init(title: "What agents can change", symbol: "slider.horizontal.3", text: """
                Only which pull requests BriefBar watches and which pipelines it pins. Nothing in Azure DevOps, where \
                BriefBar only reads.
                """),
        ])
    }
}

/// BriefBar among the Copilot CLI's MCP servers.
private struct CopilotCLIRow: View {
    @ObservedObject var agents: AgentsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("Copilot CLI")
                    .font(.headline)
                status
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            action
        }
    }

    @ViewBuilder
    private var status: some View {
        switch agents.registration {
        case .unknown:
            Text(" ")
        case .working:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Asking the Copilot CLI…")
                    .foregroundStyle(.secondary)
            }
        case .known(let status):
            switch status {
            case .added(enabled: true):
                Label("Added as \(CopilotMCPRegistration.name), so its agents and the GitHub Copilot app's sessions can use BriefBar.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .added(enabled: false):
                Text("Added as \(CopilotMCPRegistration.name), but turned off in the Copilot CLI: copilot mcp enable \(CopilotMCPRegistration.name) turns it on.")
                    .foregroundStyle(.secondary)
            case .addedElsewhere(let path):
                Text("Added, for the copy of BriefBar at \(UserPath.abbreviate(path)).")
                    .foregroundStyle(.secondary)
            case .absent:
                Text("Not added: its agents can't use BriefBar.")
                    .foregroundStyle(.secondary)
            case .taken:
                Text("It has a server named \(CopilotMCPRegistration.name) that isn't BriefBar, which BriefBar leaves. Copy BriefBar's command below to add it under another name.")
                    .foregroundStyle(.secondary)
            case .noCLI:
                Text("It isn't installed. Install it with brew install copilot-cli, or add BriefBar to another agent.")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text("Couldn't ask it: \(message)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        if case .known(let status) = agents.registration {
            switch status {
            case .added:
                Button("Remove") { agents.removeFromCopilotCLI() }
            case .addedElsewhere:
                Button("Use This Copy") { agents.addToCopilotCLI() }
            case .absent:
                Button("Add") { agents.addToCopilotCLI() }
            case .noCLI, .failed:
                Button("Try Again") { agents.refresh(force: true) }
            case .taken:
                EmptyView()
            }
        }
    }
}

/// BriefBar's plugin among the Copilot CLI's, which gives the GitHub Copilot app and the CLI `/briefbar`: installed
/// only when you ask.
private struct CopilotPluginRow: View {
    @ObservedObject var agents: AgentsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("Copilot plugin")
                    .font(.headline)
                Text("""
                    \(AgentsText.command), in the GitHub Copilot app and the Copilot CLI: what needs you, and pull \
                    requests handed to sessions you can follow there. Those sessions change code, and Push & Reply \
                    pushes and replies as you.
                    """)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                status
                    .fixedSize(horizontal: false, vertical: true)
                if needsTheServer {
                    Text("Its skill uses BriefBar's MCP server: add BriefBar to the Copilot CLI too.")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            action
        }
    }

    /// It's installed, but the Copilot CLI doesn't have BriefBar's MCP server, whose tools the skill uses.
    private var needsTheServer: Bool {
        guard agents.plugin == .known(.installed(enabled: true)), case .known(_) = agents.registration else {
            return false
        }
        return !agents.isInCopilotCLI
    }

    @ViewBuilder
    private var status: some View {
        switch agents.plugin {
        case .unknown:
            EmptyView()
        case .working:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Asking the Copilot CLI…")
                    .foregroundStyle(.secondary)
            }
        case .known(let status):
            switch status {
            case .installed(enabled: true):
                Label("Installed, as \(CopilotPluginRegistration.name). It updates with BriefBar.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .installed(enabled: false):
                Text("Installed, but turned off in Copilot.")
                    .foregroundStyle(.secondary)
            case .installedElsewhere(let path):
                Text("Installed, from the copy of BriefBar at \(UserPath.abbreviate(path)).")
                    .foregroundStyle(.secondary)
            case .absent:
                Text(agents.hasPlugin
                     ? "Not installed. It comes with BriefBar, and updates with it."
                     : "Not installed. This copy of BriefBar doesn't have it: BriefBar.app does.")
                    .foregroundStyle(.secondary)
            case .taken:
                Text("""
                    Copilot has a plugin marketplace named \(CopilotPluginRegistration.name) that BriefBar can't tell \
                    is its own, so it leaves it. To install BriefBar's, remove it with copilot plugin marketplace \
                    remove \(CopilotPluginRegistration.name).
                    """)
                    .foregroundStyle(.secondary)
            case .noCLI:
                Text("It needs the Copilot CLI, which isn't installed: brew install copilot-cli installs it.")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text("Couldn't ask the Copilot CLI: \(message)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        if case .known(let status) = agents.plugin {
            switch status {
            case .absent:
                if agents.hasPlugin {
                    Button("Install") { agents.installPlugin() }
                }
            case .installed(enabled: true):
                Button("Remove") { agents.removePlugin() }
            case .installed(enabled: false):
                Button("Turn On") { agents.installPlugin() }
            case .installedElsewhere:
                if agents.hasPlugin {
                    Button("Use This Copy") { agents.installPlugin() }
                } else {
                    Button("Remove") { agents.removePlugin() }
                }
            case .noCLI, .failed:
                Button("Try Again") { agents.refresh(force: true) }
            case .taken:
                EmptyView()
            }
        }
    }
}

/// Installs BriefBar in the agents' apps on this Mac, or copies the command any other agent runs.
private struct OtherAgentsRow: View {
    @ObservedObject var agents: AgentsModel

    var body: some View {
        let apps = agents.apps
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("Other agents")
                    .font(.headline)
                Text(apps.isEmpty
                     ? "Copy the command that starts BriefBar, and add it to another agent's MCP servers."
                     : "Install BriefBar in another agent on this Mac, or copy the command that starts it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if apps.isEmpty {
                Button("Copy Command", action: copyCommand)
            } else {
                Menu("Install") {
                    ForEach(apps) { app in
                        if app == .gitHubCopilot {
                            // Checked once the Copilot CLI has BriefBar: the Copilot CLI row removes it.
                            Toggle(app.name, isOn: Binding(
                                get: { agents.isInCopilotCLI },
                                set: { if $0 { agents.install(in: app) } }
                            ))
                            .disabled(!agents.canAddToCopilotCLI)
                        } else {
                            Button(app.name) { agents.install(in: app) }
                        }
                    }
                    Divider()
                    Button("Copy Command", action: copyCommand)
                }
                .fixedSize()
            }
        }
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(agents.command, forType: .string)
    }
}

/// Agents, among the sources on the General page.
struct AgentsSummaryRow: View {
    @ObservedObject var agents: AgentsModel
    var open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: AgentsText.symbol)
                .font(.title2)
                .frame(width: 30)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agents")
                    .font(.headline)
                Text(AgentsText.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch agents.state {
            case .on:
                Label("On", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Settings…", action: open)
            case .needsReview:
                Label("Paused", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Button("Review…", action: open)
            case .off:
                Button("Turn On…", action: open)
            }
        }
    }
}

/// Agents, in the Settings window's sidebar.
struct AgentsSidebarRow: View {
    @ObservedObject var agents: AgentsModel

    var body: some View {
        SidebarSourceRow(name: "Agents", symbol: AgentsText.symbol, state: agents.state)
    }
}
