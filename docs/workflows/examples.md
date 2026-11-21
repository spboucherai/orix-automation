<!--
ORIX OS Automation
File: docs/workflows/examples.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Built-in example automations

The 15 automations of `Workflows/Examples/` ship in the app (template gallery) and are what `orixctl workflow templates`
lists. This page says, for each one, what it does, its parameters, the permissions it declares and the tier of each
step, where its sample data is, how to try it, what it must produce, and its limitations **as observed**.

Everything below was run on one Mac on **2026-11-21** (macOS 27.0, Mac17,6) by
`Packages/ORIXServices/Tests/ORIXServicesTests/ExamplesEndToEndTests.swift` (suite `Integration · examples`): real services
on a temporary data folder, the real registered tools, the sample data copied into a temporary workspace. "Verified"
means that test passed with assertions on the content of the artifacts; nothing here is claimed beyond that.

## How to try an example

Sample data lives in `Workflows/Samples/<slug>/`. The default parameters point at `~/ORIX Samples/<slug>/…`, so copy the
sample there (or pass your own paths as parameters):

```bash
mkdir -p ~/"ORIX Samples" && cp -R Workflows/Samples/<slug> ~/"ORIX Samples"/
cd Packages/ORIXServices && swift build            # builds .build/debug/orixctl
orixctl workflow templates                         # the 15 slugs
orixctl workflow install <slug>                    # copies the template into your workflows (same as the gallery)
orixctl workflow run <slug> --dry-run --accept-permissions      # simulation: nothing is changed
orixctl workflow run <slug> --accept-permissions --approve all [--param name=json …]
```

- `--accept-permissions` accepts the permissions the workflow declares for these parameters (what the review sheet of
  the app does). Without it, and without `--approve all`, the first tool call waits: the run ends `WAITING_APPROVAL`
  and nothing happens. Verified for examples 1, 8 and 9 (headless service, nothing accepted: no file written, no
  request sent).
- `--approve all` answers every approval, including the manual gates of examples 1 and 15. With the declared
  permissions accepted **no tool call of any example needs an approval**: the tests refuse every tool approval and
  only answer the manual gates.
- `--data DIR` keeps the run history of your experiments out of the app's data folder.
- In the app: **Workflows › Template gallery**, pick the template, review the parameters and permissions in the run
  sheet, then run (or dry-run) it.

Things that hold for all examples:

- **Tiers.** 0 = read-only, 1 = reversible local write, 2 = consequential (processes, scripts, app automation,
  browser input). No example uses a tier 3 tool; none deletes, commits or pushes.
- **Notifications** (examples 3, 7, 8, 9, 10) need the ORIX app: a command-line process has no application bundle, so
  the notification step fails by itself (`Notifications need an application bundle`), it is the last step, and the run
  ends `PARTIALLY_SUCCEEDED` with every artifact produced and verified. This is what the tests observe. A notification
  actually appearing from the app was **not verified** here.
- **Dry runs** execute no tool that lacks a dry-run mode, which includes every read tool. A dry run therefore shows the
  writes it can foresee and reports the rest as "not executed" or "skipped"; examples 8 and 9 end `FAILED` in a dry
  run because their later steps need files the earlier steps would have created. A dry run never writes (verified on
  all 15 with the sample data present).
- **Outputs** (`output:` steps) are available on the live run handle; the stored receipt keeps status, tool calls,
  verifications, artifacts and limitations, not the output values.

---

## 1. Smart Downloads Organizer — `smart-downloads-organizer`

Sorts the files at the top level of a folder into category subfolders chosen from the extension, after a manual
approval. Files are moved, never deleted or overwritten.

| Parameter | Default | |
|---|---|---|
| `source` | `~/ORIX Samples/smart-downloads-organizer/Downloads` | folder to organise |
| `destination` | `~/ORIX Samples/smart-downloads-organizer/Sorted` | receives one subfolder per category |

**Permissions:** read `source`, `destination`; write `source` (a move changes the source folder) and `destination`.
**Steps and tiers:** `list`, `remaining` — `filesystem.list` (0); `confirm` — manual gate (shown as consequential);
`makeFolder` — `filesystem.mkdir` (1); `move` — `filesystem.move` (1).

