using System.Globalization;
using System.Runtime.CompilerServices;

namespace BriefBar.Core.Logging;

/// A log line, written as an interpolated string that can only hold what says nothing about your data: its literal
/// text, numbers, enums, handles, durations and `ILoggable` values such as a section's ID. There's no way to add a
/// string to it, so a name, title or message can't reach the log: that doesn't compile.
[InterpolatedStringHandler]
public ref struct LogLine
{
    DefaultInterpolatedStringHandler builder;

    public LogLine(int literalLength, int formattedCount)
    {
        builder = new DefaultInterpolatedStringHandler(
            literalLength: literalLength, formattedCount: formattedCount, provider: CultureInfo.InvariantCulture);
    }

    public void AppendLiteral(string value) => builder.AppendLiteral(value: value);

    public void AppendFormatted(int value) => builder.AppendFormatted(value: value);

    public void AppendFormatted(long value) => builder.AppendFormatted(value: value);

    public void AppendFormatted(double value, string? format = null) => builder.AppendFormatted(value: value, format: format);

    public void AppendFormatted(bool value) => builder.AppendFormatted(value: value);

    public void AppendFormatted(nint value) => builder.AppendFormatted(value: value);

    public void AppendFormatted(TimeSpan value) => builder.AppendFormatted(value: value);

    public void AppendFormatted<TEnum>(TEnum value)
        where TEnum : struct, Enum => builder.AppendFormatted(value: value);

    public void AppendFormatted(ILoggable? value) => builder.AppendLiteral(value: value?.ToString() ?? "none");

    internal string ToStringAndClear() => builder.ToStringAndClear();
}
