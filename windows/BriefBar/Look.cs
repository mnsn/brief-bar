using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using Windows.UI.Text;

namespace BriefBar;

/// How a source looks: its names, glyph and color.
internal sealed record SourceLook(string Title, string Owner, IconData Glyph, uint Color, bool ColoredInBar);

/// BriefBar's states and sources as Windows 11 draws things: Fluent icons, its colors and Segoe UI Variable.
internal static class Look
{
    public static readonly State[] States = [State.NeedsYou, State.Failing, State.Running, State.Done];

    public static bool IsDark => Application.Current.RequestedTheme == ApplicationTheme.Dark;

    public static Windows.UI.Color ColorOf(uint argb) =>
        Windows.UI.Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb);
    public static SolidColorBrush Brush(uint argb) => new(ColorOf(argb));
    static Brush Resource(string key) => (Brush)Application.Current.Resources[key];

    public static Brush Primary => Resource("TextFillColorPrimaryBrush");
    public static Brush Secondary => Resource("TextFillColorSecondaryBrush");
    public static Brush Tertiary => Resource("TextFillColorTertiaryBrush");
    public static Brush Divider => Resource("DividerStrokeColorDefaultBrush");
    public static Brush Hover => Brush(IsDark ? 0x15FFFFFFu : 0x0F000000u);
    public static Brush Pressed => Brush(IsDark ? 0x24FFFFFFu : 0x1C000000u);
    public static Brush Clear => new SolidColorBrush(Colors.Transparent);
    public static Brush White => new SolidColorBrush(Colors.White);
    public static uint Accent => IsDark ? 0xFF60CDFFu : 0xFF005FB8u;

    public static string Title(State state) => state switch
    {
        State.NeedsYou => "Needs You",
        State.Failing => "Something's Wrong",
        State.Running => "Running",
        _ => "Done or Ready",
    };

    /// After a count: "8 need you".
    public static string CountLabel(State state) => state switch
    {
        State.NeedsYou => "need you",
        State.Failing => "went wrong",
        State.Running => "running",
        _ => "done or ready",
    };

    /// For icons and dots.
    public static uint Color(State state) => state switch
    {
        State.NeedsYou => IsDark ? 0xFFFF8C3Au : 0xFFF7630Cu,
        State.Failing => IsDark ? 0xFFFF6B70u : 0xFFD13438u,
        State.Running => IsDark ? 0xFF479EF5u : 0xFF0F6CBDu,
        _ => IsDark ? 0xFF6CCB5Fu : 0xFF0F7B0Fu,
    };

    /// For words, which need more contrast than icons.
    public static uint TextColor(State state) => state switch
    {
        State.NeedsYou => IsDark ? 0xFFFFA05Cu : 0xFFB54708u,
        State.Failing => IsDark ? 0xFFFF99A4u : 0xFFC42B1Cu,
        State.Running => IsDark ? 0xFF60CDFFu : 0xFF0F6CBDu,
        _ => IsDark ? 0xFF6CCB5Fu : 0xFF0F7B0Fu,
    };

    public static IconData Icon(State state, Source source) => state switch
    {
        State.NeedsYou => Icons.HandRaise,
        State.Failing => source == Source.Copilot ? Icons.Warning : Icons.DismissCircle,
        State.Running => Icons.Flash,
        _ => Icons.CheckmarkCircle,
    };

    /// The order a source's counts go in, as its menu-bar item orders them on the Mac.
    public static State[] Order(Source source) => source == Source.Copilot
        ? [State.NeedsYou, State.Running, State.Done, State.Failing]
        : [State.NeedsYou, State.Failing, State.Running, State.Done];

    public static SourceLook Of(Source source) => source switch
    {
        Source.Chats => new("Chats", "Microsoft Teams", Icons.Person, 0xFF0F6CBDu, true),
        Source.GroupChats => new("Group Chats", "Microsoft Teams", Icons.People, 0xFF038387u, true),
        Source.AzureDevOps => new("Pull Requests", "Azure DevOps", Icons.BranchRequest, 0xFF0078D4u, false),
        Source.Copilot => new("Sessions", "GitHub Copilot", Icons.Pulse, 0xFFC239B3u, false),
        _ => new("Pull Requests", "GitHub", Icons.BranchFork, 0xFF8250DFu, false),
    };

    public static TextBlock Text(string text, double size, Brush brush, FontWeight? weight = null, int lines = 1)
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = size,
            Foreground = brush,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = lines > 1 ? TextWrapping.Wrap : TextWrapping.NoWrap,
            MaxLines = lines,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (weight is { } value) block.FontWeight = value;
        return block;
    }

    public static FontWeight SemiBold => FontWeights.SemiBold;

    /// BriefBar's mark, from its app icon: three lines of a brief, with the colors of needs you, running and done.
    public static FrameworkElement Mark(double size)
    {
        var canvas = new Canvas { Width = 16, Height = 16 };
        uint[] dots = [Color(State.NeedsYou), Color(State.Running), Color(State.Done)];
        double[] lengths = [8.4, 6.4, 7.4];
        for (int i = 0; i < 3; i++)
        {
            double center = 3 + i * 5;
            var dot = new Ellipse { Width = 3.8, Height = 3.8, Fill = Brush(dots[i]) };
            Canvas.SetLeft(dot, 0.6);
            Canvas.SetTop(dot, center - 1.9);
            var line = new Rectangle { Width = lengths[i], Height = 2.2, RadiusX = 1.1, RadiusY = 1.1, Fill = Primary };
            Canvas.SetLeft(line, 6.2);
            Canvas.SetTop(line, center - 1.1);
            canvas.Children.Add(dot);
            canvas.Children.Add(line);
        }
        return new Viewbox { Width = size, Height = size, Child = canvas, VerticalAlignment = VerticalAlignment.Center };
    }

    /// A state's icon and count, as menu-bar items and headers show them.
    public static FrameworkElement Count(State state, Source source, int count, double iconSize = 14)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(Icon(state, source).Make(iconSize, Brush(Color(state))));
        panel.Children.Add(Text(count.ToString(), 12, Primary, SemiBold));
        return panel;
    }
}
