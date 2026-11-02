# Checks BriefBar for Windows end to end with made-up data, through UI Automation: a bar at the top of each display,
# with the work area below it; its items named in words; the Overview's panel, its groups and rows; Ctrl+1, Ctrl+2,
# Ctrl+Tab and Ctrl+Shift+Tab in the panel; the same item on another display's bar, right after a press on this one;
# Copilot's panel, from its made-up sessions, with the Mac's groups, Idle folded, Clear and rows that open; Settings,
# with Copilot's page and its settings, closing the panel as it comes to the front; Azure DevOps' panel, from its
# made-up pull requests, with the Mac's groups, Mark as seen, Answered seen once the panel closes, and its page in
# Settings, whose Show To review in the bar changes what the bar counts; GitHub's panel, from its made-up pull
# requests, with the Mac's groups, its foot and the account it reads as, rows that open, and its page in Settings;
# Alt+F4 leaving a bar alone; each bar keeping its display, its window open, as displays change, and still opening
# panels; a second start while it starts opening its Overview; and every display's work area given back within a
# second of quitting, whether from scripts\quit.ps1 or because another program asked a bar to close. Build first: it
# quits a BriefBar that's running, and starts its own with --demo.
# It works over a disconnected remote session too, which has one display and can't take keys. Leave the mouse and
# keyboard alone while it runs: a click anywhere but BriefBar closes the panel it's checking, as it should, and the
# panel's keys are sent only while it's in front.
param(
    [string] $Exe = (Join-Path -Path $PSScriptRoot -ChildPath '..\BriefBar\bin\Debug\net10.0-windows10.0.26100.0\win-x64\BriefBar.exe')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class SmokeNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct MonitorInfo { public int Size; public Rect Monitor; public Rect Work; public uint Flags; }

    delegate bool MonitorProc(IntPtr monitor, IntPtr hdc, ref Rect rect, IntPtr data);

    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorProc proc, IntPtr data);
    [DllImport("user32.dll")] static extern bool GetMonitorInfoW(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint process);
    [DllImport("wtsapi32.dll")] static extern bool WTSQuerySessionInformationW(IntPtr server, int session, int infoClass, out IntPtr buffer, out int bytes);
    [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr memory);

    /// The process whose window is in front, or 0.
    public static uint ForegroundProcess()
    {
        GetWindowThreadProcessId(GetForegroundWindow(), out var process);
        return process;
    }

    /// The window in front, or 0.
    public static IntPtr ForegroundWindow() { return GetForegroundWindow(); }

    /// Whether this session is connected, as a remote session that's been disconnected isn't: keys sent to it go nowhere.
    public static bool IsConnected()
    {
        // The current session's WTSConnectState, which is WTSActive, 0, while it's connected.
        if (!WTSQuerySessionInformationW(IntPtr.Zero, -1, 8, out var buffer, out _)) return true;
        try { return Marshal.ReadInt32(buffer) == 0; }
        finally { WTSFreeMemory(buffer); }
    }

    /// Each display's bounds and work area, in physical pixels: "left,top,right,bottom|left,top,right,bottom".
    public static List<string> Displays()
    {
        var all = new List<string>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr monitor, IntPtr hdc, ref Rect rect, IntPtr data) =>
        {
            var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
            GetMonitorInfoW(monitor, ref info);
            all.Add(string.Format("{0},{1},{2},{3}|{4},{5},{6},{7}",
                info.Monitor.Left, info.Monitor.Top, info.Monitor.Right, info.Monitor.Bottom,
                info.Work.Left, info.Work.Top, info.Work.Right, info.Work.Bottom));
            return true;
        }, IntPtr.Zero);
        return all;
    }
}
'@
# Physical pixels, as BriefBar and UI Automation use them.
[void][SmokeNative]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

$WM_CLOSE = 0x0010
$WM_DISPLAYCHANGE = 0x007E
$WM_SYSCOMMAND = 0x0112
$SC_CLOSE = 0xF060

$A = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$Type = [System.Windows.Automation.ControlType]
$failures = [System.Collections.Generic.List[string]]::new()

function Check([bool] $condition, [string] $what) {
    if ($condition) { Write-Host "ok    $what" } else { Write-Host "FAIL  $what"; $failures.Add($what) }
}

