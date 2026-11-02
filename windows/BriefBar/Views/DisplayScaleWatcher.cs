using Microsoft.UI.Xaml;

namespace BriefBar.Views;

/// Tells an element's owner the scale of the display the element is on (1 at 100%, 1.5 at 150%) when it loads and
/// whenever that changes, as when a bar takes over another display or the panel opens on one, so that an icon can show
/// the drawing made for the pixels it covers there.
internal sealed class DisplayScaleWatcher
{
    readonly FrameworkElement element;
    readonly Action<double> scaleChanged;
    /// The content of the window the element is in, while it's loaded.
    XamlRoot? watched;

    public DisplayScaleWatcher(FrameworkElement element, Action<double> scaleChanged)
    {
        ArgumentNullException.ThrowIfNull(argument: element);
        ArgumentNullException.ThrowIfNull(argument: scaleChanged);
        this.element = element;
        this.scaleChanged = scaleChanged;
        element.Loaded += OnLoaded;
        element.Unloaded += OnUnloaded;
    }

    /// The scale of the display the element was last on: 1 until it's first loaded.
    public double Scale { get; private set; } = 1;

    void OnLoaded(object sender, RoutedEventArgs args)
    {
        Watch(root: element.XamlRoot);
        Update();
    }

    void OnUnloaded(object sender, RoutedEventArgs args)
    {
        // A list can load an element again, elsewhere in it, before it says it unloaded it.
        if (!element.IsLoaded)
        {
            Watch(root: null);
        }
    }

    void OnRootChanged(XamlRoot sender, XamlRootChangedEventArgs args) => Update();

    void Watch(XamlRoot? root)
    {
        if (watched == root)
        {
            return;
        }
        if (watched is not null)
        {
            watched.Changed -= OnRootChanged;
        }
        watched = root;
        if (watched is not null)
        {
            watched.Changed += OnRootChanged;
        }
    }

    void Update()
    {
        if (watched is null || watched.RasterizationScale == Scale)
        {
            return;
        }
        Scale = watched.RasterizationScale;
        scaleChanged(obj: Scale);
    }
}
