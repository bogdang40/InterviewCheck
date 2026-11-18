# Interview workspace release plan

## Release outcome

An interviewer can prepare a role once, run or import a long interview, review the specific exchanges that need attention, and recover a portable copy of the work. The browser must make the next action clear at desktop and phone widths. Every finding remains linked to the candidate's words, its source and the resource policy.

## Flow

~~~mermaid
flowchart LR
  R[Role and permitted materials] --> S[Session snapshot]
  S --> A[Capture or import exchanges]
  A --> Q[Review queue]
  Q --> E[Selected exchange and source]
  E --> N[Record explanation]
  N --> Q
  N --> X[Report or workspace backup]
~~~

## Implementation and acceptance

| Round | Product work | Acceptance through the normal interface |
| --- | --- | --- |
| 1. Find the work | A populated home prioritizes pending matches and active sessions. The archive supports status, outstanding evidence, search and shareable filters. The interview has a question navigator and a focused evidence view. | Open the right pending exchange from home in one action. The archive preserves filters on Back. A finished session can still need review. Saving, moving to the next pending exchange, finishing and reopening produce consistent counts. |
| 2. Import a complete conversation | Read WebVTT locally, select the candidate, preview exchanges and choose a subset. Submit the selected exchanges atomically to the existing session and return their stable IDs. | Test named and plain speaker formats, limits, omitted prompts, empty selection, retry, rollback, consent, a finished session and an unsaved editor. Preserve the existing single exchange workflow. |
| 3. Prepare once and review safely | Store role policy and permitted sources. Snapshot them into each selected session and use them for comparison and exports. Detect conflicting edits from separate tabs. | Two similarly named roles stay distinct. Editing a template leaves historic evidence intact. A stale review cannot overwrite a newer note or an edited exchange. Keyboard and phone users can finish the same tasks. |
| 4. Recover and hand off | Export and preview a versioned workspace backup. Restore supported local interview data transactionally, with explicit duplicate and conflict handling. Exercise a restore into an empty workspace and include reports, permission snapshots and notes. | Preserve provenance and computed records. Exclude provider credentials, billing data and writable delivery receipts. Reject unsupported versions and invalid input without a partial restore. Verify with an independent run. |
| 5. Release review | Revisit capture, review, import, export and recovery together. Reprioritize defects and further features from the evidence. | Resolve reproducible issues in the supported workflow, verify production and development entry points, check the packaged edition, and record residual field dependencies. |

The core files are in `portable/web/app`, `portable/web/components`, `portable/api` and `portable/qa`. Reuse the existing Next.js routing, FastAPI entitlement checks, SQLite write transactions and local evidence comparison. The queue uses the stored disposition of each answer. Source matching does not establish a candidate's intent.

## Review loop

The orchestrator records each round's scope and acceptance criteria. The reviewer challenges data semantics and tests before implementation. The implementer returns changed paths, test evidence and known limitations. The reviewer exercises the implementation using synthetic local records, checks responsive and keyboard use and returns defects to the owner. The orchestrator verifies the integrated revision and starts the next round. Real vendor accounts, physical capture, public hosting and field detection accuracy require distinct evidence.

## Pilot boundary

Production readiness requires a run on the actual target operating systems, a user-approved test call through the operating system picker, and authorized vendor test tenants. Detection performance requires consented interviews with ground truth obtained independently of the reviewer. A successful browser suite demonstrates the measured workflows and leaves these field questions open.

## Release record

The independent plan review moved write conflict protection ahead of review progression. On an eight-session test workspace, two older interviews containing all three pending matches were absent from the home list. The first pending exchange was 2,789 pixels down on a 390 pixel wide phone. Preserve the distinct interview and review states, stable question links and pending edits in Round 1.

Baseline is merged commit `8d8f4de`. Existing records are never used as test fixtures. Test and screenshot data belong in a scratch directory outside the user's interview store.

### Revision acceptance

The focused service checks on the implementation host exercised shared revisions across question and review edits, an existing database, backward compatible callers and competing writes. One of two writers using the same revision succeeded. The independent production browser check used two tabs. A stale save kept the second tab on the same question with its draft intact, showed the first review on explicit reload and advanced only after an intentional save against the new revision.

### Transcript import acceptance

