import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

// What a work item on the Sprint page offers a click away: its Copilot sessions and its pull requests, to open
// (`WorkItemShortcuts`), and, with Make Changes in Azure DevOps on, the states it can be put in (`StateChanges`): in its
// menus, from its state, and in its details; and on its card on My Work's Board, in its menu and VoiceOver's actions, and
// on its node on the Map, from its state, and in its menu and VoiceOver's actions where the Board has no card for it.

/// A work item's menus' items for what it opens: Open in Copilot, for its Copilot session, or Continue in Terminal, for a
/// task BriefBar runs with the Copilot CLI (`SessionOpening`), or, with two or more, a menu of them; and Show Pull Request,
/// for its pull request, over its details where there's somewhere (`itemNavigation`), or, with two or more, a menu of them.
/// Nothing for what it has none of: without Show Links, only the tasks you sent it to Copilot.
struct WorkItemOpenItems: View {
    let item: WorkItem

    @EnvironmentObject private var services: AppServices

    var body: some View {
        Items(item: item, links: services.links)
    }

    private struct Items: View {
        let item: WorkItem
        @ObservedObject var links: Links

        @EnvironmentObject private var copilot: CopilotTasksStore
        @Environment(\.itemNavigation) private var navigation

        var body: some View {
            let shortcuts = WorkItemShortcuts.of(item, links: links, copilot: copilot)
            if shortcuts.sessions.count == 1, let choice = shortcuts.sessions.first {
                let opening = SessionOpening.of(choice, links: links, copilot: copilot)
                Button(opening.title) { opening.perform() }
                    .disabled(!opening.isEnabled)
            } else if !shortcuts.sessions.isEmpty {
                Menu("Open in Copilot") {
                    ForEach(shortcuts.sessions) { choice in
                        let opening = SessionOpening.of(choice, links: links, copilot: copilot)
                        Button(WorkItemShortcuts.title(of: choice, links: links, copilot: copilot)) { opening.perform() }
                            .disabled(!opening.isEnabled)
                    }
                }
            }
            if shortcuts.pullRequests.count == 1, let pullRequest = shortcuts.pullRequests.first {
                Button("Show Pull Request \(pullRequest.label)") { WorkItemShortcuts.show(pullRequest, navigation: navigation) }
            } else if !shortcuts.pullRequests.isEmpty {
                Menu("Show Pull Request") {
                    ForEach(shortcuts.pullRequests, id: \.ref) { pullRequest in
                        Button(WorkItemShortcuts.title(of: pullRequest)) { WorkItemShortcuts.show(pullRequest, navigation: navigation) }
                    }
                }
            }
        }
    }
}

/// A work item's menus' items for its state, with Make Changes in Azure DevOps on: State, a menu of those it can be put
/// in, its own checked; and Undo, while it's the one whose state you changed last.
struct StateMenuItems: View {
    let item: WorkItem

    @EnvironmentObject private var states: StateChanges

    var body: some View {
        let choices = states.choices(for: item)
        if !choices.isEmpty {
            Divider()
            Menu("State") {
                StateChoices(item: item, choices: choices)
            }
        }
        if let undo = states.undoable, undo.key == item.key {
            Button(StateChangeText.undo(undo)) { Task { await states.undo() } }
                .disabled(states.isBusy)
        }
    }
}

/// The states a work item can be put in, as menu items, its own checked: choosing another changes it, as you.
struct StateChoices: View {
    let item: WorkItem
    let choices: [WorkItemState]

    @EnvironmentObject private var states: StateChanges

    var body: some View {
        ForEach(choices, id: \.name) { choice in
            Button {
                Task { await states.change(item, to: choice.name) }
            } label: {
                CheckedMenuLabel(title: choice.name, isChecked: StateChanges.isSame(choice.name, item.state))
            }
            .disabled(states.isBusy)
        }
    }
}

/// A work item's states as VoiceOver's actions, on a card VoiceOver reads as one, as on My Work's Board, with Make Changes in
/// Azure DevOps on: Change State to each it can be put in but its own, but while a change is on its way, which they couldn't
/// make (`StateChanges.actionChoices(for:)`); and Undo, while it's the one whose state you changed last.
struct StateActions: View {
    let item: WorkItem

