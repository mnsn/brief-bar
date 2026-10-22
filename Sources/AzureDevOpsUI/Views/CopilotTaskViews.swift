import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

extension RunPhase {
    var symbol: String {
        switch self {
        case .preparing: return "hourglass"
        case .working: return "arrow.triangle.2.circlepath"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle"
        }
    }

    var color: Color {
        switch self {
        case .preparing, .stopped: return .secondary
        case .working: return .blue
        case .finished: return .green
        case .failed: return .orange
        }
    }

    var title: String {
        switch self {
        case .preparing: return "Getting Ready"
        case .working: return "Working"
        case .finished: return "Done"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}

extension CopilotTaskEntry {
    /// "Opened a pull request", "Working for 12 min: Build the solution", "Failed: …".
    func sentence(now: Date) -> String {
        let since = status.since ?? startedAt
        switch status.phase {
        case .preparing: return "Getting its worktree ready"
        case .working: return "Working for \(Elapsed.short(since: since, now: now))" + (status.detail.map { ": \($0)" } ?? "")
        case .finished: return pullRequest != nil ? "Opened a pull request" : "Finished, without a pull request"
        case .failed: return "Failed" + (CopilotTasksStore.firstLine(status.detail).map { ": \($0)" } ?? "")
        case .stopped: return "Stopped before it finished"
        }
    }
}

/// On a story's header: a button that sends it to Copilot, shown while you point at its card; or, once it's sent, how
/// it stands, with what you can do about it.
struct CopilotTaskControl: View {
    let item: WorkItem
    var isHovered: Bool

    @EnvironmentObject private var copilot: CopilotTasksStore

    var body: some View {
        if copilot.isOn {
            if let entry = copilot.latest(for: item) {
                CopilotRunBadge(entry: entry)
            } else {
                CopilotSendButton(item: item)
                    .opacity(isHovered ? 1 : 0)
            }
        }
    }
}

/// Opens the composer for a work item.
struct CopilotSendButton: View {
    let item: WorkItem

    @EnvironmentObject private var copilot: CopilotTasksStore

    var body: some View {
        Button {
            copilot.compose(item)
        } label: {
            Image(systemName: "paperplane")
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Send to Copilot…")
        .accessibilityLabel("Send to Copilot")
    }
}

/// How a send stands, as a small capsule that opens its menu.
struct CopilotRunBadge: View {
    let entry: CopilotTaskEntry
    var compact = false

    @EnvironmentObject private var copilot: CopilotTasksStore

    var body: some View {
        let phase = entry.status.phase
        Menu {
            CopilotRunMenuItems(entry: entry)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: phase == .finished && entry.pullRequest != nil ? "arrow.triangle.pull" : phase.symbol)
                if !compact {
                    Text(phase == .finished && entry.pullRequest != nil ? "PR" : phase.title)
                }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(phase.color)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(phase.color.opacity(0.14)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Copilot, with \(entry.options.title): \(entry.sentence(now: Date()))")
    }
}

/// What you can do with a send: open its pull request, go on with it in Terminal, look at its worktree, stop it, or
/// clear it.
struct CopilotRunMenuItems: View {
    let entry: CopilotTaskEntry

    @EnvironmentObject private var copilot: CopilotTasksStore

    var body: some View {
        let phase = entry.status.phase
        Text("\(entry.sentence(now: Date())) · \(entry.options.title)")
        if entry.pullRequest != nil {
            Button("Open Pull Request") { copilot.openPullRequest(entry) }
        }
        Button("Open Work Item") { copilot.openWorkItem(entry) }
        if entry.run != nil {
            Divider()
            Button("Continue in Terminal") { copilot.continueInTerminal(entry) }
                .disabled(phase.isActive)
            Button("Show Worktree in Finder") { copilot.showWorktree(entry) }
            Button("Show What Copilot Printed") { copilot.showOutput(entry) }
                .disabled(phase.isActive)
        }
        Divider()
        if phase == .working {
            Button("Stop") { copilot.stop(entry) }
        } else if !phase.isActive {
            if entry.run != nil {
                Button("Remove Worktree…") { copilot.removeWorktree(entry) }
            }
            Button("Clear") { copilot.clear(entry) }
        }
    }
}

/// A work item's context menu: send it to Copilot, after checking the prompt or right away with either model.
struct CopilotSendMenuItems: View {
    let item: WorkItem

    @EnvironmentObject private var copilot: CopilotTasksStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        if copilot.isOn {
            Button("Send to Copilot…") { copilot.compose(item) }
            Button("Send with \(settings.copilotOptions.title)") { copilot.quickSend(item, options: settings.copilotOptions) }
            if settings.copilotQuickOptions != settings.copilotOptions {
                Button("Send with \(settings.copilotQuickOptions.title)") { copilot.quickSend(item, options: settings.copilotQuickOptions) }
            }
            if let entry = copilot.latest(for: item) {
                Menu("Copilot's Last Send") {
                    CopilotRunMenuItems(entry: entry)
                }
            }
        }
    }
}

/// Every work item sent to Copilot, in the Sprint page's header: those that left the sprint too.
struct CopilotRunsMenu: View {
    @EnvironmentObject private var copilot: CopilotTasksStore

    var body: some View {
        let entries = copilot.entries
        if copilot.isOn, !entries.isEmpty {
            Menu {
                ForEach(entries) { entry in
                    Menu(title(entry)) {
                        CopilotRunMenuItems(entry: entry)
                    }
                }
                Divider()
                Button("Clear Ended") { copilot.clearEnded() }
                    .disabled(!entries.contains { !$0.status.phase.isActive })
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "paperplane")
                    if copilot.activeCount > 0 {
                        Text("\(copilot.activeCount)").monospacedDigit()
                    }
                }
            }
            .menuStyle(.button)
            .glassButtonStyle()
            .fixedSize()
            .help(copilot.activeCount > 0
                ? "Copilot is working on \(copilot.activeCount) of the work items you sent it"
                : "The work items you sent to Copilot")
            .accessibilityLabel("Copilot")
        }
    }

    private func title(_ entry: CopilotTaskEntry) -> String {
        let name = copilot.title(entry.workItem).map { "\(entry.workItem.id): \($0)" } ?? "Work item \(entry.workItem.id)"
        return "\(name) · \(entry.status.phase == .finished && entry.pullRequest != nil ? "Pull Request" : entry.status.phase.title)"
    }
}

/// Send Work to Copilot, off by default: Copilot then changes code and opens pull requests, as you. On Azure DevOps'
/// page in Settings, it says what it does and has its options; in a menu, it opens that page until it's on.
struct CopilotSetting: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var services: AppServices
    @Environment(\.inSettingsForm) private var inSettingsForm

