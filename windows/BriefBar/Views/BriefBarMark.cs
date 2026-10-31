using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace BriefBar.Views;

/// BriefBar's mark, from its app icon: three lines of a brief, with dots in the colors of what needs you, what's
/// running and what's done.
public sealed partial class BriefBarMark : Grid
{
    public static readonly DependencyProperty NeedsYouBrushProperty = Register(name: nameof(NeedsYouBrush));
    public static readonly DependencyProperty RunningBrushProperty = Register(name: nameof(RunningBrush));
    public static readonly DependencyProperty DoneBrushProperty = Register(name: nameof(DoneBrush));
    public static readonly DependencyProperty LineBrushProperty = Register(name: nameof(LineBrush));

    readonly Ellipse[] dots = [new(), new(), new()];
    readonly Rectangle[] lines = [new(), new(), new()];

    public BriefBarMark()
    {
        IsHitTestVisible = false;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(
            element: this, value: Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        var canvas = new Canvas { Width = 16, Height = 16 };
        double[] lengths = [8.4, 6.4, 7.4];
        for (var index = 0; index < 3; index++)
        {
            var center = 3 + (index * 5);
            dots[index].Width = 3.8;
            dots[index].Height = 3.8;
            Canvas.SetLeft(element: dots[index], length: 0.6);
            Canvas.SetTop(element: dots[index], length: center - 1.9);
            lines[index].Width = lengths[index];
            lines[index].Height = 2.2;
            lines[index].RadiusX = 1.1;
            lines[index].RadiusY = 1.1;
            Canvas.SetLeft(element: lines[index], length: 6.2);
            Canvas.SetTop(element: lines[index], length: center - 1.1);
            canvas.Children.Add(item: dots[index]);
            canvas.Children.Add(item: lines[index]);
        }
        Children.Add(item: new Viewbox { Child = canvas });
    }

    public Brush? NeedsYouBrush
    {
        get => (Brush?)GetValue(dp: NeedsYouBrushProperty);
        set => SetValue(dp: NeedsYouBrushProperty, value: value);
    }

    public Brush? RunningBrush
    {
        get => (Brush?)GetValue(dp: RunningBrushProperty);
        set => SetValue(dp: RunningBrushProperty, value: value);
    }

    public Brush? DoneBrush
    {
        get => (Brush?)GetValue(dp: DoneBrushProperty);
        set => SetValue(dp: DoneBrushProperty, value: value);
    }

    public Brush? LineBrush
    {
        get => (Brush?)GetValue(dp: LineBrushProperty);
        set => SetValue(dp: LineBrushProperty, value: value);
    }

    static DependencyProperty Register(string name) => DependencyProperty.Register(
        name: name,
        propertyType: typeof(Brush),
        ownerType: typeof(BriefBarMark),
        typeMetadata: new PropertyMetadata(defaultValue: null, propertyChangedCallback: OnBrushChanged));

    static void OnBrushChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args)
    {
        var mark = (BriefBarMark)sender;
        mark.dots[0].Fill = mark.NeedsYouBrush;
        mark.dots[1].Fill = mark.RunningBrush;
        mark.dots[2].Fill = mark.DoneBrush;
        foreach (var line in mark.lines)
        {
            line.Fill = mark.LineBrush;
        }
    }
}