    @EnvironmentObject private var states: StateChanges

    var body: some View {
        ForEach(states.actionChoices(for: item), id: \.name) { choice in
            Button("Change State to \(choice.name)") { Task { await states.change(item, to: choice.name) } }
        }
        if let undo = states.undoable, undo.key == item.key {
            Button(StateChangeText.undo(undo)) { Task { await states.undo() } }
        }
    }
}

/// A task's state, at the start of its line: with Make Changes in Azure DevOps on, a menu of the states it can be put in;
/// else its symbol, which shows its details, as the rest of its line does. On My Work's Map, a work item's node starts with it.
struct StateSymbol: View {
    let item: WorkItem
    var size: CGFloat = 13
    let open: () -> Void

    @EnvironmentObject private var states: StateChanges
    @Environment(\.textScale) private var textScale

    var body: some View {
        let choices = states.choices(for: item)
        let symbol = Image(systemName: item.stateSymbol)
            .font(size: size, weight: .medium)
            .foregroundStyle(item.stateColor)
            .frame(width: (size + 3) * textScale)
            .contentShape(Rectangle())
        if choices.isEmpty {
            symbol
                .onTapGesture(perform: open)
                .help(StateChangeText.help(item, canChange: false, needsSetting: states.needsSetting(item)))
                // Its line says its state.
                .accessibilityHidden(true)
        } else {
            Menu {
                StateChoices(item: item, choices: choices)
            } label: {
                symbol
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(StateChangeText.help(item, canChange: true, needsSetting: false))
            .accessibilityLabel("State: \(item.state)")
            .accessibilityHint("Changes its state")
        }
    }
}

/// A work item's state as a chip, on its card or in its details: with Make Changes in Azure DevOps on, a menu of the states
/// it can be put in.
struct StateChip: View {
    let item: WorkItem
    var symbol: String? = nil
    var fitsWidth = false

    @EnvironmentObject private var states: StateChanges

    var body: some View {
        let choices = states.choices(for: item)
        if choices.isEmpty {
            let chip = Chip(
                text: item.state, color: item.stateColor, textColor: item.stateTextColor, symbol: symbol, fitsWidth: fitsWidth
            )
            if states.needsSetting(item) {
                chip.help(StateChangeText.help(item, canChange: false, needsSetting: true))
            } else {
                chip
            }
        } else {
            Menu {
                StateChoices(item: item, choices: choices)
            } label: {
                Chip(
                    text: item.state, color: item.stateColor, textColor: item.stateTextColor, symbol: symbol,
                    fitsWidth: fitsWidth, isMenu: true
                )
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: !fitsWidth, vertical: true)
            .help(StateChangeText.help(item, canChange: true, needsSetting: false))
            .accessibilityLabel("State: \(item.state)")
            .accessibilityHint("Changes its state")
        }
    }
}

/// Beside Open in Azure DevOps, in a work item's details: Open in Copilot, for its Copilot session, or Continue in Terminal,
/// for a task BriefBar runs with the Copilot CLI, or, with two or more, a menu of them; and its pull request, shown over the
/// details, or, with two or more, a menu of them. Each its symbol alone when they're `compact`.
struct WorkItemOpenButtons: View {
    let item: WorkItem
    var compact = false

    @EnvironmentObject private var services: AppServices

    var body: some View {
        Buttons(item: item, compact: compact, links: services.links)
    }

    private struct Buttons: View {
        let item: WorkItem
        let compact: Bool
        @ObservedObject var links: Links

        @EnvironmentObject private var copilot: CopilotTasksStore
        @Environment(\.itemNavigation) private var navigation

