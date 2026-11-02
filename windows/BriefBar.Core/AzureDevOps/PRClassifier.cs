using System.Globalization;

namespace BriefBar.Core.AzureDevOps;

/// Decides each pull request's group, reason and what's new, as the Mac's `PRClassifier` does ([How it
/// works](../../../docs/how-it-works.md#how-a-pull-requests-group-is-decided)).
public static class PRClassifier
{
    /// How `record` shows at `now`, given that activity up to `seenCutoff` counts as seen, and that comments up to
    /// `dismissedCutoff` that still wait on you don't need you anymore, since you took the pull request off Needs you; those
    /// after it that you've seen still do. Null when it shouldn't be listed: done a while ago, or done and seen.
    public static PRSnapshot? Snapshot(PRRecord record, DateTimeOffset seenCutoff, DateTimeOffset dismissedCutoff, DateTimeOffset now, ClassifierOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(argument: record);
        options ??= new ClassifierOptions();
        // Taking it off Needs you saw it, too.
        var seen = Later(first: seenCutoff, second: dismissedCutoff);
        var pr = record.PullRequest;
        var me = record.Me;
        var details = record.Details;
        var approvals = pr.Reviewers.Where(predicate: reviewer => reviewer.Vote.IsApproval() && !reviewer.IsGroup).ToList();
        var lastActivity = Later(first: pr.CreatedAt, second: details?.LastActivity ?? DateTimeOffset.MinValue);
        var inactive = options.InactiveAfter is { } inactiveAfter && now - lastActivity > inactiveAfter;

        var snapshot = new PRSnapshot
        {
            Key = pr.Key,
            Title = pr.Title.Length == 0 ? "Pull request " + Text(number: pr.Key.Number) : pr.Title,
            Repository = pr.RepositoryName,
            Project = pr.ProjectName,
            Author = pr.Author.Name,
            Role = record.Role,
            IsDraft = pr.IsDraft,
            Group = PRGroup.Waiting,
            Reason = PRReason.WaitingForReviewers,
            Headline = string.Empty,
            Since = lastActivity,
            Url = pr.WebUrl,
            Approvals = new ValueList<string>(items: approvals.Select(selector: reviewer => reviewer.Person.Name)),
            CheckState = details is null ? null : CheckStateOf(checks: details.Checks),
            HasDetails = details is not null,
            IsWatched = record.IsWatched,
            CreatedAt = pr.CreatedAt,
        };
        void Set(PRPlacement placement) => snapshot = snapshot with
        {
            Group = placement.Group,
            Reason = placement.Reason,
            Headline = placement.Headline,
            Detail = string.IsNullOrEmpty(value: placement.Detail) ? null : placement.Detail,
            Since = placement.Since ?? lastActivity,
        };

        switch (pr.Status)
        {
            case PullRequestStatus.Completed or PullRequestStatus.Abandoned:
                return Closed(record: record, snapshot: snapshot, seenCutoff: seen, now: now, lastActivity: lastActivity, options: options);
            case PullRequestStatus.Other:
                return null;
            case PullRequestStatus.Active:
                break;
            default:
                throw new InvalidOperationException(message: "A pull request in an unknown status.");
        }
        snapshot = snapshot with { Readiness = PRReadiness.From(record: record) };

        var events = new List<PREvent>();
        if (details is not null)
        {
            events = record.Role == PRRole.Author
                ? AuthorEvents(pr: pr, details: details, me: me, seenCutoff: seen, dismissedCutoff: dismissedCutoff)
                : ReviewerEvents(pr: pr, details: details, me: me, seenCutoff: seen, dismissedCutoff: dismissedCutoff);
        }
        // Comments you've seen wait on you while the pull request is active: once nothing has happened on it for a while,
        // it's idle, as it would be without them.
        if (inactive)
        {
            events.RemoveAll(match: item => !item.IsNew);
        }
        var chats = PendingChatLinks(record: record, seenCutoff: seen, now: now, options: options);
        events.AddRange(collection: chats.Select(selector: link => new PREvent(
            Id: "s" + link.Id, Kind: PREventKind.SentInChat, At: link.SentAt, Actor: link.Sender, App: link.AppName)));
        snapshot = snapshot with { Events = new ValueList<PREvent>(items: events.OrderByDescending(keySelector: item => item.At)) };
        if (chats.MaxBy(keySelector: link => link.SentAt) is { } newest)
        {
            snapshot = snapshot with { ChatSource = new ChatSource(App: newest.App, AppName: newest.AppName, Sender: newest.Sender) };
        }
        var pending = snapshot.PendingEvents.ToList();
        // What's new says why it's here; what you've seen, only when nothing is.
        var fresh = pending.Where(predicate: item => item.IsNew).ToList();
        var named = fresh.Count == 0 ? pending : fresh;
        if (named.OrderBy(keySelector: item => item.Kind.Priority()).ThenByDescending(keySelector: item => item.At).FirstOrDefault() is { } top)
        {
            var (reason, headline) = Describe(top: top, events: named);
            Set(placement: new PRPlacement(
                Group: PRGroup.NeedsYou,
                Reason: reason,
                Headline: headline,
                Detail: top.Text ?? EventDetail(item: top, pr: pr, role: record.Role),
                Since: pending.Max(selector: item => item.At)));
            if (top.ThreadId is { } thread)
            {
                snapshot = snapshot with { Url = pr.ThreadUrl(threadId: thread) };
            }
            return snapshot;
        }

        var yours = Answers(record: record, seenCutoff: seen, now: now, options: options);
        if (yours.Select(selector: answer => answer.Link).OfType<ChatLink>().MaxBy(keySelector: link => link.SentAt) is { } sent)
        {
            snapshot = snapshot with { ChatSource = new ChatSource(App: sent.App, AppName: sent.AppName, Sender: sent.Sender) };
        }
        // Moves it to Answered, saying what you did and what it answered; false when you haven't answered anything.
        bool ShowAnswer()
        {
            if (yours.OrderBy(keySelector: answer => answer.Kind.Priority()).ThenByDescending(keySelector: answer => answer.At).FirstOrDefault() is not { } answered)
            {
                return false;
            }
            Set(placement: new PRPlacement(
                Group: PRGroup.Answered, Reason: PRReason.Answered, Headline: answered.Headline, Detail: answered.Question, Since: yours.Max(selector: answer => answer.At)));
            if (answered.ThreadId is { } thread)
            {
                snapshot = snapshot with { Url = pr.ThreadUrl(threadId: thread) };
            }
            return true;
        }
        // A pull request you're not on is listed only while someone's message about it needs you, or a comment there waits
        // on you, and until you've seen that you answered it.
        if (record.Role == PRRole.Linked)
        {
            return ShowAnswer() ? snapshot : null;
        }

        if (record.Role == PRRole.Reviewer && pr.FindReviewer(id: me)?.HasDeclined == true)
        {
            Set(placement: new PRPlacement(Group: PRGroup.Idle, Reason: PRReason.Declined, Headline: "You declined"));
        }
        else if (pr.IsDraft)
        {
            Set(placement: new PRPlacement(Group: PRGroup.Idle, Reason: PRReason.Draft, Headline: "Draft", Detail: record.Role == PRRole.Reviewer ? "By " + pr.Author.Name : null));
        }
        else if (inactive)
        {
            var days = (int)(now - lastActivity).TotalDays;
            Set(placement: new PRPlacement(Group: PRGroup.Idle, Reason: PRReason.Inactive, Headline: "No activity for " + Text(number: days) + " days"));
        }
        else if (record.Role == PRRole.Author)
        {
            Set(placement: ClassifyAuthor(pr: pr, details: details, approvals: approvals));
            if (snapshot.Reason == PRReason.BuildFailed)
            {
                snapshot = snapshot with
                {
                    Failure = details?.Checks.FirstOrDefault(predicate: check => check.FailedBuildId is not null && check.IsBlocking && check.Failure is not null)?.Failure,
                };
            }
        }
        else
        {
            Set(placement: ClassifyReviewer(pr: pr, me: me, approvals: approvals, watched: record.IsWatched));
        }
        // What you answered stays in view until you've seen it, unless there's something else to do.
        if (snapshot.Group is PRGroup.Idle or PRGroup.Waiting)
        {
            ShowAnswer();
        }
        return snapshot;
    }