function Wait-Until([scriptblock] $condition, [int] $seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Condition($property, $value) { [System.Windows.Automation.PropertyCondition]::new($property, $value) }

function Start-BriefBar {
    if (Get-Process -Name BriefBar -ErrorAction SilentlyContinue) {
        & (Join-Path -Path $PSScriptRoot -ChildPath 'quit.ps1') | Out-Null
        [void](Wait-Until { -not (Get-Process -Name BriefBar -ErrorAction SilentlyContinue) } 10)
    }
    $started = Start-Process -FilePath $Exe -ArgumentList '--demo' -PassThru
    # Holding its handle from the start keeps its exit code readable once it ends.
    [void]$started.Handle
    $started
}

# The process's bars, each found by its Overview's item, or nothing until there's one per display, each a window of its
# own placed at the top of its display.
function Find-Bars($process, [int] $count) {
    $found = @($A::RootElement.FindAll($Scope::Children, (Condition $A::ProcessIdProperty $process.Id)) |
        Where-Object { $_.FindFirst($Scope::Descendants, (Condition $A::AutomationIdProperty 'OverviewButton')) })
    $windows = @($found | ForEach-Object { $_.Current.NativeWindowHandle } | Sort-Object -Unique)
    $tops = @([SmokeNative]::Displays() | ForEach-Object { (($_ -split '\|')[0] -split ',')[0..1] -join ',' })
    $placed = @($found | Where-Object { $tops -contains ('{0},{1}' -f [int]$_.Current.BoundingRectangle.Left, [int]$_.Current.BoundingRectangle.Top) })
    if ($found.Count -eq $count -and $windows.Count -eq $count -and $placed.Count -eq $count) { $found }
}

function Invoke-Item($element) {
    $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Get-OverviewItem($bar) { $bar.FindFirst($Scope::Descendants, (Condition $A::AutomationIdProperty 'OverviewButton')) }

# The panel's list, under the bar it opened from, as UI Automation shows an owned window.
function Get-PanelList($bar) { $bar.FindFirst($Scope::Descendants, (Condition $A::ControlTypeProperty $Type::List)) }

# Sends `keys` to BriefBar's panel, only while it's in front, so they can't reach another app; false if it isn't.
function Send-PanelKeys($process, [string] $keys) {
    if ([SmokeNative]::ForegroundProcess() -ne $process.Id) { return $false }
    [System.Windows.Forms.SendKeys]::SendWait($keys)
    return $true
}

# The first button under `$element` whose name is like `$pattern`.
function Get-Button($element, [string] $pattern) {
    @($element.FindAll($Scope::Descendants, (Condition $A::ControlTypeProperty $Type::Button))) |
        Where-Object { $_.Current.Name -like $pattern } | Select-Object -First 1
}

# What a panel's list shows as groups, "Needs you: 3", in order.
function Get-GroupNames($list) {
    @($list.FindAll($Scope::Children, (Condition $A::ControlTypeProperty $Type::Group)) | ForEach-Object { $_.Current.Name })
}

# Every group a panel's list shows, "Needs you: 3", in order, scrolling through it from its top: it has only those on
# screen. It's back at its top after.
function Get-AllGroupNames($list) {
    $scroll = $list.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    $scroll.SetScrollPercent(-1, 0)
    $names = [System.Collections.Generic.List[string]]::new()
    for ($step = 0; $step -lt 30; $step++) {
        Start-Sleep -Milliseconds 150
        foreach ($name in Get-GroupNames $list) { if (-not $names.Contains($name)) { $names.Add($name) } }
        if (-not $scroll.Current.VerticallyScrollable -or $scroll.Current.VerticalScrollPercent -ge 99.9) { break }
        $scroll.Scroll([System.Windows.Automation.ScrollAmount]::NoAmount, [System.Windows.Automation.ScrollAmount]::LargeIncrement)
    }
    $scroll.SetScrollPercent(-1, 0)
    @($names)
}

# Opens Copilot's panel under `$bar`, and returns its list.
function Open-Copilot($bar) {
    Invoke-Item (Get-Button $bar 'GitHub Copilot sessions: *')
    Wait-Until { $list = Get-PanelList $bar; if ($list -and $list.Current.Name -eq 'Sessions') { $list } } 5
}

# Copilot's panel, from its made-up sessions (`CopilotDemoData`): the Mac's groups in its order, Idle folded until you
# unfold it, Clear moving what's done to Idle, and a session that opens closing the panel; then Settings, from the
# panel, with Copilot's page, whose Show context usage shows each session's context on its row, and which closes the
# panel as it comes to the front.
function Test-Copilot($process, $bar) {
    Check ($null -ne (Get-Button $bar 'GitHub Copilot sessions: 3 need you, 2 running, 1 done or ready, 1 went wrong.*')) "Copilot's item counts its made-up sessions"
    # Past the 600 ms in which a press counts as the one that closed the panel, should one have.
    Start-Sleep -Milliseconds 700
    $list = Open-Copilot $bar
    Check ($null -ne $list) "pressing it opens Copilot's sessions"
    if (-not $list) { return }
    $groups = Get-GroupNames $list
    Check (($groups -join ' | ') -eq 'Needs you: 3 | Running: 2 | Done: 1 | Stopped: 1 | Idle: 2') "its groups are the Mac's, in its order ($($groups -join ', '))"
    $list.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern).SetScrollPercent(-1, 100)
    $fold = Wait-Until { Get-Button $list 'Show idle, 2' } 3
    $idleRows = { @(@($list.FindAll($Scope::Children, (Condition $A::NameProperty 'Idle: 2')))[0].FindAll($Scope::Children, (Condition $A::ControlTypeProperty $Type::ListItem))).Count }
    Check ($null -ne $fold -and (& $idleRows) -eq 0) 'its idle sessions start folded'
    if ($fold) {
        Invoke-Item $fold
        Check ($null -ne (Wait-Until { if ((& $idleRows) -eq 2) { $true } } 3)) 'and unfold'
    }
    $clear = Get-Button $list 'Clear'
    if ($clear) { Invoke-Item $clear }
    $cleared = Wait-Until { $names = Get-GroupNames $list; if ($names -contains 'Idle: 3' -and -not ($names -like 'Done: *')) { $names } } 3
    Check ($null -ne $cleared) 'Clear moves what finished to Idle'
    Check ($null -ne (Get-Button $bar 'GitHub Copilot sessions: 3 need you, 2 running, 1 went wrong.*')) 'and the bar stops counting it'
    $row = $list.FindFirst($Scope::Descendants, (Condition $A::ControlTypeProperty $Type::ListItem))
    if ($row) { Invoke-Item $row }
    Check ($null -ne (Wait-Until { if (-not (Get-PanelList $bar)) { $true } } 3)) 'pressing a session closes the panel, as it opens the session'

    # Settings, from the panel's foot.
    $list = Open-Copilot $bar
    if ($list) { Invoke-Item (Get-Button $bar 'Settings') }
    $settings = Wait-Until { $A::RootElement.FindFirst($Scope::Children, [System.Windows.Automation.AndCondition]::new(
                (Condition $A::ProcessIdProperty $process.Id), (Condition $A::NameProperty 'BriefBar Settings'))) } 5
    Check ($null -ne $settings -and -not (Get-PanelList $bar)) 'its Settings button opens Settings, in place of the panel'
    if (-not $settings) { return }
    $title = Wait-Until { $settings.FindFirst($Scope::Descendants, (Condition $A::AutomationIdProperty 'PageTitle')) } 3
    Check ($null -ne $title -and $title.Current.Name -eq 'GitHub Copilot') "at Copilot's page"
    $toggle = Get-Button $settings 'Show context usage'
    $state = if ($toggle) { $toggle.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern) }
    Check ($null -ne $state -and $state.Current.ToggleState -eq 'Off') 'which lists its settings, as they start'
    if (-not $state) { return }
    $state.Toggle()
    $list = Open-Copilot $bar
    # Copilot resolves its sessions again once the setting changes; the panel follows.
    $measured = Wait-Until { if ($list) { $rows = @($list.FindAll($Scope::Descendants, (Condition $A::ControlTypeProperty $Type::ListItem)) | Where-Object { $_.Current.Name -like '*, Context: *% full (*' }); if ($rows.Count -ge 2) { $rows } } } 5
    Check (@($measured).Count -ge 2) "Show context usage shows each measured session's context ($(@($measured).Count) rows on screen)"

    # Settings is somewhere else, as another app is: coming to the front, it closes the panel, and keeps the keyboard.
    $settingsWindow = [IntPtr]$settings.Current.NativeWindowHandle
    if ($list -and [SmokeNative]::IsConnected() -and [SmokeNative]::ForegroundProcess() -eq $process.Id -and [SmokeNative]::ForegroundWindow() -ne $settingsWindow) {
        $focusable = $settings.FindFirst($Scope::Descendants, [System.Windows.Automation.AndCondition]::new(
                (Condition $A::IsKeyboardFocusableProperty $true), (Condition $A::IsEnabledProperty $true)))
        try { $focusable.SetFocus() } catch { Write-Host "      couldn't focus Settings: $($_.Exception.Message)" }
        $closed = Wait-Until { if (-not (Get-PanelList $bar)) { $true } } 3
        # Time for a panel that took the keyboard back, as it does after a press on a bar, to have done so.
        Start-Sleep -Milliseconds 300
        Check ($null -ne $closed -and [SmokeNative]::ForegroundWindow() -eq $settingsWindow) 'Settings coming to the front closes the panel, and keeps the keyboard'
    }
    else {
        Write-Host "skip  Settings coming to the front (the session is disconnected, or the panel isn't in front)"
    }
}

