using Microsoft.UI.Xaml.Controls;

namespace BriefBar.Views;

/// What a source reads, where it connects and what it needs: on its page in Settings, before you turn it on, and later
/// under What it reads.
public sealed partial class SourceDescriptionView : UserControl
{
    public SourceDescriptionView(string reads, string network, string needs)
    {
        Reads = reads;
        Network = network;
        Needs = needs;
        InitializeComponent();
    }

    public string Reads { get; }

    public string Network { get; }

    public string Needs { get; }
}
