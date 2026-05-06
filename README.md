# Send PDF to Tablet

Right-click any PDF on Windows and send it to a tablet via Syncthing — either
view-only (auto-cleaned after a delay) or annotate-mode (where the tablet's
edits flow back to the original folder once saved to the tablet outbox folder). Common image types
(`.png .jpg .jpeg .gif .bmp .webp .heic .tif .tiff`) get the View-Only entry
as well, with the same delivery and cleanup behavior. Annotate mode is
PDF-only, since the tablet apps in this workflow only annotate PDFs.

## Scope and support

This is a tool my team and I use daily, shared in case it's useful. It is
**not** a maintained product. To keep that sustainable:

- **In scope:** Windows 10/11 + Syncthing + a Boox (Android) or iPad
  tablet running any PDF app that can read and save back to the files app, in the exact workflow described above. Bug reports for
  this configuration are welcome — please use the issue template so I
  can act on them.
- **Out of scope:** other tablets (reMarkable, Supernote, Kindle Scribe, …),
  other operating systems, other sync tools (Dropbox, OneDrive, Resilio),
  alternative file formats (EPUB, DOCX), GUI front-ends, running as a
  Windows service. These are all reasonable, just not things I'll build or
  maintain.
- **PRs are very welcome**, including ones that add support for the
  out-of-scope items above. Please open a draft PR rather than a
  feature-request issue. Anything I merge I have to be willing to support,
  so the bar for merging is "works on my setup, doesn't break the
  in-scope path, and I understand every line."
- **No warranty.** MIT-licensed. If it eats your PDFs, you keep both halves.

## Requirements

- Windows 10 or 11
- PowerShell 5.1 (ships with Windows — no install needed)
- Syncthing installed and running on the PC
- A Syncthing-compatible client on the tablet:
  - **Boox Note Air 5C / Android**: official Syncthing app (or
    Syncthing-Fork) from F-Droid or the Play Store
  - **iPad / iOS**: **Mobius Sync** from the App Store. There is no
    official Syncthing iOS app — Mobius Sync is the de facto third-party
    client and is what this was tested against. See the iPad caveats
    below; iOS background limits are the dominant gotcha
- A PDF app on the tablet — **any viewer that can open files from the
  device's file system and save edits back to the outbox will work.**
  The script doesn't care which app you use; it only matches by filename
  on the way back. Some options:
  - **iPad**: the built-in iOS PDF viewer reachable through the Files
    app (this is what I personally use — tap a PDF in the Tablet Inbox
    folder, annotate with the Markup tools, and save back to the Tablet Outbox folder), or any third-party
    app like PDF Expert, GoodNotes, Notability, PDF Viewer Pro, etc.
    Whatever you pick, just confirm it saves back to the **same file**
    in place rather than creating a new copy or exporting elsewhere.
  - **Boox Note Air 5C / Android**: KOReader, Xodo, the built-in Boox
    note app, etc. — same rule: it has to save edits back to the same
    file path.

No third-party PowerShell modules. Everything used here ships with Windows.

## How it works

```
                  +-----------------------+
   right-click -> | send_to_tablet.ps1    | --copy--+
   PDF in        |                       |         |
   Explorer      | view  -> ViewOnly     |         v
                  | annot -> Inbox       |    Syncthing folder
                  +-----------------------+         |
                            |                       v  (PC -> tablet)
                            v
                       origin-map.json         tablet reads / annotates
                            ^                       |
                            |                       v  (tablet -> PC)
                  +-----------------------+    Syncthing folder
                  | tablet_watcher.ps1    | <--watch-+
                  | -> moves to origin    |
                  | -> reaps view-only    |
                  +-----------------------+
```
 
Three Syncthing folder pairs power this:

1. **TabletViewOnly** — PC → Tablet, one-way enforced by Syncthing itself.
   Configure as **Send Only** on PC, **Receive Only** on tablet. Even if
   the user annotates a view-only file, changes cannot propagate back.
2. **TabletInbox** — Annotate-mode files heading to the tablet.
3. **TabletOutbox** — Annotated files coming back from the tablet. The
   watcher monitors this and routes each returning file to its origin.

You can collapse all three into one bidirectional folder, but the
separate-pair design enforces the view-only guarantee at the Syncthing
layer rather than relying on the script.

## Setup

### 1. Create the Syncthing folders on the PC

Pick any location. The defaults in `config.ps1` are:

```
C:\SyncthingFolders\TabletViewOnly
C:\SyncthingFolders\TabletInbox
C:\SyncthingFolders\TabletOutbox
```

Either create them yourself or let `install.ps1` create them for you.

### 2. Add them to Syncthing

