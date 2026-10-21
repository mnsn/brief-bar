import AppKit
import BriefBarCore
import BriefBarUI
import SwiftUI

/// `--render <dir>`: draws, in light and dark, the menu bar with each item's list open, each source's other
/// pictures (such as its widget at each size), and the Settings window. Useful for checking layouts without
/// screen-recording permission, and for the README's pictures. With `--demo`, from made-up data.
@MainActor
enum Renderer {
    static func run(directory: String, demo: Bool) -> Int32 {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            fputs("Can't create \(directory): \(error.localizedDescription)\n", stderr)
            return 1
        }
        Snapshot.useOverlayScrollers()
        _ = NSApplication.shared

        // Never the app's own preferences: a copy of them, or the demo's.
        let model = AppModel(demo: demo, rendering: true)
        defer { UserDefaults.standard.removePersistentDomain(forName: AppModel.renderSuite) }
        let sources = model.onSources
        var loaded = false
        Task {
            for source in sources { await source.loadForRendering() }
            loaded = true
        }
        while !loaded {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        var written: [String] = []
        let items = model.visibleItems()
        // Examples, drawn from copies of the layout, so nothing is saved: Azure DevOps and Copilot sharing an
        // item, when both are on, and every section in one item.
        var combined = model.layout
        combined.place(model.onSections)
        combined.combine(.copilotSessions, with: .azureDevOpsPullRequests)
        let combinedItems = combined.visibleItems(showing: model.onSections)
        let combinedIndex = combinedItems.firstIndex { $0.sections.count > 1 }
        var all = model.layout
        all.combineAll(items.flatMap(\.sections))
        let allItems = all.visibleItems(showing: model.onSections)
        // The Menu Bar settings' example: Azure DevOps with Copilot, and Group Chats hidden.
        var example = combined
        example.hide(.teamsGroupChats)
        for dark in [false, true] {
            guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { continue }
            let suffix = dark ? "dark" : "light"
            func picture(of items: [MenuBarLayout.Item], pressed index: Int, at section: SectionID? = nil, name: String) {
                let segments = items.map { item in
                    item.sections.compactMap { section in model.source(for: section)?.segment(for: section) }
                }
                let panel = ItemPanelModel(model: model)
                panel.sections = items[index].sections
                panel.selected = section
                let view = ItemPanelView(panel: panel)
                    .environmentObject(model.services)
                    .environmentObject(model.services.loginItem)
                    .background(Color(nsColor: .windowBackgroundColor))
                if let image = Snapshot.render(view, appearance: appearance),
                   let picture = MenuBarPicture.draw(panel: image, items: segments, pressed: index, appearance: appearance),
                   let file = Snapshot.write(picture, to: output.appending(path: "\(name)-\(suffix).png")) {
                    written.append(file)
                }
            }
            for (index, item) in items.enumerated() {
                picture(of: items, pressed: index, name: "menubar-\(item.id)")
            }
            if let combinedIndex {
                picture(of: combinedItems, pressed: combinedIndex, name: "menubar-combined")
            }
            if allItems.count == 1, allItems[0].sections.count > 1 {
                // Opened at each tab, which all keep the widest panel's width.
                for section in allItems[0].sections {
                    picture(of: allItems, pressed: 0, at: section, name: "menubar-all-\(section.rawValue)")
                }
            }
            for source in sources {
                for rendering in source.extraRenderings() {
                    if let image = Snapshot.render(rendering.view, appearance: appearance),
                       let file = Snapshot.write(image, to: output.appending(path: "\(source.id.rawValue)-\(rendering.name)-\(suffix).png")) {
                        written.append(file)
                    }
                }
            }
            let pages: [(String, SettingsDestination)] = [("general", .general), ("menu-bar", .menuBar)]
                + model.sources.map { ($0.id.rawValue, .source($0.id)) }
            func page(_ destination: SettingsDestination, name: String) {
                let navigation = SettingsNavigation()
                navigation.destination = destination
                let view = SettingsView(model: model, navigation: navigation)
                    .environmentObject(model.services)
                    .environmentObject(model.services.loginItem)
                    .background(Color(nsColor: .windowBackgroundColor))
                if let image = Snapshot.render(view, appearance: appearance),
                   let file = Snapshot.write(image, to: output.appending(path: "settings-\(name)-\(suffix).png")) {
                    written.append(file)
                }
            }
            for (name, destination) in pages {
                page(destination, name: name)
            }
            let saved = model.layout
            model.useForRendering(example)
            page(.menuBar, name: "menu-bar-example")
            model.useForRendering(saved)
        }
        written.forEach { print($0) }
        return written.isEmpty ? 1 : 0
    }
}