# Opens Azure DevOps' panel under `$bar`, and returns its list.
function Open-AzureDevOps($bar) {
    Invoke-Item (Get-Button $bar 'Azure DevOps pull requests: *')
    Wait-Until { $list = Get-PanelList $bar; if ($list -and $list.Current.Name -eq 'Pull requests') { $list } } 5
}

# Azure DevOps' panel, from its made-up pull requests (`AzureDevOpsDemoData`) through the classifier: the Mac's groups in
# its order, Idle folded, Mark as seen keeping what waits on you, a pull request that opens closing the panel, and what
# Answered showed going back to its group once the panel closes; then its page in Settings, whose Show To review in the
# bar counts To review with what needs you.
function Test-AzureDevOps($process, $bar) {
    Check ($null -ne (Get-Button $bar 'Azure DevOps pull requests: 3 need you, 2 went wrong, 2 done or ready.*')) "Azure DevOps' item counts its made-up pull requests"
    # Past the 600 ms in which a press counts as the one that closed the panel, should one have.
    Start-Sleep -Milliseconds 700
    $list = Open-AzureDevOps $bar
    Check ($null -ne $list) "pressing it opens Azure DevOps' pull requests"
    if (-not $list) { return }
    $groups = Get-AllGroupNames $list
    Check (($groups -join ' | ') -eq 'Needs you: 3 | Answered: 1 | Failing: 2 | Ready to complete: 2 | To review: 1 | Waiting: 2 | Done: 1 | Idle: 2') "its groups are the Mac's, in its order ($($groups -join ', '))"
    Check ($null -ne (Get-Button $bar 'Open Azure DevOps') -and $null -ne (Get-Button $bar 'Refresh')) 'its foot opens Azure DevOps and refreshes'
    $list.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern).SetScrollPercent(-1, 100)
    $idleRows = { @(@($list.FindAll($Scope::Children, (Condition $A::NameProperty 'Idle: 2')))[0].FindAll($Scope::Children, (Condition $A::ControlTypeProperty $Type::ListItem))).Count }
    Check ($null -ne (Wait-Until { Get-Button $list 'Show idle, 2' } 3) -and (& $idleRows) -eq 0) 'its idle pull requests start folded'
    $list.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern).SetScrollPercent(-1, 0)
    $seen = Get-Button $list 'Mark as seen'
    if ($seen) { Invoke-Item $seen }
    # The review request waits under To review; the reply and the mention, which wait on you, stay.
    $marked = Wait-Until { $names = Get-AllGroupNames $list; if ($names -contains 'Needs you: 2' -and $names -contains 'To review: 2') { $names } } 5
    Check ($null -ne $marked -and -not (Get-Button $list 'Mark as seen')) 'Mark as seen keeps what waits on you'
    Check ($null -ne (Get-Button $bar 'Azure DevOps pull requests: 2 need you, 2 went wrong, 2 done or ready.*')) 'and the bar counts what still needs you'
    $row = $list.FindFirst($Scope::Descendants, (Condition $A::ControlTypeProperty $Type::ListItem))
    if ($row) { Invoke-Item $row }
    Check ($null -ne (Wait-Until { if (-not (Get-PanelList $bar)) { $true } } 3)) 'pressing a pull request closes the panel, as it opens it'
    Start-Sleep -Milliseconds 700
    $list = Open-AzureDevOps $bar
    $groups = if ($list) { Get-AllGroupNames $list } else { @() }
    Check (-not ($groups -like 'Answered: *') -and $groups -contains 'Idle: 3') "what Answered showed goes back to its group once the panel closes ($($groups -join ', '))"

    # Settings, from the panel's foot, at Azure DevOps' page.
    if ($list) { Invoke-Item (Get-Button $bar 'Settings') }
    $settings = Wait-Until { $A::RootElement.FindFirst($Scope::Children, [System.Windows.Automation.AndCondition]::new(
                (Condition $A::ProcessIdProperty $process.Id), (Condition $A::NameProperty 'BriefBar Settings'))) } 5
    $title = if ($settings) { Wait-Until { $found = $settings.FindFirst($Scope::Descendants, (Condition $A::AutomationIdProperty 'PageTitle')); if ($found -and $found.Current.Name -eq 'Azure DevOps') { $found } } 3 }
    Check ($null -ne $title) "its Settings button opens Settings at Azure DevOps' page"
    if (-not $title) { return }
    $organization = Get-Button $settings 'contoso'
    Check ($null -ne $organization) 'which lists its organization'
    $toggle = Get-Button $settings 'Show To review in the bar'
    $state = if ($toggle) { $toggle.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern) }
    Check ($null -ne $state -and $state.Current.ToggleState -eq 'Off') 'and its settings, as they start'
    if (-not $state) { return }
    $state.Toggle()
    Check ($null -ne (Wait-Until { Get-Button $bar 'Azure DevOps pull requests: 4 need you, 2 went wrong, 2 done or ready.*' } 5)) 'Show To review in the bar counts To review with what needs you'
}

