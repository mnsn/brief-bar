using System.Globalization;

namespace BriefBar.Core.Presentation;

/// The keys that show another of the bar's items in an open panel, as ⌘1 to ⌘9 show the Mac window's pages: Ctrl+1
/// the Overview, then Ctrl+2 to Ctrl+9 the bar's items in order, and none for an item past the ninth; Ctrl+Tab the next
/// item, and Ctrl+Shift+Tab the one before, around. A bar's targets are its items' in order, the Overview's first.
public static class PanelKeys
{
    /// The last number with a key.
    public const int LastNumber = 9;

    /// "Ctrl+2", the key for the item at `position` in its bar, the Overview's being 0; null past the ninth.
    public static string? Words(int position) => position is >= 0 and < LastNumber
        ? string.Create(provider: CultureInfo.InvariantCulture, handler: $"Ctrl+{position + 1}")
        : null;

    /// What Ctrl and `number` shows, from a bar's `targets`, or null when that bar has no item with that number.
    public static PanelTarget? Numbered(IReadOnlyList<PanelTarget> targets, int number)
    {
        ArgumentNullException.ThrowIfNull(argument: targets);
        return number is >= 1 and <= LastNumber && number <= targets.Count ? targets[number - 1] : null;
    }

    /// What Ctrl+Tab shows after `current`, or Ctrl+Shift+Tab before it for `backward`, from a bar's `targets`, around:
    /// the first, or the last, when `current` isn't among them, as when its source was turned off; null when there's
    /// nothing else to show.
    public static PanelTarget? Next(IReadOnlyList<PanelTarget> targets, PanelTarget current, bool backward)
    {
        ArgumentNullException.ThrowIfNull(argument: targets);
        var index = IndexOf(targets: targets, target: current);
        if (index < 0)
        {
            return targets.Count == 0 ? null : backward ? targets[^1] : targets[0];
        }
        if (targets.Count < 2)
        {
            return null;
        }
        var step = backward ? targets.Count - 1 : 1;
        return targets[(index + step) % targets.Count];
    }

    static int IndexOf(IReadOnlyList<PanelTarget> targets, PanelTarget target)
    {
        for (var index = 0; index < targets.Count; index++)
        {
            if (targets[index] == target)
            {
                return index;
            }
        }
        return -1;
    }
}
