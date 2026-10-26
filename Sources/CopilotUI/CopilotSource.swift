import AppKit
import BriefBarCore
import BriefBarUI
import Combine
import CopilotCore
import SwiftUI

/// What every GitHub Copilot app session is doing: which are running, which need you, and which have
/// finished or stopped. It reads the Copilot app's own files, and needs no permission.
@MainActor
package final class CopilotSource: BriefBarSource {
    /// 2: Show Links.
    nonisolated package static let descriptionVersion = 2

    package let id = SourceID.copilot
    package let name = "GitHub Copilot"
    package let symbol = "waveform.path.ecg"
    package let description = SourceDescription(
        version: CopilotSource.descriptionVersion,
        summary: "What each GitHub Copilot app session is doing, and which ones need you",
        reads: "The GitHub Copilot app's own files under ~/.copilot, read-only: its database of sessions, and each session's event log. Only if you turn on Show Links: also which pull request each session started from or opened, and its project's GitHub repository and folder name, from the same database. BriefBar never changes them. It keeps only which finished sessions you've cleared, and, with Show Links, the links you add to sessions or hide, as references only, never titles.",
        network: "None. Copilot's list makes no network requests.",
        needs: "Nothing: macOS doesn't protect these files.",
        requirements: []
    )
    package let sections = [
        SectionInfo(
            id: .copilotSessions, title: "Sessions", symbol: "waveform.path.ecg",
            tint: Color(red: 0.86, green: 0.30, blue: 0.56), counted: CountNoun("Copilot session", "Copilot sessions"),
            states: Set(ItemState.allCases), surfaces: [.menuBar, .widgets, .windows]
        ),
    ]
    package var panelWidth: CGFloat { MenuPanelView.width }

    /// The groups counted in the menu bar: what to look at. Idle only shows in the list.
    private static let shownPhases: [DisplayPhase] = [.needsYou, .running, .done, .stopped]

    private let services: AppServices
    let settings: AppSettings
    let store: SessionStore
    private var linkObservers: Set<AnyCancellable> = []

    package init(services: AppServices) {
        self.services = services
        settings = AppSettings(defaults: services.defaults)
        // The demo reads only made-up data, never your own.
        store = SessionStore(settings: settings, paths: services.isDemo ? CopilotPaths.overridden() : CopilotPaths.default())
    }

    private func environment<V: View>(_ view: V) -> some View {
        view
            .interfaceOptions(from: services)
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(services)
            .environmentObject(services.loginItem)
    }

    // MARK: Lifecycle

    package func start() {
        store.start()
        // After the change: a @Published value emits before it's set.
        services.links.$isOn.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    self?.store.setReadsLinks(on)
                    self?.publishLinks()
                }
            }
            .store(in: &linkObservers)
        store.$sessions
            .sink { [weak self] sessions in MainActor.assumeIsolated { self?.publishLinks(sessions) } }
            .store(in: &linkObservers)
    }

    package func stop() {
        linkObservers.removeAll()
        store.stop()
        services.links.withdraw(.copilot)
    }

    package func deleteSavedData() {
        settings.forgetAcknowledged()
        // The links you added or hid to Copilot sessions.
        services.links.forget(.copilot)
    }

    // MARK: Show Links

    /// Tells Show Links about the sessions: what each one is, the branch and repository it works in, and the pull requests
    /// the app recorded it started from or opened.
    private func publishLinks(_ sessions: [SessionSnapshot]? = nil) {
        let links = services.links
        guard links.isOn else {
            links.withdraw(.copilot)
            return
        }
        var facts: [ItemLink] = []
        var items: [LinkedItem] = []
        for session in sessions ?? store.sessions {
            guard let ref = ItemRef.session(session.id) else { continue }
            let recorded = session.links
            for pullRequest in recorded?.pullRequests ?? [] {
                if let target = pullRequest.ref, let link = ItemLink(ref, target, origin: .copilot) { facts.append(link) }
            }
            let hint = session.isChat ? nil : session.branch.map {
                BranchHint(branch: $0, repositories: BranchHint.repositories([session.projectName, recorded?.folder], gitHub: recorded?.gitHubRepository))
            }
            let store = self.store
            items.append(LinkedItem(
                ref: ref, label: session.displayName, title: session.displayName, symbol: session.rowSymbol,
                color: session.phase == .idle ? .secondary : session.rowColor, state: session.phase.state, status: session.headline,
                place: [session.projectName, session.branch].compactMap { $0 }.joined(separator: " · "), hint: hint, date: session.since,
                open: {
                    // As it is when you click it.
                    store.open(store.sessions.first { $0.id == session.id } ?? session)
                }
            ))
        }
        links.publish(.copilot, links: facts, items: items)
    }

    // MARK: Menu bar

    package func segment(for section: SectionID) -> MenuBarSegment {
        let counts = store.counts
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString()
        for phase in Self.shownPhases where counts[phase] > 0 {
            title.append(NSAttributedString(string: " "))
            // Monochrome keeps the check and the exclamation mark cut out; one palette color fills them in.
            title.append(MenuBarDrawing.symbol(phase.symbol, color: phase.nsColor, font: font, sizeDelta: -2, monochrome: true))
            title.append(MenuBarDrawing.count(counts[phase], font: font))
        }
        let spoken = Self.shownPhases.filter { counts[$0] > 0 }.map { "\(counts[$0]) \($0.title.lowercased())" }
        return MenuBarSegment(
            glyph: symbol,
            title: title,
            summary: spoken.isEmpty ? "Copilot: all quiet" : "Copilot: " + spoken.joined(separator: ", "),
            count: counts.needsYou,
            needsAttention: counts.needsYou > 0,
            states: counts.states
        )
    }

    package var segmentsChanged: AnyPublisher<Void, Never> {
        store.$counts.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
    }

    /// Sessions that need you, are running, finished or stopped. Idle ones aren't in any state.
    package func stateRows(for section: SectionID) -> [StateRow] {
        store.sessions.compactMap { session in
            session.phase.state.map { state in
                StateRow(id: session.id, state: state, date: session.since, view: AnyView(environment(SessionRow(session: session))))
            }
        }
    }

    /// The same sessions, each in a sentence: what it waits for you on, or how it ended. Copilot's are in BriefBar's
    /// own words, without Apple Intelligence.
    package func briefLines(for section: SectionID) -> [BriefLine] {
        store.sessions.compactMap { session in
            session.phase.state.map { state in
                BriefLine(
                    id: "copilot/\(session.id)/\(session.reason.rawValue)", source: id, state: state, date: session.since,
                    sentence: session.briefSentence, open: { [store] in store.open(session) }
                )
            }
        }
    }

    /// Any session's change, such as a new question, not only the counts.
    package var stateRowsChanged: AnyPublisher<Void, Never> {
        store.$sessions.map { _ in () }.eraseToAnyPublisher()
    }

    package func panel(for section: SectionID) -> AnyView {
        AnyView(environment(MenuPanelView()))
    }

    package func panelWillShow(_ section: SectionID) {
        store.refresh()
    }

    // MARK: Widgets

    package func widget(for section: SectionID, size: WidgetSize, rows: Int) -> AnyView {
        AnyView(environment(WidgetSectionView(rows: rows)))
    }

    package func widgetHeight(for section: SectionID, rows: Int) -> CGFloat {
        WidgetSectionView.height(rows: rows, options: services.interfaceOptions)
    }

    package func widgetWidth(for section: SectionID, size: WidgetSize) -> CGFloat {
        size.width
    }

    package func widgetMenu(for section: SectionID) -> AnyView {
        AnyView(environment(SourceMenuContent()))
    }

    // MARK: Settings

    package func settingsView() -> AnyView {
        AnyView(environment(CopilotSettings()))
    }

    // MARK: Rendering

    package func loadForRendering() async {
        guard let paths = store.paths else {
            store.start()
            return
        }
        store.receive(SessionEngine.loadOnce(paths: paths, links: services.links.isOn))
        publishLinks()
    }
}