    /// The worst state among the required builds and status checks, or null without any.
    public static CheckState? CheckStateOf(IEnumerable<Check> checks)
    {
        ArgumentNullException.ThrowIfNull(argument: checks);
        var states = checks
            .Where(predicate: check => check.IsBlocking && check.Kind is CheckKind.Build or CheckKind.Status && check.State != CheckState.NotApplicable)
            .Select(selector: check => check.State)
            .ToHashSet();
        CheckState[] worstFirst = [CheckState.Failed, CheckState.Expired, CheckState.Running, CheckState.Queued, CheckState.Pending, CheckState.NotRun, CheckState.Passed];
        return worstFirst.Cast<CheckState?>().FirstOrDefault(predicate: state => states.Contains(item: state!.Value));
    }

    /// On your pull request: comments from others that came after your last word in their thread, and votes that still
    /// stand. Comments you've seen count while their thread is open, from `dismissedCutoff`; everything else only while
    /// it's new.
    internal static List<PREvent> AuthorEvents(PullRequest pr, PRDetails details, string me, DateTimeOffset seenCutoff, DateTimeOffset dismissedCutoff)
    {
        var events = new List<PREvent>();
        foreach (var thread in details.Threads)
        {
            var lastMine = thread.Comments.LastOrDefault(predicate: comment => comment.Author.Id == me)?.PublishedAt;
            var after = Later(first: WaitingSince(thread: thread, seenCutoff: seenCutoff, dismissedCutoff: dismissedCutoff), second: lastMine ?? DateTimeOffset.MinValue);
            foreach (var comment in Unanswered(thread: thread, me: me, after: after))
            {
                var kind = comment.Mentions.Contains(value: me) ? PREventKind.Mention : lastMine is not null ? PREventKind.Reply : PREventKind.Comment;
                events.Add(item: Event(kind: kind, comment: comment, thread: thread, seenCutoff: seenCutoff));
            }
        }

        var latestVotes = new Dictionary<string, Activity>(comparer: StringComparer.Ordinal);
        foreach (var item in details.Activity.Where(predicate: item => item.Kind == ActivityKind.Vote))
        {
            if (item.Actor?.Id is { } id && id != me)
            {
                latestVotes[id] = item;
            }
        }
        var lastPush = details.Activity.LastOrDefault(predicate: item => item.Kind == ActivityKind.Push)?.At;
        foreach (var (id, item) in latestVotes)
        {
            // Only a vote that still stands: the reviewer is still on the pull request, and hasn't changed it.
            if (item.Vote is not { } vote || item.At <= seenCutoff || pr.FindReviewer(id: id)?.Vote != vote)
            {
                continue;
            }
            PREventKind kind;
            switch (vote)
            {
                case Vote.Approved or Vote.ApprovedWithSuggestions:
                    kind = PREventKind.Approved;
                    break;
                case Vote.WaitingForAuthor or Vote.Rejected:
                    // You've pushed changes since.
                    if (lastPush is { } pushed && pushed > item.At)
                    {
                        continue;
                    }
                    kind = vote == Vote.Rejected ? PREventKind.Rejected : PREventKind.ChangesRequested;
                    break;
                default:
                    continue;
            }
            events.Add(item: new PREvent(Id: "v" + Text(number: item.ThreadId), Kind: kind, At: item.At, Actor: item.Actor?.Name));
        }
        return events;
    }

