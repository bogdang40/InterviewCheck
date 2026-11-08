# Job Workspaces

One folder per job pursuit. The folder is the durable artifact; SQLite indexes
it so Quick Assist can pull the right material into a prompt in milliseconds.

## Why a folder

People already keep a job description, a tailored resume, project write ups,
and interview notes somewhere. Making that place a plain folder means Finder,
Dropbox, and git all keep working, and nothing is locked inside the app.
memanager adds a manifest, a fixed shelf layout, and an index.

## Layout on disk

```
~/Documents/memanager Workspaces/<Company Role>/
  workspace.json        mirror of the database row (identity, metadata)
  README.md             explains the shelves
  Job Description/      the posting, requirements, team notes
  Resume/               the CV version for this role
  Projects/             stories and write ups worth telling
  Interviews/           round notes, interviewer names, questions asked
  Notes/                everything else
  Journal/              auto appended YYYY-MM-DD.md logs
```

The top level subfolder decides a file's category, which drives prompt
priority (job description first, journal last).

## Data model

| Table | Purpose |
| --- | --- |
| `job_workspaces` | identity, company, role, stage, folder path and bookmark, summary, notes, tags |
| `workspace_documents` | one row per indexed file: path, kind, category, size, SHA-256, extracted text |
| `workspace_journal` | problem solved entries, notes, interview rounds, decisions, open questions |

Migration v16 adds all three. `SessionDatabase+Workspaces`,
`+WorkspaceDocuments`, and `+WorkspaceJournal` hold the data access.

## Services

- `WorkspaceFolderProvisioner` creates the skeleton, avoids name collisions,
  adopts existing folders, writes the manifest. It never deletes user files.
- `WorkspaceDocumentIndexer` walks the folder, fingerprints files, extracts
  text through the existing `ModeTextExtracting` pipeline (PDF, markdown,
  text), skips unchanged files, and removes rows for vanished files. It
  never descends into dependency trees (`node_modules`, `build`, `Pods` and
  friends), stops at 2,000 files, fingerprints files over 64 MB by size, and
  ignores only the root manifest and README (a project's own README counts).
- `WorkspaceImportGuard` refuses the home folder, Documents, and the
  workspaces root as imports, and lets a manifest re-point an existing
  workspace only when the old folder is gone or it is the same folder.
- `WorkspaceJournalRecorder` writes a journal row and appends a markdown
  block under `Journal/` after each Quick Assist turn.
- `WorkspaceRelevanceRanker` scores documents and journal entries against the
  question (token overlap, category priority, recency) and picks the best
  excerpt window inside a document.
- `WorkspaceContextComposer` renders the `JOB WORKSPACE CONTEXT` block within
  a character budget: header, role summary, most relevant journal entries,
  then document excerpts.
- `WorkspaceStore` is the main actor source of truth for the UI.
- `WorkspaceQuickAssistBridge` is the only seam into `SessionController`:
  `contextBlock(question:)` before a turn, `recordProblemSolved` after it
  (routed to the workspace id captured before the turn, so switching mid
  turn never journals into the wrong folder), and
  `bindFolderToActiveModeTools` to hand the folder to the existing read
  only tool loop through the active Mode with a freshly minted bookmark.

## Where it shows up

- Workspaces screen in the overlay (folder icon in the header, next to
  Knowledge and Settings): list, create, import, edit metadata, documents,
  journal, actions (use for Quick Assist, reveal, give tools access, archive,
  delete). Any section tab, Quick Assist, or the transcript log returns to
  the mentor surface; `OverlayNavigator` owns which screen is up.
- Quick Assist top chrome: the workspace pill switches the active workspace
  and toggles context injection and auto journaling. Turning context
  injection off only removes the prompt block; journaling and knowledge
  graph attribution still follow the active workspace
  (`WorkspaceQuickAssistBridge.currentWorkspace`).
- Prompt: the block joins the existing extra context channel next to hub
  memory in `SessionController.quickAssist`.

## Settings

`workspaceContextEnabled` (default on) and `workspaceJournalAutoRecordEnabled`
(default on) in `SettingsManager`.

## Tests

`memanagerTests/Workspaces/` covers storage round trips, folder provisioning
and manifests, indexing (extract, skip unchanged, remove vanished), journal
recording (row plus markdown), and the composer's ranking and budget.
