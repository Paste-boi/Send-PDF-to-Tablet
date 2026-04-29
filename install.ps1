<#
.SYNOPSIS
    One-shot installer for the Send-PDF-to-Tablet workflow.

.DESCRIPTION
    Creates Syncthing folders if they don't exist, adds two right-click
    context menu entries to the per-user registry, and registers the watcher
    as a scheduled task that fires at logon. None of this requires admin -
    everything is per-user.

    Re-run safely: -Force on every step means the installer is idempotent.

.PARAMETER SkipFolders
    Don't create missing Syncthing folders (e.g. if you've already set them
    up under different paths and only edited config.ps1).

.PARAMETER SkipContextMenu
    Don't touch the registry.

.PARAMETER SkipScheduledTask
    Don't register the watcher scheduled task.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#>
[CmdletBinding()]
param(
    [switch] $SkipFolders,
    [switch] $SkipContextMenu,
    [switch] $SkipScheduledTask
)

$ErrorActionPreference = 'Stop'

# Friendly check for fresh clones: config.ps1 is gitignored, so a brand-new
# checkout won't have it. Point the user at the example file instead of
# letting the dot-source throw a generic file-not-found error.
$cfgPath = Join-Path $PSScriptRoot 'config.ps1'
if (-not (Test-Path -LiteralPath $cfgPath)) {
    Write-Host "config.ps1 not found." -ForegroundColor Yellow
    Write-Host "Copy the example and edit it before running install:"
    Write-Host "    Copy-Item config.example.ps1 config.ps1"
    Write-Host "    notepad config.ps1"
    exit 1
}

. $cfgPath

$sendScript    = Join-Path $PSScriptRoot 'send_to_tablet.ps1'
$watcherScript = Join-Path $PSScriptRoot 'tablet_watcher.ps1'

if (-not (Test-Path -LiteralPath $sendScript))    { throw "Missing: $sendScript" }
if (-not (Test-Path -LiteralPath $watcherScript)) { throw "Missing: $watcherScript" }

# Resolve to DOMAIN\user, which the scheduled-task cmdlets accept reliably
# regardless of whether we're on a domain-joined or stand-alone machine.
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

Write-Host "Installing Send-PDF-to-Tablet for $currentUser"
Write-Host "  project root: $PSScriptRoot"
Write-Host ""

# --- 1. Syncthing folders ---------------------------------------------------
# We create the folders so this script can run before the user has wired
# up Syncthing. The user still has to add them as Syncthing folders in the
# Syncthing UI - we can't do that from PowerShell.
if (-not $SkipFolders) {
    Write-Host "[1/3] Folders"
    foreach ($d in @($ViewOnlyInbox, $AnnotateInbox, $AnnotateOutbox)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Write-Host "      created  $d"
        } else {
            Write-Host "      exists   $d"
        }
    }
} else {
    Write-Host "[1/3] Folders   (skipped)"
}
Write-Host ""

# --- 2. Context menu entries ------------------------------------------------
function Set-ContextMenuEntry {
    # Adds a single right-click entry under HKCU. SystemFileAssociations\.pdf
    # is the right place because it survives reassigning the default app for
    # PDFs (vs. the file-type-specific ProgId, which goes away on switch).
    param(
        [string] $KeyName,
        [string] $MenuText,
        [string] $Mode
    )
    $base = "HKCU:\Software\Classes\SystemFileAssociations\.pdf\shell\$KeyName"
    if (-not (Test-Path $base))           { New-Item -Path $base           -Force | Out-Null }
    if (-not (Test-Path "$base\command")) { New-Item -Path "$base\command" -Force | Out-Null }

    Set-ItemProperty -Path $base -Name '(default)' -Value $MenuText
    # Use a stock icon - PowerShell.exe is always present, looks fine in Explorer.
    Set-ItemProperty -Path $base -Name 'Icon'      -Value 'powershell.exe,0'

    # %1 is the file path Explorer hands us. -WindowStyle Hidden suppresses
    # the PowerShell console flash; the InputBox / MessageBox windows are
    # still visible because they're separate WinForms windows.
    $cmd = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Mode {2} -Path "%1"' -f `
        (Join-Path $PSHOME 'powershell.exe'), $sendScript, $Mode
    Set-ItemProperty -Path "$base\command" -Name '(default)' -Value $cmd
}

if (-not $SkipContextMenu) {
    Write-Host "[2/3] Context menu"
    Set-ContextMenuEntry -KeyName 'SendToTabletView'     -MenuText 'Open on Tablet (View Only)' -Mode 'view'
    Set-ContextMenuEntry -KeyName 'SendToTabletAnnotate' -MenuText 'Open on Tablet (Annotate)'  -Mode 'annotate'
    Write-Host "      installed under HKCU\Software\Classes\SystemFileAssociations\.pdf\shell"
    Write-Host "      (Windows 11: you may need to click 'Show more options' or Shift+right-click to see them)"
} else {
    Write-Host "[2/3] Context menu  (skipped)"
}
Write-Host ""

# --- 3. Scheduled task ------------------------------------------------------
if (-not $SkipScheduledTask) {
    Write-Host "[3/3] Scheduled task"
    $taskName = 'Send PDF to Tablet - Watcher'

    $action = New-ScheduledTaskAction `
        -Execute  (Join-Path $PSHOME 'powershell.exe') `
        -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $watcherScript)

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser

    # Restart on failure - the watcher should never crash, but if it does
    # (e.g. Syncthing folder briefly unmounted), Task Scheduler will revive it.
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive

    Register-ScheduledTask -TaskName $taskName `
        -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Force | Out-Null
    Write-Host "      registered: '$taskName'"

    # Start it now so the user doesn't have to log out and back in.
    try {
        Start-ScheduledTask -TaskName $taskName
        Write-Host "      started"
    } catch {
        Write-Host "      could not start now (will start at next logon). Manual: Start-ScheduledTask '$taskName'"
    }
} else {
    Write-Host "[3/3] Scheduled task  (skipped)"
}

Write-Host ""
Write-Host "Done."
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. In the Syncthing UI (http://localhost:8384), add each of the three folders"
Write-Host "     and share them with the tablet. Set TabletViewOnly to Send Only on PC."
Write-Host "  2. On the tablet, set TabletViewOnly to Receive Only."
Write-Host "  3. Right-click any PDF in Explorer to test."
Write-Host "  4. Tail the log to watch events:  Get-Content -Wait '$LogPath'"
