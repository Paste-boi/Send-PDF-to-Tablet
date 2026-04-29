<#
.SYNOPSIS
    Send a PDF from Windows to a tablet via Syncthing in either view-only or
    annotate mode.

.DESCRIPTION
    Invoked by the right-click context menu entries that install.ps1 sets up.

    -Mode view
        Drops a copy of the file into the view-only Syncthing folder. The
        watcher will delete it after $ViewOnlyCleanupMinutes elapses. The
        original file is never touched and never registered for return.

    -Mode annotate
        Pops a native Windows InputBox asking for a filename suffix, then
        drops a renamed copy of the file into the annotate inbox. The
        original path is recorded in state\origin-map.json so the watcher
        can move the annotated file back to its origin once the tablet
        returns it.

.PARAMETER Path
    Absolute path to the source PDF (Explorer supplies this as %1).

.PARAMETER Mode
    Either "view" or "annotate".

.EXAMPLE
    powershell -File send_to_tablet.ps1 -Mode annotate -Path "C:\docs\report.pdf"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [ValidateSet('view','annotate')] [string] $Mode
)

$ErrorActionPreference = 'Stop'

# Pull in shared paths + Get-OriginMap / Save-OriginMap / Write-SyncLog.
. (Join-Path $PSScriptRoot 'config.ps1')

# WinForms gives us MessageBox; Microsoft.VisualBasic gives us InputBox.
# Both ship with .NET, no third-party deps.
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Windows.Forms

function Show-Error {
    # Friendly error popup AND a log line, so that errors triggered from the
    # context menu (which runs hidden) are still visible to the user.
    param([string] $Message)
    [void][System.Windows.Forms.MessageBox]::Show(
        $Message, 'Send PDF to Tablet',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error)
    Write-SyncLog -Level 'ERROR' -Message $Message
}

# --- Validate input ----------------------------------------------------------
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Show-Error "File not found:`n$Path"
    exit 1
}
if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -ne '.pdf') {
    Show-Error "Not a PDF:`n$Path"
    exit 1
}

$src      = Get-Item -LiteralPath $Path
$origStem = [System.IO.Path]::GetFileNameWithoutExtension($src.Name)
$ext      = $src.Extension   # always '.pdf' here

# =============================================================================
# VIEW MODE
# =============================================================================
if ($Mode -eq 'view') {
    if (-not (Test-Path -LiteralPath $ViewOnlyInbox)) {
        Show-Error "View-only Syncthing folder does not exist:`n$ViewOnlyInbox`n`nCheck config.ps1."
        exit 1
    }

    # Use the original filename. If a previous send is still in flight under
    # the same name, append a counter rather than clobbering it.
    $destName = $src.Name
    $dest     = Join-Path $ViewOnlyInbox $destName
    $i = 2
    while (Test-Path -LiteralPath $dest) {
        $destName = '{0}_{1}{2}' -f $origStem, $i, $ext
        $dest     = Join-Path $ViewOnlyInbox $destName
        $i++
    }

    Copy-Item -LiteralPath $src.FullName -Destination $dest -Force
    # Copy-Item preserves the source file's LastWriteTime. The watcher's
    # view-only cleanup uses LastWriteTime as its clock, so without this
    # bump any PDF older than $ViewOnlyCleanupMinutes would be reaped on
    # the very next sweep before Syncthing could deliver it to the tablet.
    (Get-Item -LiteralPath $dest).LastWriteTime = Get-Date
    Write-SyncLog "VIEW     sent  '$destName'  from '$($src.FullName)'"
    exit 0
}

# =============================================================================
# ANNOTATE MODE
# =============================================================================
if (-not (Test-Path -LiteralPath $AnnotateInbox)) {
    Show-Error "Annotate Syncthing folder does not exist:`n$AnnotateInbox`n`nCheck config.ps1."
    exit 1
}

# Native Windows input dialog. Cancel returns an empty string.
$prompt = "Enter a suffix to append to the filename.`n`nExample: 'reviewed' produces '${origStem}_reviewed.pdf'"
$rawSuffix = [Microsoft.VisualBasic.Interaction]::InputBox(
    $prompt,
    'Send PDF to Tablet (Annotate)',
    'reviewed'
)

if ([string]::IsNullOrWhiteSpace($rawSuffix)) {
    Write-SyncLog -Level 'INFO' -Message "ANNOTATE cancelled (empty suffix) for '$($src.FullName)'"
    exit 0
}

# Strip filename-illegal chars (\ / : * ? " < > | plus control chars). We do
# this rather than reject so that a user typing "JD's edits" gets a working
# filename instead of a frustrating error.
$illegal = [System.IO.Path]::GetInvalidFileNameChars() -join ''
$pattern = "[$([Regex]::Escape($illegal))]"
$suffix  = [Regex]::Replace($rawSuffix, $pattern, '').Trim()

if ([string]::IsNullOrWhiteSpace($suffix)) {
    Show-Error "Suffix contained only invalid characters."
    exit 1
}

$destName = '{0}_{1}{2}' -f $origStem, $suffix, $ext
$dest     = Join-Path $AnnotateInbox $destName

# As above: don't clobber an in-flight copy. We append _2, _3, ... and the
# returning file from the tablet must match this same name exactly.
$i = 2
while (Test-Path -LiteralPath $dest) {
    $destName = '{0}_{1}_{2}{3}' -f $origStem, $suffix, $i, $ext
    $dest     = Join-Path $AnnotateInbox $destName
    $i++
}

Copy-Item -LiteralPath $src.FullName -Destination $dest -Force

# Register the origin so tablet_watcher.ps1 knows where to send it back.
$map = Get-OriginMap
$map[$destName] = [ordered]@{
    OriginPath = $src.FullName
    SentAt     = (Get-Date).ToString('o')
    Mode       = 'annotate'
}
Save-OriginMap -Map $map

Write-SyncLog "ANNOTATE sent  '$destName'  from '$($src.FullName)'"
