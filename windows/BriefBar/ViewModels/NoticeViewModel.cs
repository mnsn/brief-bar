using BriefBar.Core.Presentation;

namespace BriefBar.ViewModels;

/// A notice in a section's panel: what it says about what the section shows, and its button, if it has one, such as
/// "More on GitHub".
public sealed class NoticeViewModel(SectionNotice notice)
{
    public SectionNotice Notice { get; } = notice ?? throw new ArgumentNullException(paramName: nameof(notice));

    public string Message => Notice.Message;

    public PanelCommand? Command => Notice.Command;

    public bool HasCommand => Notice.Command is not null;

    public string CommandTitle => Notice.Command?.Title ?? string.Empty;

    public string? CommandHelp => Notice.Command?.Help;
}