        var body: some View {
            let shortcuts = WorkItemShortcuts.of(item, links: links, copilot: copilot)
            if shortcuts.sessions.count == 1, let choice = shortcuts.sessions.first {
                let opening = SessionOpening.of(choice, links: links, copilot: copilot)
                Button {
                    opening.perform()
                } label: {
                    ControlLabel(compact ? nil : opening.title, systemImage: Self.symbol(opening.way))
                }
                .glassButtonStyle()
                .disabled(!opening.isEnabled)
                .help(Self.help(choice, opening))
                .accessibilityLabel(opening.title)
            } else if !shortcuts.sessions.isEmpty {
                Menu {
                    ForEach(shortcuts.sessions) { choice in
                        let opening = SessionOpening.of(choice, links: links, copilot: copilot)
                        Button(WorkItemShortcuts.title(of: choice, links: links, copilot: copilot)) { opening.perform() }
                            .disabled(!opening.isEnabled)
                    }
                } label: {
                    ControlLabel(compact ? nil : "Open in Copilot", systemImage: Self.symbol(.copilot))
                }
                .menuStyle(.button)
                .glassButtonStyle()
                .fixedSize()
                .help("Its \(shortcuts.sessions.count) Copilot sessions: choose one to open")
                .accessibilityLabel("Open in Copilot")
            }
            if shortcuts.pullRequests.count == 1, let pullRequest = shortcuts.pullRequests.first {
                Button {
                    WorkItemShortcuts.show(pullRequest, navigation: navigation)
                } label: {
                    ControlLabel(compact ? nil : "Pull Request \(pullRequest.label)", systemImage: "arrow.triangle.pull")
                }
                .glassButtonStyle()
                .help("Shows \(WorkItemShortcuts.title(of: pullRequest)) over these details")
                .accessibilityLabel("Show Pull Request \(pullRequest.label)")
            } else if !shortcuts.pullRequests.isEmpty {
                Menu {
                    ForEach(shortcuts.pullRequests, id: \.ref) { pullRequest in
                        Button(WorkItemShortcuts.title(of: pullRequest)) { WorkItemShortcuts.show(pullRequest, navigation: navigation) }
                    }
                } label: {
                    ControlLabel(compact ? nil : "Pull Requests", systemImage: "arrow.triangle.pull")
                }
                .menuStyle(.button)
                .glassButtonStyle()
                .fixedSize()
                .help("Its \(shortcuts.pullRequests.count) pull requests: choose one to show over these details")
                .accessibilityLabel("Show Pull Request")
            }
        }

        /// A session's symbol, which isn't Open in Azure DevOps' beside it: Copilot's, or Terminal's for a task BriefBar runs
        /// with the Copilot CLI.
        static func symbol(_ way: SessionOpening.Way) -> String {
            way == .terminal ? "terminal" : "waveform.path.ecg"
        }

        static func help(_ choice: SessionChoice, _ opening: SessionOpening) -> String {
            let name = "‘\(PullRequestSession.name(of: choice))’"
            switch (opening.way, opening.isEnabled) {
            case (.copilot, true): return "Opens \(name), its Copilot session, in the Copilot app"
            case (.terminal, true): return "Goes on with \(name), its Copilot session, in Terminal, in its worktree"
            case (.copilot, false): return "Copilot is working in \(name), or in its checkout, for a task BriefBar sent: open it once that's done"
            case (.terminal, false): return "Go on with \(name) in Terminal once Copilot is done working in it"
            }
        }
    }
}

/// What became of changing a work item's state, under the Sprint page's header, and My Work's, where it stays as the page
/// scrolls: while it's on its way; once it changed, with Undo, while it's in that state; why it didn't, with Try Again where
/// it may help; each with ✕, but while it's on its way.
struct StateChangeLine: View {
    @ObservedObject var changes: StateChanges

    var body: some View {
        if let line = changes.line {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                switch line {
                case .sending(let change):
                    ProgressView().controlSize(.small)
                    words(StateChangeText.sending(change))
                case .changed(let change):
                    symbol("checkmark.circle")
                    words(StateChangeText.changed(change))
                    if changes.undoable == change {
                        Button("Undo") { Task { await changes.undo() } }
                            .buttonStyle(.borderless)
                            .help("Change \(change.name) back to \(change.from)")
                    }
                    dismiss
                case .failed(let change, let problem):
                    symbol("exclamationmark.triangle")
                    words(StateChangeText.failed(change) + " " + problem.sentence(.setState))
                    if StateChanges.retries(problem) {
                        Button("Try Again") { Task { await changes.retry() } }
                            .buttonStyle(.borderless)
                    }
                    dismiss
                }
            }
            .font(size: 12)
            .padding(.horizontal, 4)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func words(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var dismiss: some View {
        Button {
            changes.dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(size: 9, weight: .bold)
        }
        .buttonStyle(.borderless)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }
}
