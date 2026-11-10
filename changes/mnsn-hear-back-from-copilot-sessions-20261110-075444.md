- **Hear back from the Copilot sessions you send work to.** With **Send Prompts to Copilot Sessions** on, a prompt
  about a pull request's comments, builds or merge conflicts that you send with **Send to Session** or **Send to a
  Fork** is followed by BriefBar's extension in that session, which tells BriefBar how its turn goes: waiting behind
  another, what Copilot is doing, waiting for your answer or your plan's approval, and how it ended, with what Copilot
  said last. The pull request's line shows it, however long the turn takes, and no longer loses track when you send
  the session something else meanwhile. With Azure DevOps' **Notifications** on, one notification says when the session
  waits for your answer and, in its place, when it's done, failed, or stopped by something else than you, such as the
  session closing; none comes when you stop it. Clicking it opens the pull request at its comment, as a pull request's
  notification does. A session still running the extension from before this update goes on as before, from its log. The demo's Notifications page has a made-up one.

## Descriptions

Azure DevOps: with Send Prompts to Copilot Sessions, for a prompt BriefBar's extension sends for you, what the extension
says of that prompt's turn, rather than the session's log: whether it waits in the session's queue, what it's doing, what
it waits on you for, with Copilot's question or its plan's summary, and how it ended, with what Copilot said last or its
error, and the session's name, from a file only you can read in BriefBar's own folder, every few seconds until the turn
ends; what Copilot said kept in memory only, and its first line in the notifications BriefBar posts, with Notifications
on, when the session waits on you and when the turn ends.

After this update: with Send Prompts to Copilot Sessions on, Azure DevOps reads what BriefBar's extension says of the
turn of a prompt it sent to a Copilot session, and, with Notifications on, notifies you when the session waits on you
and when the turn ends.
