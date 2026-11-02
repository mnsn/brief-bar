namespace BriefBar.Core.AzureDevOps;

/// One branch policy on a pull request, simplified: a build, a status, reviewers, a requirement, or the merge strategy.
/// The Mac's `Check`.
public sealed record Check(
    string Name,
    CheckKind Kind,
    CheckState State,
    bool IsBlocking = true,
    int? MinimumApprovers = null,
    DateTimeOffset? CompletedAt = null,
    int? BuildId = null,
    PipelineFailure? Failure = null)
{
    /// The run of a build that failed, whose timeline says where: null for anything else.
    public int? FailedBuildId => Kind == CheckKind.Build && State == CheckState.Failed ? BuildId : null;

    /// Lowercased identity IDs of the people and teams a required-reviewers policy requires, as reviewers' are; empty
    /// when it doesn't say.
    public ValueList<string> ReviewerIds
    {
        get;
        init
        {
            ArgumentNullException.ThrowIfNull(argument: value);
            field = new ValueList<string>(items: value.Select(selector: id => id.ToLowerInvariant()));
        }
    } = [];

    /// The check `evaluation` says, or null for a disabled policy.
    public static Check? From(ADOPolicyEvaluation evaluation)
    {
        ArgumentNullException.ThrowIfNull(argument: evaluation);
        var configuration = evaluation.Configuration;
        if (configuration.IsEnabled == false)
        {
            return null;
        }
        var type = configuration.TypeName;
        var settings = configuration.Settings;
        var context = evaluation.Context;
        var status = evaluation.Status ?? "queued";
        CheckKind kind;
        string name;
        CheckState state;
        switch (type)
        {
            case "Build":
                kind = CheckKind.Build;
                name = NonEmpty(text: settings?.DisplayName) ?? NonEmpty(text: context?.BuildDefinitionName) ?? "Build";
                state = status switch
                {
                    "approved" => CheckState.Passed,
                    "rejected" or "broken" => context?.IsExpired == true ? CheckState.Expired : CheckState.Failed,
                    "running" => CheckState.Running,
                    "notApplicable" => CheckState.NotApplicable,
                    // Queued: an expired build waits to be queued again; one without a build never ran.
                    _ when context?.IsExpired == true => CheckState.Expired,
                    _ when context?.BuildId is null => CheckState.NotRun,
                    _ => CheckState.Queued,
                };
                break;
            case "Status":
                kind = CheckKind.Status;
                var genre = settings?.StatusGenre is { } statusGenre ? (statusGenre.Length == 0 ? string.Empty : statusGenre + "/") : string.Empty;
                name = NonEmpty(text: settings?.DefaultDisplayName)
                    ?? (NonEmpty(text: settings?.StatusName) is { } statusName ? genre + statusName : null)
                    ?? "Status check";
                state = status switch
                {
                    "approved" => CheckState.Passed,
                    "rejected" or "broken" => CheckState.Failed,
                    "running" => CheckState.Running,
                    "notApplicable" => CheckState.NotApplicable,
                    _ => CheckState.Pending,
                };
                break;
            default:
                name = type;
                kind = type switch
                {
                    "Minimum number of reviewers" or "Required reviewers" or "Proof Of Presence" => CheckKind.Reviewers,
                    "Require a merge strategy" => CheckKind.Completion,
                    _ => CheckKind.Requirement,
                };
                state = status switch
                {
                    "approved" => CheckState.Passed,
                    "notApplicable" => CheckState.NotApplicable,
                    // A requirement that isn't met yet is reported as rejected: it's pending, not failed.
                    _ => CheckState.Pending,
                };
                break;
        }
        return new Check(
            Name: name,
            Kind: kind,
            State: state,
            IsBlocking: configuration.IsBlocking ?? true,
            MinimumApprovers: settings?.MinimumApproverCount,
            CompletedAt: evaluation.CompletedDate,
            BuildId: kind == CheckKind.Build ? context?.BuildId : null)
        {
            ReviewerIds = kind == CheckKind.Reviewers ? settings?.RequiredReviewerIds ?? [] : [],
        };
    }

    static string? NonEmpty(string? text) => text?.Trim() is { Length: > 0 } trimmed ? trimmed : null;
}
