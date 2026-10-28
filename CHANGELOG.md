# Changelog

## Unreleased

- **See a work item's details without leaving BriefBar.** Click a story, bug or task on the Sprint
  page and its details open beside the board: its state, who has it and its reason, its description,
  acceptance criteria or repro steps, its fields, its tasks and related work items, its attachments
  and its discussion. Click its parent, a task or a related work item to go to it, and **‹** to come
  back. **Open in Azure DevOps** opens it there, to change it, as right-clicking it on the board still
  does. In a narrow window the details cover the board; **✕** or Esc closes them. Clicking one of your
  work items in the Sprint list or widget now opens its details in BriefBar's window too. BriefBar
  reads a work item's details only when you open them, and again when it changes while they show, and
  keeps them in memory only. It draws their text itself, so nothing they link to or embed, such as
  images, is loaded until you click it, in your browser. Since Azure DevOps now reads this, it asks you
  to look at what it reads once more after the update.

## 0.8.2 - 2026-10-28

- **Choose when Copilot completions move to Idle.** Finished and stopped sessions stay in their
  groups until you click **Clear** or **Keep Finished Sessions For** expires. Turn on **Move Viewed
  Sessions to Idle**, off by default, to hide them after opening or viewing them instead. Turning it
  off brings back recent viewed results, without undoing explicit clears. Running the same session
  again brings its next completion back.
- **See Copilot take a task as you send it.** Sending a pull request's comments, build, conflicts or
  review to Copilot, or a work item, no longer looks like nothing happened. Copilot works on its own, in
  the Copilot CLI rather than the Copilot app, so a notification now says it's on it, what it does and
  what it won't; clicking it shows the task. With GitHub Copilot on, every task you sent is also listed
  with your Copilot sessions, marked ✈︎: running while it works, with its current step, then finished or
  stopped, highlighted until **Clear** or the retention time expires, as a session is, with optional
  dismissal after viewing. Click one to open its pull request or work item, or right-click it for the
  task's own menu.

## 0.8.0 - 2026-10-26

- **Settings stays open while you arrange.** Clicking a BriefBar menu-bar item to see what you just
  arranged no longer hides Settings behind the app you were in before, or switches to that app's
  Space. While Settings is open, BriefBar shows a Dock icon and its own menus, as it does for its
  window, so you can also get back to Settings from the Dock or with ⌘-Tab.
- **Needs You keeps what still waits on you.** Opening a pull request from BriefBar, or **Mark as
  Seen**, no longer takes it off Needs You while a comment there waits on you: a reply to you, a
  mention, or a comment on your pull request. It stays, and counts in the menu bar, without the dot that
  now marks what's new, until you reply in its thread or the thread is resolved, you send the comments
  to Copilot with **Fix Comments** or **Push & Reply**, or you choose **Remove from Needs You** in its
  menu (right-click it, or **Actions** in the window). Anything after that needs you again, and a pull
  request without activity for two weeks goes to Idle, as before. After the update, a pull request you'd
  opened whose comments still wait on you is back in Needs You.
- **Apple silicon only.** BriefBar now requires an M1 or later Mac, still on macOS 15 or later.
  The app and its updater are built only for arm64, and pull requests no longer build or test for Intel.
  Existing Intel installs aren't offered incompatible updates.
- **Seven appearance improvements, each off until you choose it.** **Settings › Appearance** offers
  compact briefs, quieter colors and surfaces, aligned and easier-to-read rows, a compact menu bar,
  clearer states and counts, visible row and widget actions, and simple layout choices. Turn on any
  combination; leaving them off keeps the existing presentation. None turns on a source, changes its
  permissions or enables an agent.
- **A compact menu bar without losing your arrangement.** Its single icon counts items that need you
  or are failing, with a warning for failures or missing access. Its list can show all activity or a
  particular source. It combines only sections already visible, and turning it off restores your
  saved arrangement.
- **Clearer lists when you want them.** Ready-to-merge pull requests can be shown separately from
  finished sessions, important rows can use larger text and aligned titles, and the brief can move
  below the first group with two highlights and an option to expand it. Optional row menus and
  widget **View All** buttons make actions easier to find while keeping each source's existing
  open/read behavior.
