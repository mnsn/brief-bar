import AzureDevOpsCore
import BriefBarCore
import BriefBarUI
import CopilotTasks
import SwiftUI

/// Under a pull request's heading, in its details and on its page over a work item's: ✨ Summarize, then, a click away,
/// what you'd otherwise find in menus. Its Copilot session, opened in Copilot, or, for a task BriefBar runs with the
/// Copilot CLI, gone on with in Terminal, as its line's ⌄ does it; the folder that session works in, opened in the editor
/// or terminal you opened one in last, ▾ choosing another, or in the Finder; and, while the details are beside the list
/// on the Pull Requests page, Fill the Page, for the details to cover it, to review the pull request in, and Show the List,
/// for it beside them again. On as many lines as they need.
struct PullRequestActionsRow: View {
    let item: PRSnapshot

    @EnvironmentObject private var sessions: PullRequestSessions
    @EnvironmentObject private var services: AppServices

    var body: some View {
        let shortcuts = SessionShortcuts.of(sessions.session(for: item.key))
        FlowLayout(spacing: 8, lineSpacing: 8) {
            PageSummarizeButton(ref: item.key.linkRef)
            if let shortcuts {
                SessionOpenButton(choice: shortcuts.choice, links: services.links)
                if let folder = shortcuts.folder {
                    FolderButtons(choice: shortcuts.choice, folder: folder, opener: services.folders)
                }
            }
            FillPageButton()
        }
        .controlSize(.small)
    }
}

/// What the actions under a pull request's heading offer for its session: the session, how it opens, and the folder it
/// works in, when that's known. Nothing without a session, or while BriefBar asks which of two or more it is.
struct SessionShortcuts: Equatable {
    var choice: SessionChoice
    var way: SessionOpening.Way
    /// An earlier task's worktree, or the folder one of the Copilot app's sessions works in, as its session state says, read
    /// with Send Work to Copilot or Show Links on; nil until it's read, and when it says none or that folder isn't there.
    var folder: URL?

    static func of(_ session: PullRequestSession?) -> SessionShortcuts? {
        guard let choice = session?.session else { return nil }
        return SessionShortcuts(choice: choice, way: SessionOpening.way(of: choice), folder: choice.folder)
    }

    /// "the worktree ‘Fix the Build’ works in, ~/Developer/copilot-worktrees/payments-api/pr-4071", for tooltips: a task
    /// BriefBar runs in a worktree of its own, or the folder of a session of the Copilot app's.
    static func folderPhrase(_ choice: SessionChoice, folder: URL) -> String {
        let kind = SessionOpening.way(of: choice) == .terminal ? "worktree" : "folder"
        return "the \(kind) ‘\(PullRequestSession.name(of: choice))’ works in, \(UserPath.abbreviate(folder.path))"
    }
}

/// How a pull request's session opens, from its line's ⌄ and the actions under its heading: in the Copilot app; or, for a
/// task BriefBar runs with the Copilot CLI, gone on with in Terminal. Neither while Copilot works in it, or in its checkout
/// for another task, as its line says Busy then.
struct SessionOpening {
    enum Way: Equatable {
        case copilot
        case terminal
    }

    let way: Way
    let isEnabled: Bool
    let perform: @MainActor () -> Void

    /// "Open in Copilot", "Continue in Terminal".
    var title: String {
        switch way {
        case .copilot: return "Open in Copilot"
        case .terminal: return "Continue in Terminal"
        }
    }

    var symbol: String {
        switch way {
        case .copilot: return "arrow.up.forward.app"
        case .terminal: return "terminal"
        }
    }

    /// In Terminal for a task BriefBar runs with the Copilot CLI; in Copilot for the app's sessions, and for a task that went
    /// on with one there.
    static func way(of choice: SessionChoice) -> Way {
        if let run = choice.run, run.isAppSession != true { return .terminal }
        return .copilot
    }

