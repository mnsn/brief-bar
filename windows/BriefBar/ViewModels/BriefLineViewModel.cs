using Microsoft.UI.Xaml.Media;

namespace BriefBar.ViewModels;

/// One line of a panel's brief: a dot in its state's color, and its sentence.
public sealed class BriefLineViewModel : Observable
{
    public BriefLineViewModel(string id)
    {
        Id = id;
    }

    public string Id { get; }

    public string Sentence { get; set => Set(storage: ref field, value: value); } = string.Empty;

    public Brush DotBrush { get; set => Set(storage: ref field, value: value); } = null!;
}
