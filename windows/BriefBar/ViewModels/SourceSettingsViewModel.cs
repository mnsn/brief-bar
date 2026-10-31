using BriefBar.Core;
using Microsoft.UI.Xaml.Media;

namespace BriefBar.ViewModels;

/// A source in Settings: its name, glyph and color, what it says it reads, and whether it's on.
public sealed class SourceSettingsViewModel : Observable
{
    public SourceSettingsViewModel(SourceEntry entry, ThemePalette palette)
    {
        ArgumentNullException.ThrowIfNull(argument: entry);
        ArgumentNullException.ThrowIfNull(argument: palette);
        Entry = entry;
        CardName = Name + ": " + StateText;
        UsePalette(palette: palette);
    }

    public SourceEntry Entry { get; }

    public string Name => Entry.Name;

    public string Summary => Entry.Description.Summary;

    public string Reads => Entry.Description.Reads;

    public string Network => Entry.Description.Network;

    public string Needs => Entry.Description.Needs;

    public IconKey Glyph => Entry.Glyph;

    public string TurnOnTitle => "Turn on " + Name;

    public string TurnOffTitle => "Turn off " + Name + "…";

    public string PausedMessage => "Since you turned " + Name + " on, an update changed what it reads. Here's what it reads now.";

    public Brush TileBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public Brush OnTileBrush { get; private set => Set(storage: ref field, value: value); } = null!;

    public SourceState State
    {
        get;
        set
        {
            if (Set(storage: ref field, value: value))
            {
                IsOn = value == SourceState.On;
                IsOff = value == SourceState.Off;
                IsPaused = value == SourceState.NeedsReview;
                StateText = value switch
                {
                    SourceState.On => "On",
                    SourceState.NeedsReview => "Paused",
                    _ => "Off",
                };
                CardName = Name + ": " + StateText;
            }
        }
    } = SourceState.Off;

    public bool IsOn { get; private set => Set(storage: ref field, value: value); }

    public bool IsOff { get; private set => Set(storage: ref field, value: value); } = true;

    public bool IsPaused { get; private set => Set(storage: ref field, value: value); }

    public string StateText { get; private set => Set(storage: ref field, value: value); } = "Off";

    /// What Narrator calls its card in General: "GitHub Copilot: On".
    public string CardName { get; private set => Set(storage: ref field, value: value); } = string.Empty;

    /// Turning it on or off is under way: its buttons wait.
    public bool IsBusy
    {
        get;
        set
        {
            if (Set(storage: ref field, value: value))
            {
                IsIdle = !value;
            }
        }
    }

    public bool IsIdle { get; private set => Set(storage: ref field, value: value); } = true;

    public void UsePalette(ThemePalette palette)
    {
        ArgumentNullException.ThrowIfNull(argument: palette);
        TileBrush = palette.Tint(tint: Entry.Tint);
        OnTileBrush = palette.OnTint;
    }
}