In the Syncthing web UI (`http://localhost:8384`):

| Folder            | Folder Type on PC | Folder Type on Tablet |
| ----------------- | ----------------- | --------------------- |
| TabletViewOnly    | **Send Only**     | **Receive Only**      |
| TabletInbox       | Send & Receive    | Send & Receive        |
| TabletOutbox      | Send & Receive    | Send & Receive        |

Share each folder with the tablet device. Accept the share on the tablet
and pick a folder path there. On iOS, Mobius Sync exposes its synced
folders to the Files app, and from there any PDF viewer (the built-in
iOS viewer, PDF Expert, GoodNotes, etc.) can open files in place.

### 3. Create your `config.ps1`

Copy the example file and edit your copy:

```powershell
Copy-Item config.example.ps1 config.ps1
notepad config.ps1
```

Update the three path variables if you used different folders. Optionally
tune `$ViewOnlyCleanupMinutes` (default 10080 = 7 days, treated as a weekly
tidy) and `$WatcherSweepSeconds` (default 30).

`config.ps1` is gitignored, so your real paths never leak into a fork or
public repo.

### 4. Run the installer

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

This creates any missing Syncthing folders, adds the two right-click
context menu entries to your registry (per-user, no admin), and registers
`tablet_watcher.ps1` as a scheduled task that runs at logon. It also
starts the watcher immediately so you don't have to log out first.

## Test

1. Right-click a PDF in Explorer → **Open on Tablet (View Only)**.
   The file should appear in `TabletViewOnly` and Syncthing should push
   it to the tablet.
2. Right-click a different PDF → **Open on Tablet (Annotate)**.
   A small input box asks for a suffix. Enter `test`. The file is renamed
   `<original>_test.pdf` and dropped into `TabletInbox`. Open it on the
   tablet, annotate, save. Within a sweep cycle (~30 s) it should appear
   back in its origin folder.
3. Tail the log to watch events live:
   ```powershell
   Get-Content -Wait .\logs\sync.log
   ```

> Windows 11 hides custom context-menu entries behind **Show more options**
> (or Shift+Right-click) by default. The entries are there.

## iPad / iOS caveats

### You can't run Syncthing itself on iOS — use Mobius Sync

There is **no official Syncthing app for iOS or iPadOS**. The Syncthing
project is volunteer-run and has long stated that the App Store rules
(background execution limits, distribution model, paid developer account)
make a maintained iOS port impractical. As a result, every "Syncthing on
iPad" workflow you'll find online actually runs a **third-party client
that speaks the Syncthing protocol** — most commonly **Mobius Sync**,
available on the App Store (free to install, with paid tiers for larger
sync volumes — check the App Store page for current pricing).

This PoC was developed and tested against Mobius Sync. From the PC's
point of view nothing changes — Mobius Sync introduces itself to your
desktop Syncthing as a regular Syncthing device, and you share folders
with it the same way you would any other peer. The differences are all
on the iPad side:

- **Install Mobius Sync, not "Syncthing".** Searching the App Store for
  "Syncthing" turns up several third-party clients of varying quality;
  Mobius Sync is the one this PoC targets and the one I can confirm works
  end-to-end with the workflow here.
- **Pair from the PC.** In the desktop Syncthing UI, add a remote device
  using the device ID Mobius Sync shows on the iPad's *This Device*
  screen, then accept the incoming pair request inside Mobius Sync.
- **Folder sharing.** Add `TabletViewOnly`, `TabletInbox`, and
  `TabletOutbox` to Mobius Sync, with the folder types from the table in
  *Setup → 2*. Mobius Sync exposes its synced folders to the iOS Files
  app, which is how any PDF viewer on the iPad — the built-in iOS one,
  PDF Expert, GoodNotes, and so on — reaches them.
- **Other iOS Syncthing clients** (e.g. fs-sync, older forks) may work,
  but I haven't tested them. If you use one, expect the same background
  caveats below to apply, since they're imposed by iOS, not by the app.

### iOS background limits — the foreground dance

iOS aggressively suspends background apps, and this restriction applies
to **any** Syncthing-protocol client on iOS, Mobius Sync included. The
app does **not** sync indefinitely in the background — only while it's
foregrounded, or during a brief OS-granted window after backgrounding
(typically tens of seconds, occasionally a few minutes, never reliable).
Mobius Sync uses the iOS background-execution APIs available to it, but
none of them substitute for a real always-on foreground service like
you'd get on Android.

Practical workflow:

1. Send a file from the PC.
2. On the iPad, foreground **Mobius Sync** for ~10–30 seconds until the
   file shows up in `TabletInbox`. Watch the per-folder status flip from
   "Syncing" to "Up to Date".
