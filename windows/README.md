# BriefBar for Windows

In development. BriefBar for Windows gives Windows what BriefBar's menu bar gives the Mac: a bar docked to the
top of each display, with each source's counts, and a panel under each of its items that lists what needs you.
It's a WinUI 3 app on .NET 10. None of the sources is ported yet ([What's next](#whats-next)), so it reads
nothing of yours: started with `--demo`, it shows **made-up data**.

## Build and run

You need Windows 11 22H2 or later and the .NET 10 SDK. From `windows/`:

```powershell
dotnet build BriefBar/BriefBar.csproj
BriefBar\bin\Debug\net10.0-windows10.0.26100.0\win-x64\BriefBar.exe --demo
```

Without `--demo`, the bar says **No source is on**. The first build downloads the Windows App SDK from NuGet,
about 300 MB. It ships inside the app, so there's nothing else to install. Add `--runtime win-arm64` to build
for Arm64.

To quit, right-click the bar and choose **Quit BriefBar**, use **More** (…) at the bottom of any panel, or run
`scripts\quit.ps1`. Quit before you build again, since the build replaces the running app. One copy runs per
sign-in: starting it again opens the running one's Overview.

```powershell
dotnet test --project BriefBar.Core.Tests/BriefBar.Core.Tests.csproj
dotnet format whitespace . --folder
scripts\smoke.ps1
```

Run the tests from `windows/`, whose `global.json` has `dotnet test` use Microsoft.Testing.Platform, as
xUnit v3 needs. The projects build with the latest recommended analyzers, nullable references and warnings as
errors; `.github/workflows/windows.yml` checks the formatting, runs the tests and builds for x64 and Arm64.
`scripts\smoke.ps1` checks the built app end to end with made-up data, through UI Automation: a bar at the top of
each display, its items named in words, the Overview's panel, the same item on another display, Alt+F4, displays
changing, and the space given back within a second of quitting or of another program asking BriefBar to close. Run
it before you open a pull request, and leave the mouse and keyboard alone while it runs, since a click elsewhere
closes the panel it's checking; it works over a disconnected remote session too.

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
  the keyboard reaches them, and UI Automation can press them. The item whose panel is open is marked, as the
  taskbar marks the app in front.
- **The panel** opens under its item as you press it: a header with the section's tile, title and status; a
  banner when a section can't show everything; the brief; then its groups (the Overview's: Needs you,
  Something's wrong, Running, Done or ready), with headers that stay in view as you scroll. Each row has a badge
  in its state's color (or a chat's initials), its title, where it stands, what it's about in two lines at most,
  how long ago, unread messages and links. The keyboard starts on its first row. It closes when you press Esc,
  click anywhere else, bring another app to the front, or press its item again.
- **It looks like Windows 11**: acrylic, [Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons),
  Segoe UI Variable, sentence case, and the panel's rounded corners and shadow. It follows light, dark and High
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
- **.NET 10**, supported until November 2028, and **x64 and Arm64**.

## The code

| Folder | What it holds |
|---|---|
| `BriefBar.Core/` | No UI and no Windows APIs, so its tests run anywhere. The states and counts (`ItemState`, `StateCounts`), the sections in the Mac's order (`Sections`), the brief (`Briefing`), and what a source gives the app (`ISectionSource`) |
| `BriefBar.Core/Presentation/` | What the bar, the panel and Narrator show: words and counts, groups and rows, where a panel opens, the bar's size, the state colors with their contrast, and the icons |
| `BriefBar.Core/Logging/`, `Demo/` | The log, which can't take content, and the made-up data |
| `BriefBar.Core.Tests/` | xUnit v3: the Swift tests ported, and tests for the above, with made-up data only |
| `BriefBar/Shell/` | The desktop: a bar per display and its space (`BarWindow`, `AppBarReservation`), the panel (`PanelController`, `PanelWindow`), displays, full screen (`DesktopWatcher`), one copy per sign-in (`SingleInstance`), and quitting (`AppShell`) |
| `BriefBar/Views/`, `ViewModels/`, `Themes/` | The bar and the panel in XAML, as buttons and a list; what they show; and their styles, per theme |
| `BriefBar/Services/` | Running the sources and handing what they show to the UI thread (`SourceHost`), and the log file |
| `BriefBar/Interop/` | The Win32 calls that WinUI doesn't cover |
| `scripts/` | `quit.ps1` quits the running BriefBar; `smoke.ps1` checks it end to end with made-up data |

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
  by the bar it opened from only while it shows, since bars close as displays change, and it forgets a window that's
  gone however it went.
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
- **`x:Bind` connects only once a view is on screen**, so the panel calls `Bindings.Update()` before it first
  measures itself, and one-time bindings (`x:Bind`'s default) never update: anything that changes is `OneWay`.
- **A remote session whose monitors change doesn't always send `WM_DISPLAYCHANGE`**; it moves the bars' space.
  So any change to their space, the work area or the scaling makes the bars check the displays, and a bar for
  each again if they're not the ones the bars are on.
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
- **Don't name a namespace `…Windows`**: it hides WinRT's `Windows.*` namespaces.

## What's next

Port the sources first, one at a time, each checked with real data ([below](#checking-with-real-data)), in
this order:

1. **Copilot sessions**, the closest to the Mac: on Windows the data is laid out the same way, in
   `%USERPROFILE%\.copilot`, with the Copilot app's database `data.db` and each session's log in
   `session-state\<id>\events.jsonl`. Port `Sources/CopilotCore`. Settings, with each source's consent, comes
   with it, since a source can't be turned on before then.
2. **Azure DevOps pull requests**: sign in with
   `az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --output json`, then only GET
   requests. On Windows, `az` is `az.cmd` on the `PATH`. Port `Sources/AzureDevOpsCore`.
3. **GitHub pull requests**: `gh auth token --hostname github.com`, then its one GraphQL query. Port
   `Sources/GitHubCore`.
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
  every count, state and row, and what opens from it.
- Report what you checked in counts and states, never names, titles, messages, IDs, organizations or projects.
  Screenshots are for the made-up data only.
- Never commit logs, databases or fixtures copied from a real machine. When real data shows a case the tests
  miss, write a made-up fixture that has the same shape.

## Releases

The Mac app's updater reads the appcast from `releases/latest/download/appcast.xml`, and the README links to
`releases/latest/download/BriefBar.zip`. A release that GitHub marks as latest must have both, so publish
Windows builds as pre-releases until each release ships both apps.