**Sample:** `Workflows/Samples/smart-downloads-organizer/Downloads` — 11 files of mixed kinds (text, CSV, PDF, PNG, zip,
placeholder audio/video, a file without extension, an upper-case extension) and a `Projects/` subfolder.

**Expected:** `Sorted/{Documents,Spreadsheets,Images,Archives,Audio,Video,Other}/…` holding the 11 files with unchanged
content; `Downloads/` keeps only `Projects/keep-me.txt`; output `moved: 11`.

**Verified 2026-11-21:** each file is in its category with the same SHA-256, nothing else was created, nothing was
deleted, the gate was asked once. Headless without accepted permissions: `WAITING_APPROVAL`, tree unchanged.

**Limitations:** top level only, hidden files ignored, at most 500 entries per run; a name collision in the destination
fails that move and stops the run (files already moved stay moved); category by extension only.

## 2. PDF to structured data and report — `pdf-to-structured-report`

Reads every PDF under a folder (page count, title, size of the text layer), writes a CSV catalogue and renders a PDF
report from a Markdown table.

| Parameter | Default |
|---|---|
| `inputFolder` | `~/ORIX Samples/pdf-to-structured-report/Input` |
| `outputFolder` | `~/ORIX Samples/pdf-to-structured-report/Output` |

**Permissions:** read both folders; write `outputFolder`.
**Steps and tiers:** `find` — `filesystem.search` (0); `info`, `text` — `documents.pdfInfo`, `documents.pdfText` (0);
`prepare` — `filesystem.mkdir` (1); `catalog` — `documents.csvWrite` (1); `markdown` — `filesystem.write` (1);
`render` — `documents.renderPDF` (1).

**Sample:** `Input/` — four synthetic PDFs made by `make-sample-pdfs.swift` (CoreGraphics/CoreText): one page with a
title, three pages with a title, one page without a Title property, and `archive/scan-without-text.pdf` (shapes only,
no text layer).

**Expected:** `Output/catalog.csv` (header + 4 rows: `file,pages,title,textCharacters`), `report.md`, `report.pdf`
(1 page); outputs `documents: 4`, `pages: 6`.

**Verified 2026-11-21:** page counts equal PDFKit's own count, the untitled PDF has an empty title, the scan has 0
text characters, the report PDF's text contains the table, the input folder is unchanged.

**Limitations:** no OCR; first 200 000 bytes of text per PDF; at most 100 PDFs per run; a `|` in a title breaks the
Markdown table; encrypted PDFs fail their iteration.

## 3. Weekly research digest — `weekly-research-digest` (agent)

On Mondays 09:00 (or manually) the workflow reads the `.md`, `.txt` and `.pdf` files of a folder, hands their text to
an agent as data, and the agent writes a dated digest in Markdown, which is then rendered as PDF.

| Parameter | Default |
|---|---|
| `researchFolder` | `~/ORIX Samples/weekly-research-digest/Research` |
| `reportsFolder` | `~/ORIX Samples/weekly-research-digest/Reports` |
| `maxDocuments` | `25` |

**Permissions:** read both folders; write `reportsFolder`; notifications. Budget: US$0.50, 600 000 tokens.
**Steps and tiers:** `discover` — `filesystem.list` (0); `content` — `filesystem.read` per text file (0);
`pdfContent` — `documents.pdfText` per PDF (0); `prepare` — `filesystem.mkdir` (1); `analyze` — agent whose only tool
is `filesystem.write` (1); `readDigest` — `filesystem.read` (0); `render` — `documents.renderPDF` (1); `announce` —
notification (1).

**Sample:** `Research/` — a short brief (`.md`), interview notes in a subfolder (`.txt`) and a three-page PDF, all
synthetic.

**Expected:** `Reports/digest-<date>.md` with a "Highlights" section naming its source files, and
`digest-<date>.pdf`; output `documents: 3`.

**Verified live 2026-11-21** with `anthropic:claude-haiku-5-5` through the development key: digest written with the
required section, cites its source files (text and PDF), reflects their content; PDF readable; research folder
unchanged; the agent made no failing tool call; 10 000–17 000 tokens, **about US$0.002**. Ends
`PARTIALLY_SUCCEEDED` under the test because of the notification (see above). Without a key the test prints
`SKIPPED(no ORIX_DEV_ANTHROPIC_API_KEY)` and verifies only the dry run (the agent step is reported as skipped, no
model call, nothing written).

