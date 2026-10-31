namespace BriefBar.Core.Copilot;

/// A question you'd otherwise see twice. When a session waits on a question or a plan, the app tells the session that
/// coordinates it, which then asks you for it: it relays the question (`relay_session_input`), or asks about the plan in
/// its own words (`ask_user`), since a plan can't be relayed. Both then wait on the same decision. Answered in the
/// coordinator, it reaches the session. A plan approved in the session itself leaves the coordinator's question waiting,
/// and approving it there fails. The Mac's `RelayedQuestions`.
public static class RelayedQuestions
{
    /// The deepest relay of a relay whose words are looked for.
    const int MaxRelayDepth = 8;

    /// The snapshots, with what each coordinator asks you for the sessions it coordinates shown once, on its own row.
    ///
    /// A coordinator asks for a session when it relays that session's question, or asks a question of its own while the
    /// session has waited on a question or plan since before. Until then the session needs you on its own. Each session
    /// asked for moves to Running (`Relayed`), to be answered in the coordinator, or in that coordinator's coordinator
    /// when it asks for the coordinator in turn. The coordinator stays in Needs you, waiting since the longest-waiting of
    /// them, with the words of the question it relays, which a relay doesn't repeat. Permission prompts are never asked
    /// for: only the session itself can answer one.
    /// - `records`: what the snapshots were resolved from, with the same IDs.
    public static List<SessionSnapshot> Merge(IReadOnlyList<SessionSnapshot> snapshots, IReadOnlyList<SessionRecord> records)
    {
        ArgumentNullException.ThrowIfNull(argument: snapshots);
        ArgumentNullException.ThrowIfNull(argument: records);
        var recordsById = FirstById(items: records, id: record => record.Id);
        var byId = FirstById(items: snapshots, id: snapshot => snapshot.Id);

        // The question each session waits for your answer to.
        var questions = new Dictionary<string, PendingTool>(comparer: StringComparer.Ordinal);
        foreach (var snapshot in snapshots)
        {
            if (snapshot is { Phase: DisplayPhase.NeedsYou, Reason: StatusReason.Question }
                && recordsById.GetValueOrDefault(key: snapshot.Id)?.Log?.Activity is { Type: LogActivityType.NeedsAnswer, Tool: { } tool })
            {
                questions[snapshot.Id] = tool;
            }
        }
        if (questions.Count == 0)
        {
            return [.. snapshots];
        }

        // A relay names the session by its ID or its workspace's.
        var named = new Dictionary<string, string>(comparer: StringComparer.Ordinal);
        foreach (var snapshot in snapshots)
        {
            named[snapshot.Id] = snapshot.Id;
        }
        foreach (var snapshot in snapshots)
        {
            if (recordsById.GetValueOrDefault(key: snapshot.Id)?.Meta.WorkspaceId is { } workspaceId)
            {
                named.TryAdd(key: workspaceId, value: snapshot.Id);
            }
        }

        // The coordinator that asks you for each session.
        var askedIn = new Dictionary<string, string>(comparer: StringComparer.Ordinal);

        string Root(string session)
        {
            var current = session;
            var seen = new HashSet<string>(comparer: StringComparer.Ordinal) { session };
            while (askedIn.TryGetValue(key: current, value: out var next) && seen.Add(item: next))
            {
                current = next;
            }
            return current;
        }

        void Ask(string session, string coordinator)
        {
            if (askedIn.ContainsKey(key: session) || session == coordinator || Root(session: coordinator) == session)
            {
                return;
            }
            askedIn[session] = coordinator;
        }

        string? Relayed(PendingTool tool) => tool.RelayedSession is { } relayed ? named.GetValueOrDefault(key: relayed) : null;

        // Every question a coordinator relays while a relay is what it asks you: it can relay several at once. Its own
        // question or plan, when it waits on one, comes first instead.
        foreach (var (coordinator, tool) in questions.OrderBy(keySelector: pair => pair.Key, comparer: StringComparer.Ordinal))
        {
            if (!tool.RelaysQuestion)
            {
                continue;
            }
            var relays = recordsById.GetValueOrDefault(key: coordinator)?.Log?.PendingTools.Values.Where(predicate: pending => pending.RelaysQuestion).ToList()
                ?? [tool];
            foreach (var relay in relays
                .OrderBy(keySelector: pending => pending.StartedAt ?? DateTimeOffset.MinValue)
                .ThenBy(keySelector: pending => pending.CallId, comparer: StringComparer.Ordinal))
            {
                if (Relayed(tool: relay) is { } session
                    && byId.GetValueOrDefault(key: session) is { Phase: DisplayPhase.NeedsYou, Reason: StatusReason.Question })
                {
                    Ask(session: session, coordinator: coordinator);
                }
            }
        }
        foreach (var snapshot in snapshots)
        {
            if (snapshot is { Phase: DisplayPhase.NeedsYou, Reason: StatusReason.Question or StatusReason.PlanApproval }
                && recordsById.GetValueOrDefault(key: snapshot.Id)?.Meta.CoordinatorSessionId is { } coordinator
                && questions.ContainsKey(key: coordinator)
                && snapshot.Since is { } waitingSince
                && byId.GetValueOrDefault(key: coordinator)?.Since is { } askedSince
                && waitingSince <= askedSince)
            {
                Ask(session: snapshot.Id, coordinator: coordinator);
            }
        }
        if (askedIn.Count == 0)
        {
            return [.. snapshots];
        }

        // What a session asks you: a relay's words are those of the session it relays.
        (string? Detail, ValueList<string> Choices) Words(string session, int depth = 0)
        {
            if (depth < MaxRelayDepth && questions.TryGetValue(key: session, value: out var tool) && Relayed(tool: tool) is { } relayedSession
                && askedIn.GetValueOrDefault(key: relayedSession) == session)
            {
                var relayedWords = Words(session: relayedSession, depth: depth + 1);
                if (relayedWords.Detail is not null)
                {
                    return relayedWords;
                }
            }
            var own = byId.GetValueOrDefault(key: session);
            return (own?.Detail, own?.Choices ?? ValueList<string>.Empty);
        }

        var asksFor = new Dictionary<string, List<SessionSnapshot>>(comparer: StringComparer.Ordinal);
        foreach (var session in askedIn.Keys)
        {
            if (byId.GetValueOrDefault(key: session) is { } snapshot)
            {
                var root = Root(session: session);
                if (!asksFor.TryGetValue(key: root, value: out var list))
                {
                    list = [];
                    asksFor[root] = list;
                }
                list.Add(item: snapshot);
            }
        }

        return snapshots.Select(selector: original =>
        {
            if (askedIn.ContainsKey(key: original.Id) && byId.GetValueOrDefault(key: Root(session: original.Id)) is { } coordinator)
            {
                var answerIn = new RelatedSession(Id: coordinator.Id, Name: coordinator.DisplayName);
                var (detail, choices) = Words(session: original.Id);
                return original with
                {
                    Detail = detail,
                    Choices = choices,
                    Phase = DisplayPhase.Running,
                    Reason = StatusReason.Relayed,
                    Headline = "Answer in “" + answerIn.Name + "”",
                    AnswerIn = answerIn,
                };
            }
            if (asksFor.TryGetValue(key: original.Id, value: out var sessions))
            {
                var ordered = sessions
                    .OrderBy(keySelector: session => session.Since ?? DateTimeOffset.MaxValue)
                    .ThenBy(keySelector: session => session.Id, comparer: StringComparer.Ordinal)
                    .ToList();
                var (detail, choices) = Words(session: original.Id);
                var since = ordered.Select(selector: session => session.Since).Prepend(element: original.Since)
                    .Where(predicate: date => date is not null).Min();
                return original with
                {
                    Detail = detail,
                    Choices = choices,
                    Since = since,
                    AsksFor = new ValueList<RelatedSession>(items: ordered.Select(selector: session => new RelatedSession(Id: session.Id, Name: session.DisplayName))),
                };
            }
            return original;
        }).ToList();
    }

    static Dictionary<string, T> FirstById<T>(IEnumerable<T> items, Func<T, string> id)
    {
        var result = new Dictionary<string, T>(comparer: StringComparer.Ordinal);
        foreach (var item in items)
        {
            result.TryAdd(key: id(arg: item), value: item);
        }
        return result;
    }
}
