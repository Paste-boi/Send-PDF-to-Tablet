# =============================================================================
# Example configuration. Copy this file to config.ps1 and edit the path block
# below to match the Syncthing folders on your machine.
#
#   PowerShell:  Copy-Item config.example.ps1 config.ps1
#   Cmd:         copy config.example.ps1 config.ps1
#
# config.ps1 is gitignored, so your real paths never get committed.
#
# Dot-sourced from the other scripts via:
#     . (Join-Path $PSScriptRoot 'config.ps1')
#
# See README.md for the Syncthing topology this project assumes (one Send-Only
# folder for view-only files plus a separate inbox/outbox pair for annotate
# mode).
# =============================================================================

# Project root resolves to whatever directory holds this file. Using
# $PSScriptRoot makes the project relocatable - move the folder, everything
# still works.
$ProjectRoot = $PSScriptRoot

# --- Syncthing folder paths --------------------------------------------------
# These three folders must already be configured as Syncthing folders shared
# with the tablet. The script does not configure Syncthing for you.

# View-only files land here. On the PC this folder must be 'Send Only';
# on the tablet it must be 'Receive Only'. That way any annotation made on
# the tablet cannot propagate back, regardless of what the user does there.
$ViewOnlyInbox  = 'C:\SyncthingFolders\TabletViewOnly'

# Annotate-mode files land here on their way out to the tablet.
$AnnotateInbox  = 'C:\SyncthingFolders\TabletInbox'

# The tablet drops annotated files into its mirror of this folder; Syncthing
# brings them here, where the watcher picks them up.
$AnnotateOutbox = 'C:\SyncthingFolders\TabletOutbox'

# --- State + log paths -------------------------------------------------------
$StateDir       = Join-Path $ProjectRoot 'state'
$LogDir         = Join-Path $ProjectRoot 'logs'
$OriginMapPath  = Join-Path $StateDir   'origin-map.json'
$LogPath        = Join-Path $LogDir     'sync.log'

# --- Behavior knobs ----------------------------------------------------------
# View-only files older than this are auto-deleted by the watcher. Treated as
# a weekly tidy rather than a per-session cleanup, so a PDF you have open on
# the tablet for hours (or that you re-open the next morning) won't disappear
# mid-read. 10080 = 7 * 24 * 60.
$ViewOnlyCleanupMinutes = 10080

# How often (seconds) the watcher polls for returned files and view-only
# cleanup candidates. Lower = snappier, higher = lighter on disk.
$WatcherSweepSeconds    = 30

# =============================================================================
# Below this line: helpers used by the other scripts. No more knobs to tune.
# =============================================================================

# Make sure runtime directories exist. Safe to run on every dot-source.
foreach ($d in @($StateDir, $LogDir)) {
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

function Write-SyncLog {
    # Append a single line to logs\sync.log. Failures here must never block
    # the workflow, so we swallow exceptions.
    param(
        [Parameter(Mandatory)] [string] $Message,
        [string] $Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch {}
}

function Get-OriginMap {
    # Load state\origin-map.json into a hashtable keyed by sent filename. If
    # the file is missing or malformed, return an empty map (and log it).
    if (-not (Test-Path -LiteralPath $OriginMapPath)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $OriginMapPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    } catch {
        Write-SyncLog -Level 'WARN' -Message "Could not parse origin map; starting fresh: $_"
        return @{}
    }
}

function Save-OriginMap {
    # Write the hashtable back as pretty-printed JSON so it stays human-
    # readable for manual recovery.
    param([Parameter(Mandatory)] $Map)
    $json = $Map | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $OriginMapPath -Value $json -Encoding UTF8
}
