using System.Globalization;

namespace BriefBar.Core.Logging;

/// BriefBar's log: what it does, in counts, states and errors, never names, messages, titles or IDs. Lines go nowhere
/// until the app gives it a sink.
public static class Log
{
    static ILogSink? sink;

    /// Where lines go from now on, or nowhere for null.
    public static void UseSink(ILogSink? newSink) => Volatile.Write(location: ref sink, value: newSink);

    public static void Write(ref LogLine line)
    {
        var text = line.ToStringAndClear();
        Volatile.Read(location: ref sink)?.Write(line: Stamped(text: text));
    }

    /// An error's type, where it was thrown, and the methods it went through, but not its message, which can quote your
    /// data, as a path or a title would; nor its source files' paths. Its inner error's type follows.
    public static void Write(Exception error, ref LogLine context)
    {
        ArgumentNullException.ThrowIfNull(argument: error);
        var text = context.ToStringAndClear();
        var detail = string.Create(
            provider: CultureInfo.InvariantCulture,
            handler: $"{text}: {error.GetType().Name}, HRESULT 0x{error.HResult:X8}, at {Frames(error: error)}");
        if (error.InnerException is { } inner)
        {
            detail += string.Create(
                provider: CultureInfo.InvariantCulture,
                handler: $"; from {inner.GetType().Name}, HRESULT 0x{inner.HResult:X8}, at {Frames(error: inner)}");
        }
        Volatile.Read(location: ref sink)?.Write(line: Stamped(text: detail));
    }

    /// "Type.Method < Type.Method": the methods an error went through, innermost first, at most 12.
    static string Frames(Exception error)
    {
        var frames = new System.Diagnostics.StackTrace(e: error, fNeedFileInfo: false).GetFrames()
            .Select(selector: frame => frame.GetMethod())
            .OfType<System.Reflection.MethodBase>()
            .Take(count: 12)
            .Select(selector: method => method.DeclaringType?.Name + "." + method.Name)
            .ToList();
        return frames.Count > 0 ? string.Join(separator: " < ", values: frames) : "unknown";
    }

    static string Stamped(string text) =>
        string.Create(provider: CultureInfo.InvariantCulture, handler: $"{DateTimeOffset.Now:HH:mm:ss.fff} {text}");
}
