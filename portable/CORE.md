# Review service

The FastAPI service keeps interviews and roles in a local SQLite file. Start it from the portable directory with the command below. The Next.js runtime forwards workspace API requests to this service. The standalone archive serves its built pages directly from FastAPI. The API documentation is available at /docs on the same port.

```sh
python -m uvicorn api.main:app --host 127.0.0.1 --port 8000
```

The default database is `portable/data/review.sqlite3`. Set `INTERVIEWCHECK_DB` to select another file. Enable embedded FastAPI accounts or configure a remote access service and the operator email to enforce membership. [Account and billing setup](CONNECTIONS.md). Local mode uses the workstation account as its trust boundary. Multiple people who share the same OS account also share the workspace.

## Review flow

1. Record the resource policy and candidate notice when opening an interview.
2. Supply one question, one answer and up to twelve named comparison texts. Paste permitted documents as separate sources and mark them permitted. The resource policy field preserves what the interviewer agreed with the candidate. The comparison algorithm processes the supplied source texts.
3. Inspect the quoted candidate and reference passages. Normalization ignores case, punctuation and differences between straight and curly apostrophes. A match starts with six consecutive words, including three distinct words outside the common word list. The source must uniquely locate that sequence. The algorithm excludes four word runs from the question and permitted texts. It also excludes six word runs shared by more than one comparison source. The report returns up to three passages, longest first. Each quote displays up to the first 36 words of its passage. The count describes the complete passage.
4. Ask the follow up and record the candidate's explanation. Set the disposition to explained or unresolved. An unanswered follow up remains pending. An edited answer or reference resets the disposition to pending and marks the old note as belonging to an earlier version.

An answer that paraphrases a reference can produce no match. Common wording in a single supplied source can produce a match. The method operates on word boundaries and uses an English common word list. Speech delivery, reading direction, and device activity do not enter the comparison.

## HTTP interface

All workspace actions use the local origin. Include `X-InterviewCheck: 1` with POST, PUT and PATCH requests. Requests carrying a different browser Origin receive HTTP 403. The service checks Host on reads and writes. The JSON body limit is 2 MiB. The transcription route accepts up to 24 MiB of raw audio.

| Method and route | Result |
| --- | --- |
| GET /api/health | Service status |
| GET /api/sessions | Session summaries with answer count and number of pending matches |
| POST /api/sessions | Create a session with candidate, role, policy and explicit boolean consent |
| GET /api/sessions/{id} | Session details, answers and their evidence |
| POST /api/preview | Calculate a comparison without storing an interview |
| POST /api/sessions/{id}/answers | Add question, answer and references |
| PUT /api/sessions/{id}/answers/{answer} | Correct captured material and recalculate its comparison |
| PATCH /api/sessions/{id}/answers/{answer} | Save note and disposition |
| GET /api/sessions/{id}/report | Download Markdown with the policy, transcripts, named sources, findings and notes |
| GET or POST /api/roles | List or create roles with a name, description and questions |
| GET /api/sessions/{id}/print | Open an accessible printable report. Choose print or save PDF in the browser |
| GET /api/exports/interviews.csv | Download the interview archive as CSV, with formula characters protected |
| GET /api/roles/{id}/export | Download the saved portable role kit |
| POST /api/roles/{id}/duplicate | Copy the latest saved template using a new UUID supplied as `id` |
| POST /api/roles/import/preview | Check the template name, question count and duplicate status for a native or portable role file |
| POST /api/roles/import | Import a native role export or portable role kit |

For create operations a client can supply an optional UUID as `id`. Replaying the same ID with identical content returns the existing object. Reusing the ID for different input returns HTTP 409. Use an answer's PUT route for intentional edits. Writes use SQLite transactions.

## Interview lifecycle

`POST /api/sessions/{id}/finish` records the end of capture. `POST /api/sessions/{id}/reopen` allows capture again when notice was recorded. Both operations can be retried. Review notes and exports remain available when capture has ended. An outstanding edit in the browser must be saved or discarded before exporting.

A new session can select a saved role using its UUID in `role_id`. Its planned questions are copied into the interview. `PUT /api/roles/{id}` edits the reusable template. Existing interviews retain the questions they started with. For sessions from earlier editions, the upgrade recovers a plan from the role title only when exactly one saved template has that name.

## Native migration

In the role library, expand **Role file and copy** and choose **Export role file** to move one template between portable workspaces. Choose **Import a role file** in the destination library. A version 1 `interviewcheck.role-kit` file carries the UUID, name, description, ordered questions, policy and permitted materials, including all text entered in those fields. The file limit is 4 MiB. Import keeps the UUID, skips identical content and reports a conflict if the saved content differs. **Duplicate latest saved role** creates a separate editable template in the current library.

