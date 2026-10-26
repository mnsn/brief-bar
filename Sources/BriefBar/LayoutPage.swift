import AppKit
import BriefBarCore
import BriefBarUI
import Combine
import SwiftUI

/// Settings › Menu Bar, Widgets and Windows: a card for each item, with a chip for each section it shows. Drag a chip
/// onto another card to put them together, onto New Item to give it one of its own, or onto Hidden; or right-click it.
struct LayoutPage: View {
    @ObservedObject var model: AppModel
    let surface: Surface

    /// Where a chip you're dragging would go.
    @LocalState private var target: DropTarget?

    private enum DropTarget: Hashable {
        /// The item with this ID.
        case item(String)
        case newItem
        case hidden
    }

    var body: some View {
        let items = model.visibleItems(surface)
        let hidden = model.hiddenSections(surface)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: surface.symbol)
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(surface.title)
                        .font(.title2.weight(.semibold))
                    Text(surface.subtitle)
                        .foregroundStyle(.secondary)
                }
            }
            Text(surface.explanation)
                .fixedSize(horizontal: false, vertical: true)

            if surface == .menuBar && !items.isEmpty {
                MenuBarLine(model: model)
            }

            if surface == .widgets {
                overviewWidget
            }

            if items.isEmpty && hidden.isEmpty {
                Text("Turn on a source to see its sections here.")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Put All in One \(surface.itemNoun)") { model.combineAll(on: surface) }
                        .disabled(items.count < 2)
                        .help("Every section in one \(surface.itemNoun.lowercased()), including those of sources you turn on later")
                    Button("Give Each Its Own \(surface.itemNoun)") { model.separateAll(on: surface) }
                        .disabled(!items.contains { $0.sections.count > 1 })
                }
                Form {
                    ForEach(items) { item in
                        Section {
                            dropZone(.item(item.id), to: item.sections.first.map { .with($0) }) {
                                chips(item.sections, in: item, items: items)
                            }
                            itemOptions(item)
                        } header: {
                            if surface == .menuBar {
                                MenuBarPreview(model: model, sections: item.sections, options: model.options(forMenuBarItem: item.id))
                            }
                        }
                    }
                    Section {
                        newItemSlot(items: items, hidden: hidden)
                    }
                    Section {
                        dropZone(.hidden, to: .hidden) {
                            if hidden.isEmpty {
                                Text("Drop a \(surface.sectionNoun) here to hide it")
                                    .foregroundStyle(.secondary)
                                    .frame(minHeight: 26)
                            } else {
                                chips(hidden, in: nil, items: items)
                            }
                        }
                    } header: {
                        Text("Hidden")
                    } footer: {
                        note(surface.hiddenNote)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
            }

            let missing = model.sourcesMissing(from: surface)
            if !missing.isEmpty {
                note("\(ListFormatter.localizedString(byJoining: missing.map(\.name))) \(missing.count == 1 ? "has" : "have") nothing to show here.")
                    .padding(.horizontal, 4)
            }
        }
    }

    /// The Overview widget, apart from the layout's widgets, which each show sections.
    private var overviewWidget: some View {
        let options = model.overviewWidgetOptions
        let change = { (body: (inout OverviewWidgetOptions) -> Void) in
            var changed = options
            body(&changed)
            model.setOverviewWidget(changed)
        }
        return Form {
            Section {
                Toggle(isOn: Binding(get: { options.isShown }, set: { isShown in change { $0.isShown = isShown } })) {
                    Label {
                        Text("Overview")
                        Text("Every source's counts, the brief's first line and what needs you, in one widget. It starts hidden, since it can show your chats.")
                    } icon: {
                        Image(systemName: AppSymbols.app)
                    }
                }
                if options.isShown {
                    Picker("Position", selection: Binding(get: { options.placement }, set: { placement in change { $0.placement = placement } })) {
                        ForEach(WidgetPlacement.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Size", selection: Binding(get: { options.size }, set: { size in change { $0.size = size } })) {
                        ForEach(WidgetSize.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Chips

    /// A chip for each of `sections`, in rows: those of `item`, or the hidden ones for nil.
    private func chips(_ sections: [SectionID], in item: SectionLayout.Item?, items: [SectionLayout.Item]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(sections, id: \.self) { section in
                chip(section, in: item, items: items)
            }
        }
    }

    private func chip(_ section: SectionID, in item: SectionLayout.Item?, items: [SectionLayout.Item]) -> some View {
        let info = model.info(for: section)
        let label = SectionChip(title: shortName(of: section), symbol: info?.symbol ?? AppSymbols.app, tint: info?.tint ?? .gray)
        return label
            .draggable(section.rawValue) { label }
            .pointerStyle(.grabIdle)
            .contextMenu { moves(for: section, in: item, items: items) }
            .help("\(name(of: section))\nDrag it onto another \(surface.itemNoun.lowercased()), or right-click it")
            .accessibilityLabel(name(of: section))
            .accessibilityHint("Its menu moves it to another \(surface.itemNoun.lowercased()), or hides it")
    }

    /// What a chip's menu offers, as dragging it would: another item, one of its own, or hiding it.
    @ViewBuilder
    private func moves(for section: SectionID, in item: SectionLayout.Item?, items: [SectionLayout.Item]) -> some View {
        let others = items.filter { $0.id != item?.id }
        ForEach(others) { other in
            if let first = other.sections.first {
                Button("\(item == nil ? "Show in" : "Move to") \(surface.itemNoun) with \(together(other.sections))") {
                    move(section, to: .with(first))
                }
            }
        }
        if !others.isEmpty {
            Divider()
        }
        if let item {
            Button("Give It Its Own \(surface.itemNoun)") { move(section, to: .alone) }
                .disabled(item.sections.count == 1)
            Divider()
            Button("Hide") { move(section, to: .hidden) }
        } else {
            Button("Show in Its Own \(surface.itemNoun)") { move(section, to: .alone) }
        }
    }

    /// After the cards, the way to add one: drop a chip on New Item, or click it and pick a section, to give that
    /// section an item of its own. It stands in for any item you could add, so there are never empty cards; once
    /// every section has an item of its own, it says so.
    private func newItemSlot(items: [SectionLayout.Item], hidden: [SectionID]) -> some View {
        let sharing = items.filter { $0.sections.count > 1 }.flatMap(\.sections)
        let canMove = !sharing.isEmpty || !hidden.isEmpty
        return dropZone(.newItem, to: canMove ? .alone : nil) {
            Menu {
                if !sharing.isEmpty {
                    Section("With Others") {
                        ForEach(sharing, id: \.self) { section in
                            Button { move(section, to: .alone) } label: { menuLabel(of: section) }
                        }
                    }
                }
                if !hidden.isEmpty {
                    Section("Hidden") {
                        ForEach(hidden, id: \.self) { section in
                            Button { move(section, to: .alone) } label: { menuLabel(of: section) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canMove ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New \(surface.itemNoun)")
                            .foregroundStyle(canMove ? .primary : .secondary)
                        Text(canMove
                             ? "Drop a \(surface.sectionNoun) here, or click to choose one"
                             : "Every \(surface.sectionNoun) has \(surface.anItem) of its own")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(!canMove)
            .help(canMove
                  ? "Give a \(surface.sectionNoun) \(surface.anItem) of its own"
                  : "Every \(surface.sectionNoun) has \(surface.anItem) of its own")
        }
    }

    private func menuLabel(of section: SectionID) -> some View {
        Label(shortName(of: section), systemImage: model.info(for: section)?.symbol ?? AppSymbols.app)
    }

    /// Where chips can be dropped, highlighted while one is over it. Nil drops nothing.
    private func dropZone<Content: View>(
        _ zone: DropTarget, to destination: SectionDestination?, @ViewBuilder content: () -> Content
    ) -> some View {
        let isTargeted = destination != nil && target == zone
        return content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.14) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2)
            )
            .padding(-5)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { payload, _ in
                drop(payload, to: destination)
            } isTargeted: { isOver in
                if isOver {
                    target = zone
                } else if target == zone {
                    target = nil
                }
            }
    }

    private func drop(_ payload: [String], to destination: SectionDestination?) -> Bool {
        target = nil
        guard let destination, let raw = payload.first else { return false }
        let section = SectionID(rawValue: raw)
        // Only a section that can show here: not text dragged in from another app.
        guard model.sections(surface).contains(section) else { return false }
        move(section, to: destination)
        return true
    }

    private func move(_ section: SectionID, to destination: SectionDestination) {
        withAnimation {
            model.move(section, to: destination, on: surface)
        }
    }

    // MARK: An item's options

    /// How a menu-bar item shows several sections; a widget's position and size; a window's button to open it.
    @ViewBuilder
    private func itemOptions(_ item: SectionLayout.Item) -> some View {
        switch surface {
        case .menuBar:
            if item.sections.count > 1 {
                menuBarOptions(item)
            }
        case .widgets:
            let options = model.options(forWidget: item.id)
            Picker("Position", selection: Binding(
                get: { options.placement },
                set: { placement in
                    var changed = options
                    changed.placement = placement
                    model.setOptions(changed, forWidget: item.id)
                }
            )) {
                ForEach(WidgetPlacement.allCases) { Text($0.title).tag($0) }
            }
            Picker("Size", selection: Binding(
                get: { options.size },
                set: { size in
                    var changed = options
                    changed.size = size
                    model.setOptions(changed, forWidget: item.id)
                }
            )) {
                ForEach(WidgetSize.allCases) { Text($0.title).tag($0) }
            }
        case .windows:
            LabeledContent(item.sections.count > 1 ? "\(item.sections.count) pages" : "One page") {
                Button("Open") { model.openWindow(item: item.id) }
            }
        }
    }

    /// Side by side, or added up by state, with which states.
    @ViewBuilder
    private func menuBarOptions(_ item: SectionLayout.Item) -> some View {
        let options = model.options(forMenuBarItem: item.id)
        let change = { (body: (inout MenuBarItemOptions) -> Void) in
            var changed = options
            body(&changed)
            model.setOptions(changed, forMenuBarItem: item.id)
        }
        Picker(selection: Binding(get: { options.byState }, set: { byState in change { $0.byState = byState } })) {
            Text("Side by Side").tag(false)
            Text("Added Up").tag(true)
        } label: {
            Text("Counts")
            Text(options.byState
                 ? "One count for each state below, added up across its sections"
                 : "Each section's own symbol and counts, one after the other")
        }
        .pickerStyle(.segmented)
        if options.byState {
            ForEach(MenuBarItemOptions.order, id: \.self) { state in
                Toggle(isOn: Binding(
                    get: { options.states.contains(state) },
                    set: { on in change { if on { $0.states.insert(state) } else { $0.states.remove(state) } } }
                )) {
                    Label {
                        Text(state.title)
                        Text(state.explanation)
                    } icon: {
                        Image(systemName: state.symbol)
                            .foregroundStyle(state.color)
                    }
                }
            }
        }
        Picker("List", selection: Binding(get: { options.listByState }, set: { listByState in change { $0.listByState = listByState } })) {
            Text("A Tab for Each Section").tag(false)
            Text("Everything by State").tag(true)
        }
        .pickerStyle(.segmented)
        if options.listByState, let reason = OnDeviceModel.unavailableReason {
            note("The brief at the top of the list is in BriefBar's own words. \(reason)")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Names

    private func name(of section: SectionID) -> String {
        guard let source = model.source(for: section) else { return section.rawValue }
        let title = source.info(for: section)?.title ?? section.rawValue
        return source.sections.count > 1 ? "\(source.name): \(title)" : source.name
    }

    /// Such as "Group Chats", or a source's name when it has one section: short enough for a chip or a menu.
    private func shortName(of section: SectionID) -> String {
        guard let source = model.source(for: section) else { return section.rawValue }
        return source.sections.count > 1 ? (source.info(for: section)?.title ?? source.name) : source.name
    }

    /// "Azure DevOps", "Chats and Azure DevOps", or "Chats and 3 others", for a menu.
    private func together(_ sections: [SectionID]) -> String {
        let names = sections.map(shortName(of:))
        guard names.count > 2, let first = names.first else {
            return ListFormatter.localizedString(byJoining: names)
        }
        return "\(first) and \(names.count - 1) others"
    }
}

/// A section you can drag: its symbol on its color, as in a window's sidebar, and its name.
private struct SectionChip: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom))
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)
            Text(title)
                .lineLimit(1)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A menu-bar item's card's header: the item as it shows in the menu bar, with your counts as they are now.
private struct MenuBarPreview: View {
    let model: AppModel
    let sections: [SectionID]
    let options: MenuBarItemOptions

    var body: some View {
        LiveCounts(model: model, sections: sections) {
            MenuBarItemPicture(content: model.menuBarContent(sections: sections, options: options))
        }
        .padding(.horizontal, 5)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// BriefBar's items, left to right as they are in your menu bar, with your counts as they are now: how much room
/// they take, all together.
private struct MenuBarLine: View {
    @ObservedObject var model: AppModel

    @Environment(\.colorScheme) private var colorScheme

    private let spacing: CGFloat = 12

    var body: some View {
        let items = model.menuBarItemsInOrder()
        VStack(alignment: .leading, spacing: 6) {
            Text("In your menu bar now")
                .font(.callout)
                .foregroundStyle(.secondary)
            LiveCounts(model: model, sections: items.flatMap(\.sections)) {
                let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
                let contents = items.map { model.menuBarContent(sections: $0.sections, options: model.options(forMenuBarItem: $0.id)) }
                let pictures = contents.compactMap { MenuBarDrawing.image(of: $0, appearance: appearance) }
                let width = pictures.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(pictures.count - 1, 0))
                // Right-aligned, as in the menu bar, and smaller if they don't all fit.
                GeometryReader { proxy in
                    HStack(spacing: spacing) {
                        ForEach(pictures.indices, id: \.self) { index in
                            Image(nsImage: pictures[index])
                        }
                    }
                    .fixedSize()
                    .scaleEffect(min(1, proxy.size.width / max(width, 1)), anchor: .trailing)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
                }
                .frame(height: 22)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("In your menu bar now")
                .accessibilityValue(contents.map(\.summary).joined(separator: "\n"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// A menu-bar item, drawn as the menu bar draws it.
private struct MenuBarItemPicture: View {
    let content: MenuBarItemContent

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = MenuBarDrawing.image(of: content, appearance: NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)) {
            Image(nsImage: image)
                .help(content.summary)
                .accessibilityLabel("In the menu bar")
                .accessibilityValue(content.summary)
        }
    }
}

/// Draws `content` again whenever the counts of `sections` may have changed.
private struct LiveCounts<Content: View>: View {
    let model: AppModel
    let sections: [SectionID]
    @ViewBuilder let content: () -> Content

    /// Goes up when the sections' counts may have changed.
    @LocalState private var updates = 0

    var body: some View {
        let _ = updates
        content()
            // Subscribed once for these sections, not on every update: some sources send what they have as soon as
            // they're subscribed to, which would draw it again, and subscribe again, without end.
            .task(id: sections) { @MainActor in
                let changes = Publishers.MergeMany(model.sourceParts(of: sections).map { $0.source.segmentsChanged })
                for await _ in changes.values {
                    updates += 1
                }
            }
    }
}

/// Its subviews in rows, left to right, starting another row when the next one doesn't fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + rowHeight + spacing)
                rowHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}

extension Surface {
    var title: String {
        switch self {
        case .menuBar: return "Menu Bar"
        case .widgets: return "Widgets"
        case .windows: return "Windows"
        }
    }

    var symbol: String {
        switch self {
        case .menuBar: return "menubar.rectangle"
        case .widgets: return "rectangle.3.group"
        case .windows: return "macwindow"
        }
    }

    /// One of its items, in a button's title.
    var itemNoun: String {
        switch self {
        case .menuBar: return "Item"
        case .widgets: return "Widget"
        case .windows: return "Window"
        }
    }

    /// What it calls a section, in a sentence.
    var sectionNoun: String {
        self == .windows ? "page" : "section"
    }

    /// One of its items, in a sentence: "an item", "a widget", "a window".
    var anItem: String {
        switch self {
        case .menuBar: return "an item"
        case .widgets: return "a widget"
        case .windows: return "a window"
        }
    }

    var subtitle: String {
        switch self {
        case .menuBar: return "Which sections show, and which share a menu-bar item"
        case .widgets: return "Which sections show on your desktop, and which share a widget"
        case .windows: return "Which pages show, and which share a window"
        }
    }

    var explanation: String {
        switch self {
        case .menuBar:
            return "Each card is a menu-bar item. Drag a section onto another card to show them in one item, onto New Item to give it one of its own, or onto Hidden if you don't need it. To move items in the menu bar, hold ⌘ and drag them."
        case .widgets:
            return "Each card is a widget, which shows its sections one above the other, behind your windows or floating above them. Drag a section onto another card to put them in one widget, onto New Widget to give it one of its own, or onto Hidden; Teams' start hidden. Drag a widget by its header, and right-click it for its settings."
        case .windows:
            return "Each card is a window, with a page for each of its sections and a sidebar to switch between them. Every page starts in one window; drag a page onto New Window to keep it beside the others, or onto Hidden. Open a window from any list's gear menu, or from a widget."
        }
    }

    var hiddenNote: String {
        switch self {
        case .menuBar:
            return "A hidden section's source stays on, with its notifications and widget. To stop it reading, turn it off."
        case .widgets:
            return "A hidden section still shows in the menu bar and in windows."
        case .windows:
            return "A hidden page still shows in the menu bar and in widgets."
        }
    }
}
