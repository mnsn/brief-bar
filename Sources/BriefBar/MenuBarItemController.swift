import AppKit
import BriefBarCore
import BriefBarUI
import Combine
import SwiftUI

/// One menu-bar item: one or more sections, with their counts side by side or added up by state, and a popover with
/// a tab for each section when it shows several.
@MainActor
final class MenuBarItemController: NSObject {
    let id: String
    private(set) var sections: [SectionID]
    private var options: MenuBarItemOptions
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    /// What the popover opens from, so it stays on the display you clicked.
    private let anchor = PopoverAnchor()
    private let panel: ItemPanelModel
    private unowned let model: AppModel
    private var cancellables: Set<AnyCancellable> = []
    /// The sections the open popover shows, and as what: one tab's, or a list by state's. Empty while it's closed.
    private var visible: [SectionID: SectionViewer.Kind] = [:]
    /// The sections whose counts the item shows.
    private var counted: [SectionID] = []

    /// Where the item is across the screen, to put items in the order they're in the menu bar. Nil until it's there.
    var screenX: CGFloat? {
        statusItem.button?.window?.frame.minX
    }

    init(id: String, sections: [SectionID], options: MenuBarItemOptions, model: AppModel) {
        self.id = id
        self.sections = sections
        self.options = options
        self.model = model
        panel = ItemPanelModel(model: model)
        super.init()

        let host = NSHostingController(rootView: ItemPanelView(panel: panel))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        panel.didSelect = { [weak self] section in
            self?.remember(section)
            self?.updateVisible()
        }
        panel.didChangePresentation = { [weak self] in self?.updateVisible() }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem.autosaveName = "BriefBar.\(id)"
        update(sections: sections, options: options)
    }

    func update(sections: [SectionID], options: MenuBarItemOptions) {
        self.sections = sections
        self.options = options
        panel.sections = sections
        if let selected = panel.selected, !sections.contains(selected) {
            panel.selected = nil
        }
        panel.usesCompactMenuBar = model.services.interfaceOptions.compactMenuBar
        panel.listByState = options.listByState && sections.count > 1 && sections.contains { model.info(for: $0)?.states.isEmpty == false }
        panel.stateList.update(sections: panel.listByState || panel.usesCompactMenuBar ? sections : [])
        updateVisible()
        setCounted(sections)
        cancellables.removeAll()
        let sources = sections.compactMap { model.source(for: $0) }
        var seen = Set<SourceID>()
        for source in sources where seen.insert(source.id).inserted {
            source.segmentsChanged
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in MainActor.assumeIsolated { self?.render() } }
                .store(in: &cancellables)
        }
        render()
    }

    func remove() {
        closePopover()
        anchor.remove()
        setVisible([:])
        setCounted([])
        cancellables.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Shows the popover at `section`'s tab, which it then opens at next time too; for nil, at the tab it showed
    /// last, or the first time, the one that needs you. A list by state has no tabs: it shows every section's things,
    /// and leaves the tab the item opens at as it was.
    func showPopover(at section: SectionID?) {
        guard let button = statusItem.button,
              let selected = MenuBarTabs.load(from: model.services.defaults).tab(
                  for: id, sections: sections, asked: section,
                  needsYou: { model.source(for: $0)?.segment(for: $0).needsAttention == true }
              )
        else { return }
        panel.selected = selected
        if panel.usesCompactMenuBar {
            panel.listByState = section == nil && !panel.stateList.sections.isEmpty
        }
        if panel.listByState {
            for section in panel.stateList.sections {
                model.source(for: section)?.panelWillShow(section)
            }
        } else {
            remember(selected)
            model.source(for: selected)?.panelWillShow(selected)
        }
        guard !popover.isShown else {
            updateVisible()
            return
        }
        model.closePanels(except: self)
        NSApp.activate()
        let anchorView = anchor.view(over: button) ?? button
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        button.highlight(true)
        popover.contentViewController?.view.window?.makeKey()
        updateVisible()
    }

    /// Tells the sources which sections the popover shows, after it opened, closed or switched tabs.
    private func updateVisible() {
        var shown: [SectionID: SectionViewer.Kind] = [:]
        if popover.isShown {
            if panel.listByState {
                for section in panel.stateList.sections { shown[section] = .stateList }
            } else if let current = panel.current {
                shown[current] = .popover
            }
        }
        panel.stateList.isShowing = popover.isShown && panel.listByState
        setVisible(shown)
    }

    private func setVisible(_ shown: [SectionID: SectionViewer.Kind]) {
        guard shown != visible else { return }
        let before = visible
        visible = shown
        for (section, kind) in before where shown[section] != kind {
            model.source(for: section)?.sectionVisibilityChanged(section, isShowing: false, by: SectionViewer(kind, id: id))
        }
        for (section, kind) in shown where before[section] != kind {
            model.source(for: section)?.sectionVisibilityChanged(section, isShowing: true, by: SectionViewer(kind, id: id))
        }
    }

    /// Tells the sources which sections' counts the item shows, in the menu bar all the time.
    private func setCounted(_ sections: [SectionID]) {
        let viewer = SectionViewer(.menuBarItem, id: id)
        let gone = counted.filter { !sections.contains($0) }
        let added = sections.filter { !counted.contains($0) }
        counted = sections
        for section in gone { model.source(for: section)?.sectionVisibilityChanged(section, isShowing: false, by: viewer) }
        for section in added { model.source(for: section)?.sectionVisibilityChanged(section, isShowing: true, by: viewer) }
    }

    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover(at: nil)
        }
    }

    /// Remembers the tab the popover shows, to open at it next time, even after BriefBar restarts.
    private func remember(_ section: SectionID) {
        var tabs = MenuBarTabs.load(from: model.services.defaults)
        guard tabs.last(for: id) != section else { return }
        tabs.remember(section, for: id)
        tabs.save(to: model.services.defaults)
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let content = model.menuBarContent(sections: sections, options: options)
        MenuBarDrawing.configure(button, item: content)
        let summary = content.summary
        button.toolTip = summary
        button.setAccessibilityLabel(summary)
        panel.objectWillChange.send()
    }
}

