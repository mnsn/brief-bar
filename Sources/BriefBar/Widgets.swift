import AppKit
import BriefBarCore
import BriefBarUI
import SwiftUI

/// One desktop widget: its sections one above the other, at the widget's own position and size.
@MainActor
final class WidgetHost {
    let id: String
    private let content: WidgetContent
    private let controller: DesktopWidgetController
    private unowned let model: AppModel
    /// The sections the widget shows on screen: none while it's hidden or covered by windows.
    private var visible: [SectionID] = []

    init(id: String, model: AppModel) {
        self.id = id
        self.model = model
        let content = WidgetContent(id: id, model: model)
        self.content = content
        // The demo's widgets go where new ones do, and never move yours.
        controller = DesktopWidgetController(
            autosaveName: model.services.isDemo ? nil : "BriefBar.widget.\(id)",
            formerAutosaveName: WidgetMigration.formerAutosaveName(for: id),
            title: "BriefBar"
        ) {
            AnyView(WidgetView(content: content)
                .environmentObject(model.services)
                .environmentObject(model.services.loginItem))
        }
        controller.onScreenChanged = { [weak self] _ in self?.updateVisible() }
    }

    func update(sections: [SectionID], options: WidgetOptions) {
        content.sections = sections
        content.options = options
        controller.setTitle(content.title)
        controller.update(show: true, placement: options.placement, size: content.size)
        updateVisible()
    }

    func close() {
        controller.close()
        updateVisible()
    }

    /// Tells the sources which sections the widget shows on screen.
    private func updateVisible() {
        let sections = controller.isOnScreen ? content.sections : []
        let viewer = SectionViewer(.widget, id: id)
        let gone = visible.filter { !sections.contains($0) }
        let added = sections.filter { !visible.contains($0) }
        visible = sections
        for section in gone { model.source(for: section)?.sectionVisibilityChanged(section, isShowing: false, by: viewer) }
        for section in added { model.source(for: section)?.sectionVisibilityChanged(section, isShowing: true, by: viewer) }
    }
}

/// What a widget shows, for its view.
@MainActor
final class WidgetContent: ObservableObject {
    let id: String
    @Published var sections: [SectionID] = []
    @Published var options = WidgetOptions()
    unowned let model: AppModel

    static let bottomPadding: CGFloat = 10
    /// The line between two sections.
    static let dividerHeight: CGFloat = 1

    init(id: String, model: AppModel) {
        self.id = id
        self.model = model
    }

    /// Rows for each section: the size's rows, shared out when there are several sections.
    var rows: Int {
        options.size.rows(sharedBy: sections.count)
    }

    /// As wide as its widest section needs, and as tall as its sections together.
    var size: CGSize {
        let parts = sections.compactMap { section in model.source(for: section).map { (section, $0) } }
        let width = parts.map { $0.1.widgetWidth(for: $0.0, size: options.size) }.max() ?? 320
        let heights = parts.map { $0.1.widgetHeight(for: $0.0, rows: rows) }.reduce(0, +)
        let dividers = CGFloat(max(parts.count - 1, 0)) * Self.dividerHeight
        return CGSize(width: width, height: heights + dividers + Self.bottomPadding)
    }

    /// Such as "Azure DevOps and GitHub Copilot", for VoiceOver.
    var title: String {
        var names: [String] = []
        for section in sections {
            guard let source = model.source(for: section) else { continue }
            let name = source.sections.count > 1 ? (source.info(for: section)?.title ?? source.name) : source.name
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? "BriefBar" : ListFormatter.localizedString(byJoining: names)
    }
}

/// A desktop widget: each section's part, with a line between them.
struct WidgetView: View {
    @ObservedObject var content: WidgetContent

    var body: some View {
        let rows = content.rows
        let size = content.size
        VStack(spacing: 0) {
            ForEach(Array(content.sections.enumerated()), id: \.element) { index, section in
                if index > 0 {
                    Divider()
                        .padding(.horizontal, 12)
                }
                if let source = content.model.source(for: section) {
                    source.widget(for: section, size: content.options.size, rows: rows)
                        .environment(\.shownSection, section)
                }
            }
        }
        .padding(.bottom, WidgetContent.bottomPadding)
        .frame(width: size.width, height: size.height, alignment: .top)
        .contextMenu {
            WidgetMenu(content: content)
                .environment(\.shownSection, content.sections.first)
        }
    }
}

/// A widget's context menu: where it sits and how big it is, each of its sources' own items, and BriefBar's.
struct WidgetMenu: View {
    @ObservedObject var content: WidgetContent

    var body: some View {
        let model = content.model
        Picker("Widget Position", selection: Binding(
            get: { content.options.placement },
            set: { placement in
                var options = content.options
                options.placement = placement
                model.setOptions(options, forWidget: content.id)
            }
        )) {
            ForEach(WidgetPlacement.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        Picker("Widget Size", selection: Binding(
            get: { content.options.size },
            set: { size in
                var options = content.options
                options.size = size
                model.setOptions(options, forWidget: content.id)
            }
        )) {
            ForEach(WidgetSize.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        Divider()

        // Each source's own items: right here for one source, in a submenu each for several.
        let parts = content.model.sourceParts(of: content.sections)
        SourceMenuItems(parts: parts)
        Divider()
        Button("Arrange Widgets…") { model.openSettings(.layout(.widgets)) }
        Button("Hide This Widget") { model.hideItem(content.id, on: .widgets) }
        Divider()
        AppMenuItems(source: parts.count == 1 ? parts.first?.source.id : nil)
    }
}
