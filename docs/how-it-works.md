# How BriefBar works

BriefBar is one app with four sources: Microsoft Teams, Azure DevOps, GitHub Copilot and GitHub. This
explains how it decides what a source may do, then how each source reads what it shows. The first
three come from Teams Pulse, ADO Pulse and Copilot Pulse, and work as those apps did.

## Sources, and turning them on

A source is off until you turn it on in Settings, on a page that says what it reads, where it connects
and what it needs (`SourceDescription`). Turning it on is your consent, which BriefBar records with
the version of that description (`SourceChoices` in `Sources/BriefBarCore`):

- A source is on only while the preferences hold your consent for it. When there's nothing saved, or
  it can't be read, nothing is on. A source that an update adds, or one this version doesn't know, is
  off: nothing but turning it on adds consent.
- When a source starts reading more, its description's version goes up. A source you turned on for an
  earlier version then pauses, until you've seen what it reads now and kept it on.
- While a source is off, BriefBar doesn't read its data or check its access: no Notification Center,
  Teams' own data, saved chats or keychain item for Teams, no `az` or Notification Center for Azure
  DevOps, no `~/.copilot` for Copilot, and no `gh` or GitHub for GitHub.
- Turning a source off stops it, takes its sections out of the menu bar, widgets and windows, removes
  its notifications, from Notification Center and the [Notifications page](#the-notifications-page),
  and deletes
  what it saved: Teams' encrypted unread chats, their key and its state; which Azure DevOps pull
  requests each account has seen or taken off Needs You; which Copilot sessions you've cleared. GitHub saves nothing but its
  settings. The links you added or hid to its things, with [Show Links](#links), go too. Its settings
  stay. The links
  to pull requests people sent you are kept in memory only, and forgotten with it.

## Permissions that macOS grants once

macOS gives some permissions to the whole app, and asks for them only once. That's why BriefBar's own
consent comes first.

- **Full Disk Access**, for reading Notification Center's database, and Teams' own data in its
  container. macOS has no prompt for it: a
  window (`FullDiskAccess` in `Sources/BriefBarUI`) walks you through System Settings. Teams
  registers when it starts and unregisters when it stops; Azure DevOps registers only while
  **Pull Requests Sent in Chats** is on. While none is registered, nothing checks the access or
  opens the window. When you turn off the last one, BriefBar offers to open the list, so you can
  remove it.
- **Notifications.** Azure DevOps asks when you turn it on. The one answer covers every source that
  posts notifications (`Notifier`), and a click goes to the source that posted it. macOS brings
  BriefBar to the front for a click, as when you open it again, usually just after the click itself
  arrives: opened at once, what the notification is about would open in your browser, say, and
  BriefBar would then come in front of it. So it opens once BriefBar is in front
  (`Notifier.handleReopen`, from `applicationShouldHandleReopen`), or half a second after the click at
  most, and BriefBar doesn't open its own list for that reopen.

### Programs BriefBar runs

macOS holds a process's "responsible process" accountable for what it does, and lets it use that
process's privacy permissions. A program that an app starts is attributed to the app. On this Mac,
Microsoft Teams' helper processes report Teams as theirs. So, once BriefBar has Full Disk Access, a
program it started would have it too. That includes:

- the Azure CLI, a Python program in a folder you can write to (`/opt/homebrew/bin`),
- the GitHub CLI, for its sign-in's token ([below](#github)),
- your login shell, which BriefBar asks where `az` and `gh` are, and which runs your shell's startup
  files,
- the Copilot CLI and git, when you send a work item to Copilot
  ([below](#send-work-to-copilot)): an agent that runs whatever commands it decides on,
- its updater, which loads Sparkle without library validation
  ([below](#the-hardened-runtime-and-library-validation)).

Every program BriefBar runs therefore goes through `ProcessRunner` (in `Sources/BriefBarCore`). It
starts the program with `posix_spawn` and its responsibility disclaimed
(`responsibility_spawnattrs_setdisclaim`, as Chromium does), so the program is responsible for itself
and gets only the permissions macOS gave it. That call is private to macOS, so it's looked up at run
time, and without it nothing starts. After starting a program, BriefBar asks macOS about it and logs a
fault if it has BriefBar's permissions after all. The updater, which runs alongside BriefBar
(`RunningProgram`), is checked before it runs: it starts suspended, and unless macOS holds it
responsible for itself, BriefBar ends it. So is the Copilot CLI (`DetachedProgram`), which runs in a
session of its own and goes on after BriefBar quits.

macOS checks privacy permissions against the executable it records as responsible when a program
starts: a disclaimed program's own (for a script, its interpreter), which it keeps when the program
goes on to run another, as a shell does; any other program gets its parent's. So BriefBar compares
that executable with its own (`Responsibility.isResponsibleForItself`), as it does to tell whose
permissions it has itself ([below](#programs-that-start-briefbar)): the process macOS names isn't
enough, as under the GitHub Copilot app's agents. With an older macOS that names no executable,
BriefBar compares process IDs. Tests (`startsProgramsResponsibleForThemselves`,
`startsAProgramResponsibleForItself`) check that programs BriefBar starts are responsible for
themselves, and a control (`aProgramStartedTheUsualWayIsntResponsibleForItself`) that the same
program started the usual way isn't, so they can fail wherever macOS names the executable: in
Terminal, on CI and under those agents alike. `scripts/test-updater-isolation.sh` also checks both
in an app that macOS opens, then BriefBar's updater the same way. The updater gets its input, its
output and `/dev/null`, and none of the descriptors BriefBar has open
(`passesTheProgramNoOtherDescriptor`).
`scripts/check-boundaries.sh` checks that no module but `BriefBarCore` uses `posix_spawn`, `Process`,
the C library's other ways to start programs, the script tasks (`NSUserUnixTask` and the others),
`NSAppleScript` or `OSAScript`.

Sparkle, in the updater, is a framework of its own, which that check doesn't read. It starts no program
either: its framework imports neither `posix_spawn` nor `NSTask`, and it submits its installer to
launchd (`SMJobSubmit`), which starts it. The installer replaces the app, the updater with it, and
opens it again.

### Programs that start BriefBar

It works the other way round too. A program that runs BriefBar's binary from a shell lends it its own
permissions: run in Terminal, it reads Notification Center with Terminal's Full Disk Access. But a
program that starts BriefBar through LaunchServices
(`open -n -g --stdout out.txt BriefBar.app --args --json`), or spawns it with its responsibility
disclaimed, makes it responsible for itself, and it then has its own Full Disk Access. That program
chose its arguments, its environment (`open --env`) and argument-domain preferences
(`--args -key value`), and can read its output. So, when BriefBar is attributed to itself
(`Attribution` in `Sources/BriefBarCore`):

- No command-line mode runs, and no `--render`, not even with `--demo`, whose data the environment
  names. `--help` still does, and so does `--check-updater`, which reads nothing of yours and takes
  no other option: it's meant to check the updater of a BriefBar started this way. The others say to
  run them from Terminal instead.
- It ignores the variables that point a source at other data (`BRIEFBAR_TEAMS_DB`,
  `BRIEFBAR_TEAMS_STATE_DIR`, `BRIEFBAR_TEAMS_CACHE`, `BRIEFBAR_CHAT_LINKS_DB`, `BRIEFBAR_COPILOT_DIR`):
  such a database could be a copy that only Full Disk Access reads, as a Time Machine backup's is.
  `BRIEFBAR_AZ` still applies: `az` runs with its own permissions.
- First thing, it puts back `HOME` from the user database and `TMPDIR` as macOS sets it, and drops
  `CFFIXED_USER_HOME`, `DIRHELPER_USER_DIR_SUFFIX` and SQLite's variables, such as `SQLITE_TMPDIR`
  (`LaunchEnvironment`). `HOME` chooses the keychain that macOS's Security framework uses, where the key
  to Teams' saved chats is: in a keychain that program made, BriefBar would make a new key, and seal
  with it the chats it read, which it saves where any program running as you can read them.
  `CFFIXED_USER_HOME` moves FileManager's home folder, `DIRHELPER_USER_DIR_SUFFIX` the temporary and
  cache folders macOS gives you (except, today, for an app with the hardened runtime, as BriefBar is),
  and `SQLITE_TMPDIR` is where SQLite would write what a query sorts, which BriefBar keeps in memory
  instead (`PRAGMA temp_store = MEMORY` on every connection, in `SQLiteConnection`), so that no
  temporary file holds it for such a program to open before SQLite deletes it. Foundation and SQLite use
  the temporary folder macOS gives you (`confstr`), and SQLite falls back to `TMPDIR` if it can't write
  there. macOS only stops that folder being deleted or renamed: you own it, so a program running as you
  could make it unwritable, and with `TMPDIR` choose where SQLite's files go. So `TMPDIR` is that
  folder, or, if macOS doesn't name one, it goes. However it's started, BriefBar finds your files
  (Notification Center's database, Teams' saved chats, `~/.copilot`) in the home folder the user
  database names (`UserHome`), not FileManager's.
- Its preferences come only from its own domain: `-key value` arguments would otherwise turn on a
  source, or **Pull Requests Sent in Chats**, without you. Any program running as you can still
  change the preferences themselves, though, with `defaults write`, including which sources are on,
  and whether BriefBar looks for pull requests sent in chats. That isn't prevented, but BriefBar
  keeps nothing it reads in Notification Center where such a program could read it (see
  [Pull requests sent in chats](#pull-requests-sent-in-chats)), so turning that on only makes
  BriefBar show those pull requests in its own lists.
- The app's standard output and error go to `/dev/null`, where frameworks could otherwise write, for
  instance with `OS_ACTIVITY_DT_MODE` set.

That's how the app always runs once installed, from Finder, a login item or an update, so it changes
nothing for it. Run from a shell, nothing changes either.

To tell, BriefBar asks macOS who's responsible for it (`responsibility_get_responsible_for_pid`), and
compares the executable it names with its own: privacy permissions are checked against that
executable. The process macOS names isn't enough. On macOS 27, a command that the GitHub Copilot app's
agents run is its own responsible process, yet attributed to the Copilot app, whose permissions it
gets. Whether macOS names BriefBar, or can't say, it counts as BriefBar's own permissions.

However it's started, BriefBar keeps the key to Teams' saved chats in your login keychain, which it
names by its file in the home folder the user database names. The default keychain and the search
list don't move it: `HOME` chooses them, and any program running as you can also change them with
`security`, without starting BriefBar at all (see [What's saved](#whats-saved)).

## Menu bar, widgets and windows

Each source has one or more sections: Teams' **Chats** and **Group Chats**, Azure DevOps' **Pull
Requests**, Copilot's **Sessions** and GitHub's **Pull Requests**. Each says where it can show
(`SectionInfo`): every section in the menu bar and in windows, and these five in widgets too. BriefBar
shows them on three surfaces,
each with a layout of its own (`SectionLayout` in `Sources/BriefBarCore`, saved as `menuBarLayout`,
`widgetLayout` and `windowLayout`): its items, in order (menu-bar items, widgets or windows), the
sections each one shows, and the sections you've hidden from it.

- Each section starts in a menu-bar item and a widget of its own, and every section starts in one
  window. Teams' widgets start hidden, so an update doesn't put your chats on the desktop.
- In **Settings › Menu Bar**, **Widgets** and **Windows** (`LayoutPage`), each item is a card with a
  chip for each section it shows. You drag a chip onto another card, onto **New Item** or onto
  **Hidden**, or pick the same move from its right-click menu, or a section from New Item's
  (`SectionLayout.move`): dropped in the item it's already in, a section stays in its place. New Item
  stands in for any item you could add, so the page never shows empty ones. Settings › Menu Bar
  starts with the menu bar's line: the items that show, in the order they're in the menu bar
  (`menuBarItemsInOrder`), each drawn as `MenuBarDrawing` draws it, with the counts as they are, and
  each card shows its own item the same way; they draw again whenever a source's counts change. **Put
  All in One** puts every section in one item: those that show, in order, then those of the sources
  that are off, so a source you turn on later joins it. **Give Each Its Own** undoes it.
- A hidden section keeps its place, for when you show it again, and its source keeps running: it
  still shows on the other surfaces, and Azure DevOps still notifies you. A notification that would
  open the hidden pull requests opens them in Azure DevOps instead. Turning on a source whose
  sections were all hidden from the menu bar when you turned it off shows them there again.
- Where a section goes is remembered while its source is off, so it comes back to the same item.
  Sections a later version adds get items of their own, or join the first window.
- Each item has a stable ID: macOS keeps a menu-bar item where you ⌘-dragged it, and BriefBar keeps a
  widget or a window where you left it (`BriefBar.widget.<ID>`, `BriefBar.window.<ID>`). The demo
  keeps neither, so it never moves yours.

**Menu-bar items** show their sections' counts side by side, each drawn the way its source draws it,
or added up by state ([below](#everything-by-state)), and their popover has a tab for each, or
one list by state. It opens at the tab it showed last, whether it opened there or you switched to it,
which each item keeps by its ID (`MenuBarTabs`, saved as `menuBarTabs`), so it outlasts a restart.
When something opens it at a section, such as a notification about several pull requests, it shows
that one, and opens there next time too. The first time, or once that tab is in another item, it opens
at the first that needs you, or the first. A list by state has no tabs: it shows every section's
things, and leaves the tab the item opens at as it was. Every tab is as wide as the
widest of the item's lists, and as tabs stop fitting, they get smaller, then become symbols with counts,
then a menu. A popover opens from an invisible window over the item (`PopoverAnchor`), so it stays on
the display you clicked: macOS moves an item's own window to whichever menu bar is active, and a click
on an item can make another display's menu bar active, as the
[FAQ in the user guide](user-guide.md#why-did-clicking-briefbar-switch-my-other-displays-space) explains.
It's a new window each time: macOS can stop keeping a window on every Space, as when the displays wake
from sleep, and a popover shown from it would open on a Space you've left. With nothing on, or every
section hidden, BriefBar shows its own icon, whose menu opens Settings.

Every popover starts with **Overview**, which opens the window at its Overview
([below](#the-overview)), and each list's title, such as **Pull Requests ›**, opens the window at that
list's page (`PageLink`). A title is a button only in a menu-bar item's list (`titleOpensPage`), not
on the page itself or in a widget, and only while a window has that page (`AppServices.hasPage`). The
tabs only switch lists, so a click meant for a tab never opens a window.

**Widgets** (`WidgetHost`) show their sections one above the other: each source draws its section's
header and rows, and the widget is as wide as its widest section needs. A widget's size gives each
section 2, 4 or 8 rows, or 2, 3 or 5 when it shares the widget. Each widget keeps its own position and
size (`widgetOptions`). Widgets were once each source's own: the first time, BriefBar brings over
their settings and positions (`WidgetMigration`).

**Windows** (`WindowHost`) have a page for each of their sections, with a sidebar of them by source,
each with its count, and ⌘1 to ⌘9. A window with several pages starts with an Overview
([below](#the-overview)), and the first of them has the [Notifications page](#the-notifications-page)
after it, while that's on and lists something. A section's page is its list, filling the window (`PanelStyle.page`), the
whole width included: a wide window, such as full screen, gets longer lines, not empty sides, and the
Sprint more columns of cards. A source can draw a page of its own instead. A window opens at the page
of the list or widget you opened it from, or at its Overview when no page is asked for, and remembers
the page you left it at. BriefBar is a menu-bar app (`LSUIElement`): while a window or Settings is open,
it shows a Dock icon and the usual menus, and it goes back once they're all closed. It needs the menu bar
then: a click on a menu-bar item first makes the app the menu bar belongs to active again
([FAQ](user-guide.md#why-did-clicking-briefbar-switch-my-other-displays-space)), whose windows would cover
Settings, or whose Space macOS would switch to, each time you clicked an item to see what you arranged. An
app only takes the menu bar as it becomes active, so when BriefBar already is, as when you open Settings
from a list, it hands over to the Dock, which has no windows to bring forward, and comes straight back
(`AppModel.showInDock`).

### Optional presentation

**Settings › Appearance** exposes seven independent `InterfaceOption`s. `InterfaceOptions` loads
each boolean from `interface.<option>` and defaults every missing value to false. `AppServices`
publishes changes to the shared SwiftUI environment, so existing windows, lists and widgets update
without changing a source's consent or its settings. The app also refreshes menu-bar items and widget
sizes; rendering never starts these live surfaces.

Compact Menu Bar derives one temporary item from the sections already visible in the saved layout.
It never saves that item into `SectionLayout`, changes hidden sections, or removes the original items'
options. Its count is Needs You plus failures, not running or finished work. Its source picker keeps
sections such as Sprint reachable even though they do not contribute to a list by state.

Clearer States separates ready pull requests from finished sessions using `StateRow.isReady`, without
changing `ItemState`, source classification, notifications or agent responses. Readable Rows uses the
same row-height calculation in widget content and window sizing. Simple Layout Choices only exposes
preset controls: choosing a preset is an explicit layout edit; enabling the appearance option is not.

**Text Size in Windows** is a `TextSize` from 100% to 150%, saved as `interface.textSize`, which
`AppServices` publishes apart from the options. Only a window's page sets the `textScale` environment
value from it (`WindowView`), and views take their fonts from `.font(size:)` and `.font(style:)`, which
multiply by it, so the same rows stay at their designed sizes in the menu bar's lists and the widgets.
What holds that text, such as avatars, badges and rows' icon columns, grows by it too, and a layout
that runs out of room moves a row's details under its headline rather than squeezing it. macOS has no
Dynamic Type, so a text style scales from its fixed size there. ⌘-scrolling changes it through a local
event monitor, only over a BriefBar window or a sheet over one (`WindowHost.owns`): `TextSizeScrolling`
turns each notch of a wheel, or each 40 points of a swipe, into a step, ignores momentum, and takes up
as bigger, as toward the top of a page, whichever way your scrolling goes.

## Everything by state

### Counts by state

Every section counts its things in four states that mean the same for every source (`ItemState` and
`StateCounts` in `Sources/BriefBarCore`), mapped next to each source's own groups:

| State | Teams (`UnreadState.states`) | Azure DevOps (`PRGroup.state`, `PipelineStatus.state`) | Copilot (`DisplayPhase.state`) | GitHub (`GitHubPRGroup.state`) |
|---|---|---|---|---|
| ✋ Needs you | Unread chats, 1:1 and group | Needs You; To Review only while **Show To Review in the Menu Bar** is on | Questions, plans and permission prompts | To Review, Changes Requested |
| ✕ Something's wrong | | Failing; failed pipelines | Stopped: interrupted, failed or not responding | Failing |
| ⚡ Running | | Pipelines running or queued | Running | |
| ✓ Done or ready | | Ready to Complete | Done | Ready to Merge |

What the menu bar doesn't count, such as an answered, waiting or idle pull request, an idle session or
the sprint's work, is in no state. Each section reports its counts in `MenuBarSegment.states`, as it
draws them: Azure DevOps and GitHub report none while they need a sign-in. `--json` prints them by
section, and `make demo-check` checks them, each section's and their sum.

### An item that adds its counts up

A menu-bar item that shows several sections has options of its own (`MenuBarItemOptions`, saved as
`menuBarItemOptions` by the item's ID, like a widget's): **Counts** side by side or added up, with
the states it shows, and its **List**. They start as items always were, side by side with a tab per
section, with ✋, ✕ and ✓ but not ⚡, and an item that goes away takes its options with it, so one
that later gets its ID starts over. Added up, the item draws one symbol and count per state, in
Azure DevOps' and Copilot's colors (`MenuBarItemContent`), then a small ⚠ if a section can't show what
it should (`MenuBarSegment.problem`, such as Teams without Full Disk Access). Its tooltip and VoiceOver
say what's in each count: "Needs you: 2 chats, 2 group chats, 4 pull requests, 3 Copilot sessions"
(`SectionInfo.counted`). With nothing to count, it shows BriefBar's own symbol.

### Lists by state

An item's list, the window's Overview and the Overview widget can show several sections' things
together by state (`StateListModel`): Needs You, Something's Wrong, Running, then Done or Ready, each
the newest first. Each source hands over the rows its own list draws (`stateRows`), with their actions
and menus, and says when they change (`stateRowsChanged`), not only when their counts do. Only
sections whose things can be in a state are in it (`SectionInfo.states`), so not the sprint, and the
list reads them only while it's on screen. For the sources it's a viewer of its own
(`SectionViewer.Kind.stateList`): Azure DevOps reads pipelines while it shows them, but doesn't count
pull requests as seen there, since Answered isn't in it.

### The brief

The list by state and the Overview start with a brief (`Briefing.pick`): up to five lines, each
source's most pressing first, so that it covers every source with something to say, then the newest
of what's wrong and of what's done or ready if those aren't in it yet, then the most pressing of the
rest. Most pressing is what needs you, then what's wrong, then what's done or ready, the newest first;
what's running isn't in it. Each source says its lines in BriefBar's own words (`briefLines`), and
says which, if any, Apple Intelligence may reword, by its own settings:

- Teams says who wrote and how many messages (`SummaryPrompt.briefSentence`). What the newest says
  goes in only while **Show Message Previews** is on, and the chat goes to the model, with the
  instructions Teams' summaries use, only while **Summarize with Apple Intelligence** is on too. Once a
  chat has its ✨ summary, the brief uses it.
- Azure DevOps says each pull request as its own brief does (`Brief.item`), and a comment goes to the
  model only while **Summaries** is on. A failed pipeline gets a sentence of its own.
- Copilot says what a session waits for or how it ended (`SessionSnapshot.briefSentence`), without
  the model.
- GitHub says who asked for a review, who asked for changes, or what failed or was approved
  (`GitHubPRSnapshot.briefSentence`), without the model.

`BriefWriter` asks Apple Intelligence's on-device model (`SystemLanguageModel.default`, never Private
Cloud Compute) for one line at a time, only for lines a list or the window shows, never in the
background: once a list hides, or a refresh takes a line away, what's still waiting isn't asked for.
It keeps what it writes in memory for ten minutes after the line was last on screen, never on disk or
in the log. Without the model, or when it fails, a line keeps BriefBar's words, and
the brief shows no ✨. `--render` keeps BriefBar's words, unless `BRIEFBAR_RENDER_SUMMARIES=1` makes it
wait for the model.

### The Overview

A window with several pages starts with an Overview (`WindowPages`): the brief, then its pages'
sections by state, in cards like the other pages'. It's ⌘1, with a count of what needs you in the
sidebar, and the window opens on it when no page is asked for: from **Overview** at the top of every
menu-bar list, from `--window`, or from Settings › Windows.

**Overview** at the top of a list (`OverviewLink`) opens the first window with several pages
(`WindowPages.overviewWindow`) at its Overview, and counts what needs you on that window's pages as its
sidebar does. Lists leave it out while no window has an Overview, as when each window shows one
section.

The Overview widget (`OverviewWidgetHost`) sums up every section of the sources that are on: how many
things are in each state, the brief's first line, then the newest of what needs you, each opening its
thing. It isn't one of the layout's widgets, which show sections: it has options of its own
(`OverviewWidgetOptions`, saved as `overviewWidget`), and starts hidden, like Teams' widgets, since it
can show your chats. Being always on screen, it never asks the model for words: it shows the brief as
a list or the window last had it worded.

### The Notifications page

**Notifications Page**, in Settings › General (`RecentNotifications` in `Sources/BriefBarUI`, saved as
`notifications.page`), is off until you turn it on. It lists what the sources posted
(`NotificationHistory` in `Sources/BriefBarCore`), the newest first, by day, in the window that has the
Overview, right after it (`WindowPages.notifications`), without a ⌘ number, so the sections' numbers stay
put as it comes and goes. `Notifier` lists each notification it posts, even one macOS doesn't show,
during a Focus or with notifications off for BriefBar. One posted again under the same ID takes its
entry's place, as a Copilot task's does, from saying it started to saying how it ended, and one that
BriefBar takes back because it no longer says what's going on (`Notifier.remove`), such as a task you
stopped, leaves the page too. Azure DevOps
posts at most four for a refresh, the last saying how many more updates there are
(`NotificationPlanner.collapse`), and lists every update: clicking that last one opens the page. An
entry keeps what its notification would open, and opens it the same way, which also takes the
notification out of Notification Center. A dot marks what you haven't seen: what the page showed is
seen once nothing shows it anymore, and clicking a notification, there or in Notification Center, sees
it too.

The entries stay in memory only, never in the preferences or on disk, for **Keep Notifications For**:
4 hours, a day or 3 days (`notifications.keepHours`), at most 200 of them, and go with their source
when you turn it off. The page lists what was posted while it was off too, but shows only while it's
on and lists something: once the last entry expires, or you clear them, it goes, and the window goes
back to its Overview. The demo lists what its made-up pull requests would have notified you of
(`DemoData.notifications`), and `--render` draws the page from them.

## Links

**Show Links** (`Links` in `Sources/BriefBarUI`, with `LinkGraph` and the rest in `Sources/BriefBarCore`) shows which
work items, pull requests and Copilot sessions go together, on their own rows. It's off until you turn it on in
Settings › General, and while it's off it shows nothing, and no source reads anything more for it.

**What a link joins.** Each thing has a reference (`ItemRef`) that says which one and nothing else: an Azure DevOps work
item or pull request, by its organization and number; a GitHub pull request, by its repository and number; or a Copilot
session, by its ID, the app's or one BriefBar started. Two things link when they're of different kinds, and not two pull
requests.

**Where links come from.** Each source that's on tells `Links` the links it knows (`ItemLink`, with where it comes from,
`LinkOrigin`) and what its things are, for other rows to show (`LinkedItem`):

- Azure DevOps (`WorkLinksStore`): the work items linked to each of your pull requests, the pull requests linked to the
  sprint's work items, and the tasks you sent to Copilot: each one's session, with the work item or pull request it was
  sent from, and with the pull request it opened, which goes with the work item too. One of your pull requests, which
  the list has, also shows in BriefBar's window (`LinkedItem.show`): in a row's links, it has **Show in BriefBar**, for
  its details on the Pull Requests page, beside **Open in Azure DevOps**, which a task's menu has too, as **Show Pull
  Request in BriefBar**, for the pull request it works on or opened (`CopilotTaskEntry.pullRequestKey`). Where no window
  has that page, it opens in Azure DevOps.
- Copilot: the pull request each app session started from or opened, as the app records it in its database
  (`workspaces`' `source_pr_*` and `created_pr_*` columns, and `workspace_pull_request_links`): GitHub's, and any
  other service's whose link it records.
- Branches (`BranchLinks`): a session on a pull request's source branch, as the Copilot app names its workspace's
  branch, in the same repository: the session's project, its folder or its GitHub repository is named like the pull
  request's repository. Not a branch everybody works on (`main`, `master`, `develop` and the like), nor the one it
  merges into.
- You (`LinkEdits`): the links you add, and the ones you hide.

**What a thing shows.** What it's linked to directly; and, between a work item and a session, what's linked through a
pull request linked to both, since a work item's pull requests and their sessions are all its work. A pull request
doesn't reach its work items' other sessions: they may be on other pull requests. A row shows a capsule for each kind:
the work item's or pull request's number, or how many; and how the session that needs you most stands, in a word and in
its color. The task Copilot is doing on a pull request, or the latest sent from a work item, isn't in them: its own
capsule shows it. Widgets' rows show none.

### Where it stands

A work item's details start with **Where It Stands** (`WhereItStandsSection` in `Sources/BriefBarUI`): what Show Links
links to it, in a card, the one that needs you most first (needs you, then what's wrong, what's at work, what's done or
ready, then the rest, the newest first in each), a session linked through a pull request under that pull request, and a
task you sent to Copilot under the work item it was sent from, where that's listed; four at first, then **Show More**,
with a tally of their states once there are five or more. A task with nothing linked shows none of it. Under its title,
as its subtitle, **Waiting on:** says who the work item and what's linked to it wait on, and for what
(`ItemStory.waits`): you first, in bold rather than a color, which could clash with the state of what it's about, such
as a ready pull request's green, saying what to do, such as "you, to complete !4091"; then other people, such as
"reviewers of Sam Rivera's !4120"; then Copilot, such as "Copilot, on task 5103", or, on that task itself, "Copilot,
working on it" (`ItemStory.Wait.said(_:on:)`); VoiceOver hears them apart, by semicolons. An Azure DevOps pull request's
come from `PullRequestWait` (in `Sources/AzureDevOpsCore`), as `work_item`'s do, and a GitHub one's from why it's in its
list (`GitHubPRSnapshot.wait`), such as "you, to merge #12"; a session waits on you while it asks, or, for a question it
relays, in the session that asks it for it, said once with that session's own question; and on Copilot while it's at
work; the work sent to Copilot, on Copilot while it goes, and on you once the one sent last for a work item or a pull
request failed, among all that was sent, such as on a pull request a task's work went on to, unless that's done or
closed since (`CopilotTaskEntry.waits(of:among:isDone:type:)`, which `work_item` uses too). Each is said once, and a
session once, whether the work sent to Copilot in it or the session itself tells of it (`ItemStory.Wait.about`); two
pull requests in the same words, numbered alike in two organizations or repositories, are each said with its place, such
as "(fabrikam)"; and other things in the same words, such as two sessions of the same name, are said once with how many,
"(2 sessions)". While a summary shows under it, its next step shows too, always, since it says what to do, which the
line doesn't. A short one doesn't break: the line breaks after a "·". Its title, chevron and count fold
Where It Stands to that line; to VoiceOver, the chevron is the disclosure button, "Where It Stands, expanded", and the
title stays a heading, and BriefBar remembers it (`links.whereItStandsFolded`); folded, with nothing waiting, it says
"Waiting on: no one", but only once the work item and all that's linked to it have said where they stand, and never
while one can't. Pages don't show it. Each row shows its state as the lists by state draw it, what it is, where it
stands in a sentence, its opening words in its state's color, and since when; one that needs you or went wrong opens in
a click. Clicking a row opens its page over the work item's details (`ItemPageView`, the `pages` of
`WorkItemDetailsStore`): what it is, where it stands and since when, and its actions, with **✨ Summarize**
and its summary under them, written as the page opens, as a work item's details do, unless one that's current is there;
then what Copilot said after its last checkpoint, while it's at work or waits for you, or
how it ended once it stopped; then all its source knows of it (`ItemStory` in `Sources/BriefBarCore`), how it's linked
to what you opened it from first, in a card as the work item's fields are, and the pipelines that ran on it; then **Also
Linked**, what else is linked to it, without the work item and the pages you came through (the `trail` of
`itemNavigation`), so it never leads back; and last what Copilot wrote of a session's work, its overview and what's
next, the rest behind **Show All Notes**, set apart by a thin rule, since those are Copilot's words, not BriefBar's.
Once it stopped, its last checkpoint's next steps are what it planned then, behind Show All Notes too. A task's report,
what Copilot printed when it ended, is what it said last when it came after its checkpoints
(`ItemStory.Account.ending(with:)`). The header says where you are, `‹ 🐞 Bug 5110 › !4091`, each crumb going back to it,
and its **⋯** acts on the page. **‹**, **⌘[**, and **Esc** on a page go back through the pages, then to the work items
you came from, each with the pages that showed over it, and scroll back to the row you opened; opening a page that shows
already goes back to it. A work item on a page is followed, as a link in the details is, read from Azure DevOps when the
sprint doesn't have it. Turning Show Links off takes the pages away. A view with nowhere to open pages (no
`itemNavigation`) shows a short preview under the row instead, with **Show All** for the rest. While Show Links is off
it reads nothing and shows one line, with **Turn On…**, which shows Show Links' setting, until you dismiss it.

Each source tells about its own things (`ItemStories`, the sources' tellers), only when a view asks and only while Show
Links is on, from what it already read, and BriefBar keeps what they tell in memory only: a story is told again when its
row changes, a minute later, or once more of it is read, such as a work item's details as they show
(`ItemStories.invalidate`), and forgotten a quarter of an hour after it was told, when its source stops or someone else
signs in to its CLI, the Azure CLI or GitHub's, or no one does, with the summaries made of them, or when Show Links goes
off. Views ask as they update, as they show and each minute, in the middle of AppKit's layout, where each change to what
they show marks their window for another pass, and AppKit throws past as many passes as the window has views: so what
they ask is taken up on the main actor's next turn, once for each thing however often it's asked
(`ItemStories.request`), and a summary looks again at what it sums up, as stories are told, once on that turn, however
many were (`StorySummaries.lookAgain`). When two sources know the same thing, what they tell is put together in the
sources' order: a task Azure DevOps sent to Copilot says how it went, and Copilot what it recorded.

- **Azure DevOps** (`PullRequestStory`): one of your pull requests, from all that's read of it: who reviews it and how
  each voted (people only: groups aren't reviewers), how many threads are open and how many comments wait on you,
  conflicts, a draft, auto-complete and its branches, and each build or status check that ran on it, with where a
  failed build failed and its first error, and the pipelines after its merge. One that's only linked, such as a
  teammate's, from the pull request itself: its author, its reviewers' votes, conflicts and branches. A task sent to
  Copilot: how it went, what for and when, the pull request it opened, and the summary it ended with. No more requests:
  it's what the lists, Show Links and Send Work to Copilot already read.
- **Copilot** (`SessionStory`, `SessionAccount`): a session's question, plan, permission prompt or error, with its
  project, branch, mode and how full its context is; and what Copilot recorded of its work, the app's sessions' and a
  task's: the titles of its [checkpoints](#where-the-data-comes-from-2), the latest one's overview, what's done and
  what's next, and the last thing it said when that came after; or, for a session without checkpoints, the summary it
  ended with or its last message. Markdown becomes plain text, cut to a few hundred characters.
- **GitHub**: one of its pull requests' latest reviews, conflicts, draft and branch, and its checks, from the one query
  it reads them with.

### Summaries

**Summaries**, in Settings › General, under Show Links, is off until you turn it on, and works only while Show Links is
on (`StorySummaries` in `Sources/BriefBarUI`). Its setting says what it does, and, right under that, **Writes**: **As
you open one**, or **Only when you ask** (`StorySummaries.writesWhenOpened`, `summaries.copilot.whenOpened`); then, a
line each, what it uses or sends, where, what it costs, which for a Copilot model follows that choice, and what the
model can do, with the model, under what it costs (`StorySummariesSetting.onDeviceSection`, `copilotSection` and
`choiceTitle`): "On this Mac: free, less accurate", Apple Intelligence, "(not on this Mac)" where this Mac can't run
it; then "Through Copilot: a request each, at the model's rate", from the cheapest to the most capable, Claude Haiku 5.5
(cheapest), Claude Sonnet 5.5, GPT-6.1 Sol, Gemini 4 Argon and Claude Opus 5.5 (most capable, costs most)
(`CopilotModel.forSummaries`), so you choose what a summary is worth; never Auto, which may choose any. The picker is as
wide as the model chosen needs, up to 320 points, so it fits in a 480-point popover. While Apple Intelligence is
chosen, a line under it says it's a small model that often gets details wrong, even in short histories, and that
Copilot's models are far more accurate: on realistic made-up items, it got every one of them wrong where Claude Haiku
5.5 got them right. So unless you chose a model, it's Claude Haiku 5.5 through Copilot where the Copilot CLI is, and
Apple Intelligence where it isn't (`StorySummaries.copilotDefaultModel`, `lookForCLI`, `hasChosenModel`): the CLI is
looked for, as your login shell finds it, once summaries are on, as BriefBar starts, as they're turned on and as their
setting shows, one look for all who ask meanwhile, which stops as they go off; never while they're off. Until the model's
known (`knowsModel`), nothing's written as something opens, nor said to be about to be, so a card never says "on this
Mac" for one that goes to Copilot; ✨ writes with the model it names. Choosing a model in the
picker, even the one that was the default, saves it, and it stays whatever's found. Existing model choices and the
on/off setting stay as they were, under the same `summaries.copilot.*` preferences; whoever had summaries on in 0.9.0
with Claude Haiku 5.5, its default then, keeps it while the CLI is there. Apple Intelligence runs through
`OnDeviceModel` and `SystemLanguageModel.default`, never Private Cloud Compute, with no tools, Copilot requests,
sign-in or subscription; it needs a supported Mac and Apple Intelligence enabled and ready, and the
setting explains when it isn't available. Opening something writes nothing with a model that can't write it there,
Apple Intelligence where this Mac can't run it, or one through Copilot where the CLI wasn't found
(`StorySummaries.canRunModel`), so each thing opened doesn't say so; ✨ still asks, and says why. Local failures never
fall back to Copilot. While Show Links is off, it's dimmed and can't be changed.
**Writes** starts as **As you open one**, except for whoever had summaries on before it came, when they were written
only when you asked: they keep **Only when you ask** until they choose otherwise, saved once, the
first time this version starts, so an update never starts spending for them.

Once something's linked to the work item (`StorySummaries.hasSomethingToSum`), and no summary shows or is about to,
Where It Stands' header has **✨ Summarize with Apple Intelligence** or **✨ Summarize with Copilot**, or just
**Summarize** where that doesn't fit; its tooltip says whether it stays on this Mac or uses your Copilot plan. With **As
you open one**, as the details open it, and while it isn't folded, the card shows at once, about as tall as it will be,
with gray lines where the summary will go and "Summarizing in a moment · on this Mac", or "· 1 request" for a Copilot
model, and **Not Now** (`StorySummaries.expect`, `isPending`); two seconds later (`openedFor`), the
details ask for it (`StorySummaries.opened`), and it's written, the caption naming the model and **Stop** in Not Now's
place, unless one is being written, you closed it, the last couldn't be written less than ten minutes ago
(`retryAfter`), even if you closed what said so, or you wrote, stopped, closed or showed one for it since it opened
(`timesActed(on:)`, which the details remember as it opens, so what they do by themselves never undoes what you did).
One that's there already shows again, as it was, while it's current, once what it summed up is told as it is now; out
of date, it's written again as it opens only once it's ten minutes old (`rewriteAfter`), since a session at work changes
what it says every few minutes, and ↻ writes it sooner. Then, and for one that couldn't be written ten minutes ago or
more, its card says so as it opens, as for a new one (`StorySummaries.isDue`): "Since then: !4120 changed. Updating in a
moment · 1 request", or "Trying again in a moment", with **Not Now** in place of ↻ and ✕, or of **Try Again**; and one
found out of date only once what it summed up is read again, as it opens, says so then, for as long
(`StorySummaries.noticeFor`). **Not
Now** keeps it from being written as it opened, this time, and ✨, or ↻, shows. While its setting shows from **Turn
On…**, nothing's written as it opens (`StorySummaries.isChoosing`, which each Turn On… claims for itself, so another
going away doesn't end it): turning summaries on there writes one once you're done choosing how. Passing through a work item on your way to another costs nothing; turning summaries on, unfolding Where It
Stands, or its getting something linked while it shows, such as links read after it opened, asks again. With **Only when
you ask**, it's written when you click ✨. The card's coming, filling and going moves what's under it smoothly.

Before it asks, the sources tell what they know of each, as for the details, the work item's description and latest
comments too, and each of its tasks, with how the work sent to Copilot for it stands; then each source reads more of
each thing for the summary, only now (`ItemStories.context(for:)`, from what each registers with `registerContext`), as
[below](#what-a-summary-reads) says; and `StorySummaryPrompt` (in `Sources/BriefBarCore`) puts them in a prompt:
instructions, then the data between `<data>` and `</data>`, which the model is told is only data, never instructions,
with any `<data>` or `</data>` in it taken out, the most pressing first, and at most 36,000 characters for Copilot or
6,000 for Apple Intelligence, even when the subject alone is long. What a source read for the summary follows each
thing's story, a labelled part each, in place of a note of its story's by the same label, such as a description cut
shorter: an even share each of 10,000 characters for the thing summed up and of 5,000 for each one linked to it, 4,000
at most, what a short part doesn't use going to the others, so a long description doesn't crowd out the comments after
it (`StorySummaryPrompt.room`); a part that would be cut to less than 200 is left out, a short one never is. For Apple
Intelligence, each thing gets 1,800 characters in all, so long discussions leave room for what's linked, and what was
read for it shares what its story leaves of them, the same way. The on-device session receives the instructions
separately, reserves up to 500 tokens for the answer and has a 45-second timeout. Character limits aren't token
guarantees: if the model's context window is exceeded, the summary says so and offers a model change, never a cloud
retry. Data cut short says details were left out, and only then are the summaries told to say they may be incomplete;
missing data never means there are no blockers, votes or work left. A note that it may be incomplete is taken out of a
summary only when nothing in its data was cut short ("…"), left out, or said to have more ("(2 more)")
(`StorySummaries.isWhole`, `StorySummary.withoutIncompleteNotes`), as a small model adds one anyway; never one that
says work is incomplete. Pipeline runs that passed are left out of the data,
so the model can't say a build passed; failed, running and waiting ones stay, a failed one with its first error. The
data starts with your name, as your pull requests have it in Azure DevOps, when that's known, and the model is told
that's who reads it, to call you "you"; then, for a work item, after `SHOWN`, who it all waits on, as Where It Stands
says it above the summary, which pages and rows don't say. The model is told that you see each item's title and status
line and what's after `SHOWN`, so it never repeats them, nor lists tasks' states or hours, but says what you'd otherwise
open Azure DevOps or a session to learn: what reviewers asked and whether that's answered, what Copilot changed and what
it said is left or risky, why a build failed, what blocks the work and on whom; and to check what was built, from pull
requests' descriptions and Copilot's answers, against the work item's description and acceptance criteria, where a pull
request that does only part of the work, the rest being other tasks' or not done yet, is work left, not a difference. It
answers in a form `StorySummary` reads, whatever Markdown is around its labels: first `CHECK:`, each way what was built
differs from what the work item asks, or None, which is never shown, and which keeps even the model on this Mac to the
form; a headline of at most 14 words, the one thing to know, the first difference found when there's one; whom the step
that unblocks the most is for, you, a person or Copilot, and what it is; and `SUMMARY:`, 2 to 5 short points, the most
important first, at most 160 words in all, each on a line of its own after "- ", with a bold lead of a word or two, such
as **Differs:**, **Review:** or **Left:**, and `code` for commit IDs, paths and endpoints. `StorySummary.parse` keeps the
points as Markdown of those few kinds, each point after "- ", however the model marked it, its bold and code closed even
where it's cut short, a link as its text, without headings, quotes, rules or code blocks; a point is never read as a
label, as "- **Next:** …" might be; an answer run into one line is read apart at its labels; your name for whom the next
step is reads as "you"; and "PR !4120" reads "!4120", "the PR" "the pull request" and "PRs" "pull requests", leaving
names such as "PR-Validation" as they are. A next step may name whom it's for first, as in "Sam Rivera: get !4120 reviewed". A
teammate's pull request says who wrote it as
one of its facts. Nothing from Teams goes in it, nor anything from the notifications that sent you a pull request: when
a pull request's row says who sent it to you in a chat, or that you answered them, the prompt says where it stands by
its votes instead (`ItemStory.sharedSentence`), and its status as active or a draft (`LinkedItem.sharedStatus`); who it
waits on says only "you, to look at !4113". The details still show who sent it.

The card (`SummaryCard`), at the top of Where It Stands, under Waiting On, shows all of it, a size bigger than the
details' text: the headline, the next step, "Next for you: Cap the backoff, then reply to Sam.", and its points, never
behind **Show More**, since that's what explains where things stand: a bullet each, with its bold and `code` as the model
wrote them, and a link only as its words, since what a model writes may come from anyone's comment (`SummaryMarkdown`,
`SummaryPoints`); an answer without points shows as the text it is. A next step that only says again what Waiting On
says above it, for whom that line says it waits on, naming what it names and nothing else, every word of it being the
line's, as "Complete !4091." under "you, to complete !4091", doesn't show (`SummaryCard.repeats`); one that says more,
as "Complete !4091 after fixing authentication.", does. Its caption says "Summary by Apple Intelligence · 2m ago", or "Summary by
Copilot", the time each minute and never cut short, and its tooltip, which model wrote it, when, from what, "from 5101,
!4120 and 1 Copilot session", and, for a Copilot model, that it was 1 request. Each action has one control: **Not Now** before it's written, **Stop** while it is; then **↻**,
which writes it again, and **✕**, each in a 22-point target, which hides it (`StorySummaries.hide`): it's kept, as long
as summaries are, and **Show Summary** shows it again without writing another; **Summarize Again**, **Copy Summary** and
**Hide Summary** in its right-click menu. Written again, by ↻, by opening it, or by **Summarize Again**, the one before
shows, gray, under "Updating · on this Mac", or "· 1 request", with **Stop**, which brings it back as it was
(`StorySummaries.previous(for:)`). Out of date, its caption says so in bold, its text turns a little lighter, and its
foot says what changed, "Since then: !4120 changed.", with **Summarize Again**, in the tint, as a link. One that
couldn't be written again stays as it was, lighter only if it's out of date too, with why at its foot, "Couldn't update:
Apple Intelligence is busy or took too long.", and under that, **Choose Model…** for a model that isn't on
your plan, and **Try Again**; ✕ then hides it as it was. One that couldn't be written at all says "Couldn't summarize:
…", with the same, and its ✕ closes it, since nothing's kept. VoiceOver says "Summary ready" and what it's of, once,
however many places show it. Your name comes from Azure DevOps, or else from your GitHub login.

While Summaries is off and Show Links is on, a line where its card would be, in Where It Stands once something's linked
and under a page's heading, offers it (`SummaryOffer`): "AI can tell you where this stands, in a few lines.", whichever
model would write them, which isn't known until they're on, with **Turn On…**, in the tint, after it while it fits, or else on a line of
its own, which shows its setting in a popover, what it uses or sends, where and what it costs, to turn it on there, the
line staying while it shows; and **✕**, which hides the line for good (`summaries.copilot.offerHidden`). It's above where
the card will be, so turning summaries on there doesn't move it.

The lists offer it too, for a pull request, Azure DevOps' or GitHub's, and a Copilot session, whatever's linked to it
(`StorySummaries.canSummarize`, while a source describes it), only when you ask, never as they show: pointing at its row
puts **✨** in its time's place (`RowTime`, which keeps the spot, and `rowSummarizeButton`), unless the row shows its
actions, and while it's written a spinner takes that place, so a second click there doesn't open the row. Its
right-click and Actions menus have, in a group of its own right after opening it, **Summarize with Apple
Intelligence** or **Summarize with Copilot**, then
**Stop Summarizing**, **Hide Summary** or **Show Summary**, and **Summarize Again** (`SummarizeMenuItems`), and so do
its accessibility actions. Its summary shows under its row (`RowSummary`) in the row's own sizes, as a chat's does: ✨
and the headline, then the next step and for whom, in full, then, quieter, the first three lines of its points, after
"•", with their bold and code (`RowSummaryContent.paragraphLines`, `SummaryMarkdown.joined`), with **Show More** at
their end, in the tint, as a link, while there's more, and, out of date, what changed, "Out of date: !4102 changed",
with **Summarize Again**; ✕ shows on the right while you point at it, over its first line, and the
time it was written is in its tooltip, so that it isn't read as the row's; it ends where the row's time does, left of
its actions. Written again, the one before stays, gray, with a spinner and **Stop** over the end of its first line; one
that couldn't be written again stays, with "Couldn't update: …" and **Try Again** at its foot. It's the same summary as
its page's; while it shows, what it summed up is read again each minute, as for Where It Stands, so it says when it's
out of date. With nothing linked to it, it sums up what its source knows of it alone; a thing no source describes, or
that nothing's known of, isn't sent. Desktop widgets show none (`offersSummaries`).

#### What a summary reads

As a summary is written, and, for one ten minutes old or more, again as its details or page open, to tell whether it's
still current, and only then, each source reads more of each thing it sums up, beyond its story
(`ItemStories.registerContext`), whichever model writes it. Nothing of it is kept but a fingerprint of each part, in
memory (`StorySummaries.lastRead`, a hash of each part's text by its label), until summaries or Show Links go off, a
source stops, or BriefBar quits; and nothing is read while Show Links is off or once the summary is taken back. A part
the prompt has no room for says it's left out, "(Comment threads left out for length.)", and so do the older comments
of a work item that don't fit or weren't read, by its comment count, "(2 earlier comments left out)":

- Azure DevOps (`WorkLinksStore.context`; every request a GET): a pull request's description, in plain text, without
  what its template asks its author in HTML comments, from a GET of it; and its comment threads, your pull requests'
  as already read and others' read where the pull request says it is (`PullRequestContext`): the unresolved ones a line
  each, the open ones first, the newest first, with who started it and where, what they said and the latest reply,
  and whether anyone else replied, "(replied, not resolved)" or "(no reply yet)", then how many are resolved, with the
  latest two in brief; each part at most 3,000 characters. A work item's texts, its description, repro steps and
  acceptance criteria, and its latest comments, up to ten, oldest first, so an answer follows its question, and, cut to
  fit, the newest stay (`ItemStory.Fact.keepsEnd`), from its details on
  screen, or read as when you open it (`WorkItemStory.context`), under its story's notes' labels, so they take those
  notes' places. A read that fails leaves its part out; once Azure DevOps asks to slow down, nothing more is read; and
  what's read as someone other than who the pull requests' refresh saw signed in is left out. That's up to two GETs a
  pull request and two or three a work item. The demo reads nothing: it has its pull requests' threads, a few made-up
  descriptions and its sprint's details.
- Copilot (`SessionConversation`, in `Sources/CopilotCore`, and `CopilotSource`): a session's conversation, from its
  log, opened below `~/.copilot` without following a symbolic link, for a session's ID, a UUID, only: the whole log
  when it's no longer than 4.5 MB, or else its first 512 KB, for what was asked first, and its last 4 MB, for the
  latest turns. It keeps what you asked, or another session did (a message whose `data.source` starts with `agent-`,
  said as "Another session"), and each answer that ended Copilot's turn, its own message without tool requests, or the
  summary it called its task done with, said once; not what it says as it calls tools, what an agent and its subagents
  say to each other, or the app's notices (`<system_notification>`). Each message is a paragraph, cut short, an ask at
  600 characters, an answer at 900 and the last one at 1,200: what was asked first, then the latest turns that fit in
  3,800 characters in all, with "(N earlier turns left out)", or "(part of the conversation left out)" where the middle
  of a longer log wasn't read. A read takes well under a tenth of a second, even for a log of hundreds of megabytes.
- GitHub: nothing more. BriefBar reads GitHub with one fixed query, so a GitHub pull request's summary has what that
  reads: its reviews, its checks and whether it can merge.

When a Copilot model is selected, `CopilotSummarizer` (in `Sources/CopilotTasks`) runs `copilot -p <prompt> --model <model> --reasoning-effort low
--available-tools=briefbar_no_tools --deny-tool shell --deny-tool write --disable-builtin-mcps --no-custom-instructions
--no-ask-user --no-color --silent --name "BriefBar summary" -C <folder>`, through `ProcessRunner`, with your login
shell's environment, for two minutes at most. No tool is called `briefbar_no_tools`, so the model has none: an empty
`--available-tools` would leave it every tool, as the CLI takes that as no limit. The folder,
`~/Library/Application Support/BriefBar/Copilot/Summaries`, is BriefBar's own and empty, so no project's instructions,
skills or MCP servers apply. Only the chosen model is used. The CLI keeps each run as a session, as it keeps every
session, named "BriefBar summary"; the Copilot app doesn't list them, and nor does BriefBar, even when it finds sessions
from their folders, without the app's database (`SessionStateScanner` leaves out those that worked in that folder,
`CopilotPaths.briefBarSummaries`).
When it fails, `CopilotSummarizer` tells from what the CLI said whether it isn't signed in ("No authentication
information found"), the model isn't on your plan, or your premium requests ran out, and the card says so in a
sentence, "The Copilot CLI isn't signed in. Run copilot in Terminal once.", with what the CLI said in its tooltip,
**Choose Model…** for a model that isn't on your plan, which shows the setting, and **Try Again**.

The summary is kept in memory only, until BriefBar quits, you close it, Show Links or Summaries goes off, or a source
stops, taking what it told with it; one being written is stopped then, and **Stop** stops it too: the model isn't asked,
or its answer is dropped, and `ProcessRunner` stops Copilot, with whatever it started, as at its timeout. Changing models
also stops summaries being written, without starting another; written summaries keep the model that wrote them. The
stories it was waiting for
stop being read, unless the details asked for them too, and a story the details are reading already is waited for rather
than left out. Once what it summed up says something else, it's out of date: what's linked, each one's state, title or
status, or what its story says, as Copilot was given it: where it stands, its facts, how its runs stand, with a failed
one's first error, all that Copilot recorded of its work, and a work item's description and latest comments
(`StorySummaries.Input`); or what was read for it, as it was last read, part by part, such as a reply in a pull request's
comment thread, which changes neither its row nor its story: a part that says something else, or that wasn't there,
counts, but not one that couldn't be read again, as when its read failed. That's read again only as one ten minutes old
or more opens, before it's written again. How long ago anything was isn't part of it, so a task's row and story say "Working" rather
than for how long, which its date says, and a pull request without recent activity says just that; nor is what
Copilot's doing just now, on a session's or a task's row or story, "Working: Run the cart tests" being just "Working"
(`StorySummaries.steady`), nor what a session at work said last, which change every few minutes, while its checkpoints,
its asking or its ending do count; and a story that's
been forgotten since, a quarter of an hour on, makes no difference until it's told again. Nor do a work item's
description and comments when they're known only then or only now: its story has them only while its details were read
and all of them only when its comments could be read too (`ItemStory.notesRead`). Read in full both then and now, a
first comment does, and so does the last one gone. Its caption then says **Out of date**, in bold, and its foot what
changed, "Since then: !4120 changed.", with **Summarize Again**; what it says turns a little lighter. The demo makes
summaries up (`DemoSummaries`) and never runs Copilot, nor does opening anything write one in `--render`, of the demo or
your own data; the demo's pictures show a summary about to be written as it opens, as it's written, once it is, as it's
written again, when that couldn't be, out of date and failed, the line that offers it while it's off (`summary-*`),
and the setting with Show Links off; a pull request's and a session's page with theirs; and a pull request's and a session's summary under its row (`rows-summary-*`), which the other pictures
of the lists don't show.

**Your edits.** Linking adds a link of your own. Unlinking takes it away, or, for a link a source knows, hides it in
BriefBar until you choose **Show Hidden Links**; hiding a pull request's link hides what's linked through it too.
Nothing goes back to Azure DevOps, GitHub or Copilot: the links are BriefBar's own. The edits are kept in the
preferences (`links`) as references only, never titles; those older than 180 days are forgotten, and turning a source
off forgets the ones about its things. A reference another program writes there is checked as BriefBar's own are, or
left out.

**What's read for it,** only while it's on:

- Azure DevOps (`LinkEngine`, with the pull requests' client, after each of their refreshes; every request a GET): each
  of your pull requests' work items, then every quarter of an hour; the sprint's work items with their relations, while
  the sprint is on screen; and what the linked work items and pull requests that no list shows are, so their rows can
  say it. When someone else signs in to the Azure CLI, all it read goes, with what was told and summed up of it, and it
  reads again from the start, as them. The [table below](#where-the-data-comes-from-1) has the requests.
- Copilot: the same database, read-only, in a query of its own, which an app without those columns doesn't answer:
  the list of sessions is read as before.
- GitHub: nothing more. Each pull request's branch comes with the one query (`headRefName`).

**Linking more.** **Link…** opens a window that lists what's linked, then up to four suggestions (`LinkSuggestions`):
on the same branch, naming the other's number (a session called "Fix 5101", a branch `users/robin/5101-fix`), sharing
words of its title, in its repository; then everything else that the sources that are on list. Checking one links it,
unchecking unlinks it. It also takes a pasted link to an Azure DevOps pull request or work item, a GitHub pull request,
or a session (`ghapp://sessions/<id>`, or its ID).

## Microsoft Teams

### Where the data comes from

When Teams shows a notification, macOS keeps a copy in Notification Center's database:

| | |
|---|---|
| File | `~/Library/Group Containers/group.com.apple.usernoted/db2/db` (SQLite, WAL mode), protected by macOS: reading it needs Full Disk Access |
| Tables | `app(app_id, identifier, badge)`, `record(rec_id, app_id, uuid, data, request_date, request_last_date, delivered_date, presented, style, snooze_fire_date)`, and `categories`, `dbinfo`, `delivered`, `displayed`, `requests` |
| Teams' rows | `record` rows whose `app` is `com.microsoft.teams2` (new Teams) or `com.microsoft.teams` (classic) |
| Each row's `data` | A binary plist: `{app, date, req: {titl, body, iden, cate, usda, …}, uuid, …}`. `req.usda` is the notification's user info, archived with NSKeyedArchiver |

Teams' user info, as of Teams 26261 on macOS 27:

| Notification | `default_type` | `default_id` | Message ID | Title / body |
|---|---|---|---|---|
| 1:1 message | `chats` | `19:…@unq.gbl.spaces` | `default_options` JSON `messageId` | sender / text |
| Group or meeting chat message | `chats` | `19:…@thread.v2` (meeting chats `19:meeting_…`) | the same | chat name / `Sender: text` |
| Reaction to your message | `chats` | the 1:1 chat's ID | the same | `<emoji> <Name> reacted to your message` / empty |
| Channel post or reply | `channels` | JSON `{channelId: 19:…@thread.tacv2, replyChainId}` | `default_options` JSON `messageId` | `<Name> posted a new message`, `<Name> replied to …` / text |

Messages, unlike reactions, have a reply box: `textInputsend_type` `chats`, and
`textInputsend_options` JSON whose `convId` is the conversation ID again. That's how BriefBar
tells them apart. No field holds a link, so BriefBar builds one (see
[Opening a chat](#opening-a-chat)).

Notification Center keeps a limited number of notifications per app: 100 for Teams on the Mac this
was built on, about two days' worth, half of them channel posts. It drops old ones as new ones
arrive, and nothing in the database records whether you've read a chat: `app.badge` stays empty,
and `presented` and `style` don't track it. Reading a chat in Teams doesn't remove its notifications
either (Teams 26276 on macOS 27): they stay until Notification Center makes room, or you clear them.

BriefBar never changes the database. It opens it with a read-only SQLite connection, for a few
milliseconds per read, and never copies it. What a query sorts stays in memory, never in a temporary
file (`PRAGMA temp_store = MEMORY`, a setting of the connection that writes nothing to the
database). Like any SQLite reader, it takes brief shared locks and
updates SQLite's shared-memory index (`db-shm`) while it reads; neither changes any data.

### Deciding what's unread

The [table in the user guide](user-guide.md#microsoft-teams) lists the rules. In more detail
(`UnreadTracker` in `Sources/TeamsCore`):

- **Arrival.** A chat message is unread if it was delivered after the chat was last read, or after
  BriefBar started (on its very first launch, everything already stored counts as read, so the
  counts are never wrong on day one). A message posted twice, for example after an edit, is counted
  once: messages are keyed by conversation and message ID.
- **Leaving Notification Center.** When notifications leave the database, either Notification
  Center made room for new ones, or you clicked or cleared them (or Teams withdrew them). BriefBar
   tells the two apart by the count: if the database holds as many Teams notifications as it
  ever has, and at least as many arrived as left, it made room, and those chats stay unread. BriefBar
   keeps them, although Notification Center no longer has them. Otherwise their chat is read up
  to them.
- **Expiry.** Unread messages older than **Keep Unread For** count as read, for the chats BriefBar
  doesn't see you read.
- **Teams' read markers**, while **Mark Chats Read When You Read Them in Teams** is on, as it is by
  default. Teams keeps how far you've read each chat in its own data on the Mac (see
  [Teams' read markers](#teams-read-markers)): the ID of the newest message you've seen. Every
  message up to it in that chat is read, by message ID, and a message whose notification has none, by
  when it was delivered. That holds for messages whose notifications arrive later, and for saved chats
  loaded later. A marker that moves back, as **Mark as Unread** in Teams doesn't even do, or a chat
  Teams drops, makes nothing unread again.
- **Teams' dock badge**, while **Mark All Read When Teams' Badge Clears** is on, as it is by default.
  Reading a chat in Teams leaves its notifications alone, but the badge gets smaller as you read, and
  disappears once nothing in Teams is unread. `lsappinfo info -long -only StatusLabel -app
  com.microsoft.teams2` reads it every 5 s while Teams runs, and when Teams comes to the front or
  leaves it, without any permission. It needs `-long`: without it, macOS 27's `lsappinfo` leaves
  `StatusLabel` out. When a badge BriefBar saw disappears, in the same Teams process, and is still
  gone 10 s later, everything delivered until it went counts as read. The wait passes over a badge
  that's back right away, as it might be while Teams reloads. No badge says nothing by itself: not
  while Teams isn't running, and not in the first minute after it starts, before it has set one. A
  badge that only gets smaller doesn't say which chat you read, so it changes nothing.
- **Launching again.** Notifications delivered after the last read BriefBar took in count as
  unread. It records when that read started every minute and when it quits, so a stretch when it
  couldn't read the database never counts as seen.

Counts are chats with unread messages, like Teams' own badge.

### Teams' read markers

Teams' window is a web app in Microsoft Edge's WebView2, which keeps the site's IndexedDB databases in
Teams' container. One of them keeps how far you've read each chat:

| | |
|---|---|
| Folder | `~/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/EBWebView/<profile>/IndexedDB/https_teams.microsoft.com_0.indexeddb.leveldb`: `WV2Profile_tfw` for work and school accounts, and any other profile and Teams site (`https_teams.<domain>_<port>`) too. macOS protects it: reading it needs Full Disk Access |
| Database | `Teams:conversation-manager:react-web-client:<tenant>:<user>:<locale>`, object store `conversations`: a record per conversation, keyed by its ID (`19:…`), the one Teams' notifications have |
| Read marker | the record's `properties.consumptionhorizon`: `<message ID>;<when it was read, in ms>;<client message ID>`. The message ID is the one notifications carry (`messageId`), when the message arrived, in milliseconds since 1970. `0;0;0`, or nothing, for a chat never read |

Reading a chat in Teams (Teams 26276 on macOS 27) rewrites its record at once, with the marker at the
newest message.

Chromium keeps IndexedDB in LevelDB, and values in Blink's and V8's serialization formats. macOS reads
none of them, so `ChromiumIndexedDB` (in `Sources/ChromiumIndexedDB`) does, read-only, and only as
far as it needs:

- **LevelDB**: tables (`.ldb`) of blocks that Snappy may compress, and the write-ahead log (`.log`),
  each checked against its CRC-32C checksums. Of a key's writes, the one with the highest sequence
  number wins, so the folder reads as it was when the read ended, without LevelDB's lock: LevelDB
  never changes a table once written, and only appends to its log. A table that compaction removes
  while it's read starts the read over. Nothing is written, and nothing copied.
- **The MANIFEST**, which `CURRENT` names, lists the tables and logs that make up the database: its
  version edits, applied in order, leave the tables, and the logs from its log number on. LevelDB
  leaves a file it no longer needs until it can remove it, and one may hold a write that compaction
  has since dropped, a deletion included, so BriefBar reads only those, as LevelDB does as it opens the
  database: otherwise a conversation that was deleted would come back. A table it lists that's
  missing starts the read over, as when compaction replaces tables meanwhile, and so does a MANIFEST
  that `CURRENT` names but that's gone, as when LevelDB replaces it. A MANIFEST that can't be read, or
  that LevelDB would refuse, makes BriefBar read every file, and counts as a file that can't be read.
  LevelDB refuses one with a damaged record, even the last, though a log's last may be one still being
  written: going by the version before it would read tables that edit removed. It refuses files that
  are still missing too, so after three tries, BriefBar counts them against the MANIFEST, or against
  `CURRENT`. Like LevelDB, it skips the rest of a block that reads as zeros, as space never written,
  and reads on, in the MANIFEST and in a log; only zeros that run to the end may be space not written
  yet, which it reads again later, unless they break off an edit of the MANIFEST, which LevelDB never
  leaves as it writes, and refuses.
- **IndexedDB's keys** each start with a database, object store and index (`KeyPrefix`), and Chromium
  sorts keys by that first. So BriefBar reads the databases' and object stores' names first, then
  only the `conversations` stores' records, and skips every table block whose index entries say it
  holds neither, without reading it: on the Mac this was built on, Teams' 117 MB come down to a few
  dozen 4 KiB blocks. Each index entry is its block's last key, as Chromium's comparator leaves it;
  if one weren't, every block would be read.
- **Values**: the record's version, then Blink's envelope (version 21, with the offset of a trailer)
  around V8's format (version 16). Blink compresses large values with Snappy, and keeps one larger
  than 64 KiB in a file in the `.indexeddb.blob` folder next to the database. Plain objects, arrays,
  strings, numbers, dates, maps and sets are read; host objects, shared memory and WebAssembly
  aren't, and a record that holds one counts as unreadable.

Of each conversation, BriefBar keeps its ID and marker, in memory. The rest of its record, such as
its last message, is read only to get past it.

The log is watched as Notification Center's is: kqueue on the `.log`, which LevelDB keeps open, and
FSEvents on the folder, for the log being replaced as LevelDB moves its writes into tables. A write
is read 0.5 s later, from where the last read stopped: only the bytes appended since, and only write
batches that are all there. A record in a blob file is read again when its blob entry arrives, which
Chromium writes after it, often in a later batch. The folder is read again from scratch when its log
is replaced or its databases change, and every 10 minutes, which also finds Teams' folder once you
sign in.

Teams' own data is read only while BriefBar can read Notification Center's database, which takes the
same Full Disk Access: opening Teams' container without it would have macOS ask to let BriefBar access
data from other apps, and an answer there would let it read Teams' data without Full Disk Access. With
another Notification Center database, such as the demo's, BriefBar reads only what
`BRIEFBAR_TEAMS_CACHE` names, laid out as `EBWebView` is.

### What's saved

Unread chats must survive a restart even after Notification Center dropped them, so BriefBar
saves them, and only them, to `~/Library/Application Support/BriefBar/Teams/unread`:

- Per unread chat: its ID, kind and name, and its unread messages (ID, time, sender and text), at
  most 20.
- Sealed with AES-GCM (CryptoKit). The 256-bit key is a generic-password item in your login
  keychain, which macOS lets only BriefBar read, identified by its signature. BriefBar names that
  keychain by its file, `Library/Keychains/login.keychain-db` in your home folder as the user
  database names it, to look for, add, update and delete the key. It doesn't use the default
  keychain or the search list, which any program running as you can change with
  `security default-keychain -s` and `security list-keychains -s`. Given a keychain that isn't
  there, macOS adds to the default one instead, so without that file BriefBar saves no key, and so
  no chats.
- Only the app opens it. Any program can run BriefBar's binary. From a shell, macOS holds the app
  that shell runs in responsible, so the binary gets none of BriefBar's Full Disk Access, but the
  keychain would still give it the key without asking. So the command-line modes and `--render` never
  use the key. They read Notification Center with the access of whoever runs them, and count as
  unread only what arrived since the app last read it: a chat that only this file still has, because
  Notification Center dropped it, doesn't show there. Started any other way, they don't run at all
  (see [Programs that start BriefBar](#programs-that-start-briefbar)).
- Written atomically, readable only by you (0600), in a folder only you can open (0700) that Time
  Machine skips.
- A chat leaves the file as soon as it's read or expires, even while the database can't be read,
  and the file is deleted when nothing is unread. A file that can't be opened with the key is
  deleted, with the key.
- If the key can't be read when BriefBar starts (a locked keychain, or a declined prompt), the
  file is left alone and never overwritten. BriefBar tries again after 1, 5, 15 and 60 minutes,
  and merges what it loads, minus what was read since. Until then it doesn't record how far it has
  seen, so the next launch counts everything since as unread.

Next to it, `state.json` holds when BriefBar first read Teams' notifications, when it last did and
whether it ever had access. Nothing else about Teams touches the disk: Teams' read markers stay in
memory. Turning Teams off deletes both files and the key, without reading them, and the folder if
that leaves it empty.

### Updates are pushed, not polled

Notification Center keeps its database open. FSEvents reports a file's writes only once the writer
closes it, so it never sees them. BriefBar instead watches SQLite's write-ahead log (`db-wal`)
with **kqueue** (`EVFILT_VNODE`), which reports every write as it happens, and reads Teams' rows
again 0.3 s later, combining bursts. FSEvents on the `db2` folder reports the log being created or
replaced, so the kqueue watch can move to the new file. `db` itself is deliberately not opened for
watching: closing an extra file descriptor on a SQLite database drops the process's SQLite locks.

Notification Center writes for every app, so most writes change nothing for Teams; BriefBar
publishes only when Teams' notifications changed. Five timers exist, and none drives updates:

- a 15 s tick that refreshes relative times and expires old unread messages,
- a 60 s safety rescan that catches anything missed, for example after the Mac wakes from sleep,
- while BriefBar can't read the database, a check for access: every 2 s while the Full Disk
  Access window is open, every 30 s otherwise,
- while **Mark All Read When Teams' Badge Clears** is on, as it is by default, a 5 s check of Teams'
  dock badge, which runs `lsappinfo` only while Teams runs (see
  [Deciding what's unread](#deciding-whats-unread)), and
- while **Mark Chats Read When You Read Them in Teams** is on, as it is by default, a 10-minute read of
  Teams' read markers from scratch (see [Teams' read markers](#teams-read-markers)).

### Opening a chat

Clicking a chat opens Teams' documented link to a message in a chat, with Teams' own URL scheme so no
browser is involved, at the chat's oldest unread message:

```text
msteams:/l/message/<conversation ID, percent-encoded>/<message ID>?context=%7B%22contextType%22%3A%22chat%22%7D
```

It's opened with Teams itself as the handler. A message without an ID falls back to
`msteams:/l/chat/<conversation ID>/0`.

### Getting listed under Full Disk Access

macOS lists an app under **Full Disk Access**, switched off, once it has been denied a folder that
Full Disk Access protects. Notification Center's database doesn't get BriefBar listed: it's in a
group container, which macOS guards with its App Data protection
(`kTCCServiceSystemPolicyAppDataDetailed`, "found app sharing this group container" in `tccd`'s log),
and that denies quietly. So while it has no access, and Teams is on, when its Full Disk Access window
opens and when you click **Open Privacy Settings**, BriefBar tries to list the folders Apple's Stocks and Safari
keep, as the [FullDiskAccess](https://github.com/inket/FullDiskAccess) package does. That reaches
`tccd` as a Full Disk Access check (`kTCCServiceSystemPolicyAllFiles`), which it denies without a
prompt. Without access, nothing is read. Whether macOS then lists the app was confirmed up to
macOS 14 by that package's author. On later versions, the window still explains how to add it with
**+**.

Organizations can skip the step entirely: a configuration profile with a
`com.apple.TCC.configuration-profile-policy` payload that allows `SystemPolicyAllFiles` for
`com.asaf.BriefBar`, with its designated requirement, grants the access when their MDM installs it.
`scripts/make-pppc-profile.sh` writes one for a built app.

### Summaries

The ✨ button on a chat asks Apple's on-device model for one sentence: what the chat is about, and
anything it asks of you (`Summarizer` in `TeamsUI`, `SummaryPrompt` in `TeamsCore`, the model in `OnDeviceModel`).
The brief asks it the same of the chats it shows, while a list by state or the Overview is on screen
([The brief](#the-brief)).

- The session is created with `SystemLanguageModel.default`, the model that runs on the Mac. The
  framework also offers `PrivateCloudComputeLanguageModel`, which runs on Apple's servers; BriefBar
   never uses it, so nothing leaves the Mac.
- The prompt holds the chat's name and kind, and its unread messages with their senders, oldest
  first (its latest messages if none are unread). The newest messages that fit in 3,000 characters
  are kept, each cut at 600, to stay within the model's context window.
- A summary is kept in memory for as long as it covers the chat's newest message, and never saved.
- With **Show Message Previews** off, summaries are hidden too, since they'd reveal the same.
- Without Apple Intelligence (on a Mac that can't run it, or with it turned off), the setting says
  why. An unsupported language, a refusal or a busy model shows a short note instead of a summary.

### When the formats change

All three formats are undocumented, so every read is checked:

- **The database's layout.** `PRAGMA table_info` lists its tables and columns first. Without
  `app(app_id, identifier)` or `record(app_id, data)`, BriefBar reports which are missing and shows
  nothing rather than guess. The other columns are optional.
- **Each notification.** Records that aren't a plist, have no request, user info or `default_type`,
  or are chat notifications without a valid `19:…@…` conversation ID are counted. If none of the
  stored Teams notifications can be read, the lists say Teams' notifications have changed; if more
  than a quarter can't, they say how many. Well-formed notifications of kinds BriefBar doesn't
  show, such as calls, are set aside without counting against it, unless they look like chat
  messages (a reply box, or a chat's ID): that's more likely a renamed chat type, so they count.
- **Archives** are decoded with secure coding and plist classes only, so an unexpected class makes a
  record unreadable instead of being instantiated.
- **Teams' read markers.** Files, log records and values that can't be read are counted, values by
  why. If Teams' folder has no `conversations` store, or none of its conversations has the read
  marker field in the form BriefBar understands, the lists say Teams' read markers have changed: a
  chat never read has the field too, as `0;…`, so a new account, whose chats have no marker yet,
  isn't taken for one. If more than a quarter can't be read, or a file can't, or a log record is
  damaged, with others after it, they say some couldn't be read. A table LevelDB is still writing isn't in
  its MANIFEST yet, so isn't read; one that can't be read counts only after it has stayed unchanged
  and unreadable for at least 5 s, since without the MANIFEST, LevelDB writes a table where it'll
  stay, and one being written reads as broken until it's done. The MANIFEST, `CURRENT` or a log that
  can't be read counts after 5 s too, though Teams appends to it meanwhile: that doesn't make it
  readable. Each read rechecks those table paths,
  so finishing or removing one clears its warning even if the current log hasn't changed. Neither
  keeps the lists from showing: chats you read in Teams then stay
  unread until another rule reads them. Lengths, nesting, blocks' keys and sparse arrays are checked
  against what's there and capped, so a value can't make BriefBar read past it, or hold much more
  than it.

`--diagnose` and **Copy Diagnostics** describe all of this by structure only: table and field names,
counts, and the shapes of values, such as `<oneOnOne ID>`, `<13-digit>` or
`json {actionType: view, messageId: <13-digit>, userContextId: <guid>}`. They also show Teams' dock
badge as BriefBar reads it, and of Teams' read markers, the folders, counts of conversations and
markers, and the formats of their values.

### Why not Microsoft Graph or a server?

Graph would need your organization to consent to an app, lets an app poll a user's chats only once
a day, and delivers changes as they happen only to a public webhook, so a server. Organizations
that use Teams also rarely allow chat content, or summaries of it, to leave their Macs. Notification
Center already has everything a glance needs, on the Mac, and Teams' own data there says how far
you've read each chat.

## Azure DevOps

### Signing in

BriefBar gets bearer tokens from the Azure CLI:

```sh
az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --output json
```

The GUID is Azure DevOps's application ID. The CLI answers silently from its own token cache and
refreshes its sign-in by itself, so BriefBar never shows a sign-in screen unless the CLI is signed
out. A token lasts about an hour; BriefBar reuses it until five minutes before it expires, and asks
again if Azure DevOps rejects it. The token also says who it's for: when you sign in to the CLI as
someone else, BriefBar starts over with their pull requests, and what they've seen.

#### Organizations in other directories

An organization belongs to one directory (a Microsoft Entra tenant), and Azure DevOps reads it only
with a token from that directory. When it rejects a token, with 401 or a sign-in page, it names the
organization's directories in `X-VSS-ResourceTenant`. When the token's own directory (its `tid`) isn't
among them, BriefBar asks the CLI for a token from the organization's directory, and tries again:

```sh
az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --tenant <directory> --output json
```

It remembers the organization's directory while it runs, once a token from there works, so its next
requests get such a token right away; one that moves to yet another directory is followed the same way.
Only GUIDs from the header are used, never the empty one. When the CLI can't give a token from there,
because it isn't signed in to that directory, that organization's problem says so: "fabrikam is in a
directory your Azure CLI isn't signed in to", with **Sign In…**, which opens Terminal to run
`az login --tenant` with the directory's ID, and `--allow-no-subscriptions`, as every sign-in does, for an
account without Azure subscriptions. Until then, each refresh asks Azure DevOps once, with a token from your
directory, which directory the organization is in, so a move is noticed too. The other organizations'
pull requests stay listed and counted, as when any of them can't be read, and once the CLI is signed in
there, the organization is read with the rest. Until then, what's listed from it stays as it was read: its
pull requests' details, builds and merges aren't asked for. An organization in such a directory says so,
whatever else failed reading it, but Azure DevOps asking BriefBar to slow down comes first. A pull
request you watch, or that was sent to you, in such an organization says the same, and is read once
you've signed in there, when its turn comes round, rather than an hour later: such an organization takes
one of the ten reads a refresh gives those pull requests, then waits behind the others, and is said at
every refresh until it's read. When every organization you
watch is in such a directory, the pull requests sent to you from others are still read. The Sprint and
Pipelines sections, the Add Pipelines sheet, its projects included, and a work item's details say the
same, and the sheet offers **Try Again** to read its projects and search again once you've signed in;
pinned pipelines in such an organization are asked for once a refresh. A team you chose shows its
sprint even while the teams of the organizations you watch wait on such a sign-in, and the Sprint names
them with any other organizations whose teams, or your team's sprint, couldn't be read; a team BriefBar
finds for you then is shown, but kept only once it's been compared with theirs: it's looked for again as
each of their directories is signed in to, or as its own needs a sign-in, and stays unkept until their
teams are read. A team whose sprint can't be read for want of such a sign-in counts among them, and
doesn't take the turn of another; and a team found for you whose organization turns out to wait on such
a sign-in, as its board or another of its organization's sprints is read, is set aside, neither shown
nor kept, and another of yours is looked for. The command line and agents, which have no button, say what to run;
an agent's work item, asked for by its number alone, is looked for in your other organizations too, and
such an organization is named only when none of them has it. With no organizations chosen, an agent
looks in one of yours in such a directory again at most once a minute, so signing in there finds your
pull requests there. A directory's ID is never shown otherwise,
and what the Azure CLI says when it can't give a token goes to the log without IDs, email addresses (a
guest's user name included) or the names of directories it quotes, in single or double quotes, or names.
The log names none of these organizations, nor the others that couldn't be read with them, and says
only how many are in such a directory: a pull request sent to you comes from a chat. While nothing could
be read but such organizations, BriefBar looks again every minute, as it does while the CLI is signed
out.

Your own tokens come from your sign-in's directory: the CLI's default directory, the first time, and
then that same directory, asked for with `--tenant`, even once `az login --tenant` has made another
directory the CLI's default. So signing in to an organization's directory changes neither whose
sign-in BriefBar reads with, nor what it read in your directory. BriefBar starts from your sign-in's
directory as it last read with it, whichever section did, the pipelines or the sprint without pull
requests too (`ado.accountDirectory`), and where that account is from (`ado.accountOrigin`); the
command line and agents do too. Turning Azure DevOps off forgets both,
with what you've seen, and nothing read before then saves them again. When the CLI can't give a token in your
directory, BriefBar looks at its default directory's token: a guest's names where its account is from
(`idp`), its own directory or, for a personal Microsoft account, `live.com`. When that's your account's,
your directory only wants you to sign in again, and BriefBar says so, with **Sign In…** signing in
there, with `az login --tenant` and your directory's ID: a plain `az login` may sign in to another
directory without what yours asks for, such as multi-factor authentication. Otherwise someone else has
signed in to the CLI, and their directory becomes the one BriefBar reads with. Tokens kept for other
directories are for the same account as yours: when someone else signs in, those go too, and one from
another directory for an account from elsewhere isn't used by anything that asked for it, nor kept:
every token kept goes with it, and BriefBar asks for yours again, which tells who's signed in. Nor is one
that was on its way when someone else signed in, wherever they're from.

**Add Organization…** checks that your sign-in can read the organization, with `_apis/connectionData`,
before watching it, and says why when it can't. One it reads is watched. One in a directory the CLI
isn't signed in to is watched too, and **Sign In…** signs in there. One it can't read otherwise isn't:
one that Azure DevOps can't find, that isn't one of your organizations (`_apis/accounts`), or that you
have no access to. Only those are checked against your organizations: one read in another directory is
read as your guest account there, which `_apis/accounts`, asked as you, may not list. A project's name,
entered as an organization's, can be another organization's, even one in another directory: so when an
organization is in another directory, or isn't one of yours, BriefBar also says where a project's
organization is, the first part of its link. One that couldn't be checked, offline say, or whose
membership couldn't be, is watched, and its list says what's wrong. Turning Azure DevOps off while it
checks stops the check, and nothing is added.

An app started from Finder or as a login item doesn't get your shell's `PATH`, so BriefBar looks
for `az` in `/opt/homebrew/bin`, `/usr/local/bin` and the other usual places, then asks your login
shell (`command -v az`). Its runs of `az` turn off the CLI's telemetry and warnings, and each is
limited to a minute: `az` runs in a process group of its own, which is ended at the time limit, and
anything it leaves running that keeps its output open is ended half a second after it exits. Both `az`
and the login shell are responsible for themselves, so they never get BriefBar's Full Disk Access (see
[Programs BriefBar runs](#programs-briefbar-runs)). Set `BRIEFBAR_AZ` to the path of `az` to use another
one.

Signing in sits behind a small protocol (`AccessTokenProvider`). A provider using Microsoft's
authentication library (MSAL) can be added once there's an app registration to sign in with.

### Where the data comes from

All requests are GETs to the Azure DevOps REST API (version 7.1), but for the four changes **Make Changes in Azure
DevOps** makes, last in the table, each when you click it ([below](#replying-and-setting-a-threads-status), and
[a pull request's tags](#a-pull-requests-tags)):

| Request | When | Provides |
|---|---|---|
| `_apis/connectionData` | once per organization, and again when you sign in as someone else; and when you add an organization, to check that your sign-in can read it | your identity ID and name |
| `_apis/git/pullrequests?searchCriteria.creatorId=…&status=active` | every refresh | your active pull requests, across all projects, with their tags (`labels`), as each list here has them |
| `_apis/git/pullrequests?searchCriteria.reviewerId=…&status=active` | every refresh | the ones you review |
| `_apis/git/pullrequests?searchCriteria.creatorId=…&status=completed&minTime=…` | every refresh | yours completed in the Done window |
| `{project}/_apis/policy/evaluations?artifactId=vstfs:///CodeReview/CodeReviewId/{project}/{id}` | per pull request | builds, status checks, reviewer and other policies |
| `{project}/_apis/git/repositories/{repo}/pullRequests/{id}/threads` | per pull request | comment threads, and activity: pushes, votes, reviewer changes |
| `{project}/_apis/git/repositories/{repo}/pullRequests/{id}/iterations?includeCommits=false` | only in a pull request's details, as the first thread on code or its Files come on screen; again after a push or a move to another target branch, and once for a thread on an update it hadn't read | its updates, and the commits each one's diff compares |
| `{project}/_apis/git/repositories/{repo}/pullRequests/{id}/iterations/{n}/changes?$top=2000&$skip=…&$compareTo=…` | with them: once for each diff a thread on screen was made on, and once for the diff of that update with the latest; for the Files, once for the latest update's diff with the base, and, once you've looked at the pull request before, once for its diff with the update you'd seen; up to five pages of 2,000 files | the files it changed, with their object IDs before and after |
| `{project}/_apis/git/repositories/{repo}/blobs/{objectId}?$format=octetstream` | with them: once for each version of a file that a thread on screen is on, and, in the Files, of each file whose row comes on screen, one file at a time, or whose page you open, up to 1 MB of it; four of these requests at a time | the file's text |
| `{project}/_apis/git/repositories/{repo}/items?path=…&versionDescriptor.version={commit}&versionDescriptor.versionType=commit` | instead, for a file that the diff didn't change, or without its object ID | the file's text at that commit |
| `{project}/_apis/git/repositories/{repo}/pullRequests/{id}/conflicts?$top=100&$skip=…` | only in the details of a pull request whose merge status says it has conflicts, as they show in a window you can see, and again once its branch or its target moves; a page of a hundred, up to ten | the files that conflict with its target branch, how each does, and whether someone resolved it in Azure DevOps |
| `{project}/_apis/build/builds/{id}/timeline` | once for each failed build of your pull requests, and again if it's retried and fails again: four a refresh; one that can't be read is tried again on the next refresh, then less and less often | where the build failed, and the first error there |
| `{project}/_apis/build/builds/{id}` | only when you open a pull request's build in its details (below), and when you open it again within ten minutes, to tell whether it ran again since | the run: its pipeline, commit, branch and how it ended |
| `{project}/_apis/build/builds/{id}/timeline`, `…/logs` | when you open a pull request's build in its details, unless BriefBar read it less than ten minutes ago, or half a minute while it's going, and it hasn't run again since | its stages, jobs and tasks, their errors, and how long each log is |
| `{project}/_apis/build/builds/{id}/logs/{logId}?startLine=…&endLine=…` | the same, for the step that failed | the last 200 lines of its log |
| `{project}/_apis/test/runs?buildUri=…&includeRunDetails=true` | the same, a hundred test runs a request, up to five hundred | the tests it published, by outcome |
| `{project}/_apis/test/Runs/{runId}/results?outcomes=Failed,Error,Timeout,Aborted` | the same, for its first three test runs with failures | the first 20 tests that failed, with their messages and stack traces |
| `{project}/_apis/build/builds?definitions=…&branchName=refs/pull/…&maxBuildsPerDefinition=25` | the same | the pipeline's runs on the pull request, for one that passed on the same commit |
| `{project}/_apis/build/builds?definitions=…&branchName=…&statusFilter=completed&$top=5` | the same | the pipeline's latest finished runs on the target branch |
| `{project}/_apis/build/builds?repositoryId=…&branchName=…&minTime=…` | after you merge a pull request (below): every refresh for half an hour, while one of its runs hasn't finished, and for a quarter of an hour after the last one did; five merges a refresh, the newest first | its target branch's runs, among them those on its merge commit |
| `{project}/_apis/build/builds?reasonFilter=buildCompletion,resourceTrigger&minTime=…` | the same, once a run on the merge commit has been found | the runs that runs started, such as a deployment |
| `{project}/_apis/build/builds/{id}/timeline` | for those runs, each pipeline's latest: every refresh while it runs, and once when it finishes (again if it's retried); four a refresh | its stages, whether one waits for an approval, and where it failed |
| `_apis/git/pullrequests/{id}` | when one of yours leaves the active list: five a refresh, the ones not looked up yet first; one that fails is tried again on the next refresh, then less and less often | whether it was completed or abandoned |
| `_apis/git/pullrequests/{id}` | for a pull request someone sent you, or that you watch, that isn't in your lists: ten a refresh, the ones never read first, then the ones read or tried longest ago; one that's closed or can't be read is tried again an hour later, and one whose organization waits on a sign-in to its directory is tried, with the others there, when its turn comes round. Once Azure DevOps asks to slow down, the rest are read at a later refresh, and none of them counts as one that can't be read | the pull request, to list it |
| `{project}/_apis/git/repositories/{repo}/pullRequests/{id}/workitems` | only with [Show Links](#links): once for each of your pull requests, twenty a refresh, then every quarter of an hour, four a refresh; one that can't be read is tried again an hour later | its work items |
| `_apis/wit/workitems?ids=…&$expand=relations` | only with Show Links, while the sprint is on screen: when its work items change, and every quarter of an hour; 200 work items a request. Azure DevOps doesn't take the fields to return with relations, so all of them come too | the pull requests each of the sprint's work items links to |
| `_apis/wit/workitems?ids=…&fields=…` | only with Show Links: for the work items linked to your pull requests that the sprint doesn't show, and those you linked, every quarter of an hour; 200 a request | their title, type, state, project and when they changed |
| `_apis/git/pullrequests/{id}` | only with Show Links: for a pull request linked to a sprint's work item, or that you linked, that your lists don't show, ten a refresh, the ones never read first; again every quarter of an hour while it's open, and every six hours once it's closed | the pull request, to show it |
| `app.vssps.visualstudio.com/_apis/profile/profiles/me`, `…/_apis/accounts` | finding your organizations; and when an organization you add can't be read, to tell whether it's one of yours | your organizations; then each one is checked for your pull requests, and when Azure DevOps asked to slow down before every one was checked, or none were found because some couldn't be checked (offline, say), it tries again a minute later, rather than keeping what it found as all there is |
| `POST {project}/_apis/git/repositories/{repo}/pullRequests/{id}/threads/{thread}/comments` | only with Make Changes in Azure DevOps on, when you click **Reply**, **Reply & Resolve** or **Reply & Reactivate**: once | your reply, in reply to the thread's first comment; Azure DevOps answers with it, as it keeps it |
| `PATCH {project}/_apis/git/repositories/{repo}/pullRequests/{id}/threads/{thread}` | the same, when you set a thread's status, or after your reply with Reply & Resolve or Reply & Reactivate: once | the thread's status alone; Azure DevOps answers with the thread, its comments as it has them now |
| `{project}/_apis/git/repositories/{repo}/pullRequests/{id}/labels` | only in a pull request's details, for one whose lists don't carry its tags, such as one sent to you or that you watch: as they show on a window's page on screen, then ten minutes after they were read, while they show; and after a change to its tags, or one called off as Make Changes in Azure DevOps goes off, below | its tags |
| `POST {project}/_apis/git/repositories/{repo}/pullRequests/{id}/labels` | only with Make Changes in Azure DevOps on, when you add a tag to an open pull request: once | the tag's name; Azure DevOps answers with the tag as the project has it, which it makes when the project has none of that name |
| `DELETE {project}/_apis/git/repositories/{repo}/pullRequests/{id}/labels/{tag}` | the same, when you click a tag's ✕: once | nothing but the tag, by the project's tag's ID; the project keeps the tag |

The list endpoints have no "last updated" field, and new comments don't change anything in them,
so a pull request's details (policies and threads, two requests) are fetched on a schedule
(`RefreshPlanner`):

- every pull request without details, which is all of them on the first load, in parallel, four at a
  time;
- then, at most eight others a refresh: changed ones first (a push, a vote, a merge status or draft
  change), by when they were last read, then the ones that are due, by when they became due, the
  earliest first. One with a build or check in progress is due a minute after it was last read, the
  others three minutes after, and drafts and idle ones fifteen. So while more builds run than a refresh
  reads, the other pull requests still get their turn, and their new comments come in.

Requests honor `Retry-After`, in seconds or as the date to wait until (`RetryAfter`): when Azure DevOps asks to
slow down, nothing is sent until the time it gave, or for a minute when it doesn't say (`ADOClient.retryAfterUnsaid`).
When nothing can be read (offline, for example), refreshes back off up to ten minutes, and waking the Mac or getting
back online refreshes right away.

Each request goes only where it's sent, with the Azure CLI's token: no redirect is followed (`RedirectGuard`). One to
another host fails with an error that says so (`ADOError.redirected`), and one on the same host is an HTTP error like
any other, as Azure DevOps answers each request where it's sent. The error doesn't name the host, which can carry an
organization's name, as it goes to the log.

Azure DevOps can't push updates to a personal app: service hooks need a project administrator and a
server reachable from the internet. Pull requests and builds take minutes to hours, so a refresh a
minute is plenty.

### How a pull request's group is decided

The [groups table in the user guide](user-guide.md#azure-devops) lists them. In more detail:

**Checks.** Each branch policy becomes a check:

- **Build**: approved is passed, rejected is failed, running is running. A queued build whose
  context says `isExpired` has expired and has to run again; a queued build without a build ID
  hasn't run at all (for example, because it's queued by hand). A failed build's errors aren't part
  of its policy, so BriefBar reads the run's timeline, once, and finds where it failed as it does for
  a pinned pipeline: the earliest failed task (or job, or stage), with its stage and its first
  error. The list, the notification and the brief then say so: "shop-web CI · Run unit tests: 2
  tests failed in DeliveryEstimateTests." Until then, or when the timeline can't be read, they name
  the build.
- **Status** (posted by another service): rejected is failed; queued means waiting for it.
- **Minimum number of reviewers**, **Required reviewers** and **Proof Of Presence** are about
  approvals.
- **Require a merge strategy** is checked when the pull request is completed, so it doesn't count
  against being ready.
- Other requirements, such as **Work item linking** and **Comment requirements**, are reported as
  rejected until they're met: that means pending, not failed.

Only blocking policies count. A disabled policy is ignored. When a project doesn't let you read its
policies, nobody can tell whether a pull request there is ready: it waits, as **Can't read its
policies**, even when its threads couldn't be read that time. And ready means ready as the pull
request is now: until its policies have been read again after a push or a vote, it waits.

**Your pull requests** are, in order: in **Needs You** if something new needs you, or a comment you've
seen still waits on you (below); **Idle** if
they're drafts or have had no activity (comments, pushes, votes) for two weeks; **Failing** for a
failed build or status check, merge conflicts, a merge Azure DevOps couldn't make otherwise (its
`mergeStatus` is `failure` or `rejectedByPolicy`) or an expired build; **Waiting** while a reviewer
wants changes; **Ready to Complete** when every blocking policy passes (or, without reviewer
policies, someone approved) and every person it requires as a reviewer approved, whether a policy or
someone added them, since Azure DevOps doesn't complete it before; and **Waiting** otherwise, with what
it's waiting for. A team it requires counts as its policy says.

**Pull requests you review** are in **Needs You** for something new, or a reply or mention you've seen
that still waits on you, **Idle** if they're drafts,
inactive, or you approved or declined them, **To Review** if you haven't voted, and **Waiting** if
you asked the author for changes.

A pull request that would be **Idle** or **Waiting** is in **Answered** instead while there's
something you answered yourself that you haven't seen yet (see below).

### What's left before you can complete it

A group says the one thing that matters most; each of your open pull requests also says all of it at
once (`PRReadiness`), once its details are read, from the same checks and votes as its group:

| Item | Said | Done when |
|---|---|---|
| A draft | ✋ **Publish the draft** | It isn't one |
| A reviewer who wants changes | ✋ **Sam wants changes**, **Sam rejected it**, **Changes requested** | Nobody does |
| **Minimum number of reviewers** | **1 of 2 approvals**, **Not approved yet**, **Approval policy pending** | The policy passes: **Approved** |
| No reviewer policy | **Not approved yet** | Someone approved |
| A reviewer it requires: a person by a policy or by hand; a team as a pending **Required reviewers** policy names it (`requiredReviewerIds`), or any that hasn't approved when the policy doesn't say | **Waiting on Sam**, **Waiting on 2 reviewers** | They approved; for a team, its **Required reviewers** policy passes |
| Builds | ✕ **Build failed** or **Build expired**, ✋ **Build hasn't run**, ↻ **Build running** | Every build passed |
| Status checks | ✕ **Check failed**, ↻ **Check running** | Every check passed |
| **Comment requirements** | ✋ **Resolve 2 comments** | The policy passes: **Comments resolved** |
| **Work item linking** | ✋ **Link a work item** | **Work item linked** |
| Any other blocking policy | Its name | It passes |
| Merge conflicts | ✕ **Merge conflicts** | There are none |
| A merge Azure DevOps couldn't make otherwise | ✕ **Merge failed**, **Merge rejected** (by a policy) | It merges, usually after another push |
| Policies you can't read | **Can't read its policies** | Never: nobody can tell |

What's left comes first, as the lists order states: what waits on you, what failed, what's running and
what waits on others, then what's done. Without a comment policy, open threads (active or pending) are
said, as **2 open comments**, but don't count against it. It's ready, with nothing left, exactly when it
would be **Ready to Complete**: everything it requires is done, as the pull request is now. Something new
that needs you, or two weeks without activity, still puts it in **Needs You** or **Idle** first. After a
push or a vote, until its policies are read again, it says what was read last, and isn't ready. When
enough people approved but a **Minimum number of reviewers** policy still isn't met, as when the last one
to push can't approve, it says **Approval policy pending**: BriefBar doesn't read who the policy counts.

**Sorting.** The list, in the menu bar and on the window's page, is by status unless you sort it by
date (`PROrder`, in the preferences as `ado.pullRequestOrder`): then every pull request but Done's and
Idle's is in one list, by when it was created, the newest or the oldest first, and each row's time is
its age. Idle's, folded below it, are in the same order; Done's, closed already, stay the latest first.
Counts, the brief, notifications, widgets and lists by state stay by status.

### A pull request's details

A click on a pull request on the window's page shows its details beside the list, or over it when the page
is narrower than 700 points (`PullRequestDetailsStore`, `PullRequestDetailsPanel`), as a work item's details
show beside the sprint: the two pages share how they lay them out (`DetailsSplit`, `DetailsLayout`), and this
one keeps its own width (`ado.pullRequestDetailsWidth`). The row shows as selected, and the click sees the pull
request, as opening it does. While they show it, though, what waits on you in its threads is as it was before
they showed it (`PullRequestDetailsStore.pendingEvents`, with `PRStore.snapshot(of:seenAt:)`): a new comment in
a resolved thread, which waits on you only while it's new, doesn't fold away as you read it, and what was new
stays new. Answering it still counts, and removing the pull request from Needs You or sending its comments to
Copilot ends that look, as showing another one or closing them does: then what you've seen is seen there too.

A pull request opens there from anywhere else in BriefBar too, as the one place it opens
(`PullRequestDetailsStore`): from the window's other pages, the Overview's rows and its brief (`BriefLine.show`),
the Notifications page (`openNotificationInWindow`) and the Pipelines page's cards, always; from the menu bar's
list, a list by state in a popover, widgets, the Overview widget's brief and Notification Center, only with
**Open Pull Requests in BriefBar** (`ado.opensPullRequestsInBriefBar`, off by default: `open(_:)`), and otherwise
in Azure DevOps, as before. A row knows which by where it shows: a window's page sets `panelStyle` to `.page`, the
Overview's rows too. Without a window that has the Pull Requests page, it opens in Azure DevOps all the same, and
its menu offers only that; otherwise its menu has both, what a click does first: **Show in BriefBar** from the
menu bar and widgets, **Show Details** in the window, and **Open in Azure DevOps**. Showing it there sees it, as
opening it in Azure DevOps does. It shows at what its row is about (`Place.about`): where its link leads
(`PRSnapshot.place`, `PullRequestPlace` in `Sources/AzureDevOpsCore`), the thread of the comment that needs you
or that you answered, or the run after its merge that failed or waits; else, for one that's failing, the first of
its builds and checks that failed; else their top, which starts with what's left. A notification shows its own
thread or run instead, which its link names, or else what its row is about (`reveal(notification:link:)`, by the
pull request's key the notification keeps, `PRKey(description:)`). A **Your Pull Requests** card on the Pipelines
page shows the run you click, or for its title the first that failed, else the builds and checks; an **After
Your Merges** card, the run its merge's pipelines name, while the list still has the pull request.

On the Sprint page, the page of one of your pull requests over a work item's details, and on the Pull Requests page
one over another pull request's, is the same view as its details (`LinkedItemPage`, `PullRequestDetailsContent`),
in a store the details keep for their pages, which follows the list and sees it as it shows, keeping what was new in its
threads new, as the details do, and keeps it while the page shows once the list doesn't have it, such as one under Done
that showing it sees, or a review that merges, until you go elsewhere; it says how it's linked to what it opened from,
leaves that out of **Also Linked**, and the header's way there carries on, `Bug 5110 › !4091 › …`, with ↗ and the
details' menu above it, for the pull request the page shows. A pull request your lists don't have, such as a teammate's,
keeps the page Show Links tells (`ItemPageView`).

They show what the list read already, so nothing more is read for them but the code that comment threads are on
([below](#the-code-comments-are-on)), the files the change touched ([below](#its-files)) and the files that conflict
([below](#its-merge-conflicts)), and they follow the list as it refreshes (`PullRequestPanel` in
`Sources/AzureDevOpsCore` puts it in order): what it is and where, its title, its row's sentence, its opening words in
its state's color, and since when; its branch and who wrote it; ✨ **Summarize** and its summary, as a pull request's
page has them; then **What's Left**, its `PRReadiness` items, what's left first, each saying **Your turn** when it
waits on you or failed, unless Copilot fixes, or pushes, its threads, builds or conflicts, with a task of BriefBar's or
a prompt sent to one of the Copilot app's sessions, which says **Copilot's on it**, with its line's symbol, or
**Copilot asks you** while that session waits for your answer (`CopilotTasksStore.onIt`), and those about its
comments, its merge conflicts, its builds and checks or its reviewers taking you there; the files that conflict with
its target branch, while it has conflicts, as below; its comment threads, by file, as below; the files its change
touched, as below; its builds and status checks, as its page's pipelines say them
(`PullRequestStory.run`), what failed first, the required one first, with where a build failed, its first error
and its run, or, once it merged, the pipelines that ran after; who reviews it, the ones it requires first, with
how each voted; and **Also Linked**, as on a page, whose work items, sessions and pull requests open as pages over
the details, **‹**, **⌘[** or Esc going back, and the header saying the way there, `‹ !4102 › 5160`. A pull
request's description isn't there: BriefBar reads it only for a summary. **↗** opens the pull request where its
row does: at the comment that needs you or that you answered, or a merge's run; ↗ on a thread or a build opens
that, and **⋯** has the row's menu, its Copilot actions among them while Send Work to Copilot is on.

Something else can ask the details to show a pull request at a place (`PullRequestDetailsStore.Place`): a thread,
which unfolds the resolved ones when it's one of them, a build by its run, a check by its name (the first of that
name), or a part, such as its comments, which What's Left does. They scroll there once it shows, and point a
thread, a build or a check out for a moment; for a thread they don't have, they scroll to their comments, and for
a run or a check they don't have, such as a run that isn't the one a policy queued last, to their builds and
checks (`Place.anchor(in:)`). Taken to a thread, the header names it after the pull request, `!4102 ›
PaymentsClient.cs:88` (`PullRequestDetailsStore.trailThread`), at the line its card shows, where it was made
(`ThreadCode.place`), until they go elsewhere in them or over them; the pull request's number there takes them
back to their top (`Place.top`). `reveal(_:at:)` shows them on the window's page and opens it there, unless no
window has that page. A pull request the list doesn't have anymore, such as a review that merged, stays as it was
last, with what the list had read of it, until you close it: it says so, and its menu loses the row's actions. The
list reads a pull request's threads and policies only while it's open, so one of yours that completes while its
details show, which stays under Done, keeps the threads, builds and checks they read last; for one that had closed
before, they say BriefBar reads those only while a pull request is open. Someone else signing in to the Azure CLI
closes it.

**Its Copilot session.** With **Send Work to Copilot** on, a line under the heading, in its details and on its page
over a work item's or another pull request's (`PullRequestDetailsContent`), names the Copilot session the pull
request's work goes to (`PullRequestSessionLine`), one for each pull request (`PullRequestSession`): the session you
chose for it, unless a task of BriefBar's started on it since, in whatever session; else its last task's, while its
worktree is there, even while Copilot still works in it, which then says it's busy; else the session of the work
item's task that opened it; else the Copilot app's session that the app records with it, that you linked to it in Show Links or
that's on its branch. Two of those that go with it as well as each other, neither with every reason the other has
and more, aren't ranked by which was active last: the line asks which is its, and goes on with the one you choose.
One whose log only has a link to it, and that was there before it was created, is a guess (`PullRequestSession.guess`),
which the line's menu offers and nothing picks; the logs are read for it only when no session goes with it, and what
they said is kept for a quarter of an hour. The sessions are those the Send to Copilot window lists
(`CopilotTasksStore.sessionChoices`), read the same way, off the main thread, and only while the window they're in
shows their page on screen, as for the code comments are on (`PullRequestSessions.setVisible`, from
`sectionVisibilityChanged`, with the window each view is in, `shownWindow`): as it does, then every ten seconds, so the
line follows the app's sessions as they start, end, open and close; once no window that shows them shows them on
screen, minimized, hidden or covered, or showing another pull request, what's being read or checked for them, such as a
search of the logs, is called off, and they're read again, with how work would reach their session, as one shows them
again. `--render` reads the sessions of the pull requests it draws once (`PullRequestSessions.prepare`), without the
search of the logs or how work would reach them, and its pictures' details follow nothing. The last eight it showed are
kept a while, to show at once as their details show again, until they're read again; and it follows BriefBar's tasks,
your choice and Show Links' links as they change. How work would reach the session
(`PullRequestSession.Delivery`), which its menu says first, is the way the window would send it unless you choose
otherwise, worked out as the window does: a task of BriefBar's with the Copilot CLI while it can go on with it
(`CopilotTasksStore.cliProblem`, without its git check, which the window still makes); the Copilot app's sessions, and
a task the app has open or the CLI can't go on with, in the app, where BriefBar's extension in the session sends it the
prompt, now or once the app loads it, or else BriefBar copies the prompt for you to paste there, as
`CopilotTasksStore.reach(of:)` says, which reads which sessions the extension listens in only while Send Prompts to
Copilot Sessions is on; or busy while a task of BriefBar's works in it or in its checkout. How it stands is what
Copilot's list says of it through Show Links, or what BriefBar follows of its own task, until that's done; then, while
Copilot's list says its session works or waits for you, as when you went on with it in the Copilot app, that
(`Links.describe(_:by:)`), which the task's own row in Show Links would hide. While it waits for your answer, the
line is orange, and opens the session in the Copilot app, where you answer it, as Copilot's list does; otherwise it
shows the session's page in the details, and it isn't under **Also Linked**. **Use for This Pull Request**, in its
menu, keeps your choice in the preferences (`ado.copilot.pullRequestSessions`), by references only, the pull
request's and the session's, never names, as Show Links keeps the links you make, and for as long
(`PullRequestSessionChoice`): what's older leaves the preferences as BriefBar reads them, a task that starts on the
pull request in another session forgets it, so clearing that task doesn't bring it back, and turning Azure DevOps off
forgets it. The Send to Copilot window goes there too, unless you choose otherwise
(`CopilotTasksStore.suggestedChoice`), following what you choose in the details while it's open, and so do agents
([below](#agents)). Without Send Work to Copilot, the line shows only the sessions Show Links links to
the pull request, read from nothing else, to look at; with neither, nothing. The demo makes its sessions up from its
own tasks and the Copilot demo's sessions that Show Links links, and reads nothing.

#### Its comment threads

Its threads go by file (`PullRequestPanel.Threads.openByFile`, `resolvedByFile`): those on the pull request itself
first, then each file's, as Azure DevOps' Files page lists them, folder by folder, each folder's folders before
its files, by name (`PullRequestPanel.listsFirst`). Files are told apart as Git tells them, by their paths' bytes
(`GitPath`): two whose names look the same, as "é" written in one character and in two, are two files, and two
names alike but for case, or for how their letters are written, go by their bytes. In each, those with a comment
that waits on you come first (as its row's events say, or said as the details showed it), then the other open
ones, from the top of the file down; the resolved ones are folded behind **Show Resolved**, by file the same way.
A thread says the lines it's on, its status as Azure DevOps names it, **Waits on you** when it does, and otherwise
who it waits on (`PullRequestPanel.Thread.waitingOn`): whom its latest comment asks, the first person, or team, it
mentions that BriefBar can name, else the pull request's author when someone else spoke last, else whoever else
spoke last; nobody once it's resolved, when only you spoke, when the latest comment asks only people BriefBar
can't name, and when it asks you, though it doesn't wait on you anymore, as when you removed it from Needs You:
then it's your turn, not someone else's. Each comment shows in full, its Markdown drawn by BriefBar
(`ReviewComment.markdown`, `RichText`, `RichTextView`), mentions as names, parsed again only when it changes, not
as the time beside it moves on (`CommentBody`); a thread of more than three shows its first and latest until you
ask for the rest.

#### Replying and setting a thread's status

With **Make Changes in Azure DevOps** on (`ado.makeChanges`, off by default: `MakeChangesSetting`), each thread on an
open pull request ends with **Reply** and its status (`ThreadReplyButtons`), in the row with Explain and Fix
(`ThreadCopilotActions`, which shows it without them too), in its details' comments and on its file's page, and its
right-click menu has them. An open pull request is one your lists have open now (`ThreadChanges.canChange`,
`CopilotSending.isOpen`), not only as its details last saw it, which keep one that left them as it was: on one that's
completed or abandoned, or that left your lists, a lock takes their place, which says why in its tooltip and to
VoiceOver (`ThreadReadOnlyMark`), and a change that finds it so says so on the thread (`ADOWriteProblem.notListed`,
`closed`) rather than nothing. They're the only changes BriefBar makes in Azure DevOps (`ADOWrite`, in
`Sources/AzureDevOpsCore`): your reply in a thread, a `POST` of a comment, in reply to the thread's first, with the body
Azure DevOps' samples send (`content`, `parentCommentId` and `commentType` 1, text), and a thread's status, a `PATCH` of
only that (`status`, by the number the API takes for it). `ADOClient.send(_:as:)` alone sends them, with a GET's
sign-in, headers and redirect guard, from the same request path, once: it sends one again only when Azure DevOps
rejected the sign-in, which it never acts on, so a change that fails otherwise, or times out, isn't made twice. When
Azure DevOps refuses one, the error says why, as it said it (`ADOError.refused`, TF401181 for a pull request that's
completed or abandoned), which shows on the thread but never goes to the log. Any answer from 200 to 299 says the change
was made, but 203, a sign-in page's: an empty 204 too, and one whose answer can't be read, which says so
(`ADOWrite.Answer.unreadable`), and the pull request is read again instead. A change called off before it goes, as when
the setting is turned off while it waits for a token, never goes. A 503, which Azure Front Door answers once Azure
DevOps takes too long, which may make the change all the same, counts as no answer in time
(`ADOWriteProblem.unanswered`): the thread is read again before it goes again; a 429 only asks it to slow down. And it
goes only as whom the list was read as when you clicked (`send(_:as:)`): when someone else signed in to the Azure CLI
since, as the list doesn't know yet, nothing goes, and the thread says so, with **Sign In…** (`ADOError.otherAccount`).
A token from your own directory says whom it's for. For an organization in another directory, whose tokens are a guest's
there, with an ID of their own that nothing in them ties to yours, the guest's token is read again, fresh, since one
kept from before someone else signed in may be theirs, and the Azure CLI gets every directory's for whom it's signed in
to now; then your own directory's sign-in, fresh, says who that is. `WriteTests` goes through every kind of change
(`ADOWrite.Kind`), and checks that nothing else in `AzureDevOpsCore` makes a request or sets a method but GET. Agents
(`--mcp`) and the command line get none of it, and the demo sends nothing: its changes are made up
(`DemoThreadChanges`), in its made-up data only, while it runs.

**Reply** opens a field under the thread, in place (`ThreadReplyComposer`), as a composer of Copilot's does, and it's
the details' one composer in place (`CopilotComposing.reply(to:)`): opening it closes Explain's or Fix's, and the other
way round, Esc closes it rather than the details (`InlineComposerOpen`), and it scrolls itself into view as it opens
(`detailsScroll`). It's Markdown, in a text view as tall as what's in it, from three lines to ten, where Return starts a
new line; **Reply**, or ⌘Return, sends it, and **Reply & Resolve**, or ⇧⌘Return, sends it then resolves the thread, or
**Reply & Reactivate** reactivates a resolved one, as Azure DevOps' own does. What you write is kept as you type
(`ThreadChanges.keep`), in memory only, for each thread, until it's sent: closing the field, or the details, keeps it,
and **Reply (Draft)** says so; turning the setting off, Azure DevOps stopping or someone else signing in to the Azure
CLI forgets it, and calls off the changes on their way (`ThreadChanges.forgetAll`): one that hasn't gone yet never does,
nothing says it failed, and one called off does nothing more as what it waited for comes back, though the setting is on
again and another change on its thread is under way. A reply goes as you wrote it, but for the lines that say nothing
before it and the spaces after it (`ThreadChanges.posted`): its first line's indent stays, which can make it code. After
a reply that may have gone, as one Azure DevOps didn't answer in time, the thread is read again before it's sent again,
by a read that starts then, never one under way before, and nothing goes until it was (`ADOWriteProblem.unconfirmed`): a
comment of yours that came since it was sent, and says the same as it would go, its first line's indent included, as
Azure DevOps keeps it, its mentions as their IDs, or as the details show it, is it, whatever came after it, so it isn't
sent twice (`ThreadChanges.Attempt`). **Resolve**, or **Reactivate** on a resolved thread, sets its status at once,
without asking, since the same menu sets it back (`ThreadStatusButton`); its **▾** has the statuses Azure DevOps' own
menu offers, Active, Pending, Resolved, Won't Fix and Closed, and By Design only for a thread that has it
(`ThreadStatus.choices`).

What Azure DevOps answers shows at once (`ThreadChange`, which `PRDetails.apply` applies once, however often): the list
applies it (`PRStore.changed`), so the details, Needs You, What's Left, the brief and the counts follow it, then the
engine does, and reads the pull request's details again, two requests, now (`PulseEngine.changed`, `readAgain`). A read
that started before the change, such as a refresh under way, doesn't undo it, even when it answers after the change's
own: its threads are left as they are, and its policies too, which a thread's status changes, such as one that wants
comments resolved, and the pull request is read again at the next refresh. So it is after a change that may have been
made, as one Azure DevOps didn't answer in time, or whose answer can't be read (`PulseEngine.mayHaveChanged`). The list
keeps the change over its refreshes until a snapshot has it (`PRStore.pending`), a status replacing one set before on
the thread, so that **Reactivate** after **Resolve** isn't undone by it. A thread you replied to doesn't wait on you, as
your last word is after the comment; one you resolved doesn't either, as the pull request is seen as you resolve it, and
its details, which keep what was new as it was when they showed it, leave out what was in it until then
(`ThreadChanges.waiting`). While the details show the pull request, a thread you change stays where it was as you first
did, with the open ones or the resolved ones, with those that wait on you or not, and among them, by when something was
last said in it then, though your reply is the latest now, however it stands now (`Threads.arranged(holding:)`), and on
its file's page, unfolded, where it was among the threads on its line (`Threads.comments(on:in:holding:)`), as you go
from one to the other and back, since the details keep them (`PullRequestDetailsContent`): so it doesn't move away as
you reply or resolve it, and the menu that sets it back is where you left it. A change that didn't happen says why on
the thread, in a sentence (`ADOWriteProblem`), with **Try Again**, **Reply…** or **Sign In…** when they may help, or,
for a reply, in its field, which stays open with what you wrote, and **Sign In…** when that's why; and a status set from
the card's menu while your reply is open says how it goes above it, and why it didn't: no permission, a pull request
that's completed or abandoned, a thread or pull request deleted meanwhile, offline, signed out, slowed down, or no
answer in time, after which the pull request is read again, since it may have been made.

**Fix Grammar**, in the field, corrects your reply's spelling, grammar and punctuation, and only those, in the language
it's written in, keeping its meaning, voice and Markdown (`GrammarFix`, in `Sources/BriefBarCore`): its code blocks,
fenced, found as Markdown closes them, in quotes too, or indented, as Markdown reads them, four columns past a list
item's indent in a list, and inline code, links and pictures, web addresses, with the parentheses they have, and
mentions, and characters that control how text reads, go to the model as markers, `{{1}}`, which it keeps, and are put
back as they were; an answer that lost, repeated or moved one is turned down. The model is told to proofread, with an
example, which Apple Intelligence corrects far more with, and gets the reply in a fence nothing in it closes, as what
someone wrote rather than what to do. Each line keeps the Markdown the reply had before what it says, such as a quote's
`>`, and the spaces after it, whatever the model did with them, and an answer that joined or split lines, kept fewer
than half of its words, or changed more than half of what it says, or 2,000 characters of a long one, what it held back
aside, as a translation or an answer to what it asks does, is turned down too (`GrammarFix.Failure.changedMore`): it's
checked off the main thread, as what it holds back is found, so the field and **Stop** answer meanwhile, and its work is
bounded, however long the reply. It shows the correction under the field, what it changes marked word by word
(`GrammarFix.changes`), a change to spaces on the word beside it, so that a correction never shows as nothing to
correct, with **Use It**, then **Undo**, while the reply is as it left it: it never changes your reply without you, nor
sends it, and the field waits while it runs, with **Stop**. It uses Apple Intelligence, on this Mac (`OnDeviceModel`),
unless you choose a Copilot model in its **▾**, from those summaries offer, which BriefBar keeps (`ado.grammar.model`):
then the Copilot CLI gets the reply, as a summary does, with no tools, in a session of its own, "BriefBar grammar fix"
(`CopilotSummarizer`), one premium request each time, which the field says. Where Apple Intelligence can't run, or is
turned off, it says so, and offers the Copilot models (`GrammarFixer`): what it can't do never goes to Copilot by
itself. The demo makes its corrections up (`GrammarFix.madeUp`), and runs no model.

`--render` draws, in the demo, Reply open, with Fix Grammar's suggestion, once used, with Apple Intelligence turned off
and with a Copilot model chosen; a reply and a status that couldn't be made; a pull request's threads read-only, as for
one that left your lists; then, from lists of their own with them made as the demo makes them, a thread replied to and
resolved, and one set to Won't Fix; and the setting, as Settings shows it (`ThreadChangesPreview`,
`threadChangeRenderings`).

#### A pull request's tags

A pull request's tags, which Azure DevOps calls its labels, show under its heading in its details
(`PullRequestTagsRow`), in the order of their names, ignoring letter case and numbers by their value (`PullRequestTag`).
The lists BriefBar reads anyway carry them, leaving them out of a pull request that has none (`ADOTagList`,
`PullRequestTag.listed`); a single pull request's read doesn't, so one your lists don't carry, such as one sent to you
or that you watch, has them read on their own, one request (`PulseEngine.readTags`), only while its details show on a
window's page on screen, as the code its comments are on is: as they come on screen, then ten minutes after they were
read, which details that stay on screen look at every half minute (`TagChanges.follow`, `isDue`); until then it shows
none. Its details keep a pull request that left your lists as it was then, as one sent to you in a chat that you're not
on once you've seen it, but for its tags, and when they were read, which follow the list's while it still reads it
(`PullRequestDetailsStore.followTags`), so those read as they show do. Azure DevOps stopping calls off the reads of tags
under way, as one that waits for the Azure CLI's sign-in, whose answer then does nothing, and nothing more is read or
changed (`TagChanges.stop`). When they were read is the engine's, on the record of each pull request the latest
refresh's lists didn't carry (`PRRecord.tagsReadAt`): a read of its own, or, for one that left its lists but stays, as
one sent to you, its lists' last; so turning the setting off and on, which forgets what was going on, doesn't hold it
up, and an organization whose lists couldn't be read keeps what they carried. The engine keeps each pull request's tags
with when the read they're from started, and a read that started earlier never replaces them, so a refresh under way
that answers after a change doesn't undo it, and a single pull request's read, which doesn't carry them, leaves them as
they were. They're on the pull request's record (`PRRecord.tags`), not on the pull request, so a change to them doesn't
make its pipelines or its details read again.

With **Make Changes in Azure DevOps** on, while the pull request is open in your lists as they are now
(`CopilotSending.isOpen`), not only as its details last saw it, and its tags are known (`TagChanges.canChange`), its
tags have ✕, and Add Tag opens a field that adds one, which is the details' one composer in place
(`CopilotComposing.tags`); otherwise the tag glyph's tooltip, and VoiceOver, say why they can't be changed. Adding one
is a `POST` of its name (`ADOWrite.addTag`); taking one off, a `DELETE` of it, by the project's tag's ID, so a name with
a slash in it is no trouble, with no body (`ADOWrite.removeTag`), whose answer, whether nothing (204), an empty 200 or
JSON, says it's done. What Azure DevOps answers shows at once, the tag as the project spells it, and the engine keeps
it, over any read that started before, then reads the tags again, one request, for anyone else's change meanwhile, in a
task that turning Azure DevOps off calls off, counted as a read of them (`PRStore.changedTags`,
`readTags(afterChanging:to:)`, `PulseEngine.changedTags`); the list keeps the change over a snapshot read before it,
which has the tags as they were, until one has it, or has tags changed since (`PRStore.pending`). A tag the pull request
has already, ignoring letter case, isn't sent. Nothing asks first: after a tag is taken off, **Undo** adds it back, by
its name (`TagChanges.removed`, `undoRemoval`), until the tags change again, you dismiss it, or nothing shows the pull
request, and, for good, once they have it again, as when someone else added it back (`TagChanges.undoable`,
`forgetRestored`); a removal that Azure DevOps answers after nothing shows the pull request anymore offers none. A
change that didn't happen says why under the tags (`ADOWriteProblem`), with **Try Again**, but not when Azure DevOps
refused it, the pull request is closed or the tag isn't there, which trying again can't help, and **Sign In…** when
that's why. One clicked as the pull request was completed or abandoned, or left your lists, goes nowhere and says so, as
a thread's does (`closed`, `notListed`), and what the tags say stays once they can't be changed, with nothing to try
again; when it may have happened all the same, as when Azure DevOps didn't answer in time, or Azure Front Door answered
503 once it took too long, the tags are read again, and, when they can't be yet, as nothing goes out for a while after a
503, as soon as they can be while its details show, half a minute after the read that couldn't, which one that started
before it doesn't cut short, and only by one that started since the change (`TagChanges.readAgain`, `unsure`); one taken
off that Azure DevOps says isn't there is, when the tags read again don't have it, as you wanted. Each change goes in a
task kept by pull request, which turning the setting off, Azure DevOps stopping or someone else signing in calls off
(`TagChanges.forgetAll`): one that hasn't gone, as while it waits for a token, never does, and one called off does
nothing more, though the setting is on again; as the setting goes off, the tags of a pull request whose change it called
off are read again, as it may have gone all the same. It goes only as whom the list was read as when you clicked
(`ADOClient.send(_:as:)`): when someone else signed in to the Azure CLI since, nothing goes, and the tags say so, with
**Sign In…**.

As you type, the field suggests (`TagChoices`) the tags you added in the pull request's project, the latest first, then
those on the pull requests BriefBar read there, the most used first, then by name, but the pull request's own, six at
most: the one that's what you typed, then those whose names start with it, then those with a word that does, then those
that have it anywhere, ignoring letter case; what you typed, when it's none of them nor one the pull request has, is a
new tag, last. The best match is chosen as you type, and with something typed one always is, so Return always adds a row
that shows, but for a tag the pull request has already, when none is and the field says so; as the tags are read again
while the field is open, the same row stays chosen, where it's still offered, or else the best match, and none once the
pull request has the tag typed, as when someone else added it (`TagChoices.chosen`). VoiceOver hears which, and how many
there are, as it changes, and when the pull request has the tag typed. ↑ and ↓ choose another; Tab completes the one
chosen in the field, sending nothing, and moves on, as it does anywhere, when there's nothing to complete; Return adds
it; and Esc closes the field (`InlineComposerOpen`). BriefBar remembers the tags you add, by their names, up to 20 for
each project, by its organization and ID, for the 20 projects you added tags in last (`UsedTags`, `ado.usedTags`), until
you turn the setting off or delete Azure DevOps' saved data. It doesn't read Azure DevOps' own list of a project's tags
(`_apis/wit/tags`), which work items share and which can hold many thousands, far more than one request reads in time.
The demo's pull requests have made-up tags (`DemoTags`), and its changes are made up too, in its data only, while it
runs.

`--render` draws, in the demo, the first of your pull requests that needs you with its tags; the field open with what you
typed and its suggestions; a change that couldn't be made; and the tags without the setting (`TagsPreview`,
`tagRenderings`).

#### The code comments are on

A thread on lines of a file shows the code it's on, as its reviewer saw it: in the diff it was made on
(`ThreadCode.span`), before Azure DevOps followed it to later ones, with three lines before and after, the lines
it's on marked, and the removed and added lines among them (`ThreadExcerpt`). `PullRequestCode` reads it, one
reader for each pull request whose details show, with GETs, four at a time: the pull request's updates, the files
the diff it was made on changed, and its file before and after that change, by their object IDs, up to 1 MB each,
each read once for every thread on it, which it compares a line at a time (`LineDiff`): with the fewest lines
removed and added, as Myers' algorithm finds them, up to 2,000 of them; past that, as for a file that changed in
many places, it lines the two versions up at the lines each has only once, as many of those as come in the same
order in both, as a patience diff does, and between those looks for the fewest again (`LineDiff.Comparison`,
`isLinedUp`). And whether the file changed since, from the diff of that update with the latest. `PullRequestCodeStore` asks for a thread's code only
once it comes on screen, as the details scroll, after a moment, so a thread scrolled past isn't read; it calls the
read off when the thread leaves the screen first, once no other view shows it, such as the same pull request's
details in another window. It reads a thread's code only while the window it's in shows its page on screen, the
Pull Requests page or the Sprint page (`sectionVisibilityChanged`, with the window each view is in,
`shownWindow`): once that window is minimized, hidden or covered, what only its threads asked for is called off,
whatever other windows show, and read once it shows them again. What's read is kept in memory only, while
something shows that pull request's details: the panel beside the list, pages over it included, or a page of it
elsewhere, which holds it while it shows (`hold`); once nothing does, it's forgotten. Each pull request's threads
are its own, as Azure DevOps numbers each pull request's threads from 1: one that fades away as the details move
to another doesn't touch the next one's thread of the same number. A thread is read again only on screen, after a
push or a move to another target branch, or when Azure DevOps followed it to other lines; until that's read, it
shows the code it showed. A read that failed in a way reading again may fix, offline, throttled or signed out, is
tried again when the thread comes on screen half a minute later, or at once with **↻**, and so is code read
without whether it changed since, which couldn't be read: it shows meanwhile, and since what was read of it is
kept, reading it again is one request at most; one that can't be read, such as a file that isn't text, longer than
1 MB, or that Azure DevOps doesn't have, says why in a few words (`ThreadCode.sentence`), with ↗ to the thread.

`CodeView` draws code, for the threads and, later, whole files: AppKit's text system, so each row is as tall as
the others, its text selectable across rows and copied without the numbers, and only the rows on screen drawn.
VoiceOver reads it a row at a time from its gutter, a list of its rows, each saying its numbers, how the change
left it, whether the comment is on it, and its text, "Line 88, added, commented: delay *= 2;"
(`ThreadCode.spoken`), then the text, as it's copied, to select. Its gutter numbers each line after the change,
and before it too when lines were removed or the thread is on the code before the change; added lines are green
with +, removed ones red with −, the lines a thread is on in the accent color with a bar, and lines left out in a
run of removed or added ones are a row that says how many (`ThreadCode.rows`). It drops the indentation every line
shares (`ThreadCode.outdented`), tells rows apart by their text's bytes, as the diff does, follows the text size
on windows' pages, and scrolls sideways a gesture that starts sideways, leaving up and down to the details. While
the details are beside the list, **⟷** makes them wide enough for a thread's longest line (`DetailsWidening`).
When the file changed after the comment, it says so, or that it may have, when that couldn't be read though the
pull request changed since, with ↗ to the pull request's Files page at that file, from the update the comment was
made on to the latest (`PRSnapshot.filePageURL`).

#### Its files

Under its comments, the details list the files the pull request's change touched (`PullRequestFilesSection`), read
as they come on screen (`PullRequestFilesStore`): all of the change, the latest update's diff with the base, as Azure
DevOps' Files page shows it, or, once you've looked at the pull request before (`SeenState.seenAt`, as the details
had it before they showed it, `PullRequestDetailsStore.lastLooked`) and an update came after, what changed since the
update you'd seen (`ChangedFiles.lastSeenUpdate`, `ChangeScope`). `PullRequestCode` reads them
(`changedFiles(of:scope:)`), through the same reader as the threads' code, so what one reads the other doesn't read
again, and with the same rules: only for a view in a window that shows its page on screen, called off once none
does, and forgotten once nothing shows the pull request. They go by folder, as the Files page lists them
(`ChangedFiles.folders`, `PullRequestPanel.listsFirst`), a folder whose only content is another folder named with it,
`src/Payments/Retry`, grouped once with the list; each says what happened to it (`FileChange.what`), how many lines
it adds and removes, and how many threads are on it (`PullRequestPanel.Threads.comments(in:)`, for all of them at
once): those Azure DevOps tracks on it, though another file took the path they name, or else, when none of the
change's files has their tracking ID, those on its path, after the change or before it; the open ones counted first,
"1 open comment, waiting on you, and 2 resolved". A file's lines are counted
(`LineCounts`) as its row comes on screen, one file at a time, in the order the rows came, by comparing its two
versions (`PullRequestCode.diff(of:in:of:)`), each read once, by its object ID, up to 1 MB; a row that leaves the
screen before its turn isn't counted, and a file that isn't text, or is longer, says so; a row on screen asks again
every half minute, for a count that failed in a way that may pass. What's counted is kept, by the versions it
compares, for as long as the pull request is: the same file changed the same way, in all of the change and since an
update, is counted once. A file that changed in more places than the diff lines up exactly, as a lock file of
packages can, is counted as it's lined up, and says that's about right (`FileDiff.isLinedUp`,
`LineCounts.isApproximate`), "~+1249 −1249". Their lines are added up once each file is counted, but for those
that aren't text, and not while one that is text can't be (`PullRequestFilesStore.totals(of:in:)`); about right when
one is.

A file opens in place of the details' parts (`PullRequestFilePage`, `PullRequestDetailsStore.file`), the header's
trail saying so, `!4102 › PaymentsClient.cs`, or `Bug 5110 › !4091 › Rounding.cs` on a pull request's page over a
work item's details; **‹**, **⌘[** or Esc go back to the details, at its row (`Place.file`), or their Files once no
row is its, as after a push took it out of the change, or at the thread it
opened from in their comments, whose file's heading, or its menu, opens it at that thread (`ChangedFileOpener`): in
all of the change, which has it whatever the Files show (`OpenFile.scope`), and on the file Azure DevOps tracks it on
(`ChangedFiles.file(of:)`), though another file took the path it names since; and it follows the file it shows
to the path a push moved it to (`PullRequestDetailsStore.follow(file:)`). Its
diff is the two versions compared a line at a time (`LineDiff`), its changes with three lines around each, and all
the lines its threads are on with three around them, the rest folded, to unfold twenty lines at a time, up from the
code below a fold or down from the code above it, or all of it (`DiffLayout`). A thread shows under the line it ends on
(`FileDiff.row(of:in:)`): where Azure DevOps followed it to, or else where it was made, when that's the version the
diff shows after the change, or, before it, the same diff; its lines on that side marked in the accent color
(`FileDiff.markedRows(of:in:)`). Those on the whole
file, and those on lines of a version it doesn't show, as one made on an earlier update that Azure DevOps didn't follow
since, show above it, the latter with the code they were made on, as in the comments, as do all its threads when its
diff can't show; resolved ones fold to a line. A file that changed in more places than the diff lines up exactly says
so above its diff. Its code is drawn by `CodeView`, two hundred lines to a view in a lazy stack, so that only those on screen are laid
out, each with room for the file's longest number, so the code lines up from one part to the next. **‹** and **›**,
or ⌥⌘↑ and ⌥⌘↓, go to the files before and after it, and ⌃⌘↑ and ⌃⌘↓ through its open threads, as it shows them,
then on to another file's (`PullRequestPanel.Threads.openOnFiles(of:)`), at its first or last as that one's page shows
them once its diff shows, or can't (`OpenFile.comment`): from a toolbar that's the lazy stack's pinned header, so it
stays at the top as the diff scrolls. While the details are beside the list, **⤢** asks the page for all of it
(`DetailsFillsPageKey`): the details then cover the list, as in a narrow window, without being made again, so nothing
in them starts over, until the file's page goes or **⤡**; the details remember it for their files' pages until they
close. A diff is read as the page shows it, asked for again every half minute while it shows, for one that failed in a
way that may pass, and called off as it goes before it's read; the last few read are kept, besides those that show. ↗
opens the file on the pull request's Files page, with what that change changed in it (`ChangedFiles.filePageURL`).

#### Its builds

One of a pull request's builds that failed, or is still running or queued, opens under its row with a click, or Space
(`PullRequestPanel.CheckLine.canInvestigate`); one that passed, expired or hasn't run, a status check, and the
pipelines after a merge, which built the target branch rather than the pull request, don't. A place in the details
opens its build too, by its run: **Build failed** in What's Left leads to the first required build that failed and can
be opened (`PullRequestPanel.build(openedBy:)`); a run on the Pipelines page leads to that run; and a failing pull
request opened from elsewhere leads to the first of its builds and checks that failed (`Place.about`), which opens
when it's a build. What's Left's other items about builds and checks, such as **Build passed**, only scroll to them.
Only then is its run read (`BuildInvestigationStore`, through `BuildInvestigator` and `BuildInvestigationReader`),
with the requests in the table above: its run first, then, at once, its timeline, its logs, its test runs, the
pipeline's runs on the pull request and its latest finished ones on the target
branch, then the end of the failed step's log and the failed tests of its first test runs with failures: ten
requests, and one more for each hundred test runs past the first hundred, up to five hundred. What was read is
kept in memory, by run, for the last twenty runs opened, until someone else signs in to the Azure CLI or Azure
DevOps is turned off, which stops the reads under way too, even those it let go of when someone else signed in
(`BuildInvestigator.stop`). It's used for ten minutes, or half a minute while the run is still going, unless its check
says the run got further since, as when it started or finished (`PipelineRun.Phase`): opening it again, which always
asks the investigator, within that time reads only the run, to tell whether it ran again since, which reads it all
again, or nothing while it's going; what was read before shows meanwhile, for the builds still open and the last five
that folded. Something that couldn't be read isn't kept, and says so, and a run that's gone, or that you can't read
any more, lets go of what was read of it, as does one that ran again since, as a look at it or its check says, when it
can't be read again (`BuildInvestigator.RunReplaced`); **Read Again**, beside when it was read, reads it anew. So does
a change of its check, as the list reads it, such as a run that finished or runs again under the same ID; and a push
or a retarget of its pull request asks the investigator again, which says again whether the run built the latest
commit, or reads it for the new target branch: at once while it's open, or as it opens again
(`BuildInvestigationStore.Stamp`). The investigator shares a read under way with whoever asks for the run meanwhile,
even to read it anew, so a read asked for then waits for it, and starts after, unless what's being read is what's
asked for by then, as when a pull request is retargeted and back; one that comes back with the run not as far along as
its check says by then, as when it finished meanwhile, is read again, once; and one that had read the run before they
asked, and found it finished, is checked with a look at the run, which reads it again if it ran again since. Only one
pull request's builds are open at a time, wherever its details show, beside the list or as a page over a work item's
or another pull request's: opening one of another's folds them, and so do the details beside the list showing another
pull request, or closing, for the one they showed; what shows of them goes, and so does what shows of a run its builds
and checks don't list any more, such as one a newer run replaced. It shows, from what was read
(`BuildInvestigationPanel.swift`): its stages, as the Pipelines page draws them (`StageFlow`); where it failed, from
its stage to its task, without a name said twice in a row (`failurePlace`), or what it does while it's going
(`progress`); whether it's the change's doing, the comparison's hints (`BuildHint`), each a sentence in its state's
color, orange for an older commit or a pass on the same commit before, red when the target branch fails too, green
when it passes, each but the first opening the run it names, and "may be flaky" only for a pass on the very same
commit; while Send Work to Copilot is on, what Copilot does about it, and **✨ Explain the Failure** and **Fix** for one
that failed ([About a failed build](#about-a-failed-build)); **Open Run**, and when it was read; its errors, each with where it is, unless its
message starts with that very place, as a compiler writes it, its code, unless its message names it, and its step,
unless it's the one that failed; how its tests went (`BuildTests.summary`), which, when they couldn't all be read,
says how many failed at least, or that no failures are known rather than that none failed, and the first that failed,
each with its class, how long it ran, its message, its first six lines with **Show More** for the rest, and, when you
ask, its stack trace, with **Open Tests**; and the last 20 lines of the failed step's log, numbered, errors red,
warnings orange and commands blue, in one text you can select across and scroll sideways, all 200 that were read with
**Show All**, and **Open Log** for the rest.

#### Its merge conflicts

While Azure DevOps says a pull request has merge conflicts (its `mergeStatus`, `PullRequest.hasConflicts`), and it's
open, its details list them under **What's Left** (`PullRequestConflictsSection`), whose **Merge conflicts** leads there
(`PullRequestPanel.Section.conflicts`, `Place.of`), as does the bar of fixes ready to push for the conflicts Copilot
resolved; once it has none, they go, and a place there goes to the details' top. Which files conflict, and how, is read
with one GET (`MergeConflicts.read`, the preview API `pullRequests/{id}/conflicts`), a page of a hundred, more only
for more, up to ten pages, stopping at a page that brings nothing new, as from a server that answers with the same page
whatever it's asked, those it doesn't number told apart by their paths, byte for byte, as Git tells paths apart
(`GitPath`). Past ten full pages, or after a full page that brought nothing new, there may be more: the details then
say at least how many files conflict, and the prompts that there may be more (`MergeConflicts.isComplete`). They're read
as the details show it in a window that shows its page on screen, as for the code comments are on
(`PullRequestConflictsStore`, which reads only as `PullRequestCodeStore` lets the details read), and again once
its branch or its target moves (`PullRequestFilesStore.Head`). Once that window is minimized, hidden or covered, a read
under way that only it asked for is called off, to be read when it shows them again. What's read is kept in memory
only, while something shows that pull request, and forgotten once nothing does, or someone else signs in to the Azure
CLI. A read that failed in a way reading again may fix, offline, throttled or signed out, is tried again half a minute
later while they show, or at once with **↻**; one Azure DevOps doesn't have, or you can't read, says so. Each file says
what each branch did to it (`MergeConflict.how`), from the type of conflict Azure DevOps names, by name or by number:
**Changed on both branches** (`editEdit`), **Added on both branches** (`addAdd`), **Changed on rename-order-status,
deleted on main** (`editDelete`) and the other way round (`deleteEdit`), and the renames, with the other path each
branch gave the file, by its name in the same folder, folders compared byte for byte, or else from the top of the
repository: **Renamed to
order-statuses.md on rename-order-status, and to docs/orders/states.md on main** (`rename1to2`), and so on; one someone
resolved in Azure DevOps, which hasn't committed the merge yet, says so. They're in the order a change lists its files
(`PullRequestPanel.listsFirst`). A click opens what the pull request changed in the file, its page in the details, at
the path the pull request has it at (`pathInPullRequest`), as from **Files**, and back comes back to them; a folder on
the pull request's branch, where the target has a file (`directoryFile`), has no changes of its own, and a file in a
folder that's a file on the other branch (`directoryChild`) may be on the target's side alone, so they open the pull
request's files in Azure DevOps there instead, with **↗** in place of **›** (`showsInAzureDevOps`). **↗** opens
the pull request in Azure DevOps, where they can be resolved.

With Send Work to Copilot on, what Copilot does about them shows under them, as on a thread (`CopilotWork`, for
`PullRequestPart.conflicts`), with **✨ Explain** and, on your own pull request, **Resolve**, which open the composer in
place ([below](#about-its-conflicts)).

### What counts as new

Azure DevOps has no read or unread state for pull requests, so BriefBar keeps its own
(`SeenState`): activity up to a pull request's cutoff counts as seen. The cutoff is when you last
opened the pull request from BriefBar, or showed its details in the window (or clicked **Mark as
Seen**), or, if that's earlier, three days before BriefBar first ran. Each account you sign in to the
Azure CLI with has its own, since two accounts can see the same pull request: switching back to an
account picks up where it left off, and nothing from the other account is announced.

After the cutoff, these need you:

- a comment by someone else (not a build service or bot) in a thread you've commented in, after your
  last comment there: a **reply**;
- a comment that @mentions you: a **mention**;
- on your pull request, a comment by someone else in a thread you haven't joined: a **comment**;
- a reviewer's "waiting for author" or "rejected" vote on your pull request, while it still stands
  and you haven't pushed since;
- on a pull request you review: being added as a reviewer (or the draft being published) when you
  haven't voted yet, and new commits since your vote.

Approvals are news too: they're announced, but they don't need you.

### What still waits on you

Seeing a comment doesn't answer it. A **reply**, **mention** or **comment** that needed you keeps the
pull request in **Needs You** once you've seen it, for as long as it waits on you: its thread is still
active (or pending), and you haven't commented in it since. The list marks only what's new, with a dot,
and says "3 replies" rather than "3 new replies" once you've seen them; what's new names the reason when
there's both. It's counted in the menu bar like the rest of Needs You, but never announced again, nor
in **Answered** when you then answer it: the pull request just goes back to its usual group.

It stops waiting on you when:

- you reply in its thread, or the thread is resolved (fixed, won't fix, closed or by design);
- you choose **Remove from Needs You** in the pull request's menu (right-click it, or **Actions** in the
  window), or a task that takes care of its comments, **Fix Comments** or **Push & Reply**, starts in
  Copilot. Each pull request has a second cutoff for this (`SeenState.dismissedAt`), which sees it too:
  for **Remove from Needs You**, the newest thing the list showed; for Copilot, the last comment that
  waited on you in the threads whose entries are still in the prompt you send, as they were when
  BriefBar wrote it, opening the composer (`CommentHandOff`). An entry is still there while its own line
  is, such as `1. src/Cart.cs, line 12 (thread 11)`: the prompt quotes comments word for word, each on
  an indented line, so one that names another thread doesn't count, and neither does a line in a fence,
  such as one of a suggested change or of an earlier answer (`PullRequestPrompt.unfencedLines`). A comment that came after, while you
  checked the prompt, say, isn't handed off, and neither is one in a thread whose entry isn't there,
  beyond the 30 it lists at most or deleted before you sent it, nor one in a thread reopened meanwhile.
  Since there's one cutoff, it then stops before the first comment that waits on you when the task
  starts, as BriefBar last read the pull request, and wasn't handed off: one in a thread answered or
  resolved meanwhile doesn't hold it back. If BriefBar doesn't have the pull request then, it goes by
  the prompt as it was written. They leave the Needs You of the account signed in to the Azure CLI when
  the prompt was written, even if another has signed in since: that account's seen state keeps it for
  when it signs in again. What comes after needs you again, as new;
- the pull request has had no activity for as long as **Idle After No Activity For** says (two weeks
  by default): it's idle, as it would be otherwise. Something new still needs you.

The rest don't wait like that once you've seen them: a review request is in **To Review**, new commits
and a vote that wants changes leave the pull request in its usual group, and a link someone sent you
stops needing you. So **Mark as Seen** sees everything in Needs You, but keeps the comments that wait on
you there. A comment from before the three days before BriefBar first ran never needs you. What you
take off Needs You is kept as what you've seen is: in the preferences, with each account, except for
pull requests listed only because someone sent them to you, kept in memory only. It's forgotten with
when you last looked at the pull request, never before (`SeenState.pruned`): once it's no longer listed
and you last looked at it two months ago or more.

### Answered

Each of those can also be answered in Azure DevOps (`PRClassifier.answers`): a reply or mention by
your comment after it in the same thread (on your pull request, any comment); a review request by
your vote; new commits since your vote by voting again; a vote that wanted changes on your pull
request by your push; and a link someone sent you by your vote, your comment or, on your pull
request, your push. Voting on a pull request you weren't asked to review adds you as a reviewer
yourself, which doesn't count as a request.

When something that needed you after the cutoff has been answered in the last day, the pull request
is in **Answered**, with what you did ("You approved") and what it answered ("Dana Whitfield sent
this in Teams"), unless it's failing, ready to complete or to review. It isn't counted in the menu
bar, announced, or in the brief. Once no popover or window page shows the pull requests anymore,
each pull request one of them showed in Answered is marked seen up to when you answered it, not up to
the time it closed, so anything that came later still counts as new. Widgets don't count as seeing it.

### Watching a pull request

**Watch a Pull Request…** takes a pull request's link, and keeps it, as a link, in the preferences
(`ado.watchedPullRequests`): it's your choice, like your organizations. BriefBar reads it by its ID with
the pull requests sent in chats, and its details as it does every pull request's. One you're not on is
listed as a review, under **To Review** as **Watching** (`PRRecord.watched()`), with its replies and
mentions; one you are on is listed as it is. What you've seen of it is kept in the preferences, as for
your own. Once it's completed or abandoned, or can't be found or read anymore, BriefBar stops watching
it (`PulseSnapshot.closedLinks`); a failure that may pass doesn't count. The command line lists the ones
the app watches too. Azure DevOps ignores the letter case of an organization's name, and so does BriefBar
(`PRKey`, `SeenState.name(of:)`): a link that spells it differently is to the pull request in your lists,
listed once, as one you watch, and what you've seen of it is the same however it's spelled.

### Pipelines after your merges

When a pull request of yours completes, Azure DevOps reports the commit that merged it
(`lastMergeCommit`). For as long as Done keeps the pull request (**Keep Done For**), BriefBar follows
the runs of the pipelines that build it: its target branch's runs on that commit, except scheduled
ones, which only happened to pick it up; the runs those started through a pipeline-completion or
resource trigger, such as a deployment; and so on. It looks for them every refresh for half an hour
after the merge, since a batched CI can wait before it starts, while one of them hasn't finished, and
for a quarter of an hour after the last one did, in case it starts another; then it stops. Each
pipeline's latest run counts: a run retried, or queued again, replaces the one before. While a run
runs, its timeline is read every refresh, for its stages and whether one waits for an approval or a
check, and once more when it finishes, for where it failed (`MergeChain`, `MergeSummary`).

Together they decide what the pull request's row says:

- **Failing**, as **Failed after merge**, when a pipeline's latest run failed, with where and its first
  error; the row and its notification open the run.
- **Waiting for approval**, in Done, while a stage of one waits for an approval or a check.
- In Done, how many are still running, and then that they passed, or, when one was canceled and none
  failed, that it was: "its pipeline was canceled", or which one, such as "“shop-web CD” was canceled".

While they run or wait, the pull request stays in Done even once you've opened it; once they've all
finished, passed or canceled, it leaves Done as before, when you've seen it. A notification says when one
fails, when one starts waiting for an approval, and when they've all finished after running: that they
passed, or that one was canceled, which opens that run. What happened before BriefBar started isn't
announced. The Pipelines page lists them under **After Your Merges**, above the pipelines you pin.
**Follow Pipelines After You Merge** turns it off, and BriefBar then forgets the runs it found.

### Pull requests sent in chats

When you turn on **Pull Requests Sent in Chats**, BriefBar reads Notification Center's database,
`~/Library/Group Containers/group.com.apple.usernoted/db2/db`, which keeps the notifications every app
has posted (about the latest hundred per app; for Teams, a couple of days). It's off by default, and
from a menu, turning it on opens its Settings page, which says what it reads.

- It reads through `NotificationCenterDB`, the reader Teams uses, asking for every app's
  notifications rather than one app's. It opens the database with a read-only SQLite connection, for
  a short read each time, and never changes it. Like any SQLite reader, it takes brief shared locks
  and updates SQLite's shared-memory index (`db-shm`) while it reads; neither changes any
  notification. It reads it when you turn the setting on, whenever the database's write-ahead log
  changes (watched with kqueue, so a new message shows within a second), when you open the pull
  requests, and once a minute.
- Each notification's title, subtitle and text are searched for links to pull requests:
  `dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id}` and the older
  `{org}.visualstudio.com/…/pullrequest/{id}`.
- In Teams, only chat messages count: the notification has a reply box and names a chat. Channel
  posts and reactions don't. The sender is the title in a 1:1 chat and comes before the colon in a
  group chat. In other apps, the title is taken as the sender.
- Emails from Azure DevOps itself, and BriefBar's and ADO Pulse's own notifications, are skipped.
- It keeps only the link, the app, the sender, the time and, for Teams, the chat and message IDs (to
  open the message). Never the message itself. Links are kept in memory only, for at most two weeks,
  and forgotten when you turn the setting off, or Azure DevOps. So is what you've seen of the pull
  requests listed only because of a link, and what you've taken off Needs You there. None of it goes to
  BriefBar's preferences or to disk, where any program running as you could read it: only what you've
  seen of your own pull requests, and taken off Needs You, is in the preferences. Builds from before the
  first release did keep the links there (`ado.chatLinks`), so at
  launch BriefBar removes them. What those builds saved of which of those pull requests you'd seen
  leaves the preferences once they're listed again, and otherwise two months after you last saw
  them, as for any pull request no longer listed.
- So after BriefBar restarts, it finds again only the links whose notifications Notification Center
  still has (for Teams, about a couple of days' worth), and a pull request you'd seen, but not voted
  or commented on since the message, needs you again.
- The command line never has them: Azure DevOps' part of `--dump`, `--json` and `--watch` leaves out
  pull requests sent in chats, and `--chats` lists the links that Notification Center has, with the
  Full Disk Access of whoever runs it.
- Only the app itself is given Notification Center for them (`ChatReading` in `AzureDevOpsUI`). What
  the pull requests' store reads it through is inert unless the app passes it, so `--render`, the
  demo and the tests read nothing there, and ask for no Full Disk Access for it, even with the
  setting on. The log says when BriefBar starts and stops looking, and how many links it found only
  as private data.

A pull request that isn't in your lists (you're not its author or a reviewer) is read with a GET by
its ID, and listed only while the link needs you. A link needs you until you open the pull request
from BriefBar, vote or comment on it after the message (or push to it, if it's yours), it closes,
or a week passes. Once you've voted or commented, it's in **Answered** until you've seen that.
Links aren't announced: the app they came in already did. Right-click one to open the message in
Teams, or to bring the app it came in forward.

macOS protects that database, so this needs Full Disk Access: the same access Teams uses, granted
once to all of BriefBar. Azure DevOps registers for it only while the setting is on, and the
window that walks you through it opens when you turn the setting on without it. `--demo` never
reads Notification Center: its links are made up. `BRIEFBAR_CHAT_LINKS_DB` points it at a copy of
the database instead, which needs no access. How the access survives rebuilds and updates is in
[Signing](#signing).

### Your sprint and pipelines

The Sprint and Pipelines sections read Azure DevOps only while something shows them on screen: a
window's page while the window is open, not minimized and not hidden behind other windows; a widget
that isn't covered by windows; a menu-bar item that shows them, or its list. Each of those tells the
source when it starts and stops showing a section (`sectionVisibilityChanged`). Then they refresh as
often as the pull requests (the **Refresh** setting), and right away when they come on screen with data
more than half a refresh old. A refresh under way when they go off screen stops before its next request.
They back off when Azure DevOps can't be read, and honor `Retry-After`, like the pull requests, with the
same client and sign-in; when you sign in to the Azure CLI as someone else, they start over with what
that account can read. They start in windows only, hidden in the menu bar and in widgets. All GETs:

| Request | When | Provides |
|---|---|---|
| `_apis/teams?$mine=true` | every six hours while the sprint shows | your teams, in every project |
| `{project}/{team}/_apis/work/teamsettings/iterations?$timeframe=current` | every hour, and once per team to find one with a sprint today | the team's current sprint and its dates |
| `{project}/{team}/_apis/work/backlogconfiguration` | once per team | which work item types are tasks, and each state's category |
| `{project}/{team}/_apis/work/teamsettings/iterations/{id}/workitems` | every refresh | the sprint's work items, and which task is under which story or bug |
| `_apis/wit/workitems?ids=…&fields=…` | every refresh, 200 work items a request | their type, title, state, who has them, hours left and backlog order |
| `_apis/wit/workitems/{id}?$expand=relations` | when you open a work item's details, unless they were read less than a minute ago; and again when the sprint shows it changed while they show | all its fields, its links, attachments and web pages, and which of its long text fields are Markdown |
| `{project}/_apis/wit/workItems/{id}/comments?$top=50&order=desc&$expand=renderedText` | with it | its latest 50 comments, as written and as HTML, and how many it has |
| `_apis/wit/workitems?ids=…&fields=…` | with it, for a work item that links to others: one request, for up to 200 | what the work items it links to are, and where they stand |
| `{project}/_apis/build/builds?definitions=…&maxBuildsPerDefinition=12` | every refresh: one per project (and branch) for all its pinned pipelines | their recent runs |
| `{project}/_apis/build/builds?repositoryId=…&branchName=refs/pull/{id}/merge` | every refresh while pipelines are visible: one per active PR you authored | its latest validation runs, up to 200 |
| `{project}/_apis/build/builds/{id}/timeline` | every refresh for a latest run in progress, once when it finishes (again if it's retried); up to six a refresh | its stages, and where it failed |
| `{project}/_apis/build/definitions?name=*…*` | when you search in **Add Pipeline** | pipelines to pin |
| `{project}/_apis/build/definitions?definitionIds=…` | when you search for a number in **Add Pipeline**, alongside the name search | the pipeline with that number, first |
| `{project}/_apis/build/definitions/{id}`, `{project}/_apis/build/builds/{id}` | when you paste a link to a pipeline, or to a run, in **Add Pipeline** | the pipeline it's to, and a run's branch |
| `_apis/projects` | when you open **Add Pipeline** | the projects to search in |

**Which sprint.** The first time, BriefBar looks through your teams (up to 25) for one with a sprint
going on today, and when several have one, picks the team with the most work assigned to you. It
keeps that team until you choose another. Organizations whose teams couldn't be read are named beside
the sprint, with why, so the team picker's gaps are explained. Azure DevOps keeps calling a team's last sprint "current"
after it's over, when the team stops planning sprints, so a sprint counts only while today is one of
its days: its first and last days are dates, which Azure DevOps keeps in UTC, and today is the day
it is on your Mac.

**The board.** The sprint's work items come with their hierarchy: each story or bug, with the tasks
under it. Which types are tasks comes from the team's settings (a team can track bugs as tasks),
and each state's category (to do, in progress, resolved, done or removed) too, whatever the process
calls its states; without them, Task is the task type and the categories are guessed from the
states' names. Removed work items aren't shown. Stories and bugs are in backlog order, in **In
Progress** when they're in progress or any of their tasks has started or is done (stories aren't
always moved along), **Not Started** otherwise, and **Done** once they're done. Tasks whose story
isn't in the sprint are together in a card of their own. **Just Mine** keeps your stories and bugs,
with all their tasks, and your tasks under anyone else's. Your work, in the summary, the sidebar, the
widget and the menu bar, is your tasks, and your stories and bugs without tasks, that aren't done.

**A work item's details.** A click on a story, bug or task shows its details beside the board, or over
it when the page is narrower than 700 points (`WorkItemDetailsStore`, `WorkItemDetailsPanel`): what
the sprint knows of it at once, then what's read of it (`WorkItemDetailsReader`). Beside the board,
they're 40% of the page, from 330 to 480 points, until you drag their left edge
(`DetailsLayout`): then they're as wide as you made them, from 330 points to as wide as
leaves the board the room it has on a 700-point page, and the width is kept in the preferences
(`ado.sprintDetailsWidth`) until a double-click on the edge brings back the usual one. The work item
comes with all its fields and its links, and its comments at the same time, through its project: when the
sprint doesn't know its project, its comments are read after it, and when it moved to another
project, they're read again through that one. Then one request reads what the work items it links to
are. A work item that can't be read says why, with **Sign In…** when that's the reason; comments that
can't be read leave the rest. Its long text fields come as HTML, or as Markdown for those switched to
it (`multilineFieldsFormat`), and its comments as HTML too (`renderedText`). BriefBar draws them itself
(`RichText`, `RichTextView`), without a web view: headings, lists and task lists, quotes, code, tables,
links and their styles. HTML in Markdown shows as Azure DevOps shows it, outside code: HTML that starts a
line starts a block of HTML, as CommonMark has them, which shows as BriefBar shows HTML, Markdown in it
as written; and in text, an HTML comment shows nothing, a line break breaks the line, a paragraph starts
and ends on lines of its own, and the other tags that format text keep their text. Scripts and styles are
left out, only links to web pages and email addresses open (in your browser), and an image is a link to
it, never loaded. What's read stays in memory only, for up to 30 work items, and is forgotten a quarter
of an hour after it's read, but for the details on screen, which stay while they show; it shows again
without being read for a minute.
The sprint's refresh tells when a work item changed (`System.ChangedDate`), which reads its details
again while they show, or tries again when they couldn't be read, once more when it changed while they
were read, and a linked work item shows as
the newer of the sprint's and what was read with the details. Another team's sprint closes them, and
so does someone else signing in to the Azure CLI, which forgets what was read as the last one. Its parent, its tasks and related work items
open in the details too, and **‹** goes back. With Show Links on, the details start with
[Where It Stands](#where-it-stands): the pull requests, pipelines and Copilot sessions linked to the work item, and
what's known of each, which needs no more requests. A link to a work item in another organization, such as a
remote link, opens there, in your browser: its ID names another work item in this organization. A click on one of your work items in a
menu-bar list or a widget opens BriefBar's window at the Sprint page, with its details, unless no
window shows that page: then it opens in Azure DevOps.

**Pipelines.** A pinned pipeline shows its twelve latest runs, or its latest runs of one branch. Its
latest run's stages come from the run's timeline: its stages in order or, for a pipeline without
stages, its jobs. A stage waiting for an approval or a check is shown as waiting. When the run
failed, it names the first task that failed, the stage it's in and its first error. Runs started by
Azure DevOps itself, such as scheduled ones, don't name who started them. The timelines never read
go first, then the ones read longest ago; one that fails is tried again on the next refresh, then
less and less often, up to every 30 minutes, and one you may not read isn't asked for again until
the run changes. One whose organization waits on a sign-in to its directory isn't one that fails: it
takes its turn again at each refresh, behind the others, and the sign-in is said, read then or not,
until one of that organization's timelines answers or the run is no longer shown. Stages are kept by organization, project and run, since run IDs are unique only
within an organization.

Below pinned pipelines, **Your Pull Requests** groups validation runs into one expandable card per
active pull request you authored, including drafts and inactive PRs. Each card names the repository
and PR number and summarizes the latest run of each pipeline; expanding it shows those runs' stages
and failure details. Runs are scoped to the PR's repository and `refs/pull/{id}/merge`, not the latest
run of that shared pipeline on another PR. Results from older commits are marked **Outdated** and
excluded from the current pass/fail summary. If Azure DevOps doesn't provide enough commit information,
the result says **Commit not verified**, rather than assuming it validates your latest changes.
Cards disappear when the PR is merged or abandoned. This does not pin those pipelines, change pinned
pipeline counts or widgets, or affect **After Your Merges**. A card's title shows the pull request's details on
the Pull Requests page, at the first run that failed, or else at its builds and checks, and each of its runs
shows them at that run ([A pull request's details](#a-pull-requests-details)); right-click it to open it in Azure
DevOps instead. **Open in Azure DevOps**, in its menu or an **After Your Merges** card's, and a click when the
details can't show, open the pull request as its row does (`PullRequestDetailsStore.openInAzureDevOps(_:link:)`,
through `PRStore.open`): at the comment that needs you or the run after its merge, which sees it. One the list
doesn't have, such as a merge it no longer lists, opens at its page.
The authored PR list carries the account that supplied it. When the pipeline reader detects another
sign-in, it clears the old runs and suspends PR cards and validation requests until the pull request
reader supplies a list for that account, even when both accounts can read the same repository.

In a window, each section has a page of its own, in the translucent look of BriefBar's windows; in a
menu-bar item's list and in a widget, the Sprint section lists your own work, and the Pipelines
section each pinned pipeline's latest run. In a list, each one's title opens its page, one of your
work items its details on the Sprint page, and the sprint's footer its task board in Azure DevOps.

### Send work to Copilot

With **Send Work to Copilot** on, a sprint's work items get a ✈︎ button and menu items that send one to
the Copilot CLI (`Sources/CopilotTasks`). Nothing happens until you send one, and BriefBar's own
requests to Azure DevOps stay GETs: the programs it starts for you do the rest.

**Sending.** The composer fills the prompt in from Settings (`PromptTemplate`: `{id}`, `{type}`,
`{title}`, `{url}`, `{organization}`, `{project}` and `{baseBranch}`), each value on its placeholder's line, with
what breaks a line, turns text around or hides it written out (`QuotedText.oneLine`), and remembers the repository
each project's work went in, by organization and project. Only a work item's prompt has `{baseBranch}` filled in as
it starts: a pull request's has no placeholders, and goes as it is, so code it quotes that holds one, such as a
suggested change, stays as it was written. Then BriefBar:

1. asks your login shell for its environment, as VS Code does (`$SHELL -i -l -c 'env -0'`), so
   Copilot, git and the commands Copilot runs find what a Terminal window finds. Started as an app,
   BriefBar's own environment came from whoever started it, so the shell starts without its `COPILOT_`
   variables, such as `COPILOT_HOME`; your shell's startup files still set them;
2. finds `copilot`: `BRIEFBAR_COPILOT_CLI`, from the command line only; your `PATH`; the usual places;
   then the newest one the GitHub Copilot app keeps in `~/Library/Caches/github-copilot-sdk/cli`;
3. finds the repository's root and base branch (where `origin/HEAD` points, or `origin/main` or
   `origin/master`), fetches that branch, and adds a worktree detached at it, in
   `copilot-worktrees/<repository>/wi-<id>` next to the repository (or in the folder you chose), so
   your own checkout is never touched;
4. starts `copilot -p <prompt> --model <model> --reasoning-effort <effort> --autopilot
   --allow-all-tools --no-ask-user --session-id <id> --name <work item> -C <worktree> --silent`, with
   a session ID it chose, in a session of its own (`DetachedProgram`), responsible for itself, so it
   has none of BriefBar's permissions and goes on if BriefBar quits. Its output goes to
   `~/Library/Application Support/BriefBar/Copilot/<id>.log`, which only you can read.

**Pull requests.** With it on, a pull request's menu sends it too, for one of five actions
(`PullRequestAction`). In the main window, every row has a visible **Actions** menu; the same actions
remain available by right-clicking, including in the menu-bar popover and widgets.
BriefBar writes the prompt from what it read of the pull request
(`PullRequestPrompt`): the unresolved comment threads, those that wait on you first, word for word,
each with its file, line and thread; for a failed build, each run's link, where it failed and its
errors, read again from its timeline (one GET a build, when you ask), or, for one that's open in the pull request's
details, what they read of it there, with its failed tests and the end of its log, and nothing is read again
([below](#about-a-failed-build)); for its conflicts, the files that conflict and how each does, once its details read
them ([above](#its-merge-conflicts)), as the window shows them; for a review, the threads already there, and when you
last voted or commented. The prompts say what Copilot may do: fixing comments or a build changes files but never
commits, pushes or replies; resolving conflicts may commit its merge, but never pushes or replies; a review changes and
posts nothing; only **Push & Reply** commits what's left, pushes the pull request's branch without force
(`git push origin HEAD:refs/heads/<branch>`) and replies on its threads. The Copilot CLI holds it to that
whatever it reads, since its denials win over `--allow-all-tools`: a review gets
`--deny-tool write --deny-tool 'shell(git commit)' --deny-tool 'shell(git push)'`, fixing comments or a
build the last two, and resolving conflicts, which has to commit its merge, `shell(git push)`. Its worktree,
`copilot-worktrees/<repository>/pr-<id>`, is detached at `origin/<branch>`, fetched first, so it never
takes the branch from a checkout that has it. The composer already knows and shows the remote
repository. **Choose Local Clone…** selects its folder on this Mac, not which repository the PR belongs to.
BriefBar checks the clone's `origin` against the PR's organization, project and repository (names or
IDs, with Azure DevOps HTTPS and SSH URLs), and remembers a valid choice immediately, even if you
cancel without sending. Later PRs in that repository reuse it. When there is no saved choice, it
checks previously chosen clones by their remotes, never by folder name or an unrelated default.
If none matches, it asks you to choose a local clone once; it never clones automatically. A moved
clone or changed origin is reported so you can choose again, and the origin is checked again before
launching a task. A later task goes on with the
last one's session, if its worktree is still there: `--session-id` is that session's, without
`--name`, in that worktree, and the run keeps its place in the list. **Push & Reply** always does, and is
offered once a task that changed files is done.

**A session that's already there.** The composer's session menu, under **Where It Goes**, also lists the sessions a task can
go to instead of a new one (`SessionChoice`), read as it opens, and only while **Send Work to Copilot**
is on. First BriefBar's own: its tasks on the work item or pull request whose worktrees are still there,
and, for a pull request, the work item's task that opened it, by the pull request's link the task kept.
Then the Copilot app's sessions, from its `data.db`, read-only (`AppSessions`), each with why it goes
with it:

- the app records the pull request with the session's workspace (as for [Show Links](#links));
- the session's branch is the pull request's, in the same repository (`BranchLinks`);
- Show Links links them, because you did or through a pull request (`LinkedSession`);
- its log has a link to it (`SessionMentions`): `…/pullrequest/<id>` or the REST API's
  `…/pullRequests/<id>` for a pull request, `…/_workitems/edit/<id>` or `…/workItems/<id>` for a work
  item, whatever their case, not followed by another digit, in a link to its organization, read from the link itself:
  `https://dev.azure.com/<organization>/…` or `https://<organization>.visualstudio.com/…`. Only the logs
  of the 40 most recently active sessions are read for it, one at a time, none once Send Work to Copilot is
  off, of those active since the pull request was
  created, or in the last 30 days for a work item; each in chunks, until its first mention, opened below
  the app's folder without following a symbolic link (`LocalFile.openFile(below:_:)`): neither the log nor
  `session-state` or the session's folder may be one, so the search reads nothing outside the app's
  sessions. A session's `workspace.yaml` is read the same way.

The rest of the app's sessions follow, the most recently active first. A pull request's task goes where its
details say its work goes ([above](#a-pull-requests-details)), by the same rules (`CopilotTasksStore.suggestedChoice`,
with `PullRequestSession.pick`): to the session you chose for it there, unless a task started on it since; else on
with its last task's session, as before; else with the session of the work item's task that opened it; else with the
app's session that the app records with it, that you linked, or that's on its branch, when one goes with it better
than the others. When two go with it as well as each other, which its details ask about, or only one whose log
mentions it and that was there before it was created may have opened it, which they offer, it starts a new session
unless you choose one, rather than guess; so it does while the session they name is busy, rather than go to another.
Its last task is the latest run BriefBar keeps on it (`CopilotTasksStore.lastTask(forPullRequest:)`), so a task that
goes on with an earlier task's session takes the place of the one you chose only once it starts. A work item's task
starts a new session unless you choose one. What BriefBar finds while the composer is open changes where a task goes
only until you choose a
session or change the prompt (`CopilotComposerView.followsSuggestions`). A session that a task of
BriefBar's works in (`CopilotTasksStore.isWorking(inSession:)`: one getting
its worktree ready, or one whose process still runs), for this subject or another, is busy: it's never
suggested, can't be chosen, and BriefBar neither opens it in the app nor starts another run in it. So
is one that works in the same checkout as such a task (`CopilotTasksStore.busyFolders`), since two of the
app's sessions can share one, and their work would mix. A folder's checkout (`CopilotTasksStore.checkoutKey`)
is the nearest folder, itself or one it's within, with a `.git` of its own, as a checkout, a worktree and a
submodule have, so sessions in different folders of one checkout share it; a folder without one, as one
that holds checkouts, is its own, since its sessions mostly work elsewhere. The composer keeps up while it's open
(`CopilotTasksStore.availability`): a session frees up once the task working in it, or in its checkout, is
done, and one that a task starts in is taken, while where the task goes and its prompt stay as they are.

The prompt is for where Copilot works (`CopilotComposerView.writtenPrompt`). A pull request's is for a
worktree of BriefBar's, detached at its latest commit, for a new session and a pull request task's
(`CopilotRun.worksInPullRequestWorktree`); and for wherever the session works otherwise
(`PullRequestPrompt.Workplace.agent`): the app's sessions, and the work item's task that opened it, which
kept its own checkout, as does a pull request task that went on with it. That one asks Copilot to fetch
the pull request's latest commit and check it out where it works, and to ask first if that isn't a clone
of its repository or has changes of its own; Push & Reply's checks that what it would push was made for
the pull request. A work item's is the one in Settings for a new worktree, and BriefBar's own for a
session that's there (`PromptTemplate.existingSession`), which checks the same way before it branches
from the latest default branch, and commits only what it changed for the work item. **Copy**, above the
prompt, puts it on the clipboard as it stands, with your changes, whatever the session and the way it
goes. It sends nothing and hands nothing off (`CommentHandOff`), so it works in the demo. A prompt you
changed stays as you wrote it when you choose another session, and **Reset** goes back to the one for
the session you chose (`CopilotComposerView.rewritten`). There are three ways to send to a session that's
there, side by side (`CopilotComposerView.Delivery`: in the Copilot app or with the CLI, to the session
itself or to a fork of it):

- **Send to Session**, the default for the app's sessions, sends the prompt to the session in the Copilot
  app, as your own message, through BriefBar's extension in it (below), then shows the session. Copilot
  works with the session's own model, mode and permissions: the CLI's `--deny-tool` limits don't apply,
  only the prompt's words. A session that's working takes it once its turn is done.
- **Send to a Fork** forks one of the app's sessions with the app's own fork, and sends the fork the
  prompt. The fork is a session of the app's, with the session's history and the changes it hasn't
  committed, in a worktree and branch of its own; the session itself gains no message, only the app's note
  that it forked. It isn't there for a chat, nor for BriefBar's own sessions, which aren't the app's; nor
  for Push & Reply, which ships what its last task changed only in that task's session and worktree, where
  a fork would push a copy of them and leave them uncommitted (`CopilotComposerView.offersFork`).
- **Run with the CLI**, the default for BriefBar's own tasks, starts the CLI as for a later task: the
  session's `--session-id`, without `--name`, in the folder it works in. That's an earlier task's
  worktree, or the `cwd` in the app's session's `session-state/<id>/workspace.yaml`, read without
  following a link, which for a pull request has to be a clone of its repository, and in whose checkout no
  other of the app's sessions runs a turn now, by the app's own flag (`CopilotTasksStore.cliProblem`). The
  composer checks an earlier task's session the same way, which may have gone on with one of the app's
  sessions, or be in a worktree another of them works in. It reads the app's database and the sessions'
  state each time, not as the window found them, and looks again every five seconds while it's open
  (`CopilotComposerView.recheckSession`), without git once the repository passed, and reads nothing while
  Send Work to Copilot is off. The store looks once more as the task starts, and the launcher right before
  it starts the CLI, after its git commands, next to its last look at the lock (`LaunchError.sharedCheckout`).
  A run in one of the
  app's sessions keeps `isAppSession`, so **Remove Worktree…** never deletes that folder and its menu
  opens the session in the app rather than in Terminal. Going on with the work item's task that opened
  a pull request, the task stays that work item's too, and shows on the pull request's row as soon as you
  send it, so no other task starts on it meanwhile; if it can't start, the run it went on with stays as
  it was, to go on with again.

The Copilot app's runtime keeps each session it has open in memory, and marks it with `inuse.<pid>.lock`
in its `session-state` folder (`SessionLock`). A turn another program runs in such a session is one the
app never sees: tried with the Copilot CLI 1.0.105, the app answered its next message without that turn,
and the session's log then held both, forked. An interactive Copilot CLI keeps the same lock, from when it
opens a session until it quits, but doesn't check for one, so BriefBar does, for
every session it goes on with: while a running program holds one, **Run with the CLI** isn't offered,
the launcher refuses (`LaunchError.openInApp`), looking again after its git commands, right before it
starts the CLI, and **Continue in Terminal** opens the session in the app instead. A lock whose program is gone, as after the app quits, doesn't count, nor does one whose
process ID belongs to a program that started after the lock was written, since macOS reuses them. Nothing keeps the app
from opening a session while the CLI works in it, so the composer asks you not to until Copilot is done.
**Send to Session** forks nothing: BriefBar's extension sends the prompt through the runtime that has the
session open.

**Sending to a session, or a fork of it.** The Copilot app offers no way for another program to send one
of its sessions a message: its `ghapp://sessions/<id>` link only shows a session, and its link for a new
session doesn't reach one that's there. A program that runs inside the session can, as an extension of
the Copilot SDK: each runs in its session's runtime, and `session.send` sends that session a message, as
yours. So **Send Prompts to Copilot Sessions**, off until you turn it on in Settings › Agents
(`CopilotSessionPrompts`), installs BriefBar's second Copilot plugin, `briefbar-sessions`, whose extension
runs in each of the app's sessions that start afterwards, acts only on its own session, and only when
BriefBar asks ([below](#its-extension-for-the-apps-sessions)). BriefBar asks through files in `~/Library/Application Support/BriefBar/Copilot/Outbox`, on
this Mac only (`CopilotOutbox`):

- **Requests.** As you send it, BriefBar writes `requests/<session>.<request>.json`: the session, and
  `send` with the prompt, or `fork`, which expires two minutes on. The session's extension claims it by
  renaming it, so it's handled once, then writes `results/<request>.json`: done, with the message's ID or
  the fork's session ID, or why not. BriefBar reads the result and removes it. A request that no extension
  claims in time, BriefBar withdraws by removing it; one that's claimed always gets a result, however long
  it takes.
- **Listening.** While it runs, the extension writes `listening/<session>.json`, with its process ID and
  when it started. BriefBar counts it only while that process runs and started by then, give or take two
  seconds, as it tells a task's process from one that got its ID later (`CopilotOutbox.isLive`).
- **Only yours.** Each folder is a real one that only you can open (0700), and each file a regular one that
  only you can read (0600), written whole to a name starting with `.`, then renamed into place. BriefBar
  opens each without following a symbolic link below your home folder, uses no folder and reads no file
  that isn't so, and makes the folders only as it writes a request. As it writes one, it removes its
  requests and results that are more than an hour old; turning Azure DevOps off removes them all, since
  they hold its prompts, even from a folder of yours that others could open by then, which goes too, and
  unlinks a link where one of their folders should be, without following it (`CopilotOutbox.forget`); what
  it can't remove, it logs. What the extensions say in `listening` stays, theirs while they run.

Before you send it, the window says what will happen, and looks again every five seconds
(`CopilotTasksStore.reach(of:)`): BriefBar's extension listens in the session, so the prompt goes at once;
nothing has the session open, so opening it in the app loads it, with the extension, which takes the
request waiting for it, about 11 seconds later; or the app, or a CLI, has had it open since before the
option was on, so it needs restarting. While the option is off, BriefBar sends nothing, even to a session
whose extension still runs, as one does until the session restarts. A task's session that BriefBar started
with the CLI isn't the app's, which can't load it.

Sending (`CopilotTasksStore.deliver`, `SessionSender`) takes one prompt at a time for each session, and
waits without blocking a thread: up to 10 seconds for a listening extension to claim a request, 45 for a
session to load and 30 more for its extension, a minute for a send's result and two for a fork's, which
took about 22 seconds. To fork, the session's extension runs the app's own `fork_session`, whose text says
the fork's session ID, beside the session's name, which you or an agent chose. BriefBar sends the fork the
prompt only once the app's database records it as a fork of the session made since the request
(`forked_from_session_id` and `created_at`, read-only), and the fork's own extension, which listens by the
time the fork is made, takes it. Like the session's, the checkout the fork works in has to be free, unless
it's the session's own, and stays as it is until the fork's prompt has gone or been taken back; when Copilot
works there for another task BriefBar sent, BriefBar copies the prompt for the fork instead. When the
extension couldn't name the fork it made, named a session the
database doesn't record so, as a name that holds another session's ID could have it do, or didn't say how
the fork went, the fork is the one the database records of the session since the request, if there's just
one; with none or more, there's no telling, and BriefBar sends nothing. Then the session, or the fork, shows the way BriefBar opens one: in the
app; or, while a CLI has it open, the terminal that CLI runs in comes to the front, since the app loading
it too would fork its history. Closing the window stops it, and so does turning Send Work to Copilot, Send
Prompts to Copilot Sessions or Azure DevOps off: a request that no extension took yet is taken back, and
nothing more is written, copied or opened, even when BriefBar was still looking how the prompt would reach the
session, or how to show it. One that an extension took goes on, and BriefBar still waits for how it went,
so that the session takes no other prompt from it meanwhile.

When BriefBar can't send it, it copies the prompt, and shows the session, for you to paste and send;
when the window knows that beforehand, its button says **Open in Copilot** (`CopilotComposerView.sendTitle`).
For a fork, it copies `/fork` and the prompt, and shows the session:
pasted and sent there, the app's own `/fork` forks the session and sends the fork the prompt. A CLI's
terminal comes to the front, but not necessarily the session's own window or tab in it, so the window stays
open to say to find it there; and since the CLI's own `/fork` takes a name for the fork rather than a
prompt, for a fork there BriefBar copies the prompt alone, to paste once you've forked the session. Once the
session forked but the prompt didn't reach the fork, it copies the prompt and shows the fork. When the
window didn't say beforehand that it would, it stays open to say why; and when the extension took the
request but didn't say how it went, or said it failed, which it also says once it stops waiting for the
session, it says the session may have it already. What the prompt quotes is handed off
once it's sent, or once the session shows with the prompt copied; without the Copilot app, nothing shows,
nothing's copied, and the window says why, along with why BriefBar didn't send it, and, when the session
may have it already, to look first, rather than send it again with the CLI.

Copilot loads a folder's own skills, MCP servers and hooks only once you trust it (`trustedFolders` in
its `config.json`). The CLI gives a worktree of a repository you trust the same trust by itself, and no
more: a worktree of one you don't trust loads only your own configuration. BriefBar doesn't pass
`--trust-folder`: the CLI refuses it with `--session-id`, and wouldn't start.

**Forking a session, and asking one a side question.** A pull request's comments do both
([below](#about-a-comment)): Fix in a fork of one of BriefBar's own sessions, and the Send to Copilot window's **Fork
with the CLI** (`CopilotLauncher.Request.forking`); and Explain (`SessionQuestions`). Send to Copilot's **Send to a
Fork** forks one of the app's
open sessions another way, through BriefBar's extension ([below](#its-extension-for-the-apps-sessions)). The Copilot
CLI's `/fork` and `/ask` are commands of its terminal: with `-p`, tried with 1.0.105, they're words sent to the model,
and join the session's history. So BriefBar asks the CLI's server, as the Copilot SDK does (`CopilotServer`): it starts
`copilot --headless --stdio` with your shell's environment, responsible for itself (`RunningProgram`), and sends it
JSON-RPC requests, each after a `Content-Length` header. It refuses whatever the server asks of it, ignores what it
says unasked, and ends its input once it's done, which ends it; once it has quit, or five seconds later if it hasn't,
its whole process group is asked to stop, and two seconds later made to, as it is when the server quits by itself
first, so that nothing it started stays behind (`RunningProgram.end(grace:)`, `endsWhatItStartedWhenItQuits`).

- **A fork** (`sessions.fork`) is a new session with the session's whole history, as the CLI saved it: it takes a
  moment, and no request to the model. The session itself stays as it was, even while it works or the Copilot app has
  it open; the CLI only leaves an empty `.workspace-fork.lock` in its folder, as its own `/fork` does. A task in a fork
  gets a worktree of its own, `copilot-worktrees/<repository>/wi-<id>-fork` or `pr-<id>-fork`, detached at the commit
  the session's checkout has, when the repository has that commit too, as its worktrees do (`Git.head(of:in:)`); for a
  session that works elsewhere, such as a folder of repositories, where a new task's worktree would start. What the
  session changed without committing stays in its checkout, as with the CLI's `/fork worktree`. The fork is named for
  the task, and the CLI goes on with it as with any session that's there: its `--session-id`, without `--name`, in that
  worktree, which it works in from then on. If the worktree can't be made, or Copilot can't start, the fork is deleted
  (`session.delete`).
- **A side question** (`session.ui.ephemeralQuery`) is what `/ask` sends: one request to the model, with the session's
  conversation and no tools, which neither the question nor the answer joins. Asked of the session itself, the CLI would
  have to open it, and its log records both, among the model's calls. So BriefBar asks a fork of it instead, `BriefBar
  question`, opened with no tools, without your skills, MCP servers or plugins, and with the model you choose or else
  the session's own, and deletes the fork once it's answered, failed or been cancelled: a fork that's been asked for is
  waited for, even once the question's cancelled, so that it can be deleted, and one the server can't delete, having
  ended, another one does, or else BriefBar again later (below). The session's log and `workspace.yaml` stay as they
  were, byte for byte, and it can be asked while it works, or while the Copilot app has it open.

Each fork is kept with the runs from the moment it's made, by its session's ID and the CLI's folder it's in, nothing
else (`ado.copilot.forksToDelete`, `LeftoverForks`), until it's deleted or a task has taken it on, so none is left
behind, with a copy of a conversation, if BriefBar quits meanwhile. One that neither the server that made it nor
another could delete stays kept, and is deleted before the next question, fork or task, even once BriefBar has started
again; one that something has open then is left for later, and so is one this BriefBar still uses, for a question or a
task that's starting (`ForksInFlight`). Each is forgotten once its folder is gone. Should your shell's `COPILOT_HOME`
change, one in the other folder waits until that's the CLI's folder again: the folder kept only tells which are the
CLI's, and is never where BriefBar deletes anything. Any program running as you can change the preferences, so one
that isn't a session's is never used.

Forking with an older CLI can change the session it forks: tried on a session that 1.0.105 wrote, 1.0.78 added a line
to its log, and 1.0.87 replaced the whole log with that line. 1.0.95, 1.0.99, 1.0.102, 1.0.103 and 1.0.105 left it as it
was, so BriefBar forks nothing with a CLI older than 1.0.95, as the server's `connect` says
(`CopilotServer.forksSafelyFrom`).

**Following it.** Copilot logs the session to `~/.copilot/session-state/<id>/events.jsonl` (under
`COPILOT_HOME`, if your shell sets it), as for the app's sessions, and BriefBar reads it the same way
([below](#how-a-status-is-decided)), every three seconds while a task runs, and not at all otherwise or
while **Send Work to Copilot** is off. Whether the process still runs is checked first, by its ID and
start time, so one that gets its ID after a restart isn't mistaken for it. While it runs, the task is
working, whatever its log says for now: in autopilot, Copilot goes on after a turn that looks like its
last, and after an error. Once it's gone, and BriefBar has heard how it ended if it started it, its log
and output are complete, and say how it went: done if Copilot called it done or exited cleanly, failed
if Copilot reported an error or exited badly, and stopped otherwise. A task that went on with a session,
or forked one, has that session's history in its log too, which doesn't count: one that stops before
Copilot writes anything, as when the CLI refuses its options, failed, even if the session had finished,
and didn't open the session's pull request (`CopilotRun.launchedAt`). The pull request is then the one
the task it went on with had, or else the last link to one in what Copilot said since it started, in its
summary or its last message, or in what it printed. A notification says how it went; clicking it opens
the pull request, or the work item.

**Showing it.** Nothing opens: Copilot works in a session of its own, which the Copilot app doesn't list.
So as you send a task, while its worktree is still getting ready, a notification says Copilot is on it,
what it does and what it won't (`CopilotTasksStore.startedNotification`); the one that says how it ended
takes its place, or, when none will because you stopped the task or turned notifications or Send Work to
Copilot off, it's taken away. Clicking it shows the task with your Copilot sessions, in the menu bar or a
window. The work item's card or pull request's row shows how it's going. And while the GitHub Copilot
source is on, Azure DevOps tells it every task, as it stands, through `AppServices.sentTasks` (`SentTasks`,
in memory only), and its list shows each one with the app's sessions ([below](#how-a-status-is-decided)).
Neither source reads anything more for it.

**What's kept.** Which work items and pull requests you sent, what for, with which model, in which
repository and worktree, whether you stopped it, whether it went on with one of the Copilot app's sessions,
which comment threads, builds and conflicts it took on, by their IDs, and the pull request's link go to the preferences
(`ado.copilot.runs`), without their titles; and so are the prompts about them sent to the app's sessions, by references only
(`ado.copilot.sentPrompts`); and so
do your choices and the repository of each project, and the forks BriefBar hasn't deleted yet, by their sessions' IDs
and their CLI's folder (`ado.copilot.forksToDelete`), which turning Azure DevOps off keeps, to delete them once it's on
again. Any program running as you can change the
preferences, and BriefBar may have Full Disk Access, so the files it reads for a task aren't kept
there: a task keeps its session's ID, a UUID, which names its session log and its output, and those
are read without following a symbolic link. What Copilot printed when it ended stays in a file only you
can read. Turning Azure DevOps off forgets the tasks, the repositories and those prompts, and deletes what Copilot
printed. **Clear** forgets a task and deletes what it printed; **Remove Worktree…** deletes its
worktree with git, and asks again before deleting changes that aren't committed; it isn't there for one
of the app's sessions, whose folder is the app's, and doesn't delete one that Copilot works in, for a
task BriefBar sent in another session, or in one of the app's sessions running a turn there, the task's
own too once you went on with it in the app, or that a session BriefBar is sending a prompt to works in,
as it looks right before git deletes it, after each answer (`CopilotTasksStore.worktreeInUse`); from that
look until git is done, its checkout is busy, so no task of BriefBar's starts there meanwhile, as a
session's is while BriefBar sends it a prompt, or copies one for it and shows it, and a fork's while
BriefBar sends the fork one, until the prompt has gone, been taken back, or been copied with the session
showing
(`CopilotTasksStore.deliveringFolders`). A prompt sent to a session stays on disk only in its request, until the
session's extension is done with it or BriefBar withdraws it ([above](#send-work-to-copilot)). Copilot's
branches, pull requests and sessions are yours, and stay.

#### About a comment

In a pull request's details, while Send Work to Copilot is on, each open thread's card ends with **✨ Explain** and
**Fix** (`ThreadCopilotActions`), and the comments' heading has **Fix All** (`CommentsHeader`) on your pull request
while comments wait on you. Each opens a composer in place (`CommentComposer`, over `CopilotPartComposer` and
`CopilotAskComposer`, which a failed build and conflicts use too, each with what it asks about and the prompts it sends,
`CopilotAsking`): a field for your words, where it goes, and its button, which Return in the field presses, with a beep
while it can't send. One is open at a time in the details, in their comments, builds and conflicts alike
(`CopilotComposing`, which `PullRequestDetailsContent` keeps, as a file's page does its own), which keep what you wrote
in each until you send it (`CopilotDrafts`), and it scrolls itself into view as it opens. Where it goes (`CopilotDestinations`) is
first the session that last worked on the thread, as its line says, when the pull request's
session line knows it, else the pull request's own (`PullRequestSession.pick`), chosen unless the line asks which, or,
for a fix while it's one of BriefBar's tasks and busy, a fork of it; for a fix, a fork of it and a new session; then the
line's other sessions and its guess, and the app's other sessions. Without any, Explain has nobody to ask. Each says how a prompt would get there as the line works it out (`PullRequestSession.delivery`),
estimated without reading anything for all but the line's own, and the composer checks the one you choose as the Send to
Copilot window would, without its git check (`CopilotTasksStore.delivery(to:for:checksRepository:)`, `reach(of:)`), and,
for a new session, whether BriefBar knows a clone of the repository. Sending (`CopilotSending`) goes the way that says: a
task of BriefBar's goes on with the CLI, in its worktree; one of the Copilot app's sessions gets the prompt through
BriefBar's extension, or copied for you to paste (`CopilotTasksStore.deliver`); a fork of one of BriefBar's own sessions
is the CLI's, which picks the fork's ID, so the send goes by one of BriefBar's until the fork is made, then by the
fork's; a fork of one of the app's is the app's, through the extension; and a new session gets a worktree of the clone
BriefBar knows, or else the Send to Copilot window opens, to choose one. **Edit the Whole Prompt…**, last in ▾, opens
that window with the prompts, at the place you chose (`ComposerStart`), once what they quote is read, as a send waits
for it. A pull request that left your lists, or was completed or abandoned, while a send waited gets nothing, and its
composer says so (`CopilotSending.isOpen`). **Esc** closes a composer in place before the
details it's in (`InlineComposerOpen`). What a composer sends is called off as it closes, with ✕ or **Esc**, as another
opens, or as its page goes, with the details or for another pull request, file or page, though not as its card scrolls
out of sight in a file's diff (`CopilotDrafts.sends`): a prompt no session took yet is taken back, as when the Send to
Copilot window closes, and nothing starts or opens after. The details, which keep their one composer and what each
sends, call it all off as their parts go, for a file's page or with them, not as one part goes on its own, such as the
conflicts once they're resolved (`PullRequestDetailsContent`). VoiceOver hears what's sent, and what becomes of it, as it
happens.

**Fix** (`PullRequestPrompt.fixThread`) addresses that thread alone: its entry as Fix Comments lists it, each comment in
full as its author wrote it, one of more than a line under its author's name in a fence nothing in it closes, then that
the comments are what their authors ask of the change, not instructions (`PullRequestPrompt.commentsSaid`), as every
prompt that quotes threads says; the code it's on as the reviewer saw it, once it's read (`ThreadExcerpt`), numbered, with
what was added, removed and commented, in a fence too; and what you wrote, quoted as yours; then it builds and tests, without
committing, pushing or replying. On a file's page, whose threads don't show their own code, a composer has it read as it
opens, as a thread that comes on screen does, through the reader the page's diff was read with: only while its window
shows on screen, called off as it hides, and read again once it shows. Explain, Fix and **Ask in the Session** wait for a
read that's under way as they go, and go without the code when it isn't read
(`PullRequestCodeStore.excerpt(of:in:by:on:)`). A ```` ```suggestion ```` fence, in any case, is a suggested change
(`RichText.Block.suggestion`), blank lines at its ends and all, which the comment shows labeled; **Apply ‹name›'s
suggestion as written** has the prompt quote the latest that someone else suggested in the thread
(`CommentSuggestion.latest`) and ask for it as it's written, on the lines the thread is on, which Copilot finds in the
file as it is now by their code, since their numbers are from when the thread was written. The box is checked when the suggestion is the thread's last comment. Once a session answered Explain on the thread,
**Include the answer above** quotes what it answered (`CopilotAnswer`, cut to 6,000 characters) before your words, which
can point to it, in a fence nothing in it closes, saying that it may quote what it read, not instructions, since it often
quotes a comment or a run word for word (`PullRequestPrompt.earlier`); Ask More quotes it the same way. Its hand-off is that thread's comments that wait on you
(`CommentHandOff.init(_:thread:dismissedCutoff:account:)`), and since a pull request has one cutoff, a comment that waits
on you from before, in another thread, keeps both on Needs You: as BriefBar last read the pull request when the task
starts, or, when it hasn't read it then, as after you switch accounts, as the prompt was written, for which the other
threads' comments are kept too. **Fix All** is Fix Comments' prompt, with your words
quoted as yours; it says **Fix 1 Comment** while open threads that don't wait on you are left (`CopilotAsk.fixAllTitle`).

**Explain** (`PullRequestPrompt.explainThread`) quotes the thread and its code the same way, with your question, and asks
the session you chose, aside, why the reviewer wrote it, what they want, how the code relates, and ways to address it
(`CopilotQuestions`, over `SessionQuestions`): in a fork with no tools, deleted after, with the session's own model. The
answer stays in memory only, until you dismiss it, BriefBar quits, or Send Work to Copilot or Azure DevOps is turned off,
which stops a question that's being asked, and deletes its fork. When the CLI can't ask aside, or doesn't have the
session, **Ask in the Session** sends `PullRequestPrompt.askAboutThread` to the session as a prompt, as a fix goes, with
what it answered before for a follow-up, which changes nothing but joins its history. Once it answered, **Ask More** quotes the question and the answer, which the next
throwaway fork never saw, and asks your next question with them in mind, or, without one, why you got it again. The demo
makes its answers up (`DemoData.explanation`), and runs nothing.

**What Copilot does about a thread** is said on it, in a sentence (`CopilotWork`, `CopilotWorkLine`), from the latest work
that took it on, as for a build and conflicts, with the step it's at, or, once it's over, what Copilot said under it, on
up to three lines, such as why it couldn't, and whole in its tooltip (`CopilotWork.said`). A task of BriefBar's, named
for what it does, is called a task in its sentences and where it goes, "the ‘Fix Comments’ task", so that it doesn't
read as a command (`CopilotWork.quoted(_:isTask:)`). A task of BriefBar's keeps what it took on with its run, threads, builds
and conflicts, by their kinds and IDs, each with when (`CopilotRun.taken`, `PullRequestPart`); going on with a session
whose changes aren't pushed, on the same pull request, keeps what it took on before, with how that ended. Push & Reply
takes on what it ships (`TakenPart.ships`): the threads its prompt lists, to reply on, and the builds and conflicts the
session fixed and hasn't pushed, which its push takes along, however it's sent (`CopilotTasksStore.unpushedParts`). The
other threads the session fixed stay as they were, fixed and not pushed, with when, since it doesn't reply on them, and a
thread that another session fixed since stays that one's. Once it's done, those it listed say they're pushed and replied, and a later
task in the session keeps them so, for an older fix of one of them, elsewhere, not to say it's ready again
(`CopilotRun.taken(goingOnWith:on:taking:for:at:)`). A
prompt sent to one of the Copilot app's sessions, or copied for you to paste there, is kept by references only, never what
it says: the pull request, the session that took it and the one it forked, what it took on, what for, and when (`SentPrompt`,
`ado.copilot.sentPrompts`), for as long as a link you make. The app runs it, so BriefBar follows it from the session's log
since it began to send it, so that a turn that's over before BriefBar hears the prompt went counts too, but only from the
first message the session got since, the prompt itself as the earliest, sent or pasted: a turn that was under way as it
was sent, or copied, is an earlier message's, and a question it asks you counts while something runs the session or has
it open, as one it ended with stopped (`SessionTurn`). It's read where the session is, in the Copilot app's folder
or, for one pasted in a terminal, the CLI's, as a task's is, every three seconds, with which
sessions the app runs a turn in and whether something has the session open, only while one hasn't ended and Send Work to
Copilot is on and Azure DevOps hasn't stopped: a turn that's over twice in a row, a few seconds apart, ended, which its
record keeps; one copied as `/fork` follows the fork the app records as made since, when it made just one. One you
didn't paste goes after half an hour, and one whose turn hasn't ended after twelve hours. Once BriefBar sends the
session another prompt, about threads or not, or goes on with it with the CLI, before a prompt's turn was seen to end,
the session's log can't tell their turns apart: BriefBar stops following the earlier one, whose thread says **Sent to
‘Retry backoff’ · see the session**, or **Copied for ‘Retry backoff’ · see the session** for one it copied, rather than
how the later turn went, and leaves it out of the bar below; it's kept as long as one that ended
(`SentPrompt.overlapped`, `CopilotTasksStore.overlap(promptsIn:before:)`). While BriefBar is sending the session another
prompt, or starting the CLI on it, the earlier one isn't followed, since the new one's turn may end before BriefBar hears
it went; once nothing went, it's followed again (`CopilotTasksStore.pauseFollowing`). A turn seen over just once isn't taken as its
end, since it may be the end of the turn that ran as it was sent. A fix that's done and not pushed, of a thread that's
still open, a build that doesn't pass or conflicts the pull request still has (`PRRecord.partsToFix`), counts in the bar
at the details' foot (`ReadyFixesBar`, `CopilotTasksStore.readyFixes`), the pull request's
own or, under its page over the details on the Pull Requests or Sprint page, the linked one's, and so does one
whose Push & Reply failed or stopped, to try again (`CopilotWork.waitsToBePushed`), even once a question was asked about
the thread since, whose sentence says what's ready by what it fixed, "2 fixes", "a build's fix", "the conflicts'
resolution", "1 fix and the conflicts' resolution ready in ‘Retry backoff’" (`ReadyFixesBar.sentence(_:in:)`), takes the
details to the first thing they fixed, and whose **Push & Reply…** opens the Send to Copilot window in the session the fixes are
in, for their threads alone: its prompt lists them and replies on them alone, or on none for a build's fix alone, and
hands off what waits on you in them alone (`PullRequestPrompt.pushAndReply(_:workplace:threads:)`,
`PullRequestPrompt.shippedThreads`), and the task that ships them takes them on, with their builds and conflicts, so they
say they're pushed once it's done, though prompts fixed them rather than its runs. A prompt in the Send to Copilot window
takes on what its action is for (`PullRequestTasks.parts`): the threads whose entries are still in it as you send it
(`PullRequestPrompt.threadsListed`), the builds that failed for Fix the Build, the conflicts for Resolve Conflicts. The
demo's are made up (`SentPrompt.demo`).

#### About a failed build

In a pull request's details, while Send Work to Copilot is on, a build that failed and is open under its row
(`BuildInvestigationView`) has, as a thread does, what a session said of it, what Copilot does about it, then **✨ Explain
the Failure** and **Fix** (`BuildCopilotActions`), above **Open Run**, each opening a composer in their place
(`BuildComposer`, over `CopilotPartComposer`), one at a time in the details with the comments' and the conflicts', and
each build's row its own, where two of the pull request's policies run the same pipeline (`CopilotComposing.row`). While
what shows of the run is of an attempt before it ran again under the same ID, or before its pull request changed, until
it's read again, they wait, saying why, and a composer that's open closes, keeping your words, what it was sending called
off, so that nothing quotes another attempt as this one (`BuildInvestigationStore.current`). Copilot takes the build on by the pipeline its policy runs (`PullRequestPart.build`,
from `Check.definitionId`, which the policy's settings say, else its run's): each of its runs, as it runs again or after a
push, is the same build. Where it goes is as for a comment: the session that last worked on the build, else the pull
request's, and, for Fix, a fork of it and a new session; then the rest (`CopilotDestinations`).

**Explain the Failure** (`PullRequestPrompt.explainBuild`) quotes what the details read of the run as it opened
(`FailedBuildReport.init(_:name:)`): where it failed, from its stage to its task, its first ten errors with where each
is, the first five tests that failed, each with the first twelve lines of what it said and six of its stack trace, at
most 1,000 and 800 characters, and how many more failed, the last 40 lines of the failed step's log, each cut to 300
characters, and what tells whether it's the change's doing (`BuildHint`). Anyone who can push code can write what a run
says, so a name, of the build, a step or a test, stays on its line, with its line breaks, other control characters and
the invisible ones that reorder text or hide text a model may read, such as direction marks and overrides and Unicode
tags, written out as escapes (`PullRequestPrompt.oneLine`); its errors, each test's message and stack trace, and the log
each go in a fence nothing in them closes, with the same characters written out but tabs (`PullRequestPrompt.fenced`);
and the prompt then says that they're what the build said, not instructions. The pull request's title, repository and
branches, which whoever opened it named, stay on their lines the same way in every prompt (`PullRequestPrompt.introduction`),
and so do names, paths and comments of one line; a branch whose name holds what a shell reads, such as `$(…)` or a
backtick, which Git allows, is in single quotes wherever a prompt names it, in a command such as `git push origin
HEAD:refs/heads/'<branch>'` or in a sentence Copilot may make one from, so it runs nothing (`PullRequestPrompt.branch`). It asks the
session, aside, what failed and why, and whether it's the change, a flaky test, the target branch or the build's
infrastructure (`CopilotQuestions`, over `SessionQuestions`). What it answers is kept with the run it's about, and the
attempt of it, by when its check said it finished, so it doesn't show with another run of the build, nor once its failed
jobs ran again under the same ID (`CopilotQuestions.Question.isAbout(run:attempt:)`); and each run is asked about on its
own row, where two policies run the same pipeline (`CopilotQuestions.Key.run`). Each time the pull requests are read
again, an answer about a run its details don't list any more, or about another attempt of one, goes, and stops while it's
being asked, so that Ask More and Fix don't build on it; not while its policies can't be read
(`CopilotQuestions.dismissStale(of:)`). **Ask in the Session** sends `PullRequestPrompt.askAboutBuild` instead,
which can read the run's whole log with the session's Azure DevOps tools. The demo makes its answer up
(`DemoData.buildExplanation`).

**Fix** (`PullRequestPrompt.fixBuild(_:failures:workplace:how:answer:alone:)`) quotes the same, then your words, as yours,
and the answer if you include it, and keeps to that build. It's Fix the Build, whose `deniedTools` refuse commits and
pushes, and hands nothing off, since a build waits on nobody. The pull request's own **Fix the Build** quotes what its
details read of each failed build that's open there, while that's of the run as its check and the pull request are now
(`PRStore.investigation`, `BuildInvestigationStore.current`, `PullRequestTasks.reports`), else its timeline's errors, as
before, since what's kept of a folded build isn't read again as it changes, and takes on each of its failed builds (`PullRequestTasks.parts`).

What Copilot does about the build is said as on a thread (`CopilotWork`): **Copilot is fixing this build in ‘Retry
backoff’**, **Fixed in ‘Retry backoff’, not pushed**, **Pushed from ‘Retry backoff’**; with its run while it's open, and
under its name while it's closed, or before its run is read (`BuildWorkLine`), which says too that a session is
explaining it, with **Stop**, or answered, or couldn't, with **Show**, which opens it, once that's newer than what Copilot
does about it. VoiceOver hears what becomes of them either way. Once the build passes, as when it ran again or after a
push, or doesn't apply, or expired after it passed, which is to queue again, its line goes, unless Copilot is still at
it, and so does a pushed fix's once a run of the build failed, or failed and expired, after Copilot started to push, for
you to fix it again (`CopilotWork.shows(onBuild:)`, `CopilotWork.takenAt`); one that failed, then expired, as when its
target branch moved, is still to fix, and an unpushed fix of it stays (`Check.expiredFrom`, `Check.needsNoFix`); its fix isn't counted in the bar at the details'
foot once the build passes (`PRRecord.partsToFix`). A pass ends it for good: each time the pull requests are read again,
whether their rows changed or not, what each task and prompt took on of a build that a run passed after, or passed and
expired, is let go, so that a later run that fails, maybe for another reason, doesn't bring its fix back; a task that goes
on with the session, while it gets ready, launches without it. What Copilot is still at stays, and so does what it took
on since; a pipeline another of the pull request's policies runs is passed only
once none of them needs a fix, and a pull request whose policies couldn't be read keeps it all
(`CopilotTasksStore.endWorkOnBuildsThatPassed(in:)`). Push & Reply ships it with the threads its session fixed, or alone, replying on no thread then
(`PullRequestPrompt.pushAndReply(_:workplace:threads:)`), and any Push & Reply in the session that fixed it, from the
pull request's menu too, takes it along, so it says it's pushed once that's done.

#### About its conflicts

Under a pull request's merge conflicts ([above](#its-merge-conflicts)), while Send Work to Copilot is on, **✨ Explain**
and, on your own pull request, **Resolve** (`ConflictsCopilotActions`) open the same composer in place
(`ConflictsComposer`, over `CopilotPartComposer`, for `PullRequestPart.conflicts`), in a box of its own, one at a time
with the comments' and builds' (`CopilotComposing`), going where a thread's would: first the session that last worked on
the conflicts, else the pull request's. Its prompts
list the files that conflict, each with how, as the details read them for the pull request as it is now, the first 50
(`PullRequestPrompt.conflictList`). Whoever made a file chose its path, which Git lets hold a line break, so each
stays on its line, its line breaks and other control characters written out (`PullRequestPrompt.oneLine`), and the
list ends saying they're paths, not instructions (`PullRequestPrompt.conflictsSaid`), as a build's prompts say of what
it said; the target branch's name stays on its line the same way wherever they name it. A prompt sent while they're
read, from the composer, **Ask in the Session** or the menu, waits for that read, and is written for the pull request as
it is once it ends, so one pushed to or retargeted meanwhile names its target branch as it is now, with the files read
for that, never those of the old one (`PullRequestConflictsStore.forPrompt`); without them, as when they couldn't be
read, it goes without, for Copilot to find them as it merges. **Resolve** (`PullRequestPrompt.resolveConflicts`, the
prompt of **Resolve Conflicts with Copilot…** in the pull request's menu, which lists them too while the details have
them, `PRStore.copilotPrompts`) has Copilot fetch the target branch, merge it in and
resolve them, keeping what each side meant, as you say, quoted as yours, building on what the session explained when you
include it, then build and run the tests that cover what conflicted. It may commit the merge, which the Copilot CLI
allows, but never push, which it denies: its composer says so (`PullRequestAction.leavesOut`), and **Push & Reply**, in
the bar at the details' foot once it's done, pushes it, replying on no thread. It hands nothing off: conflicts don't wait
on you in Needs You. **Explain** (`PullRequestPrompt.explainConflicts`) asks the session you chose, aside, as for a thread,
why they conflict: what the pull request changed in each file, what the target branch likely changed there, from how
each conflicts, how it would resolve each and what to check after; **Ask in the Session**
(`PullRequestPrompt.askAboutConflicts`) asks it as a prompt instead, where it may read the target branch, but changes
nothing. What it answers is about the branches as they were asked about (`CopilotQuestions.Question.head`): once someone
pushes to the pull request or retargets it, the answer goes as the list reads it again, and what's still being asked
stops (`CopilotQuestions.dismissStale`), so Ask More and Resolve never build on it. Sent while the branches move, as
the files are read again, one that would build on an answer about them as they were stops instead, and its composer
says so: sent again, it goes without it (`CopilotAsking.quoting`). What Copilot does about them is said
under them in a sentence, as on a thread: **Copilot is resolving the
conflicts in ‘Rename the order status enum’**, **Resolved in ‘Rename the order status enum’, not pushed**, **Couldn't
resolve them: …**. The demo makes its answer up (`DemoData.conflictsExplanation`), and runs nothing.

### Notifications

After each refresh, BriefBar compares the new list with the previous one (`NotificationPlanner`)
and announces events it hasn't seen before, as well as your pull requests that start failing,
become ready or complete, and what the pipelines after your merges do. What you've seen is never
announced, even while it still waits on you. Events from before BriefBar started aren't announced: they're in the
panel. When there's a lot at once, it posts the three newest and one "more updates" notification.
Changing a setting or time passing never causes a notification. Clicking one opens the comment it's
about, in Azure DevOps, or in the pull request's details with **Open Pull Requests in BriefBar** on, and marks the
pull request seen.

### The brief

Azure DevOps' own brief, at the top of its list and its page, picks, in code, the newest pull
request that needs you, the newest failure and the newest one that's ready (then more of what needs
you, up to three). Each names whoever its pull request is there for: the one who commented, or the
reviewer who wants changes or rejected it, even when someone else has commented since. The brief across
sources ([above](#the-brief)) says each pull request the same way. Items about a comment go to Apple
Intelligence's on-device model one at a time, with the commenter, the title and the comment, and come
back as one sentence such as "Sam asks you to cap the backoff at 30 seconds on …". The others are plain
sentences. Results are kept for as long as the app runs, never block the panel, and fall back to the
plain sentence if the model isn't available or fails. BriefBar explicitly uses
`SystemLanguageModel.default`: nothing goes to Private Cloud Compute or any other model.

### Limits

- Pull requests sent in chats are only as complete as Notification Center: a message you saw in the
  app before it posted a notification, or one older than the notifications it keeps, isn't there.
  Since BriefBar keeps the links in memory only, that's also true of a link it had found, once
  BriefBar restarts.
- Pull requests assigned only to a group or team you're in aren't listed: Azure DevOps's reviewer
  search matches you, not your groups.
- An organization in another directory than your sign-in's is read only once the Azure CLI is signed
  in to that directory too. The CLI gives tokens for the account it's signed in with, so organizations
  that each need a different account can't all be read at once. BriefBar doesn't tell a directory your
  account isn't in from one it only has to sign in to again: either way, it offers to sign in there, and
  signing in says which it is.
- A failed build says where it failed only when its run's timeline can be read, and then only its
  first error. Opened in a pull request's details, it shows its errors, the first 20 tests that failed and the
  last 200 lines of the failed step's log: the rest is in Azure DevOps.
- The pipelines after a merge are found in its repository's project: a run that a trigger starts in
  another project isn't.
- The Sprint section shows one team's current sprint at a time, from your teams in the organizations
  BriefBar watches.
- Pipelines are build pipelines, YAML or classic; classic release pipelines aren't shown.

## GitHub Copilot

### Where the data comes from

The Copilot app already records everything needed, in two places under `~/.copilot`:

| Source | Written by | Provides |
|---|---|---|
| `data.db` (SQLite, WAL mode) | the Copilot app | sessions, names, projects/branches, which session started which and which coordinates which, which one each fork was forked from, the "is running" flag, unread markers, the activity feed, how full each session's context window is; and, only with [Show Links](#links), the pull request each session started from or opened, and its project's GitHub repository and folder name |
| `session-state/<id>/events.jsonl` | the Copilot agent | a step-by-step log: turns, tool calls, questions, plans, permission prompts, errors; and, only as [Summarize with Copilot](#what-a-summary-reads) writes a summary, what was asked in it and what Copilot answered |
| `session-state/<id>/checkpoints/` | the Copilot agent | only with [Show Links](#links), for [Where It Stands](#where-it-stands): the notes Copilot writes when it compacts a long session, `index.md` with each one's title, and the latest one's overview, what's done and what's next |

BriefBar combines the two. The database says which sessions exist and whether the app
thinks they're running. The tail of each log says exactly where a session is, for example
"asked a question at 14:02 and is still waiting".

BriefBar never changes either of them:

- The logs are opened read-only. After the first read, only what's been appended is read.
- A session's checkpoints and last words are read only when a work item's details show the session
  ([Where It Stands](#where-it-stands)): `index.md` (up to 256 KB), the start of the latest checkpoint
  (up to 512 KB) and the end of its log (up to 2 MB), each opened below `~/.copilot` without following
  a symbolic link (`LocalFile.openFile(below:_:)`), and only for a session whose ID is a UUID. A
  checkpoint's file name comes from `index.md`, so it's opened only when it's a single plain name
  ending in `.md`.
- The database is opened with a read-only SQLite connection. Like any SQLite reader, it briefly
  takes shared locks and updates SQLite's shared-memory index (`data.db-shm`) while it reads;
  neither changes any data. Each read is one snapshot, a read transaction (`SQLiteConnection`): all
  its queries see the database as the first one did, so a write the app commits between two of them
  can't mix old and new rows into one list. When the app has quit and SQLite has removed the write-ahead log, a
  read-only connection can't open the database, so BriefBar reads it in SQLite's
  [immutable mode](https://www.sqlite.org/uri.html#uriimmutable) instead. That takes no locks, so
  what it reads holds only while the app leaves the file alone: BriefBar looks at the file's identity,
  size and time, and whether a log appeared, before and after the read. If the app opened or wrote the
  database meanwhile, BriefBar reads it again, the usual way once the app has it open; after three
  reads in a row that changed, it says "Copilot database query failed: it kept changing as it was
  read", and the list keeps what it last read.

### How a status is decided

The [states table in the user guide](user-guide.md#github-copilot) lists every status and when
it applies. A few more details:

- "Needs you" sorts the longest-waiting session first; the other groups show the most recent
  first.
- **Done** and **Stopped** sessions stay highlighted until you click **Clear** on their group
  in the menu-bar panel, or the **Keep Finished Sessions For** time passes (1 hour by default).
  **Move Viewed Sessions to Idle**, off by default, optionally dismisses them sooner: when you
  open one from BriefBar, view it in the frontmost Copilot app, or Copilot clears its unread marker.
  Turning the option off shows recent viewed completions again, but doesn't undo explicit clears.
  Clear and viewed markers are kept separately. Clear applies only to runs that have already ended:
  a later completion in the same session appears again, timed from that run's end.
  After clearing or expiry, the session moves to Idle.
  Old saved "seen" markers are treated only as viewed, never as explicit clears, so they don't
  suppress recent completions unless the option is on.
- Detailed states (questions, plans, permissions, the current step) come from the agent's log on
  this Mac. A session without a local log only shows Running, Interrupted or Idle, based on the
  app's own flags.
- **Show Relayed Questions Once**, off by default, shows a question asked for another session once
  (`RelayedQuestions`). When a session waits on a question or a plan, the app tells the session that
  coordinates it (`coordinating_creator_session_id`, on its workspace, or for a chat in
  `chat_parent_links`), which asks you for it. It relays a question with `relay_session_input`, which
  names the session, by its workspace or its own ID, but doesn't repeat the question, and it can relay
  several at once. A plan can't be relayed, so it asks about the plan with its own `ask_user`. Either
  way, it's one decision, best made in the coordinator: answered there, it's passed on. A relayed
  question answered in the session ends the relay too, but a plan approved in the session itself leaves
  the coordinator's question waiting, and its approval then fails. With the setting on, a relay counts
  as waiting for your answer, with the words of the question it relays, after any question or plan of
  the coordinator's own, which comes first. Once the coordinator asks, by a relay that names the
  session or by a question of its own that started after the session began waiting, the session moves
  to **Running** as **Answer in “…”**, and clicking it opens the coordinator. Every other session it
  coordinates that had been waiting since before moves with it, since the coordinator brings them up
  next. The coordinator stays in **Needs you**, timed from the longest wait among them. When a
  coordinator's own question is asked for in turn, by the session coordinating it, they all point to
  the session that asks you in the end. Until the coordinator asks, the session needs you on its own.
  Permission prompts are never asked for: only the session itself can answer one. With the setting off,
  a relay shows as **Working**, as it did before, and the session it relays for needs you on its own.
- **Nest Sessions Under Their Parents**, off by default, nests sessions under the sessions that started
  them, as the Copilot app's sidebar does (`SessionNesting`), but within each group. A session's parent
  is the one the sidebar nests it under. For a project session, that's the session of the parent
  workspace (`workspace_parent_links`) of the workspace it's listed with, the one in its project that
  started it, but not the one it was forked from (`forked_from_session_id`). Without a parent workspace,
  it's the chat that started it (`coordinating_creator_session_id`, else `creator_session_id`, on that
  workspace), whether or not the chat coordinates it. For a chat, it's the session that coordinates it,
  else the one that started it (`chat_parent_links`). Detaching a session in the app forgets all of
  these, so it stands on its own, and a session that started one in another project gets no parent
  workspace, so the sidebar doesn't nest that one either. Each is read apart from the main query, so an
  older schema only loses nesting. Without the Copilot app, there's no database to read them from, so
  nothing nests.
  Within a group, a session whose parent is in the same group sits right under it, indented, its own
  children under it in turn. Before grouping, a parent that finished (`.finished`) while sessions under
  it, at any depth, still run or need you moves to them: to **Needs you** when one of them needs you,
  else to **Running**, as **Waiting for child sessions** (`.waitingForChildren`), saying how many need
  you and how many are running, and waiting since the earliest of them. A parent that stopped, failed
  or went idle keeps its group. A family takes the place of the member that sorts first, so **Needs you**
  still starts with the longest wait; in it, the parent comes first, then its children in the group's
  order. A session whose parent is in another group keeps its place, with a **↳** tag naming the parent,
  which opens it, as clicking it would, except when its **Answer in “…”** names that session already. The
  row, itself a button, would take the click from a button in it, so the tag's button lies over the tag,
  outside the row's (`ParentTag.Target`). A parent BriefBar doesn't
  list, such as an archived one, nests nothing and gets no tag. Counts don't change. **Everything by
  State** sorts every section's items together, so it doesn't nest sessions, and tags each one with a
  listed parent. The command line and agents follow the same setting: `--dump` indents nested sessions
  and tags the others, and `--mcp` indents nested sessions under their parents and says which session
  started each of the others.
- **Show Context Usage** shows the app's latest measurement of each session's context window
  (`session_context_usage`): the tokens the conversation takes up, as a share of the model's
  limit. Copilot compacts a conversation at about 80% of the limit, so the percentage turns
  orange from 70%. Sessions the app hasn't measured show nothing.
- Clicking a session opens it through the Copilot app's `ghapp://sessions/<id>` link. Without the app
  (`CopilotApp.isInstalled`: nothing on the Mac opens `ghapp://` links), the sessions are the Copilot
  CLI's, and one opens with the CLI instead (`CLISession`), looked at again on each click. A session a
  CLI still holds (`SessionLock`) brings the app macOS holds responsible for that CLI to the front, such
  as Terminal, iTerm or VS Code: resuming it in a second terminal would fork its history. BriefBar can't
  pick the exact window or tab, which would take AppleScript. Any other session opens in Terminal with
  `copilot --resume <id>`, in the `cwd` its `workspace.yaml` names, as **Continue in Terminal** does for
  a task, with `COPILOT_HOME` set to the folder BriefBar read the session from, whatever your shell
  sets. A new Terminal window takes a moment to start the CLI, which holds the session only once it
  starts, so for 30 seconds another click on that session starts nothing more (`CLISession.Starting`):
  two CLIs in it would fork its history. Turning Copilot off, or quitting, stops one that's still being
  opened before it reads more of its session. The script, in BriefBar's caches and named by the
  session's whole ID, removes itself as it starts, and turning Copilot off removes any that never ran.
  The **Open Copilot** button and menu item are hidden then. The demo's made-up sessions always open in
  the app.
- The tasks you sent to Copilot from Azure DevOps ([above](#send-work-to-copilot)) are in the list too,
  with ✈︎ before their names, unless the app's database lists their sessions itself, as it does once you
  open one there. (Without the database, the list is every recent session folder, and a task's folder is
  the task.) Azure DevOps already follows them, so the list takes how each one stands from it rather than
  reading anything (`StatusResolver.snapshot(unlisted:…)`): **Running** while its worktree gets ready
  (Starting…) and while Copilot works, with its current step; then **Done** or **Stopped**, highlighted as
  long as a session would be, until Clear or retention expiry, with optional dismissal on opening
  while **Move Viewed Sessions to Idle** is on. One you stopped yourself is idle at once.
  Clicking one opens its pull request, or its work item, and its menu is the task's own: go on in
  Terminal, or in the Copilot app for one of its sessions, show the worktree or what Copilot printed,
  stop it, remove its worktree or clear it.

### Updates are pushed, not polled

- **Agent logs** are watched with **FSEvents**. The agent closes `events.jsonl` after every
  append, so each write produces an event (about 0.15 s latency).
- **The app's database** is watched with **kqueue** on `data.db-wal`. This was a key finding:
  FSEvents only reports a file's content changes once the writer **closes** it. The Copilot app
  keeps its SQLite connection open, so its writes to `data.db-wal` produce no FSEvents at all,
  even though the file changes. A kqueue `EVFILT_VNODE` watch reports every write immediately.
  Bursts (one tool call causes about 10 writes) are combined into one reload after 0.25 s.
  When the app quits and SQLite deletes the WAL file, the watch is re-armed as soon as the file
  is recreated. `data.db` itself is deliberately not opened for watching: closing an extra file
  descriptor on a SQLite database drops the process's SQLite locks.

On real data, a session rename (a database-only change) reached the UI about 0.26 s after the
app wrote it.

Two timers exist, and neither drives status updates:

- a 15 s tick that refreshes relative times ("3m") and expires the "keep finished" window, and
- a 60 s safety rescan that catches anything missed, for example after the Mac wakes from sleep.

### When the Copilot app's files change

This relies on the Copilot app's **undocumented** local files: the database schema, the event
log format, and the `ghapp://` link. An app update could change them.

- If the main database query fails, the app uses a simpler one: session names only, without the
  running flag, projects or branches.
- If the database can't be read at all, sessions are listed from their log folders, and the
  problem is shown in the panel and the widget. On a Mac without the Copilot app, a database that
  isn't there at all (`EngineSnapshot.databaseMissing`: no such file, not one that can't be reached,
  looked at on every read that fails) is no problem: the Copilot CLI keeps none, so the list is its
  session folders, and nothing is shown, in the panel, the widget, the command line or to agents
  (`CopilotApp.problem(of:)`). With the app installed, it's shown as before.
- Sending a prompt to a session ([above](#send-work-to-copilot)) relies on the Copilot SDK's extensions, which
  are supported, on how the app runs them in its sessions, on its `fork_session` tool, which the SDK's
  `tools.execute` runs and which it marks as experimental, and on `forked_from_session_id`. If any of
  them changes, BriefBar copies the prompt for you to paste instead, as it does whenever the extension
  doesn't answer, and does no harm.

## GitHub

The GitHub source (`Sources/GitHubCore`, `Sources/GitHubUI`) lists your pull requests on github.com.
It's off until you turn it on, like every source, and until then never runs `gh` or connects to
GitHub.

### Signing in

BriefBar uses the GitHub CLI's sign-in, never a personal access token of its own:

```sh
gh auth token --hostname github.com
```

`gh` prints the token it keeps in the keychain (`GitHubCLITokenProvider`). BriefBar keeps it in memory
only, for half an hour, then asks again, in case you signed in as someone else, and asks again right
away if GitHub rejects it. Concurrent requests share one run of `gh`, which is limited to 30 seconds,
with prompts, update checks and colors turned off (`GH_PROMPT_DISABLED`, `GH_NO_UPDATE_NOTIFIER`,
`NO_COLOR`). Turning GitHub off cancels the read that waits for a token: a run of `gh` under way stops
once no request waits for it, and a request that gave up gets no token, so it reaches nothing, not even
memory. It tells a signed-out CLI from other failures by what `gh` prints. **Sign In…** opens
Terminal to run `gh auth login --hostname github.com --web`.

As with `az`, BriefBar looks for `gh` in `/opt/homebrew/bin`, `/usr/local/bin` and the other usual
places, then asks your login shell (`command -v gh`), and both are responsible for themselves (see
[Programs BriefBar runs](#programs-briefbar-runs)). Set `BRIEFBAR_GH` to the path of `gh` to use
another one. Only github.com is read, not GitHub Enterprise Server.

### Where the data comes from

Each refresh is one request: a POST of the same GraphQL query (`PullRequestQuery`) to
`https://api.github.com/graphql`. GitHub's GraphQL API takes reads and writes alike as POSTs, so the
query is fixed text with only its search strings and a count as variables, and a test checks that it
has no mutation. It asks for two searches, 50 pull requests each:

| Search | Provides |
|---|---|
| `is:pr is:open archived:false user-review-requested:@me` | pull requests that ask for your review by name, not a team's |
| `is:pr is:open archived:false author:@me` | your own |

With each pull request come its repository, author, branch (`headRefName`, for [Show Links](#links)), whether it's a
draft, whether it can merge
(`mergeable`), the review decision, the latest review from each reviewer, and the state of its latest
commit's checks (`statusCheckRollup`). The client sends no cookies and keeps no cache
(`GitHubClient.makeSession`). It connects to api.github.com only, and follows no redirect (`RedirectGuard`), so the
token goes nowhere else: one to another host fails with an error that says so, without naming the host
(`GitHubError.redirected`), and one on api.github.com is an HTTP error like any other, as GitHub answers the query where
it's sent.

It refreshes every 2 minutes by default (**Refresh Every** in its settings), when a list opens if the
last read is more than 10 seconds old, and every minute while you need to sign in or are offline, so a
fix shows soon. When GitHub asks it to slow down, it sends nothing until the time GitHub gave:
`Retry-After` for its secondary limits, in seconds or as the date to wait until (`RetryAfter`), the hourly
limit's reset (`x-ratelimit-reset`), or a minute when GitHub only says so in words. At the default, that's 30
requests an hour, a small part of GitHub's hourly limit for the GraphQL API.

When GitHub answers with errors alongside what it could read, such as an organization that uses SAML
single sign-on the GitHub CLI isn't authorized for, the list shows what it read with a note saying
why the rest is missing. An empty list says **All quiet** only when the last read worked and read every
pull request there is (`GitHubStore.isAllQuiet`): not before a read has worked, nor while it says you're
offline, GitHub can't be reached or some pull requests couldn't be read.

### How a pull request's group is decided

`GitHubClassifier` puts each pull request in one group, the first that applies:

- **To Review**: someone asked you, by name, to review it.
- For your own: **Waiting** if it's a draft; **Failing** if its checks fail or it has merge
  conflicts; **Changes Requested** if the review decision says so (or, without one, a reviewer's latest
  review does, a deleted account's too); **Waiting** while its checks run; **Ready to Merge** if it's
  approved (or, without a decision, a reviewer's latest review approves it, a deleted account's too); and
  **Waiting** for reviews otherwise.

A pull request that's both yours and asks for your review is listed once, as yours. To Review and
Changes Requested count as needing you, Failing as something wrong and Ready to Merge as done or
ready; Waiting isn't counted.

### Limits

- Review requests to a team you're in aren't listed, only those to you by name, as with Azure DevOps.
- Only the 50 most recently changed of each search are read; when there are more to review, the list
  has **More on GitHub**.
- Pull requests in organizations that use SAML single sign-on need the GitHub CLI authorized for them.
- There are no notifications, and nothing is saved: the list is read again each time, and kept in
  memory only.

## Agents

`BriefBar --mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server. An agent, such as
the Copilot CLI, starts it and talks to it on its standard input and output: one JSON-RPC 2.0 message a
line, in the protocol's versions from 2024-11-05 to 2025-11-25 (`MCPServer` in `Sources/BriefBarUI`).
It offers tools, and none of the protocol's other features. Only its messages go to standard output:
the file descriptor moves aside first, so anything else printed goes to standard error.

### Off until you turn it on

Like a source, agents are off until you turn them on, in **Settings › Agents**, which says what they
get, where it goes and what they can change. Turning them on saves your consent with the version of
what agents get (`AgentAccess` in `Sources/BriefBarCore`); when an update gives them more, that
version goes up, and they wait until you've seen what they get now, as a paused source does. Until
then, the server starts, so the agent can say what's wrong, but every tool answers that agents are
off, or paused, instead of reading anything. It checks with each call, so turning agents off stops a
server that's already running, in an agent session that's still open. The demo answers with its
made-up data either way.

Turning agents on also adds BriefBar to the Copilot CLI's MCP servers, as `briefbar`, and turning them
off removes it (`CopilotMCPRegistration` in `Sources/CopilotTasks`). The GitHub Copilot app's sessions
use the same servers. BriefBar runs the CLI's own `copilot mcp get`, `add` and `remove`, with your
login shell's environment, so it finds the CLI and its `COPILOT_HOME` as Terminal does, and never
reads or writes the CLI's configuration itself: other servers' settings are there, tokens included.
Turning agents on replaces a server that runs another copy of BriefBar, such as one you built, with
this one; afterwards, the page offers **Use This Copy** when the CLI runs another. Turning agents off
removes whichever copy it runs. A server named `briefbar` that isn't BriefBar stays as it is. Turning
them off also removes BriefBar's plugin and its extension for the app's sessions, if you installed them
([below](#its-copilot-plugin)); turning them on never installs either. If the CLI can't remove any of
them, the page says so while agents are off, with **Try Again** ([below](#its-copilot-plugin)).

The page's **Install** lists the agents' apps on your Mac that BriefBar can be installed in (`AgentApp` in
`Sources/BriefBarCore`), as LaunchServices finds them by bundle identifier. Visual Studio Code and
Cursor each get the install link their own link generators make, with BriefBar's binary and `--mcp`:
`vscode:mcp/install?` and the server as JSON, and Cursor's `anysphere.cursor-deeplink/mcp/install`
with it in Base64. Both decode the link's query twice, so a `%` for VS Code, and a `+` in Cursor's
Base64, are encoded twice. The app shows what it would add and asks you first, and keeps it in its
own settings, which BriefBar never reads or writes: BriefBar can't tell whether it's there, and
turning agents off doesn't remove it, but then its tools answer that agents are off. The GitHub
Copilot app has no such link; its sessions use the Copilot CLI's servers, so **GitHub Copilot** adds
BriefBar there, as above, and is checked once the CLI has it. **Copy Command** copies the command for
any other agent. The demo and `--render` list all three, and the demo opens none.

### What it answers

It's a command-line mode like `--json`, with the same rules:

- It runs with the permissions of whoever started it: the Copilot CLI's in Terminal, or the GitHub
  Copilot app's for its agents (see [Programs that start BriefBar](#programs-that-start-briefbar)).
  Started as an app, it refuses.
- It serves the sources that are on in the app, and checks with each call: turn one off, and its tools
  say so instead of answering. `--source` narrows them, and never adds one that's off. Each source gives
  its own tools (`SourceCommandLine.mcp`), and `needs_me` asks all of them at once. Teams gives none:
  its chats come from what only Full Disk Access reads, and what a tool answers goes to the agent's
  model, which may run in the cloud. GitHub gives none either: its pull requests aren't offered to agents.
- A source's tool asks the others what they know of the things it names (`MCPRelated` in
  `Sources/BriefBarUI`), so the sources stay apart: Azure DevOps never reads Copilot's files, nor
  Copilot Azure DevOps, but for what Send Work to Copilot reads in the app too, while it's on: the
  session `pull_request` names (below). A source tells of its own things through its teller
  (`MCPSource.related`), and `MCPSource.tools` gives each tool every source's teller while it runs, in a
  task-local value, so no tool's signature changes. A teller answers only while its source is on:
  `available(while:refusal:)` refuses it as it refuses the source's tools, and the tool that asked says
  so in a line rather than failing. `--source` leaves the others out, tellers and all.
- Azure DevOps reads as the app does, with its organizations, its settings and what you've seen and
  taken off Needs You in it, so the groups match the menu bar's, and like the other modes it leaves out
  pull requests sent in chats. In Needs You, what you've seen that still waits on you says so. One
  `PulseEngine` serves the whole session (`AzureDevOpsReader`): a tool reads again only
  when what it has is a minute old, as the app does at its most often, so calls one after another share
  a read. A read that failed in a way you can fix, such as a sign-in that expired, isn't kept, so the
  next call reads again. The pinned pipelines and the sprint are read the same way, when a tool needs
  them. Each read runs on its own, so a call the agent cancels doesn't cut short what the next one gets.
- Copilot's sessions come from the app's database and the sessions' logs, as `--json` reads them. For
  another source's tool, it also reads where each session's work goes (`SessionLinks`) and, for the
  sessions it tells of, what Copilot recorded of their work (`SessionAccount`), whether Show Links is on
  or not.

`pull_request_prompt` gives the prompts of a pull request's Copilot actions (see
[Send work to Copilot](#send-work-to-copilot)), told to work in the agent's checkout rather than a
worktree: fetch the branch and check it out, or ask where to work if that isn't a clone of the
repository or has changes of its own. Push & Reply, for one of yours, first checks that HEAD contains
the pull request's branch and that everything it would push was made for it, stops and asks if not,
and never rebases. For a failed build, it reads each run's timeline first, with a GET, rather than what the details read
of it. The Copilot
CLI's `--deny-tool` rules don't come with it: the agent's own permissions apply.

While **Send Work to Copilot** is on, `pull_request` also names an open pull request's session: the
Copilot session BriefBar sends its work to, as its details show it (see [A pull request's
details](#a-pull-requests-details)), by its name and session ID, with why and where it is, and whether Copilot
still works in it. It's found the same way (`CopilotTasksStore.pullRequestSession`, with `PullRequestSession`):
the session you chose for it, unless a task started on it since; else its last task's session; else the session
of the work item's task that opened it; else the Copilot app's session that the app records with it, that you
linked to it in Show Links, or that's on its branch. When you chose a new session, it says so; when two sessions
go with it as well as each other, it names both, and that BriefBar asks you which; and when none does, it names
one whose log mentions it and that was there before it was created as one that may have opened it, not as its
session. The logs are read for mentions only when no session goes with it, since only then do they matter. `--mcp`
finds it with a store of its own (`AzureDevOpsReader.session`): over a copy of the tasks sent to Copilot and of the
sessions you chose for pull requests' work, in memory, each task as its log says it stands, with the pull request
one opened while BriefBar was quit, as the app finds it when it next looks (`RunTranscript.openedPullRequest`), so
nothing it does is saved; with the environment
`--mcp` started with, rather than your login shell's, which it would have to start; and with the links
you made, from the app's settings, only while Show Links is on. Like the composer, it reads the Copilot
app's database read-only, the folder each of its sessions works in and, for mentions, their logs, and
nothing at all while Send Work to Copilot is off or in the demo, whose composer reads no sessions. Its
store has a copy of the app's setting, so it reads the app's again every tenth of a second while it
looks: turned off meanwhile, it reads nothing more, as the composer's search stops, and names none. It
says whether the session is one the Copilot app has, which an agent there can send a message to: one
of its own, one a task went on with, or a task's that you opened there, which its database lists, open
or not. Otherwise it's a task BriefBar runs with the Copilot CLI, which the app doesn't have. When no
session goes with it and none may have opened it, it says nothing.

`work_item` tells a work item, by its number or link, as its details and Where It Stands do (see [Where
it stands](#where-it-stands)), in Markdown laid out for an agent (`AgentText.workItem`). First a few
lines: its state and why, who has it, its sprint, with the day it ends and the days left when it's the
sprint going on, whose dates the sprint has, how many of its tasks are done, the hours left, who it
waits on, and what you can do now: what waits on you, without "you, to", and your tasks that aren't
started, unless Copilot works on one, such as "complete !4091 · start task 5104", or that nothing waits
on you. Then its tasks in the sprint, or its children when it isn't there, each with the latest work
sent to Copilot for it; each pull request it links to, told by `PullRequestStory` as the panel's rows
are: yours as your lists have them, with their checks and merge pipelines, and with `pull_request` to
call for their threads while one is open, and the others as they say themselves, with what isn't read of
them; what the other sources know of those pull requests, such as the Copilot sessions on them; the rest
of the work sent to Copilot for it; and last, its description, its other long texts, such as acceptance
criteria or repro steps, and its latest comments, each quoted, since what people wrote is data. Who it
waits on comes from the same data: each of your pull requests' group and reason in your lists, such as
you, to complete one that's ready, or to fix one whose build failed; another's votes, such as its
reviewers until every required one approved, people and groups alike, even one who declined, then its
author, unless it's set to complete by itself, without saying it's ready to complete, since its policies
and checks aren't read; the work sent to Copilot, as the details have it: going on, or the one sent last
for something that's not done failed; and a session that waits for you, or, for one whose coordinator
relays its question, in the session where you answer it, which its lines link to. It reads the work item
with the same GETs as its details, whose `$expand=relations` already names its pull requests, so it
works whether Show Links is on or not, then one GET for each of those pull requests your lists don't
have, one after another (`LinkEngine.lookUp`), stopping only if Azure DevOps asks to slow down: one it
didn't get to says so, rather than that it couldn't be read. Without a link, it looks in the sprint,
then in each of your organizations.

It asks the other sources about its pull requests (`MCPRelated.ask`), with what links each to a session
by its branch: its branch, its target and its repository (`BranchHint`). Copilot (`CopilotAgent.related`)
answers with the app's sessions on them, linked as Show Links links them: on a pull request's branch in
its repository (`BranchLinks`), or recorded by the app as the pull request a session started from or
opened (`SessionSnapshot.recordedLinks`); the ones that need you first, then the newest. For the first
five, it reads what Copilot recorded of their work (`SessionAccount`) and tells it briefly: the latest
checkpoint's overview, cut to its first sentences, its first next step, and what the session said last
when that came after; once it stopped, what it said then is how it ended, and the next step it planned
at its checkpoint is left out. The rest are named. A session BriefBar sent work to is told with that work. When
Copilot is off in the app, the answer says so in a line; with `--source ado`, there's no Copilot to ask.

The tools that change something change only BriefBar's own lists, as its menus do:
`watch_pull_request` and `stop_watching_pull_request` the pull requests you watch, and `pin_pipeline`
and `unpin_pipeline` the pinned pipelines. A pull request is read right after it's watched, and if
it's closed or you can't read it, it isn't watched after all. They write the app's preferences, then
post a distributed notification that says only that something changed (`AgentChanges`), since any
program can see it go by, so a running BriefBar reads those two lists again at once, and again when
Azure DevOps starts. The demo keeps them in memory.

### Its Copilot plugin

BriefBar's plugin for Copilot (`Resources/CopilotPlugin`) gives the GitHub Copilot app's sessions, and
the Copilot CLI's, one skill, `briefbar`, which the app offers as **/briefbar**. It's text that says how
to use the server's tools there: it adds no tool, runs no code and reads nothing itself, so agents get
nothing more, and `AgentAccess`'s version stays as it was.

**Installing it.** Only **Install**, on the Agents page once agents are on, installs it; turning agents
off removes it (`CopilotPluginRegistration` in `Sources/CopilotTasks`). As for the server, BriefBar runs
the CLI's own commands, with your login shell's environment, and never reads or writes the CLI's
files. `copilot plugin marketplace add` registers the folder in BriefBar.app that holds its plugins,
`Contents/Resources/CopilotPlugin`, as a marketplace named `briefbar`, and `copilot plugin install
briefbar@briefbar` turns the plugin on. The marketplace has BriefBar's other plugin too, its extension
for the app's sessions ([below](#its-extension-for-the-apps-sessions)), which **Send Prompts to Copilot
Sessions** installs the same way, as `briefbar-sessions@briefbar`: each is installed and removed on its
own. The CLI loads a plugin from a marketplace on this Mac where it is, without copying it, so the
plugin is the one in the app: an update to BriefBar updates it for the sessions that start afterwards.
The build adds BriefBar's version to each, and `scripts/check-app.sh` checks that. Removing one turns it
off first, with `copilot plugin uninstall`, so that it doesn't come back on with its marketplace, then
removes the marketplace, unless BriefBar's other plugin is on, which keeps it, and without `--force`:
that would uninstall whatever else the marketplace has, so the CLI refuses instead if it has a plugin it
copied, and says which. What the page says
comes from `copilot plugin list --json`, whose `installedFrom` is the folder the plugin loads from, and
`copilot plugin marketplace list --json`. The CLI lists every plugin of a marketplace on this Mac,
installed or not, turned off unless it was turned on, so one of BriefBar's that's off while the other is
on counts as not installed. A marketplace's name, and its folder's, prove nothing, as
anyone can choose them, so BriefBar changes one named `briefbar` only if it's this copy's, or the
`Contents/Resources/CopilotPlugin` folder of an app whose bundle identifier is BriefBar's, as it reads it
in that app's `Info.plist`: another copy of BriefBar, such as one you built, which **Use This Copy**
replaces, with whatever of BriefBar's was on there. It leaves any other, and one in an app that's no
longer there, and says how to remove it yourself. Opened where it was downloaded, BriefBar runs from a
temporary copy (App Translocation), and doesn't install the plugin from there.

**Turning agents off.** BriefBar removes its MCP server and its plugins from the CLI. Agents are off
then, so the page shows only what's still going on: removing them, and what the CLI couldn't remove,
with **Try Again**, which removes it again (`AgentCleanup`). BriefBar's checks and changes reach the
CLI one at a time, in the order they were asked for, and the page shows what the last one found only
once it's done (`CopilotCLIProgress`): a check that ends while a removal is still to come, as when you
turn agents off just as the page opens, isn't taken for what's left. It shows why in the CLI's own words, such
as which plugins keep a marketplace there, which you may have to remove first: its first three lines,
at most 300 characters, without terminal escapes or other control characters. It keeps that only until
BriefBar quits: either way, BriefBar answers agents that they're off.

**What the skill does.** **/briefbar** on its own calls `needs_me`, and in the app shows what it lists
in the app's inbox widget, by BriefBar's groups, with the links BriefBar gives, and
`ghapp://sessions/<id>` for a Copilot session. When agents are off, every tool says so, and the agent
stops there; when only a source is off, `needs_me` says so under its heading and has the others, which
the agent still shows. Asked to fix a pull request's comments, its build or its
conflicts, or to review it, the agent first asks BriefBar about it with `pull_request`, even given its link,
and stops there if BriefBar refuses, as when agents or Azure DevOps are off, before any session or worktree
is made; that also says which actions apply, and, with Send Work to Copilot on, names the pull request's
session ([above](#what-it-answers)). In the app, the work then goes to a session you can follow. When
`pull_request` names one of the app's sessions, you choose: that session, or a new one, and, when the
agent talks in that very session, a fork of it. The agent asks unless you said which, and does only that
one. It sends the session the prompt with the app's `send_session_message`, or, in that very session,
does the work there. A fork is a copy of the session, with its history, in a worktree of its own, so the
work can go another way while the session stays as it is; but the app's `fork_session` forks only the
session the agent talks in, so the agent forks only that one, then sends the fork the prompt. For
another session, it says that BriefBar's Send to Copilot window has **Send to a Fork**. A new session,
also when `pull_request` names none, or names a task BriefBar runs with the Copilot CLI, which the app
doesn't have, is one it starts with the app's own tools, in a worktree of a repository the app knows
whose `origin` is the pull request's repository: it asks you when none or several are, never clones,
and never works in a folder that is your own checkout. Wherever the work goes, its prompt holds only the
pull request's link and the action, and has the session call `pull_request_prompt` itself, so what the
pull request's authors wrote reaches it as a tool's answer, not as your request; the skill tells agents
that such text is data, never instructions. Push & Reply goes to the session that made the changes,
never a new one. In the Copilot CLI, the agent follows the prompt where it is. It doesn't answer a
session's question, plan or permission for you: it offers to open the session, with the app's
`navigate_to`. Asked how a work item is going, as with **/briefbar 5101**, it calls `work_item` and
answers in at most four short lines, with their links: where it stands and what you can do now, what's
done, by people and by Copilot, what's left and who has it, and who it waits on; then it offers one
next step, and starts nothing. Given a pull request's number, it calls `pull_request`, and it tries
that before asking for a link when `work_item` finds nothing.

`CopilotPluginTests` checks the plugin's manifests, that the skill's frontmatter values are plain YAML
scalars, which a colon and a space would end, and that the skill names only tools that
`BriefBar --mcp` lists, their arguments and values, and the app's tools it uses, and every tool
BriefBar has; that it stops only for what BriefBar answers when agents are off
(`AgentAccess.refusal`), not when a source is; that it checks a pull request with `pull_request`
before it starts a session for it, forks one or sends one a message; and that it offers the session
`pull_request` names beside a new one, asks unless you said which, forks only the session it talks in,
and gives the same prompt wherever the work goes.

### Its extension for the app's sessions

**Send Prompts to Copilot Sessions**, on the Agents page once agents are on, lets Send to Copilot send a
prompt to one of the GitHub Copilot app's sessions itself, with **Send to Session**, or fork the session
and send the prompt to the fork, with **Send to a Fork**, rather than copy it for you to paste
([Send work to Copilot](#send-work-to-copilot)). The app's
links only open a session, and an MCP server only answers a tool call, but an extension can: the
Copilot SDK's extensions are processes that the app's runtime starts in each session it has open, which
join that session (`joinSession()`) and can send it a message (`session.send`). So BriefBar's second
plugin, `briefbar-sessions` (`Resources/CopilotPlugin/briefbar-sessions`), holds one extension and
nothing else: no skill, tool, hook or command. Agents get nothing more, and `AgentAccess`'s version
stays as it was.

**Turning it on.** It's off until you turn it on, as anything is that not everyone would want: then the
page installs the plugin with the CLI's own commands, as **Install** installs the other
([above](#its-copilot-plugin)), and turning it off, or turning agents off, removes it
(`CopilotPluginRegistration`, for `.sessions`). BriefBar keeps whether it's on, as the CLI last said,
in its preferences (`CopilotSessionPrompts`), and sends prompts to sessions only while it is. The app's
runtime starts the extension in the sessions that start after it's installed, at once, but those already
open get it only once they start again; and turning it off doesn't stop it in the sessions that are
open, until they start again, so BriefBar stops sending at once, whatever the CLI says. Each session
the app has open runs it as a process of its own, of about 46 MB. The plugin's manifest is in the Agent
Plugins 1.0 format, as the other's is, where the runtime reads an extension only from the app's own
folder: `com.github.copilot/extensions/briefbar-sessions/extension.mjs`. Tried with the runtime of the
GitHub Copilot app 1.1.34: a plugin loaded in place from a marketplace on this Mac runs its extension
there, one that's listed but not installed doesn't, and a root `extensions` folder isn't read.

**What it does.** It acts only on the requests BriefBar writes for its own session, in the files that
**Sending to a session, or a fork of it** describes ([Send work to Copilot](#send-work-to-copilot)), and
nothing else: no network, no other program, and nothing logged. It uses only folders and files that
are yours and only yours, as BriefBar does, and follows no link below your home folder.

- Once it has joined its session, it says so in `listening`, and stops saying so when it stops: when
  the runtime stops it, or goes away and so ends its connection.
- It watches `requests` (`fs.watch`), and takes only its own session's, oldest first. It claims one by
  renaming it, so that each is handled once, by one extension. Then it reads it, without following a
  link, and acts on it only if it's a regular file that only you can read, of 256 KiB or less, in version
  1 of the format, with every field valid, for its own session, and not expired: made at most 120 seconds
  before it expires, and not past that.
- A `send` hands its prompt to `session.send`, which queues it while a turn runs. It's your own message
  in the session: one more turn, with the session's model, mode and permissions.
- A `fork` runs the app's own `fork_session` through `session.rpc.tools.execute`, with no model turn,
  and says which session is the fork, from what the tool answers: the app records it as the original's
  fork, with its history and its uncommitted changes, in a worktree of its own, and the original gains
  only a note that it was forked. The fork's runtime, and its extension, start at once, so BriefBar then
  sends the prompt to the fork through the fork's own extension. A fork takes about 20 seconds.
- Last, it writes the result, never with the prompt: done, with the message's ID or the fork's session's,
  or why not: `invalid`, `expired`, `send_failed`, `fork_unavailable` where the session doesn't offer the
  app's fork, as a chat may not, or `fork_failed`, where the fork failed or Copilot couldn't say how it
  went, so that a fork may exist. It writes it once `session.send` or the fork is done, however long that
  takes. Then it removes the request it claimed, if BriefBar hasn't removed it already, as turning Azure
  DevOps off does.
- As it starts, it removes the requests of its session that an extension which ended mid-request had
  claimed, since they hold prompts.

`Tests/CopilotPlugin` tests it with Node's test runner, with made-up sessions and requests in an outbox
in a temporary folder, and the extension as the runtime starts it, with a stand-in for the SDK's
`joinSession` (`make plugin-test`, which CI runs). The tests aren't in BriefBar.app, which ships only the
extension, as `CopilotPluginTests` and `scripts/check-app.sh` check.

## Desktop widgets

Each widget is a window of BriefBar's own (`DesktopWidgetController` in `Sources/BriefBarUI`). A new
one goes in the top-right corner of the screen, below the widgets already there.

### Why not a WidgetKit widget?

WidgetKit widgets are drawn by the system from a timeline, and the system **budgets** how often
they can reload. Per Apple's [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date),
a frequently viewed widget typically gets 40–70 refreshes a day, "roughly every 15 to 60 minutes".
That is the delay you see with polling-based widgets.

- `WidgetCenter.reloadAllTimelines()` doesn't avoid that. A reload requested by a background app
  counts against the budget. The exceptions are narrow, such as the containing app being in the
  foreground.
- [Widget push updates](https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications)
  through APNs are "budgeted … and delivered opportunistically" as well. They also need a server,
  push entitlements and a paid developer account.
- Third-party widget hosts such as Pushcut or Scriptable are WidgetKit widgets themselves, so they
  have the same limit. Shortcuts and App Intents run from a script don't avoid it either.

Copilot hooks aren't needed: the app and the agent already write every state change to disk,
so watching those files sees changes without changing any Copilot configuration.

So BriefBar uses a different approach: a borderless, non-activating panel drawn by the app
itself. It sits at desktop level (behind windows, on every Space) and is styled like a macOS
widget. A running app can redraw its own window whenever it likes, so there is no refresh budget.

The trade-offs:

- it isn't in the system widget gallery or Notification Center,
- it doesn't follow the desktop widget tinting, and
- the app must be running (that's what Launch at Login is for).

A WidgetKit extension also needs Xcode to build, and this project builds with the Command Line
Tools alone.

## Signing

macOS records each Full Disk Access grant, and the access list of the keychain item that protects
Teams' saved chats, with the app's **designated requirement**: the part of its signature that says
how to recognize it again. It checks the running app against it.

- An ad-hoc signature's designated requirement is its code hashes (`cdhash H"…"`). Apple's
  [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
  puts it this way: ad hoc signed code "has a DR but it's tied to that specific version of the code",
  so "macOS can't track this authorization across versions of your app". Every build loses Full Disk
  Access, although System Settings may still show the switch on. macOS keeps the requirement of the
  build you allowed, and turning the switch off and on keeps it too: remove BriefBar from the list, or
  run `tccutil reset SystemPolicyAllFiles com.asaf.BriefBar`, which resets only BriefBar's entry, and
  add it again.
- Signed with a certificate, the requirement names the certificate instead:
  `identifier "com.asaf.BriefBar" and certificate leaf = H"<the certificate's hash>"`. A rebuilt app
  with different code hashes still satisfies it, so macOS keeps the access.

Builds from source are signed ad hoc (`scripts/build-app.sh`, through `scripts/sign-app.sh`), with the
hardened runtime and no timestamp, so signing makes no network request. Each build needs Full Disk
Access again, but there's no key on the Mac that anything could sign as BriefBar with. The keychain
item for Teams' unread chats trusts the app by its signature too, so macOS may ask whether a new build
may use it; declined, the saved chats are left alone.

### An optional certificate for builds from source

`scripts/make-signing-identity.sh` (`make signing-identity`) creates a certificate, **BriefBar
Signing**: self-signed, for code signing only, valid for 10 years, in the login keychain.
`scripts/build-app.sh` then signs every build with it, so Full Disk Access survives rebuilds. Nothing
has to trust the certificate: macOS matches the certificate itself. `--delete` deletes it and its key,
and builds are signed ad hoc again.

Matching a certificate is only as strong as the private key behind it: anything that can sign with
the key can sign itself as `com.asaf.BriefBar`, satisfy the requirement, and get the Full Disk Access
you gave BriefBar. So no app may use the key without asking, and nothing can take it:

- `security import` can't make such a key. With `-T /usr/bin/codesign`, codesign may use the key
  silently; without it, `/usr/bin/security`, the app that imported it, may. Either way, any program
  running as you could have it sign. `scripts/signing-key.swift` imports the key with an access list
  that trusts no app, so codesign asks for your login password every time, and as non-extractable, so
  it can't be exported even with the password. It then reads back what macOS made of it, and if that
  isn't so, `scripts/make-signing-identity.sh` deletes the certificate again.
- **Always Allow** in that prompt would add codesign to the list. `scripts/build-app.sh` reads the
  list before every build, and again after signing (without prompting), and refuses to go on while
  any app is on it or the key can be exported; after signing, it deletes the build.
  `scripts/make-signing-identity.sh --replace` swaps such a certificate for a new one, and `--check`
  reads the list. Any program can make codesign ask, too, so allow the prompt only while a build of
  yours is signing.
- It signs with the certificate's SHA-1 (`sign_with` in `scripts/signing.sh`), never its name, which
  could also match a look-alike or an identity preference, and then checks that the signature names
  that certificate. Every check that fails stops the build.
- It signs the updater, then the app, so each build uses the key twice, and asks twice.
  Sparkle.framework is signed ad hoc: with library validation off (below), the updater loads it
  whoever signed it, and the updater's own signature records its exact code hash.
- The certificate and its key are made in memory, with macOS's own `openssl`, and reach the keychain
  through a pipe, never a file.

`scripts/test-signing-key.sh` (`make signing-key-check`) checks all of that in throwaway keychains,
with nothing that makes macOS ask. Only CI's throwaway keychains (`scripts/ci-signing-identity.sh`)
let codesign use their key without asking, since nothing could answer a prompt there. Don't give a
build signed with one Full Disk Access.

### Releases

Releases are signed with a certificate too, all with the same one, **BriefBar Release**, which isn't
on any Mac. `scripts/make-release-keys.sh` makes it in memory, once, for the `release` environment's
secrets and the maintainer's password manager, so only the release workflow's approved job can sign
with it. That job imports it into a keychain of its own (`scripts/import-release-identity.sh`), where
only codesign may use it and nothing can export it, and signs the updater and the app with it
(`scripts/sign-release.sh`). It checks that the signed app has the designated requirement in
`Resources/ReleaseRequirement.txt`, so a release can't quietly cost everyone their access, and that the
updater's names the same certificate, then deletes the keychain. `scripts/check-app.sh`
fails if a release's requirement names code hashes. CI, and the release's build job, sign with a
throwaway certificate instead.

Changing the certificate, or the bundle identifier, loses Full Disk Access once: remove BriefBar from
the list (or reset its entry with `tccutil`, as above) and add it again. That's also what happens when
a copy you built updates itself to a release.

### The hardened runtime and library validation

BriefBar and its updater run with the hardened runtime, so other processes can't use BriefBar's Full
Disk Access by injecting code into them: macOS ignores `DYLD_` environment variables for them, such as
`DYLD_INSERT_LIBRARIES`, and doesn't let debuggers attach. That takes System Integrity Protection,
which is on unless you turn it off: with it off, macOS doesn't stop programs from loading code into
BriefBar, or into any other app, and BriefBar can't prevent that.

The hardened runtime also turns on library validation, which loads only libraries signed by Apple or by
the app's own team. A self-signed certificate has no team, so macOS would refuse Sparkle, even signed
with the same certificate ("mapping process and mapped file (non-platform) have different Team IDs").
And macOS recognizes an app by its own executable's signature, so an app with library validation off
loads whatever its frameworks hold: anything running as you could copy the app anywhere, put its own
code in the copy's framework, and run that code with the app's permissions. An app that loaded Sparkle
itself would need library validation off, and have that hole.

So library validation stays on in BriefBar: it has no entitlements, and links only Apple's libraries,
by their full paths, with no run path and no `Frameworks` folder. Sparkle is in an app of its own
inside BriefBar, `Contents/Helpers/BriefBar Updater.app` (`Sources/BriefBarUpdater`), whose one
entitlement, `com.apple.security.cs.disable-library-validation` in
`Resources/BriefBarUpdater.entitlements`, turns the check off there only. Code put in the updater's
Sparkle.framework runs as the updater, which has none of BriefBar's permissions: it has its own bundle
identifier, `com.asaf.BriefBar.Updater`, which you don't give any, and BriefBar starts it responsible
for itself ([above](#programs-briefbar-runs)). Its only run path is its own `Frameworks`: one that named
the toolchain's or the build's folder would be a place to put a look-alike library. A Developer ID
certificate, which has a team, would let Sparkle load with library validation on.

`scripts/test-updater-isolation.sh` shows it on a copy of a build that macOS opens: BriefBar loads only
Apple's libraries, and an ad-hoc library put in place of Sparkle, in the updater and in BriefBar's own
`Contents/Frameworks`, and named by `DYLD_INSERT_LIBRARIES`, runs only in the updater, which macOS
holds responsible for itself. `BriefBar --check-updater` reports the same about any copy, listing every
library loaded into BriefBar but its executable, which it tells by its Mach-O header: dyld lists a
library that `DYLD_INSERT_LIBRARIES` inserts before the executable. With System Integrity Protection
off, as on GitHub's runners, that variable loads code into any app, so there the test leaves it out,
and puts the library only in Sparkle's places; it prints `csrutil status`, and says which it did.

## Updating the app

BriefBar updates itself with [Sparkle](https://sparkle-project.org) 2, in its updater,
`Contents/Helpers/BriefBar Updater.app`, which embeds `Sparkle.framework` without the XPC services that
only sandboxed apps need (`Sources/BriefBarUpdater`). BriefBar starts the updater when it starts, if it
has an update key, and they talk in one line of JSON at a time through the updater's standard input
and output (`Sources/BriefBar/Updater.swift`): BriefBar asks it to check, or to check automatically or
not, and takes from it only whether a check can start, whether checks are automatic, and a version to
show. Sparkle updates BriefBar.app, whose `Info.plist` has the feed and the key, keeps its settings in
BriefBar's preferences, and shows its own windows, with BriefBar's name and icon. To install, its
installer quits BriefBar, replaces the app, the updater with it, and opens it again. The updater quits
when BriefBar does.

- **Only if you allow it.** Sparkle asks on the second launch whether to check automatically, and
  then checks once a day. **Check for Updates…** checks right away. A build without `SUPublicEDKey`
  in its `Info.plist` never checks, and has no update settings, and neither do the command-line modes,
  `--demo` or `--render`.
- **What it fetches**: `appcast.xml` from
  `https://github.com/mnsn/brief-bar/releases/latest/download/`, and the zip that it names. These are
  BriefBar's only network requests apart from the Azure DevOps and GitHub sources'. They send no
  cookies, and the same `Accept-Language` for everyone, and Sparkle's anonymous system profiling stays
  off.
- **What it accepts**: only an appcast and a zip signed with the project's EdDSA key, and it checks the
  zip before unpacking it. The appcast requires arm64 hardware and the macOS the app needs
  (`LSMinimumSystemVersion`), so existing Intel installs aren't offered an incompatible update, and a
  Mac on an older macOS keeps the version it has.
  [SECURITY.md](../SECURITY.md#how-updates-are-verified) has the details.
- **Gently**: right after launch, Sparkle shows a new version itself. A later, scheduled check doesn't
  take the focus from the app you're using: the updater tells BriefBar, and the lists, the window and
  every gear menu say that an update is waiting instead.
- **Full Disk Access survives**, because every release is signed with the same certificate.
- **Installed with Homebrew**, it updates itself all the same. The cask, in
  [mnsn/homebrew-tap](https://github.com/mnsn/homebrew-tap), says so (`auto_updates`), so
  `brew upgrade` leaves it to the updater unless you add `--greedy`. The release workflow points the
  cask at each release, with its zip's SHA-256 (`scripts/update-homebrew-cask.sh`).

## Checks

- `make test` runs every module's tests, with made-up data, and with a single thread in Swift's
  cooperative pool (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`), so that code that blocks a thread of it
  while waiting for async work hangs on any Mac, not only on one with few cores.
- `make plugin-test` runs the tests of BriefBar's extension for the Copilot app's sessions
  (`Tests/CopilotPlugin`), with Node's test runner and a stand-in for the Copilot SDK
  ([Its extension for the app's sessions](#its-extension-for-the-apps-sessions)). CI runs it too.
- `make demo-check` checks that every source's made-up data lands in the expected groups, and in the
  expected states, each section's and all of them added up. It runs the same checks the Pulse apps ran
  on their demos.
- `scripts/check-boundaries.sh` reads each module's object files and fails unless only
  `AzureDevOpsCore` and `GitHubCore` use networking APIs, and only `BriefBarCore` starts programs. It
  also fails if those stop using them, since the check could no longer tell. It reads BriefBar's own
  modules, the updater's included, not Sparkle, whose requests are only for updates.
- `WriteTests` checks that the only changes BriefBar can make in Azure DevOps are those `ADOWrite` lists, each as it's
  sent, and that nothing else in `AzureDevOpsCore` makes a request or sets a method but GET
  ([Replying and setting a thread's status](#replying-and-setting-a-threads-status),
  [A pull request's tags](#a-pull-requests-tags)).
- `scripts/check-app.sh` checks a built app: its signatures and the hardened runtime; that BriefBar has
  no entitlements and links only Apple's libraries, with no run path or `Frameworks`; that the updater
  has its own identity, the one entitlement, the same signature as BriefBar, and Sparkle in its own
  `Frameworks`, without the XPC services, with its license and arm64 code; that BriefBar and its updater
  contain only arm64 code; a designated requirement that names a certificate, unless `--allow-ad-hoc`
  says a build of your own may be ad hoc; the update settings (the feed, the signed-appcast keys, and
  with `--release` the public key); that BriefBar and its updater need the macOS its `Info.plist` says,
  which the appcast says too; its Copilot plugins, at its own version, without their tests; and that it
  runs, starts the updater, which loads Sparkle, and passes the demo check.
- `scripts/test-updater-isolation.sh` (`make updater-check`) shows, on a copy of a build that macOS
  opens, that the updater is responsible for itself and that other code in place of Sparkle never runs
  as BriefBar ([above](#the-hardened-runtime-and-library-validation)). CI runs it on every package.
- `scripts/update-rehearsal.sh` (`make update-rehearsal`) installs an update through the updater, the way
  an installed copy gets one: a copy at version 0.9.0, with a bundle identifier of its own, checks a feed
  on the Mac signed with a throwaway key, downloads 0.9.1 and installs it, updater included, and the
  designated requirement stays the same. CI runs it on every package.
- `make signing-key-check` checks, in throwaway keychains, everything that keeps a signing key safe
  (above).
- `scripts/test-homebrew-cask.sh` (`make homebrew-cask-check`) runs the release workflow's last step,
  `scripts/update-homebrew-cask.sh`, against a tap of its own, with no network and no key: it sets the
  cask's version and SHA-256 in one commit, the same release again changes nothing, an older release
  never replaces a newer one, and it refuses another zip for the same version. CI runs it.
- `scripts/appcast-dry-run.sh` signs a packaged app's update and appcast with a throwaway key, the way
  a release does, and checks them as the app would.
