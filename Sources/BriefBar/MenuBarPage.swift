import BriefBarCore
import BriefBarUI
import SwiftUI

/// Settings › Menu Bar: which sections share a menu-bar item.
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
    }

    var body: some View {
        let items = model.visibleItems()
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "menubar.rectangle")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Menu Bar")
                        .font(.title2.weight(.semibold))
                    Text("Which sections share a menu-bar item")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Each section starts with a menu-bar item of its own. Put sections together to show their counts side by side in one item, whose list has a tab for each. To move items in the menu bar, hold ⌘ and drag them.")
                .fixedSize(horizontal: false, vertical: true)

            if items.isEmpty {
                Text("Turn on a source to see its sections here.")
                    .foregroundStyle(.secondary)
            } else {
                Form {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Section(items.count > 1 ? "Item \(index + 1), from the left" : "Item") {
                            ForEach(item.sections, id: \.self) { section in
                                Picker(name(of: section), selection: placement(of: section, in: item, items: items)) {
                                    if item.sections.count > 1 {
                                        Text("With \(names(item.sections.filter { $0 != section }))").tag(Placement.current)
                                    }
                                    Text("On Its Own").tag(Placement.own)
                                    ForEach(items.filter { $0.id != item.id }) { other in
                                        Text("With \(names(other.sections))").tag(Placement.with(other.id))
                                    }
                                }
                            }
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

    private func placement(of section: SectionID, in item: MenuBarLayout.Item, items: [MenuBarLayout.Item]) -> Binding<Placement> {
        Binding {
            item.sections.count > 1 ? .current : .own
        } set: { placement in
            switch placement {
            case .current:
                break
            case .own:
                model.separate(section)
            case .with(let id):
                if let other = items.first(where: { $0.id == id })?.sections.first {
                    model.combine(section, with: other)
                }
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
