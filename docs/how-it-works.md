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
[FAQ in the README](../README.md#why-did-clicking-briefbar-switch-my-other-displays-space) explains.
With nothing on, or every section hidden, BriefBar shows its own icon, whose menu opens Settings.

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
([FAQ](../README.md#why-did-clicking-briefbar-switch-my-other-displays-space)), whose windows would cover
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
  sent from, and with the pull request it opened, which goes with the work item too.
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

**Your edits.** Linking adds a link of your own. Unlinking takes it away, or, for a link a source knows, hides it in
BriefBar until you choose **Show Hidden Links**; hiding a pull request's link hides what's linked through it too.
Nothing goes back to Azure DevOps, GitHub or Copilot: BriefBar never writes there. The edits are kept in the
preferences (`links`) as references only, never titles; those older than 180 days are forgotten, and turning a source
off forgets the ones about its things. A reference another program writes there is checked as BriefBar's own are, or
left out.

**What's read for it,** only while it's on:

- Azure DevOps (`LinkEngine`, with the pull requests' client, after each of their refreshes; every request a GET): each
  of your pull requests' work items, then every quarter of an hour; the sprint's work items with their relations, while
  the sprint is on screen; and what the linked work items and pull requests that no list shows are, so their rows can
  say it. The [table below](#where-the-data-comes-from-1) has the requests.
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

The [table in the README](../README.md#microsoft-teams) lists the rules. In more detail
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
- Without Apple Intelligence (before macOS 26, on a Mac that can't run it, or with it turned off),
  the setting says why. An unsupported language, a refusal or a busy model shows a short note
  instead of a summary.
- FoundationModels is linked weakly, so the app still opens on macOS 15. Built with an SDK that
  doesn't have it, such as Xcode 16's, the app leaves the summarizer out, and the setting says that
  summaries need a build made with the macOS 26 SDK.

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
  why. If Teams' folder has no `conversations` store, or none of its conversations has a marker
  BriefBar understands, the lists say Teams' read markers have changed; if more than a quarter can't
  be read, or a file can't, they say some couldn't be read. A table counts only after it has stayed
  unchanged and unreadable for at least 5 s: LevelDB writes a table where it'll stay, so one being
  written reads as broken until it's done. Each read rechecks those table paths, so finishing or
  removing one clears its warning even if the current log hasn't changed. Neither keeps the lists
  from showing: chats you read in Teams then stay
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

All requests are GETs to the Azure DevOps REST API (version 7.1):

| Request | When | Provides |
|---|---|---|
| `_apis/connectionData` | once per organization, and again when you sign in as someone else | your identity ID and name |
| `_apis/git/pullrequests?searchCriteria.creatorId=…&status=active` | every refresh | your active pull requests, across all projects |
| `_apis/git/pullrequests?searchCriteria.reviewerId=…&status=active` | every refresh | the ones you review |
| `_apis/git/pullrequests?searchCriteria.creatorId=…&status=completed&minTime=…` | every refresh | yours completed in the Done window |
| `{project}/_apis/policy/evaluations?artifactId=vstfs:///CodeReview/CodeReviewId/{project}/{id}` | per pull request | builds, status checks, reviewer and other policies |
| `{project}/_apis/git/repositories/{repo}/pullRequests/{id}/threads` | per pull request | comment threads, and activity: pushes, votes, reviewer changes |
| `{project}/_apis/build/builds/{id}/timeline` | once for each failed build of your pull requests, and again if it's retried and fails again: four a refresh; one that can't be read is tried again on the next refresh, then less and less often | where the build failed, and the first error there |
| `{project}/_apis/build/builds?repositoryId=…&branchName=…&minTime=…` | after you merge a pull request (below): every refresh for half an hour, while one of its runs hasn't finished, and for a quarter of an hour after the last one did; five merges a refresh, the newest first | its target branch's runs, among them those on its merge commit |
| `{project}/_apis/build/builds?reasonFilter=buildCompletion,resourceTrigger&minTime=…` | the same, once a run on the merge commit has been found | the runs that runs started, such as a deployment |
| `{project}/_apis/build/builds/{id}/timeline` | for those runs, each pipeline's latest: every refresh while it runs, and once when it finishes (again if it's retried); four a refresh | its stages, whether one waits for an approval, and where it failed |
| `_apis/git/pullrequests/{id}` | when one of yours leaves the active list: five a refresh, the ones not looked up yet first; one that fails is tried again on the next refresh, then less and less often | whether it was completed or abandoned |
| `_apis/git/pullrequests/{id}` | for a pull request someone sent you, or that you watch, that isn't in your lists: ten a refresh, the ones never read first; one that's closed or can't be read is tried again an hour later | the pull request, to list it |
| `{project}/_apis/git/repositories/{repo}/pullRequests/{id}/workitems` | only with [Show Links](#links): once for each of your pull requests, twenty a refresh, then every quarter of an hour, four a refresh; one that can't be read is tried again an hour later | its work items |
| `_apis/wit/workitems?ids=…&$expand=relations` | only with Show Links, while the sprint is on screen: when its work items change, and every quarter of an hour; 200 work items a request. Azure DevOps doesn't take the fields to return with relations, so all of them come too | the pull requests each of the sprint's work items links to |
| `_apis/wit/workitems?ids=…&fields=…` | only with Show Links: for the work items linked to your pull requests that the sprint doesn't show, and those you linked, every quarter of an hour; 200 a request | their title, type, state, project and when they changed |
| `_apis/git/pullrequests/{id}` | only with Show Links: for a pull request linked to a sprint's work item, or that you linked, that your lists don't show, ten a refresh, the ones never read first; again every quarter of an hour while it's open, and every six hours once it's closed | the pull request, to show it |
| `app.vssps.visualstudio.com/_apis/profile/profiles/me`, `…/_apis/accounts` | finding your organizations | your organizations; then each one is checked for your pull requests, and when none were found because some couldn't be checked (offline, say), it tries again a minute later |

The list endpoints have no "last updated" field, and new comments don't change anything in them,
so a pull request's details (policies and threads, two requests) are fetched on a schedule
(`RefreshPlanner`):

- every pull request without details, which is all of them on the first load, in parallel, four at a
  time;
- then, at most eight others a refresh: changed ones first (a push, a vote, a merge status or draft
  change), then those with a build or check in progress (every minute), the others every three
  minutes, and drafts and idle ones every fifteen.

Requests honor `Retry-After`: when Azure DevOps asks to slow down, nothing is sent until the time it
gave. When nothing can be read (offline, for example), refreshes back off up to ten minutes, and
waking the Mac or getting back online refreshes right away.

Azure DevOps can't push updates to a personal app: service hooks need a project administrator and a
server reachable from the internet. Pull requests and builds take minutes to hours, so a refresh a
minute is plenty.

### How a pull request's group is decided

The [groups table in the README](../README.md#azure-devops) lists them. In more detail:

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
failed build or status check, merge conflicts or an expired build; **Waiting** while a reviewer
wants changes; **Ready to Complete** when every blocking policy passes (or, without reviewer
policies, someone approved); and **Waiting** otherwise, with what it's waiting for.

**Pull requests you review** are in **Needs You** for something new, or a reply or mention you've seen
that still waits on you, **Idle** if they're drafts,
inactive, or you approved or declined them, **To Review** if you haven't voted, and **Waiting** if
you asked the author for changes.

A pull request that would be **Idle** or **Waiting** is in **Answered** instead while there's
something you answered yourself that you haven't seen yet (see below).

### What counts as new

Azure DevOps has no read or unread state for pull requests, so BriefBar keeps its own
(`SeenState`): activity up to a pull request's cutoff counts as seen. The cutoff is when you last
opened the pull request from BriefBar (or clicked **Mark as Seen**), or, if that's earlier, three
days before BriefBar first ran. Each account you sign in to the Azure CLI with has its own, since
two accounts can see the same pull request: switching back to an account picks up where it left off,
and nothing from the other account is announced.

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
  an indented line, so one that names another thread doesn't count. A comment that came after, while you
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
the app watches too.

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
- In Done, how many are still running, and then that they passed.

While they run or wait, the pull request stays in Done even once you've opened it; once they've all
passed, it leaves Done as before, when you've seen it. A notification says when one fails, when one
starts waiting for an approval, and when they've all passed after running; what happened before
BriefBar started isn't announced. The Pipelines page lists them under **After Your Merges**, above the
pipelines you pin. **Follow Pipelines After You Merge** turns it off, and BriefBar then forgets the
runs it found.

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
| `{project}/_apis/build/builds?definitions=…&maxBuildsPerDefinition=12` | every refresh: one per project (and branch) for all its pinned pipelines | their recent runs |
| `{project}/_apis/build/builds?repositoryId=…&branchName=refs/pull/{id}/merge` | every refresh while pipelines are visible: one per active PR you authored | its latest validation runs, up to 200 |
| `{project}/_apis/build/builds/{id}/timeline` | every refresh for a latest run in progress, once when it finishes (again if it's retried); up to six a refresh | its stages, and where it failed |
| `{project}/_apis/build/definitions?name=*…*` | when you search in **Add Pipeline** | pipelines to pin |
| `{project}/_apis/build/definitions?definitionIds=…` | when you search for a number in **Add Pipeline**, alongside the name search | the pipeline with that number, first |
| `{project}/_apis/build/definitions/{id}`, `{project}/_apis/build/builds/{id}` | when you paste a link to a pipeline, or to a run, in **Add Pipeline** | the pipeline it's to, and a run's branch |
| `_apis/projects` | when you open **Add Pipeline** | the projects to search in |

**Which sprint.** The first time, BriefBar looks through your teams (up to 25) for one with a sprint
going on today, and when several have one, picks the team with the most work assigned to you. It
keeps that team until you choose another. Azure DevOps keeps calling a team's last sprint "current"
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

**Pipelines.** A pinned pipeline shows its twelve latest runs, or its latest runs of one branch. Its
latest run's stages come from the run's timeline: its stages in order or, for a pipeline without
stages, its jobs. A stage waiting for an approval or a check is shown as waiting. When the run
failed, it names the first task that failed, the stage it's in and its first error. Runs started by
Azure DevOps itself, such as scheduled ones, don't name who started them. The timelines never read
go first, then the ones read longest ago; one that fails is tried again on the next refresh, then
less and less often, up to every 30 minutes, and one you may not read isn't asked for again until
the run changes. Stages are kept by organization, project and run, since run IDs are unique only
within an organization.

Below pinned pipelines, **Your Pull Requests** groups validation runs into one expandable card per
active pull request you authored, including drafts and inactive PRs. Each card names the repository
and PR number and summarizes the latest run of each pipeline; expanding it shows those runs' stages
and failure details. Runs are scoped to the PR's repository and `refs/pull/{id}/merge`, not the latest
run of that shared pipeline on another PR. Results from older commits are marked **Outdated** and
excluded from the current pass/fail summary. If Azure DevOps doesn't provide enough commit information,
the result says **Commit not verified**, rather than assuming it validates your latest changes.
Cards disappear when the PR is merged or abandoned. This does not pin those pipelines, change pinned
pipeline counts or widgets, or affect **After Your Merges**.
The authored PR list carries the account that supplied it. When the pipeline reader detects another
sign-in, it clears the old runs and suspends PR cards and validation requests until the pull request
reader supplies a list for that account, even when both accounts can read the same repository.

In a window, each section has a page of its own, in the translucent look of BriefBar's windows; in a
menu-bar item's list and in a widget, the Sprint section lists your own work, and the Pipelines
section each pinned pipeline's latest run. In a list, each one's title opens its page, and the
sprint's footer its task board in Azure DevOps.

### Send work to Copilot

With **Send Work to Copilot** on, a sprint's work items get a ✈︎ button and menu items that send one to
the Copilot CLI (`Sources/CopilotTasks`). Nothing happens until you send one, and BriefBar's own
requests to Azure DevOps stay GETs: the programs it starts for you do the rest.

**Sending.** The composer fills the prompt in from Settings (`PromptTemplate`: `{id}`, `{type}`,
`{title}`, `{url}`, `{organization}`, `{project}` and `{baseBranch}`) and remembers the repository
each project's work went in, by organization and project. Then BriefBar:

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
errors, read again from its timeline (one GET a build, when you ask); for a review, the threads already
there, and when you last voted or commented. The prompts say what Copilot may do: fixing comments, a
build or conflicts changes files but never commits, pushes or replies; a review changes and posts
nothing; only **Push & Reply** commits, pushes the pull request's branch without force
(`git push origin HEAD:refs/heads/<branch>`) and replies on its threads. The Copilot CLI holds it to that
whatever it reads, since its denials win over `--allow-all-tools`: a review gets
`--deny-tool write --deny-tool 'shell(git commit)' --deny-tool 'shell(git push)'`, fixing comments or a
build the last two, and resolving conflicts, which has to commit its merge, `shell(git push)`. Its worktree,
`copilot-worktrees/<repository>/pr-<id>`, is detached at `origin/<branch>`, fetched first, so it never
takes the branch from a checkout that has it. The composer already knows and shows the remote
repository. **Local Clone** selects its folder on this Mac, not which repository the PR belongs to.
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

Copilot loads a folder's own skills, MCP servers and hooks only once you trust it (`trustedFolders` in
its `config.json`). The CLI gives a worktree of a repository you trust the same trust by itself, and no
more: a worktree of one you don't trust loads only your own configuration. BriefBar doesn't pass
`--trust-folder`: the CLI refuses it with `--session-id`, and wouldn't start.

**Following it.** Copilot logs the session to `~/.copilot/session-state/<id>/events.jsonl` (under
`COPILOT_HOME`, if your shell sets it), as for the app's sessions, and BriefBar reads it the same way
([below](#how-a-status-is-decided)), every three seconds while a task runs, and not at all otherwise or
while **Send Work to Copilot** is off. Whether the process still runs is checked first, by its ID and
start time, so one that gets its ID after a restart isn't mistaken for it. While it runs, the task is
working, whatever its log says for now: in autopilot, Copilot goes on after a turn that looks like its
last, and after an error. Once it's gone, and BriefBar has heard how it ended if it started it, its log
and output are complete, and say how it went: done if Copilot called it done or exited cleanly, failed
if Copilot reported an error or exited badly, and stopped otherwise. The pull request is then the last
link to one in Copilot's summary, its last message, or what it printed, and a notification says how it
went; clicking it opens the pull request, or the work item.

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
repository and worktree, whether you stopped it, and the pull request's link go to the preferences (`ado.copilot.runs`),
without their titles; and so
do your choices and the repository of each project. Any program running as you can change the
preferences, and BriefBar may have Full Disk Access, so the files it reads for a task aren't kept
there: a task keeps its session's ID, a UUID, which names its session log and its output, and those
are read without following a symbolic link. What Copilot printed when it ended stays in a file only you
can read. Turning Azure DevOps off forgets the tasks and the repositories, and deletes what Copilot
printed. **Clear** forgets a task and deletes what it printed; **Remove Worktree…** deletes its
worktree with git, and asks again before deleting changes that aren't committed. Copilot's branches,
pull requests and sessions are yours, and stay.

### Notifications

After each refresh, BriefBar compares the new list with the previous one (`NotificationPlanner`)
and announces events it hasn't seen before, as well as your pull requests that start failing,
become ready or complete, and what the pipelines after your merges do. What you've seen is never
announced, even while it still waits on you. Events from before BriefBar started aren't announced: they're in the
panel. When there's a lot at once, it posts the three newest and one "more updates" notification.
Changing a setting or time passing never causes a notification. Clicking one opens the comment it's
about, and marks the pull request seen.

### The brief

Azure DevOps' own brief, at the top of its list and its page, picks, in code, the newest pull
request that needs you, the newest failure and the newest one that's ready (then more of what needs
you, up to three). The brief across sources ([above](#the-brief)) says each pull request the same
way. Items about a comment go to Apple Intelligence's on-device model one at a time, with the
commenter, the title and the comment, and come back as one sentence such as "Sam asks you to cap the
backoff at 30 seconds on …". The others are plain sentences. Results are kept for as long as the app
runs, never block the panel, and fall back to the plain sentence if the model isn't available or
fails. BriefBar explicitly uses `SystemLanguageModel.default`: nothing goes to Private Cloud Compute
or any other model.

### Limits

- Pull requests sent in chats are only as complete as Notification Center: a message you saw in the
  app before it posted a notification, or one older than the notifications it keeps, isn't there.
  Since BriefBar keeps the links in memory only, that's also true of a link it had found, once
  BriefBar restarts.
- Pull requests assigned only to a group or team you're in aren't listed: Azure DevOps's reviewer
  search matches you, not your groups.
- Organizations in other Microsoft Entra tenants than the Azure CLI's default can't be read with its
  token.
- A failed build says where it failed only when its run's timeline can be read, and then only its
  first error: the rest is in its log, which BriefBar doesn't read.
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
| `data.db` (SQLite, WAL mode) | the Copilot app | sessions, names, projects/branches, the "is running" flag, unread markers, the activity feed, how full each session's context window is; and, only with [Show Links](#links), the pull request each session started from or opened, and its project's GitHub repository and folder name |
| `session-state/<id>/events.jsonl` | the Copilot agent | a step-by-step log: turns, tool calls, questions, plans, permission prompts, errors |

BriefBar combines the two. The database says which sessions exist and whether the app
thinks they're running. The tail of each log says exactly where a session is, for example
"asked a question at 14:02 and is still waiting".

BriefBar never changes either of them:

- The logs are opened read-only. After the first read, only what's been appended is read.
- The database is opened with a read-only SQLite connection. Like any SQLite reader, it briefly
  takes shared locks and updates SQLite's shared-memory index (`data.db-shm`) while it reads;
  neither changes any data. When the app has quit and SQLite has removed the write-ahead log, a
  read-only connection can't open the database, so BriefBar reads it in SQLite's
  [immutable mode](https://www.sqlite.org/uri.html#uriimmutable) instead.

### How a status is decided

The [states table in the README](../README.md#github-copilot) lists every status and when
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
- **Show Context Usage** shows the app's latest measurement of each session's context window
  (`session_context_usage`): the tokens the conversation takes up, as a share of the model's
  limit. Copilot compacts a conversation at about 80% of the limit, so the percentage turns
  orange from 70%. Sessions the app hasn't measured show nothing.
- Clicking a session opens it through the Copilot app's `ghapp://sessions/<id>` link.
- The tasks you sent to Copilot from Azure DevOps ([above](#send-work-to-copilot)) are in the list too,
  with ✈︎ before their names, unless the app's database lists their sessions itself, as it does once you
  open one there. (Without the database, the list is every recent session folder, and a task's folder is
  the task.) Azure DevOps already follows them, so the list takes how each one stands from it rather than
  reading anything (`StatusResolver.snapshot(unlisted:…)`): **Running** while its worktree gets ready
  (Starting…) and while Copilot works, with its current step; then **Done** or **Stopped**, highlighted as
  long as a session would be, until Clear or retention expiry, with optional dismissal on opening
  while **Move Viewed Sessions to Idle** is on. One you stopped yourself is idle at once.
  Clicking one opens its pull request, or its work item, and its menu is the task's own: go on in
  Terminal, show the worktree or what Copilot printed, stop it, remove its worktree or clear it.

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
  problem is shown in the panel and the widget.

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
`NO_COLOR`). It tells a signed-out CLI from other failures by what `gh` prints. **Sign In…** opens
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
(`GitHubClient.makeSession`).

It refreshes every 2 minutes by default (**Refresh Every** in its settings), when a list opens if the
last read is more than 10 seconds old, and every minute while you need to sign in or are offline, so a
fix shows soon. When GitHub asks it to slow down, it sends nothing until the time GitHub gave:
`Retry-After` for its secondary limits, the hourly limit's reset (`x-ratelimit-reset`), or a minute
when GitHub only says so in words. At the default, that's 30 requests an hour, a small part of GitHub's
hourly limit for the GraphQL API.

When GitHub answers with errors alongside what it could read, such as an organization that uses SAML
single sign-on the GitHub CLI isn't authorized for, the list shows what it read with a note saying
why the rest is missing.

### How a pull request's group is decided

`GitHubClassifier` puts each pull request in one group, the first that applies:

- **To Review**: someone asked you, by name, to review it.
- For your own: **Waiting** if it's a draft; **Failing** if its checks fail or it has merge
  conflicts; **Changes Requested** if the review decision says so (or, without one, a reviewer's latest
  review does); **Waiting** while its checks run; **Ready to Merge** if it's approved; and **Waiting**
  for reviews otherwise.

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
them off also removes BriefBar's plugin, if you installed it ([below](#its-copilot-plugin)); turning them
on never installs it. If the CLI can't remove either, the page says so while agents are off, with **Try
Again** ([below](#its-copilot-plugin)).

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
- Azure DevOps reads as the app does, with its organizations, its settings and what you've seen and
  taken off Needs You in it, so the groups match the menu bar's, and like the other modes it leaves out
  pull requests sent in chats. In Needs You, what you've seen that still waits on you says so. One
  `PulseEngine` serves the whole session (`AzureDevOpsReader`): a tool reads again only
  when what it has is a minute old, as the app does at its most often, so calls one after another share
  a read. A read that failed in a way you can fix, such as a sign-in that expired, isn't kept, so the
  next call reads again. The pinned pipelines and the sprint are read the same way, when a tool needs
  them. Each read runs on its own, so a call the agent cancels doesn't cut short what the next one gets.
- Copilot's sessions come from the app's database and the sessions' logs, as `--json` reads them.

`pull_request_prompt` gives the prompts of a pull request's Copilot actions (see
[Send work to Copilot](#send-work-to-copilot)), told to work in the agent's checkout rather than a
worktree: fetch the branch and check it out, or ask where to work if that isn't a clone of the
repository or has changes of its own. Push & Reply, for one of yours, first checks that HEAD contains
the pull request's branch and that everything it would push was made for it, stops and asks if not,
and never rebases. For a failed build, it reads each run's timeline first, with a GET. The Copilot
CLI's `--deny-tool` rules don't come with it: the agent's own permissions apply.

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
files. `copilot plugin marketplace add` registers the folder in BriefBar.app that holds the plugin,
`Contents/Resources/CopilotPlugin`, as a marketplace named `briefbar`, and `copilot plugin install
briefbar@briefbar` turns the plugin on. The CLI loads a plugin from a marketplace on this Mac where it
is, without copying it, so the plugin is the one in the app: an update to BriefBar updates it for the
sessions that start afterwards. The build adds BriefBar's version to it, and `scripts/check-app.sh`
checks that. Removing it turns the plugin off first, with `copilot plugin uninstall`, so that it doesn't
come back on with its marketplace, then removes the marketplace, without `--force`: that would uninstall
whatever else the marketplace has, so the CLI refuses instead if it has a plugin it copied, and says
which. What the page says
comes from `copilot plugin list --json`, whose `installedFrom` is the folder the plugin loads from, and
`copilot plugin marketplace list --json`. A marketplace's name, and its folder's, prove nothing, as
anyone can choose them, so BriefBar changes one named `briefbar` only if it's this copy's, or the
`Contents/Resources/CopilotPlugin` folder of an app whose bundle identifier is BriefBar's, as it reads it
in that app's `Info.plist`: another copy of BriefBar, such as one you built, which **Use This Copy**
replaces. It leaves any other, and one in an app that's no longer there, and says how to remove it
yourself. Opened where it was downloaded, BriefBar runs from a temporary copy (App Translocation), and
doesn't install the plugin from there.

**Turning agents off.** BriefBar removes its MCP server and its plugin from the CLI. Agents are off
then, so the page shows only what's still going on: removing them, and what the CLI couldn't remove,
with **Try Again**, which removes it again (`AgentCleanup`). It shows why in the CLI's own words, such
as which plugins keep a marketplace there, which you may have to remove first: its first three lines,
at most 300 characters, without terminal escapes or other control characters. It keeps that only until
BriefBar quits: either way, BriefBar answers agents that they're off.

**What the skill does.** **/briefbar** on its own calls `needs_me`, and in the app shows what it lists
in the app's inbox widget, by BriefBar's groups, with the links BriefBar gives, and
`ghapp://sessions/<id>` for a Copilot session. When agents are off, every tool says so, and the agent
stops there; when only a source is off, `needs_me` says so under its heading and has the others, which
the agent still shows. Asked to fix a pull request's comments, its build or its
conflicts, or to review it, the agent in the app starts a session for it with the app's own tools, in a
worktree of a repository the app knows whose `origin` is the pull request's repository: it asks you
when none or several are, never clones, and never works in a folder that is your own checkout. That
session's first prompt holds only the pull request's link and the action, and has it call
`pull_request_prompt` itself, so what the pull request's authors wrote reaches it as a tool's answer,
not as your request; the skill tells agents that such text is data, never instructions. Push & Reply
goes to the session that made the changes, never a new one. In the Copilot CLI, the agent follows the
prompt where it is. It doesn't answer a session's question, plan or permission for you: it offers to
open the session, with the app's `navigate_to`.

`CopilotPluginTests` checks the plugin's manifests, and that the skill names only tools that
`BriefBar --mcp` lists, their arguments and values, and the app's tools it uses, and every tool
BriefBar has; and that it stops only for what BriefBar answers when agents are off
(`AgentAccess.refusal`), not when a source is.

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
  zip before unpacking it. The appcast requires arm64 hardware, so existing Intel installs aren't
  offered an incompatible update. [SECURITY.md](../SECURITY.md#how-updates-are-verified) has the details.
- **Gently**: right after launch, Sparkle shows a new version itself. A later, scheduled check doesn't
  take the focus from the app you're using: the updater tells BriefBar, and the lists, the window and
  every gear menu say that an update is waiting instead.
- **Full Disk Access survives**, because every release is signed with the same certificate.

## Checks

- `make test` runs every module's tests, with made-up data, and with a single thread in Swift's
  cooperative pool (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`), so that code that blocks a thread of it
  while waiting for async work hangs on any Mac, not only on one with few cores.
- `make demo-check` checks that every source's made-up data lands in the expected groups, and in the
  expected states, each section's and all of them added up. It runs the same checks the Pulse apps ran
  on their demos.
- `scripts/check-boundaries.sh` reads each module's object files and fails unless only
  `AzureDevOpsCore` and `GitHubCore` use networking APIs, and only `BriefBarCore` starts programs. It
  also fails if those stop using them, since the check could no longer tell. It reads BriefBar's own
  modules, the updater's included, not Sparkle, whose requests are only for updates.
- `scripts/check-app.sh` checks a built app: its signatures and the hardened runtime; that BriefBar
  has no entitlements and links only Apple's libraries, with no run path or `Frameworks`; that the
  updater has its own identity, the one entitlement, the same signature as BriefBar, and Sparkle in
  its own `Frameworks`, without the XPC services, with its license and arm64 code; that BriefBar and
  its updater contain only arm64 code; a designated requirement that names a certificate, unless
  `--allow-ad-hoc` says a build of your own may be ad hoc; the update settings (the feed, the
  signed-appcast keys, and with `--release` the
  public key); FoundationModels linked weakly so it opens on macOS 15; its Copilot plugin, at its own
  version; and that it runs, starts the updater, which loads Sparkle, and passes the demo check.
- `scripts/test-updater-isolation.sh` (`make updater-check`) shows, on a copy of a build that macOS
  opens, that the updater is responsible for itself and that other code in place of Sparkle never runs
  as BriefBar ([above](#the-hardened-runtime-and-library-validation)). CI runs it on every package.
- `scripts/update-rehearsal.sh` (`make update-rehearsal`) installs an update through the updater, the way
  an installed copy gets one: a copy at version 0.9.0, with a bundle identifier of its own, checks a feed
  on the Mac signed with a throwaway key, downloads 0.9.1 and installs it, updater included, and the
  designated requirement stays the same. CI runs it on every package.
- `make signing-key-check` checks, in throwaway keychains, everything that keeps a signing key safe
  (above).
- `scripts/appcast-dry-run.sh` signs a packaged app's update and appcast with a throwaway key, the way
  a release does, and checks them as the app would.
