using System.Globalization;
using System.Text.Json;

namespace BriefBar.Core;

/// Reads what Azure DevOps and GitHub answer leniently, as the Mac's `ADOJSON` and its `lenient` decoding, and GitHub's
/// `Lossy` lists, do: a value that's missing, null or of an unexpected type reads as missing, and a list skips an element
/// it can't read. Dates are ISO 8601, with Azure DevOps' varying precision (`Timestamp`).
internal static class LenientJson
{
    /// The member `name` of `element`, an object, or null.
    public static JsonElement? Member(JsonElement? element, string name) =>
        element is { ValueKind: JsonValueKind.Object } value && value.TryGetProperty(propertyName: name, value: out var member)
            && member.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined)
            ? member
            : null;

    public static string? Text(JsonElement? element, string name) =>
        Member(element: element, name: name) is { ValueKind: JsonValueKind.String } text ? text.GetString() : null;

    public static int? WholeNumber(JsonElement? element, string name) =>
        Member(element: element, name: name) is { ValueKind: JsonValueKind.Number } number && number.TryGetInt32(value: out var value) ? value : null;

    public static bool? Flag(JsonElement? element, string name) =>
        Member(element: element, name: name) switch
        {
            { ValueKind: JsonValueKind.True } => true,
            { ValueKind: JsonValueKind.False } => false,
            _ => null,
        };

    public static DateTimeOffset? Date(JsonElement? element, string name) =>
        Text(element: element, name: name) is { } text ? Timestamp.Parse(text: text) : null;

    /// The member `name`, an object, or null.
    public static JsonElement? Node(JsonElement? element, string name) =>
        Member(element: element, name: name) is { ValueKind: JsonValueKind.Object } node ? node : null;

    /// The elements of the array `name`, each read by `read`, without those it can't read; null when there's no array.
    public static List<T>? Items<T>(JsonElement? element, string name, Func<JsonElement, T?> read)
        where T : class
    {
        if (Member(element: element, name: name) is not { ValueKind: JsonValueKind.Array } array)
        {
            return null;
        }
        var items = new List<T>();
        foreach (var item in array.EnumerateArray())
        {
            if (read(arg: item) is { } value)
            {
                items.Add(item: value);
            }
        }
        return items;
    }

    /// The members of the object `name`, each read by `read`, without those it can't read; null when there's no object.
    public static Dictionary<string, T>? Members<T>(JsonElement? element, string name, Func<JsonElement, T?> read)
        where T : class
    {
        if (Node(element: element, name: name) is not { } node)
        {
            return null;
        }
        var members = new Dictionary<string, T>(comparer: StringComparer.Ordinal);
        foreach (var member in node.EnumerateObject())
        {
            if (read(arg: member.Value) is { } value)
            {
                members[member.Name] = value;
            }
        }
        return members;
    }

    /// A value of any kind as text: a string as it is, a number or a true or false as JSON writes it.
    public static string? AnyText(JsonElement? element) => element switch
    {
        { ValueKind: JsonValueKind.String } text => text.GetString(),
        { ValueKind: JsonValueKind.Number } number when number.TryGetInt64(value: out var whole) => whole.ToString(provider: CultureInfo.InvariantCulture),
        { ValueKind: JsonValueKind.Number } number => number.GetDouble().ToString(provider: CultureInfo.InvariantCulture),
        { ValueKind: JsonValueKind.True } => "true",
        { ValueKind: JsonValueKind.False } => "false",
        _ => null,
    };
}
