using System.Globalization;
using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

/// How far an SVG path reaches: the box around the points it passes through and its curves' control points, which hold
/// each curve. Arcs, which can bulge past their ends, aren't measured; no icon has one.
static class SvgPathExtent
{
    /// The longer of the path's width and height, in its own units.
    public static double LongerSide(string svg)
    {
        var tokens = SvgPathData.ToXaml(svg: svg, rule: IconFillRule.Nonzero).Split(separator: ' ')[1..];
        double left = double.MaxValue, top = double.MaxValue, right = double.MinValue, bottom = double.MinValue;
        double x = 0, y = 0, startX = 0, startY = 0;
        var command = 'M';
        var index = 0;
        void Include(double pointX, double pointY)
        {
            (left, right) = (Math.Min(val1: left, val2: pointX), Math.Max(val1: right, val2: pointX));
            (top, bottom) = (Math.Min(val1: top, val2: pointY), Math.Max(val1: bottom, val2: pointY));
        }
        while (index < tokens.Length)
        {
            if (char.IsLetter(c: tokens[index][0]))
            {
                command = tokens[index][0];
                index++;
                if (command is 'Z' or 'z')
                {
                    (x, y) = (startX, startY);
                }
                continue;
            }
            var (originX, originY) = char.IsLower(c: command) ? (x, y) : (0.0, 0.0);
            double Number(int offset) => double.Parse(s: tokens[index + offset], provider: CultureInfo.InvariantCulture);
            switch (char.ToUpperInvariant(c: command))
            {
                case 'H':
                    x = originX + Number(offset: 0);
                    index += 1;
                    break;
                case 'V':
                    y = originY + Number(offset: 0);
                    index += 1;
                    break;
                case 'M' or 'L' or 'T':
                    (x, y) = (originX + Number(offset: 0), originY + Number(offset: 1));
                    index += 2;
                    break;
                case 'S' or 'Q':
                    Include(pointX: originX + Number(offset: 0), pointY: originY + Number(offset: 1));
                    (x, y) = (originX + Number(offset: 2), originY + Number(offset: 3));
                    index += 4;
                    break;
                case 'C':
                    Include(pointX: originX + Number(offset: 0), pointY: originY + Number(offset: 1));
                    Include(pointX: originX + Number(offset: 2), pointY: originY + Number(offset: 3));
                    (x, y) = (originX + Number(offset: 4), originY + Number(offset: 5));
                    index += 6;
                    break;
                default:
                    throw new NotSupportedException(message: $"Measuring a path's '{command}' isn't supported.");
            }
            if (command is 'M' or 'm')
            {
                // A move starts a shape, which Z returns to; numbers after it draw lines.
                (startX, startY) = (x, y);
                command = command == 'M' ? 'L' : 'l';
            }
            Include(pointX: x, pointY: y);
        }
        return Math.Max(val1: right - left, val2: bottom - top);
    }
}
