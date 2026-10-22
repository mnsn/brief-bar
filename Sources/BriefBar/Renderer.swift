import AppKit
import BriefBarCore
import BriefBarUI
import SwiftUI

/// `--render <dir>`: draws, in light and dark, the menu bar with each item's list open, the widgets, the window
/// at each page, each source's other pictures, and the Settings window. Useful for checking layouts without
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

        // Never the app's own preferences: a copy of them in memory, or the demo's.
        let model = AppModel(demo: demo, rendering: true)
        model.placeSections()
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
        func write(_ image: NSBitmapImageRep?, _ name: String) {
            if let image, let file = Snapshot.write(image, to: output.appending(path: "\(name).png")) {
                written.append(file)
            }
        }

        // Examples, drawn from copies of the layouts, so nothing is saved.
        let shown = model.sections(.menuBar)
        let items = model.visibleItems(.menuBar)
        // Azure DevOps and Copilot sharing an item, when both are on.
        var combined = model.layout(.menuBar)
        combined.place(shown)
        combined.combine(.copilotSessions, with: .azureDevOpsPullRequests)
        let combinedItems = combined.visibleItems(showing: shown)
        let combinedIndex = combinedItems.firstIndex { $0.sections.count > 1 }
        // Every section in one item, side by side, then added up by what they mean, as Settings suggests.
        var all = model.layout(.menuBar)
        all.combineAll(items.flatMap(\.sections))
        let allItems = all.visibleItems(showing: shown)
        let merged = allItems.first.map { [$0.id: MenuBarItemOptions(byState: true)] } ?? [:]
        // The Menu Bar settings' example: Azure DevOps with Copilot, and Group Chats hidden.
        var example = combined
        example.hide(.teamsGroupChats)
        // A widget for each section that has one, and one for all that show.
        let widgetSections = model.sections(.widgets)
        let shownWidgetSections = model.visibleItems(.widgets).flatMap(\.sections)
        let windowSections = model.sections(.windows)

        for dark in [false, true] {
            guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { continue }
            let suffix = dark ? "dark" : "light"

            func picture(
                of items: [SectionLayout.Item], pressed index: Int, at section: SectionID? = nil, name: String,
                options: [String: MenuBarItemOptions] = [:]
            ) {
                let contents = items.map { item in
                    model.menuBarContent(sections: item.sections, options: options[item.id] ?? model.options(forMenuBarItem: item.id))
                }
                let panel = ItemPanelModel(model: model)
                panel.sections = items[index].sections
                panel.selected = section
                let view = ItemPanelView(panel: panel)
                    .environmentObject(model.services)
                    .environmentObject(model.services.loginItem)
                    .background(Color(nsColor: .windowBackgroundColor))
                if let image = Snapshot.render(view, appearance: appearance) {
                    write(MenuBarPicture.draw(panel: image, items: contents, pressed: index, appearance: appearance), "\(name)-\(suffix)")
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
                picture(of: allItems, pressed: 0, name: "menubar-merged", options: merged)
            }

            func widget(_ sections: [SectionID], size: WidgetSize, name: String) {
                let content = WidgetContent(id: "render", model: model)
                content.sections = sections
                content.options = WidgetOptions(size: size)
                let view = WidgetView(content: content)
                    .environmentObject(model.services)
                    .environmentObject(model.services.loginItem)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(16)
                write(Snapshot.render(view, appearance: appearance), "\(name)-\(suffix)")
            }
            for size in WidgetSize.allCases {
                for section in widgetSections {
                    widget([section], size: size, name: "widget-\(section.rawValue)-\(size.rawValue)")
                }
                if shownWidgetSections.count > 1 {
                    widget(shownWidgetSections, size: size, name: "widget-all-\(size.rawValue)")
                }
            }

            // A window with one page: no sidebar.
            if let section = windowSections.first {
                let content = WindowContent(id: "render-alone", model: model)
                content.update(sections: [section])
                let view = WindowView(content: content)
                    .environment(\.isRendering, true)
                    .environmentObject(model.services)
                    .environmentObject(model.services.loginItem)
                    .frame(width: 560, height: 640)
                write(Snapshot.render(view, appearance: appearance), "window-alone-\(suffix)")
            }
            // One window with every page, open at each.
            if !windowSections.isEmpty {
                let content = WindowContent(id: "render", model: model)
                content.update(sections: windowSections)
                for section in windowSections {
                    content.select(section, notify: false)
                    let view = WindowView(content: content)
                        .environment(\.isRendering, true)
                        .environmentObject(model.services)
                        .environmentObject(model.services.loginItem)
                        .frame(width: 980, height: 680)
                    write(Snapshot.render(view, appearance: appearance), "window-\(section.rawValue)-\(suffix)")
                }
            }

            for source in sources {
                for rendering in source.extraRenderings() {
                    write(Snapshot.render(rendering.view, appearance: appearance), "\(source.id.rawValue)-\(rendering.name)-\(suffix)")
                }
            }

            func page(_ destination: SettingsDestination, name: String) {
                let navigation = SettingsNavigation()
                navigation.destination = destination
                let view = SettingsView(model: model, navigation: navigation)
                    .environmentObject(model.services)
                    .environmentObject(model.services.loginItem)
                    .background(Color(nsColor: .windowBackgroundColor))
                write(Snapshot.render(view, appearance: appearance), "settings-\(name)-\(suffix)")
            }
            let pages: [(String, SettingsDestination)] = [("general", .general)]
                + Surface.allCases.map { ($0.title.lowercased().replacingOccurrences(of: " ", with: "-"), .layout($0)) }
                + model.sources.map { ($0.id.rawValue, .source($0.id)) }
            for (name, destination) in pages {
                page(destination, name: name)
            }
            let saved = model.layout(.menuBar)
            let savedOptions = model.menuBarItemOptions
            model.useForRendering(example)
            page(.layout(.menuBar), name: "menu-bar-example")
            if allItems.count == 1, allItems[0].sections.count > 1 {
                model.useForRendering(all)
                model.useForRendering(merged)
                page(.layout(.menuBar), name: "menu-bar-merged")
            }
            model.useForRendering(saved)
            model.useForRendering(savedOptions)
        }
        written.forEach { print($0) }
        return written.isEmpty ? 1 : 0
    }
}
