import BriefBarCore
import Foundation

/// A row of a list by state, with the section it's from.
package struct StateListEntry: Identifiable {
    package var section: SectionID
    package var row: StateRow

    package init(section: SectionID, row: StateRow) {
        self.section = section
        self.row = row
    }

    package var id: String { "\(section.rawValue)/\(row.id)" }
}

/// One state's rows, in a list by state.
package struct StateListGroup: Identifiable {
    package var state: ItemState
    package var entries: [StateListEntry]

    package var id: ItemState { state }
}

package enum StateList {
    /// The rows by state, in the states' order: needs you, something's wrong, running, then done or ready. In each,
    /// the newest first, then those with no date, each in the order they came in; states without rows are left out.
    package static func groups(_ entries: [StateListEntry]) -> [StateListGroup] {
        ItemState.allCases.compactMap { state in
            let rows = entries.enumerated()
                .filter { $0.element.row.state == state }
                .sorted { lhs, rhs in
                    switch (lhs.element.row.date, rhs.element.row.date) {
                    case let (left?, right?) where left != right: return left > right
                    case (.some, nil): return true
                    case (nil, .some): return false
                    default: return lhs.offset < rhs.offset
                    }
                }
                .map(\.element)
            return rows.isEmpty ? nil : StateListGroup(state: state, entries: rows)
        }
    }
}
