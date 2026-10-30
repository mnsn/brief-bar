using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace BriefBar;

/// What the panel shows: a header, the brief, then the things in each state, as BriefBar's Overview on the Mac.
internal static class PanelContent
{
    public static Grid Build(string key, Action quit)
    {
        bool overview = key == "overview";
        Source? source = overview ? null : Enum.Parse<Source>(key);
        var items = Demo.Items.Where(item => source is null || item.Source == source).ToList();
        var brief = Demo.Brief.Where(line => source is null || line.Source == source).ToList();

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.Children.Add(Header(source, items));

        var list = new StackPanel { Padding = new Thickness(10, 6, 10, 12) };
        if (brief.Count > 0) list.Children.Add(BriefCard(brief));
        foreach (var state in Look.States)
        {
            var rows = items.Where(item => item.State == state).ToList();
            if (rows.Count == 0) continue;
            var title = Look.Text($"{Look.Title(state)} ({rows.Count})", 13, Look.Brush(Look.TextColor(state)), Look.SemiBold);
            title.Margin = new Thickness(6, 14, 0, 4);
            list.Children.Add(title);
            foreach (var item in rows) list.Children.Add(Row(item, showSource: source is null));
        }
        var scroll = new ScrollViewer
        {
            Content = list,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Disabled,
            IsTabStop = true,
        };
        Grid.SetRow(scroll, 1);
        root.Children.Add(scroll);

        var footer = Footer(quit);
        Grid.SetRow(footer, 2);
        root.Children.Add(footer);
        return root;
    }

    /// So Esc works straight away.
    public static void FocusList(Grid root)
    {
        if (root.Children.OfType<ScrollViewer>().FirstOrDefault() is { } scroll) scroll.Focus(FocusState.Programmatic);
    }

    static FrameworkElement Header(Source? source, List<Item> items)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var look = source is { } value ? Look.Of(value) : null;
        grid.Children.Add(look is null ? Icons.Stack.Make(20, Look.Brush(Look.Accent)) : look.Glyph.Make(20, Look.Brush(look.Color)));
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(Look.Text(look?.Title ?? "Overview", 15, Look.Primary, Look.SemiBold));
        titles.Children.Add(Look.Text(look?.Owner ?? "Everything, by what it needs from you", 12, Look.Secondary));
        Grid.SetColumn(titles, 1);
        grid.Children.Add(titles);

        FrameworkElement summary;
        if (source is null)
        {
            var needsYou = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            needsYou.Children.Add(Look.Text($"{Demo.Count(State.NeedsYou)} need you", 12, Look.Secondary));
            needsYou.Children.Add(Icons.ChevronRight.Make(12, Look.Secondary));
            summary = needsYou;
        }
        else
        {
            var counts = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            foreach (var state in Look.Order(source.Value))
            {
                int count = items.Count(item => item.State == state);
                if (count > 0) counts.Children.Add(Look.Count(state, source.Value, count));
            }
            summary = counts;
        }
        summary.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(summary, 2);
        grid.Children.Add(summary);

