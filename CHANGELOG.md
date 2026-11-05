# Changelog

## Unreleased

- **Buttons and menus grow with Text Size in Windows.** At a bigger text size, in Settings › Appearance, the controls on
  windows' pages grow with their text: the pages' headers, such as By Status, List | Map and Open in Azure DevOps on the
  Pull Requests pages, rows' Actions, a pull request's Explain, Fix, Reply, Resolve, Fix Grammar and Push & Reply…, and
  the composers' buttons.
- **In a narrow window, a page's header shows its buttons as symbols alone**, each named in its tooltip and to
  VoiceOver, so what the page says it's about isn't cut short.
- **The fixes ready to push take two lines at most**, at the foot of a pull request's details: at a bigger text size,
  Push & Reply… goes under the sentence rather than beside it.
- **Adding a tag shows the field and its suggestions**, scrolling the details as they appear, rather than leaving them
  under the fixes ready to push.
- **A file's diff folds only runs of four or more unchanged lines**: fewer show, where a fold saved no room.
- **What's Left says a pull request set to complete automatically completes by itself**, as its heading does, rather
  than that you can complete it.
- **`--render` draws Settings with its chosen page highlighted in the sidebar**, where it drew a black capsule.

## 0.15.0 - 2026-11-04

- **Copilot sessions keep BriefBar up to date.** Turn on **Updates from Copilot Sessions** in Settings › Agents, and
  sessions tell BriefBar the work items and pull requests they're working on, the pull requests they opened, and what
  they just changed in Azure DevOps. With Show Links on, a session shows on what it's working on, in the Sprint, on your
  pull requests and in their details, where it can be the pull request's session, and a click opens it; with Pull
  Request Order on, a pull request it opened joins its lane in By Mission, whose Map says what it's working on now. What
  a session changed, BriefBar reads again right away instead of at its next refresh, never more than it reads anyway.
  Sessions change Azure DevOps with their own tools: BriefBar still gives them no way to. It's off by default, and agents
  pause until you've seen what they get now.
- **After this update, Azure DevOps, Copilot and agents ask you once to look at what they read and get, and wait until
  you have.** With Updates from Copilot Sessions on, Copilot reads what sessions tell BriefBar they're working on and
  the pull requests they opened, Azure DevOps reads again right away what a session says it changed there, and agents
  get the tools to tell BriefBar.

## 0.14.1 - 2026-11-04

- **What you write to Copilot in a pull request's details stays until you send it.** What you type in **Explain**,
  **Fix**, **Resolve** or **Fix All** is there again when you open it after a page opened over the details, such as its
  Copilot session's, after its file's page, where the same thread's composer has it too, and after you looked at another
  pull request: while BriefBar runs, in memory only, as your replies are. The same composer open in two windows shows what
  you write in either. A thread you just replied to or resolved stays where it was too, while the details show its pull
  request, pages over them included, rather than folding away with the resolved ones as you come back.
- **Back from a file's page, the details are where you left them.** A composer that was open closes as a file's page
  opens, keeping what you wrote, so **‹** goes back to the file's row, or to the comment it opened from, rather than
  opening the composer again and moving the keyboard's focus there.
- **A reply that lands once you've moved on leaves the keyboard where you are.** Reply takes the keyboard's focus back
  only when you were still in that reply as it went, and only on that thread, not as you type in another composer, such
  as Reply on another thread, Add Tag or Explain.
- **VoiceOver hears what became of Copilot's work once.** A pull request open in two windows, or a build that two
  policies run, says "answered" or "fixed" once, rather than once for each place that shows it.
- **A long answer shows its beginning, with Show More.** What a session answered with Explain shows its first dozen or
  so lines, fading out, and **Show More** shows the rest, as a row's summary does.
- **BriefBar no longer takes a little more memory each time a list updates with summaries on.** Each time a list or
  page that shows Apple Intelligence's summaries updated, such as Azure DevOps' Pull Requests page, BriefBar kept what
  checking that Apple Intelligence was available took, until it quit.
- **`--render` draws every picture.** With every source on, it stopped before the last ones, out of room for SwiftUI's
  views, as it kept each picture's window and views until it quit.

## 0.14.0 - 2026-11-04

