import AppKit
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// Whether agents may use BriefBar (`BriefBar --mcp`), and BriefBar among the Copilot CLI's MCP servers. Agents are off
/// until you turn them on, like a source: turning them on adds BriefBar to the Copilot CLI, and turning them off
/// removes it. The demo and `--render` never run the CLI, and show what it would say.
@MainActor
final class AgentsModel: ObservableObject {
    /// BriefBar among the Copilot CLI's servers, as the CLI last said.
    enum Registration: Equatable {
        case unknown
        /// Asking the CLI, or changing what it has.
        case working
        case known(CopilotMCPRegistration.Status)
    }

    @Published private(set) var state: SourceState
    @Published private(set) var registration: Registration = .unknown

    private let defaults: UserDefaults
    private let isLive: Bool
    /// BriefBar's binary, which agents start with `--mcp`.
    let executable: String
    /// The CLI, once found with your login shell's environment.
    private var cli: CopilotMCPRegistration?
    /// The last change, which the next one waits for, so they reach the CLI in the order you made them.
    private var last: Task<Void, Never>?
    private var checkedAt: Date?

    init(defaults: UserDefaults, isLive: Bool, executable: String = Bundle.main.executablePath ?? AppIdentity.name) {
        self.defaults = defaults
        self.isLive = isLive
        self.executable = executable
        state = AgentAccess.state(in: defaults)
    }

    /// What an agent runs, to show and copy.
    var command: String { "\(Self.quoted(executable)) --mcp" }

    /// With your consent to what agents get now. The first time, BriefBar adds itself to the Copilot CLI too; Keep Them
    /// On, after an update, leaves the CLI as it was.
    func turnOn() {
        guard state != .on else { return }
        let wasOff = state == .off
        AgentAccess.turnOn(in: defaults)
        state = .on
        Log.app.info("Turned on agents")
        if wasOff {
            change(demo: .added(enabled: true)) { await $0.add() }
        } else {
            refresh(force: true)
        }
    }

    /// `--mcp` refuses from now on, and BriefBar leaves the Copilot CLI.
    func turnOff() {
        guard state != .off else { return }
        AgentAccess.turnOff(in: defaults)
        state = .off
        Log.app.info("Turned off agents")
        change(demo: .absent) { await $0.remove() }
    }

    /// Asks the Copilot CLI whether it has BriefBar: when the page shows, unless it asked a moment ago.
    func refresh(force: Bool = false) {
        guard state == .on, registration != .working else { return }
        if !force, let checkedAt, Date().timeIntervalSince(checkedAt) < 30 { return }
        change(demo: .added(enabled: true)) { await $0.status() }
    }

    func addToCopilotCLI() {
        change(demo: .added(enabled: true)) { await $0.add() }
    }

    func removeFromCopilotCLI() {
        change(demo: .absent) { await $0.remove() }
    }

    private func change(
        demo: CopilotMCPRegistration.Status, _ action: @escaping @Sendable (CopilotMCPRegistration) async -> CopilotMCPRegistration.Status
    ) {
        guard isLive else {
            registration = .known(demo)
            return
        }
        registration = .working
        let previous = last
        let executable = executable
        last = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if cli == nil { cli = await CopilotMCPRegistration.find(executable: executable) }
            let status: CopilotMCPRegistration.Status
            if let cli {
                status = await action(cli)
            } else {
                status = .noCLI
            }
            registration = .known(status)
            checkedAt = Date()
            Log.app.info("Agents in the Copilot CLI: \(status.kind, privacy: .public)")
        }
    }

    /// For `--render`: agents on, and BriefBar added to the Copilot CLI, or as they were, without saving either.
    func useForRendering(on: Bool) {
        state = on ? .on : AgentAccess.state(in: defaults)
        registration = on ? .known(.added(enabled: true)) : .unknown
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

// MARK: - The page

enum AgentsText {
    static let symbol = "sparkles"
    static let summary = "The Copilot CLI and other agents can ask BriefBar what needs you"
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
                AgentsDescriptionBox()
                Button("Let Agents Use BriefBar") { agents.turnOn() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                Text("""
                    Turning them on adds BriefBar to the Copilot CLI's MCP servers, which the GitHub Copilot app's \
                    sessions use too. Turning them off, at any time, removes it.
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
                    OtherAgentsRow(command: agents.command)
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

/// What agents get, where it goes, and what they can change.
struct AgentsDescriptionBox: View {
    var body: some View {
        DescriptionBox(entries: [
            .init(title: "What agents get", symbol: "text.bubble", text: """
                What needs you, from the sources that are on: your pull requests, one at a time with its comment threads \
                word for word, your pipelines and sprint, the work BriefBar sent to Copilot, and your Copilot sessions. \
                Never your Teams chats.
                """),
            .init(title: "Where it goes", symbol: "network", text: """
                To the agent that asks, and its model, which may run in the cloud. Titles and comments come word for word \
                from whoever wrote them, and an agent may act on what they say.
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
                Text("It has a server named \(CopilotMCPRegistration.name) that isn't BriefBar, which BriefBar leaves. Add BriefBar under another name, with the command below.")
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

/// The command any other agent runs.
private struct OtherAgentsRow: View {
    let command: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("Other agents")
                    .font(.headline)
                Text("Add BriefBar as a local MCP server, over standard input and output, that runs:")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
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
