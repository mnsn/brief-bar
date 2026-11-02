namespace BriefBar.Core.AzureDevOps;

/// What the orders mean, and how they're said and saved.
public static class PROrders
{
    /// Every order, as the menu that sorts the list offers them.
    public static IReadOnlyList<PROrder> All { get; } = Enum.GetValues<PROrder>();

    /// Whether the list is by when they were created, rather than in their groups.
    public static bool IsByDate(this PROrder order) => order != PROrder.Status;

    /// Its name in the menu that sorts the list, in sentence case: "By status", "Newest first".
    public static string Title(this PROrder order) => order switch
    {
        PROrder.Status => "By status",
        PROrder.NewestFirst => "Newest first",
        PROrder.OldestFirst => "Oldest first",
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(order), actualValue: order, message: "Not an order."),
    };

    /// The Mac's name for it, as it's saved: `status`, `newestFirst`, `oldestFirst`.
    public static string RawValue(this PROrder order) => order switch
    {
        PROrder.Status => "status",
        PROrder.NewestFirst => "newestFirst",
        PROrder.OldestFirst => "oldestFirst",
        _ => throw new ArgumentOutOfRangeException(paramName: nameof(order), actualValue: order, message: "Not an order."),
    };

    /// The order `rawValue` names, as `RawValue` says it; null for anything else.
    public static PROrder? FromRawValue(string? rawValue) =>
        All.Cast<PROrder?>().FirstOrDefault(predicate: order => order!.Value.RawValue() == rawValue);
}