- **See the order your pull requests merge in, By Mission.** Turn on **Pull Request Order** in Settings, and the
  window's Pull Requests pages, Azure DevOps' and GitHub's, can list them **By Mission**: the pull requests that go
  together, each mission a card with its pull requests in the order they merge, drawn as a graph beside them, a solid
  line for stacked and a dashed one for merge after, with a bar of how many merged, the Copilot sessions it goes with
  and a ★ to keep it on top. **Map** shows each mission in merge waves instead. Every row says where it stands, such as
  **Next to merge** or **After !4102**, By Status too, where that turns orange on one that's ready to complete before
  what it goes after, and clicking it shows its mission. The order comes from the stacks BriefBar sees, GitHub stacks
  and pull requests that target each other's branches, and from what Copilot sessions tell it: with agents on, sessions
  get tools to tell BriefBar an order, and Copilot a skill that says when to. It never changes a pull request's status,
  What's Left or the menu bar. It's off until you turn it on; then GitHub also reads each pull request's base branch
  and its place in a stack, and Copilot which pull request each session opened, as their descriptions say.
- **After this update, GitHub, Copilot and agents ask you once to look at what they read and get, and wait until you
  have.** With Pull Request Order on, GitHub also reads each pull request's base branch, whether it comes from a fork,
  its repository's default branch and its place in a stack, Copilot reads which pull request each session opened, and
  agents get the tools to tell BriefBar an order.

## 0.13.0 - 2026-11-04

- **Ask Copilot about a failed build, right where you read it.** With Send Work to Copilot on, a build that failed in a
  pull request's details has **✨ Explain the Failure** and **Fix** under where it failed, which open a small composer
  there, as a comment's do. **Explain the Failure** asks the Copilot session that worked on the build, or the pull
  request's own, what failed and why, and whether it's this change, a flaky test, the target branch or the build's
  infrastructure, from what BriefBar read of the run: its errors, the tests that failed with what each said, and the
  last lines of its log. Its answer shows under the run until the build runs again, and asking changes nothing. **Fix**
  has Copilot reproduce the failure and fix it, as you say, building on the answer if you like, in the pull request's
  session, a fork of it or a new one, without committing, pushing or touching pipelines. The build then says what
  Copilot does about it, above its buttons while it's open and under its name while it's closed, such as **Copilot is
  fixing this build in ‘Retry backoff’ · 2m** or **Fixed in ‘Retry backoff’, not pushed**, and the fix counts in the
  fixes ready to push at the foot of the details, until a rerun, or a push, that passes ends it, for good. **Fix the
  Build with Copilot…**, in a pull request's menu, quotes the same of a build you opened, and its builds say what
  Copilot does about them too. Azure DevOps' description says what's sent.
- **What Copilot said, under its line.** Once Copilot is done with a comment or a build, its line says what it said
  under it, such as why it couldn't fix it, rather than cutting it short, and BriefBar's own tasks read as tasks, as in
  **Fixed in the ‘Fix Comments’ task, not pushed**. What's Left says **Copilot's on it** for a prompt sent to one of the
  Copilot app's sessions too, not only for BriefBar's tasks, and **Copilot asks you** while that session waits for your
  answer; the fixes ready to push at the foot of the details say what they fixed, such as **1 fix and a build's fix
  ready in ‘Retry backoff’**.
- **Comments fixed with Copilot before this update no longer say so.** What tasks and prompts took on before isn't
  read any more, so those comments lose the line that said what Copilot did, and the bar of fixes ready to push
  forgets them. **Push & Reply with Copilot…**, in the pull request's menu, still pushes them from their session.
- **See which files conflict, and have Copilot resolve them.** When a pull request has merge conflicts, its
  details list the files that conflict with its target branch, right under What's Left, whose **Merge
  conflicts** now takes you there: each says what each branch did to it, such as **Changed on both branches**
  or **Changed on rename-order-status, deleted on main**, and opens what the pull request changed in it. With
  Send Work to Copilot on, **✨ Explain** asks the session that worked on the pull request why they conflict,
  and **Resolve** has Copilot merge the target branch in and resolve them, as you say, in a composer in place
  that says where it goes and what Copilot does: it may commit the merge, but doesn't push, which **Push &
  Reply** does once it's done. **Resolve Conflicts with Copilot…** lists the files too, once the details read
  them. BriefBar reads them with one request as the details show a pull request with conflicts, and keeps them
  in memory only.
- **BriefBar no longer quits as a minute passes while a summary shows.** With summaries on, a minute passing while a
  summary showed, under a row or on a page, could make BriefBar quit, as it checked again, everywhere at once, where
  what the summary sums up stands.
