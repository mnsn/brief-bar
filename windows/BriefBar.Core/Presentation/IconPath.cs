namespace BriefBar.Core.Presentation;

/// An icon's drawing: an SVG path on a square of `Size` units, filled by `Rule`.
public sealed record IconPath(int Size, IconFillRule Rule, string Svg);
