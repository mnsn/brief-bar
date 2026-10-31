using System.Text;

namespace BriefBar.Core;

/// Allocation-free ISO-8601 parser for timestamps like `2026-10-18T17:00:07.304Z`, including the seven-digit fractions
/// Azure DevOps uses. Copilot's event logs parse one per line, so it avoids the general parsers. The Mac's `Timestamp`.
public static class Timestamp
{
    const long SecondsPerDay = 86_400;

    public static DateTimeOffset? Parse(string text)
    {
        ArgumentNullException.ThrowIfNull(argument: text);
        if (text.Length > 64)
        {
            return Parse(bytes: Encoding.UTF8.GetBytes(s: text));
        }
        Span<byte> bytes = stackalloc byte[Encoding.UTF8.GetMaxByteCount(charCount: text.Length)];
        var count = Encoding.UTF8.GetBytes(chars: text, bytes: bytes);
        return Parse(bytes: bytes[..count]);
    }

    /// Accepts `YYYY-MM-DD(T| )HH:MM:SS[.fraction][Z|±HH[:MM]]`, as UTF-8.
    public static DateTimeOffset? Parse(ReadOnlySpan<byte> bytes)
    {
        var count = bytes.Length;
        if (count < 19)
        {
            return null;
        }
        if (Number(bytes: bytes, start: 0, length: 4) is not { } year || bytes[4] != (byte)'-'
            || Number(bytes: bytes, start: 5, length: 2) is not { } month || bytes[7] != (byte)'-'
            || Number(bytes: bytes, start: 8, length: 2) is not { } day
            || bytes[10] is not ((byte)'T' or (byte)'t' or (byte)' ')
            || Number(bytes: bytes, start: 11, length: 2) is not { } hour || bytes[13] != (byte)':'
            || Number(bytes: bytes, start: 14, length: 2) is not { } minute || bytes[16] != (byte)':'
            || Number(bytes: bytes, start: 17, length: 2) is not { } second)
        {
            return null;
        }
        if (month is < 1 or > 12 || day is < 1 or > 31 || hour >= 24 || minute >= 60 || second > 60)
        {
            return null;
        }

        var index = 19;
        long fractionTicks = 0;
        if (index < count && bytes[index] is (byte)'.' or (byte)',')
        {
            index++;
            var scale = TimeSpan.TicksPerSecond / 10;
            var sawDigit = false;
            while (index < count && Digit(value: bytes[index]) is { } digit)
            {
                fractionTicks += digit * scale;
                scale /= 10;
                index++;
                sawDigit = true;
            }
            if (!sawDigit)
            {
                return null;
            }
        }

        long offsetSeconds = 0;
        if (index < count)
        {
            switch (bytes[index])
            {
                case (byte)'Z' or (byte)'z':
                    index++;
                    break;
                case (byte)'+' or (byte)'-':
                    var sign = bytes[index] == (byte)'-' ? -1 : 1;
                    index++;
                    if (index + 2 > count || Number(bytes: bytes, start: index, length: 2) is not { } offsetHours)
                    {
                        return null;
                    }
                    index += 2;
                    if (index < count && bytes[index] == (byte)':')
                    {
                        index++;
                    }
                    var offsetMinutes = 0;
                    if (index + 2 <= count && Number(bytes: bytes, start: index, length: 2) is { } minutes)
                    {
                        offsetMinutes = minutes;
                        index += 2;
                    }
                    offsetSeconds = sign * ((offsetHours * 3_600L) + (offsetMinutes * 60L));
                    break;
                default:
                    return null;
            }
        }
        if (index != count)
        {
            return null;
        }

        var days = DaysFromCivil(year: year, month: month, day: day);
        var whole = (days * SecondsPerDay) + (hour * 3_600L) + (minute * 60L) + second - offsetSeconds;
        var ticks = DateTimeOffset.UnixEpoch.UtcTicks + (whole * TimeSpan.TicksPerSecond) + fractionTicks;
        if (ticks < DateTimeOffset.MinValue.UtcTicks || ticks > DateTimeOffset.MaxValue.UtcTicks)
        {
            return null;
        }
        return new DateTimeOffset(ticks: ticks, offset: TimeSpan.Zero);
    }

    /// Howard Hinnant's days-from-civil algorithm (proleptic Gregorian calendar): days since 1970-01-01.
    public static long DaysFromCivil(long year, int month, int day)
    {
        var y = month <= 2 ? year - 1 : year;
        var era = (y >= 0 ? y : y - 399) / 400;
        var yearOfEra = y - (era * 400);
        var shiftedMonth = (month + 9) % 12;
        var dayOfYear = (((153 * shiftedMonth) + 2) / 5) + day - 1;
        var dayOfEra = (yearOfEra * 365) + (yearOfEra / 4) - (yearOfEra / 100) + dayOfYear;
        return (era * 146_097) + dayOfEra - 719_468;
    }

    static int? Digit(byte value) => value is >= (byte)'0' and <= (byte)'9' ? value - '0' : null;

    static int? Number(ReadOnlySpan<byte> bytes, int start, int length)
    {
        var value = 0;
        for (var index = start; index < start + length; index++)
        {
            if (Digit(value: bytes[index]) is not { } digit)
            {
                return null;
            }
            value = (value * 10) + digit;
        }
        return value;
    }
}