- **Reply to comments, and resolve them, without opening Azure DevOps.** Turn on **Make Changes in Azure DevOps** in
  Azure DevOps' settings, off by default, and each comment thread in a pull request's details has **Reply** and
  **Resolve**, beside ✨ Explain and Fix. **Reply** opens a field under the comment, in Markdown: **Reply**, or ⌘Return,
  sends it as you, and **Reply & Resolve** resolves the thread too. **Resolve**'s **▾** sets any status Azure DevOps
  offers, such as **Won't Fix** or **Closed**, and **Reactivate** brings a resolved thread back. The thread shows it at
  once, stays where it is, and stops waiting on you, and Needs You and what's left follow. What you write is kept until
  you send it, and a thread says in a sentence why something didn't go, such as no permission or being offline.
  **Fix Grammar** corrects a reply's spelling, grammar and punctuation, in its own language, keeping your words, code,
  links and mentions: with Apple Intelligence on your Mac, unless you choose a Copilot model in its **▾**, one premium
  request each, and it shows the correction for you to use, with Undo. With tags, below, these are the only changes
  BriefBar makes in Azure DevOps: only when you click them, and never from agents.
- **See a pull request's tags, and add or remove them.** A pull request's details show its tags under its heading.
  With **Make Changes in Azure DevOps** on, **✕** on a tag removes it, with **Undo**, and **Add Tag** opens a field
  that suggests tags as you type: those you added in that project, which BriefBar remembers, then those on the pull
  requests it read there. **Tab** completes the one you chose, **Return** adds it, or what you typed as a new tag,
  and **Esc** closes it. The tags show what Azure DevOps answered, and say in a sentence why a change didn't go,
  such as no permission or being offline. Azure DevOps' description says so: it reads tags with the lists it reads
  already, or with one request for a pull request sent to you or that you watch, and keeps the tags you add, up to
  20 for each project, until you turn the setting off.
- **After this update, Azure DevOps asks you once to look at what it reads and changes.** A pull request's details
  now read the files that conflict and, when your lists don't carry them, its tags. With Make Changes in Azure
  DevOps on, they send your replies, statuses and tags.

## 0.12.0 - 2026-11-03

- **BriefBar now needs macOS 26 or later.** On macOS 15, BriefBar keeps the version it has: its updater doesn't
  offer this release or any later one.
- **HTML in work items' Markdown shows as Azure DevOps shows it.** In a work item's details, HTML such as a
  line break (`<br>`), a table or `<details>` shows as it does in Azure DevOps, and an HTML comment shows
  nothing, rather than showing as they were written.
- **See each comment with its code, without opening Azure DevOps.** In a pull request's details, its
  comment threads now go by file, in the order its change lists them, with those on the pull request
  itself first. Each thread on code shows the lines it's on as its reviewer saw them, with their numbers,
  what was added and removed, and the lines it's about marked; long lines scroll sideways, and **⟷**
  makes the details wide enough for them. When the code changed after the comment, it says so, with
  **↗** to see what changed. Each comment shows in full, formatted as it was written, and a long thread
  shows its first and latest comments until you ask for the rest. Each thread also says how it stands
  and who it waits on: you, or someone else, such as **Waiting on Sam**. BriefBar reads a comment's code
  only as it comes on screen, and keeps it in memory only while those details show.
- **Find out why a build failed without leaving BriefBar.** In a pull request's details, click a build that
  failed, or **Build failed** in What's Left, and it opens in place: its stages, where it failed, from its stage
  to its task, whether it's the change's doing (it built an older commit, it passed on the same commit before
  and may be flaky, or the target branch fails too), its errors, the tests that failed with what each said and
  its stack trace, and the last lines of the failed step's log, selectable, with **Open Run**, **Open Log** and
  **Open Tests** for the rest, and **Fix the Build with Copilot…** while Send Work to Copilot is on. A build
  that's still going shows its stages as they are. BriefBar reads all this only as you open a build, with about
  ten requests, and keeps it in memory only.
- **Each pull request has one Copilot session, under its heading in its details.** With Send Work to
  Copilot on, a line names the session its work goes to, why it's its, such as **on its branch**, and how
  it stands, in its state's color: its last task's, the work item's task that opened it, or the Copilot
  app's session that goes with it. Click it to see the session's page; while it waits for your answer, it's
  orange, and a click opens it in the Copilot app, where you answer it. When two sessions go with it as well
  as each other, it asks which is its rather than guess. **⌄** opens the session in Copilot, or in Terminal
  for a task BriefBar runs, and **Use for This Pull Request** sends its work to another session, or to a
  new one, from then on. The Send to Copilot window and agents' `pull_request` go where the line says, so
  when the line asks, or its session is busy, the window starts a new session unless you choose one, rather
  than guess or go to another. BriefBar reads the Copilot app's sessions for it only while those details
  show on screen.
- **Show a task's or a link's pull request in BriefBar.** A Copilot task's menu has **Show Pull Request in
  BriefBar**, and one of your pull requests in a row's links **Show in BriefBar**, for its details on the
  window's Pull Requests page, beside opening it in Azure DevOps.
