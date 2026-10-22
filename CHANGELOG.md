# Changelog

## 0.1.0 - Unreleased

The first version: Teams Pulse, ADO Pulse and Copilot Pulse in one menu-bar app.

- **Three sources, each off until you turn it on.** Microsoft Teams (unread chats), Azure DevOps (pull
  requests) and GitHub Copilot (app sessions) work as their Pulse apps did. Each first says what it
  reads, where it connects and what it needs. Turning one off deletes what it saved.
- **Azure DevOps as ADO Pulse has it now:** an **Answered** group for what you've taken care of in
  Azure DevOps, until you've seen it; **Pull Requests Sent in Chats**, off until you turn it on, which
  lists a pull request when someone sends you a link to it, from the notifications every app posts,
  keeping only the links, in memory, as it does which of those pull requests you've seen; and what
  you've seen of your own pull requests, kept for each Azure CLI account. `--render` and the demo
  never look for those links, and the log keeps how many it found private.
- **Your sprint and pipelines**, from ADO Pulse's window: your team's current sprint as a task board,
  with **Just Mine**, and the pipelines you pin, stage by stage. Each is a section of its own, a page
  in BriefBar's window to start with, and reads Azure DevOps only while something shows it, stopping a
  refresh under way once nothing does. They start over when you sign in to the Azure CLI as someone
  else. A retried run's stages are read again, runs in different organizations are kept apart, and a
  timeline that keeps failing doesn't hold up the rest.
- **Send Work to Copilot**, off by default: a ✈︎ button on the sprint's work items sends one to the
  Copilot CLI on your Mac, with your sign-in, tools, MCP servers and instructions. Check the prompt,
  which you can change, and choose the model, its reasoning effort and the repository, or right-click
  to send right away with your model (Claude Opus 5.5, Max by default) or the one for easy work
  (Claude Sonnet 5.5, Medium). Copilot works on its own in a new worktree at the latest base branch,
  then pushes a branch and opens a published pull request linked to the work item, which shows under
  Pull Requests. The task shows how it's going, a notification says how it went, and its menu opens the
  pull request, continues the session in Terminal, stops Copilot or removes the worktree. Azure
  DevOps' description says so, and its version goes up, so it pauses until you've looked.
- **Permissions once.** Full Disk Access and notifications are BriefBar's, granted once, and used only
  by the sources you turn on. An update never turns a source on, and one that starts reading more
  pauses until you've looked.
- **Menu bar, widgets and windows, arranged as you like.** Each section (Teams' Chats and Group
  Chats, pull requests, the sprint, pipelines, sessions) can share a menu-bar item, a desktop widget or a window with
  others, have one of its own, or be hidden from any of them. Settings › Menu Bar, Widgets and
  Windows also put everything in one, or give each its own.
- **One count by meaning.** A menu-bar item that shows several sections can add their counts up by
  what they mean, the same for every source: ✋ what needs you (unread chats, pull requests that need
  you, Copilot's questions, plans and permission prompts), ✕ what's wrong, ✓ what's done or ready, and
  ⚡ what's running if you turn it on. Choose it for each item under **Counts** in Settings › Menu Bar;
  until you do, an item shows its sections' counts side by side. `--json` prints each section's counts
  by state too.
- **Everything in one list, by state**, for such an item (**List** › **Everything by State**): what
  needs you, what's wrong, what's running and what's done or ready, from every section, the newest
  first, each with the actions its own list has.
- **A brief across sources** at the top of that list and of the window's Overview: up to five lines,
  from every source with something to say, each opening its thing. Apple Intelligence rewords the
  ones with something to condense, on your Mac, only while the list or the Overview is on screen;
  without it, they stay in BriefBar's own words. Teams' message text goes in only while **Show Message
  Previews** is on, and chats go to Apple Intelligence only while **Summarize with Apple Intelligence**
  is on too.
- **A window** that opens on an **Overview** of everything by state, with the brief, then has a page
  for each section, and a sidebar with their counts. BriefBar shows a Dock icon only while it's open.
- **Widgets for every source**, each with its own position and size, and an **Overview** widget: every
  source's counts, the brief's first line and what needs you. Teams' and the Overview start hidden.
- **Settings in a window of their own**, and in each list's gear menu.
- **Programs it starts can't use its permissions.** Every program BriefBar starts runs responsible for
  itself, such as its updater, the Azure CLI and the login shell that finds it, and the Copilot CLI
  and git for Send Work to Copilot. BriefBar tells by the executable macOS holds responsible for each,
  the one privacy permissions follow, and runs the updater and Copilot only once macOS confirms it.
- **Started by another program with its own permissions, BriefBar takes your keychain, home folder and
  temporary folder from macOS, not from that program.** Such a program chooses BriefBar's arguments
  and environment, and `HOME` chooses the keychain macOS uses: in a keychain that program made,
  BriefBar would seal the Teams chats it read with a new key there, where they're saved for any
  program to read. So BriefBar then runs none of the command-line modes that read your data, puts back
  `HOME` from the user database and `TMPDIR` as the temporary folder macOS gives you, and drops
  `CFFIXED_USER_HOME`, `DIRHELPER_USER_DIR_SUFFIX` and SQLite's variables, before anything reads them.
  However it's started, it finds your files (Notification Center's database, Teams' saved chats,
  `~/.copilot`, the Azure CLI) in the home folder the user database names, and the key to Teams' saved
  chats always goes in your login keychain, by its file, whatever the default keychain and the search
  list say. What SQLite sorts stays in memory, never in a temporary file that a program running as you
  could open.
- **Releases with in-app updates.** Each release is built from its tagged source by GitHub Actions,
  with an attestation, and signed with the project's own certificate, so updates keep Full Disk
  Access. BriefBar checks for updates only if you allow it, and installs only updates signed with the
  project's key.
- **Builds from source are signed ad hoc**, so no key on your Mac can sign as BriefBar. An optional
  certificate keeps their Full Disk Access across rebuilds: no app may use its key without asking, and
  it can't be exported.
- **The hardened runtime, with library validation on:** BriefBar loads only Apple's libraries.
  Sparkle, its updater, needs library validation off, so it runs in an app of its own inside BriefBar,
  `Contents/Helpers/BriefBar Updater.app`, with none of BriefBar's permissions: a copy of BriefBar
  with other code in place of Sparkle can't run that code with BriefBar's Full Disk Access.
  `BriefBar --check-updater` shows how macOS treats the updater. `make updater-check` checks it in a
  copy of a build that macOS opens, with other code in place of Sparkle, and `make update-rehearsal`
  installs an update through it, from a feed on the Mac.
