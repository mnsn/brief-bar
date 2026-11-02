using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using BriefBar.Core.AzureDevOps;

namespace BriefBar.Core.Tests.AzureDevOps;

/// Made-up Azure DevOps JSON, as the Swift tests' `Fixture` makes it, for the shapes BriefBar reads.
internal static class Fixture
{
    public const string Org = "contoso";

    /// Your identity's ID, lowercased.
    public static string Me => People.Me.Id;

    /// Someone as Azure DevOps names them: their ID in capitals, as it sends it, and an email-style name, or a build
    /// service's.
    public static JsonObject Identity(Person person, string? unique = null) => new()
    {
        ["id"] = person.Id.ToUpperInvariant(),
        ["displayName"] = person.Name,
        ["uniqueName"] = unique ?? (person.IsBot ? "Build\\" + person.Id : person.FirstName.ToLowerInvariant() + "@contoso.com"),
    };

    public static JsonObject Reviewer(Person person, int vote = 0, bool required = false, bool group = false)
    {
        var json = Identity(person: person);
        json["vote"] = vote;
        json["isRequired"] = required;
        if (group)
        {
            json["isContainer"] = true;
        }
        return json;
    }

    public static JsonObject PullRequest(
        int id,
        string title = "Fix the checkout total",
        Person? author = null,
        IEnumerable<JsonNode>? reviewers = null,
        DateTimeOffset? created = null,
        string status = "active",
        DateTimeOffset? closed = null,
        string merge = "succeeded",
        bool draft = false,
        string sourceCommit = "abc",
        string project = "p1",
        string repository = "r1")
    {
        var json = new JsonObject
        {
            ["pullRequestId"] = id,
            ["codeReviewId"] = id,
            ["title"] = title,
            ["status"] = status,
            ["createdBy"] = Identity(person: author ?? People.Me),
            ["creationDate"] = Iso(date: created ?? TestTimes.T(seconds: -2 * Make.Day)),
            ["sourceRefName"] = "refs/heads/fix-total",
            ["targetRefName"] = "refs/heads/main",
            ["mergeStatus"] = merge,
            ["isDraft"] = draft,
            ["reviewers"] = new JsonArray(items: [.. reviewers ?? []]),
            ["repository"] = new JsonObject
            {
                ["id"] = repository,
                ["name"] = "shop-web",
                ["url"] = "https://example.invalid",
                ["project"] = new JsonObject { ["id"] = project, ["name"] = "Shop", ["state"] = "wellFormed" },
            },
            ["lastMergeSourceCommit"] = new JsonObject { ["commitId"] = sourceCommit },
            ["lastMergeTargetCommit"] = new JsonObject { ["commitId"] = "def" },
            ["url"] = "https://example.invalid",
            ["supportsIterations"] = true,
        };
        if (closed is { } date)
        {
            json["closedDate"] = Iso(date: date);
        }
        return json;
    }

    public static JsonObject Evaluation(
        string type, string status, bool blocking = true, bool enabled = true, JsonObject? settings = null, JsonObject? context = null, DateTimeOffset? completed = null)
    {
        var json = new JsonObject
        {
            ["evaluationId"] = Guid.NewGuid().ToString(),
            ["status"] = status,
            ["configuration"] = new JsonObject
            {
                ["isEnabled"] = enabled,
                ["isBlocking"] = blocking,
                ["type"] = new JsonObject { ["id"] = Guid.NewGuid().ToString(), ["displayName"] = type },
                ["settings"] = settings ?? [],
            },
        };
        if (context is not null)
        {
            json["context"] = context;
        }
        if (completed is { } date)
        {
            json["completedDate"] = Iso(date: date);
        }
        return json;
    }

    public static JsonObject Comment(int id, Person author, string content, DateTimeOffset at, string type = "text", bool deleted = false) => new()
    {
        ["id"] = id,
        ["parentCommentId"] = 0,
        ["author"] = Identity(person: author),
        ["content"] = content,
        ["publishedDate"] = Iso(date: at),
        ["lastUpdatedDate"] = Iso(date: at),
        ["commentType"] = type,
        ["isDeleted"] = deleted,
    };

    public static JsonObject Thread(
        int id, IEnumerable<JsonNode> comments, DateTimeOffset published, string status = "active", JsonObject? properties = null, JsonObject? identities = null, string? filePath = null)
    {
        var json = new JsonObject
        {
            ["id"] = id,
            ["publishedDate"] = Iso(date: published),
            ["lastUpdatedDate"] = Iso(date: published),
            ["status"] = status,
            ["comments"] = new JsonArray(items: [.. comments]),
            ["isDeleted"] = false,
        };
        if (properties is not null)
        {
            json["properties"] = properties;
        }
        if (identities is not null)
        {
            json["identities"] = identities;
        }
        if (filePath is not null)
        {
            json["threadContext"] = new JsonObject
            {
                ["filePath"] = filePath,
                ["rightFileStart"] = new JsonObject { ["line"] = 12, ["offset"] = 1 },
                ["rightFileEnd"] = new JsonObject { ["line"] = 12, ["offset"] = 9 },
            };
        }
        return json;
    }

    /// A system thread recording activity, such as `VoteUpdate`, by `person`, whose identity is key `1`.
    public static JsonObject Activity(int id, string type, DateTimeOffset at, Person by, IReadOnlyDictionary<string, string>? properties = null, IReadOnlyDictionary<string, JsonNode>? identities = null)
    {
        var props = new JsonObject { ["CodeReviewThreadType"] = Property(value: type) };
        foreach (var (key, value) in properties ?? new Dictionary<string, string>())
        {
            props[key] = Property(value: value);
        }
        var known = new JsonObject { ["1"] = Identity(person: by) };
        foreach (var (key, value) in identities ?? new Dictionary<string, JsonNode>())
        {
            known[key] = value.DeepClone();
        }
        var byKey = type switch
        {
            "VoteUpdate" => "CodeReviewVotedByIdentity",
            "RefUpdate" => "CodeReviewRefUpdatedByIdentity",
            "ReviewersUpdate" => "CodeReviewReviewersUpdatedByIdentity",
            _ => null,
        };
        if (byKey is not null)
        {
            props[byKey] = Property(value: "1");
        }
        return Thread(id: id, comments: [Comment(id: 1, author: by, content: "System message", at: at, type: "system")], published: at, status: "unknown", properties: props, identities: known);
    }

    public static JsonObject List(IEnumerable<JsonNode> items)
    {
        var array = new JsonArray(items: [.. items]);
        return new JsonObject { ["count"] = array.Count, ["value"] = array };
    }

    /// `json` read as `read` reads it, as Azure DevOps would send it.
    public static T? Read<T>(JsonNode json, Func<JsonElement, T?> read)
        where T : class
    {
        using var document = JsonDocument.Parse(json: json.ToJsonString());
        return read(arg: document.RootElement);
    }

    /// As Azure DevOps writes a time: `2026-10-18T10:00:00.000Z`.
    public static string Iso(DateTimeOffset date) => TestTimes.Iso(date: date);

    static JsonObject Property(string value) => new() { ["$type"] = "System.String", ["$value"] = value };

    /// A whole number as text, for properties such as `CodeReviewRefNewCommitsCount`.
    public static string Text(int number) => number.ToString(provider: CultureInfo.InvariantCulture);
}
