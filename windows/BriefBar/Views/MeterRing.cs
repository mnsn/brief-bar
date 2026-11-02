using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Ellipse = Microsoft.UI.Xaml.Shapes.Ellipse;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace BriefBar.Views;

/// How full something is, as a small ring filled clockwise from the top, as the Mac draws a Copilot session's context
/// usage: a faint track, and `Fraction` of it in `Stroke`. Each ring draws its own geometry: WinUI won't let two shapes
/// share one, and rows in a list swap view models as they're reused. It's decoration: its row says the same in words.
public sealed partial class MeterRing : Grid
{
    public static readonly DependencyProperty FractionProperty = DependencyProperty.Register(
        name: nameof(Fraction),
        propertyType: typeof(double),
        ownerType: typeof(MeterRing),
        typeMetadata: new PropertyMetadata(defaultValue: 0.0, propertyChangedCallback: OnFractionChanged));

    public static readonly DependencyProperty StrokeProperty = DependencyProperty.Register(
        name: nameof(Stroke),
        propertyType: typeof(Brush),
        ownerType: typeof(MeterRing),
        typeMetadata: new PropertyMetadata(defaultValue: null, propertyChangedCallback: OnStrokeChanged));

    public static readonly DependencyProperty TrackProperty = DependencyProperty.Register(
        name: nameof(Track),
        propertyType: typeof(Brush),
        ownerType: typeof(MeterRing),
        typeMetadata: new PropertyMetadata(defaultValue: null, propertyChangedCallback: OnTrackChanged));

    const double Size = 12;
    const double Thickness = 1.5;

    readonly Ellipse track = new() { StrokeThickness = Thickness, Opacity = 0.35 };
    readonly Path arc = new()
    {
        StrokeThickness = Thickness,
        StrokeStartLineCap = PenLineCap.Round,
        StrokeEndLineCap = PenLineCap.Round,
    };

    public MeterRing()
    {
        Width = Size;
        Height = Size;
        IsHitTestVisible = false;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(
            element: this, value: Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        Children.Add(item: track);
        Children.Add(item: arc);
    }

    /// From 0, empty, to 1, full.
    public double Fraction
    {
        get => (double)GetValue(dp: FractionProperty);
        set => SetValue(dp: FractionProperty, value: value);
    }

    public Brush? Stroke
    {
        get => (Brush?)GetValue(dp: StrokeProperty);
        set => SetValue(dp: StrokeProperty, value: value);
    }

    public Brush? Track
    {
        get => (Brush?)GetValue(dp: TrackProperty);
        set => SetValue(dp: TrackProperty, value: value);
    }

    static void OnFractionChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args)
    {
        var ring = (MeterRing)sender;
        ring.arc.Data = Arc(fraction: Math.Clamp(value: (double)args.NewValue, min: 0, max: 1));
    }

    static void OnStrokeChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((MeterRing)sender).arc.Stroke = (Brush?)args.NewValue;

    static void OnTrackChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((MeterRing)sender).track.Stroke = (Brush?)args.NewValue;

    /// The part of the ring `fraction` fills, new for each ring.
    static Geometry? Arc(double fraction)
    {
        var radius = (Size - Thickness) / 2;
        var center = Size / 2;
        if (fraction <= 0)
        {
            return null;
        }
        if (fraction >= 0.999)
        {
            return new EllipseGeometry { Center = new Point(x: center, y: center), RadiusX = radius, RadiusY = radius };
        }
        var angle = fraction * 2 * Math.PI;
        var figure = new PathFigure { StartPoint = new Point(x: center, y: center - radius), IsClosed = false, IsFilled = false };
        figure.Segments.Add(item: new ArcSegment
        {
            Point = new Point(x: center + (radius * Math.Sin(a: angle)), y: center - (radius * Math.Cos(d: angle))),
            Size = new Size(width: radius, height: radius),
            SweepDirection = SweepDirection.Clockwise,
            IsLargeArc = fraction > 0.5,
        });
        var geometry = new PathGeometry();
        geometry.Figures.Add(item: figure);
        return geometry;
    }
}
