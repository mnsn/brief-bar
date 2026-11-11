- **Approved, a stage of its own.** With **Pull Request Order** on, a pull request of yours whose required reviewers
  approved it, but that Azure DevOps can't complete yet, is **Approved**, between Teammate's review and Can merge,
  saying what it still waits for, such as **Build running**, or who approved it, rather than going back to In progress.
  The Board has an **Approved** column, its title marked with a seal, Up Next an **Approved next** slot, marked with it
  too, and its details' track an Approved step. Like Can merge, only Azure DevOps puts a pull request there: nobody can
  set it.
- **BriefBar never moves your pull requests back on its own.** A failed or expired build, conflicts, a merge Azure
  DevOps couldn't make, changes someone wants and a Copilot session that writes it or asks you something now mark it
  where it is, after its row's words, **Maria approved it · build failed**, and on its Board card, **✕ Build failed**,
  **✋ Sam wants changes**, rather than putting it in progress. It goes back only once it loses what its stage stands
  for: its approval, as when a push resets the votes, back to Teammate's review; Azure DevOps' readiness while it's
  still approved, from Can merge back to Approved. In progress is for drafts, and for one the session that opened it
  still writes. Your own moves, and the stages sessions set, still move it either way.
- **Fix next, from every column.** Up Next's **Fix next** has what needs you wherever it is, saying what and where,
  **Build failed · in Approved**, while one in Your review is still your next review too. Its card wears **Fix next**
  on the Board. Where Up Next's slots wrap, they spread evenly over their lines.

## Descriptions

Azure DevOps: with Pull Request Order on, how far each of your own pull requests got, Your review, Teammate's review,
Approved or Can merge, kept in BriefBar's preferences for each account you sign in with, by reference, until it merges
or closes, is a draft again, or no list has had it for 30 days.

After this update: with Pull Request Order on, Azure DevOps keeps how far each of your pull requests got, so that
BriefBar never moves one back on its own.
