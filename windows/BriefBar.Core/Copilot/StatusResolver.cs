namespace BriefBar.Core.Copilot;

/// Combines the app's metadata with what a session's log says into what its list shows. The Mac's `StatusResolver`.
public static class StatusResolver
{
    /// The session as its list shows it at `now`.
    /// - `clearedAt`: when you last cleared it, which dismisses a run that ended before then.
    /// - `viewedAt`: when you last viewed it, which dismisses a run that ended before then only with Move Viewed
    ///   Sessions to Idle.
    public static SessionSnapshot Snapshot(
        SessionRecord record, DateTimeOffset now, ResolverOptions? options = null, AppViewState? view = null,
        DateTimeOffset? clearedAt = null, DateTimeOffset? viewedAt = null)
    {
        ArgumentNullException.ThrowIfNull(argument: record);
        options ??= new ResolverOptions();
        view ??= new AppViewState();
        var meta = record.Meta;
        var idle = new SessionSnapshot
        {
            Id = meta.Id,
            Name = PlainText.SingleLine(text: meta.Name),
            ProjectName = meta.ProjectName,
            Branch = meta.Branch,
            IsChat = meta.IsChat,
            Mode = meta.Mode,
            Phase = DisplayPhase.Idle,
            Reason = StatusReason.Idle,
            Headline = StatusReason.Idle.Headline(),
            Since = meta.UpdatedAt,
            ContextUsage = meta.ContextUsage,
        };

        SessionSnapshot Set(DisplayPhase phase, StatusReason reason, DateTimeOffset? since, string? detail = null, ValueList<string>? choices = null) =>
            idle with
            {
                Phase = phase,
                Reason = reason,
                Headline = reason.Headline(),
                Since = since,
                Detail = Flattened(detail: detail),
                Choices = choices ?? ValueList<string>.Empty,
            };

        SessionSnapshot Ended(StatusReason reason, DateTimeOffset? date, string? detail)
        {
            var endedAt = date ?? meta.UpdatedAt;
            var isCleared = clearedAt is { } cleared && cleared >= (endedAt ?? DateTimeOffset.MinValue);
            var isViewed = options.MoveViewedToIdle && HasBeenViewed(meta: meta, endedAt: endedAt, view: view, viewedAt: viewedAt);
            return Set(
                phase: EndedPhase(reason: reason, endedAt: endedAt, now: now, options: options, isSeen: isCleared || isViewed),
                reason: reason, since: endedAt, detail: detail);
        }

        if (record.Log is not { } log || log.Phase == LogPhase.Unknown)
        {
            if (meta.IsRunning == true)
            {
                return Set(phase: DisplayPhase.Running, reason: StatusReason.Working, since: meta.UpdatedAt);
            }
            return meta.WasInterrupted ? Ended(reason: StatusReason.Interrupted, date: meta.UpdatedAt, detail: null) : idle;
        }

        // The log says mid-turn, but the app says not running and the log has gone quiet: the CLI died or was stopped
        // without writing a final event. If the app's flag is unknown, the log is trusted.
        if (log.Phase == LogPhase.Running && meta.IsRunning == false && log.LastEventAt is { } lastEvent && now - lastEvent > options.StaleAfter)
        {
            return Ended(reason: meta.WasInterrupted ? StatusReason.Interrupted : StatusReason.Unresponsive, date: lastEvent, detail: null);
        }

        // The app already started a new turn, but the CLI hasn't logged it yet.
        if (meta.IsRunning == true && log.Phase != LogPhase.Running && meta.UpdatedAt is { } updatedAt
            && now - updatedAt < options.StartingGrace
            && updatedAt - (log.PhaseSince ?? DateTimeOffset.MinValue) > TimeSpan.FromSeconds(value: 1))
        {
            return Set(phase: DisplayPhase.Running, reason: StatusReason.Starting, since: updatedAt);
        }

        var activity = log.Activity;
        return activity.Type switch
        {
            LogActivityType.NeedsPermission => Set(
                phase: DisplayPhase.NeedsYou, reason: StatusReason.Permission, since: activity.Permission!.RequestedAt,
                detail: activity.Permission.Detail ?? activity.Permission.Kind),
            LogActivityType.NeedsAnswer when activity.Tool!.RelaysQuestion && !options.ShowRelayedQuestionsOnce =>
                Set(phase: DisplayPhase.Running, reason: StatusReason.Working, since: log.PhaseSince, detail: log.CurrentStep),
            // A relayed question's own words are the session's that waits on it (`RelayedQuestions`).
            LogActivityType.NeedsAnswer => Set(
                phase: DisplayPhase.NeedsYou, reason: StatusReason.Question, since: activity.Tool!.StartedAt,
                detail: activity.Tool.Question ?? activity.Tool.RelayContext, choices: activity.Tool.Choices),
            LogActivityType.NeedsPlanApproval => Set(
                phase: DisplayPhase.NeedsYou, reason: StatusReason.PlanApproval, since: activity.Tool!.StartedAt,
                detail: activity.Tool.PlanSummary),
            LogActivityType.Working => Set(phase: DisplayPhase.Running, reason: StatusReason.Working, since: activity.At, detail: activity.Text),
            LogActivityType.Finished => Ended(
                reason: StatusReason.Finished, date: activity.At,
                detail: activity.Text ?? ActivityText(meta: meta, kind: "agent_idle", near: activity.At)),
            LogActivityType.Interrupted => Ended(reason: StatusReason.Interrupted, date: activity.At, detail: null),
            LogActivityType.Failed => Ended(
                reason: StatusReason.Failed, date: activity.At,
                detail: activity.Text ?? ActivityText(meta: meta, kind: "agent_error", near: activity.At)),
            _ => idle,
        };
    }

