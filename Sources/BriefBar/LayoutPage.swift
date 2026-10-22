import BriefBarCore
import BriefBarUI
import SwiftUI

/// Settings › Menu Bar, Widgets and Windows: which sections show there, and which share an item.
struct LayoutPage: View {
    @ObservedObject var model: AppModel
    let surface: Surface

    /// Where a section shows.
    private enum Placement: Hashable {
        /// In an item of its own.
        case own
        /// With the other sections of the item it's in.
        case current
        /// In another item, by ID.
        case with(String)
        /// Nowhere.
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
                            ForEach(item.sections, id: \.self) { section in
                                picker(for: section, in: item, items: items)
                            }
                            itemOptions(item)
                        } header: {
                            if let header = header(for: item) {
                                Text(header)
                            }
                        }
                    }
                    if !hidden.isEmpty {
                        Section {
                            ForEach(hidden, id: \.self) { section in
                                picker(for: section, in: nil, items: items)
                            }
                        } header: {
                            Text("Hidden")
                        } footer: {
                            note(surface.hiddenNote)
                        }
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

    /// What a picker calls the place that holds a section.
    private func header(for item: SectionLayout.Item) -> String? {
        switch surface {
        case .menuBar:
            return item.sections.count > 1 ? "Together in one item" : nil
        case .widgets, .windows:
            return item.sections.count > 1 ? "Together in one \(surface.itemNoun.lowercased())" : nil
        }
    }

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
                Button("Open") { model.openWindow(at: item.sections.first) }
            }
        }
    }

    /// Side by side, or added up by what they mean, with which states.
    @ViewBuilder
    private func menuBarOptions(_ item: SectionLayout.Item) -> some View {
        let options = model.options(forMenuBarItem: item.id)
        let change = { (body: (inout MenuBarItemOptions) -> Void) in
            var changed = options
            body(&changed)
            model.setOptions(changed, forMenuBarItem: item.id)
        }
        Picker("Counts", selection: Binding(get: { options.byState }, set: { byState in change { $0.byState = byState } })) {
            Text("Side by Side").tag(false)
            Text("By Meaning").tag(true)
        }
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
    }

    /// Where `section` shows: in `item`, or nowhere when that's nil.
    private func picker(for section: SectionID, in item: SectionLayout.Item?, items: [SectionLayout.Item]) -> some View {
        Picker(name(of: section), selection: placement(of: section, in: item, items: items)) {
            if let item, item.sections.count > 1 {
                Text("With \(together(item.sections.filter { $0 != section }))").tag(Placement.current)
            }
            Text("On Its Own").tag(Placement.own)
            ForEach(items.filter { $0.id != item?.id }) { other in
                Text("With \(together(other.sections))").tag(Placement.with(other.id))
            }
            Divider()
            Text("Hidden").tag(Placement.hidden)
        }
    }

    private func placement(of section: SectionID, in item: SectionLayout.Item?, items: [SectionLayout.Item]) -> Binding<Placement> {
        let current: Placement = item.map { $0.sections.count > 1 ? .current : .own } ?? .hidden
        return Binding {
            current
        } set: { placement in
            guard placement != current else { return }
            switch placement {
            case .current:
                break
            case .own:
                model.separate(section, on: surface)
            case .with(let id):
                if let other = items.first(where: { $0.id == id })?.sections.first {
                    model.combine(section, with: other, on: surface)
                }
            case .hidden:
                model.hide(section, on: surface)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func name(of section: SectionID) -> String {
        guard let source = model.source(for: section) else { return section.rawValue }
        let title = source.info(for: section)?.title ?? section.rawValue
        return source.sections.count > 1 ? "\(source.name): \(title)" : source.name
    }

    /// Such as "Group Chats", or a source's name when it has one section: short enough for a menu.
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
            return "Each section starts with a menu-bar item of its own. Put sections together in one item to show their counts side by side or added up by what they mean, with a tab for each in its list or everything in one list by state, and hide the ones you don't need. To move items in the menu bar, hold ⌘ and drag them."
        case .widgets:
            return "A widget shows its sections one above the other, behind your windows or floating above them. Each section starts with a widget of its own; Teams' start hidden. Drag a widget by its header, and right-click it for its settings."
        case .windows:
            return "A window has a page for each of its sections, with a sidebar to switch between them. Every page starts in one window; give a page a window of its own to keep it beside the others. Open a window from any list's gear menu, or from a widget."
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
