import AppKit
import BriefBarCore
import BriefBarUI
import Combine
import SwiftUI

/// One menu-bar item: one or more sections, with their counts side by side, and a popover with a tab for
/// each section when it shows several.
@MainActor
final class MenuBarItemController: NSObject {
    let id: String
    private(set) var sections: [SectionID]
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let panel: ItemPanelModel
    private unowned let model: AppModel
    private var cancellables: Set<AnyCancellable> = []

    init(id: String, sections: [SectionID], model: AppModel) {
        self.id = id
        self.sections = sections
        self.model = model
        panel = ItemPanelModel(model: model)
        super.init()

        let host = NSHostingController(rootView: ItemPanelView(panel: panel))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem.autosaveName = "BriefBar.\(id)"
        update(sections: sections)
    }

    func update(sections: [SectionID]) {
        self.sections = sections
        panel.sections = sections
        if let selected = panel.selected, !sections.contains(selected) {
            panel.selected = nil
        }
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
        cancellables.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Shows the popover, at this section's tab, or the one that needs you.
    func showPopover(at section: SectionID?) {
        guard let button = statusItem.button else { return }
        let selected = section.flatMap { sections.contains($0) ? $0 : nil } ?? preferredSection
        panel.selected = selected
        model.source(for: selected)?.panelWillShow(selected)
        guard !popover.isShown else { return }
        model.closePanels(except: self)
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
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

    /// The first section that needs you, or the one shown last.
    private var preferredSection: SectionID {
        let segments = sections.map { ($0, model.source(for: $0)?.segment(for: $0)) }
        if let attention = segments.first(where: { $0.1?.needsAttention == true }) {
            return attention.0
        }
        if let selected = panel.selected, sections.contains(selected) {
            return selected
        }
        return sections[0]
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let segments = sections.compactMap { section in model.source(for: section)?.segment(for: section) }
        MenuBarDrawing.configure(button, segments: segments)
        let summary = segments.map(\.summary).joined(separator: "\n")
        button.toolTip = summary
        button.setAccessibilityLabel(summary)
        panel.objectWillChange.send()
    }
}

/// The popover's content: one section's panel, under a tab for each section when there are several.
@MainActor
final class ItemPanelModel: ObservableObject {
    @Published var sections: [SectionID] = []
    @Published var selected: SectionID?
    private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var current: SectionID? {
        selected.flatMap { sections.contains($0) ? $0 : nil } ?? sections.first
    }

    /// The widest of its sections' panels, so the popover keeps its width as you switch tabs.
    var width: CGFloat {
        sections.compactMap { model.source(for: $0)?.panelWidth }.max() ?? 360
    }

    func title(for section: SectionID) -> String {
        guard let source = model.source(for: section) else { return section.rawValue }
        let title = source.sections.first { $0.id == section }?.title ?? source.name
        let count = source.segment(for: section).count
        return count > 0 ? "\(title) \(count)" : title
    }

    func panel(for section: SectionID) -> AnyView {
        model.source(for: section)?.panel(for: section) ?? AnyView(EmptyView())
    }

    func select(_ section: SectionID) {
        selected = section
        model.source(for: section)?.panelWillShow(section)
    }
}

struct ItemPanelView: View {
    @ObservedObject var panel: ItemPanelModel

    var body: some View {
        VStack(spacing: 0) {
            if panel.sections.count > 1, let current = panel.current {
                // Smaller tabs when there are too many for the popover's width.
                ViewThatFits(in: .horizontal) {
                    tabs(current: current)
                    tabs(current: current)
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(width: panel.width)
                Divider()
            }
            if let current = panel.current {
                panel.panel(for: current)
                    .id(current)
            }
        }
        .environment(\.panelWidth, panel.sections.count > 1 ? panel.width : nil)
    }

    private func tabs(current: SectionID) -> some View {
        Picker("Section", selection: Binding(get: { current }, set: { panel.select($0) })) {
            ForEach(panel.sections, id: \.self) { section in
                Text(panel.title(for: section)).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
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
        destination = everythingHidden ? .menuBar : .general
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
}

enum AppSymbols {
    /// BriefBar's own symbol, in the menu bar and in Settings.
    static let app = "rectangle.stack"
}
