<#
Records the Elgato Game Capture HD composite feed WITHOUT launching the
GameCapture.exe GUI, by loading its own .NET assembly in-process and calling
its native Elgato.VideoCapture.VideoCaptureApiEx capture API directly.
Adapted from the proven probe (N64 2/.codex-work/capture-elgato-api.ps1).

This is the fix for the driver-crash risk documented in this session: the
crash (bugcheck 0x3B/0x7E in ucx01000.sys, ElgatoGC658.sys) only happens
when GameCapture.exe is force-terminated with a USB transfer in flight.
Running the capture API in-process inside this PowerShell session and
calling Capture_StopCapturing()/Release() before exiting normally avoids
that abrupt-termination race entirely -- there is no separate GUI process
to ever force-kill. Prefer this over launching GameCapture.exe for any
scripted/hardware-loop capture.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [int]$Seconds = 60,

    [string]$GameCaptureDir = 'C:\Program Files\Elgato\GameCapture'
)

$ErrorActionPreference = 'Stop'
$null = Add-Type -AssemblyName System.Windows.Forms

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue

[AppDomain]::CurrentDomain.add_AssemblyResolve({
    param($sender, $args)
    $path = Join-Path $GameCaptureDir ($args.Name.Split(',')[0] + '.dll')
    if (Test-Path -LiteralPath $path) {
        try { return [Reflection.Assembly]::LoadFrom($path) } catch { }
    }
    return $null
})

$asm = [Reflection.Assembly]::LoadFrom((Join-Path $GameCaptureDir 'GameCapture.exe'))
$api = [Activator]::CreateInstance($asm.GetType('Elgato.VideoCapture.VideoCaptureApiEx'))

$initResult = $api.Initialize(2, '')
Write-Host "Capture API initialized (result=$initResult)."
if (-not $initResult) {
    throw 'VideoCaptureApiEx.Initialize returned failure -- is the Game Capture HD device connected?'
}

try {
    $api.Capture_StartCapturing($OutputPath, $true)
    Write-Host "Recording to $OutputPath for $Seconds seconds..."
} catch {
    throw "Capture_StartCapturing failed: $($_.Exception.Message)"
}

$end = [DateTime]::UtcNow.AddSeconds($Seconds)
while ([DateTime]::UtcNow -lt $end) {
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 100
}

try {
    $api.Capture_StopCapturing()
    Write-Host 'Capture stopped cleanly.'
} catch {
    Write-Warning "Capture_StopCapturing threw: $($_.Exception.Message)"
}

# Let the writer finish flushing the file before releasing the API.
for ($i = 0; $i -lt 50; $i++) {
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 100
}

$api.Release()
Write-Host 'Capture API released.'

if (Test-Path -LiteralPath $OutputPath) {
    $item = Get-Item -LiteralPath $OutputPath
    [pscustomobject]@{
        Path         = $item.FullName
        Bytes        = $item.Length
        LastWriteUtc = $item.LastWriteTimeUtc
    }
} else {
    throw "No output file was produced at $OutputPath."
}
