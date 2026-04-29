<#
.SYNOPSIS
    Background watcher for the Send-PDF-to-Tablet workflow.

.DESCRIPTION
    Polls $AnnotateOutbox for files returning from the tablet and moves each
    one to the origin path recorded in state\origin-map.json. Also reaps
    files in $ViewOnlyInbox that are older than $ViewOnlyCleanupMinutes.

    Runs forever. install.ps1 registers it as a scheduled task that fires
    on user logon. To run manually for debugging:

        powershell -NoProfile -ExecutionPolicy Bypass -File tablet_watcher.ps1
#>
[CmdletBinding()]
param()

# Continue rather than Stop: a single bad file should never crash the loop.
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'config.ps1')

Write-SyncLog -Level 'INFO' -Message "Watcher starting. Outbox=$AnnotateOutbox  ViewOnly=$ViewOnlyInbox  Sweep=${WatcherSweepSeconds}s"

# Map of file path -> last seen size. Lets us tell whether a file is still
# being written by Syncthing: if its size is the same as last sweep AND we
# can open it for read, it's stable.
$script:lastSeenSize = @{}

function Test-FileReady {
    # Considered ready when the file's size is the same on two consecutive
    # sweeps and is non-zero. A partial Syncthing transfer keeps growing, so
    # a stable size across one sweep cycle is a good proxy for "done".
    param([string] $FilePath)

    try {
        $size = (Get-Item -LiteralPath $FilePath -ErrorAction Stop).Length
    } catch {
        return $false
    }
    if ($size -le 0) { return $false }

    if ($script:lastSeenSize.ContainsKey($FilePath) -and $script:lastSeenSize[$FilePath] -eq $size) {
        return $true
    }
    $script:lastSeenSize[$FilePath] = $size
    return $false
}

function Get-UniqueDestPath {
    # If $PreferredName is free in $TargetDir, return it. Otherwise return
    # PreferredName_yyyy-MM-dd_HHmm[.pdf]; if even that collides, append _2,
    # _3, ... The user's "never overwrite" rule is preserved either way.
    param([string] $TargetDir, [string] $PreferredName)

    $candidate = Join-Path $TargetDir $PreferredName
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }

    $stem  = [System.IO.Path]::GetFileNameWithoutExtension($PreferredName)
    $ext   = [System.IO.Path]::GetExtension($PreferredName)
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'

    $candidate = Join-Path $TargetDir ('{0}_{1}{2}' -f $stem, $stamp, $ext)
    $i = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $TargetDir ('{0}_{1}_{2}{3}' -f $stem, $stamp, $i, $ext)
        $i++
    }
    return $candidate
}

function Invoke-ReturnSweep {
    # Process every stable file in the outbox. For each, look up its origin,
    # move it there (with collision-safe naming), tidy up the inbox copy and
    # the origin-map entry.
    if (-not (Test-Path -LiteralPath $AnnotateOutbox)) { return }

    $map = Get-OriginMap
    $mapDirty = $false

    foreach ($f in Get-ChildItem -LiteralPath $AnnotateOutbox -File -Filter '*.pdf' -ErrorAction SilentlyContinue) {
        if (-not (Test-FileReady -FilePath $f.FullName)) { continue }

        $entry = $map[$f.Name]
        if (-not $entry) {
            # Exact-match policy (per design): if the filename isn't in the
            # map, we don't guess. Leave it for the user to handle.
            Write-SyncLog -Level 'WARN' -Message "Returned file '$($f.Name)' has no origin entry; leaving in outbox."
            continue
        }

        $originPath = [string]$entry.OriginPath
        $originDir  = Split-Path -Parent $originPath
        if (-not (Test-Path -LiteralPath $originDir)) {
            Write-SyncLog -Level 'ERROR' -Message "Origin folder missing for '$($f.Name)': $originDir"
            continue
        }

        $destPath = Get-UniqueDestPath -TargetDir $originDir -PreferredName $f.Name

        try {
            Move-Item -LiteralPath $f.FullName -Destination $destPath -Force
            Write-SyncLog "RETURN   moved '$($f.Name)'  ->  '$destPath'"
        } catch {
            Write-SyncLog -Level 'ERROR' -Message "Failed to move '$($f.Name)' to '$destPath': $_"
            continue
        }

        # Tidy up: drop the now-stale inbox copy if Syncthing left it there.
        $inboxCopy = Join-Path $AnnotateInbox $f.Name
        if (Test-Path -LiteralPath $inboxCopy) {
            try {
                Remove-Item -LiteralPath $inboxCopy -Force
            } catch {
                Write-SyncLog -Level 'WARN' -Message "Could not delete inbox copy '$inboxCopy': $_"
            }
        }

        $map.Remove($f.Name)
        $script:lastSeenSize.Remove($f.FullName) | Out-Null
        $mapDirty = $true
    }

    if ($mapDirty) { Save-OriginMap -Map $map }
}

function Invoke-ViewOnlyCleanup {
    # Files in $ViewOnlyInbox older than $ViewOnlyCleanupMinutes get deleted.
    # Age is measured by LastWriteTime, which is set when send_to_tablet.ps1
    # copied the file in - so the clock starts at send time.
    if (-not (Test-Path -LiteralPath $ViewOnlyInbox)) { return }
    $cutoff = (Get-Date).AddMinutes(-1 * $ViewOnlyCleanupMinutes)

    foreach ($f in Get-ChildItem -LiteralPath $ViewOnlyInbox -File -Filter '*.pdf' -ErrorAction SilentlyContinue) {
        if ($f.LastWriteTime -gt $cutoff) { continue }
        $ageMin = [int][math]::Round(((Get-Date) - $f.LastWriteTime).TotalMinutes)
        try {
            Remove-Item -LiteralPath $f.FullName -Force
            Write-SyncLog "VIEW     cleanup '$($f.Name)' (mtime ${ageMin} min old, cutoff ${ViewOnlyCleanupMinutes} min)"
        } catch {
            Write-SyncLog -Level 'WARN' -Message "Could not delete '$($f.FullName)': $_"
        }
    }
}

# Main loop. Each pass is independent; if one sweep fails the next one tries
# again. The sleep gates how often we hit the disk.
while ($true) {
    try { Invoke-ReturnSweep }      catch { Write-SyncLog -Level 'ERROR' -Message "Invoke-ReturnSweep:      $_" }
    try { Invoke-ViewOnlyCleanup }  catch { Write-SyncLog -Level 'ERROR' -Message "Invoke-ViewOnlyCleanup:  $_" }
    Start-Sleep -Seconds $WatcherSweepSeconds
}