extension MenuBarItemController: NSPopoverDelegate {
    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            updateVisible()
            // Unless it opened again as it was closing, from the same anchor.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.popover.isShown else { return }
                self.anchor.remove()
                self.statusItem.button?.highlight(false)
            }
        }
    }
}

/// The popover's content, under the Overview at the top: one section's panel, under a tab for each section when there
/// are several; or every section's things together, by state.
@MainActor
final class ItemPanelModel: ObservableObject {
    @Published var sections: [SectionID] = []
    @Published var selected: SectionID?
    /// One list by state rather than a tab for each section.
    @Published var listByState = false
    @Published var usesCompactMenuBar = false
    let stateList: StateListModel
    /// Another tab was chosen.
    var didSelect: (SectionID) -> Void = { _ in }
    var didChangePresentation: () -> Void = {}
    fileprivate unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
        stateList = StateListModel(model: model)
    }

    var current: SectionID? {
        selected.flatMap { sections.contains($0) ? $0 : nil } ?? sections.first
    }

    var updates: UpdateStatus {
        model.services.updates
    }

    /// The widest of its sections' panels, so the popover keeps its width as you switch tabs.
    var width: CGFloat {
        sections.compactMap { model.source(for: $0)?.panelWidth }.max() ?? 360
    }

    func title(for section: SectionID) -> String {
        guard let source = model.source(for: section) else { return section.rawValue }
        let title = source.info(for: section)?.title ?? source.name
        let segment = source.segment(for: section)
        let count = model.services.interfaceOptions.clearerStates ? segment.attentionCount : segment.count
        return count > 0 ? "\(title) \(count)" : title
    }

    /// The section's symbol and count, for tabs too small for titles.
    func shortTitle(for section: SectionID) -> some View {
        let symbol = model.info(for: section)?.symbol ?? "circle"
        let segment = model.source(for: section)?.segment(for: section)
        let count = model.services.interfaceOptions.clearerStates ? (segment?.attentionCount ?? 0) : (segment?.count ?? 0)
        return Label(count > 0 ? "\(count)" : "", systemImage: symbol)
            .labelStyle(.titleAndIcon)
    }

    /// For VoiceOver and a tab's tooltip.
    func spokenTitle(for section: SectionID) -> String {
        guard let source = model.source(for: section) else { return section.rawValue }
        let title = source.info(for: section)?.title ?? source.name
        return source.sections.count > 1 ? "\(source.name): \(title)" : title
    }

    func panel(for section: SectionID) -> AnyView {
        model.source(for: section)?.panel(for: section) ?? AnyView(EmptyView())
    }

    func select(_ section: SectionID) {
        if usesCompactMenuBar { listByState = false }
        selected = section
        model.source(for: section)?.panelWillShow(section)
        didSelect(section)
    }

    func showAllActivity() {
        listByState = true
        for section in stateList.sections {
            model.source(for: section)?.panelWillShow(section)
        }
        didChangePresentation()
    }
}

struct ItemPanelView: View {
    @ObservedObject var panel: ItemPanelModel

