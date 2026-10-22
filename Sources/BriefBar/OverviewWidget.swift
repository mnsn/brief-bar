import AppKit
import BriefBarCore
import BriefBarUI
import SwiftUI

/// The Overview widget on the desktop: every source's counts by state, the brief's first line, and the newest of what
/// needs you, each opening its thing. It covers every source that's on, whatever widgets the layout has, and starts
/// hidden (`OverviewWidgetOptions`).
@MainActor
final class OverviewWidgetHost {
    private let content: OverviewWidgetContent
    private let controller: DesktopWidgetController
    private unowned let model: AppModel
    /// The sections it shows on screen: none while it's hidden or covered by windows.
    private var visible: [SectionID] = []

    init(model: AppModel) {
        self.model = model
        let content = OverviewWidgetContent(model: model)
        self.content = content
        // The demo's widget goes where new ones do, and never moves yours.
        controller = DesktopWidgetController(
            autosaveName: model.services.isDemo ? nil : "BriefBar.widget.overview", title: "BriefBar Overview"
        ) {
            AnyView(OverviewWidgetView(content: content, list: content.list, writer: model.briefWriter)
                .environmentObject(model.services)
                .environmentObject(model.services.loginItem))
        }
        controller.onScreenChanged = { [weak self] _ in self?.updateVisible() }
    }

    func update(sections: [SectionID], options: OverviewWidgetOptions) {
        content.options = options
        content.list.update(sections: sections)
        controller.update(show: true, placement: options.placement, size: content.size)
        updateVisible()
    }

    func close() {
        controller.close()
        updateVisible()
    }

    /// Tells the sources which sections it shows on screen, and reads them only then.
    private func updateVisible() {
        content.list.isShowing = controller.isOnScreen
        let sections = controller.isOnScreen ? content.list.sections : []
        let viewer = SectionViewer(.widget, id: "overview")
        let gone = visible.filter { !sections.contains($0) }
        let added = sections.filter { !visible.contains($0) }
        visible = sections
        for section in gone { model.source(for: section)?.sectionVisibilityChanged(section, isShowing: false, by: viewer) }
        for section in added { model.source(for: section)?.sectionVisibilityChanged(section, isShowing: true, by: viewer) }
    }
}

/// What the Overview widget shows, for its view.
@MainActor
final class OverviewWidgetContent: ObservableObject {
    @Published var options = OverviewWidgetOptions()
    /// It never asks Apple Intelligence to word the brief: it's always there. It shows what a list or a window had worded.
    let list: StateListModel
    unowned let model: AppModel

    static let headerHeight: CGFloat = 36
    static let briefHeight: CGFloat = 40
    static let rowHeight: CGFloat = 24
    static let bottomPadding: CGFloat = 10

    init(model: AppModel) {
        self.model = model
        list = StateListModel(model: model, wordsBrief: false)
    }

    var size: CGSize {
        let rows = CGFloat(options.size.rows)
        return CGSize(
            width: options.size == .compact ? 300 : 340,
            height: Self.headerHeight + Self.briefHeight + (rows + 1) * Self.rowHeight + Self.bottomPadding
        )
    }
}

struct OverviewWidgetView: View {
    @ObservedObject var content: OverviewWidgetContent
    @ObservedObject var list: StateListModel
    @ObservedObject var writer: BriefWriter

    private static let gradient = LinearGradient(
        colors: [Color(red: 0.98, green: 0.55, blue: 0.20), Color(red: 0.93, green: 0.30, blue: 0.55),
                 Color(red: 0.55, green: 0.35, blue: 0.95), Color(red: 0.25, green: 0.55, blue: 1.0)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    var body: some View {
        let size = content.size
        let lines = Briefing.widgetLines(list.lines, rows: content.options.size.rows)
        VStack(alignment: .leading, spacing: 0) {
            header
            if let first = lines.first {
                let text = writer.text(for: first)
                Button {
                    first.open()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if text.isWritten {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Self.gradient)
                        }
                        Text(text.text)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: OverviewWidgetContent.briefHeight, alignment: .topLeading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .help(text.isWritten ? "Written on this Mac by Apple Intelligence. Click to open it." : "Click to open it")
            }
            ForEach(lines.needsYou) { line in
                Button {
                    line.open()
                } label: {
                    HStack(spacing: 8) {
                        mark(line.source)
                        Text(writer.text(for: line).text)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .frame(height: OverviewWidgetContent.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .help(writer.text(for: line).text)
            }
            if lines.more > 0 {
                Text("\(lines.more) more need you")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(height: OverviewWidgetContent.rowHeight)
                    .padding(.horizontal, 14)
            }
            if list.groups.isEmpty {
                Text(list.sections.isEmpty ? "Turn on a source to see it here" : "Nothing needs you")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
        }
        .padding(.bottom, OverviewWidgetContent.bottomPadding)
        .frame(width: size.width, height: size.height, alignment: .top)
        .contextMenu {
            OverviewWidgetMenu(content: content)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: AppSymbols.app)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Overview")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            ForEach(list.groups) { group in
                HStack(spacing: 2) {
                    Image(systemName: group.state.symbol)
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(group.entries.count)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(group.state.color)
                .help("\(group.state.title): \(group.entries.count)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(group.state.title): \(group.entries.count)")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: OverviewWidgetContent.headerHeight)
    }

    /// Which source a line is from: its symbol, in its color.
    private func mark(_ id: SourceID) -> some View {
        let source = content.model.source(id)
        return Image(systemName: source?.symbol ?? "circle")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(source?.sections.first?.tint ?? .secondary)
            .frame(width: 14)
            .help(source?.name ?? "")
            .accessibilityLabel(source?.name ?? "")
    }
}

/// The Overview widget's context menu: where it sits and how big it is, each source's own items, and BriefBar's.
struct OverviewWidgetMenu: View {
    @ObservedObject var content: OverviewWidgetContent

    var body: some View {
        let model = content.model
        Picker("Widget Position", selection: Binding(
            get: { content.options.placement },
            set: { placement in
                var options = model.overviewWidgetOptions
                options.placement = placement
                model.setOverviewWidget(options)
            }
        )) {
            ForEach(WidgetPlacement.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        Picker("Widget Size", selection: Binding(
            get: { content.options.size },
            set: { size in
                var options = model.overviewWidgetOptions
                options.size = size
                model.setOverviewWidget(options)
            }
        )) {
            ForEach(WidgetSize.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        Divider()
        SourceMenuItems(parts: model.sourceParts(of: content.list.sections))
        Divider()
        Button("Arrange Widgets…") { model.openSettings(.layout(.widgets)) }
        Button("Hide This Widget") {
            var options = model.overviewWidgetOptions
            options.isShown = false
            model.setOverviewWidget(options)
        }
        Divider()
        AppMenuItems(source: nil)
    }
}