- **Copilot tasks start again in repositories you trust.** With Copilot CLI 1.0.100 or later, a pull
  request or work item sent from a trusted repository failed at once: the CLI refuses the option
  BriefBar added to trust its worktree. BriefBar no longer adds it, and Copilot still trusts the
  worktree of a repository you trust. When Copilot can't start, the notification now gives the CLI's
  error rather than a hint to try `--help`.
- **See what goes together: Show Links.** Turn on **Show Links** in **Settings › General**, off by
  default, and rows show small capsules for what goes with them: a pull request's work items and the
  Copilot sessions working on it, a work item's pull requests (a teammate's too) and their sessions,
  and a session's pull request and work item. The sessions' capsule says how the one that needs you
  most stands, in its color. Links come from Azure DevOps, from the tasks you send to Copilot and what
  the Copilot app records, and from a session on a pull request's branch; right-click a row to link
  more, with suggestions, or to unlink. What you link or unlink stays in BriefBar: Azure DevOps, GitHub
  and Copilot never see it. Azure DevOps, Copilot and GitHub say what they read for it, so each asks
  you to look again before reading more.

## 0.4.0 - 2026-10-26

- **Copilot tasks on pull requests start again.** Sending a PR to Copilot, such as **Pre-review with
  Copilot**, no longer waits five minutes and then fails with "git failed" when your clone signs in
  to Azure DevOps with Git Credential Manager. Programs BriefBar starts now begin with no signals
  blocked, so the credential helper answers and the PR's branch is fetched right away.
- **Install BriefBar in another agent with a click.** In **Settings › Agents**, **Install** replaces
  copying a command: it adds BriefBar to Visual Studio Code or Cursor, whichever are on your Mac, with
  each app's own install link, so the app shows what it would add and asks you first, and keeps it in
  its own settings, which BriefBar never reads or writes. **GitHub Copilot**, in the same menu, adds
  BriefBar to the Copilot CLI, whose servers the GitHub Copilot app's sessions use, and is checked
  once it's there. **Copy Command** still copies the command, for any other agent.
- **Visible pull request actions.** Every Azure DevOps PR row in the main window has an **Actions**
  menu, including its Copilot actions, without needing a right-click. Menu-bar popovers and widgets
  keep their existing menus.
- **Choose a PR's local clone once.** The Copilot composer shows the PR's remote repository and
  remembers its verified local clone as soon as you choose it. Known clones are matched by their
  `origin`, not their folder names, and an unrelated repository is never selected as a fallback.
  BriefBar asks when it has no matching clone; it does not clone automatically.

## 0.3.0 - 2026-10-26

- **Arrange the menu bar, widgets and windows by dragging.** In Settings › Menu Bar, Widgets and
  Windows, each item is now a card with a chip for each section it shows, rather than a menu for every
  section that named its place by the others. Drag a chip onto another card to put them together, onto
  **New Item** to give it one of its own, or onto **Hidden**. Click **New Item** to choose a section
  instead, or right-click a chip for the same moves.
- **See your menu bar while you arrange it.** Settings › Menu Bar starts with BriefBar's items as they
  are in your menu bar now, left to right, with your counts, and each card shows its own item the same
  way, so you can see how much room they take.
- **Added Up, rather than By Meaning.** A menu-bar item that shows several sections shows their counts
  **Side by Side** or **Added Up** by state, and Settings now says what each one does. An item you set
  to By Meaning stays added up.

## 0.2.1 - 2026-10-25

- **Pages use the whole window.** In a wide window, such as full screen, a page no longer stays in a
  column in the middle with empty sides: its rows, the Overview's included, run the width of the window,
  and the Sprint puts its cards in as many columns as fit.

## 0.2.0 - 2026-10-25

A GitHub source for your pull requests on github.com, Copilot on your Azure DevOps pull requests, the
pipelines after your merges, Teams chats read where you read them, and, if you let them, agents that
can ask BriefBar what needs you. After the update, Teams and Azure DevOps wait until you've looked at
what they read now, in BriefBar's Settings.

- **GitHub, a new source, off until you turn it on.** It lists your pull requests on github.com: those
  that ask for your review by name, and your own that need changes, are failing (checks or merge
  conflicts), are approved, or are waiting. It signs in with the GitHub CLI (`gh auth login`), never a
  personal access token, keeps the token in memory only, and sends one read-only GraphQL query each
  refresh, every 2 minutes by default. It saves nothing but its settings, and like every source, does
  nothing at all until you turn it on. It has a menu-bar item, a widget and a page in the window, and
  counts by meaning with the others.
