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
    # Adds a single right-click entry under HKCU. SystemFileAssociations\<ext>
    # is the right place because it survives reassigning the default app
    # (vs. the file-type-specific ProgId, which goes away on switch).
    param(
        [string] $Extension,   # e.g. '.pdf' or '.png'
        [string] $KeyName,
        [string] $MenuText,
        [string] $Mode
    )
    $base = "HKCU:\Software\Classes\SystemFileAssociations\$Extension\shell\$KeyName"
    if (-not (Test-Path $base))           { New-Item -Path $base           -Force | Out-Null }
    if (-not (Test-Path "$base\command")) { New-Item -Path "$base\command" -Force | Out-Null }

    Set-ItemProperty -Path $base -Name '(default)' -Value $MenuText
    # Stock icon - PowerShell.exe is always present, looks fine in Explorer.
    Set-ItemProperty -Path $base -Name 'Icon'      -Value 'powershell.exe,0'

    # %1 is the file path Explorer hands us. -WindowStyle Hidden suppresses
    # the PowerShell console flash; the InputBox / MessageBox windows are
    # still visible because they're separate WinForms windows.
    $cmd = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Mode {2} -Path "%1"' -f `
        (Join-Path $PSHOME 'powershell.exe'), $sendScript, $Mode
    Set-ItemProperty -Path "$base\command" -Name '(default)' -Value $cmd
}

# Extension lists are also referenced (in spirit) by send_to_tablet.ps1's
# allow-list; keep these in sync with that script if you add or remove types.
$pdfExts   = @('.pdf')
$imageExts = @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic', '.tif', '.tiff')

if (-not $SkipContextMenu) {
    Write-Host "[2/3] Context menu"
    # PDFs: both View and Annotate entries.
    foreach ($ext in $pdfExts) {
        Set-ContextMenuEntry -Extension $ext -KeyName 'SendToTabletView'     -MenuText 'Open on Tablet (View Only)' -Mode 'view'
        Set-ContextMenuEntry -Extension $ext -KeyName 'SendToTabletAnnotate' -MenuText 'Open on Tablet (Annotate)'  -Mode 'annotate'
    }
    # Images: View only. Annotate is PDF-only because the tablet apps in this
    # workflow (PDF Expert / KOReader) only annotate PDFs.
    foreach ($ext in $imageExts) {
        Set-ContextMenuEntry -Extension $ext -KeyName 'SendToTabletView' -MenuText 'Open on Tablet (View Only)' -Mode 'view'
    }
    Write-Host "      installed under HKCU\Software\Classes\SystemFileAssociations\<ext>\shell"
    Write-Host "      PDFs: View + Annotate.  Images ($($imageExts -join ' ')): View only."
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

    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser

    # Second trigger fires on workstation unlock. A sleep/hibernate cycle
    # often kills the watcher process (the logon-triggered task exits with
    # STATUS_CONTROL_C_EXIT when the session is suspended), and without this
    # the watcher stays dead until the next full logoff/logon. Built via CIM
    # because New-ScheduledTaskTrigger doesn't expose unlock as an option;
    # StateChange=8 is TASK_SESSION_STATE_CHANGE_SESSION_UNLOCK.
    $sessionTriggerClass = Get-CimClass `
        -Namespace 'Root\Microsoft\Windows\TaskScheduler' `
        -ClassName  'MSFT_TaskSessionStateChangeTrigger'
    $unlockTrigger = New-CimInstance -CimClass $sessionTriggerClass -ClientOnly -Property @{
        Enabled     = $true
        StateChange = 8
        UserId      = $currentUser
    }

    # Restart on failure - the watcher should never crash, but if it does
    # (e.g. Syncthing folder briefly unmounted), Task Scheduler will revive it.
    # MultipleInstances=IgnoreNew means the unlock trigger is a no-op when the
    # watcher is already running, so unlocking the screen never spawns dupes.
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive

    Register-ScheduledTask -TaskName $taskName `
        -Action $action -Trigger @($logonTrigger, $unlockTrigger) -Settings $settings -Principal $principal `
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
