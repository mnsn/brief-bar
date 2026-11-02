using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace BriefBar.ViewModels;

/// A view model that tells its views when a property changes.
public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    /// Sets `storage` to `value`, and says so if it changed.
    protected bool Set<T>(ref T storage, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(x: storage, y: value))
        {
            return false;
        }
        storage = value;
        PropertyChanged?.Invoke(sender: this, e: new PropertyChangedEventArgs(propertyName: propertyName));
        return true;
    }

    /// Says `propertyName` changed, for a property whose value is kept elsewhere, such as in settings.
    protected void RaisePropertyChanged(string propertyName) =>
        PropertyChanged?.Invoke(sender: this, e: new PropertyChangedEventArgs(propertyName: propertyName));
}