    /// On a pull request you review: replies and mentions, a review request you haven't seen, and pushes since your vote.
    /// Replies and mentions you've seen count while their thread is open, from `dismissedCutoff`.
    internal static List<PREvent> ReviewerEvents(PullRequest pr, PRDetails details, string me, DateTimeOffset seenCutoff, DateTimeOffset dismissedCutoff)
    {
        var events = new List<PREvent>();
        foreach (var thread in details.Threads)
        {
            var lastMine = thread.Comments.LastOrDefault(predicate: comment => comment.Author.Id == me)?.PublishedAt;
            var after = Later(first: WaitingSince(thread: thread, seenCutoff: seenCutoff, dismissedCutoff: dismissedCutoff), second: lastMine ?? DateTimeOffset.MinValue);
            foreach (var comment in Unanswered(thread: thread, me: me, after: after))
            {
                if (comment.Mentions.Contains(value: me))
                {
                    events.Add(item: Event(kind: PREventKind.Mention, comment: comment, thread: thread, seenCutoff: seenCutoff));
                }
                else if (lastMine is not null)
                {
                    events.Add(item: Event(kind: PREventKind.Reply, comment: comment, thread: thread, seenCutoff: seenCutoff));
                }
            }
        }

        var votedAt = details.Activity.LastOrDefault(predicate: item => item.Kind == ActivityKind.Vote && item.Actor?.Id == me && item.Vote != Vote.None)?.At;
        var current = pr.FindReviewer(id: me);
        if (votedAt is { } voted)
        {
            var pushes = details.Activity.Where(predicate: item => item.Kind == ActivityKind.Push && item.At > voted && item.At > seenCutoff).ToList();
            if (pushes.Count > 0)
            {
                var latest = pushes[^1];
                var commits = pushes.Sum(selector: push => push.CommitCount ?? 0);
                events.Add(item: new PREvent(
                    Id: "p" + Text(number: latest.ThreadId), Kind: PREventKind.NewCommits, At: latest.At, Actor: pr.Author.Name, Count: commits > 0 ? commits : null));
            }
        }
        else if (current is { Vote: Vote.None, HasDeclined: false } && !pr.IsDraft)
        {
            // Asked to review, from when you were added, or the draft was published.
            var added = details.Activity.LastOrDefault(predicate: item => item.Kind == ActivityKind.ReviewersChanged && item.Added.Contains(value: me));
            var published = details.Activity.LastOrDefault(predicate: item => item.Kind == ActivityKind.DraftChanged)?.At ?? DateTimeOffset.MinValue;
            var at = Later(first: added?.At ?? pr.CreatedAt, second: published);
            if (at > seenCutoff)
            {
                events.Add(item: new PREvent(
                    Id: "r" + Text(number: added?.ThreadId ?? 0),
                    Kind: PREventKind.ReviewRequest,
                    At: at,
                    Actor: pr.Author.Name,
                    Text: current.IsRequired ? "Required reviewer" : null));
            }
        }
        return events;
    }

