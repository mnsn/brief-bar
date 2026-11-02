using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace BriefBar.Views;

/// Lays its children out left to right, `Spacing` apart, and starts another line, `LineSpacing` below, when the next one
/// doesn't fit, as the Mac's `FlowLayout` lays out what's left before you can complete a pull request. A child wider than
/// a line gets the whole line, and cuts its words short.
public sealed partial class FlowPanel : Panel
{
    public static readonly DependencyProperty SpacingProperty = DependencyProperty.Register(
        name: nameof(Spacing),
        propertyType: typeof(double),
        ownerType: typeof(FlowPanel),
        typeMetadata: new PropertyMetadata(defaultValue: 0.0, propertyChangedCallback: OnLayoutChanged));

    public static readonly DependencyProperty LineSpacingProperty = DependencyProperty.Register(
        name: nameof(LineSpacing),
        propertyType: typeof(double),
        ownerType: typeof(FlowPanel),
        typeMetadata: new PropertyMetadata(defaultValue: 0.0, propertyChangedCallback: OnLayoutChanged));

    public double Spacing
    {
        get => (double)GetValue(dp: SpacingProperty);
        set => SetValue(dp: SpacingProperty, value: value);
    }

    public double LineSpacing
    {
        get => (double)GetValue(dp: LineSpacingProperty);
        set => SetValue(dp: LineSpacingProperty, value: value);
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        foreach (var child in Children)
        {
            child.Measure(availableSize: new Size(width: availableSize.Width, height: double.PositiveInfinity));
        }
        return Flow(lineWidth: availableSize.Width, place: null);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        Flow(lineWidth: finalSize.Width, place: (child, bounds) => child.Arrange(finalRect: bounds));
        return finalSize;
    }

    static void OnLayoutChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) => ((FlowPanel)sender).InvalidateMeasure();

    /// Where each child goes on lines `lineWidth` wide, given to `place` when there is one, and the size they all take.
    /// Children that are collapsed take no room, nor spacing.
    Size Flow(double lineWidth, Action<UIElement, Rect>? place)
    {
        var lines = new List<List<(UIElement Child, double Width)>>();
        var line = new List<(UIElement Child, double Width)>();
        var used = 0.0;
        foreach (var child in Children.Where(predicate: child => child.Visibility == Visibility.Visible))
        {
            var width = Math.Min(val1: child.DesiredSize.Width, val2: lineWidth);
            if (line.Count > 0 && used + Spacing + width > lineWidth)
            {
                lines.Add(item: line);
                line = [];
                used = 0;
            }
            used += (line.Count > 0 ? Spacing : 0) + width;
            line.Add(item: (child, width));
        }
        if (line.Count > 0)
        {
            lines.Add(item: line);
        }

        var top = 0.0;
        var widest = 0.0;
        foreach (var placed in lines)
        {
            var height = placed.Max(selector: entry => entry.Child.DesiredSize.Height);
            var left = 0.0;
            foreach (var (child, width) in placed)
            {
                place?.Invoke(arg1: child, arg2: new Rect(x: left, y: top, width: width, height: height));
                left += width + Spacing;
            }
            widest = Math.Max(val1: widest, val2: left - Spacing);
            top += height + LineSpacing;
        }
        return new Size(width: widest, height: lines.Count == 0 ? 0 : top - LineSpacing);
    }
}
