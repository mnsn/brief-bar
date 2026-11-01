namespace BriefBar.Core.Copilot;

/// Sessions under the sessions that started them, as the Copilot app's sidebar nests them (`SessionMeta.ParentSessionId`),
/// within each of the list's groups. The Mac's `SessionNesting`.
public static class SessionNesting
{
    /// The snapshots, with each session whose parent is in its group right under it, one level deeper.
    ///
    /// A family, a session and those nested under it, takes the place of its member that sorts first, so that Needs you
    /// still starts with the longest wait. In it, a parent comes first, then its children, in the group's order. A session
    /// whose parent is in another group stays where it was. Every session whose parent is listed, in any group, knows it
    /// (`Parent`), so a row that isn't nested under it can name it. Nothing is added or left out.
    /// - `snapshots`: sorted, as `SessionOrdering` sorts them.
    /// - `records`: what the snapshots were resolved from, with the same IDs.
    public static List<SessionSnapshot> Nest(IReadOnlyList<SessionSnapshot> snapshots, IReadOnlyList<SessionRecord> records)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshots);
        ArgumentNullException.ThrowIfNull(argument: records);
        var parents = new Dictionary<string, string>(comparer: StringComparer.Ordinal);
        foreach (var record in records)
        {
            if (record.Meta.ParentSessionId is { } parent && parent != record.Id)
            {
                parents.TryAdd(key: record.Id, value: parent);
            }
        }
        if (parents.Count == 0)
        {
            return [.. snapshots];
        }
        var byId = new Dictionary<string, SessionSnapshot>(comparer: StringComparer.Ordinal);
        foreach (var snapshot in snapshots)
        {
            byId.TryAdd(key: snapshot.Id, value: snapshot);
        }
        if (byId.Count != snapshots.Count)
        {
            return [.. snapshots];
        }

        var groups = new List<List<SessionSnapshot>>();
        foreach (var snapshot in snapshots)
        {
            if (groups.Count > 0 && groups[^1][^1].Phase == snapshot.Phase)
            {
                groups[^1].Add(item: snapshot);
            }
            else
            {
                groups.Add(item: [snapshot]);
            }
        }
        return groups.SelectMany(selector: group => Nested(group: group, parents: parents).Select(selector: entry =>
        {
            var parent = parents.TryGetValue(key: entry.Snapshot.Id, value: out var parentId) ? byId.GetValueOrDefault(key: parentId) : null;
            return entry.Snapshot with
            {
                Depth = entry.Depth,
                Parent = parent is null ? entry.Snapshot.Parent : new RelatedSession(Id: parent.Id, Name: parent.DisplayName),
            };
        })).ToList();
    }

    /// One group's sessions, each with how deep it's nested.
    static List<(SessionSnapshot Snapshot, int Depth)> Nested(List<SessionSnapshot> group, Dictionary<string, string> parents)
    {
        var position = new Dictionary<string, int>(comparer: StringComparer.Ordinal);
        for (var index = 0; index < group.Count; index++)
        {
            position[group[index].Id] = index;
        }

        // The parent each one has in the group.
        var up = new Dictionary<string, string>(comparer: StringComparer.Ordinal);
        foreach (var snapshot in group)
        {
            if (parents.TryGetValue(key: snapshot.Id, value: out var parent) && position.ContainsKey(key: parent))
            {
                up[snapshot.Id] = parent;
            }
        }
        // Sessions recorded as each other's parents, which the app shouldn't allow, would all be left out: the one that
        // sorts first heads them instead.
        foreach (var snapshot in group)
        {
            var path = new List<string> { snapshot.Id };
            var current = snapshot.Id;
            while (up.TryGetValue(key: current, value: out var next))
            {
                var start = path.IndexOf(item: next);
                if (start >= 0)
                {
                    var head = path.Skip(count: start).MinBy(keySelector: id => position.GetValueOrDefault(key: id)) ?? next;
                    up.Remove(key: head);
                    break;
                }
                path.Add(item: next);
                current = next;
            }
        }

        var children = new Dictionary<string, List<string>>(comparer: StringComparer.Ordinal);
        foreach (var snapshot in group)
        {
            if (up.TryGetValue(key: snapshot.Id, value: out var parent))
            {
                if (!children.TryGetValue(key: parent, value: out var list))
                {
                    list = [];
                    children[parent] = list;
                }
                list.Add(item: snapshot.Id);
            }
        }
        // Where each family goes: its first member's place.
        var places = new Dictionary<string, int>(comparer: StringComparer.Ordinal);
        int Place(string id)
        {
            if (places.TryGetValue(key: id, value: out var known))
            {
                return known;
            }
            var first = (children.GetValueOrDefault(key: id) ?? []).Select(selector: Place).Prepend(element: position.GetValueOrDefault(key: id)).Min();
            places[id] = first;
            return first;
        }

        var ordered = new List<(SessionSnapshot Snapshot, int Depth)>();
        void Add(string id, int depth)
        {
            if (!position.TryGetValue(key: id, value: out var index))
            {
                return;
            }
            ordered.Add(item: (group[index], depth));
            foreach (var child in (children.GetValueOrDefault(key: id) ?? []).OrderBy(keySelector: Place))
            {
                Add(id: child, depth: depth + 1);
            }
        }
        foreach (var root in group.Select(selector: snapshot => snapshot.Id).Where(predicate: id => !up.ContainsKey(key: id)).OrderBy(keySelector: Place))
        {
            Add(id: root, depth: 0);
        }
        return ordered;
    }
}