- **Review the whole change, file by file, without opening Azure DevOps.** Under its comments, a pull
  request's details list the files it changes, folder by folder, each with what happened to it, how many
  lines it adds and removes, and how many comments are on it. Click one to see its changes, with a few
  lines around each and the rest folded, to unfold as you need, and its comments at their lines. **‹** and
  **›**, or **⌥⌘↑** and **⌥⌘↓**, go from file to file, and **⌃⌘↑** and **⌃⌘↓** from comment to comment, on
  to the next file's. **⤢** lets a file's changes fill the page, for long lines. Once you've looked at a
  pull request before, its files can show only what changed since. BriefBar reads which files changed, and
  each file, only as they come on screen or you open one, one file at a time, and keeps them in memory
  only while those details show; Azure DevOps' description says so.
- **Ask Copilot about a comment, right where you read it.** With Send Work to Copilot on, each open comment
  thread in a pull request's details has **✨ Explain** and **Fix**, which open a small composer under the comment:
  say what you want, or just press Return. **Explain** asks the Copilot session that worked on it, or the pull
  request's own, why you got the comment, what the reviewer wants and how to address it, and shows the answer under
  the comment: it's asked aside, so it changes nothing, and the session's history stays as it was. **Ask More**
  follows up on its answer. **Fix** has Copilot address that comment alone, as you say, building on the answer if you
  like ("the second way"), or apply a reviewer's **Suggested change** as it's written, then build and test, without
  committing, pushing or replying. Choose where it goes in **▾**: the session, a fork of it, a new session, or
  another, each saying how it would go there; **Edit the Whole Prompt…** there opens the Send to Copilot window.
  Each thread then says what Copilot does about it, such as **Fixing this in a fork of ‘Retry backoff’ · 2m** or
  **Fixed in ‘Retry backoff’, not pushed**; **Fix All** sits at the top of the comments; and once fixes are done, a
  bar at the foot of the details takes you to them and offers **Push & Reply**. The Send to Copilot window can also
  fork BriefBar's own sessions, with **Fork with the CLI**. Explain sends the session's conversation, with the
  comment and its code, to GitHub Copilot.
- **After this update, Azure DevOps asks you once to look at what it reads.** A pull request's details
  now read the code its comments are on, its files, its builds and the Copilot app's sessions that go with it.

## 0.11.1 - 2026-11-03

- **Send a prompt straight to one of the Copilot app's sessions, or to a fork of it.** In the Send to Copilot
  window, for a session that's already there, **Send to Session** sends the prompt to the session in the Copilot
  app, as your own message, instead of copying it for you to paste. **Send to a Fork** forks the session, with
  its history and the changes it hasn't committed, into a worktree of its own, and sends the fork the prompt,
  while the session stays as it is. Both need **Send Prompts to Copilot Sessions**, which you turn on in
  Settings › Agents. Until then, and whenever BriefBar can't send it, it copies the prompt and opens the session
  for you to paste, as **Open in Copilot** did, or for a fork `/fork` and the prompt. The window says which
  before you send it.
- **Send Prompts to Copilot Sessions, in Settings › Agents.** Turn it on, and BriefBar installs a small
  extension in the GitHub Copilot app's sessions, so that Send to Copilot can send a prompt to a session
  itself, or fork the session and send the prompt to the fork, rather than copy it for you to paste. It's
  off until you turn it on, since each session the app has open runs it, at about 46 MB, and sessions
  that are already open get it once they start again. Turning it off, or turning agents off, removes it.
- **Build errors without stray color codes.** Where a pull request's or a pipeline's run failed, and in the
  prompt that asks Copilot to fix it, BriefBar leaves out the color codes some tools write into their
  errors, which showed as `[31m`.
- **A task that goes on with a Copilot session says it failed when Copilot stops before it starts.** When
  the Copilot CLI refused to start, such as **Push & Reply with Copilot…** after an earlier task, the task
  said it was done, as that earlier task had.
- **A pull request opens in its details from anywhere in BriefBar's window.** On the Overview, in its brief and on
  the Notifications page, clicking a pull request shows its details on the Pull Requests page, at the comment or
  the run it's about; on the Pipelines page, a pull request's card shows the run you click, or the first that
  failed. On the Sprint page, one of your pull requests linked to a work item shows the same details, with its
  comment threads, builds and checks, and reviewers, and the way there in their header, such as
  **Bug 5110 › !4091**. **Open Pull Requests in BriefBar**, off by default in Azure DevOps' settings, does the
  same for the menu bar's list, widgets and notifications, rather than opening Azure DevOps. Either way, a pull
  request's menu has both **Show in BriefBar** and **Open in Azure DevOps**.
