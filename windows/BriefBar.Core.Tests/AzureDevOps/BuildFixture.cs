using System.Text.Json.Nodes;
using BriefBar.Core.AzureDevOps;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Made-up pipeline runs and their timelines, as Azure DevOps sends them: the Swift tests' `WorkFixture.build`, `record`
/// and `timeline`.
internal static class BuildFixture
{
    /// A run of "pipeline {definition}", in the folder `\Shop`, queued at `queued`: started half a minute later unless it
    /// hasn't started, and finished `minutes` after that once it's completed. Sam asked for it unless `requestedFor` says
    /// who did.
    public static JsonObject Build(
        int id,
        int definition,
        DateTimeOffset queued,
        string status = "completed",
        string? result = "succeeded",
        double minutes = 5,
        string branch = "refs/heads/main",
        string reason = "individualCI",
        Person? requestedFor = null,
        string project = "p1")
    {
        var json = new JsonObject
        {
            ["id"] = id,
            ["buildNumber"] = "20261018." + Fixture.Text(number: id),
            ["status"] = status,
            ["reason"] = reason,
            ["sourceBranch"] = branch,
            ["queueTime"] = Fixture.Iso(date: queued),
            ["definition"] = new JsonObject { ["id"] = definition, ["name"] = "pipeline " + Fixture.Text(number: definition), ["path"] = "\\Shop" },
            ["project"] = new JsonObject { ["id"] = project, ["name"] = project == "p1" ? "Shop" : "Other" },
            ["requestedFor"] = Fixture.Identity(person: requestedFor ?? People.Sam),
        };
        if (result is not null)
        {
            json["result"] = result;
        }
        if (status != "notStarted")
        {
            json["startTime"] = Fixture.Iso(date: queued.AddSeconds(seconds: 30));
        }
        if (status == "completed")
        {
            json["finishTime"] = Fixture.Iso(date: queued.AddSeconds(seconds: 30 + (minutes * 60)));
        }
        return json;
    }

    /// A record of a run's timeline, a stage, phase, job, task or checkpoint, completed and succeeded unless said, with
    /// the issues it logged. Its parent and result are null rather than left out, as Azure DevOps sends them.
    public static JsonObject Record(
        string id,
        string type,
        string name,
        string? parent = null,
        int? order = null,
        string state = "completed",
        string? result = "succeeded",
        string? identifier = null,
        DateTimeOffset? finished = null,
        IEnumerable<JsonNode>? issues = null)
    {
        var json = new JsonObject
        {
            ["id"] = id,
            ["type"] = type,
            ["name"] = name,
            ["state"] = state,
            ["issues"] = new JsonArray(items: [.. issues ?? []]),
            ["parentId"] = parent,
            ["result"] = result,
        };
        if (order is { } position)
        {
            json["order"] = position;
        }
        if (identifier is not null)
        {
            json["identifier"] = identifier;
        }
        if (finished is { } date)
        {
            json["finishTime"] = Fixture.Iso(date: date);
        }
        return json;
    }

    /// An issue a timeline record logged: an error unless said.
    public static JsonObject Issue(string message, string type = "error") => new() { ["type"] = type, ["message"] = message };

    /// A run's timeline, of `records`.
    public static JsonObject Timeline(IEnumerable<JsonNode> records) => new()
    {
        ["id"] = Guid.NewGuid().ToString(),
        ["changeId"] = 1,
        ["records"] = new JsonArray(items: [.. records]),
    };
}
