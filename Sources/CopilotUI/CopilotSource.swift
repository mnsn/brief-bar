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
    nonisolated package static let descriptionVersion = 1

    package let id = SourceID.copilot
    package let name = "GitHub Copilot"
    package let symbol = "waveform.path.ecg"
    package let description = SourceDescription(
        version: CopilotSource.descriptionVersion,
        summary: "What each GitHub Copilot app session is doing, and which ones need you",
        reads: "The GitHub Copilot app's own files under ~/.copilot, read-only: its database of sessions, and each session's event log. BriefBar never changes them. It keeps only which finished sessions you've cleared.",
        network: "None. Copilot's list makes no network requests.",
        needs: "Nothing: macOS doesn't protect these files.",
        requirements: []
    )
    package let sections = [SectionInfo(id: .copilotSessions, title: "Sessions")]
    package var panelWidth: CGFloat { MenuPanelView.width }

    /// The groups counted in the menu bar: what to look at. Idle only shows in the list.
    private static let shownPhases: [DisplayPhase] = [.needsYou, .running, .done, .stopped]

    private let services: AppServices
    let settings: AppSettings
    let store: SessionStore
    private lazy var widget = DesktopWidgetController(autosaveName: "BriefBar.copilot.widget", title: name) { [unowned self] in
        AnyView(self.environment(WidgetView()))
    }
    private var cancellables: Set<AnyCancellable> = []

    package init(services: AppServices) {
        self.services = services
        settings = AppSettings(defaults: services.defaults)
        // The demo reads only made-up data, never your own.
        store = SessionStore(settings: settings, paths: services.isDemo ? CopilotPaths.overridden() : CopilotPaths.default())
    }

    private func environment<V: View>(_ view: V) -> some View {
        view
            .environmentObject(store)
            .environmentObject(settings)
            .environmentObject(services)
            .environmentObject(services.loginItem)
    }

    // MARK: Lifecycle

    package func start() {
        store.start()
        settings.$showWidget
            .combineLatest(settings.$placement, settings.$widgetSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show, placement, size in
                MainActor.assumeIsolated {
                    self?.widget.update(show: show, placement: placement,
                                        size: CGSize(width: size.width, height: WidgetView.height(for: size)))
                }
            }
            .store(in: &cancellables)
    }

    package func stop() {
        cancellables.removeAll()
        widget.hide()
        store.stop()
    }

    package func deleteSavedData() {
        settings.forgetAcknowledged()
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
            needsAttention: counts.needsYou > 0
        )
    }

    package var segmentsChanged: AnyPublisher<Void, Never> {
        store.$counts.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
    }

    package func panel(for section: SectionID) -> AnyView {
        AnyView(environment(MenuPanelView()))
    }

    package func panelWillShow(_ section: SectionID) {
        store.refresh()
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
        store.receive(SessionEngine.loadOnce(paths: paths))
    }

    package func extraRenderings() -> [(name: String, view: AnyView)] {
        AppSettings.WidgetSize.allCases.map { size in
            let widget = environment(WidgetView(size: size))
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(16)
            return (name: "widget-\(size.rawValue)", view: AnyView(widget))
        }
    }
}