- **Opening a pull request in Azure DevOps from the Pipelines page sees it**, as opening it anywhere else in
  BriefBar does, so what was new on it isn't anymore. It opens where its row does: at the comment that needs you,
  or the run after its merge.

## 0.11.0 - 2026-11-02

- **See a pull request's details without leaving BriefBar.** On the window's **Pull Requests** page,
  click a pull request to see it beside the list, or over it in a narrow window: where it stands,
  **What's Left** before you can complete it, each item saying when it's your turn and taking you to
  what it's about, its comment threads with the ones that wait on you first, its builds and checks with
  where one failed and its first error, who reviews it and how each voted, and the work items and
  Copilot sessions linked to it. **↗** opens it in Azure DevOps, at the comment that needs you, and **⋯**
  has the row's actions. Drag the details' edge to make them wider; **✕** or **Esc** closes them. The
  menu-bar list and widgets still open pull requests in Azure DevOps.
- **Copy the prompt from the Send to Copilot window.** **Copy**, above the prompt, puts it on the
  clipboard as it stands, with your changes, whatever you choose under **Where It Goes**, to paste where
  you like. It sends nothing, so the comments it quotes stay on **Needs You**.
- **With Nest Sessions Under Their Parents, a finished parent stays in Running or Needs You while its child sessions do.**
  Its row says it's waiting for child sessions and how many need you or are running.
- **GitHub's list says All quiet only once it has read all your pull requests.** It said so under a note
  that you were offline, that GitHub couldn't be reached or that some pull requests couldn't be read, and
  even before it had read any. Now it shows only the note.
- **A review by a deleted GitHub account counts.** On a pull request without a review decision, changes
  it requested put the pull request under Changes Requested, and its approval under Ready to Merge,
  rather than Waiting.
- **Azure DevOps and GitHub never follow a redirect**, so your sign-in's token goes only where it should. When
  one redirects BriefBar to another host, the list says so.
- **Turning GitHub off stops a run of the GitHub CLI that's under way**, so the token it would get goes
  nowhere.
- **When Azure DevOps or GitHub asks BriefBar to wait until a given time, it waits until then.** Either can
  give a date rather than a number of seconds, and BriefBar waited a minute instead.
- **The Copilot app's sessions are read all at once.** When the app saved a change as BriefBar read its
  database, a session's status and its latest activity could come from either side of it.
- **Agents can send a pull request's work to its own Copilot session.** With Send Work to Copilot on,
  BriefBar's `pull_request` tool names the session BriefBar sends a pull request's work to, such as the
  one on its branch or the one that opened it, and why. In the GitHub Copilot app, **/briefbar** then
  offers to send the work there, rather than always starting a new session, and asks which you want
  unless you've said; asked in that very session, it can also fork it, so the work goes another way while
  the session stays as it is. Since agents get more, they wait until you've seen what they get now.
- **Organizations in another directory.** When an Azure DevOps organization is in a directory (tenant)
  your Azure CLI isn't signed in to, BriefBar says so and names it, rather than asking you to sign in
  again, and its **Sign In…** signs in to that directory (`az login --tenant`). Your other
  organizations' pull requests stay listed meanwhile, and once you've signed in there, BriefBar reads
  both, still as you. **Add Organization…** now checks that your sign-in can read an organization as
  you add it, and says why when it can't, with where a project's organization is when you entered a
  project's name.
- **Teams' read markers come only from the files Teams still uses.** Teams can leave behind a file it no
  longer needs, which may hold a conversation it has since deleted. BriefBar read those files too, so a
  deleted conversation's old read marker could come back; it now reads only the files Teams' database
  lists, as Teams does. If that list is damaged, or names files that aren't there, the lists say some read
  markers couldn't be read.
- **A Teams account whose chats were never opened no longer says Teams' read markers have changed.** None
  of its chats had a read marker yet, which BriefBar took for a Teams update that changed them. It now goes
  by the field that holds one, which a chat never read has too.
- **A damaged record in Teams' data says some read markers couldn't be read.** A record whose checksum
  doesn't match may have held any chat's read marker, and the lists said nothing of it, so a chat you'd
  read in Teams could stay unread here without a word.

## 0.10.2 - 2026-11-01

