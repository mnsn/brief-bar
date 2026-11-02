namespace BriefBar.Core.ChromiumIndexedDB;

/// Which versions of Blink's and V8's formats a value was written with: Blink's version is 0 for values without Blink's
/// envelope. `Compressed` says whether Blink compressed it. The Mac's `SerializedValue.Format`.
public readonly record struct SerializedFormat(int Blink, int V8, bool Compressed)
{
    /// "Blink 21, V8 16, compressed".
    public override string ToString() =>
        string.Create(provider: System.Globalization.CultureInfo.InvariantCulture, handler: $"Blink {Blink}, V8 {V8}") + (Compressed ? ", compressed" : string.Empty);
}