Quit the native app before copying its SQLite database, or use SQLite's backup command to create a consistent snapshot. If a database uses WAL, a copy of the database file alone can omit recent commits. Run the importer against the snapshot on Windows, Linux or macOS. The optional destination is a dedicated portable review database.

```sh
python -m api.migrate interview-snapshot.sqlite
python -m api.migrate role.json --destination ./data/review.sqlite3
```

The importer opens the native database read only. A single target transaction covers the import. A failure rolls back imported records. Repeating an import skips sessions and roles that already exist. To inspect a later snapshot independently, specify a new destination.

The portable role library receives the role title, description and planned questions. Each imported role also retains the full native profile, including prompts and expected answers. Each imported session retains its original session metadata, transcript per question, reference data, native scores, labels and notes. Original records can be inspected in session JSON and the Markdown report. Archived scores remain historical observations. The original notice state carries over. New capture in an archived interview requires a previously recorded notice.

The importer reads the detector report tables introduced in native schema version 17. Account data, credentials, timed words and cached connector data stay in the native database. The native source and its external files remain the archival copy.

## Verification

```sh
python -m pytest -q tests/test_review.py tests/test_migrate.py
```

The tests exercise planted overlap, different wording, missing material, short answers, agreement between references, permitted passages, prompt echoes, consent, account gating, retries and migration. They use synthetic records. Field recall and false referral rates require independently labeled interviews.

Run `python evaluate.py` from the portable directory to reproduce the fixed comparison cases in `evaluation/cases.json`.

| Known synthetic condition | Passage match | No passage match | Limited evidence |
| --- | ---: | ---: | ---: |
| Outside assistance specified in fixture | 4 | 2 | 1 |
| Independent answer specified in fixture | 1 | 4 | 1 |
| Permitted source | 0 | 1 | 0 |

The independent match is a familiar saying found in a single comparison source. The assisted misses include an unseen coach and a paraphrase. The unseen coaching and independent reasoning cases have identical observable inputs and produce the same result. These 14 cases describe specific behaviors and give no estimate of population accuracy.

## Mailbox invites

Set `IMAP_HOST`, `IMAP_USERNAME` and `IMAP_PASSWORD` for a mailbox that contains interview invitations. Use `IMAP_FOLDER` for a dedicated folder and `IMAP_PORT` for a TLS port other than 993. In Connections choose **Sync Mailbox invites**. The service opens the mailbox read only. It searches within the most recent 500 message UIDs and the last 60 days. It inspects MIME structure for the 60 most recent matching messages, then fetches up to 30 calendar parts with BODY.PEEK. An encoded attachment can contain at most 400,000 bytes. Each socket action has an eight second timeout. The sync checks a 45 second deadline between operations.

The calendar parser resolves invite revisions and cancellations across the examined messages. Results include upcoming dated events and report unreadable or omitted attachments. The mailbox remains the source of record for older messages and recurring series. No message body outside the calendar MIME parts is retrieved.

## Private ATS notes

In the interview detail, select **Send a private ATS note**. Choose a provider, search for the candidate's email and verify the returned name and provider ID. Preview the suggested note, edit it and confirm its recipient before sending. The draft uses the interviewer's recorded observations. A candidate disclosure requires an interviewer note. It can coexist with any text comparison result.