# Opens GitHub's panel under `$bar`, and returns its list: titled Pull requests too, it's told from Azure DevOps' by its
# first group.
function Open-GitHub($bar) {
    Invoke-Item (Get-Button $bar 'GitHub pull requests: *')
    Wait-Until { $list = Get-PanelList $bar; if ($list -and $list.Current.Name -eq 'Pull requests' -and (Get-GroupNames $list) -contains 'To review: 2') { $list } } 5
}

# GitHub's panel, from its made-up pull requests (`GitHubDemoData`) through the classifier: the Mac's groups in its order,
# Waiting listed but not counted, its foot with Open GitHub, the account it reads as and a refresh, a pull request that
# opens closing the panel; then its page in Settings, with how often it reads.
function Test-GitHub($process, $bar) {
    Check ($null -ne (Get-Button $bar 'GitHub pull requests: 3 need you, 2 went wrong, 1 done or ready.*')) "GitHub's item counts its made-up pull requests, not those that wait"
    # Past the 600 ms in which a press counts as the one that closed the panel, should one have.
    Start-Sleep -Milliseconds 700
    $list = Open-GitHub $bar
    Check ($null -ne $list) "pressing it opens GitHub's pull requests"
    if (-not $list) { return }
    $groups = Get-AllGroupNames $list
    Check (($groups -join ' | ') -eq 'To review: 2 | Changes requested: 1 | Failing: 2 | Ready to merge: 1 | Waiting: 2') "its groups are the Mac's, in its order ($($groups -join ', '))"
    Check ($null -ne (Get-Button $bar 'Open GitHub') -and $null -ne (Get-Button $bar 'Refresh')) 'its foot opens GitHub and refreshes'
    $account = $bar.FindFirst($Scope::Descendants, (Condition $A::NameProperty 'Signed in to the GitHub CLI as robin'))
    Check ($null -ne $account) 'and says who it reads as'
    $row = $list.FindFirst($Scope::Descendants, (Condition $A::ControlTypeProperty $Type::ListItem))
    Check ($null -ne $row -and $row.Current.Name -like '*, Review requested, By *, contoso/*#*') "its rows say why each is there, and which it is ($(if ($row) { $row.Current.Name -replace ',.*$', '' }))"
    if ($row) { Invoke-Item $row }
    Check ($null -ne (Wait-Until { if (-not (Get-PanelList $bar)) { $true } } 3)) 'pressing a pull request closes the panel, as it opens it'

    # Settings, from the panel's foot, at GitHub's page.
    Start-Sleep -Milliseconds 700
    $list = Open-GitHub $bar
    if ($list) { Invoke-Item (Get-Button $bar 'Settings') }
    $settings = Wait-Until { $A::RootElement.FindFirst($Scope::Children, [System.Windows.Automation.AndCondition]::new(
                (Condition $A::ProcessIdProperty $process.Id), (Condition $A::NameProperty 'BriefBar Settings'))) } 5
    $title = if ($settings) { Wait-Until { $found = $settings.FindFirst($Scope::Descendants, (Condition $A::AutomationIdProperty 'PageTitle')); if ($found -and $found.Current.Name -eq 'GitHub') { $found } } 3 }
    Check ($null -ne $title) "its Settings button opens Settings at GitHub's page"
    if (-not $title) { return }
    $refresh = $settings.FindFirst($Scope::Descendants, [System.Windows.Automation.AndCondition]::new(
            (Condition $A::ControlTypeProperty $Type::ComboBox), (Condition $A::NameProperty 'Refresh')))
    $chosen = if ($refresh) { $refresh.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection() | ForEach-Object { $_.Current.Name } }
    Check ($chosen -eq 'Every 2 minutes') "which reads every 2 minutes, as it starts ($chosen)"
}