3. Open the file from the synced folder using whatever PDF viewer you
   prefer — the built-in iOS PDF viewer in the Files app, PDF Expert,
   GoodNotes, etc. Annotate and save. Make sure your viewer saves **in
   place** (same path, same filename) rather than exporting a copy; the
   watcher matches returned files by exact filename.
4. Switch back to Mobius Sync and leave it foregrounded until the upload
   completes (folder shows "Up to Date" again, with no pending out-of-sync
   items). If you lock the iPad too early, the upload can stall partway
   and the watcher on the PC will keep waiting.
5. Once Mobius Sync reports "Up to Date", the watcher on the PC moves
   the returned file to its origin within one sweep cycle (~30 s by
   default).

If a sync stalls, the usual fix is to foreground Mobius Sync again and
let it finish — there's nothing to repair on the PC side as long as the
file hasn't actually arrived in `TabletOutbox` yet.

### Why Boox / Android is smoother

A Boox Note Air 5C runs full Android, where the official Syncthing app
can hold a persistent foreground-service notification and sync
continuously. The same scripts in this repo work without ceremony there —
only the iPad-specific foreground dance goes away. If you use this
workflow heavily and have a choice of tablet, an Android-based e-ink
device removes the most annoying part of the iOS path.

## Recovery

In-flight annotate-mode files are tracked in `state\origin-map.json`. It's
plain pretty-printed JSON, keyed by sent filename. Example:

```json
{
  "report_reviewed.pdf": {
    "OriginPath": "\\\\fileserver\\share\\projects\\Q2\\report.pdf",
    "SentAt": "2026-04-29T11:32:08.1234567+02:00",
    "Mode": "annotate"
  }
}
```

If something goes wrong (watcher crashed, file corruption, etc.) you can
recover manually:

1. Open `state\origin-map.json` in any editor.
2. Find the filename you sent.
3. Move the file from `TabletOutbox` to the `OriginPath` listed there.
4. Delete that entry from `origin-map.json`.

## Files

| File                     | Purpose                                                                 |
| ------------------------ | ----------------------------------------------------------------------- |
| `config.example.ps1`     | Template config (committed). Copy this to `config.ps1`                  |
| `config.ps1`             | Your local config (gitignored). Holds your Syncthing paths and helpers  |
| `send_to_tablet.ps1`     | Invoked by Explorer when you click a context menu entry                 |
| `tablet_watcher.ps1`     | Background loop: handles returns, reaps view-only files                 |
| `install.ps1`            | One-shot setup: folders, registry, scheduled task                       |
| `state/origin-map.json`  | (created at runtime, gitignored) Where each in-flight file came from    |
| `logs/sync.log`          | (created at runtime, gitignored) Append-only event log                  |

## Uninstall

```powershell
# stop and remove the scheduled task
Unregister-ScheduledTask -TaskName 'Send PDF to Tablet - Watcher' -Confirm:$false

# remove the right-click entries (loops over every extension and key)
foreach ($ext in '.pdf','.png','.jpg','.jpeg','.gif','.bmp','.webp','.heic','.tif','.tiff') {
    foreach ($key in 'SendToTabletView','SendToTabletAnnotate') {
        $path = "HKCU:\Software\Classes\SystemFileAssociations\$ext\shell\$key"
        if (Test-Path $path) { Remove-Item $path -Recurse -Force }
    }
}
```

The Syncthing folders, log, and origin map are left alone so you don't
accidentally lose state — delete those by hand if you want a clean slate.

## Troubleshooting

**Context menu entries don't appear.** On Windows 11, click "Show more
options" or Shift+right-click. If still missing, sign out and back in
(Explorer caches the shell registry).

**The InputBox never opens.** Check `logs\sync.log` for an error line. If
the script is failing before the dialog, the most common cause is
`config.ps1` pointing at a folder that doesn't exist — a MessageBox tells
you which one.

**The watcher isn't moving returned files.**
- `Get-ScheduledTask -TaskName 'Send PDF to Tablet - Watcher' | Get-ScheduledTaskInfo` — should show `LastTaskResult: 0` and a recent `LastRunTime`.
- Tail `logs\sync.log` to confirm the watcher is sweeping.
- Confirm the returned filename in `TabletOutbox` matches the key in
  `state\origin-map.json` exactly. Match policy is exact filename — so if
  the tablet renamed the file on save, the watcher won't claim it (that's
  by design, but it does mean you'll see a `WARN ... has no origin entry`
  line in the log).

**A returned filename collides with an existing file at the origin.**
The watcher appends a timestamp (e.g. `report_reviewed_2026-04-29_1530.pdf`)
and moves the file under the new name. The original is never overwritten.