Ashby, Greenhouse and Lever support private notes with credentials that permit writing them. Merge also requires `MERGE_REMOTE_USER_ID` and a linked provider that exposes activity visibility. The application checks the linked schema and expects confirmation of private visibility. Lever user mentions can expand the audience, so remove mentions before sending. Native provider references describe these permissions. [Ashby notes](https://developers.ashbyhq.com/reference/candidatecreatenote), [Greenhouse notes](https://harvestdocs.greenhouse.io/reference/post_v3-notes), [Lever notes](https://hire.lever.co/developer/documentation#add-a-note), [Merge activity capabilities](https://docs.merge.dev/merge-unified/ats/common-models/activities/meta-post-retrieve).

A receipt tracks each draft by session and provider ID. The application records the attempt before contacting the provider. A repeated request for an accepted draft returns its receipt. After an interruption or unconfirmed response, inspect delivery history and the destination before preparing another draft.

```sh
python -m pytest -q tests/test_mailbox.py tests/test_ats_notes.py
```

These tests use a scripted mailbox and mocked ATS transports. They exercise TLS configuration, read only access, calendar part selection, changed and cancelled invitations, destination confirmation, explicit private visibility and duplicate send protection.

Workable writes comments restricted to administrators when `WORKABLE_MEMBER_ID` is configured. Recruitee resolves the token owner's admin ID and restricts a protected note to that admin. [Workable comment visibility](https://workable.readme.io/reference/comment-on-candidate), [Recruitee API](https://apidocs.recruitee.com/).

## Conflicting edits

Each saved answer has one revision for the transcript, sources, disposition and note. The first revision is 1. A material change increments it. The browser sends its draft's `expected_revision` on PUT and PATCH. A stale request receives HTTP 409 and the header `X-InterviewCheck-Conflict: answer-revision`. Reloading the saved exchange shows its latest content alongside the editable draft. The reviewer can keep editing the draft against that version or discard it. This also applies before moving to the next pending review. Existing records receive revision 1 on upgrade. Clients that omit `expected_revision` keep their original update behavior.

## Import a WebVTT conversation

Open a consented interview in progress and choose **Import transcript exchanges**. Select the candidate and each interviewer. The importer groups adjacent interviewer cues into prompts and candidate cues into answers. Other speakers interrupt a pair. The preview counts unassigned cues, standalone candidate turns and unanswered prompts. Inspect the question and answer text, edit either, and select the exchanges to save. The existing **Import a meeting transcript** control inside the exchange editor still imports one exchange.

The browser reads a WebVTT file of up to 2 MB with up to 10,000 cues. It accepts named voice tags and names followed by a colon. One cue must have a single speaker and valid timestamps. Only the selected exchanges, speaker names, timestamps and file fingerprint go to the local service. Each submission can include up to 100 exchanges with a combined maximum of 500,000 characters. Each selected question can contain up to 4,000 characters and each answer up to 24,000.

POST `/api/sessions/{id}/imports/webvtt` accepts `request_id`, `transcript_sha256`, `candidate_speaker`, `interviewer_speakers` and a list of `exchanges`. Each list item carries its ordinal, start and end in milliseconds, question and answer. The browser includes the first and last cue indexes to distinguish distinct turns even when their timestamps coincide. API clients that omit cue indexes must provide distinct time ranges. The service saves the batch and its receipt in one SQLite transaction. It returns the number saved, the number already imported, the ordered answer IDs and a replay indicator. A repeated request with the same input returns the same IDs. Changing the selection under a previously committed request ID returns HTTP 409. An exact receipt replay can be acknowledged after the session finishes. New selections require an open session and recorded notice.

Each imported exchange retains its original fingerprint, speaker mapping, ordinal, time range and any supplied cue indexes. Changing the selected interviewers or display ordinal leaves an unchanged turn identifiable by its original candidate and cue coordinates. Identical text at two positions produces distinct records. A fresh request for an already imported exchange skips it even after an interviewer edits it. Submitting different source text for the same original position returns a conflict and rolls back the request. Deselect a conflicting exchange or edit it in the interview record. Raw source files and file names are not stored.

## Role policies and permitted sources

Save the assistance policy and up to eight named permitted sources in a role template. Each source accepts a name of up to 180 characters and text of up to 12,000 characters. Selecting a template on the setup form copies its values into the draft. The interviewer can edit those values and confirm the notice before starting capture. The new interview keeps its own copy. Later template changes apply to future interviews.

The session detail returns the policy and its `permitted_sources` snapshot. Live draft comparison, saving, editing and evaluating imported exchanges apply the same snapshot. Each answer stores its own explicit comparison sources separately. Markdown, the print view and archive CSV include the agreed materials. Older roles and sessions receive an empty source list on upgrade.

## Review brief

Open an interview and choose **Review brief** for a handoff based on saved outcomes. The default Markdown identifies the interview by its local session UUID and refers to exchanges by their order. It includes capture state, comparison counts and mutually exclusive interviewer outcome counts. Pending review counts only passage matches awaiting review. Exchanges with a pending disposition and no match have their own group. Human disclosures and unresolved outcomes are recorded independently of the comparison result.

The default brief omits names, role, policy text, questions, answers, prompts, source labels and passages, notes and native records. The local preview controls use exchange UUIDs to select text. Select individual answer excerpts or notes under **Choose excerpts and notes** to include them. An excerpt contains at most 240 Unicode characters from the beginning of the saved answer. An included note contains its full saved text. Either may identify people. The full evidence report, print view and archive CSV remain separate exports.

Downloading compares the current brief against the preview digest. If its content changed, refresh the preview and inspect it again. The brief is downloaded locally. It has no send action.

## Play a local source recording

Select an exchange imported from WebVTT and open **Local recording playback**. Choose the recording that corresponds to that transcript. The display identifies the candidate speaker and the imported exchange start and end times. Confirm the match before pressing **Play excerpt**. An interval can include both the interviewer's prompt and the candidate's reply. The operator can pause, resume or replay it. An empty interval, an unreadable recording, an unknown duration, or an interval outside the recording disables playback.

The browser opens a temporary object URL for the selected file. Playback does not upload media, write to the interview database, call a transcription provider, or identify the recording automatically. Changing questions pauses playback. A selected file remains available only for exchanges in the same session with the same transcript fingerprint. Selecting a different transcript, removing the recording or leaving the interview releases the file handle. Use capture and transcription separately if new words need to be added to the interview.

## Trash and permanent deletion

Select **Move to Trash** on an interview and confirm. Trash removes the interview from the normal archive, queue, exports, recipient lookups and direct review URLs. **Undo move** and **Restore interview** return the original record, including its notice, finished state, saved draft and review notes. Trash has no automatic purge schedule.

To erase local interview data, open **Trash**, choose **Delete permanently**, and enter the exact interview ID shown there. Restore and purge requests carry an opaque version for that move. A stale confirmation cannot affect a record that was restored and moved again. Permanent deletion removes the session, exchanges, draft, source snapshot, import receipts and local ATS delivery history in one transaction. Shared role templates remain available.

A note dispatched to an external ATS before removal cannot be recalled here. An in-flight lookup or delivery response cannot recreate a purged record or return its private recipient. After restoring a session with an attempted delivery, check the ATS before sending another note. Previously exported documents and external backups remain under the operator's control. Running the native importer against an existing trashed interview skips it. Explicitly importing the original native snapshot after permanent deletion can create a new local copy.

## Find records

Quick search sends a literal query to the authenticated service by POST. It matches role names, candidate names, session roles, questions and answers, and excludes private notes, source texts and credentials. Exact and prefix title matches take precedence over answer body matches. A search response includes up to 50 distinct records with a bounded excerpt of the matching field. Trashed sessions and their answers are excluded.

The interview archive loads 25 summaries per page. Its URL preserves the candidate or role filter, capture state, evidence status, sort and page. The home page returns full counts alongside up to ten sessions awaiting review and five active sessions. Each queued link opens the first pending match in capture order. Existing clients can still read the original session list endpoint.

## Assignment queues

Open **Interviews** to find reviews by assignee, priority or deadline. **Due soon** covers the next 48 hours, including the upper bound. Each page shows its position in the filtered queue. Moving to another page or filter clears the current selection; bulk changes apply only to the selected interviews on the displayed page. Interviews in Trash are excluded.

## Question origins

A new exchange can have one explicit origin. Choose a **Planned question** to link its one based slot in this interview's frozen plan, or select **Parent exchange** to link a follow up. The **Ask this follow up** action fills the suggested question and selects its parent. Editing the question wording preserves the link. Select a different origin to replace it, or clear the current selection to remove it. An imported, manual or older exchange has no recorded lineage until an operator explicitly assigns one.

In the focused interview, **Question plan** shows how many slots have a recorded exchange. Identical prompt text in different slots counts separately. An unlinked answer with matching wording does not count toward a slot. Parent and child question buttons navigate the recorded links. Saving a draft, resuming it, publishing and restoring a workspace backup retain these relationships. A parent must exist in the same interview; an exchange cannot parent itself or create a cycle. Full Markdown, print and archive CSV exports include recorded origins. The default redacted review brief does not add this material.

Clients can supply `parent_answer_id` or `planned_slot` when creating or updating an exchange or saved draft. Omit both on update to preserve the existing origin. Supplying either field sets the origin pair; explicit nulls clear it.


## Workspace recovery

Open **Data** to download a whole workspace or one interview and its linked role. The JSON contains private interview records, permitted material, review notes, saved drafts and their provenance. A whole workspace includes interviews already in Trash. Account credentials, billing, external send history and operation tokens are outside this archive.

Versions 3 and 4 record the current assignment for each interview, including interviews in Trash. An assignment contains the assignee email, who assigned it, its priority, its deadline if set, and the time of the last assignment change. An unassigned interview has an explicit null assignment.

Version 4 also saves private panel handoff notes, including each note's ID, author, category, text and creation time. A note whose text was erased by retention stays empty. Use a workspace that supports version 4 to restore new downloads. Restoring a version 1, 2 or 3 file preserves existing handoff notes on matching interviews. Such files cannot recover handoff notes into an empty workspace.

Versions 1 and 2 did not record assignments. Restoring an older file into a fresh workspace leaves its interviews unassigned. Restoring the same file over an otherwise identical interview preserves the assignment already in the workspace.

Select a local backup and choose **Preview restore**. The server checks the format, graph, word matches and snapshot against the file and compares stable record IDs with the target. The preview lists new records, identical records, conflicts, saved drafts and the number of assignments and handoff notes in the file. If a recorded assignment or handoff note differs from the target, the entire restore stops. A handoff note ID already attached to another interview also blocks the restore. On explicit **Restore new records**, the server checks the same file and database again inside one write transaction. A fresh Trash operation version is issued for each restored trashed interview.

JSON restore has a 20 MiB file limit. Export smaller sets as individual interviews where appropriate. For a complete large deployment, use SQLite's consistent backup procedure and retain any separate account database under the operator's storage policy. The service does not automatically delete backup files when an interview is purged.
