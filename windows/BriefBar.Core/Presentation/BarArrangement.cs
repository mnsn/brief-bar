namespace BriefBar.Core.Presentation;

/// Which bar window takes each display as displays change, so that no bar window closes while BriefBar runs: closing a
/// WinUI window while a UI Automation client, such as Narrator, holds on to it can crash BriefBar (windows/README.md).
/// A bar showing on a display just like one there now keeps it. Then each display left takes a window at its scaling,
/// so that the window's layout needn't change: a bar that showed elsewhere moves there, or else a spare shows again.
/// Then any window left takes a display left, as a new one would, changing its scaling as it shows. So there are never
/// more bar windows than the most displays there have been at once. Only a display left after all that gets a new
/// window, and a bar that showed and takes no display steps aside: hidden, holding no space, for a display that comes
/// back.
public sealed record BarArrangement(IReadOnlyList<int?> ForDisplays, IReadOnlyList<int> SteppingAside)
{
    /// `ForDisplays[i]` is the index in `candidates` of the window that takes `displays[i]`, or null for a new one.
    /// `SteppingAside` lists the indices of the candidates that showed and take no display.
    public static BarArrangement Plan(IReadOnlyList<BarCandidate> candidates, IReadOnlyList<DisplayShape> displays)
    {
        ArgumentNullException.ThrowIfNull(argument: candidates);
        ArgumentNullException.ThrowIfNull(argument: displays);
        var taken = new bool[candidates.Count];
        var forDisplays = new int?[displays.Count];
        for (var display = 0; display < displays.Count; display++)
        {
            var shape = displays[display];
            forDisplays[display] = Take(
                candidates: candidates,
                taken: taken,
                fits: candidate => candidate.IsShowing && candidate.Bounds == shape.Bounds && candidate.Dpi == shape.Dpi);
        }
        for (var display = 0; display < displays.Count; display++)
        {
            var dpi = displays[display].Dpi;
            forDisplays[display] ??= Take(candidates: candidates, taken: taken, fits: candidate => candidate.IsShowing && candidate.Dpi == dpi)
                ?? Take(candidates: candidates, taken: taken, fits: candidate => !candidate.IsShowing && candidate.Dpi == dpi);
        }
        for (var display = 0; display < displays.Count; display++)
        {
            forDisplays[display] ??= Take(candidates: candidates, taken: taken, fits: candidate => candidate.IsShowing)
                ?? Take(candidates: candidates, taken: taken, fits: candidate => !candidate.IsShowing);
        }
        var steppingAside = Enumerable.Range(start: 0, count: candidates.Count)
            .Where(predicate: index => candidates[index].IsShowing && !taken[index])
            .ToList();
        return new BarArrangement(ForDisplays: forDisplays, SteppingAside: steppingAside);
    }

    /// The first candidate not taken yet that `fits`, now taken; or null.
    static int? Take(IReadOnlyList<BarCandidate> candidates, bool[] taken, Func<BarCandidate, bool> fits)
    {
        for (var index = 0; index < candidates.Count; index++)
        {
            if (!taken[index] && fits(arg: candidates[index]))
            {
                taken[index] = true;
                return index;
            }
        }
        return null;
    }
}