    /// Links people sent you that still need you: sent after you last looked, within `KeepChatLinksFor`, and not followed by
    /// your comment, vote or, on your own pull request, push.
    internal static List<ChatLink> PendingChatLinks(PRRecord record, DateTimeOffset seenCutoff, DateTimeOffset now, ClassifierOptions options) =>
        record.ChatLinks.Where(predicate: link =>
        {
            if (link.SentAt <= seenCutoff || now - link.SentAt > options.KeepChatLinksFor)
            {
                return false;
            }
            if (record.Details is not { } details)
            {
                return true;
            }
            var me = record.Me;
            var commented = details.Threads.Any(predicate: thread => thread.Comments.Any(predicate: comment => comment.Author.Id == me && comment.PublishedAt > link.SentAt));
            var acted = details.Activity.Any(predicate: item => item.At > link.SentAt && item.Actor?.Id == me
                && (item.Kind == ActivityKind.Vote || (record.Role == PRRole.Author && item.Kind == ActivityKind.Push)));
            return !commented && !acted;
        }).ToList();

    /// What needed you since you last looked that you've answered yourself, within `KeepAnsweredFor`. Each mirrors what
    /// made it need you: a message about it, answered by your vote, comment or, on your own pull request, push; a comment,
    /// by your reply in its thread; a review request, or new commits since your vote, by your vote; and on your own pull
    /// request, a vote that wanted changes, by your push.
    internal static List<PRAnswer> Answers(PRRecord record, DateTimeOffset seenCutoff, DateTimeOffset now, ClassifierOptions options)
    {
        if (record.Details is not { } details)
        {
            return [];
        }
        var pr = record.PullRequest;
        var me = record.Me;
        var votes = details.Activity
            .Where(predicate: item => item.Kind == ActivityKind.Vote && item.Actor?.Id == me && item.Vote != Vote.None)
            .OrderBy(keySelector: item => item.At)
            .ToList();
        var pushes = record.Role == PRRole.Author
            ? details.Activity.Where(predicate: item => item.Kind == ActivityKind.Push && item.Actor?.Id == me).OrderBy(keySelector: item => item.At).ToList()
            : [];
        var comments = details.Threads.SelectMany(selector: thread => thread.Comments).Where(predicate: comment => comment.Author.Id == me)
            .OrderBy(keySelector: comment => comment.PublishedAt)
            .ToList();
        var answers = new List<PRAnswer>();

        foreach (var link in record.ChatLinks.Where(predicate: link => link.SentAt > seenCutoff))
        {
            var candidates = new List<PRAnswer>();
            if (votes.Find(match: item => item.At > link.SentAt) is { } vote)
            {
                candidates.Add(item: new PRAnswer(Kind: PREventKind.SentInChat, From: link.Sender, At: vote.At, Action: PRAnswerAction.Vote, Vote: vote.Vote, Link: link));
            }
            if (comments.Find(match: comment => comment.PublishedAt > link.SentAt) is { } comment)
            {
                candidates.Add(item: new PRAnswer(Kind: PREventKind.SentInChat, From: link.Sender, At: comment.PublishedAt, Action: PRAnswerAction.Comment, Link: link));
            }
            if (pushes.Find(match: item => item.At > link.SentAt) is { } push)
            {
                candidates.Add(item: new PRAnswer(Kind: PREventKind.SentInChat, From: link.Sender, At: push.At, Action: PRAnswerAction.Push, Commits: push.CommitCount, Link: link));
            }
            // Answered while it still needed you.
            if (candidates.MinBy(keySelector: answer => answer.At) is { } first && first.At - link.SentAt <= options.KeepChatLinksFor)
            {
                answers.Add(item: first);
            }
        }

        foreach (var thread in details.Threads)
        {
            var mine = thread.Comments.Where(predicate: comment => comment.Author.Id == me).ToList();
            foreach (var comment in thread.Comments.Where(predicate: comment => comment.Author.Id != me && !comment.Author.IsBot && comment.PublishedAt > seenCutoff))
            {
                if (mine.Find(match: reply => reply.PublishedAt > comment.PublishedAt) is not { } reply)
                {
                    continue;
                }
                PREventKind kind;
                if (comment.Mentions.Contains(value: me))
                {
                    kind = PREventKind.Mention;
                }
                else if (mine.Exists(match: earlier => earlier.PublishedAt < comment.PublishedAt))
                {
                    kind = PREventKind.Reply;
                }
                else if (record.Role == PRRole.Author)
                {
                    kind = PREventKind.Comment;
                }
                else
                {
                    // Comments between others don't concern you as a reviewer.
                    continue;
                }
                answers.Add(item: new PRAnswer(Kind: kind, From: comment.Author.Name, At: reply.PublishedAt, Action: PRAnswerAction.Comment, ThreadId: thread.Id));
            }
        }

        switch (record.Role)
        {
            case PRRole.Reviewer:
                answers.AddRange(collection: ReviewerAnswers(pr: pr, details: details, me: me, votes: votes, seenCutoff: seenCutoff));
                break;
            case PRRole.Author:
                // A vote that wanted changes, answered by your push. Only from a reviewer still on the pull request, as in
                // Needs you; your push may have reset the vote itself.
                foreach (var item in details.Activity.Where(predicate: item => item.Kind == ActivityKind.Vote && item.At > seenCutoff))
                {
                    if (item.Actor is not { } voter || voter.Id == me || item.Vote is not (Vote.WaitingForAuthor or Vote.Rejected)
                        || pr.FindReviewer(id: voter.Id) is null || pushes.Find(match: push => push.At > item.At) is not { } push)
                    {
                        continue;
                    }
                    answers.Add(item: new PRAnswer(
                        Kind: item.Vote == Vote.Rejected ? PREventKind.Rejected : PREventKind.ChangesRequested,
                        From: voter.Name,
                        At: push.At,
                        Action: PRAnswerAction.Push,
                        Commits: push.CommitCount));
                }
                break;
            case PRRole.Linked:
                break;
            default:
                throw new InvalidOperationException(message: "A pull request with an unknown role.");
        }
        return answers.Where(predicate: answer => now - answer.At < options.KeepAnsweredFor).ToList();
    }