- **Copilot on your pull requests.** With **Send Work to Copilot** on, a pull request's menu sends it
  to the Copilot CLI too: **Fix Comments** (the threads that wait on you, word for word), **Fix the
  Build** (where it failed, and its errors), **Resolve Conflicts**, and, on one you review,
  **Pre-review**, which drafts your review and posts nothing. None of them pushes or replies; once one
  is done, **Push & Reply** goes on in the same session and worktree, commits, pushes the branch and
  answers the threads it addressed. The Copilot CLI refuses what each shouldn't do, whatever a comment
  asks: only Push & Reply may push, and a review can't change files or commit. Each works in a worktree
  at the pull request's latest commit, and its row shows how it's going.
- **Pipelines after your merges.** When a pull request of yours completes, BriefBar follows the
  pipelines that run on its merge commit, and the ones those start, such as a deployment, while Done
  keeps it. Its row says how they're going, moves to **Failing** if one fails, saying where, and
  shows **Waiting for approval** while a stage waits for one; a notification says so, and when they've
  all passed. The Pipelines page lists them under **After Your Merges**. They're read with your pull
  requests, with GETs, only while they run; **Follow Pipelines After You Merge** turns it off. Azure
  DevOps' description says so, and its version goes up, so it pauses until you've looked.
- **A failed build says where it failed.** A pull request of yours that's failing because of a build
  now says where, and the first error there, such as "shop-web CI · Run unit tests: 2 tests failed in
  DeliveryEstimateTests.", in its list, its notification and the brief. BriefBar reads the build's
  timeline once, with a GET, as it does for a pinned pipeline, and again only if the build is retried
  and fails again.
- **Chats you read in Teams are read in BriefBar too**, within a second or so, up to the newest message
  you saw there. Teams keeps how far you've read each chat in its own data on your Mac; BriefBar reads
  just that, read-only and in place, keeps it in memory only, and needs no sign-in or network for it,
  only the Full Disk Access it already has. **Mark Chats Read When You Read Them in Teams** turns it
  off. **Copy Diagnostics** and `--diagnose` say what BriefBar could read of it, by counts only; if a
  Teams update changes it, the lists say so, and the other rules still apply. Teams' description says
  so, and its version goes up, so it pauses until you've looked.
- **Agents can ask BriefBar, if you let them.** `BriefBar --mcp` is a Model Context Protocol server,
  off until you turn it on in **Settings › Agents**, which says what agents get first. Turning it on
  adds BriefBar to the Copilot CLI's MCP servers, which the GitHub Copilot app's sessions use too, and
  turning it off removes it. An agent can then ask what needs you; read your pull requests, one with
  its comment threads word for word, your pipelines, sprint, Copilot tasks and sessions; get the
  prompt that fixes a pull request's comments, build or conflicts, or reviews it, to follow where it
  works; and watch pull requests and pin pipelines. It serves the sources that are on, reads as the app
  does, changes nothing in Azure DevOps, and leaves Teams and GitHub out. What it answers goes to the
  agent's model.
- **Watch a pull request by its link.** **Watch a Pull Request…**, in Azure DevOps' settings, follows a
  pull request you're not on, such as one your team was asked to review: it's listed under **To
  Review**, as **Watching**, with what's new on it, until it closes or you stop watching it. Azure
  DevOps' description says it keeps the ones you watch.
- **Find a pipeline by its number.** **Add Pipeline**'s search finds pipelines by number as well as by
  name, in the same field: type `1234` or `#1234`, the number in the pipeline's address in Azure DevOps
  (`definitionId=1234`), and that pipeline comes first, then the ones named like it. Each result shows
  its number.
- **Pin a pipeline by its link.** **Add Pipeline** takes a link to a pipeline, or to one of its runs,
  as well as a name or number: a run's link pins its pipeline, showing that run's branch.
- **Open the window from every list.** **Overview** at the top opens the window's Overview, with how
  many things need you. The list's title, such as **Pull Requests ›**, opens its page.

## 0.1.0 - 2026-10-22

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
