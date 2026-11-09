# Elgato Game Capture HD: BSOD when force-killing GameCapture.exe

If you force-close **GameCapture.exe** (Task Manager → End Task, or any
other `TerminateProcess`-style kill) while the original **Elgato Game
Capture HD** (2013-era hardware, USB `VID_0FD9&PID_0051`) is actively
capturing, Windows can bugcheck with `SYSTEM_SERVICE_EXCEPTION` (`0x3B`) or
`KMODE_EXCEPTION_NOT_HANDLED` (`0x7E`).

This is a real kernel-driver bug, not user error, and it isn't going to get
a vendor fix — the driver behind it hasn't been touched since 2016. This
repo documents the root cause from an actual crash dump and gives a drop-in
workaround.

## Quick fix

Close Game Capture HD with the included script instead of Task Manager's
**End Task**:

```powershell
.\scripts\Stop-GameCapture.ps1
```

If you automate captures, use `scripts\Capture-Elgato-Native.ps1` instead so
there is no GUI process to kill at all. Both scripts are explained in
[The fix](#the-fix).

## Root cause

`ElgatoGC658.sys` (service `ElgatoGC658Y`) is the AVStream kernel driver
for the original Game Capture HD. It's old:

- File version `2.1.1.5`, product version `2.3.0.0`, built **2016-08-03**
- Code-signing certificate expired **2017-05-11**
- No updates since — Elgato/Corsair does not support this hardware on
  modern Windows, and never will

The driver has a use-after-free race in its USB transfer-completion path.
When something cancels an in-flight USB transfer abruptly -- which is
exactly what happens when the owning process (`GameCapture.exe`) is
force-terminated mid-capture -- the URB completion callback runs against a
WDF object whose handle no longer belongs to a live process, and the kernel
dereferences it:

```
ucx01000!Urb_LegacyTransferUrbCompletion
  -> Wdf01000!imp_WdfObjectGetTypedContextWorker
    -> Wdf01000!FxObject::_GetObjectFromHandle  (inlined)
      -> access violation (0xc0000005) on a stale handle
```

Confirmed from two independent minidumps on the same machine, both with
identical `FAILURE_BUCKET_ID: AV_ucx01000!Urb_LegacyTransferUrbCompletion`:

**Crash 1** -- directly tied to killing the app:
```
BUGCHECK_CODE:  3b
BUGCHECK_P1: c0000005
PROCESS_NAME:  GameCapture.ex
FAILURE_BUCKET_ID:  AV_ucx01000!Urb_LegacyTransferUrbCompletion
```

Stack (top of the relevant frames):
```
nt!KiSystemServiceExit
nt!KiInitiateUserApc
nt!KiDeliverApc
nt!KiSchedulerApcTerminate
nt!PspExitThread                      <- the terminated process's thread exiting
nt!IoCancelThreadIo
nt!IoCancelIrp
Wdf01000!FxIrpQueue::_WdmCancelRoutineInternal
Wdf01000!FxIoQueue::_IrpCancelForQueue
Wdf01000!FxIoQueue::CancelForQueue
Wdf01000!FxRequest::CompleteWithInformation (inlined)
Wdf01000!FxRequest::Complete
Wdf01000!FxRequest::CompleteInternal
Wdf01000!FxIrp::CompleteRequest (inlined)
nt!IofCompleteRequest
nt!IopfCompleteRequest
nt!IopUnloadSafeCompletion
ucx01000!Urb_LegacyTransferUrbCompletion+0x61
Wdf01000!imp_WdfObjectGetTypedContextWorker+0x5b   <- faults here
```

**Crash 2** -- same failure bucket, this time hit by a `System` worker
thread during device teardown rather than the app's own exit, confirming
it's a genuine, reproducible driver bug and not a one-off:
```
BUGCHECK_CODE:  7e
PROCESS_NAME:  System
FAILURE_BUCKET_ID:  AV_ucx01000!Urb_LegacyTransferUrbCompletion
```

`ucx01000.sys` is the Windows-inbox USB Connector Extension (part of the
generic USB 3.x host controller stack), and it's the same on every Windows
PC -- it isn't the culprit. The bug is that Elgato's client driver
(`ElgatoGC658.sys`) doesn't correctly synchronize its own object cleanup
against a USB transfer completion racing in from process/thread teardown.
That's a client-driver bug, not something ucx01000.sys or Windows can guard
against generically.

## The fix

You can't patch a closed-source, WHQL-signed kernel driver safely (doing so
requires disabling driver signature enforcement machine-wide, which is a
worse trade than the bug). The real fix is to stop triggering the race:
**never force-terminate GameCapture.exe while it's capturing.** Close it
normally (or send it a clean `WM_CLOSE`), and the driver's own shutdown
path runs instead of getting yanked out from under an in-flight transfer.

### `scripts/Stop-GameCapture.ps1`

Drop-in replacement for Task Manager's "End Task": closes GameCapture.exe
via its normal window-close handler instead of `TerminateProcess`. Refuses
to force-kill by default (that's the thing that crashes the driver) --
pass `-ForceIfHung` only if you've accepted that risk for a genuinely wedged
process.

```powershell
.\Stop-GameCapture.ps1
```

### `scripts/Capture-Elgato-Native.ps1`

For anyone scripting/automating captures (soak tests, CI, hardware-in-the-
loop rigs): don't launch the GameCapture.exe GUI at all. Its own `.NET`
assembly can be loaded in-process and its capture API called directly --
`Capture_StartCapturing` / `Capture_StopCapturing` / `Release()` -- from a
plain PowerShell script. Since there's no separate GUI process, there's
nothing to ever force-kill, so the race can't happen by construction:

```powershell
.\Capture-Elgato-Native.ps1 -OutputPath C:\captures\clip.mp4 -Seconds 60
```

## Diagnosing this yourself

If you hit a BSOD around `GameCapture.exe` and want to confirm it's this
bug rather than something else:

1. Install WinDbg: `winget install Microsoft.WinDbg`
2. Find the minidump: `C:\Windows\Minidump\*.dmp` (the exact filename is
   also printed in `Event Viewer -> Windows Logs -> System`, search for
   Event ID 1001 from `Microsoft-Windows-WER-SystemErrorReporting`)
3. Analyze it:
   ```
   cdb.exe -z <path-to-dump> -y "srv*C:\symbols*https://msdl.microsoft.com/download/symbols" -c "!analyze -v; q"
   ```
4. Look for `FAILURE_BUCKET_ID: AV_ucx01000!Urb_LegacyTransferUrbCompletion`
   and `PROCESS_NAME: GameCapture.ex` (or `System`, if it happened during
   teardown rather than at the exact moment of the kill).

## Hardware affected

Confirmed on the original **Elgato Game Capture HD** (USB
`VID_0FD9&PID_0051`), driver service `ElgatoGC658Y`. This is Elgato's first
capture card (2013), long discontinued. Newer Elgato capture devices use
different, actively-maintained drivers and are not known to have this
specific bug -- if you're hitting something that looks similar on newer
hardware, it's a different driver and worth reporting to Elgato/Corsair
directly, since those products are still supported.

## Credits and provenance

This is independent, unaffiliated reverse-engineering of observed crash
behavior. Not affiliated with Elgato, Corsair, or Microsoft.

## License

MIT. See [LICENSE](LICENSE). The scripts are provided as-is; force-killing a
wedged capture with `-ForceIfHung` is at your own risk.