    /// On a pull request you review: a review request, answered by your vote, and new commits since your vote, by voting
    /// again. Voting on a pull request you weren't on adds you as a reviewer yourself, which isn't a request.
    static List<PRAnswer> ReviewerAnswers(PullRequest pr, PRDetails details, string me, List<Activity> votes, DateTimeOffset seenCutoff)
    {
        var answers = new List<PRAnswer>();
        var additions = details.Activity.Where(predicate: item => item.Kind == ActivityKind.ReviewersChanged && item.Added.Contains(value: me)).ToList();
        (DateTimeOffset At, string By)? requested = null;
        if (additions.FindLast(match: item => item.Actor?.Id != me) is { } added)
        {
            requested = (added.At, added.Actor?.Name ?? pr.Author.Name);
        }
        else if (additions.Count == 0)
        {
            requested = (pr.CreatedAt, pr.Author.Name);
        }
        if (requested is { } request)
        {
            var published = details.Activity.LastOrDefault(predicate: item => item.Kind == ActivityKind.DraftChanged)?.At ?? DateTimeOffset.MinValue;
            var at = Later(first: request.At, second: published);
            if (at > seenCutoff && votes.Find(match: vote => vote.At > at) is { } vote)
            {
                answers.Add(item: new PRAnswer(Kind: PREventKind.ReviewRequest, From: request.By, At: vote.At, Action: PRAnswerAction.Vote, Vote: vote.Vote));
            }
        }
        for (var index = 1; index < votes.Count; index++)
        {
            var previous = votes[index - 1];
            var next = votes[index];
            var pushed = details.Activity.Any(predicate: item => item.Kind == ActivityKind.Push && item.At > previous.At && item.At < next.At && item.At > seenCutoff);
            if (pushed)
            {
                answers.Add(item: new PRAnswer(Kind: PREventKind.NewCommits, From: pr.Author.Name, At: next.At, Action: PRAnswerAction.Vote, Vote: next.Vote));
            }
        }
        return answers;
    }

    /// Comments from people, not bots, other than you, published after `after`.
    static IEnumerable<ReviewComment> Unanswered(ReviewThread thread, string me, DateTimeOffset after) =>
        thread.Comments.Where(predicate: comment => comment.Author.Id != me && !comment.Author.IsBot && comment.PublishedAt > after);

    /// Since when a thread's comments can need you: in an open one, those you've seen wait on you too, back to when you
    /// last took the pull request off Needs you; in a resolved one, only new ones are news.
    static DateTimeOffset WaitingSince(ReviewThread thread, DateTimeOffset seenCutoff, DateTimeOffset dismissedCutoff) =>
        thread.IsResolved ? seenCutoff : dismissedCutoff;

    static PREvent Event(PREventKind kind, ReviewComment comment, ReviewThread thread, DateTimeOffset seenCutoff) => new(
        Id: "c" + Text(number: thread.Id) + "." + Text(number: comment.Id),
        Kind: kind,
        At: comment.PublishedAt,
        Actor: comment.Author.Name,
        Text: comment.Text,
        ThreadId: thread.Id,
        IsNew: comment.PublishedAt > seenCutoff);

    /// "Sam Rivera replied", or "3 new replies"; "3 replies" once you've seen them.
    static (PRReason Reason, string Headline) Describe(PREvent top, List<PREvent> events)
    {
        var actor = top.Actor ?? "Someone";
        var sameKind = events.Count(predicate: item => item.Kind == top.Kind);
        var fresh = top.IsNew ? "new " : string.Empty;
        return top.Kind switch
        {
            PREventKind.Mention => (PRReason.Mentioned, actor + " mentioned you"),
            PREventKind.SentInChat => (PRReason.SentInChat, top.Actor is { } sender
                ? sender + " sent this in " + (top.App ?? "a chat")
                : "Sent to you in " + (top.App ?? "a chat")),
            PREventKind.Reply => (PRReason.Replied, sameKind > 1 ? Text(number: sameKind) + " " + fresh + "replies" : actor + " replied"),
            PREventKind.Comment => (PRReason.Commented, sameKind > 1 ? Text(number: sameKind) + " " + fresh + "comments" : actor + " commented"),
            PREventKind.ReviewRequest => (PRReason.ReviewRequested, "Review requested"),
            PREventKind.NewCommits => (PRReason.NewCommits, (top.Count switch
            {
                null => "New commits",
                1 => "1 new commit",
                { } count => Text(number: count) + " new commits",
            }) + " since your vote"),
            PREventKind.ChangesRequested => (PRReason.ChangesRequested, actor + " is waiting for you"),
            PREventKind.Rejected => (PRReason.Rejected, actor + " rejected it"),
            PREventKind.Approved => (PRReason.ReadyToComplete, actor + " approved"),
            _ => throw new InvalidOperationException(message: "An event of an unknown kind."),
        };
    }

