- **A card a key moves on My Work's Board keeps the keyboard, however long Azure DevOps takes.** When Azure DevOps took
  more than ten seconds to answer, a work item's card that **⌘→** or **⌘←** moved lost the keyboard to the card after
  it, which the next key then moved. It now takes the keyboard back once its new state comes, whenever that is, unless
  you chose another card meanwhile.
- **A key shows a column you hid for the card it moves there.** With **Merged** or **Completed** hidden, **⌘→** into it
  set the work item's state but took its card, and the keyboard, out of sight. The column now shows for the moment, as
  it does for **Show Them**, with the card and the keyboard in it, so that **⌘←** moves it back. It stays hidden in your
  layout.
- **A finished mission's lane stays open for the work a key finishes.** A key that finishes the last of your work in a
  finished mission's lane, whose pull requests all merged, keeps that lane open, with the card and the keyboard on it,
  as it already did a story's lane, rather than fold it under the card, until you fold it yourself.
- **VoiceOver offers no state change that can't happen.** While a state change is on its way, VoiceOver's actions on a
  work item's card on My Work's Board leave out **Change State to …**, which did nothing then, as its **State** menu is
  dimmed.
