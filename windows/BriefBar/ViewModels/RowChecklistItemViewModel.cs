using BriefBar.Core;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.ViewModels;

/// One thing on a row's checklist: its icon, in its state's color, and its words, quiet once it's done or on a quiet row.
public sealed record RowChecklistItemViewModel(IconKey Icon, Brush IconBrush, string Label, bool IsQuiet)
{
    public bool IsNotQuiet => !IsQuiet;
}