    static string? EventDetail(PREvent item, PullRequest pr, PRRole role) => item.Kind switch
    {
        PREventKind.ReviewRequest or PREventKind.NewCommits => "By " + pr.Author.Name,
        PREventKind.SentInChat => role == PRRole.Author ? "Your pull request" : "By " + pr.Author.Name,
        _ => null,
    };

    /// Your pull request: failing, waiting for reviewers, changes or checks, or ready to complete. Whether it's ready is
    /// known only from policies that could be read, for the pull request as it is now: details read before its latest
    /// change, a push or a vote, may no longer apply.
    static PRPlacement ClassifyAuthor(PullRequest pr, PRDetails? details, List<Reviewer> approvals)
    {
        var checks = details?.Checks ?? [];
        var blocking = checks.Where(predicate: check => check.IsBlocking && check.Kind != CheckKind.Completion && check.State != CheckState.NotApplicable).ToList();
        var current = details is not null && details.Fingerprint == pr.Fingerprint;
        var known = current && details?.ChecksKnown == true;

        var failedBuilds = blocking.Where(predicate: check => check.Kind == CheckKind.Build && check.State == CheckState.Failed).ToList();
        var failedChecks = blocking.Where(predicate: check => check.Kind == CheckKind.Status && check.State == CheckState.Failed).ToList();
        var expired = blocking.Where(predicate: check => check.Kind == CheckKind.Build && check.State == CheckState.Expired).ToList();
        // What's wrong with its merge too, after a failed build or check: " · merge conflicts", " · merge failed".
        var conflicts = pr.HasConflicts ? " · merge conflicts"
            : pr.MergeProblem is { } failedMerge ? " · " + failedMerge.Headline.ToLowerInvariant()
            : string.Empty;
        if (failedBuilds.Count > 0)
        {
            // Each build with where it failed, once its timeline has been read: "shop-web CI · Run unit tests: …".
            var builds = failedBuilds.Select(selector: build => build.Failure is { } failure ? build.Name + " · " + failure.Summary : build.Name);
            return new PRPlacement(
                Group: PRGroup.Failing,
                Reason: PRReason.BuildFailed,
                Headline: failedBuilds.Count > 1 ? Text(number: failedBuilds.Count) + " builds failed" : "Build failed",
                Detail: string.Join(separator: ", ", values: builds.Concat(second: failedChecks.Select(selector: check => check.Name))) + conflicts,
                Since: LatestCompletion(checks: failedBuilds));
        }
        if (failedChecks.Count > 0)
        {
            return new PRPlacement(
                Group: PRGroup.Failing,
                Reason: PRReason.CheckFailed,
                Headline: failedChecks.Count > 1 ? Text(number: failedChecks.Count) + " checks failed" : "Check failed",
                Detail: Names(checks: failedChecks) + conflicts,
                Since: LatestCompletion(checks: failedChecks));
        }
        if (pr.HasConflicts)
        {
            return new PRPlacement(Group: PRGroup.Failing, Reason: PRReason.Conflicts, Headline: "Merge conflicts", Detail: pr.SourceBranch + " into " + pr.TargetBranch);
        }
        // Azure DevOps couldn't merge it otherwise, so it can't be completed either, however its policies stand.
        if (pr.MergeProblem is { } problem)
        {
            return new PRPlacement(Group: PRGroup.Failing, Reason: PRReason.MergeFailed, Headline: problem.Headline, Detail: problem.Detail);
        }
        if (expired.Count > 0)
        {
            return new PRPlacement(Group: PRGroup.Failing, Reason: PRReason.BuildExpired, Headline: "Build expired", Detail: Names(checks: expired) + " · queue it again");
        }

        var wantChanges = pr.Reviewers.Where(predicate: reviewer => reviewer.Vote.WantsChanges() && !reviewer.IsGroup).ToList();
        if ((wantChanges.Find(match: reviewer => reviewer.Vote == Vote.Rejected) ?? wantChanges.FirstOrDefault()) is { } first)
        {
            var rejected = first.Vote == Vote.Rejected;
            return new PRPlacement(
                Group: PRGroup.Waiting,
                Reason: rejected ? PRReason.Rejected : PRReason.ChangesRequested,
                Headline: rejected ? "Rejected" : "Changes requested",
                Detail: string.Join(separator: ", ", values: wantChanges.Select(selector: reviewer => reviewer.Person.Name)));
        }

        var running = blocking.Where(predicate: check => check.Kind is CheckKind.Build or CheckKind.Status
            && check.State is CheckState.Running or CheckState.Queued or CheckState.Pending).ToList();
        var notRun = blocking.Where(predicate: check => check.Kind == CheckKind.Build && check.State == CheckState.NotRun).ToList();
        var reviewersPending = blocking.Where(predicate: check => check.Kind == CheckKind.Reviewers && check.State != CheckState.Passed).ToList();
        var requirements = blocking.Where(predicate: check => check.Kind == CheckKind.Requirement && check.State != CheckState.Passed).ToList();
        var hasReviewerPolicy = checks.Any(predicate: check => check.Kind == CheckKind.Reviewers && check.IsBlocking);
        var approvedBy = approvals.Count == 0 ? null : "Approved by " + string.Join(separator: ", ", values: approvals.Select(selector: reviewer => reviewer.Person.Name));
        // A reviewer it requires holds it up until they approve, whether a policy or someone added them, even one who
        // declined: Azure DevOps won't complete it before. A team, such as one a policy adds, counts as its policy says.
        var requiredWaiting = pr.Reviewers.Where(predicate: reviewer => reviewer.IsRequired && !reviewer.IsGroup && !reviewer.Vote.IsApproval()).ToList();

        if (known && running.Count == 0 && notRun.Count == 0 && reviewersPending.Count == 0 && requirements.Count == 0 && requiredWaiting.Count == 0
            && (hasReviewerPolicy || approvals.Count > 0))
        {
            return new PRPlacement(
                Group: PRGroup.Ready,
                Reason: pr.AutoComplete ? PRReason.AutoComplete : PRReason.ReadyToComplete,
                Headline: pr.AutoComplete ? "Completing automatically" : "Ready to complete",
                Detail: approvedBy ?? "No approvals required");
        }

        var progress = new List<string>();
        if (reviewersPending.Select(selector: check => check.MinimumApprovers).Max() is { } minimum && minimum > 0)
        {
            progress.Add(item: Text(number: approvals.Count) + " of " + Text(number: minimum) + " approvals");
        }
        else
        {
            progress.Add(item: approvedBy ?? "No approvals yet");
        }
        if (requiredWaiting.Count > 0)
        {
            var names = ListWords.Join(names: requiredWaiting.Select(selector: reviewer => reviewer.Person.Name).ToList(), limit: 3);
            progress.Add(item: names + (requiredWaiting.Count == 1 ? " is required" : " are required"));
        }
        if (running.Count > 0)
        {
            progress.Add(item: running.Exists(match: check => check.Kind == CheckKind.Build) ? "build running" : "checks running");
        }

        if (!current)
        {
            return new PRPlacement(Group: PRGroup.Waiting, Reason: PRReason.WaitingForReviewers, Headline: "Waiting for reviewers", Detail: progress[0]);
        }
        if (details?.ChecksKnown == false)
        {
            return new PRPlacement(Group: PRGroup.Waiting, Reason: PRReason.RequirementsPending, Headline: "Can't read its policies", Detail: progress[0]);
        }
        if (reviewersPending.Count > 0 || requiredWaiting.Count > 0 || (!hasReviewerPolicy && approvals.Count == 0))
        {
            return new PRPlacement(Group: PRGroup.Waiting, Reason: PRReason.WaitingForReviewers, Headline: "Waiting for reviewers", Detail: string.Join(separator: " · ", values: progress));
        }
        if (running.Count > 0)
        {
            var builds = running.Exists(match: check => check.Kind == CheckKind.Build);
            return new PRPlacement(Group: PRGroup.Waiting, Reason: PRReason.ChecksRunning, Headline: builds ? "Build running" : "Checks running", Detail: Names(checks: running));
        }
        if (notRun.Count > 0)
        {
            return new PRPlacement(Group: PRGroup.Waiting, Reason: PRReason.RequirementsPending, Headline: "Build hasn't run", Detail: Names(checks: notRun) + " · queue it");
        }
        return new PRPlacement(Group: PRGroup.Waiting, Reason: PRReason.RequirementsPending, Headline: RequirementHeadline(requirements: requirements), Detail: progress[0]);
    }