**Limitations:** needs a provider key and a default model; the digest is model-written and only its existence and
section are verified, not its accuracy; first 12 000 bytes of each document, no OCR; an unreadable document is left
out and the run ends `PARTIALLY_SUCCEEDED`; listing is 3 levels deep, 500 entries; a scheduled run cannot ask for
approval. An earlier version let the agent open the files itself: in four of five live runs on 2026-11-21 the model
called the PDF reader on a Markdown file (three times before the instructions named the tool per file type, once
after), and because the agent runtime counts a failed tool call that the same tool never repeats successfully as an
unrecovered failure, those runs ended `FAILED` with a digest on disk. That is why the workflow now reads the documents
itself (three live runs in a row passed). The same strictness applies to examples 4 and 11, whose agents still read
files themselves (plain text only; no failure observed in four live runs each).

## 4. Git repository test-and-review assistant — `git-test-and-review` (agent)

Reads the status, diff and log of a local repository, runs its test command, has an agent write a review of the
uncommitted changes with the test result in hand, and saves the diff as a patch. It never commits or pushes.

| Parameter | Default | |
|---|---|---|
| `repository` | `~/ORIX Samples/git-test-and-review/repo` | working tree |
| `testExecutable` | `sh` | the program that runs the tests; it is the declared process permission |
| `testArguments` | `[run-tests.sh]` | argv array, no shell |
| `reviewsFolder` | `~/ORIX Samples/git-test-and-review/Reviews` | receives `review.md`, `changes.patch` |