# Asks BriefBar to quit with `$ask`, and checks that every display's work area is back within a second, and that it
# ends within three, without an error: an unexpected error gives the space back too, and ends with 1.
function Test-Quit($process, $before, [scriptblock] $ask, [string] $how) {
    $started = [Diagnostics.Stopwatch]::StartNew()
    & $ask
    $restored = Wait-Until { -not (Compare-Object -ReferenceObject $before -DifferenceObject ([SmokeNative]::Displays())) } 3
    $spaceBack = $started.ElapsedMilliseconds
    $ended = $process.WaitForExit(3000)
    Check ([bool]$restored -and $spaceBack -le 1000) "$how gives the space back within a second ($spaceBack ms)"
    Check $ended "and it ends within three seconds ($($started.ElapsedMilliseconds) ms)"
    if ($ended) {
        Check ($process.ExitCode -eq 0) "without an error (exit code $($process.ExitCode))"
    }
    else {
        Stop-Process -Id $process.Id
    }
}

# Everything but quitting, on a running BriefBar.
function Test-Running($process, $before) {
    $bars = Wait-Until { Find-Bars -process $process -count $before.Count } 15
    Check ($null -ne $bars) "a bar on each of the $($before.Count) displays"
    if (-not $bars) { return }
    $during = [SmokeNative]::Displays()
    foreach ($bar in @($bars)) {
        $rect = $bar.Current.BoundingRectangle
        $display = @($during) | Where-Object {
            $bounds = ($_ -split '\|')[0] -split ','
            [int]$bounds[0] -eq [int]$rect.Left -and [int]$bounds[1] -eq [int]$rect.Top -and [int]$bounds[2] -eq [int]$rect.Right
        }
        Check ($null -ne $display) "the bar at $($rect.Left),$($rect.Top) spans its display's top"
        if ($display) {
            $work = ($display -split '\|')[1] -split ','
            Check ([int]$work[1] -ge [int]$rect.Bottom) "its display's work area starts below it ($($work[1]) >= $($rect.Bottom))"
        }
        Check ((Get-OverviewItem $bar).Current.Name -like 'Overview: *') "its Overview's item is named in words"
        $buttons = @($bar.FindAll($Scope::Descendants, (Condition $A::ControlTypeProperty $Type::Button)))
        $unnamed = @($buttons | Where-Object { $_.Current.Name -notmatch '^[A-Z][\w ]+: ' })
        Check ($buttons.Count -ge 2 -and $unnamed.Count -eq 0) "its $($buttons.Count) items are named in words"
        $keys = @($buttons | ForEach-Object { $_.Current.AcceleratorKey }) -join ', '
        $expected = @(1..$buttons.Count | ForEach-Object { if ($_ -le 9) { "Ctrl+$_" } else { '' } }) -join ', '
        Check ($keys -eq $expected) "and say their keys in order ($keys)"
    }

    # The Overview's panel: its list, its groups by state, and its rows.
    $first = @($bars)[0]
    Invoke-Item (Get-OverviewItem $first)
    $list = Wait-Until { Get-PanelList $first } 5
    Check ($null -ne $list -and $list.Current.Name -eq 'Overview') 'pressing it opens the Overview'
    if ($list) {
        $groups = @($list.FindAll($Scope::Children, (Condition $A::ControlTypeProperty $Type::Group)))
        Check ($groups.Count -ge 1 -and $groups[0].Current.Name -like 'Needs you: *') "its first group is Needs you ($($groups.Count) on screen)"
        $rows = @($list.FindAll($Scope::Descendants, (Condition $A::ControlTypeProperty $Type::ListItem)))
        Check ($rows.Count -ge 1) "it has rows ($($rows.Count) on screen)"
        $badNames = @($rows | Where-Object { $_.Current.Name -match '\.\.|\d+[mhd] ago' })
        Check ($badNames.Count -eq 0) 'its rows are named in words, without doubled stops'
        $doubled = @($rows | Where-Object { $_.FindFirst($Scope::Children, (Condition $A::NameProperty $_.Current.Name)) })
        Check ($doubled.Count -eq 0) 'no row says its name twice'
        $scroll = $list.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        Check ($scroll.Current.VerticalScrollPercent -le 0) 'it opens at its top'
    }

    # From the keyboard, in the panel: Ctrl+2 shows the bar's first section's, under its item, Ctrl+Tab the next,
    # Ctrl+Shift+Tab the one before, and Ctrl+1 the Overview again.
    if ($list -and [SmokeNative]::IsConnected() -and [SmokeNative]::ForegroundProcess() -eq $process.Id) {
        $overviewLeft = $list.Current.BoundingRectangle.Left
        $section = $null
        if (Send-PanelKeys $process '^2') {
            $section = Wait-Until { $shown = Get-PanelList $first; if ($shown -and $shown.Current.Name -ne 'Overview') { $shown } } 5
        }
        Check ($null -ne $section -and $section.Current.BoundingRectangle.Left -gt $overviewLeft) "Ctrl+2 shows the first section's panel, under its item ($($section.Current.Name))"
        if ($section) {
            $firstSection = $section.Current.Name
            $next = $null
            if (Send-PanelKeys $process '^{TAB}') {
                $next = Wait-Until { $shown = Get-PanelList $first; if ($shown -and $shown.Current.Name -notin @('Overview', $firstSection)) { $shown } } 5
            }
            Check ($null -ne $next) "Ctrl+Tab shows the next one's ($($next.Current.Name))"
            $back = (Send-PanelKeys $process '^+{TAB}') -and (Wait-Until { (Get-PanelList $first).Current.Name -eq $firstSection } 5)
            Check ([bool]$back) 'Ctrl+Shift+Tab shows the one before'
        }
        $list = $null
        if (Send-PanelKeys $process '^1') {
            $list = Wait-Until { $shown = Get-PanelList $first; if ($shown -and $shown.Current.Name -eq 'Overview') { $shown } } 5
        }
        Check ($null -ne $list -and $list.Current.BoundingRectangle.Left -eq $overviewLeft) 'Ctrl+1 shows the Overview again, where it was'
    }
    else {
        Write-Host "skip  the panel's keys (the session is disconnected, or the panel isn't in front)"
    }

    # The same item on another display's bar opens the panel there, rather than closing it here, even right after a
    # press on this one: that's a press of its own, not the same press arriving twice.
    if (@($bars).Count -ge 2) {
        $second = @($bars)[1]
        if (-not (Get-PanelList $first)) {
            # Past the 600 ms in which a press counts as the one that closed it, should it have closed.
            Start-Sleep -Milliseconds 700
            Invoke-Item (Get-OverviewItem $first)
            [void](Wait-Until { Get-PanelList $first } 5)
        }
        # Past the 350 ms in which a second press on the same item counts as the same press, this one closes it.
        Start-Sleep -Milliseconds 400
        Invoke-Item (Get-OverviewItem $first)
        Invoke-Item (Get-OverviewItem $second)
        $moved = Wait-Until { (Get-PanelList $second) -and -not (Get-PanelList $first) } 5
        Check ([bool]$moved) "the same item on another display's bar opens its panel there, even right after a press here"
    }
    else {
        Write-Host 'skip  the same item on another display (one display)'
    }

    Test-Copilot -process $process -bar $first
    Test-AzureDevOps -process $process -bar $first
    Test-GitHub -process $process -bar $first

    # Alt+F4 doesn't close a bar.
    $handle = [IntPtr]$first.Current.NativeWindowHandle
    [void][SmokeNative]::PostMessageW($handle, $WM_SYSCOMMAND, [IntPtr]$SC_CLOSE, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 800
    Check ([SmokeNative]::IsWindow($handle) -and -not $process.HasExited) 'Alt+F4 leaves a bar alone'

    # Displays change, as when one is plugged in or the PC wakes: the bars are arranged again, and here, where the
    # displays stay as they were, each keeps its display. No bar window closes while BriefBar runs, since closing one
    # while a UI Automation client holds on to it can crash it. Their items still open panels.
    $oldHandles = @(@($bars) | ForEach-Object { $_.Current.NativeWindowHandle } | Sort-Object)
    $log = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'BriefBar\Logs\BriefBar.log'
    $logLength = (Get-Item -Path $log).Length
    [void][SmokeNative]::PostMessageW($handle, $WM_DISPLAYCHANGE, [IntPtr]32, [IntPtr]::Zero)
    $arranged = Wait-Until {
        $stream = [IO.File]::Open($log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            [void]$stream.Seek([Math]::Min($logLength, $stream.Length), [IO.SeekOrigin]::Begin)
            $added = [IO.StreamReader]::new($stream).ReadToEnd()
        }
        finally {
            $stream.Dispose()
        }
        $added -match "bars: $($before.Count), 0 new, 0 stepped aside"
    } 10
    $again = Find-Bars -process $process -count $before.Count
    $newHandles = @(@($again) | ForEach-Object { $_.Current.NativeWindowHandle } | Sort-Object)
    Check ([bool]$arranged -and $null -ne $again -and -not (Compare-Object -ReferenceObject $oldHandles -DifferenceObject $newHandles)) 'after displays change, each bar keeps its display, its window open'
    if ($again) {
        $first = @($again)[0]
        # Arranging the bars closed the panel: past the 600 ms in which a press on its item counts as the one that
        # closed it.
        Start-Sleep -Milliseconds 700
        Invoke-Item (Get-OverviewItem $first)
        $reopened = Wait-Until { Get-PanelList $first } 5
        Check ($null -ne $reopened -and -not $process.HasExited) 'and their items still open panels'
    }
}

$before = [SmokeNative]::Displays()
$process = Start-BriefBar
try {
    Test-Running -process $process -before $before
}
finally {
    if (-not $process.HasExited) {
        Test-Quit -process $process -before $before -how 'quitting' -ask {
            & (Join-Path -Path $PSScriptRoot -ChildPath 'quit.ps1') | Out-Null
        }
    }
    else {
        Check $false "it kept running (it ended with $($process.ExitCode))"
    }
}

# Started again while it's still starting, BriefBar opens its Overview once it's up, and the second start ends. Then
# another program asking a bar to close, as `taskkill` without /F does, quits BriefBar.
$process = Start-BriefBar
$claimed = Wait-Until {
    $mutex = $null
    if ([System.Threading.Mutex]::TryOpenExisting('BriefBar.Windows', [ref]$mutex)) { $mutex.Dispose(); $true }
} 10
$second = if ($claimed) { [System.Diagnostics.Process]::Start($Exe, '--demo') }
$bars = Wait-Until { Find-Bars -process $process -count $before.Count } 15
if ($bars) {
    $overview = Wait-Until { @(@($bars) | ForEach-Object { Get-PanelList $_ } | Where-Object { $_.Current.Name -eq 'Overview' }) } 5
    Check ($null -ne $second -and $second.WaitForExit(5000) -and $second.ExitCode -eq 0 -and $null -ne $overview) 'a second start while it starts opens its Overview once it''s up, and ends'
    $handle = [IntPtr]@($bars)[0].Current.NativeWindowHandle
    Test-Quit -process $process -before $before -how 'a close request' -ask {
        [void][SmokeNative]::PostMessageW($handle, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    }
}
else {
    Check $false 'it started again'
    Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) failed"
    exit 1
}
Write-Host 'All passed'
