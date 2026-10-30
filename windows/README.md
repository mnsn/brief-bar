# BriefBar for Windows

In development. BriefBar for Windows gives Windows what BriefBar's menu bar gives the Mac: a bar docked to the
top of each display, with each source's counts, and a panel under it that lists what needs you. It's a WinUI 3
app, and for now it shows **made-up data**: none of the sources is ported yet ([What's next](#whats-next)).

## Build and run

You need Windows 11 22H2 or later and the .NET 9 SDK.

```powershell
dotnet build windows/BriefBar.Windows.sln
windows\BriefBar\bin\x64\Debug\net9.0-windows10.0.22621.0\win-x64\BriefBar.exe
```

The first build downloads the Windows App SDK from NuGet, about 300 MB. It ships inside the app, so there's
nothing else to install. To quit, click **Quit** at the bottom of any panel, or run `windows\scripts\quit.ps1`;
quit before you build again, since the build replaces the running app. One copy runs at a time.

It writes what it does to `%TEMP%\BriefBar.log`: panels opening and closing, bars hiding and showing, never
any content.

## What it does

- **A bar at the top of every display**, 32 pixels high at 100% scaling and 48 at 150%. It reserves its space
  with Windows' [application desktop toolbar API](https://learn.microsoft.com/windows/win32/shell/application-desktop-toolbars)
  (`SHAppBarMessage`), as the taskbar reserves its own, so maximized windows stop below it. It's always on
  top, and it isn't in the taskbar or Alt+Tab. Clicking it makes it the active window, as clicking the taskbar
  does.
- **It steps aside for full screen.** While a full-screen window, such as a game or a video, is in front on a
  display, that display's bar hides, and it stays hidden while that window stays on that display, even as you
  work on another, as the taskbar does.
- **Its items:** on the left, BriefBar's mark and the brief's first line, which opens the Overview; on the right,
  each source's glyph and its counts by state, as BriefBar's menu-bar items show them on the Mac, with a
  tooltip that says what each count is.
- **The panel** opens under its item as you press it: a header, the brief, then the things in each state (Needs
  You, Something's Wrong, Running, Done or Ready), the Overview's from every source. It closes when you press
  Esc, click anywhere else, bring another app to the front, or click its item again.
- **It looks like Windows 11:** acrylic, [Fluent UI System Icons](https://github.com/microsoft/fluentui-system-icons),
  Segoe UI Variable, and the panel's rounded corners and shadow, in light and dark.
- **It comes and goes cleanly.** There's a bar for each display, again whenever displays change, and it
  reserves its space again when Explorer restarts. Quitting gives the space back at once, and if the app is
  killed or crashes, Windows takes the space back by itself.

## The code

| File | What it does |
|---|---|
| `BriefBar/App.xaml.cs` | Puts a bar on each display, hides bars for full-screen windows, closes panels when another app comes to the front, and quits, from the panel or `scripts/quit.ps1` |
| `BriefBar/BarWindow.cs` | One display's bar: its window, its reserved space, its items, and the window messages a docked bar has to handle |
| `BriefBar/PanelWindow.cs` | The panel's window: where it opens, and what closes it |
| `BriefBar/PanelContent.cs` | What the panel shows: the header, the brief, and a row for each thing |
| `BriefBar/AppBar.cs` | Displays, in physical pixels, and the reserved space (`SHAppBarMessage`) |
| `BriefBar/Acrylic.cs` | Windows 11's acrylic, as an active window shows it |
| `BriefBar/Look.cs` | Each state's and source's colors, icons and names, and small views they share |
| `BriefBar/Demo.cs` | The made-up items and brief, until the sources are ported |
| `BriefBar/Icons.cs`, `IconData.cs` | Fluent icons' paths, and drawing them at any size |
| `BriefBar/Native.cs` | The Win32 calls that WinUI doesn't cover |
| `BriefBar/Log.cs` | The log in `%TEMP%` |

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
- **Acrylic turns into a flat color in an inactive window**, and the bar is never active: `ActiveAcrylic` keeps
  `IsInputActive` on.
- **Windows 11 draws a 1-pixel border** around windows; the bar turns it off (`DWMWA_BORDER_COLOR`).
- **A click on the bar could be spent activating it** while some apps were in front, such as the Xbox app or a
  Windows Security prompt; the bar answers `WM_MOUSEACTIVATE` with `MA_NOACTIVATE`.
- **XAML moves focus to the bar on a press**, before the press reaches the item, which takes activation from an
  open panel. So the panel doesn't take focus moving to BriefBar's own windows as you going elsewhere (it takes
  focus back for Esc), and items act on `PointerPressed`, since a click's release can get lost.
- **A press that makes the bar the active window can arrive twice**, about 130 ms apart, and the second would
  close the panel the first opened: the bar ignores a second press on the same item within 350 ms.
- **Windows can refuse to bring the panel to the front**, as with a full-screen game in front:
  `Native.ForceForeground` attaches to the front window's input for a moment, and a low-level mouse hook closes
  the panel on a click elsewhere even if it never became active.
- **Don't name a namespace `…Windows`**: it hides WinRT's `Windows.*` namespaces.

## What's next

Port the sources first, one at a time, each checked with real data ([below](#checking-with-real-data)), in
this order:

1. **Copilot sessions**, the closest to the Mac: on Windows the data is laid out the same way, in
   `%USERPROFILE%\.copilot`, with the Copilot app's database `data.db` and each session's log in
   `session-state\<id>\events.jsonl`. Port `Sources/CopilotCore`.
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

Then, each checked the same way: consent for each source, and Settings; the brief from real data; opening a
row's item; notifications (`AppNotificationManager` works without a package); Launch at Login; the window with
its pages (the Sprint, the Overview, a work item's details); summaries, with the Copilot CLI only; agents
(`--mcp`); and packaging, signing and updates.

Keep the logic out of the app: a `BriefBar.Core` class library with no UI, a folder per source like
`Sources/*Core`, and a test project with the Swift tests ported to it, all with made-up data. Keep the Swift
names, such as `PRStore` and `SessionEngine`, so changes can be brought over either way, and add `dotnet test`
to `.github/workflows/windows.yml`. [How it works](../docs/how-it-works.md) is the spec for what each source
shows, and why.

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