The focused service suite uses temporary SQLite databases. It covers stable IDs for repeated words at different positions, overlapping selections, exact receipt replay, changed request payloads, original imports after manual edits, concurrent duplicates, rollback on a late conflict, consent, finished sessions and validation bounds. A parser check with both voice tags and speaker prefixes confirmed timestamp spans, unassigned speakers, leading answers and trailing prompts. Production browser acceptance is recorded in the final verification record.

### Source playback acceptance

A browser test created a four second PCM recording in memory and selected it through the review page. Chrome decoded it, stayed paused after selection, sought to the saved interval, paused and resumed on request, and stopped at the end of the exchange. Switching to another exchange from the same transcript kept the file and paused it. An interval longer than the recording disabled playback. Removing the file revoked its object URL. A second test selected unreadable media and verified the error and recovery control. Neither workflow sent media to a service. Separate transcript fingerprints require a new file selection.

## Subsequent reviewed rounds

| Round | Improvement | Release check |
| --- | --- | --- |
| E | Play a local recording at a WebVTT exchange's original interval. | Verify media duration and speaker attribution. Stop playback and release the file on source changes. No media leaves the browser. |
| F | Generate a review brief with explicit disclosure controls. | Default output excludes candidate wording, source contents, notes and legacy metadata. A changed record requires a fresh preview before download. |
| G | Save, resume, discard or publish an incomplete exchange. | Restart the service and recover the same draft revision. Finishing and competing edits cannot lose the draft. Reports count only published answers. |
| H | Bound archive reads and search across interviews, roles and exchanges. | Benchmark a 5,000 interview fixture, preserve filter history and exact links, and verify keyboard search. |
| I | Move interviews to Trash, restore them or explicitly purge a selected trashed record. | Exclude trash from normal reads and writes. Restore preserves its lifecycle and evidence. Restored backups retain Trash state with fresh operation versions. |
| J | Support system, light and dark appearance and accessible small screen navigation. | Check text contrast, keyboard access, reduced motion and persistence using a real browser. |
| K | Preserve follow up parentage and links to the question plan. | Distinguish repeated prompt wording by snapshot slot. Verify links through editing, drafts, exports and backup recovery. |
| L | Explain available connections before credentials are installed. | Derive readiness from the same configuration as the integration; display variable names only. Distinguish configured from a verified provider call. |
| M | Let a new operator practice on three fictional exchanges before the first interview. | Reuse the real comparison service and question navigation. Practice outcomes stay in memory. Verify zero saved records, no report export and no provider calls. |
| N | Check microphone or shared audio locally before an interview. | On explicit operator action, verify the browser supplies a track and report actual signal or silence. Release resources on stop, timeout, cancellation or navigation. No recording, persistence, or provider request. |
| O | Bind provider responses to the inputs that triggered them. Support a bounded, explicit reference lineup. | Changing or abandoning the original question or role must never attach stale output. Disclose recipients; keep per-request outcomes and retry only selected failures. |

The scaling baseline contained 5,000 interviews and 30,000 answers. The original archive request returned 1,697,607 bytes and created approximately 65,465 DOM nodes at desktop width. Hosted deployments, actual recording sources and real provider tenants have separate field verification requirements.

### Trash acceptance

The lifecycle service tests use a temporary database and mocked providers. They exercise the reversible move, preservation of a saved draft and notes, stale confirmation after a second move, simultaneous restore and purge, isolation of another interview using the same role, and removal of all local session children. They also suspend ATS requests while removing a record. Old callbacks disclose no recipient and cannot revive the purged record or create a draft after restoration.

### Question lineage acceptance

The transaction and migration tests cover two plan slots with the same question, edits to the original role, a manually typed matching question, saved draft publication, an old database, WebVTT import, parent and child links, cross interview parents, a cycle and an explicit clear. Full Markdown, printable HTML and archive CSV contain the recorded origins. The redacted brief omits them. The backup graph validator also handles a chain of 2,200 forward references without recursion.

### Audio preflight acceptance

Chrome decoded generated tone and silence through the browser's real Web Audio analyser. The operator had to start each check. A selected shared surface carried separate video and audio tracks, and both ended when the check stopped. The tests exercised denied permission, a surface without audio, a cancelled picker that returned tracks late, an ended source and a hidden tab. The browser created no MediaRecorder and issued no content writes during the measurement. Physical microphone, picker behavior and live calls still need field checks on each target operating system.