    /// A session the Copilot app doesn't list, such as one BriefBar started for a task you sent, as the list shows it,
    /// from what follows it: running while it starts or works; once it ended, highlighted until dismissed or
    /// `RecentWindow` passes, as the app's sessions are.
    /// - `since`: when it got to its state.
    /// - `isSeen`: already dismissed according to your settings, or nothing to look at.
    public static SessionSnapshot Snapshot(
        string unlistedId, string name, string? place, StatusReason reason, string? detail, DateTimeOffset? since, DateTimeOffset now,
        bool isSeen, ResolverOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(argument: name);
        options ??= new ResolverOptions();
        var phase = reason switch
        {
            StatusReason.Question or StatusReason.PlanApproval or StatusReason.Permission => DisplayPhase.NeedsYou,
            StatusReason.Working or StatusReason.Starting or StatusReason.Relayed => DisplayPhase.Running,
            StatusReason.Finished or StatusReason.Interrupted or StatusReason.Failed or StatusReason.Unresponsive =>
                EndedPhase(reason: reason, endedAt: since, now: now, options: options, isSeen: isSeen),
            _ => DisplayPhase.Idle,
        };
        return new SessionSnapshot
        {
            Id = unlistedId,
            Name = PlainText.SingleLine(text: name),
            ProjectName = place,
            Phase = phase,
            Reason = reason,
            Headline = reason.Headline(),
            Detail = Flattened(detail: detail),
            Since = since,
        };
    }

    /// Where something that ended shows: done or stopped, highlighted, if it ended within `RecentWindow` and you haven't
    /// dismissed it since; idle otherwise.
    internal static DisplayPhase EndedPhase(StatusReason reason, DateTimeOffset? endedAt, DateTimeOffset now, ResolverOptions options, bool isSeen)
    {
        var isRecent = endedAt is { } ended && now - ended <= options.RecentWindow;
        if (!isRecent || isSeen)
        {
            return DisplayPhase.Idle;
        }
        return reason == StatusReason.Finished ? DisplayPhase.Done : DisplayPhase.Stopped;
    }

    internal static bool HasBeenViewed(SessionMeta meta, DateTimeOffset? endedAt, AppViewState view, DateTimeOffset? viewedAt)
    {
        if (viewedAt is { } viewed && viewed >= (endedAt ?? DateTimeOffset.MinValue))
        {
            return true;
        }
        if (meta.WorkspaceId is { } workspaceId && view.UnreadWorkspaceIds is { } unread && view.UnreadUpdatedAt is { } updatedAt
            && endedAt is { } ended && updatedAt >= ended)
        {
            return !unread.Contains(item: workspaceId);
        }
        return false;
    }

    /// The app's own activity-feed preview, if it belongs to the same end of a turn.
    internal static string? ActivityText(SessionMeta meta, string kind, DateTimeOffset? near)
    {
        if (meta.LastActivity is not { } activity || activity.Kind != kind || activity.Text.Length == 0)
        {
            return null;
        }
        if (near is { } date && activity.At is { } at && at < date.AddSeconds(seconds: -30))
        {
            return null;
        }
        return activity.Text;
    }

    /// Markdown on one line, or null when that says nothing.
    static string? Flattened(string? detail) =>
        detail is null ? null : PlainText.FromMarkdown(markdown: detail) is { Length: > 0 } flat ? flat : null;
}