**Permissions:** read `repository`, `reviewsFolder`; write `reviewsFolder`; processes `git` and `testExecutable`.
Budget: US$0.50.
**Steps and tiers:** `status`, `diff`, `log`, `patch` — `git.status`, `git.diff`, `git.log`, `git.createPatch` (0;
the patch is written to the run's artifacts); `tests` — `shell.run` (2, sandboxed); `prepare` — `filesystem.mkdir`
(1); `review` — agent limited to `filesystem.read`, `filesystem.search`, `git.diff`, `git.log` (0) and
`filesystem.write` (1); `savePatch` — `filesystem.copy` (1).

**Sample:** `Workflows/Samples/git-test-and-review/setup.sh [target]` creates `<target>/repo` (default
`~/ORIX Samples/git-test-and-review/repo`): two commits on `main`, then an uncommitted change that breaks its three
shell tests, plus one untracked file. No nested `.git` is stored in this repository.

```bash
Workflows/Samples/git-test-and-review/setup.sh
orixctl workflow run git-test-and-review --accept-permissions --approve all
```

**Expected:** `Reviews/review.md` (sections Tests / Must fix / Should fix / Notes, stating that the tests failed),
`Reviews/changes.patch`; outputs `testsPassed: false`, `branch: main`, `patchWritten: true`.

**Verified live 2026-11-21** (Haiku 5.5): the review states the failure and discusses `slugify.sh`; the patch holds the
tracked change and not the untracked file; `HEAD`, commit count and `git status --porcelain` are identical before and
after; about 13 000–20 000 tokens, **US$0.002**; `SUCCEEDED`. Without a key: `SKIPPED(no ORIX_DEV_ANTHROPIC_API_KEY)`
for the review, but the git steps, the real test command (exit code 1, its output) and the patch are still verified,
and the run ends `FAILED` at the agent step, with no review file.

**Limitations:** the test command is sandboxed — it reads the repository but can only write to the reviews folder and
the run's artifacts, so runners that write build products into the repository (`swift test`, `npm test`) need the
repository added to `permissions.filesystem.write` by the user; a non-zero exit code does not fail the step (it is
reported); the patch has unstaged changes of tracked files only; needs a provider key.

## 5. CSV cleanup and chart generation — `csv-cleanup-and-charts`

Cleans a CSV with a standard-library Python script running in the sandbox, and draws an SVG bar chart of the first
all-numeric column.

| Parameter | Default |
|---|---|
| `inputFile` | `~/ORIX Samples/csv-cleanup-and-charts/input.csv` |
| `outputFolder` | `~/ORIX Samples/csv-cleanup-and-charts/Output` |

**Permissions:** read `inputFile`, `outputFolder`; write `outputFolder`; script runtime `python`.
**Steps and tiers:** `inspect`, `cleaned` — `documents.csvRead` (0); `prepare` — `filesystem.mkdir` (1); `clean` —
`python.run` (2, sandboxed, no network).

**Sample:** `input.csv` — byte-order mark, padded cells, a blank line, an all-empty row, two duplicate rows, a short
row and a row with an extra cell.

**Expected:** `Output/cleaned.csv` (header + 5 rows: North, South, East, West, Central) and `Output/chart.svg` (five
bars of the `units` column); outputs `rowsBefore: 9`, `rows: 5`.

**Verified 2026-11-21:** the cleaned file equals the expected text exactly, the chart has 5 bars titled `units`, the
input is unchanged, the output folder contains only the two files.

**Limitations:** needs a `python3` on the Mac (ORIX creates its own virtual environment from it on first use, a few
seconds; system Python is never modified); UTF-8 input only; first 40 rows charted; cleaning is trimming, padding and
exact de-duplication, nothing smarter.

## 6. Batch image conversion and naming — `batch-image-conversion`

Converts every image at the top level of a folder to one format with sequential names, four at a time. Originals are
untouched.

| Parameter | Default |
|---|---|
| `sourceFolder` | `~/ORIX Samples/batch-image-conversion/Originals` |
| `outputFolder` | `~/ORIX Samples/batch-image-conversion/Converted` |
| `format` | `jpeg` (png, jpeg, jpg, heic, tiff, gif, bmp) |
| `prefix` | `image` |

**Permissions:** read both folders; write `outputFolder`.
**Steps and tiers:** `list`, `converted` — `filesystem.list` (0); `prepare` — `filesystem.mkdir` (1); `one` —
`documents.imageConvert` (1).

**Sample:** `Originals/` — five synthetic images made by `make-sample-images.swift` (PNG with alpha, JPEG, TIFF, GIF,
a PNG with an upper-case extension and a space in its name) and one text file that must be ignored.

**Expected:** `Converted/<prefix>-1.jpeg … <prefix>-5.jpeg`; output `converted: 5`.

**Verified 2026-11-21:** five readable JPEGs with the pixel sizes of their sources, in listing order; the text file is
left out; originals unchanged.

**Limitations:** names follow byte order (upper case first) and are not zero-padded; an existing output file is never
overwritten (a rerun into a non-empty folder fails on the first collision); animated GIFs keep their first frame only.

## 7. Calendar-based preparation — `calendar-preparation` (Apple Events)

On weekday mornings (or manually) reads the start date and title of the coming events from Calendar with one
AppleScript and writes a briefing with a checklist line per event. Read-only.

| Parameter | Default |
|---|---|
| `daysAhead` | `1` |
| `outputFolder` | `~/ORIX Samples/calendar-preparation/Briefings` |

**Permissions:** write `outputFolder`; script runtime `applescript`; automation of `com.apple.iCal`; notifications.
**Steps and tiers:** `prepare` — `filesystem.mkdir` (1); `events` — `applescript.run` targeting Calendar (2);
`write` — `filesystem.write` (1); `announce` — notification (1).

**Sample:** none needed (the workflow reads the real Calendar). `sample-events.ics` holds two synthetic events you can
import into a calendar to try it on known data; see `ABOUT.txt`.

**Expected:** `Briefings/briefing-<date>.md` — "Events in the next N day(s): k" and k checklist lines.

**Status 2026-11-21: SKIPPED(appleEvents not granted).** Calendar was not running and Automation consent for it had
never been given to the test process, so its status was `unknown`; running the script would have made macOS show its
consent prompt, which a test must not do. Verified instead: the script addresses only Calendar and contains no command
that creates, changes or deletes anything; the declared permissions are the Calendar automation and one write folder;
a dry run reports the AppleScript step as simulated and writes nothing. The test runs the workflow for real when
consent is already granted (and asserts the briefing), and asserts `BLOCKED_PERMISSION` with no file when consent was
refused. **A real read of Calendar events has not been verified on this Mac.**

**Limitations:** macOS asks once for Automation consent (ORIX → Calendar) and ORIX never answers it; the script opens
Calendar if it is closed; only start date and title are read; dates are formatted in the Mac's language; large
calendars are slow (120 s limit).

## 8. Folder backup and verification — `folder-backup-and-verify`

Archives a folder into a dated zip, records its SHA-256, restores the archive into a temporary folder, compares the
restored tree with the source (hidden files included) and moves the temporary copy to the Trash.

| Parameter | Default |
|---|---|
| `source` | `~/ORIX Samples/folder-backup-and-verify/Documents` |
| `backupRoot` | `~/ORIX Samples/folder-backup-and-verify/Backups` |

**Permissions:** read `source`, `backupRoot`; write `backupRoot`; delete (move to Trash) under `backupRoot`;
notifications.
**Steps and tiers:** `prepare` — `filesystem.mkdir` (1); `archive` — `filesystem.archive` (1); `checksum` —
`filesystem.checksum` (0); `record` — `filesystem.write` (1); `restore` — `filesystem.unarchive` (1); `compare` —
`filesystem.compare` (0); `cleanup` — `filesystem.trash` (1); `announce` — notification (1).

**Sample:** `Documents/` — a small tree with subfolders, a file with accented characters, a 4 kB binary file and a
hidden file.

**Expected:** `Backups/backup-<date>.zip` and `backup-<date>.zip.sha256`; outputs `identical: true`, `sha256`.

**Verified 2026-11-21:** the recorded checksum equals the SHA-256 of the archive; an independent `ditto` restore of
the archive gives a tree identical to the source, hidden file included; the source is unchanged; the temporary restore
folder is gone from the backup root and is in the Trash (the test then removes its own item from the Trash). Headless
without accepted permissions: `WAITING_APPROVAL`, nothing written.

**Limitations:** a local copy, not an off-site backup; needs space for archive + restored copy; one archive per day
(a second run replaces it); old backups are never pruned; the temporary copy stays in the Trash until emptied.

## 9. Website change monitoring — `website-change-monitor`

Every hour (or manually) fetches one page from one approved host, keeps the last copy, compares the new body with the
previous one byte for byte and posts a notification when it differs.

| Parameter | Default | |
|---|---|---|
| `host` | `example.com` | the only host that may be contacted: it **is** the network permission |
| `url` | `https://${{ params.host }}/` | page to watch, on that host |
| `stateFolder` | `~/ORIX Samples/website-change-monitor/State` | keeps `current.html`, `previous.html` |

**Permissions:** network `host`; read/write `stateFolder`; notifications.
**Steps and tiers:** `fetch` — `http.request` GET (0, network capability); `prepare` — `filesystem.mkdir` (1);
`saveCurrent` — `filesystem.write` (1); `findPrevious` — `filesystem.search` (0); `diff` — `filesystem.compare` (0);
`promote` — `filesystem.copy` (1); `alert` — notification (1).

**Sample:** `site/page-v1.html` and `site/page-v2.html` (one sentence differs). Serve one on loopback and swap it:

```bash
cd Workflows/Samples/website-change-monitor/site && cp page-v1.html page.html && python3 -m http.server 8766 --bind 127.0.0.1 &
orixctl workflow run website-change-monitor --accept-permissions --approve all \
  --param host='"127.0.0.1"' --param url='"http://127.0.0.1:8766/page.html"'      # first run: baseline
cp page-v2.html page.html                                                          # then run again: changed
```

**Expected:** outputs `firstRun`, `changed`, `status: 200`, `sha256` of the saved body; `previous.html` always holds
the last fetched copy.

**Verified 2026-11-21 against a loopback server only** (no request to the public internet): baseline run
(`firstRun: true`), identical run (`changed: false`, alert skipped), changed run (`changed: true`, new copy promoted,
alert attempted); exactly one GET per run; the proposed network grant is the `host` parameter; a `url` on another
host than `host` is not fetched (`WAITING_APPROVAL`, no request received); headless without accepted permissions: no
request, nothing written. **The default `https://example.com/` was not contacted by any test.**

**Limitations:** HTTPS only, plain http for loopback addresses only; one GET, no login, no JavaScript; byte comparison
(rotating content counts as a change), bodies over 2 MB are truncated first; respect the site's terms and robots
policy; the alert is a notification (app only).

## 10. Local system health report — `system-health-report`

Collects system information, mounted volumes, the ten busiest processes, power state and network state in parallel,
writes a dated Markdown report and warns when the startup disk is nearly full.

| Parameter | Default |
|---|---|
| `outputFolder` | `~/ORIX Samples/system-health-report/Reports` |
| `minFreeFraction` | `0.1` |

**Permissions:** read/write `outputFolder`; notifications.
**Steps and tiers:** `info`, `disk`, `processes`, `power`, `network` — `system.info`, `system.diskUsage`,
`system.processes`, `system.powerState`, `system.networkState` (0, no capability); `prepare` — `filesystem.mkdir` (1);
`write` — `filesystem.write` (1); `warn` — notification (1), only when the disk is low.

**Sample:** none needed; see `ABOUT.txt`.

**Expected:** `Reports/health-<date>.md` with the sections Machine, Disk, Busiest processes, Power, Network; outputs
`freeFraction`, `lowDisk`, `osVersion`.

**Verified 2026-11-21:** the report holds this Mac's real core count and the expected fields; the free fraction is
within 5 points of the figure read directly from the system; only the report file was written; `SUCCEEDED` (the disk
was not low, so the warning was skipped).

**Limitations:** a snapshot, not a trend; "free" is the space macOS reports as available for important usage (what
Finder shows); sections are raw JSON; the low-disk warning is a notification (app only) and was not exercised; a dry
run has no disk figures and reports the later steps as skipped.

## 11. Meeting notes organization — `meeting-notes-organizer` (agent)

For each `.txt`/`.md` transcript of a folder an agent writes a notes file (Summary, Decisions, Action items); the
workflow then writes an index of all notes.

| Parameter | Default |
|---|---|
| `transcriptsFolder` | `~/ORIX Samples/meeting-notes-organizer/Transcripts` |
| `notesFolder` | `~/ORIX Samples/meeting-notes-organizer/Notes` |

**Permissions:** read both folders; write `notesFolder`. Budget: US$1 for the whole run.
**Steps and tiers:** `list` — `filesystem.list` (0); `prepare` — `filesystem.mkdir` (1); `summarize` — one agent per
transcript, limited to `filesystem.read` (0) and `filesystem.write` (1); `index` — `filesystem.write` (1).

**Sample:** `Transcripts/` — two short synthetic meetings (`.txt` and `.md`).

**Expected:** `Notes/<transcript>-notes.md` per transcript, each with the three sections, and `Notes/index.md` linking
them.

**Verified live 2026-11-21** (Haiku 5.5): two notes files with the three sections, decisions and owners taken from the
transcripts, index listing both, transcripts unchanged; about 43 000 tokens, **US$0.004**; `SUCCEEDED`. Without a
key: `SKIPPED(no ORIX_DEV_ANTHROPIC_API_KEY)`; the dry run is verified (no model call, nothing written — a dry run
cannot know the transcripts, so the loop is not entered).

**Limitations:** notes are model-written, only their sections are verified; one agent run per transcript, sequential;
when the cost budget is reached the run stops with `BUDGET_EXCEEDED` and the notes already written stay; top level
only, 500 entries.

## 12. Document metadata extraction and cataloging — `document-metadata-catalog`

Walks a folder and writes one CSV row per file: relative path, extension, size, modification date, content type and
SHA-256.

| Parameter | Default |
|---|---|
| `documentsFolder` | `~/ORIX Samples/document-metadata-catalog/Documents` |
| `catalogFile` | `~/ORIX Samples/document-metadata-catalog/catalog.csv` |

**Permissions:** read `documentsFolder`, `catalogFile`; write `catalogFile`.
**Steps and tiers:** `list` — `filesystem.list` (0); `meta`, `hash` — `filesystem.metadata`, `filesystem.checksum`
(0); `catalog` — `documents.csvWrite` (1); `readBack` — `documents.csvRead` (0).

**Sample:** `Documents/` — five small files in nested folders.

**Expected:** `catalog.csv` with the header `path,extension,bytes,modified,contentType,sha256` and 5 rows; outputs
`files: 5`, `totalBytes`.

**Verified 2026-11-21:** every row's size and SHA-256 equal the file's, dates are ISO 8601, the row set equals the
file set, the documents are unchanged.

**Limitations:** file-system metadata only (no PDF author, no EXIF); 16 levels deep, hidden files and symbolic links
skipped; at most 2 000 files — a larger folder fails the verification instead of producing an incomplete catalogue;
the catalogue is rewritten in full at every run.

## 13. Scheduled screenshot of a selected app window — `scheduled-window-screenshot` (Screen Recording)

On weekdays every hour (or manually) captures the frontmost window of one chosen application into a dated PNG, when
that application has a window on screen.

| Parameter | Default |
|---|---|
| `bundleID` | `com.apple.Safari` |
| `outputFolder` | `~/ORIX Samples/scheduled-window-screenshot/Captures` |

**Permissions:** screen capture scope `window:<bundleID>` (one application's window, never the display); read/write
`outputFolder`.
**Steps and tiers:** `windows` — `system.windows` (0); `prepare` — `filesystem.mkdir` (1); `capture` —
`screen.capture` (1, needs the macOS Screen Recording permission).

**Sample:** none needed; see `ABOUT.txt`. Try it on a harmless window:
`orixctl workflow run scheduled-window-screenshot --accept-permissions --param bundleID='"com.apple.finder"'`.

**Expected:** `Captures/capture-<date>-<timestamp>.png`; outputs `captured`, `file`, `windows`.

**Verified 2026-11-21: VERIFIED(screenRecording granted)** — Screen Recording was already granted to the process that
ran the tests; a real window was captured (a 1720×998 px Terminal window in one run), the PNG was readable with the
pixel size the tool reported, and it was deleted right after the assertion. Also verified: an application that is not
running gives `SUCCEEDED` with `captured: false`, no picture, nothing launched. When Screen Recording is not granted
the test asserts `BLOCKED_PERMISSION` with no file and prints `SKIPPED(screenRecording not granted)`; that branch did
not run on this Mac.

**Limitations:** ORIX cannot grant itself Screen Recording; the window is captured as displayed (choose the
application with care; password managers are refused by the tool and nothing is captured while a password field has
focus); a locked or sleeping Mac yields nothing; captures are never pruned; the hourly schedule itself was not
exercised here (the scheduler is tested elsewhere).

## 14. Automated spreadsheet validation — `spreadsheet-validation`

Reads one sheet of an `.xlsx` workbook, checks that the required columns exist, that no row is empty and that the key
column is always filled, writes a report, and fails the run when a rule is broken.

| Parameter | Default | |
|---|---|---|
| `workbook` | `~/ORIX Samples/spreadsheet-validation/data.xlsx` | |
| `sheet` | `"1"` | sheet name, or position starting at 1 |
| `requiredColumns` | `[id, name, amount]` | titles expected in the first row |
| `keyColumn` | `0` | zero-based index of the column that must never be empty |
| `reportFolder` | `~/ORIX Samples/spreadsheet-validation/Reports` | receives `validation.md` |

**Permissions:** read `workbook`, `reportFolder`; write `reportFolder`.
**Steps and tiers:** `read` — `documents.xlsxRead` (0); `prepare` — `filesystem.mkdir` (1); `report` —
`filesystem.write` (1).

**Sample:** `data.xlsx` (header + 4 complete rows, one formula cell) and `data-invalid.xlsx` (a renamed column, a row
without id, an empty row), both generated by `make-sample-workbooks.sh` from hand-written SpreadsheetML.

```bash
orixctl workflow run spreadsheet-validation --accept-permissions \
  --param workbook='"~/ORIX Samples/spreadsheet-validation/data-invalid.xlsx"'      # ends FAILED, on purpose
```

**Expected:** `Reports/validation.md` ending with `Valid: true` (run `SUCCEEDED`) or `Valid: false` with the counts
(run `FAILED`).

**Verified 2026-11-21:** the valid workbook passes with 4 data rows and the formula read as its cached value; the
broken one ends `FAILED` at the verification with the report saying "Missing required columns: 1 amount", "Fully empty
rows: 1", "Rows without a key value: 2"; neither workbook is modified.

**Limitations:** `.xlsx` only (no `.xls`, `.numbers`, encrypted files); formulas as cached values, dates as serial
numbers; first row is the header; at most 20 000 rows (a longer sheet fails validation); no type or range rules.

## 15. Multi-step browser data entry on a test site — `browser-data-entry`

Opens a two-page test form in the built-in browser (a private WKWebView), fills name and e-mail, goes to the second
page, chooses a plan and ticks the terms, asks for approval, submits, reads the confirmation and saves a screenshot.

| Parameter | Default | |
|---|---|---|
| `host` | `localhost` | the only host the browser may open: it **is** the browser permission |
| `pageURL` | `http://${{ params.host }}:8765/form.html` | first page of the form |
| `fullName`, `email`, `plan` | `Ada Lovelace`, `ada@example.com`, `team` | values entered |
| `evidenceFolder` | `~/ORIX Samples/browser-data-entry/Evidence` | receives `confirmation.png` |

**Permissions:** browser `host`; read/write `evidenceFolder`.
**Steps and tiers:** `open` — `browser.open` (1); `formReady`, `detailsReady`, `confirmation` — `browser.waitFor` (0);
`fillName`, `fillEmail`, `choosePlan`, `acceptTerms` — `browser.fill` (2); `next`, `submit` — `browser.click` (2);
`confirm` — manual gate before the submission; `readResult` — `browser.read` (0); `screenshot` —
`browser.screenshot` (1); `close` — `browser.close` (0); `prepare` — `filesystem.mkdir` (1).

**Sample:** `site/` — a static three-page site (`form.html` → `details.html` → `done.html`); the values travel in the
address, nothing is stored or sent anywhere.

```bash
cd ~/"ORIX Samples"/browser-data-entry/site && python3 -m http.server 8765 --bind 127.0.0.1 &
orixctl workflow run browser-data-entry --accept-permissions --approve all
```

**Expected:** `Evidence/confirmation.png`; output `confirmation` containing
`Registered <name> <<email>> on plan <plan>.`.

**Verified 2026-11-21** against a loopback server through the real WKWebView tools: the server received
`/form.html`, then `/details.html?name=…&email=…`, then `/done.html?…plan=…&terms=yes`; the confirmation text shows
the submitted values; the screenshot is a readable PNG whose SHA-256 equals the tool's; the gate was asked once and
named what would be submitted; the browser session is closed at the end. With the gate refused: run `FAILED`, the
second page was reached but `/done.html` was never requested, no screenshot.

**Limitations:** a test site only — do not point it at a real site without reading its terms; no CAPTCHA, login or
anti-bot measure is handled; the selectors match the sample pages; plain http is accepted for loopback only; the
built-in browser shares nothing with Safari.

---

## What was and was not verified, in one table

| # | Example | 2026-11-21 on this Mac |
|---|---|---|
| 1 | smart-downloads-organizer | verified (real run) + refused without permissions |
| 2 | pdf-to-structured-report | verified (real run) |
| 3 | weekly-research-digest | verified **live** (Haiku 5.5, US$0.002); notification step fails outside the app |
| 4 | git-test-and-review | verified **live** (Haiku 5.5, US$0.002) |
| 5 | csv-cleanup-and-charts | verified (real sandboxed Python) |
| 6 | batch-image-conversion | verified (real run) |
| 7 | calendar-preparation | **skipped**: Automation consent for Calendar not granted; read-only structure and dry run verified |
| 8 | folder-backup-and-verify | verified (real run) + refused without permissions; notification step fails outside the app |
| 9 | website-change-monitor | verified on loopback only + refused without permissions; public internet never contacted |
| 10 | system-health-report | verified (real run); low-disk warning not exercised |
| 11 | meeting-notes-organizer | verified **live** (Haiku 5.5, US$0.004) |
| 12 | document-metadata-catalog | verified (real run) |
| 13 | scheduled-window-screenshot | verified (Screen Recording granted, real window captured and deleted) |
| 14 | spreadsheet-validation | verified (valid and invalid workbook) |
| 15 | browser-data-entry | verified (real WKWebView, loopback site) + refused gate |

Not verified anywhere: notifications appearing from the app; the triggers firing (schedule, interval, file change —
the scheduler has its own tests); a run started from the app's gallery UI (the gallery calls the same
`installBuiltIn` / `startRun` services the tests use).

To repeat the verification:

```bash
cd Packages/ORIXServices
swift test --filter "Integration · examples"                                        # agent examples: dry run only
../../Scripts/test/with-dev-keys.sh swift test --filter "Integration · examples"    # agent examples live (under US$0.01 in total)
```
