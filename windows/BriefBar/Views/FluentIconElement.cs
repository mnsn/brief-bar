using System.Globalization;
using BriefBar.Core;
using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using XamlPath = Microsoft.UI.Xaml.Shapes.Path;

namespace BriefBar.Views;

/// A Fluent icon as an `IconElement`, for controls that take one, such as a page's item in Settings: drawn 16 pixels
/// square, as Windows draws icons there, from the drawing made for the pixels it covers on its display (`IconPaths`).
internal static class FluentIconElement
{
    const double Size = 16;

    public static PathIcon Make(IconKey icon)
    {
        // Its full square, or NavigationView's 16-pixel box would stretch it to the drawing's bottom-right corner.
        var made = new PathIcon { Width = Size, Height = Size };
        var display = new DisplayScaleWatcher(element: made, scaleChanged: scale => Draw(element: made, icon: icon, scale: scale));
        Draw(element: made, icon: icon, scale: display.Scale);
        return made;
    }

    /// Gives `element` the drawing of `icon` for a display at `scale`.
    static void Draw(PathIcon element, IconKey icon, double scale)
    {
        var drawing = IconPaths.Of(icon: icon, size: Size, scale: scale);
        var data = SvgPathData.ToXaml(svg: drawing.Svg, rule: drawing.Rule);
        // A geometry of its own, taken from the path it's read with: WinUI ends the app when two elements share one.
        var read = (XamlPath)XamlReader.Load(
            xaml: string.Create(
                provider: CultureInfo.InvariantCulture,
                handler: $"<Path xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" Data=\"{data}\" />"));
        var geometry = read.Data;
        read.Data = null;
        if (drawing.Size != Size)
        {
            geometry.Transform = new ScaleTransform { ScaleX = Size / drawing.Size, ScaleY = Size / drawing.Size };
        }
        element.Data = geometry;
    }
}
