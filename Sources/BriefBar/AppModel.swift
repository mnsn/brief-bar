import AppKit
import BriefBarCore
import BriefBarUI
import Combine
import CopilotTasks

/// The app: its sources, which of them are on, and where their sections show: menu-bar items, desktop widgets
/// and windows, each arranged by a layout of its own.
@MainActor
final class AppModel: ObservableObject {
    let services: AppServices
    let sources: [any BriefBarSource]
    /// Whether agents may use BriefBar, and BriefBar among the Copilot CLI's MCP servers.
    let agents: AgentsModel
    /// Words the brief across sources on this Mac, for every list and page that shows it.
    let briefWriter: BriefWriter
    @Published private(set) var choices: SourceChoices
    @Published private(set) var layouts: [Surface: SectionLayout] = [:]
    /// Each widget's position and size, by the widget's ID.
    @Published private(set) var widgetOptions: [String: WidgetOptions]
    /// How each menu-bar item shows its sections, by the item's ID: side by side, unless you chose otherwise.
    @Published private(set) var menuBarItemOptions: [String: MenuBarItemOptions]
    /// Whether the Overview widget shows, where and how big.
    @Published private(set) var overviewWidgetOptions: OverviewWidgetOptions

    private var items: [String: MenuBarItemController] = [:]
    /// The visible items' IDs, left to right.
    private var itemOrder: [String] = []
    private var placeholder: PlaceholderItem?
    private var widgets: [String: WidgetHost] = [:]
    private var overviewWidget: OverviewWidgetHost?
    private var windows: [String: WindowHost] = [:]
    private lazy var settingsWindow = SettingsWindowController(model: self)
    /// The Overview at the top of every list.
    private(set) lazy var overviewLink = OverviewLink(model: self)
    private var cancellables: Set<AnyCancellable> = []
    /// Activates BriefBar again once the Dock is active, to take the menu bar (`showInDock`).
    private var takingMenuBar: AnyCancellable?

    private static let launchedKey = "hasLaunched"

