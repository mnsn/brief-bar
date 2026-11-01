using System.Collections.ObjectModel;

namespace BriefBar.ViewModels;

/// Brings a list on screen up to date in place: it keeps the items that are still there, so a list keeps its scroll
/// position and focus as a source updates it, and moves, adds and removes only what changed.
internal static class CollectionSync
{
    public static void Sync<TItem, TValue>(
        ObservableCollection<TItem> items,
        IReadOnlyList<TValue> values,
        Func<TItem, TValue, bool> matches,
        Func<TValue, TItem> create,
        Action<TItem, TValue> update)
    {
        ArgumentNullException.ThrowIfNull(argument: items);
        ArgumentNullException.ThrowIfNull(argument: values);
        for (var index = 0; index < values.Count; index++)
        {
            var value = values[index];
            var existing = IndexOf(items: items, value: value, matches: matches, from: index);
            if (existing < 0)
            {
                items.Insert(index: index, item: create(arg: value));
                continue;
            }
            if (existing != index)
            {
                items.Move(oldIndex: existing, newIndex: index);
            }
            update(arg1: items[index], arg2: value);
        }
        while (items.Count > values.Count)
        {
            items.RemoveAt(index: items.Count - 1);
        }
    }

    static int IndexOf<TItem, TValue>(ObservableCollection<TItem> items, TValue value, Func<TItem, TValue, bool> matches, int from)
    {
        for (var index = from; index < items.Count; index++)
        {
            if (matches(arg1: items[index], arg2: value))
            {
                return index;
            }
        }
        return -1;
    }
}
