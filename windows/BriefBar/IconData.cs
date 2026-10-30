using System.Globalization;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace BriefBar;

/// A Fluent icon: an SVG path on a square of `Size` units.
internal sealed class IconData(int size, FillRule rule, string svg)
{
    string? data;

    /// The icon `pixels` wide, filled with `brush`.
    public FrameworkElement Make(double pixels, Brush brush)
    {
        data ??= ToXaml(svg, rule);
        var path = (Path)XamlReader.Load(
            $"<Path xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" Data=\"{data}\" />");
        path.Fill = brush;
        path.Width = size;
        path.Height = size;
        return new Viewbox { Width = pixels, Height = pixels, Child = path, VerticalAlignment = VerticalAlignment.Center };
    }

    /// SVG path data in XAML's path syntax: numbers spelled out in full, and the fill rule first.
    static string ToXaml(string svg, FillRule rule)
    {
        var xaml = new StringBuilder(rule == FillRule.Nonzero ? "F1 " : "F0 ");
        char command = ' ';
        int argument = 0, i = 0;
        while (i < svg.Length)
        {
            char c = svg[i];
            if (char.IsWhiteSpace(c) || c == ',')
            {
                i++;
                continue;
            }
            if (char.IsLetter(c) && c is not ('e' or 'E'))
            {
                command = c;
                argument = 0;
                xaml.Append(c).Append(' ');
                i++;
                continue;
            }
            // An arc's two flags are single digits, which SVG lets run into the next number.
            if (command is 'a' or 'A' && argument % 7 is 3 or 4)
            {
                xaml.Append(c).Append(' ');
                i++;
                argument++;
                continue;
            }
            int start = i;
            if (c is '-' or '+') i++;
            bool dot = false;
            while (i < svg.Length && (char.IsDigit(svg[i]) || (svg[i] == '.' && !dot)))
            {
                dot |= svg[i] == '.';
                i++;
            }
            if (i < svg.Length && svg[i] is 'e' or 'E')
            {
                i++;
                if (i < svg.Length && svg[i] is '-' or '+') i++;
                while (i < svg.Length && char.IsDigit(svg[i])) i++;
            }
            if (i == start || !double.TryParse(svg.AsSpan(start, i - start), NumberStyles.Float, CultureInfo.InvariantCulture, out var number))
            {
                i = Math.Max(i, start + 1);
                continue;
            }
            xaml.Append(number.ToString("0.####", CultureInfo.InvariantCulture)).Append(' ');
            argument++;
        }
        return xaml.ToString().TrimEnd();
    }
}
