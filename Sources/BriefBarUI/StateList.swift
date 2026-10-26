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
    package enum Completion: String {
        case ready, finished
    }

    package var state: ItemState
    package var entries: [StateListEntry]
    package var completion: Completion?

    package var id: String { completion.map { "\(state.rawValue).\($0.rawValue)" } ?? state.rawValue }
    package var title: String {
        switch completion {
        case .ready: "Ready to Merge"
        case .finished: "Finished"
        case nil: state.title
        }
    }
    package var countLabel: String {
        switch completion {
        case .ready: "ready to merge"
        case .finished: "finished"
        case nil: state.countLabel
        }
    }
    package var symbol: String { completion == .ready ? "arrow.triangle.merge" : state.symbol }
}

package enum StateList {
    /// The rows by state, in the states' order: needs you, something's wrong, running, then done or ready. In each,
    /// the newest first, then those with no date, each in the order they came in; states without rows are left out.
    package static func groups(_ entries: [StateListEntry], separateReady: Bool = false) -> [StateListGroup] {
        ItemState.allCases.flatMap { state -> [StateListGroup] in
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
            guard !rows.isEmpty else { return [] }
            if separateReady, state == .done {
                return [StateListGroup.Completion.ready, .finished].compactMap { completion in
                    let matching = rows.filter { $0.row.isReady == (completion == .ready) }
                    return matching.isEmpty ? nil : StateListGroup(state: state, entries: matching, completion: completion)
                }
            }
            return [StateListGroup(state: state, entries: rows)]
        }
    }
}
