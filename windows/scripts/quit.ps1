# Quits BriefBar for Windows cleanly, giving back the space at the top of each display.
try {
    $signal = [System.Threading.EventWaitHandle]::OpenExisting('BriefBar.Windows.Quit')
    [void]$signal.Set()
    $signal.Dispose()
    'Asked BriefBar to quit.'
} catch [System.Threading.WaitHandleCannotBeOpenedException] {
    'BriefBar is not running.'
}