    /// - Parameters:
    ///   - demo: made-up data for every source, which are all on.
    ///   - rendering: for `--render`: a copy of the installed app's preferences, kept in memory.
    init(demo: Bool, rendering: Bool = false) {
        // `--demo` and `--render` never touch the app's own preferences.
        let defaults: UserDefaults
        if rendering && !demo {
            defaults = MemoryDefaults(values: UserDefaults.standard.persistentDomain(forName: AppIdentity.bundleIdentifier) ?? [:])
        } else if demo || rendering {
            defaults = MemoryDefaults()
        } else {
            defaults = .standard
        }
        services = AppServices(defaults: defaults, isDemo: demo)
        // Only the app itself asks the Copilot CLI.
        agents = AgentsModel(defaults: defaults, isLive: !demo && !rendering)
        // Summaries: the app asks the Copilot CLI when you ask; the demo makes them up; `--render` of your own data writes
        // none.
        services.summaries.models = CopilotModel.suggestions.map { StorySummaries.Model(id: $0.id, name: $0.name) }
        services.summaries.write = demo ? DemoSummaries.write : rendering ? nil : AppModel.copilotSummaries()
        // `--render` keeps the brief in BriefBar's own words, so pictures don't depend on the model, unless asked to wait.
        briefWriter = BriefWriter(isEnabled: !rendering || Attribution.environment["BRIEFBAR_RENDER_SUMMARIES"] == "1")
        // Only the app itself reads Notification Center for pull requests sent in chats.
        sources = SourceCatalog.sources(services: services, chats: demo || rendering ? .inert : .notificationCenter())
        var choices = SourceChoices.load(from: defaults)
        if demo {
            for source in sources { choices.turnOn(source.id, version: source.description.version) }
        }
        self.choices = choices
        WidgetMigration.run(defaults)
        widgetOptions = WidgetOptions.load(from: defaults)
        menuBarItemOptions = MenuBarItemOptions.load(from: defaults)
        overviewWidgetOptions = OverviewWidgetOptions.load(from: defaults)
        layouts = Dictionary(uniqueKeysWithValues: Surface.allCases.map { ($0, SectionLayout.load($0, from: defaults)) })

        services.openSettings = { [weak self] destination in self?.openSettings(destination) }
        services.showPanel = { [weak self] section in self?.showPanel(section) ?? false }
        services.closePanels = { [weak self] in self?.closePanels() }
        services.openWindow = { [weak self] section in self?.openWindow(at: section) }
        services.hasPage = { [weak self] section in self?.hasPage(section) ?? false }
        services.notifier.onOpen = { [weak self] click in
            guard let self else { return }
            // One that only counted the updates: the Notifications page lists them, while the window has it.
            if click.sumsUp, self.openNotificationsPage() { return }
            guard let source = click.source, self.state(of: source) == .on else { return }
            self.source(source)?.openNotification(click.userInfo)
        }

        // Opening something hands focus to another app; don't leave a list hanging open.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.closePanels() } }
            .store(in: &cancellables)

        services.$interfaceOptions
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.objectWillChange.send()
                    if !rendering { self?.updateSurfaces() }
                }
            }
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

    /// The first section of each source among `sections`, for a menu with each source's own items.
    func sourceParts(of sections: [SectionID]) -> [(section: SectionID, source: any BriefBarSource)] {
        var parts: [(section: SectionID, source: any BriefBarSource)] = []
        for section in sections {
            guard let source = source(for: section), !parts.contains(where: { $0.source.id == source.id }) else { continue }
            parts.append((section, source))
        }
        return parts
    }

    func info(for section: SectionID) -> SectionInfo? {
        source(for: section)?.info(for: section)
    }

    /// The sections' counts by state, added up: what a window's sidebar and the Overview at the top of every list
    /// count for its Overview.
    func states(of sections: [SectionID]) -> StateCounts {
        sections.compactMap { source(for: $0)?.segment(for: $0).states }.reduce(StateCounts(), +)
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
        // Keep It On, after an update, leaves everything where it was.
        place(source, turnedOn: wasOff)
        Log.app.info("Turned on \(id.rawValue, privacy: .public)")
        source.start()
        updateSurfaces()
        source.didTurnOn()
    }

    /// Turns a source off: it stops, and what it saved about your data is deleted. Its settings stay.
    func turnOff(_ id: SourceID) {
        guard let source = source(id), state(of: id) != .off else { return }
        source.stop()
        source.deleteSavedData()
        services.notifier.removeDelivered(from: id)
        services.recentNotifications.forget(id)
        choices.turnOff(id)
        choices.save(to: services.defaults)
        Log.app.info("Turned off \(id.rawValue, privacy: .public)")
        updateSurfaces()
    }

    // MARK: Layouts

    func layout(_ surface: Surface) -> SectionLayout {
        layouts[surface] ?? SectionLayout(surface)
    }

    /// The sections that can show on `surface`, of every source or only those that are on, in the sources'
    /// order, hidden ones included.
    func sections(_ surface: Surface, onlyOn: Bool = true) -> [SectionID] {
        (onlyOn ? onSources : sources).flatMap { source in
            source.sections.filter { $0.surfaces.contains(surface) }.map(\.id)
        }
    }

    /// The sections of the sources that are on that you've hidden from `surface`.
    func hiddenSections(_ surface: Surface) -> [SectionID] {
        sections(surface).filter(layout(surface).isHidden)
    }

    /// The sources that are on with no section that can show on `surface`, such as a source without widgets.
    func sourcesMissing(from surface: Surface) -> [any BriefBarSource] {
        onSources.filter { source in !source.sections.contains { $0.surfaces.contains(surface) } }
    }

    func visibleItems(_ surface: Surface) -> [SectionLayout.Item] {
        layout(surface).visibleItems(showing: sections(surface))
    }

    /// The menu-bar items that show, left to right as they are in the menu bar, where you may have ⌘-dragged them;
    /// in the layout's order until they're all there, as for `--render`.
    func menuBarItemsInOrder() -> [SectionLayout.Item] {
        let visible = presentedMenuBarItems
        let positions = visible.compactMap { items[$0.id]?.screenX }
        guard positions.count == visible.count else { return visible }
        return zip(visible, positions).sorted { $0.1 < $1.1 }.map(\.0)
    }

    var presentedMenuBarItems: [SectionLayout.Item] {
        services.interfaceOptions.menuBarItems(visibleItems(.menuBar))
    }

    /// Puts a section where you dropped it in Settings: with others, on its own, or hidden. A hidden section's source
    /// stays on.
    func move(_ section: SectionID, to destination: SectionDestination, on surface: Surface) {
        change(surface) { $0.move(section, to: destination) }
    }

    /// Hides every section of an item, such as a widget.
    func hideItem(_ id: String, on surface: Surface) {
        guard let item = visibleItems(surface).first(where: { $0.id == id }) else { return }
        change(surface) { layout in item.sections.forEach { layout.hide($0) } }
    }

    /// Puts every section in one item: as they show now, then those of the sources that are off, so they join
    /// it when you turn them on.
    func combineAll(on surface: Surface) {
        let order = visibleItems(surface).flatMap(\.sections) + sections(surface, onlyOn: false)
        change(surface) { $0.combineAll(order) }
    }

    func separateAll(on surface: Surface) {
        change(surface) { $0.separateAll() }
    }

    func options(forWidget id: String) -> WidgetOptions {
        widgetOptions[id] ?? WidgetOptions()
    }

    func setOptions(_ options: WidgetOptions, forWidget id: String) {
        widgetOptions[id] = options
        // Only the widgets there are; a widget that's gone starts over if it comes back.
        let ids = Set(layout(.widgets).items.map(\.id))
        widgetOptions = widgetOptions.filter { ids.contains($0.key) }
        WidgetOptions.save(widgetOptions, to: services.defaults)
        updateWidgets()
    }

    func options(forMenuBarItem id: String) -> MenuBarItemOptions {
        if services.interfaceOptions.compactMenuBar, id == InterfaceOptions.compactMenuBarID {
            return MenuBarItemOptions(byState: true, listByState: true)
        }
        return menuBarItemOptions[id] ?? MenuBarItemOptions()
    }

    func setOptions(_ options: MenuBarItemOptions, forMenuBarItem id: String) {
        menuBarItemOptions[id] = options
        keepMenuBarItemOptions()
        updateMenuBar()
    }

    /// Only the items there are, and only what isn't the default: an item that's gone takes its options with it.
    private func keepMenuBarItemOptions() {
        let kept = MenuBarItemOptions.kept(menuBarItemOptions, in: layout(.menuBar))
        if kept != menuBarItemOptions {
            menuBarItemOptions = kept
        }
        MenuBarItemOptions.save(kept, to: services.defaults)
    }

    /// For `--render`: draws Settings with `layout`, without saving it or changing what shows.
    func useForRendering(_ layout: SectionLayout) {
        layouts[layout.surface] = layout
    }

    /// For `--render`: draws Settings with these menu-bar items' options, without saving them.
    func useForRendering(_ options: [String: MenuBarItemOptions]) {
        menuBarItemOptions = options
    }

    private func change(_ surface: Surface, _ body: (inout SectionLayout) -> Void) {
        var layout = layout(surface)
        body(&layout)
        layouts[surface] = layout
        layout.save(to: services.defaults)
        if surface == .menuBar {
            keepMenuBarItemOptions()
        }
        update(surface)
    }

    /// Places the sections of the sources that are on, as at launch: `--render` draws them where they'd be.
    func placeSections() {
        for source in onSources {
            place(source, turnedOn: false)
        }
    }

    /// Places a source's sections on every surface: where they were, or where each surface puts new sections.
    /// A section that starts hidden on a surface, such as a Teams widget, is hidden there the first time.
    private func place(_ source: any BriefBarSource, turnedOn: Bool) {
        for surface in Surface.allCases {
            var layout = layout(surface)
            let sections = source.sections.filter { $0.surfaces.contains(surface) }
            for info in sections where layout.item(containing: info.id) == nil && info.hiddenAtFirst.contains(surface) {
                layout.hide(info.id)
            }
            let ids = sections.map(\.id)
            // Turning a source on always shows it in the menu bar, even if you'd hidden all of it.
            if turnedOn && surface == .menuBar {
                layout.sourceTurnedOn(ids)
            } else {
                layout.place(ids)
            }
            layouts[surface] = layout
            layout.save(to: services.defaults)
        }
    }

    private func update(_ surface: Surface) {
        switch surface {
        case .menuBar: updateMenuBar()
        case .widgets: updateWidgets()
        case .windows: updateWindows()
        }
    }

    private func updateSurfaces() {
        Surface.allCases.forEach(update)
    }

    // MARK: Menu bar

    /// What a menu-bar item that shows these sections draws, with its options.
    func menuBarContent(sections: [SectionID], options: MenuBarItemOptions) -> MenuBarItemContent {
        let shown = sections.filter { source(for: $0) != nil }
        return MenuBarItemContent(
            segments: shown.compactMap { source(for: $0)?.segment(for: $0) },
            counted: shown.map { info(for: $0)?.counted ?? CountNoun("item", "items") },
            byState: options.byState ? options.shownStates : nil,
            compact: services.interfaceOptions.compactMenuBar
        )
    }

    private func updateMenuBar() {
        let visible = presentedMenuBarItems
        let ids = Set(visible.map(\.id))
        for (id, item) in items where !ids.contains(id) {
            item.remove()
            items[id] = nil
        }
        // New items appear to the left of earlier ones, so create them right to left: the first is leftmost.
        for entry in visible.reversed() {
            let options = options(forMenuBarItem: entry.id)
            if let item = items[entry.id] {
                item.update(sections: entry.sections, options: options)
            } else {
                items[entry.id] = MenuBarItemController(id: entry.id, sections: entry.sections, options: options, model: self)
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
        guard let entry = presentedMenuBarItems.first(where: { $0.sections.contains(section) }),
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

    // MARK: Widgets

    /// What an Overview covers when it's not a window's: every section of the sources that are on whose things can be
    /// in a state.
    var overviewSections: [SectionID] {
        onSources.flatMap { source in source.sections.filter { !$0.states.isEmpty }.map(\.id) }
    }

    func setOverviewWidget(_ options: OverviewWidgetOptions) {
        overviewWidgetOptions = options
        options.save(to: services.defaults)
        updateOverviewWidget()
    }

    private func updateOverviewWidget() {
        let sections = overviewSections
        guard overviewWidgetOptions.isShown, !sections.isEmpty else {
            overviewWidget?.close()
            overviewWidget = nil
            return
        }
        let widget = overviewWidget ?? OverviewWidgetHost(model: self)
        overviewWidget = widget
        widget.update(sections: sections, options: overviewWidgetOptions)
    }

    private func updateWidgets() {
        let visible = visibleItems(.widgets)
        let ids = Set(visible.map(\.id))
        for (id, widget) in widgets where !ids.contains(id) {
            widget.close()
            widgets[id] = nil
        }
        for entry in visible {
            let widget = widgets[entry.id] ?? WidgetHost(id: entry.id, model: self)
            widgets[entry.id] = widget
            widget.update(sections: entry.sections, options: options(forWidget: entry.id))
        }
        updateOverviewWidget()
    }

    // MARK: Windows

    /// Opens the window that shows `section`'s page, at that page; for nil, or a page you've hidden, the first
    /// window. With every page hidden, Settings › Windows.
    func openWindow(at section: SectionID?) {
        closePanels()
        let visible = visibleItems(.windows)
        guard let entry = section.flatMap({ section in visible.first { $0.sections.contains(section) } }) ?? visible.first else {
            openSettings(.layout(.windows))
            return
        }
        let window = windows[entry.id] ?? WindowHost(id: entry.id, model: self)
        windows[entry.id] = window
        window.update(sections: entry.sections)
        window.show(at: section)
        showInDock()
    }

    /// Opens one window, at `page`, or at its Overview if it has one.
    func openWindow(item id: String, at page: SectionID? = nil) {
        closePanels()
        guard let entry = visibleItems(.windows).first(where: { $0.id == id }) else { return }
        let window = windows[entry.id] ?? WindowHost(id: entry.id, model: self)
        windows[entry.id] = window
        window.update(sections: entry.sections)
        window.show(at: page)
        showInDock()
    }

    /// Opens the window that has the Overview, at the Overview; with none, the first window.
    func openOverview() {
        if let window = overviewLink.window {
            openWindow(item: window.id)
        } else {
            openWindow(at: nil)
        }
    }

    // MARK: Notifications

    /// Whether a window has the Notifications page: the one with the Overview has it, while the page is on and lists
    /// something.
    func hasNotificationsPage(window id: String) -> Bool {
        services.recentNotifications.showsPage && overviewLink.window?.id == id
    }

    /// Opens the window that has the Notifications page, at that page. False when none has it.
    @discardableResult
    func openNotificationsPage() -> Bool {
        guard let window = overviewLink.window, hasNotificationsPage(window: window.id) else { return false }
        openWindow(item: window.id, at: WindowPages.notifications)
        return true
    }

    /// Opens what a notification on the Notifications page is about, as clicking it in Notification Center does, which
    /// then has no need to keep it.
    func open(_ entry: NotificationHistory.Entry) {
        services.recentNotifications.markSeen(entry.id)
        services.notifier.removeDelivered(entry.id)
        guard state(of: entry.source) == .on else { return }
        source(entry.source)?.openNotification(entry.userInfo)
    }

    /// Whether a window has a page for `section`: not once you've hidden it from windows.
    func hasPage(_ section: SectionID) -> Bool {
        visibleItems(.windows).contains { $0.sections.contains(section) }
    }

    /// Whether a BriefBar window or Settings is open, for the Dock icon.
    var hasOpenWindow: Bool {
        windows.values.contains { $0.isOpen } || settingsWindow.isOpen
    }

    /// A window or Settings closed: BriefBar goes back to being a menu-bar app once none is open.
    func windowDidClose() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasOpenWindow else { return }
            takingMenuBar = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// While a window or Settings is open, BriefBar shows a Dock icon and its own menus, and becomes the active app.
    ///
    /// A menu-bar app has no menu bar: the app you were in keeps it, and a click on a BriefBar item first makes that
    /// app active again, so its windows would cover BriefBar's, or macOS would switch to its Space. An app only takes
    /// the menu bar as it becomes active, so when BriefBar already is, such as from its list, it hands over to the
    /// Dock, which has no windows to bring forward, and comes straight back.
    private func showInDock() {
        let isActiveMenuBarApp = NSApp.isActive && NSApp.activationPolicy() != .regular
        NSApp.setActivationPolicy(.regular)
        guard isActiveMenuBarApp,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else {
            NSApp.activate()
            return
        }
        takingMenuBar = NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .first()
            .timeout(.seconds(1), scheduler: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { NSApp.activate() } }
        NSApp.yieldActivation(to: dock)
        if !dock.activate(from: .current, options: []) {
            takingMenuBar = nil
        }
    }

    private func updateWindows() {
        let visible = visibleItems(.windows)
        for (id, window) in windows {
            if let entry = visible.first(where: { $0.id == id }) {
                window.update(sections: entry.sections)
            } else {
                window.close()
                windows[id] = nil
            }
        }
        overviewLink.update()
    }

    // MARK: Lifecycle

    func launch() {
        for source in onSources {
            source.start()
        }
        placeSections()
        updateSurfaces()

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

    /// Opening the app again (Finder, Spotlight, `open`) shows the first list, the first window when the menu bar
    /// shows nothing, or Settings when nothing is on.
    func reopen() {
        if let first = itemOrder.first, let item = items[first] {
            item.showPopover(at: nil)
        } else if !onSources.isEmpty, !visibleItems(.windows).isEmpty {
            openWindow(at: nil)
        } else {
            openSettings(onSources.isEmpty ? .general : .layout(.menuBar))
        }
    }

    /// Opens Settings at `destination`. As with a window, BriefBar shows a Dock icon and has the menu bar until it
    /// closes, so you can click its items to see what you arrange without Settings going away (`showInDock`).
    func openSettings(_ destination: SettingsDestination) {
        closePanels()
        settingsWindow.show(destination)
        showInDock()
    }
}

extension AppModel {
    /// Asks the Copilot CLI for summaries, with no tools, one at a time as you ask.
    static func copilotSummaries() -> StorySummaries.Writer {
        let summarizer = CopilotSummarizer()
        return { prompt, options in
            switch await summarizer.summarize(prompt, options: CopilotRunOptions(model: options.model, effort: options.effort)) {
            case .success(let answer): return .success(answer)
            case .failure(let failure): return .failure(StorySummaries.Problem(failure.message))
            }
        }
    }
}
