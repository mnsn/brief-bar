namespace BriefBar.ViewModels;

/// One of your organizations on Azure DevOps' page in Settings, and whether BriefBar watches it: switching it changes the
/// settings at once.
public sealed class OrganizationViewModel : Observable
{
    readonly Action<string> toggle;
    bool isWatched;

    public OrganizationViewModel(string name, bool isWatched, Action<string> toggle)
    {
        ArgumentNullException.ThrowIfNull(argument: toggle);
        Name = name;
        this.isWatched = isWatched;
        this.toggle = toggle;
    }

    public string Name { get; }

    public bool IsWatched
    {
        get => isWatched;
        set
        {
            if (Set(storage: ref isWatched, value: value))
            {
                toggle(obj: Name);
            }
        }
    }

    /// Shows whether it's watched as the settings say now, without changing them.
    public void Show(bool watched) => Set(storage: ref isWatched, value: watched, propertyName: nameof(IsWatched));
}
