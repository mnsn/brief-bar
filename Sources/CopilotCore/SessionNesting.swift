import Foundation

/// Sessions under the sessions that started them, as the Copilot app's sidebar nests them (`SessionMeta.parentSessionId`),
/// within each of the list's groups.
public enum SessionNesting {
    /// The snapshots, with each session whose parent is in its group right under it, one level deeper.
    ///
    /// A family, a session and those nested under it, takes the place of its member that sorts first, so that Needs You
    /// still starts with the longest wait. In it, a parent comes first, then its children, in the group's order. A
    /// session whose parent is in another group stays where it was. Every session whose parent is listed, in any group,
    /// knows it (`parent`), so a row that isn't nested under it can name it. Nothing is added or left out.
    /// - Parameters:
    ///   - snapshots: sorted, as `SessionOrdering` sorts them.
    ///   - records: what the snapshots were resolved from, with the same IDs.
    public static func nest(_ snapshots: [SessionSnapshot], records: [SessionRecord]) -> [SessionSnapshot] {
        var parents: [String: String] = [:]
        for record in records {
            if let parent = record.meta.parentSessionId, parent != record.id, parents[record.id] == nil {
                parents[record.id] = parent
            }
        }
        guard !parents.isEmpty else { return snapshots }
        let byId = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard byId.count == snapshots.count else { return snapshots }

        var groups: [[SessionSnapshot]] = []
        for snapshot in snapshots {
            if let last = groups.last?.last, last.phase == snapshot.phase {
                groups[groups.count - 1].append(snapshot)
            } else {
                groups.append([snapshot])
            }
        }
        return groups.flatMap { group in
            nested(group, parents: parents).map { snapshot, depth in
                var snapshot = snapshot
                snapshot.depth = depth
                if let parent = parents[snapshot.id].flatMap({ byId[$0] }) {
                    snapshot.parent = RelatedSession(id: parent.id, name: parent.displayName)
                }
                return snapshot
            }
        }
    }

    /// One group's sessions, each with how deep it's nested.
    private static func nested(_ group: [SessionSnapshot], parents: [String: String]) -> [(SessionSnapshot, Int)] {
        let position = Dictionary(uniqueKeysWithValues: group.enumerated().map { ($1.id, $0) })

        // The parent each one has in the group.
        var up: [String: String] = [:]
        for snapshot in group {
            if let parent = parents[snapshot.id], position[parent] != nil {
                up[snapshot.id] = parent
            }
        }
        // Sessions recorded as each other's parents, which the app shouldn't allow, would all be left out: the one that
        // sorts first heads them instead.
        for snapshot in group {
            var path = [snapshot.id]
            var current = snapshot.id
            while let next = up[current] {
                if let start = path.firstIndex(of: next) {
                    let head = path[start...].min { position[$0, default: 0] < position[$1, default: 0] } ?? next
                    up[head] = nil
                    break
                }
                path.append(next)
                current = next
            }
        }

        var children: [String: [String]] = [:]
        for snapshot in group {
            if let parent = up[snapshot.id] {
                children[parent, default: []].append(snapshot.id)
            }
        }
        // Where each family goes: its first member's place.
        var places: [String: Int] = [:]
        func place(of id: String) -> Int {
            if let known = places[id] { return known }
            let first = (children[id] ?? []).map(place(of:)).reduce(position[id, default: 0], min)
            places[id] = first
            return first
        }

        var ordered: [(SessionSnapshot, Int)] = []
        func add(_ id: String, depth: Int) {
            guard let index = position[id] else { return }
            ordered.append((group[index], depth))
            for child in (children[id] ?? []).sorted(by: { place(of: $0) < place(of: $1) }) {
                add(child, depth: depth + 1)
            }
        }
        for root in group.map(\.id).filter({ up[$0] == nil }).sorted(by: { place(of: $0) < place(of: $1) }) {
            add(root, depth: 0)
        }
        return ordered
    }
}
