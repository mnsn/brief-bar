using System.Globalization;
using BriefBar.Core.AzureDevOps;
using BriefBar.Core.Presentation;

namespace BriefBar.Core.Tests.Presentation;

public sealed class IconPathsTests
{
    static readonly bool[] requiredOrNot = [true, false];
    /// 100% and 200%.
    static readonly double[] wholeScales = [1.0, 2.0];

    [Fact]
    public void EveryDrawingIsOneXamlCanRead()
    {
        foreach (var icon in Enum.GetValues<IconKey>())
        {
            foreach (var drawing in IconPaths.Drawings(icon: icon))
            {
                Assert.True(condition: drawing.Size is 12 or 16 or 20 or 24 or 32, userMessage: $"{icon} is {drawing.Size} units square.");
                var xaml = SvgPathData.ToXaml(svg: drawing.Svg, rule: drawing.Rule);
                Assert.Matches(expectedRegexPattern: @"^F[01] [MmLlHhVvCcSsQqTtAaZz0-9.\- ]+$", actualString: xaml);
            }
        }
    }

    /// Each drawing reaches across at least half its square, so one that's only part of its icon shows: Fluent's
    /// Hourglass Half, filled, at 16 is only its sand.
    [Fact]
    public void EveryDrawingReachesAcrossItsSquare()
    {
        var partial = Enum.GetValues<IconKey>()
            .SelectMany(selector: icon => IconPaths.Drawings(icon: icon).Select(selector: drawing => (Icon: icon, Drawing: drawing)))
            .Where(predicate: shown => SvgPathExtent.LongerSide(svg: shown.Drawing.Svg) < shown.Drawing.Size / 2.0)
            .Select(selector: shown => shown.Icon + " at " + shown.Drawing.Size)
            .ToList();
        Assert.Empty(collection: partial);
    }

    [Fact]
    public void HasEachIconOnceAtEachSize()
    {
        foreach (var icon in Enum.GetValues<IconKey>())
        {
            var sizes = IconPaths.Drawings(icon: icon).Select(selector: drawing => drawing.Size).ToList();
            Assert.Equal(expected: sizes.Distinct().Count(), actual: sizes.Count);
        }
    }

    /// Every icon lines up with a display's pixels at Windows' usual scales, at the sizes BriefBar shows it: 16 pixels
    /// square covers 16 of a display's pixels at 100%, 20 at 125%, 24 at 150% and 32 at 200%, its 16 doubled. Fluent
    /// doesn't draw every icon at every size, so these don't: Copilot's pulse at 16, Branch Request at 24, and the plan,
    /// the clock with a cross and the power icon at 16. The chevron shows only at 12.
    [Fact]
    public void LinesUpWithTheDisplaysPixelsWhereFluentDrawsIt()
    {
        (double Size, double Scale)[] shown = [(16, 1), (16, 1.25), (16, 1.5), (16, 2), (20, 1), (20, 2), (24, 1), (24, 2)];
        var blurred = Enum.GetValues<IconKey>()
            .Where(predicate: icon => icon != IconKey.ChevronRight)
            .SelectMany(selector: icon => shown.Select(selector: at => (Icon: icon, at.Size, at.Scale)))
            .Where(predicate: at => !LinesUp(drawing: IconPaths.Of(icon: at.Icon, size: at.Size, scale: at.Scale), pixels: at.Size * at.Scale))
            .Select(selector: at => string.Create(provider: CultureInfo.InvariantCulture, handler: $"{at.Icon} at {at.Size} on {at.Scale:0.##}"))
            .ToList();
        Assert.Equal(
            expected:
            [
                "BranchRequest at 16 on 1.5", "BranchRequest at 24 on 1", "BranchRequest at 24 on 2",
                "ClipboardTaskList at 16 on 1", "ClipboardTaskList at 16 on 2",
                "ClockDismiss at 16 on 1", "ClockDismiss at 16 on 2",
                "Power at 16 on 1", "Power at 16 on 2",
                "Pulse at 16 on 1",
            ],
            actual: blurred.Order(comparer: StringComparer.Ordinal));
    }

