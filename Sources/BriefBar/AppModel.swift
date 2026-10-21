import AppKit
import BriefBarCore
import BriefBarUI
import Combine

/// The app: its sources, which of them are on, and the menu-bar items that show them.
@MainActor
final class AppModel: ObservableObject {
    let services: AppServices
    let sources: [any BriefBarSource]
    @Published private(set) var choices: SourceChoices
    @Published private(set) var layout: MenuBarLayout

    private var items: [String: MenuBarItemController] = [:]
    /// The visible items' IDs, left to right.
    private var itemOrder: [String] = []
    private var placeholder: PlaceholderItem?
    private lazy var settingsWindow = SettingsWindowController(model: self)
    private var cancellables: Set<AnyCancellable> = []

    private static let launchedKey = "hasLaunched"

    /// Throwaway preferences for `--demo` and `--render`, which never touch the app's own.
    static let demoSuite = "\(AppIdentity.bundleIdentifier).demo"
    static let renderSuite = "\(AppIdentity.bundleIdentifier).render"

    /// - Parameters:
    ///   - demo: made-up data for every source, which are all on.
    ///   - rendering: for `--render`: a copy of the installed app's preferences, deleted afterwards.
    init(demo: Bool, rendering: Bool = false) {
        let defaults: UserDefaults
        let suiteName = rendering ? Self.renderSuite : Self.demoSuite
        if demo || rendering, let suite = UserDefaults(suiteName: suiteName) {
            suite.removePersistentDomain(forName: suiteName)
            if rendering, !demo, let app = UserDefaults.standard.persistentDomain(forName: AppIdentity.bundleIdentifier) {
                suite.setPersistentDomain(app, forName: suiteName)
            }
            defaults = suite
        } else {
            defaults = .standard
        }
        services = AppServices(defaults: defaults, isDemo: demo)
        sources = SourceCatalog.sources(services: services)
        var choices = SourceChoices.load(from: defaults)
        if demo {
            for source in sources { choices.turnOn(source.id, version: source.description.version) }
        }
        self.choices = choices
        layout = MenuBarLayout.load(from: defaults)

        services.openSettings = { [weak self] destination in self?.openSettings(destination) }
        services.showPanel = { [weak self] section in self?.showPanel(section) ?? false }
        services.closePanels = { [weak self] in self?.closePanels() }
        services.notifier.onOpen = { [weak self] source, info in
            guard let self, let source, self.state(of: source) == .on else { return }
            self.source(source)?.openNotification(info)
        }

        // Opening something hands focus to another app; don't leave a list hanging open.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.closePanels() } }
            .store(in: &cancellables)
    }

    // MARK: Sources

    func state(of source: SourceID) -> SourceState {
        guard let found = self.source(source) else { return .off }
        return choices.state(of: source, version: found.description.version)
    }

    func source(_ id: SourceID) -> (any BriefBarSource)? {
        sources.first { $0.id == id }
    }

    func source(for section: SectionID) -> (any BriefBarSource)? {
        sources.first { $0.sections.contains { $0.id == section } }
    }

    var onSources: [any BriefBarSource] {
        sources.filter { state(of: $0.id) == .on }
    }

    /// Turns a source on, with your consent to what it says it reads now, and asks for what it needs.
    func turnOn(_ id: SourceID) {
        guard let source = source(id), state(of: id) != .on else { return }
        let wasOff = state(of: id) == .off
        choices.turnOn(id, version: source.description.version)
        choices.save(to: services.defaults)
        let sections = source.sections.map(\.id)
        // Keep It On, after an update, leaves the menu bar as it was.
        if wasOff {
            layout.sourceTurnedOn(sections)
        } else {
            layout.place(sections)
        }
        layout.save(to: services.defaults)
        Log.app.info("Turned on \(id.rawValue, privacy: .public)")
        source.start()
        updateMenuBar()
        source.didTurnOn()
    }

    /// Turns a source off: it stops, and what it saved about your data is deleted. Its settings stay.
    func turnOff(_ id: SourceID) {
        guard let source = source(id), state(of: id) != .off else { return }
        source.stop()
        source.deleteSavedData()
        services.notifier.removeDelivered(from: id)
        choices.turnOff(id)
        choices.save(to: services.defaults)
        Log.app.info("Turned off \(id.rawValue, privacy: .public)")
        updateMenuBar()
    }

