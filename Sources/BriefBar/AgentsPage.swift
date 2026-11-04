import AppKit
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// Whether agents may use BriefBar (`BriefBar --mcp`), and BriefBar among the Copilot CLI's MCP servers. Agents are off
/// until you turn them on, like a source: turning them on adds BriefBar to the Copilot CLI, and turning them off
/// removes it. BriefBar's plugin for Copilot, which gives the GitHub Copilot app and the CLI `/briefbar`, is installed
/// only when you ask, once agents are on, and so is its extension for the app's sessions, with Send Prompts to Copilot
/// Sessions; turning agents off removes both too. If the CLI can't remove any of them, the page says so while agents are
/// off, and tries again when you ask. Other agents' apps, such as VS Code, get BriefBar only when you install it in
/// them, with their own install links, and keep it until you remove it there. The demo and `--render` never run the CLI
/// or open another app, and show what the CLI would say.
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
    /// BriefBar's server and plugins in the CLI: working until the last check or change asked for is done, so that an
    /// earlier one's answer isn't shown while a later one is still to come (`CopilotCLIProgress`).
    @Published private var serverProgress = CopilotCLIProgress<CopilotMCPRegistration.Status>()
    @Published private var pluginProgress = CopilotCLIProgress<CopilotPluginRegistration.Status>()
    @Published private var sessionPromptsProgress = CopilotCLIProgress<CopilotPluginRegistration.Status>()
    /// Pull Request Order's skill, which Copilot gets while both it and agents are on.
    @Published private var orderProgress = CopilotCLIProgress<CopilotPluginRegistration.Status>()
    /// What you turned Send Prompts to Copilot Sessions to, while the CLI is at it.
    @Published private var sessionPromptsAsked: Bool?
    /// What you last turned it to, which Try Again asks the CLI for again.
    private var sessionPromptsWanted: Bool?

    var registration: Registration {
        if serverProgress.isWorking { return .working }
        return serverProgress.status.map(Registration.known) ?? .unknown
    }

    var plugin: Plugin {
        if pluginProgress.isWorking { return .working }
        return pluginProgress.status.map(Plugin.known) ?? .unknown
    }

    /// BriefBar's extension for the app's sessions among the CLI's plugins: Send Prompts to Copilot Sessions.
    var sessionPrompts: Plugin {
        if sessionPromptsProgress.isWorking { return .working }
        return sessionPromptsProgress.status.map(Plugin.known) ?? .unknown
    }

    /// Pull Request Order's skill among the CLI's plugins.
    var orderSkill: Plugin {
        if orderProgress.isWorking { return .working }
        return orderProgress.status.map(Plugin.known) ?? .unknown
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
    private var sessionPromptsCheckedAt: Date?
    private var orderCheckedAt: Date?

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
    /// whether its plugins are there, which it never installs by itself; Keep Them On, after an update, leaves the CLI as
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
            refreshSessionPrompts(force: true)
            // With Pull Request Order on, which you turned on before agents.
            if isOrderOn { pullRequestOrderChanged(true) }
        } else {
            // Pull Request Order, turned on while agents waited for you to see what they get: its skill, unless BriefBar
            // added it before, which leaves it as you have it in the Copilot CLI, turned off there or not.
            if isOrderOn, !orderSkillMayBeInstalled { pullRequestOrderChanged(true) }
            refresh(force: true)
        }
    }

    /// `--mcp` refuses from now on, and BriefBar and its plugins leave the Copilot CLI. BriefBar stops sending prompts to
    /// sessions at once, as the sessions that are open keep its extension until they start again.
    func turnOff() {
        guard state != .off else { return }
        AgentAccess.turnOff(in: defaults)
        state = .off
        CopilotSessionPrompts.set(false, in: defaults)
        // As turning it off does, so that the page shows it off meanwhile, and Try Again can't turn it back on.
        sessionPromptsAsked = false
        sessionPromptsWanted = false
        Log.app.info("Turned off agents")
        change(demo: .absent) { await $0.remove() }
        changePlugin(demo: .absent) { await $0.remove() }
        changeSessionPrompts(demo: .absent) { await $0.remove() }
        changeOrderSkill(demo: .absent) { await $0.remove() }
    }

    /// Asks the Copilot CLI whether it has BriefBar and its plugins: when the page shows, unless it asked a moment ago.
    func refresh(force: Bool = false) {
        removeOwedOrderSkill()
        guard state == .on else { return }
        if registration != .working, force || checkedAt.map({ Date().timeIntervalSince($0) >= 30 }) ?? true {
            change(demo: .added(enabled: true)) { await $0.status() }
        }
        refreshPlugin(force: force)
        refreshSessionPrompts(force: force)
        refreshOrderSkill(force: force)
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
        return AgentCleanup.left(
            server: serverProgress, plugin: pluginProgress, sessionPrompts: sessionPromptsProgress, order: orderProgress
        )
    }

    /// While agents are off, BriefBar is removing itself, or its plugins, from the Copilot CLI.
    var isLeaving: Bool {
        state == .off && (registration == .working || plugin == .working || sessionPrompts == .working || orderSkill == .working)
    }

    /// Removes again what turning agents off couldn't.
    func removeLeftovers() {
        guard let leftovers else { return }
        Log.app.info("Removing what turning agents off left in the Copilot CLI")
        if leftovers.server != nil { change(demo: .absent) { await $0.remove() } }
        if leftovers.plugin != nil { changePlugin(demo: .absent) { await $0.remove() } }
        if leftovers.sessionPrompts != nil { changeSessionPrompts(demo: .absent) { await $0.remove() } }
        if leftovers.order != nil { changeOrderSkill(demo: .absent) { await $0.remove() } }
    }

    // MARK: Pull Request Order's skill

    /// Pull Request Order is on, in Settings › General.
    var isOrderOn: Bool { PullRequestOrderSetting.isOn(in: defaults) }

    /// BriefBar asked the Copilot CLI to add Pull Request Order's skill, and the CLI hasn't said since that it's gone: kept
    /// in the preferences, so that a skill a removal couldn't take away still shows after BriefBar starts again.
    static let orderSkillMayBeInstalledKey = "order.skillMayBeInstalled"

    private var orderSkillMayBeInstalled: Bool {
        get { defaults.bool(forKey: Self.orderSkillMayBeInstalledKey) }
        set {
            if newValue {
                defaults.set(true, forKey: Self.orderSkillMayBeInstalledKey)
            } else {
                defaults.removeObject(forKey: Self.orderSkillMayBeInstalledKey)
            }
        }
    }

    /// Whether the Agents page shows the skill: while Pull Request Order is on, or while the Copilot CLI may still have it
    /// without it, so that you can remove it. Until you turn Pull Request Order on, BriefBar doesn't even ask about it.
    var showsOrderSkill: Bool { isOrderOn || orderSkillMayBeInstalled }

    /// Pull Request Order turned on or off: with agents on, Copilot gets its skill, which tells the sessions that open pull
    /// requests together when to tell BriefBar their order; turned off, the skill goes. Agents turned on later add it then,
    /// and turned off remove it. A copy of BriefBar without the plugin can remove it, but not install it.
    func pullRequestOrderChanged(_ isOn: Bool) {
        if isOn {
            guard state == .on, hasPlugin else { return }
            Log.app.info("Adding Pull Request Order's skill")
            orderSkillMayBeInstalled = true
            changeOrderSkill(demo: .installed(enabled: true)) { await $0.install() }
        } else {
            guard state == .on || orderSkill != .unknown else { return }
            Log.app.info("Removing Pull Request Order's skill")
            changeOrderSkill(demo: .absent) { await $0.remove() }
        }
    }

    /// The Copilot CLI may still have Pull Request Order's skill though agents or Pull Request Order are off, as a removal
    /// that couldn't take it away before BriefBar quit leaves it: BriefBar tries again once as the Agents page shows. If it
    /// still can't, the page says so, with Try Again.
    private func removeOwedOrderSkill() {
        guard orderSkillMayBeInstalled, state == .off || !isOrderOn, orderSkill == .unknown else { return }
        Log.app.info("Removing Pull Request Order's skill, which a removal before couldn't")
        changeOrderSkill(demo: .absent) { await $0.remove() }
    }

    private func refreshOrderSkill(force: Bool) {
        guard orderSkill != .working, showsOrderSkill || orderSkill != .unknown else { return }
        if !force, let orderCheckedAt, Date().timeIntervalSince(orderCheckedAt) < 30 { return }
        var demo = CopilotPluginRegistration.Status.absent
        if case .known(let status) = orderSkill { demo = status }
        changeOrderSkill(demo: demo) { await $0.status() }
    }

    private func changeOrderSkill(
        demo: CopilotPluginRegistration.Status,
        _ action: @escaping @Sendable (CopilotPluginRegistration) async -> CopilotPluginRegistration.Status
    ) {
        guard isLive else {
            orderProgress = CopilotCLIProgress(status: demo)
            note(demo)
            return
        }
        let request = orderProgress.ask()
        withPlugin(.order, action) { [weak self] status in
            guard let self else { return }
            orderProgress.answer(request, with: status)
            orderCheckedAt = Date()
            note(status)
            Log.app.info("Pull Request Order's skill in the Copilot CLI: \(status.kind, privacy: .public)")
        }
    }

    /// Remembers whether the Copilot CLI may have the skill, from what it said of it.
    private func note(_ status: CopilotPluginRegistration.Status) {
        switch status {
        case .installed, .installedElsewhere: orderSkillMayBeInstalled = true
        case .absent, .taken: orderSkillMayBeInstalled = false
        // Without the CLI, or its answer, BriefBar can't tell whether it's gone.
        case .noCLI, .failed: break
        }
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

    // MARK: Send Prompts to Copilot Sessions

    /// It's on, as you chose and the Copilot CLI then installed it, which is what Send to Copilot goes by; while the CLI
    /// is at it, what you turned it to.
    var areSessionPromptsOn: Bool {
        if sessionPrompts == .working, let asked = sessionPromptsAsked { return asked }
        return CopilotSessionPrompts.isOn(in: defaults)
    }

    /// It's off, but the Copilot CLI still has BriefBar's extension, as when removing it failed: sessions that start
    /// run it, though BriefBar sends them nothing.
    var isSessionPromptsLeftOver: Bool {
        guard !areSessionPromptsOn, case .known(let status) = sessionPrompts else { return false }
        return Self.isOn(status)
    }

    /// You can turn it on or off: not while the CLI is at it, nor where a marketplace by BriefBar's name isn't its own,
    /// nor turn it on in a copy of BriefBar without the plugin. Such a copy can turn it off, as another copy's may be on.
    var canChangeSessionPrompts: Bool {
        canAskForSessionPrompts && (hasPlugin || areSessionPromptsOn)
    }

    /// Installs BriefBar's extension for the app's sessions, or removes it: only when you ask. Any copy of BriefBar can
    /// remove it, but only one with the plugin can install it. Turned off, BriefBar stops sending prompts to sessions at
    /// once, whatever the CLI says, as the sessions that are open keep the extension until they start again.
    func setSessionPrompts(_ isOn: Bool) {
        guard canAskForSessionPrompts, hasPlugin || !isOn else { return }
        sessionPromptsAsked = isOn
        sessionPromptsWanted = isOn
        Log.app.info("Turned \(isOn ? "on" : "off", privacy: .public) Send Prompts to Copilot Sessions")
        if isOn {
            changeSessionPrompts(demo: .installed(enabled: true), installing: true) { await $0.install() }
        } else {
            CopilotSessionPrompts.set(false, in: defaults)
            changeSessionPrompts(demo: .absent) { await $0.remove() }
        }
    }

    /// Asks the CLI again for what you last turned it to, or, when it last checked what the CLI has, checks again.
    func retrySessionPrompts() {
        if let sessionPromptsWanted {
            setSessionPrompts(sessionPromptsWanted)
        } else {
            refreshSessionPrompts(force: true)
        }
    }

    private func refreshSessionPrompts(force: Bool) {
        guard sessionPrompts != .working else { return }
        if !force, let sessionPromptsCheckedAt, Date().timeIntervalSince(sessionPromptsCheckedAt) < 30 { return }
        // Try Again then asks the CLI again, rather than redo what you asked for before, which the CLI may have undone.
        sessionPromptsWanted = nil
        // The demo has only what you did on this page.
        var demo = CopilotPluginRegistration.Status.absent
        if case .known(let status) = sessionPrompts { demo = status }
        changeSessionPrompts(demo: demo) { await $0.status() }
    }

    /// The CLI isn't at it, and a marketplace by BriefBar's name is its own, if there's one.
    private var canAskForSessionPrompts: Bool {
        switch sessionPrompts {
        case .working, .known(.taken): return false
        case .unknown, .known: return true
        }
    }

    static func isOn(_ status: CopilotPluginRegistration.Status) -> Bool {
        switch status {
        case .installed(enabled: true), .installedElsewhere: return true
        case .installed(enabled: false), .absent, .taken, .noCLI, .failed: return false
        }
    }

    /// Keeps what the CLI said, for Send to Copilot, which sends prompts to sessions only while it's on: on only once the
    /// CLI has installed it as you asked, and off once the CLI doesn't have it. A check never turns it back on, so
    /// that it stays off when removing it failed; and when the CLI couldn't say, it stays as it was.
    private func remember(sessionPrompts status: CopilotPluginRegistration.Status, installing: Bool) {
        switch status {
        case .failed, .noCLI:
            break
        case .installed(enabled: true), .installedElsewhere:
            if installing { CopilotSessionPrompts.set(true, in: defaults) }
        case .installed(enabled: false), .absent, .taken:
            CopilotSessionPrompts.set(false, in: defaults)
        }
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
        withPlugin(.skill, action) { [weak self] status in
            guard let self else { return }
            pluginProgress.answer(request, with: status)
            pluginCheckedAt = Date()
            Log.app.info("BriefBar's plugin in the Copilot CLI: \(status.kind, privacy: .public)")
        }
    }

    private func changeSessionPrompts(
        demo: CopilotPluginRegistration.Status, installing: Bool = false,
        _ action: @escaping @Sendable (CopilotPluginRegistration) async -> CopilotPluginRegistration.Status
    ) {
        guard isLive else {
            sessionPromptsProgress = CopilotCLIProgress(status: demo)
            sessionPromptsAsked = nil
            remember(sessionPrompts: demo, installing: installing)
            return
        }
        let request = sessionPromptsProgress.ask()
        withPlugin(.sessions, action) { [weak self] status in
            guard let self else { return }
            sessionPromptsProgress.answer(request, with: status)
            sessionPromptsCheckedAt = Date()
            // Only what the last one asked for found counts, as the page shows.
            if !sessionPromptsProgress.isWorking {
                sessionPromptsAsked = nil
                remember(sessionPrompts: status, installing: installing)
            }
            Log.app.info("BriefBar's extension for sessions in the Copilot CLI: \(status.kind, privacy: .public)")
        }
    }

    /// Runs `action` on one of BriefBar's plugins, with the Copilot CLI once it's found, then `answer` with what it found.
    private func withPlugin(
        _ plugin: CopilotPluginRegistration.Plugin,
        _ action: @escaping @Sendable (CopilotPluginRegistration) async -> CopilotPluginRegistration.Status,
        answer: @escaping @MainActor @Sendable (CopilotPluginRegistration.Status) -> Void
    ) {
        let marketplace = pluginMarketplace
        withCLI { cli in
            let status: CopilotPluginRegistration.Status
            if let cli {
                status = await action(CopilotPluginRegistration(
                    cli: cli, marketplace: marketplace, plugin: plugin, bundleIdentifier: AppIdentity.bundleIdentifier
                ))
            } else {
                status = .noCLI
            }
            answer(status)
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

    /// For `--render`: agents on, BriefBar added to the Copilot CLI and its plugins not installed yet, or the extension
    /// for the app's sessions installed, or as they were, without saving any of it: `--render` keeps the preferences
    /// in memory.
    func useForRendering(on: Bool, sessionPrompts: Bool = false) {
        state = on ? .on : AgentAccess.state(in: defaults)
        serverProgress = CopilotCLIProgress(status: on ? .added(enabled: true) : nil)
        pluginProgress = CopilotCLIProgress(status: on ? .absent : nil)
        sessionPromptsProgress = CopilotCLIProgress(status: on ? (sessionPrompts ? .installed(enabled: true) : .absent) : nil)
        if on { CopilotSessionPrompts.set(sessionPrompts, in: defaults) }
    }

    /// For `--render`: agents just turned off, and the Copilot CLI couldn't remove the plugin, without saving either.
    func useForRenderingLeftovers() {
        state = .off
        serverProgress = CopilotCLIProgress(status: .absent)
        pluginProgress = CopilotCLIProgress(
            status: .failed("Couldn't save the settings: another Copilot process is writing them.")
        )
        sessionPromptsProgress = CopilotCLIProgress(status: .absent)
        CopilotSessionPrompts.set(false, in: defaults)
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
                    .font(style: .largeTitle)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agents")
                        .font(style: .title2, weight: .semibold)
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
                    there, and turn on \(CopilotSessionPrompts.title). Turning agents off, at any time, removes them \
                    all.
                    """)
                    .font(style: .callout)
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
                    SessionPromptsRow(agents: agents)
                        .padding(.vertical, 10)
                    if agents.showsOrderSkill {
                        Divider()
                        OrderSkillRow(agents: agents)
                            .padding(.vertical, 10)
                    }
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
                        .font(style: .headline)
                    if let server = leftovers.server {
                        Text("Its MCP server, \(CopilotMCPRegistration.name): \(server)")
                    }
                    if let plugin = leftovers.plugin {
                        Text("Its Copilot plugin: \(plugin)")
                    }
                    if let sessionPrompts = leftovers.sessionPrompts {
                        Text("Its extension for \(CopilotSessionPrompts.title): \(sessionPrompts)")
                    }
                    if let order = leftovers.order {
                        Text("Its skill for \(PullRequestOrderSettingView.title): \(order)")
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
                word for word and, with Send Work to Copilot on, the Copilot session BriefBar sends its work to, your \
                pipelines and sprint, a work item with its description, latest comments, the pull requests linked to it and \
                the Copilot sessions on those, with what Copilot recorded of their work, the work BriefBar sent to Copilot, \
                and your Copilot sessions. With Pull Request Order on, the orders sessions told BriefBar their pull \
                requests merge in. Never your Teams chats or your pull requests on GitHub.
                """),
            .init(title: "Where it goes", symbol: "network", text: """
                To the agent that asks, and its model, which may run in the cloud. Titles, comments and Copilot's notes \
                come word for word from whoever wrote them, and an agent may act on what they say.
                """),
            .init(title: "What agents can change", symbol: "slider.horizontal.3", text: """
                Only which pull requests BriefBar watches and which pipelines it pins and, with Pull Request Order on, the \
                orders it keeps. Nothing in Azure DevOps or on GitHub: BriefBar gives agents no way to change them.
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
                    .font(style: .headline)
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
                    .font(style: .headline)
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

/// Send Prompts to Copilot Sessions: BriefBar's extension for the GitHub Copilot app's sessions, among the Copilot CLI's
/// plugins, installed only when you turn it on, and removed when you turn it off.
private struct SessionPromptsRow: View {
    @ObservedObject var agents: AgentsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "paperplane")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(CopilotSessionPrompts.title)
                    .font(style: .headline)
                Text("""
                    Send to Copilot can then send a prompt to one of the GitHub Copilot app's sessions itself, or fork \
                    the session and send it to the fork, when you ask, instead of copying it for you to paste. It adds \
                    a small extension to each session the app opens: a process of about 46\u{00A0}MB that does nothing \
                    else.
                    """)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                status
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(CopilotSessionPrompts.title, isOn: Binding(
                get: { agents.areSessionPromptsOn },
                set: { agents.setSessionPrompts($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(!agents.canChangeSessionPrompts)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch agents.sessionPrompts {
        case .unknown:
            if !agents.hasPlugin {
                Text("This copy of BriefBar doesn't have it: BriefBar.app does.")
                    .foregroundStyle(.secondary)
            }
        case .working:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Asking the Copilot CLI…")
                    .foregroundStyle(.secondary)
            }
        case .known(let status):
            switch status {
            case .installed(enabled: true), .installedElsewhere:
                if agents.isSessionPromptsLeftOver {
                    HStack(alignment: .firstTextBaseline) {
                        Text("""
                            Off, but the Copilot CLI still has it, so sessions that start run it, though BriefBar sends \
                            them nothing.
                            """)
                            .foregroundStyle(.secondary)
                        Button("Remove") { agents.setSessionPrompts(false) }
                    }
                } else if case .installedElsewhere(let path) = status {
                    Text(agents.hasPlugin
                         ? "On, from the copy of BriefBar at \(UserPath.abbreviate(path)). Turn it off and on to use this copy."
                         : "On, from the copy of BriefBar at \(UserPath.abbreviate(path)).")
                        .foregroundStyle(.secondary)
                } else {
                    Label("""
                        On, as \(CopilotPluginRegistration.Plugin.sessions.rawValue). Sessions get it as they start: \
                        one that's open now, once it starts again.
                        """, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case .installed(enabled: false), .absent:
                if !agents.hasPlugin {
                    Text("This copy of BriefBar doesn't have it: BriefBar.app does.")
                        .foregroundStyle(.secondary)
                }
            case .taken:
                Text("""
                    Copilot has a plugin marketplace named \(CopilotPluginRegistration.name) that BriefBar can't tell \
                    is its own, so it leaves it. To turn this on, remove it with copilot plugin marketplace remove \
                    \(CopilotPluginRegistration.name).
                    """)
                    .foregroundStyle(.secondary)
            case .noCLI:
                Text("It needs the Copilot CLI, which isn't installed: brew install copilot-cli installs it.")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                HStack(alignment: .firstTextBaseline) {
                    Text("Couldn't ask the Copilot CLI: \(message)")
                        .foregroundStyle(.secondary)
                    Button("Try Again") { agents.retrySessionPrompts() }
                }
            }
        }
    }
}

/// Pull Request Order's skill in the Copilot CLI, which comes and goes with Pull Request Order, in Settings › General.
private struct OrderSkillRow: View {
    @ObservedObject var agents: AgentsModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(PullRequestOrderSettingView.title)'s skill")
                    .font(style: .headline)
                status
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private static let installed = "On, as \(CopilotPluginRegistration.Plugin.order.rawValue). Sessions get it as they start: "
        + "it tells the ones that open pull requests together when to tell BriefBar their order."

    @ViewBuilder
    private var status: some View {
        switch agents.orderSkill {
        case .unknown:
            Text(agents.hasPlugin
                 ? "It comes with \(PullRequestOrderSettingView.title), in Settings › General."
                 : "This copy of BriefBar doesn't have it: BriefBar.app does.")
                .foregroundStyle(.secondary)
        case .working:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Asking the Copilot CLI…")
                    .foregroundStyle(.secondary)
            }
        case .known(let status):
            switch status {
            case .installed where !agents.isOrderOn, .installedElsewhere where !agents.isOrderOn:
                HStack(alignment: .firstTextBaseline) {
                    Text("Still in the Copilot CLI, though \(PullRequestOrderSettingView.title) is off.")
                        .foregroundStyle(.secondary)
                    Button("Remove") { agents.pullRequestOrderChanged(false) }
                }
            case .installed(enabled: true), .installedElsewhere:
                Label(Self.installed, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .installed(enabled: false), .absent, .taken, .noCLI:
                HStack(alignment: .firstTextBaseline) {
                    Text(agents.isOrderOn ? "Not in the Copilot CLI." : "Off, with \(PullRequestOrderSettingView.title).")
                        .foregroundStyle(.secondary)
                    if agents.isOrderOn, agents.hasPlugin {
                        Button("Add") { agents.pullRequestOrderChanged(true) }
                    }
                }
            case .failed(let message):
                HStack(alignment: .firstTextBaseline) {
                    Text("Couldn't ask the Copilot CLI: \(message)")
                        .foregroundStyle(.secondary)
                    Button("Try Again") { agents.pullRequestOrderChanged(agents.isOrderOn) }
                }
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
                    .font(style: .headline)
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
                .font(style: .title2)
                .frame(width: 30)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agents")
                    .font(style: .headline)
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