    /// A pull request's checklist shows its icons at 12 pixels, and so do its links; Fluent draws the raised hand, Branch
    /// Request and the plan at no 12, so those are scaled at 100%.
    [Fact]
    public void LinesUpOnAPullRequestsChecklist()
    {
        var checklist = new ItemState?[] { ItemState.Done, ItemState.Failing, ItemState.NeedsYou, ItemState.Running, null }
            .SelectMany(selector: state => requiredOrNot.Select(selector: required => AzureDevOpsRows.Icon(
                item: new PRReadinessItem(Kind: default, State: state, Label: "An item", IsRequired: required))));
        var blurred = checklist
            .Concat(second: [IconKey.BranchRequest, IconKey.ClipboardTaskList])
            .Distinct()
            .SelectMany(selector: icon => wholeScales.Select(selector: scale => (Icon: icon, Scale: scale)))
            .Where(predicate: at => !LinesUp(drawing: IconPaths.Of(icon: at.Icon, size: 12, scale: at.Scale), pixels: 12 * at.Scale))
            .Select(selector: at => string.Create(provider: CultureInfo.InvariantCulture, handler: $"{at.Icon} on {at.Scale:0.##}"))
            .ToList();
        Assert.Equal(
            expected: ["BranchRequest on 1", "BranchRequest on 2", "ClipboardTaskList on 1", "HandRaise on 1"],
            actual: blurred.Order(comparer: StringComparer.Ordinal));
    }

    [Theory]
    [InlineData(IconKey.CheckmarkCircle, 16, 1.0, 16)]
    [InlineData(IconKey.CheckmarkCircle, 16, 1.25, 20)]
    [InlineData(IconKey.CheckmarkCircle, 16, 1.5, 24)]
    // Doubled at 200%, as no drawing is made for 32.
    [InlineData(IconKey.CheckmarkCircle, 16, 2.0, 16)]
    [InlineData(IconKey.CheckmarkCircle, 20, 2.0, 20)]
    // One made for the pixels it covers before one doubled.
    [InlineData(IconKey.CheckmarkCircle, 12, 2.0, 24)]
    [InlineData(IconKey.ChevronRight, 12, 2.0, 12)]
    [InlineData(IconKey.Pulse, 16, 2.0, 32)]
    // Else the nearest, the larger of two as near: 28 pixels at 175%, and where Fluent has none at that size.
    [InlineData(IconKey.CheckmarkCircle, 16, 1.75, 24)]
    [InlineData(IconKey.Pulse, 16, 1.0, 20)]
    [InlineData(IconKey.BranchRequest, 16, 1.5, 20)]
    [InlineData(IconKey.HandRaise, 12, 1.0, 16)]
    [InlineData(IconKey.Person, 18, 1.0, 20)]
    // A scale that isn't one is taken as 100%.
    [InlineData(IconKey.Person, 16, double.NaN, 16)]
    [InlineData(IconKey.Person, 16, 0.0, 16)]
    public void ShowsTheDrawingForThePixelsItCovers(IconKey icon, double size, double scale, int drawn)
    {
        Assert.Equal(expected: drawn, actual: IconPaths.Of(icon: icon, size: size, scale: scale).Size);
    }
    [Theory]
    [InlineData("M1.5.5L2,3Z", IconFillRule.Nonzero, "F1 M 1.5 0.5 L 2 3 Z")]
    [InlineData("M-1-2h3", IconFillRule.EvenOdd, "F0 M -1 -2 h 3")]
    [InlineData("M0 0a1 1 0 01 2 3", IconFillRule.Nonzero, "F1 M 0 0 a 1 1 0 0 1 2 3")]
    [InlineData("M1e-1 2E2", IconFillRule.Nonzero, "F1 M 0.1 200")]
    public void SpellsOutWhatSvgRunsTogether(string svg, IconFillRule rule, string expected)
    {
        Assert.Equal(expected: expected, actual: SvgPathData.ToXaml(svg: svg, rule: rule));
    }

    [Fact]
    public void RefusesSomethingThatIsntAPath()
    {
        Assert.Throws<FormatException>(testCode: () => SvgPathData.ToXaml(svg: "M 1 # 2", rule: IconFillRule.Nonzero));
    }

    /// Whether `drawing` covers `pixels` as it was drawn, or doubled.
    static bool LinesUp(IconPath drawing, double pixels) => drawing.Size == pixels || drawing.Size * 2 == pixels;
}
