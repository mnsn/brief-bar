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

    /// Accepts `YYYY-MM-DD(T| )HH:MM:SS[.fraction][Z|±HH[[:]MM]]`, with a day that's in its month and an offset under a
    /// day, as UTF-8.
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
        if (month is < 1 or > 12 || day < 1 || day > DaysInMonth(year: year, month: month) || hour >= 24 || minute >= 60 || second > 60)
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
                    if (Offset(bytes: bytes[index..]) is not { } offset)
                    {
                        return null;
                    }
                    offsetSeconds = offset;
                    index = count;
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

    /// How many days `month` has in `year`, in the proleptic Gregorian calendar that `DaysFromCivil` counts in: a date
    /// past its month's end, such as February 31, is no date, rather than one in March.
    static int DaysInMonth(int year, int month) => month switch
    {
        2 => IsLeapYear(year: year) ? 29 : 28,
        4 or 6 or 9 or 11 => 30,
        _ => 31,
    };

    /// Every fourth year, but not every hundredth, unless it's every four hundredth.
    static bool IsLeapYear(int year) => year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);

    /// The seconds east of UTC that `bytes`, the rest of the timestamp from its sign, says: `±HH`, `±HHMM` or `±HH:MM`,
    /// with hours under 24 and minutes under 60. Null for anything else, such as `+01:60`, rather than `+02:00`, or a
    /// colon without minutes.
    static long? Offset(ReadOnlySpan<byte> bytes)
    {
        int? minutes = bytes.Length switch
        {
            3 => 0,
            5 => Number(bytes: bytes, start: 3, length: 2),
            6 when bytes[3] == (byte)':' => Number(bytes: bytes, start: 4, length: 2),
            _ => null,
        };
        if (minutes is not { } offsetMinutes || Number(bytes: bytes, start: 1, length: 2) is not { } offsetHours
            || offsetHours >= 24 || offsetMinutes >= 60)
        {
            return null;
        }
        var sign = bytes[0] == (byte)'-' ? -1 : 1;
        return sign * ((offsetHours * 3_600L) + (offsetMinutes * 60L));
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