    static let title = "Send Work to Copilot"
    static let explanation = """
        Adds a button to the sprint's work items that sends one to the Copilot CLI on this Mac, with a prompt you can \
        change and the model you choose. Copilot works on its own, in a new worktree of the repository you pick, with \
        your sign-in, tools, MCP servers and instructions, then pushes a branch and opens a pull request, as you. \
        BriefBar starts it only when you send something, and follows it from Copilot's own log of the session.
        """

    var body: some View {
        if inSettingsForm {
            Section {
                Toggle(isOn: $settings.copilotEnabled) {
                    Text(Self.title)
                    Text(Self.explanation)
                }
                if settings.copilotEnabled {
                    CopilotOptionsForm()
                }
            }
        } else if settings.copilotEnabled {
            Toggle(Self.title, isOn: $settings.copilotEnabled)
        } else {
            Button(Self.title + "…") { services.openSettings(.source(.azureDevOps)) }
        }
    }
}

/// The models, the prompt and where worktrees go, in Settings.
private struct CopilotOptionsForm: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        LabeledContent("Model") {
            HStack(spacing: 8) {
                CopilotModelMenu(model: $settings.copilotOptions.model)
                CopilotEffortPicker(effort: $settings.copilotOptions.effort)
            }
        }
        LabeledContent("Model for Easy Work") {
            HStack(spacing: 8) {
                CopilotModelMenu(model: $settings.copilotQuickOptions.model)
                CopilotEffortPicker(effort: $settings.copilotQuickOptions.effort)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Prompt")
                Spacer()
                Button("Reset") { settings.copilotPrompt = nil }
                    .disabled(settings.copilotPrompt == nil)
            }
            TextEditor(text: Binding(
                get: { settings.copilotPromptTemplate },
                set: { settings.copilotPrompt = $0 == PromptTemplate.standard ? nil : $0 }
            ))
            .font(.system(size: 12))
            .frame(height: 190)
            Text("{id}, {type}, {title}, {url}, {organization} and {project} become the work item's; {baseBranch}, the branch its worktree starts from.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        LabeledContent("Worktrees") {
            HStack(spacing: 8) {
                Text(settings.copilotWorktreesFolder.map { UserPath.abbreviate($0) } ?? "In copilot-worktrees, next to each repository")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…", action: chooseFolder)
                if settings.copilotWorktreesFolder != nil {
                    Button("Reset") { settings.copilotWorktreesFolder = nil }
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Copilot's worktrees go, each in a folder named after its repository."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.copilotWorktreesFolder = url.path
    }
}