        return new Border
        {
            Child = grid,
            Padding = new Thickness(16, 12, 16, 12),
            BorderBrush = Look.Divider,
            BorderThickness = new Thickness(0, 0, 0, 1),
        };
    }

    static FrameworkElement BriefCard(List<BriefLine> lines)
    {
        var stack = new StackPanel { Spacing = 7 };
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        title.Children.Add(Icons.Sparkle.Make(14, Look.Brush(Look.IsDark ? 0xFFC4A7FFu : 0xFF8B5CF6u)));
        title.Children.Add(Look.Text("Brief", 12, Look.Secondary, Look.SemiBold));
        stack.Children.Add(title);
        foreach (var line in lines)
        {
            var row = new Grid { ColumnSpacing = 9 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(6) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Children.Add(new Ellipse
            {
                Width = 6,
                Height = 6,
                Fill = Look.Brush(Look.Color(line.State)),
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 7, 0, 0),
            });
            var text = Look.Text(line.Text, 13, Look.Primary, lines: 3);
            text.VerticalAlignment = VerticalAlignment.Top;
            Grid.SetColumn(text, 1);
            row.Children.Add(text);
            stack.Children.Add(row);
        }
        return new Border
        {
            Child = stack,
            Padding = new Thickness(12, 10, 12, 12),
            Margin = new Thickness(0, 6, 0, 2),
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            BorderBrush = Gradient(0xFFF0A3CBu, 0xFFB9A3F3u, 0xFF95BFF5u),
            Background = Gradient(Look.IsDark ? 0x26F0A3CBu : 0x33F7C6DEu, Look.IsDark ? 0x1AB9A3F3u : 0x26D9CCFAu, Look.IsDark ? 0x2695BFF5u : 0x33C6DCFAu),
        };
    }

    static LinearGradientBrush Gradient(params uint[] colors)
    {
        var brush = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
        for (int i = 0; i < colors.Length; i++)
        {
            brush.GradientStops.Add(new GradientStop { Color = Look.ColorOf(colors[i]), Offset = i / (double)(colors.Length - 1) });
        }
        return brush;
    }

    /// One thing: its source in the margin, an icon in its state's color, its title, what it's waiting on, and when.
    static FrameworkElement Row(Item item, bool showSource)
    {
        var look = Look.Of(item.Source);
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(showSource ? 14 : 0) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(30) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        if (showSource)
        {
            var glyph = look.Glyph.Make(13, Look.Brush(look.Color));
            glyph.VerticalAlignment = VerticalAlignment.Top;
            glyph.Margin = new Thickness(0, 9, 0, 0);
            ToolTipService.SetToolTip(glyph, $"{look.Owner} {look.Title}");
            grid.Children.Add(glyph);
        }

        var badgeGlyph = item.Icon.Make(15, Look.White);
        badgeGlyph.HorizontalAlignment = HorizontalAlignment.Center;
        var badge = new Border
        {
            Width = 30,
            Height = 30,
            CornerRadius = new CornerRadius(15),
            Background = Look.Brush(Look.Color(item.State)),
            VerticalAlignment = VerticalAlignment.Top,
            Child = badgeGlyph,
        };
        Grid.SetColumn(badge, 1);
        grid.Children.Add(badge);

        var text = new StackPanel { Spacing = 1 };
        text.Children.Add(Look.Text(item.Title, 14, Look.Primary, Look.SemiBold));
        text.Children.Add(Look.Text(item.Status, 12, Look.Brush(Look.TextColor(item.State)), lines: 2));
        if (item.Detail is { } detail) text.Children.Add(Look.Text(detail, 12, Look.Secondary, lines: 2));
        Grid.SetColumn(text, 2);
        grid.Children.Add(text);

        var right = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right };
        right.Children.Add(Look.Text(item.Age, 12, Look.Tertiary));
        if (item.Unread > 0)
        {
            right.Children.Add(new Border
            {
                MinWidth = 18,
                Height = 18,
                CornerRadius = new CornerRadius(9),
                Padding = new Thickness(5, 0, 5, 0),
                HorizontalAlignment = HorizontalAlignment.Right,
                Background = Look.Brush(look.Color),
                Child = new TextBlock
                {
                    Text = item.Unread.ToString(),
                    FontSize = 11,
                    FontWeight = Look.SemiBold,
                    Foreground = Look.White,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            });
        }
        Grid.SetColumn(right, 3);
        grid.Children.Add(right);

        var row = new Border
        {
            Child = grid,
            Padding = new Thickness(8, 8, 10, 8),
            CornerRadius = new CornerRadius(6),
            Background = Look.Clear,
        };
        row.PointerEntered += (_, _) => row.Background = Look.Hover;
        row.PointerExited += (_, _) => row.Background = Look.Clear;
        return row;
    }

    static FrameworkElement Footer(Action quit)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Look.Text("BriefBar for Windows prototype · made-up data", 12, Look.Tertiary));
        var button = new Button { Padding = new Thickness(10, 4, 10, 5) };
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        label.Children.Add(Icons.Power.Make(14, Look.Primary));
        label.Children.Add(new TextBlock { Text = "Quit", FontSize = 12 });
        button.Content = label;
        button.Click += (_, _) => quit();
        Grid.SetColumn(button, 1);
        grid.Children.Add(button);
        return new Border
        {
            Child = grid,
            Padding = new Thickness(16, 8, 10, 8),
            BorderBrush = Look.Divider,
            BorderThickness = new Thickness(0, 1, 0, 0),
        };
    }
}
