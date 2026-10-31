using BriefBar.Core.Copilot;

namespace BriefBar.Core.Demo;

/// Made-up Copilot sessions, as the engine would read them from the Copilot app: what each session's database row says,
/// and its log, as events, all minutes before `now`. Three need you, two run (one started by the other), one finished,
/// one stopped responding, and two are idle. Nothing is read: for `--demo`, screenshots and tests.
public static class CopilotDemoData
{
    public static EngineSnapshot Snapshot(DateTimeOffset now) => new()
    {
        Records =
        [
            Record(id: "demo-release", name: "Release 2.4.0", project: "acme-api", running: true, minutes: 1, now: now, usage: (82_000, 200_000), log:
            [
                Event(kind: LogEventKind.UserMessage, now: now, minutes: 5),
                Event(kind: LogEventKind.PermissionRequested(request: new PermissionRequest
                {
                    RequestId = "push", Kind = "shell", Detail = "git push origin main --follow-tags",
                }), now: now, minutes: 1),
            ]),
            Record(id: "demo-oauth", name: "Move sign-in to OAuth 2.1", project: "acme-api", running: true, minutes: 2, now: now, usage: (151_000, 200_000), log:
            [
                Event(kind: LogEventKind.UserMessage, now: now, minutes: 12),
                Event(kind: LogEventKind.ToolStarted(tool: new ToolStart
                {
                    CallId = "plan", Name = "exit_plan_mode", PlanSummary = "Replace cookie sessions with OAuth 2.1 and PKCE.",
                }), now: now, minutes: 2),
            ]),
            Record(id: "demo-dark-mode", name: "Add dark mode to settings", project: "shop-web", running: true, minutes: 4, now: now, usage: (41_000, 128_000), log:
            [
                Event(kind: LogEventKind.UserMessage, now: now, minutes: 9),
                Event(kind: LogEventKind.ToolStarted(tool: new ToolStart
                {
                    CallId = "ask", Name = "ask_user", Question = "Should dark mode follow the system appearance?",
                    Choices = ["Follow the system", "Always dark", "Let me choose"],
                }), now: now, minutes: 4),
            ]),
            Record(id: "demo-payments", name: "Migrate payments to the new SDK", project: "payments-api", running: true, minutes: 3, now: now, usage: (64_000, 200_000), log:
            [
                Event(kind: LogEventKind.UserMessage, now: now, minutes: 3),
                Event(kind: LogEventKind.ToolStarted(tool: new ToolStart
                {
                    CallId = "update", Name = "bash", Description = "Updating 14 call sites in PaymentsClient",
                }), now: now, minutes: 1),
            ]),
            Record(id: "demo-screenshots", name: "Update the README screenshots", project: "docs-site", running: true, minutes: 6, now: now, parent: "demo-payments", log:
            [
                Event(kind: LogEventKind.UserMessage, now: now, minutes: 6),
                Event(kind: LogEventKind.ToolStarted(tool: new ToolStart
                {
                    CallId = "capture", Name = "bash", Description = "Capturing dark mode",
                }), now: now, minutes: 2),
            ]),
            Record(id: "demo-sync-retry", name: "Add retry to sync", project: "shop-web", running: false, minutes: 9, now: now, log:
            [
                Event(kind: LogEventKind.UserMessage, now: now, minutes: 20),
                Event(kind: LogEventKind.TaskComplete(summary: "Added retry with backoff to sync. Its tests pass.", success: true), now: now, minutes: 9),
            ]),
            // The log says it was mid-turn, but the app no longer runs it: it stopped responding.
            Record(id: "demo-flaky-login", name: "Fix the flaky login test", project: "shop-web", running: false, minutes: 31, now: now, log:
            [
                Event(kind: LogEventKind.UserMessage, now: now, minutes: 40),
                Event(kind: LogEventKind.ToolStarted(tool: new ToolStart
                {
                    CallId = "tests", Name = "bash", Description = "Run the login tests",
                }), now: now, minutes: 31),
            ]),
            Record(id: "demo-changelog", name: "Tidy the changelog", project: "docs-site", running: false, minutes: 180, now: now, log:
            [
                Event(kind: LogEventKind.UserMessage, now: now, minutes: 200),
                Event(kind: LogEventKind.TaskComplete(summary: "Tidied the changelog.", success: true), now: now, minutes: 180),
            ]),
            Record(id: "demo-release-dates", name: "Ask about release dates", project: null, running: false, minutes: 1_500, now: now, log: null),
        ],
    };

    static SessionRecord Record(
        string id, string name, string? project, bool running, int minutes, DateTimeOffset now, LogEvent[]? log,
        (long Tokens, long Limit)? usage = null, string? parent = null)
    {
        SessionLogState? state = null;
        if (log is not null)
        {
            state = new SessionLogState();
            state.Apply(events: log);
        }
        return new SessionRecord(
            Meta: new SessionMeta
            {
                Id = id,
                Name = name,
                SessionType = project is null ? "general_chat" : "project",
                Mode = "interactive",
                IsRunning = running,
                CreatedAt = now.AddDays(days: -1),
                UpdatedAt = now.AddMinutes(minutes: -minutes),
                ProjectName = project,
                Branch = project is null ? null : id,
                WorkspaceId = project is null ? null : "workspace-" + id,
                ParentSessionId = parent,
                ContextUsage = usage is { } measured ? new ContextUsage(Tokens: measured.Tokens, Limit: measured.Limit) : null,
            },
            Log: state);
    }

    static LogEvent Event(LogEventKind kind, DateTimeOffset now, int minutes) => new(Timestamp: now.AddMinutes(minutes: -minutes), Kind: kind);
}