- **A redesigned Send to Copilot window.** It looks like the rest of BriefBar now: translucent, with
  colored tiles and cards instead of a plain form. **Where It Goes** shows the session and the
  repository as rows you click to change; for a session that's already there, **Open in Copilot** and
  **Run with the CLI** sit side by side, each saying what it does and, when it can't be used, why. The
  model and how hard it thinks are under the prompt, which says where it came from, with **Reset** once
  you change it. It follows **Quieter Colors and Surfaces** in Settings › Appearance.
- **See what's left before you can complete each of your pull requests.** Under each of your open
  Azure DevOps pull requests, a line checks everything Azure DevOps requires: approvals, such as **1 of
  2 approvals**, the reviewers it requires, builds, status checks, comments to resolve, a linked work
  item, merge conflicts and drafts. What's left comes first, with what to do (**Resolve 2 comments**),
  what failed (**Build failed**) or who it waits on (**Waiting on Sam**), then what's done, with a ✓.
  Point at the row for who approved and where a build failed.
- **Sort your pull requests by date.** With ↑↓ at the top of the list, or the menu on the window's
  page, list them **Newest First** or **Oldest First**, by when each was created, in one list where each
  still says where it stands, with Idle's folded below it in the same order; or **By Status**, in their
  groups, as before. BriefBar keeps your choice.
- **A person marked as a required reviewer now holds a pull request out of Ready to Complete until they
  approve**, as Azure DevOps does, whether a policy or someone added them. A team still counts as its
  policy says.
- **A pull request Azure DevOps can't merge is under Failing.** When its merge fails for a reason other
  than conflicts, or a policy rejects it, it says **Merge failed** or **Merge rejected**, as conflicts
  do, rather than being ready to complete.

## 0.10.1 - 2026-11-01

- **A menu-bar item's list opens on the desktop you're on.** Clicking a BriefBar item after you'd
  switched desktops (Spaces) could open its list out of sight, on a desktop you'd left, and keep doing
  so until you opened it from the menu bar on another display. Now it opens where you click.
- **A pipeline canceled after you merge no longer reads as passed.** Once none of the pipelines that ran
  after your pull request merged failed, waits or still runs, but one was canceled, its row in Done says
  "its pipeline was canceled", or which one, such as "“shop-web CD” was canceled", and so do its
  notification, **Pipeline canceled**, its page and the Pipelines page, rather than that they passed.
- **A pull request you watch is listed once.** Watched by a link that spells its organization's name with
  other capital letters, such as `Contoso` for `contoso`, it was listed twice, and seeing one left the
  other new. Azure DevOps ignores the difference, and now so does BriefBar.
- **New comments come in while many builds run.** With eight or more pull requests whose builds were
  running, BriefBar kept reading only those, and new comments on your other pull requests waited until
  the builds finished. Each now takes its turn, the one that's waited longest first.
- **Pull requests you watch are read again soon after Azure DevOps asks BriefBar to slow down**, rather
  than an hour later.
- **Finding your organizations tries again when Azure DevOps asks BriefBar to slow down**, rather than
  keeping only those it had checked by then, for good.
- **The brief names who wants changes, or rejected your pull request**, rather than someone who commented
  after them.
- **The Copilot app's sessions are read again when the app changes them as BriefBar reads them.** While
  the app was closed, BriefBar could read its database just as the app opened or wrote it, and list what
  it read partway. It now notices and reads it again, and says so if the database keeps changing.

## 0.10.0 - 2026-11-01

- **Choose the model that writes summaries, from free on your Mac to the most capable.** In
  **Settings › General › Summaries**, choose Apple Intelligence, free on your Mac, or a model through
  Copilot, from Claude Haiku 5.5, the cheapest, to Claude Opus 5.5, the most capable, which costs the
  most: the picker says what each costs. Unless you chose a model, Claude Haiku 5.5 writes them when
  the Copilot CLI is installed, and Apple Intelligence when it isn't. Apple Intelligence needs no
  Copilot subscription and keeps the summary on your Mac, but it's a small model that often gets
  details wrong; Copilot's models are far more accurate. Summaries still start off. If Apple
  Intelligence isn't ready or can't summarize an item, BriefBar explains why and never switches to
  Copilot automatically.
- **Know where things stand in a few lines, as you open them.** With **Summaries** on, opening a work
  item's details, or a pull request's or a Copilot session's page, writes a summary at the top: a
  headline, the next step and whose it is, and a few points, a bullet each, on what reviewers asked and
  whether it's answered, what Copilot did and said is left, what's blocking, and where what was built
  differs from what the work item asks. It reads more than the rows show, so you don't have to open
  Azure DevOps or the session: the work item's description and comments, each Azure DevOps pull
  request's description and comment threads, and what you asked in each Copilot session and what
  Copilot answered. Its card says what it's about to do as it opens, with **Not Now**: Apple
  Intelligence writes it on your Mac, and a Copilot model uses one request on your Copilot plan. One
  that's still current shows again as it was; once something changes, **↻** writes a new one, as
  opening it does, saying so first, once that summary is ten minutes old. If you turned summaries on
  before, they're still written only when you click **✨**: choose **As you open one** in its setting's
  **Writes** to change that. While they're off, Where It Stands and pages offer them, with **Turn
  On…**. Azure DevOps and GitHub Copilot each say what they read for it, so they ask you to look again
  once.
