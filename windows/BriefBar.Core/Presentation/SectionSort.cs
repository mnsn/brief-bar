namespace BriefBar.Core.Presentation;

/// How a section's list can be sorted, from a menu at the top of its panel, as the Mac's ↑↓ menu sorts pull requests: each
/// of `Choices` is a command its section performs, `Chosen` is the key of the one in use, `Name` is what Narrator calls
/// the menu, and `Help` says what the choices do, for its tooltip.
public sealed record SectionSort(ValueList<PanelCommand> Choices, string Chosen, string Name, string Help)
{
    /// The choice in use, if it's one of `Choices`.
    public PanelCommand? ChosenChoice => Choices.FirstOrDefault(predicate: choice => choice.Key == Chosen);
}
