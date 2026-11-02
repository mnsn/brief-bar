using System.Globalization;

namespace BriefBar.Core.AzureDevOps;

/// Something that needed you that you've since answered yourself in Azure DevOps: what needed you (`Kind`) and who it came
/// from; when you answered, and how, with your vote or how many commits you pushed; the message that sent it to you, and
/// the thread you answered in. The Mac's `PRClassifier.Answer`.
internal sealed record PRAnswer(
    PREventKind Kind,
    string? From,
    DateTimeOffset At,
    PRAnswerAction Action,
    Vote? Vote = null,
    int? Commits = null,
    ChatLink? Link = null,
    int? ThreadId = null)
{
    /// What you did: "You approved", "You replied", "You pushed 2 commits".
    public string Headline => Action switch
    {
        PRAnswerAction.Vote => (Vote ?? AzureDevOps.Vote.None) switch
        {
            AzureDevOps.Vote.Approved => "You approved",
            AzureDevOps.Vote.ApprovedWithSuggestions => "You approved with suggestions",
            AzureDevOps.Vote.WaitingForAuthor => "You asked for changes",
            AzureDevOps.Vote.Rejected => "You rejected it",
            _ => "You voted",
        },
        PRAnswerAction.Comment => Kind == PREventKind.SentInChat ? "You commented" : "You replied",
        PRAnswerAction.Push => Commits switch
        {
            null or <= 0 => "You pushed changes",
            1 => "You pushed 1 commit",
            { } commits => string.Create(provider: CultureInfo.InvariantCulture, handler: $"You pushed {commits} commits"),
        },
        _ => throw new InvalidOperationException(message: "An answer of an unknown kind."),
    };

    /// What it answered: "Dana Whitfield sent this in Teams", "Sam Rivera replied to you".
    public string Question
    {
        get
        {
            var who = From ?? "Someone";
            return Kind switch
            {
                PREventKind.SentInChat => From is { } sender
                    ? sender + " sent this in " + (Link?.AppName ?? "a chat")
                    : "Sent to you in " + (Link?.AppName ?? "a chat"),
                PREventKind.Mention => who + " mentioned you",
                PREventKind.Reply => who + " replied to you",
                PREventKind.Comment => who + " commented",
                PREventKind.ReviewRequest => who + " asked you to review",
                PREventKind.NewCommits => "New commits by " + who,
                PREventKind.ChangesRequested => who + " asked for changes",
                PREventKind.Rejected => who + " rejected it",
                PREventKind.Approved => who + " approved",
                _ => throw new InvalidOperationException(message: "An answer to an unknown kind of event."),
            };
        }
    }
}