- **Read more of a summary under a row:** its headline, the next step and the first three lines of its
  points, with **Show More** for all of them, and what changed once it's out of date; written again, the
  one before stays until the new one's ready.
- **BriefBar no longer lists the Copilot CLI's sessions that write summaries**, even when it reads
  sessions from their folders.
- **Make the text in BriefBar's windows bigger.** **Text Size in Windows**, in **Settings ›
  Appearance**, enlarges the text on the pages of BriefBar's windows, up to 150%, for reading long
  descriptions and comments. In a window, hold ⌘ and scroll up to make it bigger, or down to make it
  smaller. The menu bar's lists, the widgets and Settings keep their size.
- **Install it with Homebrew.** `brew install --cask mnsn/tap/briefbar` puts BriefBar in your
  Applications folder, and each release updates the cask. BriefBar still updates itself, and since it
  isn't notarized, macOS still asks you to allow it the first time you open it.
- **Make a work item's details wider.** On the Sprint page, drag the left edge of a work item's
  details to make them wider, to read a long description or summary, or narrower again. BriefBar
  keeps the width you choose, as far as the window has room for it beside the board; double-click
  the edge for the usual width.

## 0.9.0 - 2026-10-29

- **See where a work item stands, without leaving BriefBar.** With **Show Links** on, a work item's
  details on the Sprint page start with **Where It Stands**: the pull requests, their pipelines and the
  Copilot sessions that go with it, what needs you first, each saying where it stands in a sentence, and
  **Waiting on** says who it all waits on, you first; click its title to fold it to just that line.
  Click one to see what's known of it: a pull request's reviewers and votes, its open comments and the
  ones waiting on you, conflicts, and each build or check that ran on it, with where a failed one
  failed; a Copilot session's question or plan, and what Copilot recorded of its work as it went, its
  notes, what it did, what's next and what it said last. It's all from what BriefBar already reads,
  shown as it was written, with no more requests to Azure DevOps. The GitHub Copilot source asks you to
  look at what it reads again, since it now reads a linked session's checkpoints, in memory only.
- **Ask Copilot to sum it up.** Turn on **Summarize with Copilot** in **Settings › General**, and **✨
  Summarize** in Where It Stands asks the Copilot CLI for a short summary of the work item and everything
  linked to it: where it stands, what's next and who for, and what's been done. It runs only when you
  click it, with a small model unless you choose another, and without any tools, so Copilot can only
  write. What the details show goes to GitHub Copilot for it, never anything from Teams, and the summary
  stays in memory, saying when something changed since.
- **See where a pull request or a session stands, on demand.** With **Summarize with Copilot** on,
  point at a pull request or a Copilot session in a list, Azure DevOps', GitHub's or Copilot's, and
  click **✨** where its time was, or right-click it, for a two-line summary under its row: what its
  row doesn't say, and what's next and for whom, from what BriefBar knows of it and what's linked to
  it. **✕** hides it, and **Show Summary** brings it back without asking Copilot again.
