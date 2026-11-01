namespace BriefBar.Core.AzureDevOps;

/// Says a pull request in a sentence, as the Mac's `Brief.item` does: who did what, and on which pull request.
public static class Brief
{
    /// One pull request's sentence: "Sam Rivera replied on “Fix the checkout total”."
    public static BriefItem Item(PRSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshot);
        var title = "“" + snapshot.Title + "”";
        var pending = snapshot.PendingEvents.ToList();
        var top = pending.Find(match: item => KindMatches(kind: item.Kind, reason: snapshot.Reason)) ?? pending.FirstOrDefault();
        var actor = top?.Actor ?? "Someone";
        var pipeline = snapshot.Merge?.Pipeline is { } name ? "“" + name + "”" : "A pipeline";
        var sentence = snapshot.Reason switch
        {
            PRReason.Mentioned => actor + " mentioned you on " + title + ".",
            PRReason.Replied => actor + " replied on " + title + ".",
            PRReason.Commented => actor + " commented on " + title + ".",
            PRReason.SentInChat => actor + " sent you " + title + (top?.App is { } app ? " in " + app : string.Empty) + ".",
            PRReason.ReviewRequested => snapshot.Author + " asked you to review " + title + ".",
            PRReason.NewCommits => title + " has new commits since your vote.",
            PRReason.ChangesRequested => actor + " is waiting for changes on " + title + ".",
            PRReason.Rejected => snapshot.Group == PRGroup.NeedsYou ? actor + " rejected " + title + "." : title + " was rejected.",
            PRReason.BuildFailed or PRReason.CheckFailed => snapshot.Failure is { } failure
                ? title + " failed at " + failure.Step + "."
                : title + " failed" + (snapshot.Detail is { } detail ? ": " + detail + "." : "."),
            PRReason.Conflicts => title + " has merge conflicts.",
            PRReason.BuildExpired => title + " needs its build queued again.",
            PRReason.FailedAfterMerge => pipeline + " failed after " + title + " merged.",
            PRReason.WaitingForApproval => pipeline + " waits for approval after " + title + " merged.",
            PRReason.ReadyToComplete => title + " is approved and ready to complete.",
            PRReason.AutoComplete => title + " is approved and will complete automatically.",
            _ => title + ": " + snapshot.Headline + ".",
        };
        return new BriefItem(
            Id: snapshot.Id + ":" + snapshot.Reason + ":" + (top?.Id ?? string.Empty),
            Key: snapshot.Key,
            Group: snapshot.Group,
            Reason: snapshot.Reason,
            Sentence: sentence,
            Url: snapshot.Url);
    }

    static bool KindMatches(PREventKind kind, PRReason reason) => (kind, reason) switch
    {
        (PREventKind.Mention, PRReason.Mentioned) or (PREventKind.Reply, PRReason.Replied)
            or (PREventKind.Comment, PRReason.Commented) or (PREventKind.SentInChat, PRReason.SentInChat)
            or (PREventKind.ChangesRequested, PRReason.ChangesRequested) or (PREventKind.Rejected, PRReason.Rejected) => true,
        _ => false,
    };
}
