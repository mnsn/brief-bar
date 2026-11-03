namespace BriefBar.ViewModels;

/// One of your organizations on Azure DevOps' page in Settings, and whether BriefBar watches it: switching it changes the
/// settings at once, to what the switch says, whatever else changed them since it last showed them.
public sealed class OrganizationViewModel : Observable
{
    readonly Action<string, bool> watch;
    bool isWatched;

    /// `watch` watches an organization, or stops watching it, by its name.
    public OrganizationViewModel(string name, bool isWatched, Action<string, bool> watch)
    {
        ArgumentNullException.ThrowIfNull(argument: watch);
        Name = name;
        this.isWatched = isWatched;
        this.watch = watch;
    }

    public string Name { get; }

    public bool IsWatched
    {
        get => isWatched;
        set
        {
            if (Set(storage: ref isWatched, value: value))
            {
                watch(arg1: Name, arg2: value);
            }
        }
    }

    /// Shows whether it's watched as the settings say now, without changing them.
    public void Show(bool watched) => Set(storage: ref isWatched, value: watched, propertyName: nameof(IsWatched));
}