- **Open a pull request or a session on a page of its own.** In Where It Stands, click a pull request
  or a Copilot session to see all that's known of it in the details, with what else is linked to it,
  such as a pull request's sessions. The header shows the way back, such as **Bug 5110 › !4091**, and
  **‹**, **⌘[** or **Esc** goes back.
- **Ask an agent how a work item is going.** BriefBar's agent tools have `work_item`: a work item by its
  number or link, with who it waits on, such as reviewers or you, its tasks, each pull request linked to
  it, your teammates' too, with its votes, comments and pipelines, the Copilot sessions on those pull
  requests with what Copilot recorded of their work, the work BriefBar sent to Copilot for it, and its
  description and latest comments. In the GitHub Copilot app, try **/briefbar 5101**: it answers in four
  short lines. Since agents get more, they wait until you've seen what they get now.
- **See which Copilot sessions another one started.** Turn on **Nest Sessions Under Their Parents** in
  Copilot's settings, and a session that another session started shows under it, indented, as in the
  Copilot app's sidebar, when both are in the same group, such as **Running**. One in another group
  stays where it was, with a **↳** tag that names the session that started it; click the tag to open
  that session. The counts stay the same.

## 0.8.6 - 2026-10-29

- **Copilot sessions work without the Copilot app.** On a Mac with only the Copilot CLI, the
  Sessions list said "Could not open Copilot database", and clicking a session failed, since nothing
  could open it. It now lists the CLI's recent sessions without that warning, and clicking one opens it
  in a terminal: one the CLI still has open brings up the app it runs in, such as Terminal, and any
  other opens in Terminal with `copilot --resume`, in the folder it worked in. With the Copilot app
  installed, nothing changes.

## 0.8.5 - 2026-10-29

- **Answer a Copilot question once, where it's passed on.** When a session that another session
  coordinates asks a question or has a plan for you, the coordinating session asks you too, and a plan
  you approved in the session itself made the coordinating session's approval fail. Turn on **Show
  Relayed Questions Once** in Copilot's settings, and once the coordinating session asks, **Needs You**
  lists it only there, and clicking it opens it, so you answer where it's passed on. The session it's
  for moves to **Running** as **Answer in “…”**, which opens the coordinating session too; right-click
  it to open the session itself. Until the coordinating session asks, the session needs you on its own.

## 0.8.4 - 2026-10-29

- **A work item's details show its text as written.** In fields written in Markdown, a numbered list
  with code, a quote, a heading or a table in an item started counting again after it, and nested
  lists lost their levels; they now go on, and end, as written. A backslash that ends a line, such
  as in `C:\`, no longer disappears, text in many layers of formatting no longer slows BriefBar
  down, and details that couldn't be read are read again when the work item changes while they show.

## 0.8.3 - 2026-10-28

- **Follow pipeline runs by pull request.** Below pinned pipelines, **Your Pull Requests** shows one
  expandable card for each active Azure DevOps pull request you authored, including drafts. See its
  pipeline status at a glance, or expand it for the latest runs, stages and failure details, without
  mixing up the same pipeline's runs on different pull requests. Results from older commits are
  marked **Outdated**, and results whose commit cannot be verified say so rather than counting as
  current passes. A card disappears when its pull request is merged or abandoned. Pinned pipelines,
  their counts and widgets stay unchanged.
- **Clicking a notification shows what it's about.** BriefBar opened the comment or the run in your
  browser, but macOS then brought BriefBar to the front, over it, as if you'd opened BriefBar again,
  so it looked as if nothing happened. It now opens it once BriefBar is in front, and doesn't open its
  own list for the click.
- **A Notifications page, so you can see what you missed.** Turn on **Notifications Page** in
  **Settings › General**, and BriefBar's window lists what BriefBar notified you of, the newest first,
  right after the Overview: banners that went away, notifications macOS didn't show, during a Focus
  or with notifications off for BriefBar, and every update of a refresh that had more than its
  notifications show. Click one to open what it's about. It keeps them for a day, or 4 hours or 3
  days, in memory only, and shows only while it lists something.
- **Send comments to the session that opened the pull request.** Fixing a pull request's comments, build
  or conflicts, reviewing it, or sending a sprint's work item to Copilot no longer always starts a new
  session. The window's new **Session** menu lists where the task can go instead: BriefBar's earlier tasks
  on it, the task of the work item that opened the pull request, and your Copilot app's sessions that go
  with it, such as the one on the pull request's branch, one you linked with Show Links, or one whose log
  links to it, with the rest under **Other Copilot Sessions**. Unless its last task's session is there, a
  pull request's task goes to the session that likely opened it. **Open in Copilot** copies the prompt
  and opens that session in the Copilot app, for you to paste and send; **Run with the CLI** goes on with
  it right away, on its own, while the app doesn't have it open. Azure DevOps asks you to look at what it
  reads once more: as the window opens, it now reads the Copilot app's sessions, read-only.

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

- **/briefbar in the GitHub Copilot app.** Once agents are on, **Settings › Agents** can install
  BriefBar's Copilot plugin, which the GitHub Copilot app and the Copilot CLI load. It's off until
  you click **Install**, and turning agents off removes it, or says what it couldn't remove, with
  **Try Again**. Type **/briefbar** in the app to see what needs you as an inbox you can search,
  sort and group, with links to each pull request, pipeline and Copilot session waiting for you. Ask
  it to fix a pull request's comments, build or conflicts, or to review one, and the work starts in
  a session of its own in the app, in a worktree of your clone, where you can follow and steer it;
  **Push & Reply** then goes to that same session. Sessions waiting for your answer are only opened
  for you, never answered. The plugin comes with BriefBar and updates with it, and gives agents
  nothing BriefBar didn't already.


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
