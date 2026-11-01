using System.Globalization;
using System.Text;

namespace BriefBar.Core.Presentation;

/// SVG path data in XAML's path syntax: every number spelled out, and the fill rule first (`F0` for even-odd, `F1` for
/// nonzero). SVG lets numbers run together ("1.5.5", "-1-2") and an arc's two flags run into the next number, which
/// XAML doesn't.
public static class SvgPathData
{
    public static string ToXaml(string svg, IconFillRule rule)
    {
        ArgumentNullException.ThrowIfNull(argument: svg);
        var xaml = new StringBuilder(value: rule == IconFillRule.Nonzero ? "F1 " : "F0 ");
        var command = ' ';
        var argument = 0;
        var index = 0;
        while (index < svg.Length)
        {
            var character = svg[index];
            if (char.IsWhiteSpace(c: character) || character == ',')
            {
                index++;
                continue;
            }
            if (char.IsLetter(c: character) && character is not ('e' or 'E'))
            {
                command = character;
                argument = 0;
                xaml.Append(value: character).Append(value: ' ');
                index++;
                continue;
            }
            // An arc's two flags are single digits, which SVG lets run into the next number.
            if (command is 'a' or 'A' && argument % 7 is 3 or 4)
            {
                xaml.Append(value: character).Append(value: ' ');
                index++;
                argument++;
                continue;
            }
            var start = index;
            index = EndOfNumber(svg: svg, start: index);
            if (index == start || !double.TryParse(
                s: svg.AsSpan(start: start, length: index - start),
                style: NumberStyles.Float,
                provider: CultureInfo.InvariantCulture,
                result: out var number))
            {
                throw new FormatException(message: "A path has something that isn't a number where one should be.");
            }
            xaml.Append(value: number.ToString(format: "0.####", provider: CultureInfo.InvariantCulture)).Append(value: ' ');
            argument++;
        }
        return xaml.ToString().TrimEnd();
    }

    /// Where the number starting at `start` ends: a sign, digits with one point, and an exponent.
    static int EndOfNumber(string svg, int start)
    {
        var index = start;
        if (index < svg.Length && svg[index] is '-' or '+')
        {
            index++;
        }
        var hasPoint = false;
        while (index < svg.Length && (char.IsDigit(c: svg[index]) || (svg[index] == '.' && !hasPoint)))
        {
            hasPoint |= svg[index] == '.';
            index++;
        }
        if (index < svg.Length && svg[index] is 'e' or 'E')
        {
            index++;
            if (index < svg.Length && svg[index] is '-' or '+')
            {
                index++;
            }
            while (index < svg.Length && char.IsDigit(c: svg[index]))
            {
                index++;
            }
        }
        return index;
    }
}
