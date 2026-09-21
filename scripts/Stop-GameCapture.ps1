<#
Safely closes Elgato Game Capture HD (GameCapture.exe) instead of force-killing it.

Why this exists:
Task Manager's "End Task" calls TerminateProcess, which yanks the process out
from under its kernel driver (ElgatoGC658.sys, dated 2016, unmaintained) while
a USB isochronous transfer may still be in flight. The driver's URB completion
handler then dereferences a WDF object whose handle no longer belongs to a
live process, which triggers bugcheck 0x3B/0x7E in ucx01000.sys
(Urb_LegacyTransferUrbCompletion). Confirmed from minidumps
092126-14078-01.dmp and 092026-12109-01.dmp, same failure bucket both times.

This script instead asks the process to close via its normal window-close
path (WM_CLOSE), which lets the app stop the capture stream and release its
device handle cleanly before exiting -- avoiding the race that crashes the
driver. Only if the app is well and truly hung does it fall back to a
force-kill, which reintroduces the crash risk, so that fallback is opt-in.
#>

[CmdletBinding()]
param(
    [int]$GracefulTimeoutSeconds = 15,
    [switch]$ForceIfHung
)

$procs = Get-Process -Name "GameCapture" -ErrorAction SilentlyContinue

if (-not $procs) {
    Write-Host "GameCapture.exe is not running."
    exit 0
}

foreach ($proc in $procs) {
    Write-Host "Requesting graceful close of GameCapture (PID $($proc.Id))..."

    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
        $null = $proc.CloseMainWindow()
    } else {
        Write-Warning "No main window handle found for PID $($proc.Id); it may already be minimized to tray or headless. Waiting anyway in case it exits on its own."
    }

    $exited = $proc.WaitForExit($GracefulTimeoutSeconds * 1000)

    if ($exited) {
        Write-Host "GameCapture closed cleanly."
        continue
    }

    if ($ForceIfHung) {
        Write-Warning "GameCapture did not close within $GracefulTimeoutSeconds s. Force-killing PID $($proc.Id) -- this can crash the ElgatoGC658Y driver if a USB transfer is in flight. Consider stopping the capture in-app instead."
        Stop-Process -Id $proc.Id -Force
    } else {
        Write-Warning "GameCapture did not close within $GracefulTimeoutSeconds s. Not force-killing it, because that is what triggers the driver crash (bugcheck 0x3B/0x7E in ucx01000.sys). Stop the capture/recording inside the app first, or re-run with -ForceIfHung if you accept the crash risk."
    }
}
