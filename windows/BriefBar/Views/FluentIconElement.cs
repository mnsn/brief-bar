using System.Globalization;
using BriefBar.Core;
using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.Views;

/// A Fluent icon as an `IconElement`, for controls that take one, such as a page's item in Settings: drawn 16 pixels
/// square, as Windows draws icons there.
internal static class FluentIconElement
{
    const double Size = 16;

    public static PathIcon Make(IconKey icon)
    {
        var drawing = IconPaths.Of(icon: icon);
        var data = SvgPathData.ToXaml(svg: drawing.Svg, rule: drawing.Rule);
        var made = (PathIcon)XamlReader.Load(
            xaml: string.Create(
                provider: CultureInfo.InvariantCulture,
                handler: $"<PathIcon xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" Data=\"{data}\" />"));
        if (drawing.Size != Size)
        {
            made.Data.Transform = new ScaleTransform { ScaleX = Size / drawing.Size, ScaleY = Size / drawing.Size };
        }
        return made;
    }
}
