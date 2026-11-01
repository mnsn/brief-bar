using System.Collections.Concurrent;
using BriefBar.Core;
using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using XamlPath = Microsoft.UI.Xaml.Shapes.Path;

namespace BriefBar.Views;

/// A Fluent icon, `Size` pixels square, filled with `Fill`. It's decoration: Narrator reads what's next to it.
public sealed partial class FluentIcon : Grid
{
    public static readonly DependencyProperty IconProperty = DependencyProperty.Register(
        name: nameof(Icon),
        propertyType: typeof(IconKey),
        ownerType: typeof(FluentIcon),
        typeMetadata: new PropertyMetadata(defaultValue: IconKey.Stack, propertyChangedCallback: OnIconChanged));

    public static readonly DependencyProperty SizeProperty = DependencyProperty.Register(
        name: nameof(Size),
        propertyType: typeof(double),
        ownerType: typeof(FluentIcon),
        typeMetadata: new PropertyMetadata(defaultValue: 16.0, propertyChangedCallback: OnSizeChanged));

    public static readonly DependencyProperty FillProperty = DependencyProperty.Register(
        name: nameof(Fill),
        propertyType: typeof(Brush),
        ownerType: typeof(FluentIcon),
        typeMetadata: new PropertyMetadata(defaultValue: null, propertyChangedCallback: OnFillChanged));

    /// Each icon's path data in XAML's syntax, converted once.
    static readonly ConcurrentDictionary<IconKey, string> xamlData = new();

    readonly Viewbox box = new();
    XamlPath? path;

    public FluentIcon()
    {
        IsHitTestVisible = false;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(
            element: this, value: Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        Children.Add(item: box);
        ApplySize();
        DrawIcon();
    }

    public IconKey Icon
    {
        get => (IconKey)GetValue(dp: IconProperty);
        set => SetValue(dp: IconProperty, value: value);
    }

    public double Size
    {
        get => (double)GetValue(dp: SizeProperty);
        set => SetValue(dp: SizeProperty, value: value);
    }

    public Brush? Fill
    {
        get => (Brush?)GetValue(dp: FillProperty);
        set => SetValue(dp: FillProperty, value: value);
    }

    static void OnIconChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) => ((FluentIcon)sender).DrawIcon();

    static void OnSizeChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) => ((FluentIcon)sender).ApplySize();

    static void OnFillChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args)
    {
        var icon = (FluentIcon)sender;
        if (icon.path is not null)
        {
            icon.path.Fill = icon.Fill;
        }
    }

    void ApplySize()
    {
        Width = Size;
        Height = Size;
        box.Width = Size;
        box.Height = Size;
    }

    void DrawIcon()
    {
        var drawing = IconPaths.Of(icon: Icon);
        var data = xamlData.GetOrAdd(key: Icon, valueFactory: _ => SvgPathData.ToXaml(svg: drawing.Svg, rule: drawing.Rule));
        path = (XamlPath)XamlReader.Load(
            xaml: $"<Path xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" Data=\"{data}\" />");
        path.Width = drawing.Size;
        path.Height = drawing.Size;
        path.Fill = Fill;
        box.Child = path;
    }
}
