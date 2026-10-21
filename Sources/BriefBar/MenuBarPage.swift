import BriefBarCore
import BriefBarUI
import SwiftUI

/// Settings › Menu Bar: which sections show, and which share a menu-bar item.
struct MenuBarPage: View {
    @ObservedObject var model: AppModel

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
        let items = model.visibleItems()
        let hidden = model.hiddenSections
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "menubar.rectangle")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Menu Bar")
                        .font(.title2.weight(.semibold))
                    Text("Which sections show, and which share a menu-bar item")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Each section starts with a menu-bar item of its own. Put sections together to show their counts side by side in one item, whose list has a tab for each, and hide the ones you don't need. To move items in the menu bar, hold ⌘ and drag them.")
                .fixedSize(horizontal: false, vertical: true)

            if items.isEmpty && hidden.isEmpty {
                Text("Turn on a source to see its sections here.")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Put All in One Item") { model.combineAll() }
                        .disabled(items.count < 2)
                        .help("Every section in one menu-bar item, including those of sources you turn on later")
                    Button("Give Each Its Own Item") { model.separateAll() }
                        .disabled(!items.contains { $0.sections.count > 1 })
                }
                Form {
                    ForEach(items) { item in
                        if item.sections.count > 1 {
                            Section("Together in one item") {
                                ForEach(item.sections, id: \.self) { section in
                                    picker(for: section, in: item, items: items)
                                }
                            }
                        } else {
                            Section {
                                picker(for: item.sections[0], in: item, items: items)
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
                            Text("A hidden section's source stays on, with its notifications and widget. To stop it reading, turn it off.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Where `section` shows: in `item`, or nowhere when that's nil.
    private func picker(for section: SectionID, in item: MenuBarLayout.Item?, items: [MenuBarLayout.Item]) -> some View {
        Picker(name(of: section), selection: placement(of: section, in: item, items: items)) {
            if let item, item.sections.count > 1 {
                Text("With \(names(item.sections.filter { $0 != section }))").tag(Placement.current)
            }
            Text("On Its Own").tag(Placement.own)
            ForEach(items.filter { $0.id != item?.id }) { other in
                Text("With \(names(other.sections))").tag(Placement.with(other.id))
            }
            Divider()
            Text("Hidden").tag(Placement.hidden)
        }
    }

    private func placement(of section: SectionID, in item: MenuBarLayout.Item?, items: [MenuBarLayout.Item]) -> Binding<Placement> {
        let current: Placement = item.map { $0.sections.count > 1 ? .current : .own } ?? .hidden
        return Binding {
            current
        } set: { placement in
            guard placement != current else { return }
            switch placement {
            case .current:
                break
            case .own:
                model.separate(section)
            case .with(let id):
                if let other = items.first(where: { $0.id == id })?.sections.first {
                    model.combine(section, with: other)
                }
            case .hidden:
                model.hide(section)
            }
        }
    }

    private func name(of section: SectionID) -> String {
        guard let source = model.source(for: section) else { return section.rawValue }
        let title = source.sections.first { $0.id == section }?.title ?? section.rawValue
        return source.sections.count > 1 ? "\(source.name): \(title)" : source.name
    }

    private func names(_ sections: [SectionID]) -> String {
        ListFormatter.localizedString(byJoining: sections.map(name(of:)))
    }
}
