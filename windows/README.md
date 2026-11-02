# BriefBar for Windows

In development. BriefBar for Windows gives Windows what BriefBar's menu bar gives the Mac: a bar docked to the top of each
display, with each source's counts, and a panel under each of its items that lists what needs you. It's a WinUI 3 app on
.NET 10. Its first three sources, **GitHub Copilot sessions**, **Azure DevOps pull requests** and **GitHub pull
requests**, are ported; Teams comes next ([What's next](#whats-next)). Every source is off until you turn it on in
Settings, and reads nothing until then. Started with `--demo`, it shows **made-up data** for every source, and reads
nothing of yours.

## Build and run

You need Windows 11 22H2 or later and the .NET 10 SDK. From `windows/`:

```powershell
dotnet build BriefBar/BriefBar.csproj
BriefBar\bin\Debug\net10.0-windows10.0.26100.0\win-x64\BriefBar.exe --demo
```

Without `--demo`, the bar says **No source is on** until you turn one on: right-click the bar and choose
**Settings**, or press **Open Settings** in the Overview. Settings, and what you turned on, are saved in
`%LOCALAPPDATA%\BriefBar\Settings.json`; with `--demo`, nothing is saved. The first build downloads the parts of the
Windows App SDK that BriefBar uses from NuGet, about 120 MB. They ship inside the app, so there's nothing else to
install. Add `--runtime win-arm64` to build for Arm64.

To quit, right-click the bar and choose **Quit BriefBar**, use **More** (…) at the bottom of any panel, press
**Quit** in Settings, or run `scripts\quit.ps1`. Quit before you build again, since the build replaces the running
app. One copy runs per sign-in: starting it again opens the running one's Overview.

```powershell
dotnet test --project BriefBar.Core.Tests/BriefBar.Core.Tests.csproj
dotnet format whitespace . --folder
scripts\check-notices.ps1
scripts\smoke.ps1
```

Run the tests from `windows/`, whose `global.json` has `dotnet test` use Microsoft.Testing.Platform, as
xUnit v3 needs. The projects build with the latest recommended analyzers, nullable references and warnings as
errors; `.github/workflows/windows.yml` checks the formatting, runs the tests, builds for x64 and Arm64 and checks the
third-party notices ([Releases](#releases)) for every pull request that changes `windows/`, and `main` requires it to
pass.
`scripts\smoke.ps1` checks the built app end to end with made-up data, through UI Automation: a bar at the top of
each display, its items named in words with their keys, the Overview's panel, the panel's keys, the same item on
another display right after a press on this one, Copilot's panel (its groups, Idle folded, Clear, a row that opens),
Settings (a Copilot setting, and closing the panel as it comes to the front), Azure DevOps' panel (its groups, Idle
folded, Mark as seen, Answered seen once the panel closes, sorting by date and back) and its page in Settings,
GitHub's panel (its groups, its foot with the account it reads as, a row that opens) and its page in Settings, Alt+F4,
each bar keeping its display as displays change, a second start while BriefBar starts opening its Overview, and the
space given back within a second of quitting or of another program asking BriefBar to close. Run it before you open a
pull request, and leave the mouse and keyboard alone while it runs, since a click elsewhere closes the panel it's
checking; it sends keys only while the panel is in front, and it works over a disconnected remote session too, without
the keys.

BriefBar writes what it does to `%LOCALAPPDATA%\BriefBar\Logs\BriefBar.log`, kept under 1 MB with two older
files beside it: bars placed, panels opened and closed, errors' types. Its log lines take only numbers, states,
section names and the like, so nothing you see can reach it: a line with a string in it doesn't compile.

## What it does

- **A bar at the top of every display**, 32 pixels high at 100% scaling and 48 at 150%, and taller as you make
  Windows' text bigger, up to 40 pixels at 100%. It reserves its space with Windows'
  [application desktop toolbar API](https://learn.microsoft.com/windows/win32/shell/application-desktop-toolbars)
  (`SHAppBarMessage`), as the taskbar reserves its own, so maximized windows stop below it. It's always on top,
  it isn't in the taskbar or Alt+Tab, and a click on it leaves your window active.
- **On its left, what needs you, in words**: "8 need you · 3 went wrong · 3 done or ready", each number in its
  state's color, across every source. It opens the Overview. What's running isn't in those words, as it isn't in
  the Mac's counts added up, but its tooltip says it.
- **On its right, an item per section**, in the Mac's order: the source's glyph, its short name ("Copilot",
  "Azure DevOps") and its counts by state. Needs you is a filled pill; the rest are an icon and a number, and
  zero is quiet. Its tooltip says each count in words, and how fresh it is ("Live", "Updated 20 s ago"), or that
  the section is starting, can't read, is paused or is stale.
- **The items are buttons**, as tall as the bar, so a flick of the pointer to the screen's edge lands on one.
  Narrator names each in words ("GitHub Copilot sessions: 3 need you, 2 running, 1 done or ready, 1 went wrong"),
  and UI Automation can press them. The item whose panel is open is marked, as the taskbar marks the app in front.
- **The keyboard gets there from a panel.** The bar never takes the keyboard, so your window keeps it. Starting
  BriefBar again opens its Overview, with the keyboard on its first row; in any panel, Ctrl+1 shows the Overview,
  Ctrl+2 to Ctrl+9 the bar's items in order, as the Mac window's ⌘1 to ⌘9 show its pages, and Ctrl+Tab and
  Ctrl+Shift+Tab the next item and the one before. Each item's tooltip says its key, and Narrator says it too.
- **The panel** opens under its item as you press it: a header with the section's tile, title and status, and **Sort**
  for a list that can be sorted; a banner when a section can't show everything; notes about what it shows, such as
  that there's more on GitHub than it reads; the brief; then its groups (the Overview's: Needs you, Something's wrong,
  Running, Done or ready), with headers that stay in view as you scroll. Each row has a badge in its state's color (or
  a chat's initials), its title, where it stands, what it's about in two lines at most (three when it needs you),
  what's left before it's done where its source says, how long ago, unread messages and links. The keyboard starts on
  its first row. Pressing a row, or Enter, opens what it's about and
  closes the panel; right-click, the menu key or Shift+F10 shows everything it can do; its tooltip shows all of it.
  A group can have a button, as Copilot's Done has Clear, or start folded, as Copilot's Idle does. Its foot has the
  section's own buttons, such as **Open GitHub Copilot**, who it reads as, such as the GitHub CLI's login, and
  **Settings**. It closes when you press Esc, click anywhere else, Settings included, bring another app or Settings
  to the front, or press its item again.
- **Settings**, a window like Windows 11's own, opens from the bar's right-click menu, a panel's **Settings**
  button, or the empty Overview. **General** lists each source and whether it's on. A source's page says, before you
  turn it on, what BriefBar reads for it, where it connects and what it needs, as the Mac's does; turning it on is
  your consent to that, saved with the version of what it said (`SourceChoices`). A source that reads more after an
  update waits, paused, reading nothing, until you've seen what it reads now and kept it on. Turning one off, which
  asks first, stops it, takes it off the bar and deletes what BriefBar saved for it at once, without waiting for it
  to stop, so quitting meanwhile can't leave it behind; its settings stay. If a choice can't be saved, as on a full
  disk, Settings says so: it lasts until BriefBar quits, and BriefBar tries to save it again whenever a setting
  changes, and as it quits.
- **GitHub Copilot sessions**, as on the Mac ([How it works](../docs/how-it-works.md#github-copilot)): what each
  session in the GitHub Copilot app is doing, from the app's own files in `%USERPROFILE%\.copilot`, read-only,
  as they change. Its groups are the Mac's: Needs you (a question, a plan to review, a permission), Running, Done
  and Stopped (each with **Clear**, which moves them to Idle), and Idle, folded. A row opens its session in the
  Copilot app (`ghapp://sessions/<id>`), or, for a question that a coordinating session asks for another, the session
  where you answer it; its menu opens the session itself, and the one that started it. On a PC with only the Copilot
  CLI, a row opens its session in a terminal, as the Mac does in Terminal: it brings up the terminal of a CLI that has
  the session open, or else runs `copilot --resume <id>` in the folder the session works in. Its settings are the
  Mac's: Keep finished sessions for, Move viewed sessions to idle, Show relayed questions once, Nest sessions under
  their parents (a ↳ tag names a parent elsewhere) and Show context usage (a ring and a percentage, orange from 70%).
- **Azure DevOps pull requests**, as on the Mac ([How it works](../docs/how-it-works.md#azure-devops)): yours and the
  ones you review, in the organizations you choose, which it finds the first time, and the ones you watch by their
  links, read with the Azure CLI's sign-in (`az account get-access-token`, its token kept in memory only) and GET
  requests only, every minute. Organization names are compared ignoring case, as Azure DevOps does: a pull request
  you watch by a link that spells its organization another way is the one your lists have, listed once, and an
  organization spelled another way, as when finding your organizations again spells it as Azure DevOps does, keeps
  its pull requests, even while it can't be read. Its groups are the Mac's: Needs you (with **Mark as seen** while
  something there is new), Answered (until you've seen it in the panel), Failing, Ready to complete, To review,
  Waiting, Done (with **Clear**) and Idle, folded; the bar counts Needs you, Failing and Ready to complete, and To
  review too if you turn that on. As on the Mac, a merge Azure DevOps couldn't make (it failed, or a policy rejected
  it) is under Failing, and a person it requires as a reviewer keeps it out of Ready to complete until they approve,
  as Azure DevOps does. A row says why it's there, with the comment, the failed step or who approved; it opens the
  pull request in your browser, at the comment that needs you, and sees it; its menu removes it from Needs you, or
  stops watching it. Under each of your open pull requests, Idle's too, a line says what's left before you can
  complete it, as on the Mac ([What's left](../docs/how-it-works.md#whats-left-before-you-can-complete-it)): what
  you have to do first, such as **Resolve 2 comments**, then what failed, such as **Build failed**, what's running,
  and what waits on others, such as **1 of 2 approvals** or **Waiting on Sam**, each with its state's icon and color,
  then what's done, such as **Build passed**, quieter; open comments that no policy requires resolving are said too,
  without holding it up. The row's tooltip and Narrator say all of it, with who approved and where a build failed,
  and the tooltip says when it was created. **Sort** (↑↓) at the top of the panel lists the pull requests **By
  status**, in the groups above, or by when each was created, **Newest first** or **Oldest first**: in one list where
  each still says where it stands, and its time says how long ago it was created, with Done's, the latest first, and
  Idle's, in the same order, after it. The bar's counts, the brief and the Overview stay by status, and BriefBar keeps
  your choice (`ado.pullRequestOrder`). After you merge one, Done says how the pipelines that run on its merge go:
  running, waiting for an approval, and then passed or canceled, until you've seen it; one that fails moves it to
  Failing. Its foot has **Open Azure DevOps**, and an icon beside Settings
  refreshes now, as the Mac's does. Signed out, it offers to sign in, which runs `az login` in a console window;
  without the Azure CLI, or with one it can't start, it links to its installation. Its settings are the Mac's:
  Refresh, Keep done for, Idle after no activity for, Show To review in the bar, Follow pipelines after you merge,
  your organizations (with Add an organization and Find my organizations again), and the pull requests you watch
  (with Watch a pull request, by its link).
- **GitHub pull requests**, as on the Mac ([How it works](../docs/how-it-works.md#github)): the open pull requests on
  github.com that ask for your review by name, and your own, read with the GitHub CLI's sign-in (`gh auth token
  --hostname github.com`, its token kept in memory only, for half an hour, and forgotten as GitHub is turned off, which
  ends a run of `gh` under way) and one GraphQL query that only reads, every 2 minutes, and as you open the list,
  unless it read in the last 10 seconds. Its groups are the Mac's: To review, Changes requested, Failing, Ready to merge
  and Waiting; the bar counts all but Waiting. Where GitHub gives no review decision, as for a repository that doesn't
  require reviews, the latest reviews decide, a deleted account's too. A row says why it's there and who ("Changes
  requested · By sam"), and which pull request it is (`owner/repo#123`); it opens the pull request on GitHub. Notes
  beside the list say what GitHub couldn't read, as for an organization that needs single sign-on, and when there are
  more than the 50 it reads of each kind, with **More on GitHub**. Its foot has **Open GitHub**, the account the GitHub
  CLI is signed in to, and an icon beside Settings that refreshes now. Signed out, it offers to sign in, which runs `gh
  auth login --hostname github.com --web` in a console window; without the GitHub CLI, or with one it can't start, it
  links to its installation. Its setting is the Mac's: Refresh, every 1, 2, 5 or 15 minutes.
- **It looks like Windows 11**: acrylic, [Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons),
  each shown at a size Fluent drew it for, so it lines up with the pixels, Segoe UI Variable, sentence case, and the
  panel's rounded corners and shadow. It follows light, dark and High
  Contrast as Windows changes, and its state colors meet WCAG AA against its background in light and dark (text
  4.5:1, icons 3:1), which a test checks. States never rely on color alone: each has its own icon and words.
- **It steps aside for full screen.** While a full-screen window, such as a game or a video, is in front on a
  display, that display's bar hides, and it stays hidden while that window stays on that display, even as you
  work on another, as the taskbar does.
- **It comes and goes cleanly.** There's a bar for each display, again whenever displays change, including a
  remote session's when you connect from another PC, and it reserves its space again when Explorer restarts.
  Quitting, signing out or shutting down gives the space back at once, and so does an unexpected error, which
  BriefBar logs before it ends. Another program asking it to close, as `taskkill` without `/F` does, quits it the
  same way; Alt+F4 doesn't close a bar, as it doesn't close the taskbar. If it's killed, Windows takes the space
  back by itself.

## Choices for Windows

The Mac app is the spec ([How it works](../docs/how-it-works.md)): the same sources, states, counts and rules.
Where Windows differs, these were decided:

- **The bar goes at the top**, like the Mac's menu bar. The bottom, above the taskbar, will be a choice in
  Settings.
- **Its left side says what needs you, in words**, rather than the brief's first line, which quotes chats and
  titles on every screen you share. The brief's first line will be a choice in Settings.
- **Hiding the panel and the window from screen sharing and recordings** will be a choice in Settings, off by
  default.
- **Sentence case** ("Needs you"), as Windows writes it.
- **The keyboard reaches the bar's items from a panel**, with Ctrl+1 to Ctrl+9 and Ctrl+Tab, since Windows has no
  key like the Mac's Ctrl+F8 for a bar like this one. Starting BriefBar again opens the Overview, as reopening it
  shows the Mac's first item.
- **.NET 10**, supported until November 2028, and **x64 and Arm64**.
- **Copilot sessions open in the GitHub Copilot app**, as on the Mac when it's installed. On a PC with only the
  Copilot CLI, a row opens its session in a terminal, as the Mac opens it in Terminal: the terminal of a CLI that
  has it open comes to the front, or else `copilot --resume <id>` runs in Windows' default terminal, in the session's
  folder. What goes wrong, such as a CLI BriefBar can't find, is said in Windows' own dialog.
- **Azure DevOps signs in with `az login` in a console window**, which stays open so you can read what it said, where
  the Mac opens Terminal. It doesn't list pull requests sent to you in chats yet: on the Mac that reads every app's
  notifications, which comes with Teams.
- **GitHub signs in with `gh auth login --hostname github.com --web` in a console window**, which stays open too, as
  `az login`'s does, where the Mac opens Terminal. BriefBar finds `gh` where `BRIEFBAR_GH` says, in your `PATH`, or
  where its installer or WinGet puts it. Names in a GitHub row are listed as Windows writes a list ("By sam, kai, and
  lee"), where the Mac writes "sam, kai and lee". Its empty list says **All quiet** only when it read them all: the
  Mac's says so under a note that it's offline, can't reach GitHub or couldn't read some pull requests too, even before
  any read has worked.

## The code

| Folder | What it holds |
|---|---|
| `BriefBar.Core/` | No UI and no Windows APIs, so its tests run anywhere. The states and counts (`ItemState`, `StateCounts`), the sections in the Mac's order (`Sections`), the brief (`Briefing`), what a source gives the app (`ISectionSource`), the sources Windows has (`SourceCatalog`), turning them on and off with your consent (`SourceSwitch`, `SourceChoices`, `PausedSource`), reading other apps' files and databases without holding them open (`SharedFile`, `SQLiteConnection`), reading what Azure DevOps and GitHub answer leniently (`LenientJson`), waiting as long as they ask (`RetryAfter`, `RateLimitGate`) and refusing to be sent elsewhere (`Redirects`), and the one place that starts programs or looks into running ones (`ProcessRunner`), with finding them as a terminal would (`ProgramLocator`) |
| `BriefBar.Core/AzureDevOps/` | Azure DevOps pull requests, ported from `Sources/AzureDevOpsCore` with the Swift names (`ADOClient`, `AzureCLITokenProvider`, `PulseEngine`, `PRClassifier`, `SeenState`, `MergeFollower`…), the store and settings from `AzureDevOpsUI` (`PRStore`, `AzureDevOpsSettings`), and the source (`AzureDevOpsSource`, `AzureDevOpsRows`). Only this folder and `GitHub/` may use the network (`BoundaryTests`) |
| `BriefBar.Core/Copilot/` | GitHub Copilot sessions, ported from `Sources/CopilotCore` with the Swift names (`SessionEngine`, `AppDatabase`, `EventLogReader`, `StatusResolver`…), the store from `CopilotUI` (`SessionStore`, `CopilotSettings`), opening a session with the Copilot CLI (`CLISession`, `SessionLock`), and the source (`CopilotSource`, `CopilotRows`) |
| `BriefBar.Core/GitHub/` | GitHub pull requests, ported from `Sources/GitHubCore` with the Swift names (`PullRequestQuery`, `GitHubClient`, `GitHubCLITokenProvider`, `GitHubClassifier`, `GitHubReader`…), the store and settings from `GitHubUI` (`GitHubStore`, `GitHubSettings`), and the source (`GitHubSource`, `GitHubRows`) |
| `BriefBar.Core/Presentation/` | What the bar, the panel and Narrator show: words and counts, groups, rows and what they can do, a row's checklist of what's left, how a list can be sorted, notes beside a list and who a section reads as, where a panel opens, the panel's keys, the bar's size, the state colors with their contrast, and the icons |
| `BriefBar.Core/Settings/` | Where settings are kept: a JSON file for the app, memory for tests and the demo |
| `BriefBar.Core/Logging/`, `Demo/` | The log, which can't take content, and the made-up data, Copilot's, Azure DevOps' and GitHub's through their real stores |
| `BriefBar.Core.Tests/` | xUnit v3: the Swift tests ported, and tests for the above, with made-up data only |
| `BriefBar/Shell/` | The desktop: a bar per display and its space (`BarWindow`, `AppBarReservation`), the panel (`PanelController`, `PanelWindow`), Settings (`SettingsWindow`), displays, full screen (`DesktopWatcher`), one copy per sign-in (`SingleInstance`), and quitting (`AppShell`) |
| `BriefBar/Views/`, `ViewModels/`, `Themes/` | The bar, the panel and Settings in XAML; what they show; and their styles, per theme |
| `BriefBar/Services/` | The sources you turned on and how each is made (`AppSources`), running them and handing what they show to the UI thread (`SourceHost`), the Copilot app as Windows knows it (`CopilotAppShell`), the terminal a Copilot CLI runs in (`CopilotCLIShell`), opening Azure DevOps' and GitHub's pages in your browser (`BrowserShell`), and the log file |
| `BriefBar/Interop/` | The Win32 calls that WinUI doesn't cover |
| `scripts/` | `quit.ps1` quits the running BriefBar; `smoke.ps1` checks it end to end with made-up data; `check-notices.ps1` checks that `THIRD-PARTY-NOTICES.md` names every file the build ships from someone else ([Releases](#releases)) |

Each type has its own file. Logic goes in `BriefBar.Core`, with tests; the app only shows it.

## Why a bar at the top

Windows has no `NSStatusItem`, and apps can't add their own item to the Windows 11 taskbar. These were tried
first, on Windows 11 26H2:

- **A notification area (tray) icon** is one 16 to 24 pixel image, with no text beside it. Windows 11 puts new
  icons in the overflow, which only you can change, and shows them only on the main display's taskbar.
- **A window over empty space on the taskbar** can look like part of it, but nothing supports it: it depends on
  the taskbar's layout, which changes with apps, alignment, auto-hide and updates.
- **Taskbar app tasks** (`Windows.UI.Shell.Tasks`) are drawn by Windows, with a badge and a card per task, but
  the API is experimental, needs an MSIX package, and gives each task a taskbar button of its own.

The application desktop toolbar API is documented and has worked the same way for decades; YASB, Zebar, Cairo
and RetroBar dock their bars with it. WinUI 3 has Windows 11's acrylic and controls built in, and the Windows App
SDK ships inside the app.

## Pitfalls already found

- **Tool windows don't hear about scaling changes** on Windows 11 (no `WM_DPICHANGED`), so the bar isn't one: it
  stays off the taskbar and out of Alt+Tab with `WS_EX_NOACTIVATE` instead.
- **Moving a window to a display with other scaling** sends `WM_DPICHANGED` with its rect scaled, which WinUI then
  applies; the bar puts its own rect in the message first.
- **WinUI windows have a minimum height**: `WM_GETMINMAXINFO` lets the bar be 32 pixels.
- **A window without a border or title bar keeps a 3-pixel dialog frame**, which WinUI puts back whenever it
  sets the window's styles, so the bar's items wouldn't reach the screen's edge: the bar answers
  `WM_NCCALCSIZE`, which makes the whole window its content.
- **WinUI puts the window menu back too**, which Narrator lists as "System", and which could move or close a bar:
  both windows take `WS_SYSMENU` off in `WM_STYLECHANGING`, after WinUI's turn (`WindowMenu`).
- **Windows destroys an owned window with its owner**, and WinUI doesn't raise `Closed` for it: the panel is owned
  by the bar it opened from only while it shows, and it forgets a window that's gone however it went.
- **Closing a WinUI window while a UI Automation client holds on to it can crash the app**, in
  `Microsoft.UI.Xaml.dll`, with no managed exception. `Close` disconnects the window's automation provider with a
  cross-apartment COM call, whose modal loop dispatches window messages, such as the `WM_WINDOWPOS*` a display change
  brings, into the half-closed window. Narrator, Voice Access and many other apps are such clients. So no bar window
  closes while BriefBar runs: as displays change, each keeps its display or takes another, one at its scaling
  first, or steps aside, hidden and holding no space, for a display that comes back (`BarArrangement`). Only a
  display left over gets a new window, so there are never more bar windows than the most displays there have been at
  once, and windows close only as BriefBar quits, after every bar's space is back. A bar that stepped aside ignores
  presses on its buttons, which a UI Automation client that held on to one could still make.
- **A WinUI window closes on `WM_CLOSE`**, which Alt+F4 and `taskkill` send, leaving its space reserved: a bar turns
  down Alt+F4 (`SC_CLOSE`), and turns any other close into quitting BriefBar.
- **Acrylic turns into a flat color in an inactive window**, and the bar is never active: `ActiveAcrylic` keeps
  `IsInputActive` on.
- **Windows 11 draws a 1-pixel border** around windows; the bar turns it off (`DWMWA_BORDER_COLOR`).
- **A click on the bar could be spent activating it** while some apps were in front, such as the Xbox app or a
  Windows Security prompt; the bar answers `WM_MOUSEACTIVATE` with `MA_NOACTIVATE`.
- **XAML moves focus to the bar on a press**, before the press reaches the item, which takes activation from an
  open panel. So the panel doesn't take focus moving to BriefBar's own windows as you going elsewhere (it takes
  focus back for Esc), and items act as they're pressed (`ClickMode="Press"`), since a click's release can get
  lost.
- **A press that makes the bar the active window can arrive twice**, about 130 ms apart, and the second would
  close the panel the first opened: a second press on the same item within 350 ms is ignored (`PanelToggle`).
- **Windows can refuse to bring the panel to the front**, as with a full-screen game in front, or a press that
  came through UI Automation rather than the mouse: `Foreground.Bring` attaches to the front window's input for a
  moment, and a low-level mouse hook closes the panel on a click elsewhere even if it never became active.
- **Measuring a list without a height limit puts every row on screen**, and scrolling or focusing it before it's
  laid out leaves it scrolled to its end: the panel measures itself at its tallest, and focuses its first row
  once it's laid out.
- **A grouped list keeps a row it still has in view as its groups change**: sorting the pull requests by date
  replaces every group but Done's and Idle's, so the list was left at Done, far down. Once the order changes, the
  panel scrolls back to its top after the list is laid out (`PanelViewModel.Resorted`).
- **`x:Bind` connects only once a view is on screen**, so the panel calls `Bindings.Update()` before it first
  measures itself, and one-time bindings (`x:Bind`'s default) never update: anything that changes is `OneWay`.
- **A remote session whose monitors change doesn't always send `WM_DISPLAYCHANGE`**; it moves the bars' space.
  So any change to their space, the work area or the scaling makes the bars check the displays, and arranges them
  again if they're not the ones the bars are on.
- **Watching every window's moves to find full-screen windows** wakes BriefBar on every move of the mouse: it
  watches the foreground window's thread only, and looks again every second only while a display has one.
- **Quitting has to give the space back itself**: the first version left the second display's space reserved,
  and its process running, for 5 to 8 seconds. BriefBar gives every bar's space back first (`ABM_REMOVE`), then
  closes its windows, and ends within a second.
- **`AccessibilitySettings.HighContrastChanged` throws in a desktop app** (`0x80070490`): BriefBar follows
  `UISettings.ColorValuesChanged`.
- **An unhandled exception doesn't end a WinUI desktop app**, which runs on without its windows: BriefBar logs
  it, gives every bar's space back, and ends. One thrown while UI Automation presses a button goes back to the
  caller instead, so check the log when you test that way.
- **WinUI ends the app at once when a shape gets a geometry that another shape uses**, with `E_INVALIDARG` in
  `combase.dll`, no managed exception and nothing in the log, only a dump in `%LOCALAPPDATA%\CrashDumps`. A list
  reuses its rows' elements as it scrolls and changes, so a view model must never hold a `Geometry`: Copilot's
  context ring draws its own (`MeterRing`).
- **Fluent draws each icon anew for each size**, on that size's pixels, and an icon scaled to another size blurs, at
  100% and 150% most: the bar's state icons were 16-unit drawings shown at 14 pixels, and Copilot's 20-unit pulse at
  16. Icons show at 12, 16, 20 or 24 pixels, each from its drawing for that size (`IconPaths.Of(icon, size)`). Where
  Fluent has none, the nearest is scaled: Pulse at 16, Branch Request at 24, and the plan's, the clock's and the power
  icon's at 16, in a row's badge.
- **A read-only SQLite connection to a database in WAL mode creates its `-wal` and `-shm` files** when they're
  gone, as when the Copilot app isn't running: `AppDatabase` opens such a database immutable instead, without locks.
  That holds only while the app leaves the file alone, so it checks the file's size and time, and that there's still
  no log, before and after: if the app opened or wrote it meanwhile, it reads again, the usual way. SQLite's
  Windows files are opened without delete sharing, so connections are never pooled (`Pooling=False`) and each
  closes once it has read, or the Copilot app couldn't replace its own files.
- **`FileSystemWatcher` does report the Copilot app's writes to `data.db-wal`** while the app holds it open
  (checked: about 20 events in 30 seconds of use), so the engine reads on change, not on a timer; a watcher that
  overflows or fails reads everything again, and it reads everything once a minute anyway.
- **`ghapp://` with no path opens the Copilot app's start page**, away from what it showed: **Open GitHub Copilot**
  brings the app's window to the front instead, and uses the link only to start the app when it has no window.
- **A press through UI Automation doesn't let BriefBar bring another app to the front**, as a click does: check
  what opens from a row with the mouse.
- **Don't name a namespace `…Windows`**: it hides WinRT's `Windows.*` namespaces.
- **On Windows, `az` is a batch file, `az.cmd`**, and Windows runs a batch file in `cmd.exe`, which reads its whole
  command line as commands, quotes or not. So nothing of yours reaches it: `ProcessRunner` gives a batch file fixed
  words only (letters, digits and `-._:/=`, checked to the end of the text, since a regex's `$` lets a final line
  break through), runs it as `cmd.exe /d /v:off /s /c "<path> <words>"`, without AutoRun commands or delayed
  expansion, refuses a path with quotes, `%` or line breaks, and treats `az.cmd.` as the batch file Windows would run.
  An `az.cmd` it refuses, like one removed since BriefBar found it, can't run: the panel says BriefBar couldn't get a
  token from the Azure CLI, which it looks for again within a minute, and Sign in opens the page that says how to
  install it, rather than ending BriefBar or its reading. A `copilot.cmd` it refuses can't open a session in a
  terminal: BriefBar says so, with the command to run instead.
  `az.cmd` runs Python, which can hold its output open after `az` ends: the runner waits half a second for the rest,
  then ends what's left, and a timeout ends the whole tree.
- **A console program started by an app without a console gets a window of its own**, in Windows' default
  terminal, such as Windows Terminal: that's how `az login` and `copilot --resume` open. To bring up the terminal a
  Copilot CLI already runs in, BriefBar attaches to its console for a moment (`AttachConsole`, taking Ctrl+C
  meanwhile so it can't end BriefBar): in Windows Terminal, `GetConsoleWindow` gives a hidden stand-in window, owned
  by the terminal's own (`GA_ROOTOWNER`), checked on this PC; in an editor's terminal it's owned by nothing, so
  BriefBar says where the session is instead.
- **That window closes the moment its program ends**, before you can read what it said. `az login` stays open
  because `az.cmd` is a batch file, which runs in `cmd.exe /k`; `gh.exe` isn't one, so `gh auth login` would close as
  soon as it was done. A program whose window should stay open runs in `cmd.exe /k` as a batch file does, with fixed
  words only (`ProcessRunner.CmdArguments`). `cmd.exe` would read a percent sign in its path as part of a command, and
  Windows allows one in a folder's name: a program found there, such as `gh.exe` or an `az.exe`, runs directly
  instead, in a window that closes once it's done, and a batch file there, such as `gh.cmd`, can't run at all, which
  the panel says.
- **`CancellationTokenSource.Cancel()` runs every callback on its token before it returns**, on the thread that calls
  it, and a registration's `Dispose()` waits for its callback while that runs: one that blocks, such as one ending a
  program, holds up whatever cancelled. So BriefBar stops each source on the thread pool, and waits for them only so
  long as it quits (`SourceSwitch`, `SourceHost`); and `SourceHost`, Azure DevOps' source and GitHub's cancel with
  `CancelAsync`, which runs the callbacks on the thread pool, and let go of what those may use only once they've
  finished: GitHub's keeps its connection to GitHub until then, even when it's disposed while it stops.
- **Windows' task dialog needs Common Controls 6**, which only an app's manifest can ask for; without it,
  `TaskDialog` isn't there at all.
- **Azure DevOps' empty list isn't "All clear" until each organization has been read once** (`FirstLoaded`): found
  with real data, the panel said "All clear" for the seconds between finding your organizations and reading them.
  The Mac shows "Loading" while it refreshes; Windows only the first time, so the bar doesn't say it's starting at
  every refresh of an empty list. An organization spelled another way since, as when finding your organizations
  again spells it as Azure DevOps does, keeps when it was first read (`PulseSnapshot.FirstRead`).
- **Seconds since 1970 in a double don't hold every tick of today's dates**: saved that way, a time reads back a
  tick or two off, and a seen time that comes back early makes the comment it was set to new again, so what you'd
  taken off Needs you came back after a restart. `SettingsValues` saves times as decimal seconds, to the tick.
- **A new comment shows within a minute to a quarter of an hour**, as on the Mac: the lists are read every minute,
  but each pull request's threads and policies only as often as `RefreshPlanner` says (every minute while a build
  runs, every 3 minutes, or every 15 for a quiet one), unless the pull request itself changed. Besides new ones, at
  most 8 are read a refresh, changed ones first, then those due longest, so pull requests whose builds run can't keep
  the others waiting.
- **Azure DevOps can ask BriefBar to slow down** (429 or 503): as on the Mac, nothing is sent until the time it gave
  (`Retry-After`, a number of seconds or, as RFC 9110 allows, a date, which GitHub's client reads the same way), or for
  a minute when it doesn't say, whichever reader asks next. The readers of the pull requests you watch, of those that
  left your lists, of failed builds and of merges stop, and count nothing as failed: a pull request you watch is read
  once BriefBar may send again, not an hour later. The reader of threads and policies stops too: a pull request it was
  reading then waits its usual interval, and the rest keep their turn. Finding your organizations saves nothing then,
  rather than only the ones it had checked, and the first time, it tries again a minute later.
- **`HttpClient` follows a redirect to any host** by default, and sends the request there, with its body for a 307 or
  a 308: a proxy's sign-in page could send BriefBar's requests to a host its sources' descriptions don't name. Neither
  client follows one (`Redirects`): one to another host is refused in words that name it, and one that stays on the
  same host is an HTTP error like any other. Neither source needs one: checked with real data, none of about 200
  answers from api.github.com, dev.azure.com and app.vssps.visualstudio.com, to the requests a refresh sends, was one.
- **UI Automation sees only the rows on screen**: the panel's list is virtualized, so `smoke.ps1` scrolls through
  it to see every group.

## What's next

Port the sources first, one at a time, each checked with real data ([below](#checking-with-real-data)), in
this order:

1. ~~**Copilot sessions**~~, done, with Settings and each source's consent; with the Azure DevOps layer, rows on a
   PC with only the Copilot CLI open in a terminal. Not ported yet, for later layers: Show Links, a work item's
   details and summaries, tasks sent to the Copilot CLI, and `--mcp`.
2. ~~**Azure DevOps pull requests**~~, done: the pull requests' section, its settings, and opening each pull request,
   with what's left before each of yours can complete and sorting the list by date. Not ported yet, for later layers:
   the Sprint and Pipelines sections, a pull request's page with its story, the brief's summaries, notifications,
   pull requests sent in chats (with Teams, as it reads notifications), Show Links, sending work to Copilot, and
   `--mcp`.
3. ~~**GitHub pull requests**~~, done: the pull requests' section, its setting, and opening each pull request, with
   the GitHub CLI's sign-in and its one GraphQL query. Not ported yet, for later layers: a pull request's page with its
   story (`PullRequestStory`), the brief's summaries, Show Links, and the sign-in's state in Settings.
4. **Teams chats**, the hardest. On the Mac, BriefBar reads Teams' notifications from Notification Center's
   database and Teams' read markers from its web view's IndexedDB (`TeamsCore`, `NotificationCenterDB`,
   `ChromiumIndexedDB`). On Windows, notifications are in
   `%LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db`, an undocumented SQLite database, and the new
   Teams keeps its data under `%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\`, with WebView2's data in
   Chromium's IndexedDB format. Confirm both on a machine signed in to Teams before porting.

Then, each checked the same way: the bar's choices in Settings ([above](#choices-for-windows)); the brief from
real data; opening a row's item; notifications (`AppNotificationManager` works without a package); Launch at
Login; the window with its pages (the Sprint, the Overview, a work item's details); summaries, with the Copilot
CLI only; agents (`--mcp`); and packaging, signing and updates.

Each source goes in a folder of `BriefBar.Core` like `Sources/*Core`, with the Swift tests ported to
`BriefBar.Core.Tests`, all with made-up data. Keep the Swift names, such as `PRStore` and `SessionEngine`, so
changes can be brought over either way. Never hold another app's files open between reads: Windows won't let
it replace a file that BriefBar has open.

## Rules

The [ground rules](../CONTRIBUTING.md#ground-rules) are the Mac app's, and they apply here too. In short: every
source is off until you turn it on, and reads nothing while it's off; only Azure DevOps (GET requests) and GitHub
(one GraphQL query) use the network, and neither ever writes; databases are opened read-only, in place; logs hold
counts, states and errors, never names, messages, titles or IDs; and nothing acts for you unless you ask.

## Checking with real data

The repository is public, and chats, pull requests and sessions are private, often confidential.

- Check each source against its own app or site: Azure DevOps, GitHub, the Copilot app and Teams. Compare
  every count, state and row, and what opens from it. The log says each source's counts by state as it changes
  (`copilot: Ready, 36 sessions…`, `azureDevOps: Ready, problem none, organizations 1: 4 need you…`, `github: Ready,
  problem none, notice False, more than shown False: 2 to review…`), without names.
  The screen tool can't read the Copilot app's window, so ask whoever's at the PC to compare it; what a row opened
  is in the app's own `lastRoutePath`, in `data.db`. For Azure DevOps, a throwaway program that reads the same
  organizations through `BriefBar.Core` and, separately, with its own GET requests (the Azure CLI's token) can compare
  every row's group with Azure DevOps' own facts, and every row's link with its repository's web URL, printing counts
  only; keep it out of the repository. For GitHub, the same: `BriefBar.Core`'s read beside `gh`'s own searches
  (`gh api graphql`, `gh search prs`), with the same sign-in.
- Run BriefBar, and `gh` or `az`, as you would: an agent's shell often has its own `GH_TOKEN`, `GH_HOST` and `gh`, and
  `gh auth token` gives `GH_TOKEN` when it's set, so a BriefBar started from there reads GitHub as the agent. Start it
  without `GH_TOKEN`, `GITHUB_TOKEN` and `GH_HOST`, with your own `gh` first in `PATH`.
- Turning a source on saves your consent in `%LOCALAPPDATA%\BriefBar\Settings.json`: copy it before a check, and put it
  back after each one, so the check leaves your choices as they were.
- Report what you checked in counts and states, never names, titles, messages, IDs, organizations or projects.
  Screenshots are for the made-up data only.
- Never commit logs, databases or fixtures copied from a real machine. When real data shows a case the tests
  miss, write a made-up fixture that has the same shape.

## Releases

The Mac app's updater reads the appcast from `releases/latest/download/appcast.xml`, and the README links to
`releases/latest/download/BriefBar.zip`. A release that GitHub marks as latest must have both, so publish
Windows builds as pre-releases until each release ships both apps.

`THIRD-PARTY-NOTICES.md` ships beside `BriefBar.exe`, and it must be complete before any release: for each package
whose files are in the app, a table of those files with the version built, and the package's license and notices, in
full. `scripts\check-notices.ps1` keeps it complete. It compares each file in the build that BriefBar doesn't build
itself with the files of the packages the build restored, and fails when the file isn't in the table of the package it
comes from, saying which that is; when a table's version isn't the one built; when a table names a file that its
package doesn't put in the build, or a package the build doesn't use; and when the build's copy of the notices isn't
the current one. CI runs it on the Release builds for x64 and Arm64, so a pull request that adds, updates or removes a
package can't pass until the notices say so. The Windows SDK's projection is the one version it doesn't check: the
.NET SDK picks it, so it follows whichever SDK builds.

## License

BriefBar is licensed under the GNU General Public License, version 3 or later ([LICENSE](../LICENSE)). BriefBar for
Windows ships Microsoft's Windows App SDK, the Windows SDK's projection for .NET and WinRT.Runtime inside its app, so
its licensors add a permission, under the GPL's section 7, to combine it with them:
[GPL-ADDITIONAL-PERMISSION.md](../GPL-ADDITIONAL-PERMISSION.md). `THIRD-PARTY-NOTICES.md` lists their files, with
their license terms.
