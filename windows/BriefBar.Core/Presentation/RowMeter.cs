namespace BriefBar.Core.Presentation;

/// How full something is, shown on a row as a ring and a percentage, such as a Copilot session's context window:
/// `Fraction` from 0 to 1, `IsHigh` once it's worth a look, and `Spoken`, the same in words.
public sealed record RowMeter(double Fraction, string Text, bool IsHigh, string Spoken);
