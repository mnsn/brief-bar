- **A task you send starts a session in the Copilot app.** With **Send Prompts to Copilot Sessions** on, a work item's
  new session now starts in the GitHub Copilot app, in a new worktree of the repository, where you can follow and
  steer it, rather than run on its own with the Copilot CLI. It works in autopilot, with the model and effort you
  chose, and BriefBar shows it in the app once it starts; **Send with …** starts it there too. The Send to Copilot
  window has **In the Copilot App** and **Run with the CLI**, and **New Sessions**, in Azure DevOps' settings, chooses
  which comes first. The app needs the repository among its own; when it can't start the session, the window says why,
  and runs it with the CLI. A pull request's new session still runs with the CLI.

## Descriptions

Azure DevOps: only with Send Work to Copilot and Send Prompts to Copilot Sessions, as a work item's new session starts
in the Copilot app: the app's projects, read-only from its database, with their IDs, names and folders and whether each
is a repository; which of its sessions are in that project and when each started; which ones the app has open; and what
BriefBar's extension, in another of the app's sessions, says of starting it, from files only you can read in BriefBar's
own folder, which the prompt goes through too.

After this update: with Send Prompts to Copilot Sessions on, Azure DevOps reads the Copilot app's projects to start a
work item's new session there.