    /// A pull request you review, or watch: approved, waiting for its author, or to review.
    static PRPlacement ClassifyReviewer(PullRequest pr, string me, List<Reviewer> approvals, bool watched)
    {
        var mine = pr.FindReviewer(id: me);
        switch (mine?.Vote ?? Vote.None)
        {
            case Vote.Approved or Vote.ApprovedWithSuggestions:
                var others = approvals.Where(predicate: reviewer => reviewer.Person.Id != me).Select(selector: reviewer => reviewer.Person.Name).ToList();
                return new PRPlacement(
                    Group: PRGroup.Idle,
                    Reason: PRReason.YouApproved,
                    Headline: "You approved",
                    Detail: others.Count == 0 ? "By " + pr.Author.Name : "Also approved by " + string.Join(separator: ", ", values: others));
            case Vote.WaitingForAuthor:
                return new PRPlacement(Group: PRGroup.Waiting, Reason: PRReason.WaitingForAuthor, Headline: "Waiting for the author", Detail: "You asked " + pr.Author.Name + " for changes");
            case Vote.Rejected:
                return new PRPlacement(Group: PRGroup.Waiting, Reason: PRReason.WaitingForAuthor, Headline: "You rejected it", Detail: "By " + pr.Author.Name);
            default:
                var headline = mine?.IsRequired == true ? "Required review" : mine is null && watched ? "Watching" : "Optional review";
                return new PRPlacement(Group: PRGroup.ToReview, Reason: PRReason.ReviewPending, Headline: headline, Detail: "By " + pr.Author.Name);
        }
    }