    var body: some View {
        VStack(spacing: 0) {
            OverviewLinkView(link: panel.model.overviewLink)
            UpdateBanner(updates: panel.updates)
            if panel.usesCompactMenuBar {
                Menu {
                    if !panel.stateList.sections.isEmpty {
                        Button("All Activity") { panel.showAllActivity() }
                        Divider()
                    }
                    ForEach(panel.sections, id: \.self) { section in
                        Button(panel.spokenTitle(for: section)) { panel.select(section) }
                    }
                } label: {
                    Text(panel.listByState ? "All Activity" : panel.current.map(panel.spokenTitle) ?? "Sections")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(width: panel.width)
                .accessibilityLabel("Choose a source or all activity")
                Divider()
            }
            if panel.listByState {
                StateListView(list: panel.stateList, model: panel.model, width: panel.width)
                    .environmentObject(panel.model.services)
                    .environmentObject(panel.model.services.loginItem)
            } else {
                tabbed
            }
        }
        .environment(\.panelStyle, .popover(width: panel.sections.count > 1 ? panel.width : nil))
        .interfaceOptions(from: panel.model.services)
    }

    @ViewBuilder
    private var tabbed: some View {
        if panel.sections.count > 1, !panel.usesCompactMenuBar, let current = panel.current {
            // As many sections as there are: smaller tabs, then symbols with counts, then a menu, as they stop
            // fitting the popover's width.
            ViewThatFits(in: .horizontal) {
                tabs(current: current)
                tabs(current: current)
                    .controlSize(.small)
                symbolTabs(current: current)
                menu(current: current)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: panel.width)
            Divider()
        }
        if let current = panel.current {
            // Its title opens its page in BriefBar's window.
            panel.panel(for: current)
                .environment(\.shownSection, current)
                .environment(\.titleOpensPage, true)
                .id(current)
        }
    }

    private func selection(_ current: SectionID) -> Binding<SectionID> {
        Binding(get: { current }, set: { panel.select($0) })
    }

    private func tabs(current: SectionID) -> some View {
        Picker("Section", selection: selection(current)) {
            ForEach(panel.sections, id: \.self) { section in
                Text(panel.title(for: section))
                .help(panel.spokenTitle(for: section))
                .accessibilityLabel(panel.spokenTitle(for: section))
                .tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// Each section's symbol and count, for when titles don't fit: a segmented picker draws a label's title but not
    /// its icon.
    private func symbolTabs(current: SectionID) -> some View {
        HStack(spacing: 2) {
            ForEach(panel.sections, id: \.self) { section in
                let isSelected = section == current
                Button {
                    panel.select(section)
                } label: {
                    panel.shortTitle(for: section)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.primary.opacity(0.13) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(panel.spokenTitle(for: section))
                .accessibilityLabel(panel.spokenTitle(for: section))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func menu(current: SectionID) -> some View {
        Picker("Section", selection: selection(current)) {
            ForEach(panel.sections, id: \.self) { section in
                Text(panel.title(for: section)).tag(section)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}

/// That an update is waiting, after a scheduled check found it, at the top of every list until you look at it.
struct UpdateBanner: View {
    @ObservedObject var updates: UpdateStatus

    var body: some View {
        if let version = updates.pendingVersion {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.tint)
                    Text("BriefBar \(version) is available")
                    Spacer()
                    Button("Update…") { updates.check() }
                        .buttonStyle(.borderless)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                Divider()
            }
        }
    }
}

/// BriefBar's own icon in the menu bar, while no source is on or you've hidden every section, so you can always
/// get to Settings.
@MainActor
final class PlaceholderItem: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private unowned let model: AppModel
    private var destination = SettingsDestination.general

    init(model: AppModel) {
        self.model = model
        super.init()
        let image = NSImage(systemSymbolName: AppSymbols.app, accessibilityDescription: AppIdentity.name)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.autosaveName = "BriefBar.placeholder"
        update(everythingHidden: false)
    }

    /// - Parameter everythingHidden: sources are on, but you've hidden all their sections.
    func update(everythingHidden: Bool) {
        destination = everythingHidden ? .layout(.menuBar) : .general
        statusItem.button?.toolTip = everythingHidden ? "BriefBar: every section is hidden" : "BriefBar: nothing is on"

        let menu = NSMenu()
        let note = NSMenuItem(
            title: everythingHidden
                ? "You've hidden every section from the menu bar."
                : "BriefBar shows nothing until you turn on a source.",
            action: nil, keyEquivalent: ""
        )
        note.isEnabled = false
        menu.addItem(note)
        let choose = NSMenuItem(
            title: everythingHidden ? "Choose What the Menu Bar Shows…" : "Choose What BriefBar Shows…",
            action: #selector(openSettings), keyEquivalent: ","
        )
        choose.target = self
        menu.addItem(choose)
        if everythingHidden {
            let window = NSMenuItem(title: "Open in Window", action: #selector(openWindow), keyEquivalent: "")
            window.target = self
            menu.addItem(window)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit BriefBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func openSettings() {
        model.openSettings(destination)
    }

    @objc private func openWindow() {
        model.openWindow(at: nil)
    }
}
