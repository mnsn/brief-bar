using System.Globalization;
using BriefBar.Core.Presentation;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace BriefBar.ViewModels;

/// Settings' Appearance: what the bar shows behind its words, and a color of your own, with what Settings says when
/// the bar shows it other than as chosen, so that its words read (`ReadableTint`).
public sealed class AppearanceSettingsViewModel : Observable
{
    readonly AppearanceSettings settings;
    readonly Func<bool> transparencyEffects;
    readonly Func<uint> barColorNow;

    /// `transparencyEffects` says whether Windows' Transparency effects is on; `barColorNow`, the color the bar shows
    /// now, which a color of your own starts from.
    public AppearanceSettingsViewModel(AppearanceSettings settings, Func<bool> transparencyEffects, Func<uint> barColorNow)
    {
        ArgumentNullException.ThrowIfNull(argument: settings);
        ArgumentNullException.ThrowIfNull(argument: transparencyEffects);
        ArgumentNullException.ThrowIfNull(argument: barColorNow);
        this.settings = settings;
        this.transparencyEffects = transparencyEffects;
        this.barColorNow = barColorNow;
        Refresh();
    }

    /// The choices, in `BarBackground`'s order.
    public static IReadOnlyList<string> Choices { get; } = ["Automatic", "Like the taskbar", "Custom color"];

    public int SelectedIndex
    {
        get => (int)settings.BarBackground;
        set
        {
            if (value < 0 || value >= Choices.Count || value == (int)settings.BarBackground)
            {
                return;
            }
            var background = (BarBackground)value;
            if (background == BarBackground.CustomColor && settings.BarColor is null)
            {
                settings.BarColor = barColorNow();
            }
            settings.BarBackground = background;
            Refresh();
        }
    }

    /// What the chosen one does.
    public string Description { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public bool IsCustomColor { get; private set => Set(storage: ref field, value: value); }

    /// The color of your own, as chosen, with how see-through it is.
    public Color Chosen { get; private set => Set(storage: ref field, value: value); }

    public Brush Swatch { get; private set => Set(storage: ref field, value: value); } = new SolidColorBrush();

    /// "#1C1C1C, 80% opaque".
    public string ChosenText { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    /// What the bar shows instead of the color as chosen, and why, or nothing.
    public string Note { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    public bool HasNote { get; private set => Set(storage: ref field, value: value); }

    /// Keeps `color` as your own.
    public void Choose(Color color)
    {
        settings.BarColor = ThemePalette.ArgbOf(color: color);
        Refresh();
    }

    /// Shows what's saved, and what the bar shows of it now, as Transparency effects may have changed.
    public void Refresh()
    {
        OnSelectionChanged();
        Description = settings.BarBackground switch
        {
            BarBackground.LikeTheTaskbar => "Acrylic, or flat where Windows draws no acrylic.",
            BarBackground.CustomColor => "A color of your own, as see-through as you like.",
            _ => "Acrylic, or see-through where Windows draws no acrylic, as over Remote Desktop.",
        };
        IsCustomColor = settings.BarBackground == BarBackground.CustomColor;
        var chosen = settings.BarColor ?? barColorNow();
        Chosen = ThemePalette.ColorOf(argb: chosen);
        Swatch = new SolidColorBrush(color: Chosen);
        ChosenText = ColorWords(argb: chosen);
        var note = ReadableTint.Of(chosen: chosen, dark: null, transparencyEffects: transparencyEffects()).Note;
        Note = note ?? string.Empty;
        HasNote = IsCustomColor && note is not null;
    }

    /// The list's selection changed, or may have: its binding reads it again.
    void OnSelectionChanged() => RaisePropertyChanged(propertyName: nameof(SelectedIndex));

    /// "#1C1C1C, 80% opaque", or "#1C1C1C" when it's opaque.
    static string ColorWords(uint argb)
    {
        var hex = "#" + (argb & 0x00FFFFFFu).ToString(format: "X6", provider: CultureInfo.InvariantCulture);
        var alpha = argb >> 24;
        if (alpha == 0xFF)
        {
            return hex;
        }
        var percent = Math.Round(value: alpha * 100 / 255.0, mode: MidpointRounding.AwayFromZero);
        return string.Create(provider: CultureInfo.InvariantCulture, handler: $"{hex}, {percent}% opaque");
    }
}