    /// Done, for your own pull requests: completed or abandoned within `KeepDoneFor`, and not seen since, or merged with
    /// pipelines that still run, wait or failed after it.
    static PRSnapshot? Closed(PRRecord record, PRSnapshot snapshot, DateTimeOffset seenCutoff, DateTimeOffset now, DateTimeOffset lastActivity, ClassifierOptions options)
    {
        // Done is for your own pull requests.
        if (record.Role != PRRole.Author)
        {
            return null;
        }
        var pr = record.PullRequest;
        var closed = pr.ClosedAt ?? lastActivity;
        if (now - closed > options.KeepDoneFor)
        {
            return null;
        }
        var completed = pr.Status == PullRequestStatus.Completed;
        var merge = completed ? record.Merge?.Summary : null;
        snapshot = snapshot with { Merge = merge };
        PRSnapshot Placed(PRPlacement placement) => snapshot with
        {
            Group = placement.Group,
            Reason = placement.Reason,
            Headline = placement.Headline,
            Detail = string.IsNullOrEmpty(value: placement.Detail) ? null : placement.Detail,
            Since = placement.Since ?? lastActivity,
        };
        // What its pipelines do after it merged shows, whether or not you've seen it since. Once they've all finished,
        // passed or canceled, it's Done until you've seen it.
        if (merge is not null && merge.Outcome is not (MergeOutcome.Passed or MergeOutcome.Canceled))
        {
            switch (merge.Outcome)
            {
                case MergeOutcome.Failed:
                    snapshot = Placed(placement: new PRPlacement(
                        Group: PRGroup.Failing,
                        Reason: PRReason.FailedAfterMerge,
                        Headline: "Failed after merge",
                        Detail: string.Join(separator: " · ", values: new[] { merge.Pipeline, merge.Failure?.Summary }.OfType<string>()),
                        Since: merge.Since ?? closed)) with
                    {
                        Failure = merge.Failure,
                    };
                    break;
                case MergeOutcome.Waiting:
                    snapshot = Placed(placement: new PRPlacement(
                        Group: PRGroup.Done,
                        Reason: PRReason.WaitingForApproval,
                        Headline: "Waiting for approval",
                        Detail: string.Join(separator: " · ", values: new[] { merge.Pipeline, merge.Stage }.OfType<string>()),
                        Since: merge.Since ?? closed));
                    break;
                default:
                    var running = merge.Running == 1 ? "1 pipeline running" : Text(number: merge.Running) + " pipelines running";
                    snapshot = Placed(placement: new PRPlacement(
                        Group: PRGroup.Done, Reason: PRReason.Completed, Headline: "Completed", Detail: "Merged into " + pr.TargetBranch + " · " + running, Since: closed));
                    break;
            }
            if (merge.Outcome != MergeOutcome.Running && merge.RunUrl is { } url)
            {
                snapshot = snapshot with { Url = url };
            }
            return snapshot;
        }
        if (closed <= seenCutoff)
        {
            return null;
        }
        var detail = completed ? "Merged into " + pr.TargetBranch : null;
        if (merge is not null)
        {
            detail = (detail ?? string.Empty) + merge.Outcome switch
            {
                MergeOutcome.Canceled => merge.Total == 1 ? " · its pipeline was canceled" : " · “" + merge.Pipeline + "” was canceled",
                _ => merge.Total == 1 ? " · its pipeline passed" : " · " + Text(number: merge.Total) + " pipelines passed",
            };
        }
        return Placed(placement: new PRPlacement(
            Group: PRGroup.Done,
            Reason: completed ? PRReason.Completed : PRReason.Abandoned,
            Headline: completed ? "Completed" : "Abandoned",
            Detail: detail,
            Since: closed));
    }

    static string RequirementHeadline(List<Check> requirements) => requirements.FirstOrDefault()?.Name switch
    {
        null => "Waiting",
        "Comment requirements" => "Resolve comments",
        "Work item linking" => "Link a work item",
        { } name => name,
    };

    static string Names(List<Check> checks) => string.Join(separator: ", ", values: checks.Select(selector: check => check.Name));

    static DateTimeOffset? LatestCompletion(List<Check> checks) => checks.Select(selector: check => check.CompletedAt).Max();

    static DateTimeOffset Later(DateTimeOffset first, DateTimeOffset second) => first > second ? first : second;

    static string Text(int number) => number.ToString(provider: CultureInfo.InvariantCulture);
}
