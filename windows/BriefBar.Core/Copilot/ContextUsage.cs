namespace BriefBar.Core.Copilot;

/// How much of a session's context window its conversation takes up, in tokens, as the app records it.
public sealed record ContextUsage(long Tokens, long Limit)
{
    /// The share of the window in use, from 0 to 1.
    public double Fraction => Limit > 0 ? Math.Clamp(value: (double)Tokens / Limit, min: 0, max: 1) : 0;

    public int Percent => (int)Math.Round(value: Fraction * 100, mode: MidpointRounding.AwayFromZero);
}