    @MainActor
    static func of(_ choice: SessionChoice, links: Links, copilot: CopilotTasksStore) -> SessionOpening {
        switch way(of: choice) {
        case .terminal:
            let entry = copilot.entries.first { $0.id == choice.id }
            let isEnabled = (entry.map { !$0.status.phase.isActive } ?? false) && !choice.isUnavailable && copilot.canSend
            return SessionOpening(way: .terminal, isEnabled: isEnabled) {
                if let entry { copilot.continueInTerminal(entry) }
            }
        case .copilot:
            return SessionOpening(way: .copilot, isEnabled: !choice.isUnavailable) {
                PullRequestSessionMenu.openInCopilot(choice, links: links, copilot: copilot)
            }
        }
    }
}

/// Open in Copilot, or Continue in Terminal: the pull request's session, as its line's ⌄ opens it.
private struct SessionOpenButton: View {
    let choice: SessionChoice
    @ObservedObject var links: Links

    @EnvironmentObject private var copilot: CopilotTasksStore

    var body: some View {
        let opening = SessionOpening.of(choice, links: links, copilot: copilot)
        Button {
            opening.perform()
        } label: {
            ControlLabel(opening.title, systemImage: opening.symbol)
                .fixedSize()
        }
        .glassButtonStyle()
        .disabled(!opening.isEnabled)
        .help(help(opening))
    }

    private func help(_ opening: SessionOpening) -> String {
        let name = "‘\(PullRequestSession.name(of: choice))’"
        switch (opening.way, opening.isEnabled) {
        case (.copilot, true): return "Opens \(name), this pull request's session, in the Copilot app"
        case (.terminal, true): return "Goes on with \(name), this pull request's session, in Terminal, in its worktree"
        case (.copilot, false): return "Copilot is working in \(name), or in its checkout, for a task BriefBar sent: open it once that's done"
        case (.terminal, false): return "Go on with \(name) in Terminal once Copilot is done working in it"
        }
    }
}

/// The folder the pull request's session works in: in the editor or terminal you opened one in last, ▾ choosing another or
/// copying its path; and in the Finder.
private struct FolderButtons: View {
    let choice: SessionChoice
    let folder: URL
    @ObservedObject var opener: FolderOpener

    var body: some View {
        let phrase = SessionShortcuts.folderPhrase(choice, folder: folder)
        if let app = opener.preferred {
            SplitMenuButton(
                "Open in \(app.name)", systemImage: app.symbol,
                help: "Opens \(phrase), in \(app.name). Its menu opens it in another app, where folders open from then on.",
                hint: "Opens the folder in another editor or terminal, which folders open in from then on, or copies its path.",
                entries: entries(checking: app)
            ) {
                opener.open(folder, in: app)
            }
            .fixedSize()
        }
        Button {
            opener.openInFinder(folder)
        } label: {
            ControlLabel("Open in Finder", systemImage: "folder")
                .fixedSize()
        }
        .glassButtonStyle()
        .help("Opens \(phrase), in the Finder")
        // The apps on this Mac, the first time a folder shows.
        .onAppear { opener.lookForApps() }
    }

    /// The editors, then the terminals, the one it opens in checked, and Copy Path.
    private func entries(checking chosen: FolderApp) -> [SplitMenuButton.Entry] {
        var items: [SplitMenuButton.Entry] = []
        for (kind, title) in [(FolderApp.Kind.editor, "Editors"), (.terminal, "Terminals")] {
            let apps = opener.installed.filter { $0.kind == kind }
            guard !apps.isEmpty else { continue }
            items.append(.header(title))
            for app in apps {
                items.append(.item(app.name, isChecked: app == chosen) { opener.open(folder, in: app) })
            }
        }
        items.append(.divider)
        items.append(.item("Copy Path") { opener.copyPath(folder) })
        return items
    }
}

/// Fill the Page, for the details to cover the list beside them, to review the pull request in; Show the List, for it beside
/// them again. Only where the details offer it: beside the list on the Pull Requests page.
private struct FillPageButton: View {
    @Environment(\.detailsFilling) private var filling

    var body: some View {
        if let filling {
            let fills = filling.isFilling
            Button {
                filling.fill(!fills)
            } label: {
                ControlLabel(
                    fills ? "Show the List" : "Fill the Page",
                    systemImage: fills ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                )
                .fixedSize()
            }
            .glassButtonStyle()
            .help(fills ? "Shows the list beside the details again" : "Makes the details fill the page, over the list, to review the pull request in")
        }
    }
}