    /// Whether a source that's on needs this, such as Full Disk Access.
    func isNeededByOnSource(_ requirement: Requirement) -> Bool {
        onSources.contains { $0.description.requirements.contains(requirement) }
    }

    // MARK: Menu bar

    /// The sections of the sources that are on, in the sources' order, including hidden ones.
    var onSections: [SectionID] {
        onSources.flatMap { $0.sections.map(\.id) }
    }

    /// The sections of the sources that are on that you've hidden.
    var hiddenSections: [SectionID] {
        onSections.filter(layout.isHidden)
    }

    func visibleItems() -> [MenuBarLayout.Item] {
        layout.visibleItems(showing: onSections)
    }

    func combine(_ section: SectionID, with other: SectionID) {
        layout.combine(section, with: other)
        layoutChanged()
    }

    func separate(_ section: SectionID) {
        layout.separate(section)
        layoutChanged()
    }

    /// Hides a section from the menu bar. Its source stays on.
    func hide(_ section: SectionID) {
        layout.hide(section)
        layoutChanged()
    }

    /// Puts every section in one item, as they show now, left to right, then those of the sources that are off,
    /// so they join it when you turn them on.
    func combineAll() {
        layout.combineAll(visibleItems().flatMap(\.sections) + sources.flatMap { $0.sections.map(\.id) })
        layoutChanged()
    }

    func separateAll() {
        layout.separateAll()
        layoutChanged()
    }

    /// For `--render`: draws Settings with `layout`, without saving it or changing the menu bar.
    func useForRendering(_ layout: MenuBarLayout) {
        self.layout = layout
    }

    private func layoutChanged() {
        layout.save(to: services.defaults)
        updateMenuBar()
    }

    private func updateMenuBar() {
        let visible = visibleItems()
        let ids = Set(visible.map(\.id))
        for (id, item) in items where !ids.contains(id) {
            item.remove()
            items[id] = nil
        }
        // New items appear to the left of earlier ones, so create them right to left: the first is leftmost.
        for entry in visible.reversed() {
            if let item = items[entry.id] {
                item.update(sections: entry.sections)
            } else {
                items[entry.id] = MenuBarItemController(id: entry.id, sections: entry.sections, model: self)
            }
        }
        itemOrder = visible.map(\.id)
        if visible.isEmpty {
            if placeholder == nil { placeholder = PlaceholderItem(model: self) }
            placeholder?.update(everythingHidden: !onSources.isEmpty)
        } else {
            placeholder?.remove()
            placeholder = nil
        }
    }

    /// Opens the list that shows `section`. False when no item shows it, because it's hidden.
    @discardableResult
    func showPanel(_ section: SectionID) -> Bool {
        guard let entry = visibleItems().first(where: { $0.sections.contains(section) }),
              let item = items[entry.id]
        else { return false }
        item.showPopover(at: section)
        return true
    }

    func closePanels(except kept: MenuBarItemController? = nil) {
        for item in items.values where item !== kept {
            item.closePopover()
        }
    }

    // MARK: Lifecycle

    func launch() {
        for source in onSources {
            source.start()
        }
        layout.place(onSections)
        layout.save(to: services.defaults)
        updateMenuBar()

        let firstLaunch = !services.defaults.bool(forKey: Self.launchedKey)
        services.defaults.set(true, forKey: Self.launchedKey)
        if let review = sources.first(where: { state(of: $0.id) == .needsReview }) {
            // It reads more since you turned it on: it waits for you to look.
            openSettings(.source(review.id))
        } else if firstLaunch && !services.isDemo {
            openSettings(.general)
        }
        Log.app.info("Launched from \(Bundle.main.bundlePath, privacy: .public) with \(self.onSources.map(\.id.rawValue).joined(separator: ", "), privacy: .public) on")
    }

    func terminate() {
        for source in onSources {
            source.stop()
        }
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the first list, or Settings when nothing shows.
    func reopen() {
        if let first = itemOrder.first, let item = items[first] {
            item.showPopover(at: nil)
        } else {
            openSettings(onSources.isEmpty ? .general : .menuBar)
        }
    }

    func openSettings(_ destination: SettingsDestination) {
        closePanels()
        settingsWindow.show(destination)
    }
}
