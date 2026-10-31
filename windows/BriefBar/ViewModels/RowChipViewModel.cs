using BriefBar.Core;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.ViewModels;

/// A chip on a row, for what it's linked to.
public sealed record RowChipViewModel(string Text, IconKey Icon, Brush Background, Brush Foreground);
