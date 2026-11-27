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

In the role library, expand **Role file and copy** and choose **Export role file** to move one template between portable workspaces. Version 2 of `interviewcheck.role-kit` carries the role UUID, name, description, ordered questions, policy, permitted materials and ordered grading rubric. Each criterion includes its ID, weight, expected signals and red flags. The file includes the full text in these fields and has a 4 MiB limit.

Choose **Import a role file** in the destination library. Preview shows the question count and, for version 2, the criterion count. Import keeps the UUID, skips identical templates and reports a conflict when a field recorded in the file differs. Version 1 files have no rubric field. They create new roles with an empty rubric and preserve the rubric on an otherwise identical saved role. **Duplicate latest saved role** creates an independent template with a new ID and its own initial revision.

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

When a judge model is connected, **Suggest questions** uses the passage match saved with the exchange. It sends the interview question and up to three pairs of matched excerpts to the model. Each excerpt is limited to 1,000 characters. The model selects a phrase and an angle, such as verification or a limitation. The app checks that the phrase occurs in the matched answer excerpt and uses it in a question. An exchange with insufficient evidence or no eligible match keeps its local follow up. The same applies to an archived exchange without recorded notice. A match shows shared wording. The interviewer can use a suggested question to ask how the candidate reached an answer, then record the outcome.

Run `python -m pytest -q tests/test_saved_judge.py` from the portable directory to exercise this decision on the fixed comparison cases, including permitted text, a brief independent answer and a shared saying. A scripted provider returns a high score. The saved review exposes only suggested questions.

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

The scorecard editor sends the version it opened. If someone else saves first, the editor combines edits to different criteria and asks which score to keep for each criterion that both reviewers changed. Check the result and select **Save scorecard**. Unchanged criteria keep their original reviewer and update time. A rationale needs a rating before it can be saved.

If a reconciliation request temporarily fails, the scorecard and assignment editors keep the open proposal. If access is denied, the affected editor clears its private fields. Reload that editor after access returns to see the current saved values.

To correct a grade entered by mistake, mark that saved rating for removal. The preview excludes the marked rating. Its rationale stays available for **Undo** until you save. After saving, a criterion in the current role appears ungraded. A criterion added only to this interview disappears. If another reviewer changed a marked rating, compare their edit with the proposed removal before saving again.

The handoff panel loads 20 notes at a time. Select a category or browse older notes without losing a note you are writing or a score you are editing. The panel uses the saved note timestamp and ID for stable ordering. Paging affects only the panel. A workspace backup still carries all handoff notes for each included interview.

Local answer edits follow the saved draft or published exchange they belong to. Reverting all edits clears that editor's recovery copy. If an older app saved edits without recording the draft ID, open **Unlinked local draft** to inspect and copy or download the text. Moving an interview to Trash clears its local copies in this browser. Signing out clears local copies for the workspace.

## Import a WebVTT conversation

Open a consented interview in progress and choose **Import transcript exchanges**. Select the candidate and each interviewer. The importer groups adjacent interviewer cues into prompts and candidate cues into answers. Other speakers interrupt a pair. The preview counts unassigned cues, standalone candidate turns and unanswered prompts. Inspect the question and answer text, edit either, and select the exchanges to save. The existing **Import a meeting transcript** control inside the exchange editor still imports one exchange.

The browser reads a WebVTT file of up to 2 MB with up to 10,000 cues. It accepts named voice tags and names followed by a colon. One cue must have a single speaker and valid timestamps. Only the selected exchanges, speaker names, timestamps and file fingerprint go to the local service. Each submission can include up to 100 exchanges with a combined maximum of 500,000 characters. Each selected question can contain up to 4,000 characters and each answer up to 24,000.

POST `/api/sessions/{id}/imports/webvtt` accepts `request_id`, `transcript_sha256`, `candidate_speaker`, `interviewer_speakers` and a list of `exchanges`. Each list item carries its ordinal, start and end in milliseconds, question and answer. The browser includes the first and last cue indexes to distinguish distinct turns even when their timestamps coincide. API clients that omit cue indexes must provide distinct time ranges. The service saves the batch and its receipt in one SQLite transaction. It returns the number saved, the number already imported, the ordered answer IDs and a replay indicator. A repeated request with the same input returns the same IDs. Changing the selection under a previously committed request ID returns HTTP 409. An exact receipt replay can be acknowledged after the session finishes. New selections require an open session and recorded notice.

Each imported exchange retains its original fingerprint, speaker mapping, ordinal, time range and any supplied cue indexes. Changing the selected interviewers or display ordinal leaves an unchanged turn identifiable by its original candidate and cue coordinates. Identical text at two positions produces distinct records. A fresh request for an already imported exchange skips it even after an interviewer edits it. Submitting different source text for the same original position returns a conflict and rolls back the request. Deselect a conflicting exchange or edit it in the interview record. Raw source files and file names are not stored.

## Role policies and permitted sources

Save the assistance policy and up to eight named permitted sources in a role template. Each source accepts a name of up to 180 characters and text of up to 12,000 characters. Selecting a template on the setup form copies its values into the draft. The interviewer can edit those values and confirm the notice before starting capture. The new interview keeps its own copy. Later template changes apply to future interviews.

The session detail returns the policy and its `permitted_sources` snapshot. Live draft comparison, saving, editing and evaluating imported exchanges apply the same snapshot. Each answer stores its own explicit comparison sources separately. Markdown, the print view and archive CSV include the agreed materials. Older roles and sessions receive an empty source list on upgrade.

## Panel discussions

Open a reviewer disagreement under **Roles**, or open **Panel discussion** on a saved exchange. Entitled reviewers can inspect the recorded opinions, process state, and dates. An administrator can request follow up, complete a discussion, or reopen it. Each action requires a reason. The editor binds that reason to the current administrator session and the saved exchange. Signing out or changing accounts clears the private draft. After a purge and JSON restore, open a fresh editor for the restored exchange. Only administrators can read the private reasons and the identities of the administrators who recorded them. Panel decisions do not change an answer disposition, score, or hiring outcome.

A change to the saved exchange content or a new reviewer opinion requires another panel review, even if the wording or opinion is later restored. Editing only a reviewer note leaves the existing process state in place. A former decision remains in the history when the current context changes. Cases with required follow up remain in the open view. The history page shows up to ten changes per read.

Private panel records live in the review SQLite database and are covered by the consistent database backup. The ordinary workspace JSON and calibration exports omit them. Restoring a workspace JSON into an empty database recovers the underlying reviews and starts any disagreement without a panel decision. Replaying a matching JSON file preserves local decisions. Trash hides the discussion. Retention anonymization and permanent purge erase its history.

## Deferred questions

Keep a selected follow up on its saved parent without replacing the interview's existing exchange draft. Equal question wording on different parents identifies different work. A pending item becomes fulfilled only when its linked child exchange is actually committed. Saving a draft, closing the editor, reaching an assignment deadline or finishing the interview does not fulfill an item. Reopen a finished interview before beginning another exchange.

A changed parent requires explicit reconfirmation against its current material. A reviewer note alone does not invalidate the question. The original selected wording and parent are retained; a fulfilled child remains linked to that parent if its answer is corrected. Withdrawing notice, Trash and retention protection restrict availability. Retention anonymization removes deferred questions and linked drafts.

Workspace JSON version 7 includes each interview's deferred questions, their state and the link to any saved deferred draft. Existing schedules, notes, scorecards and role snapshots keep their earlier meanings. Older imports start without deferred work, and replaying a matching version 1 to 6 file preserves locally saved questions. Each fulfilled question is checked against a publication fact on its original child, including after a later correction. Each parked linked draft has a separate local token. Discarding and recreating it issues a new token even if all visible fields are identical. A matching question restored from JSON confirms its presence, but cannot confirm an earlier Keep request. A fresh JSON restore regenerates local edit tokens. Read the restored queue and draft before writing. A consistent SQLite backup also retains in-flight request receipts.

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

Quick search sends a literal query to the authenticated service by POST. It matches role names, candidate names, session roles, questions and answers, and excludes private notes, source texts and credentials. Exact and prefix title matches take precedence over answer body matches. The palette pages through matching records while keeping its search term and page history in memory. The **Data** page can also browse interviews or search by candidate or role before downloading a single interview.

API clients can request up to 50 distinct results per response. Send an empty `cursor` to start a paged search. Send the returned `next_cursor` with the same literal and record types to read the next page. A null continuation marks the end. Each request reads the current workspace, so edits and moves to Trash can change later results. Clients that omit `cursor` keep the original response shape.

The interview archive loads 25 summaries per page. Its URL preserves the candidate or role filter, capture state, evidence status, sort and page. The home page returns full counts alongside up to ten sessions awaiting review and five active sessions. Each queued link opens the first pending match in capture order. Existing clients can still read the original session list endpoint.

In role calibration, each numbered question is grouped by its slot and the prompt saved with the interview. Editing the recorded wording of an answer keeps it in its planned group. An older interview with no usable plan, or one displayed as anonymized, uses its recorded wording. Role and cohort review percentages use human-reviewed answers as their denominator. A group with no reviewed answers has no measured percentage.

## Assignment queues

Open **Interviews** to find reviews by assignee, priority or deadline. **Due soon** covers the next 48 hours, including the upper bound. Each page shows its position in the filtered queue. Moving to another page or filter clears the current selection; bulk changes apply only to the selected interviews on the displayed page. Interviews in Trash are excluded.

An open queue refreshes when a deadline enters **Due soon** or becomes overdue. Selecting interviews for a bulk edit holds the displayed rows and their saved versions until you finish or clear the selection.

When editing one assignment, leaving the displayed UTC date unchanged preserves the original time and precision. Changing the date sets the deadline to 23:59:59 UTC. A blank date clears the deadline. Bulk assignment replaces the deadline on every selected interview.

Assignment changes in the browser use the version displayed for each interview. When another reviewer changes an assignment first, compare the current assignment with your proposed change before saving. For a bulk change, a conflict leaves every selected interview unchanged. Review the refreshed page and select the intended interviews again. The form keeps the entered assignee, priority and date.

## Question origins

A new exchange can have one explicit origin. Choose a **Planned question** to link its one based slot in this interview's frozen plan, or select **Parent exchange** to link a follow up. The **Ask this follow up** action fills the suggested question and selects its parent. Editing the question wording preserves the link. Select a different origin to replace it, or clear the current selection to remove it. An imported, manual or older exchange has no recorded lineage until an operator explicitly assigns one.

In the focused interview, **Question plan** shows how many slots have a recorded exchange. Identical prompt text in different slots counts separately. An unlinked answer with matching wording does not count toward a slot. Parent and child question buttons navigate the recorded links. Saving a draft, resuming it, publishing and restoring a workspace backup retain these relationships. A parent must exist in the same interview; an exchange cannot parent itself or create a cycle. Full Markdown, print and archive CSV exports include recorded origins. The default redacted review brief does not add this material.

Clients can supply `parent_answer_id` or `planned_slot` when creating or updating an exchange or saved draft. Omit both on update to preserve the existing origin. Supplying either field sets the origin pair; explicit nulls clear it.


Candidate comparisons use the saved question plan for each interview. If plans differ, each candidate's cell shows the prompt that applied at the time. Additional answers retain their slot and exchange link. Excerpts and reviewer notes require a new selection when the comparison moves to a different set or order of interviews.

Changing what to include requests a fresh comparison and cancels a Markdown download that is still being prepared. If access is denied, use **Retry comparison** after access is restored.

Use **Change interviews** to select up to six interviews across archive pages or searches. Select **Include saved scorecards** to compare the recorded criteria, weights and ratings in selection order. **Include reviewer rationales** also shares the rationale text in the comparison, printout and Markdown download. Each interview's weighted percentage uses only criteria with a saved rating. Percentages round to one decimal place, with exact ties rounded to the even tenth. An interview with no ratings is ungraded.

## Workspace recovery

Open **Data** to download a whole workspace or one interview and its linked role. The JSON contains private interview records, permitted material, review notes, saved drafts and their provenance. A whole workspace includes interviews already in Trash. Account credentials, billing, external send history and operation tokens are outside this archive.

The download link names the selected scope. Before handing the file to the browser, the app checks the filename and compares the received bytes with the SHA-256 checksum from the server. Open **Backup checksum** to copy the verified value and keep it separately for a later restore. A failed download keeps the selection available for retry. Selecting a different scope cancels a transfer that is still being verified.

Versions 3 and later record the current assignment for each interview, including interviews in Trash. An assignment contains the assignee email, who assigned it, its priority, its deadline if set, and the time of the last assignment change. An unassigned interview has an explicit null assignment.

Versions 4 and later also save private panel handoff notes, including each note's ID, author, category, text and creation time. A note whose text was erased by retention stays empty. Restoring a version 1, 2 or 3 file preserves existing handoff notes on matching interviews. Such files cannot recover handoff notes into an empty workspace.

Version 5 introduced rubric scorecard entries for each interview in display order, including each criterion ID, criterion label, weight, rating, reviewer rationale, who last updated it and the update time. A rationale erased by retention anonymization stays empty while the numeric rating and weight remain intact. Restoring a version 1, 2, 3 or 4 file preserves existing rubric scorecards on matching interviews and leaves newly restored interviews ungraded.

Version 6 also saves each interview's original role rubric, including the role version, order, criteria weights and guidance. A new interview started without a role template records that choice. The scorecard shows its captured rubric even if the role later changes. Historical interviews whose original rubric cannot be established show the current template as a fallback and keep existing grades. Versions 1 through 5 preserve existing snapshots when restored to the same interview and supply no snapshot for a newly restored interview. Restore downloads that include deferred questions on a workspace that supports version 7.

The version 6 privacy record preserves a confirmed retention timestamp for active and trashed interviews. It omits the administrator's identity. Restore preserves restrictions on calibration details, saved model suggestions and private ATS transfers. Versions 1 through 5 lack the original receipt. On a fresh import, a matching pseudonym paired with a scrubbed answer, or with an empty interview and no draft or native payload, creates a protective hold with unknown provenance. A workspace upgrade applies the same check to older restored records. A hold does not certify erasure. An existing local marker is preserved on a matching legacy replay. Keep a SQLite backup for original audit attribution.

An older database can contain a confirmed erasure receipt alongside private answer text or a saved revision. The workspace withholds the affected interview from review and search. A whole workspace JSON backup stops if it includes such an interview. The archive CSV also stops if the interview is outside Trash. You can still export unaffected interviews individually. **Admin > Compliance > Data retention** shows the number withheld.

For recovery, take a consistent SQLite backup and inspect a separate copy. The query `SELECT session_id FROM retention_read_holds ORDER BY session_id` lists the affected IDs in the upgraded copy. The original interview, saved revisions and erasure receipt remain in SQLite. Check the copy against a known backup taken after erasure. Reopen a corrected copy and verify the affected report before returning it to service. Trash still follows the configured purge schedule.

Versions 1 and 2 did not record assignments. Restoring an older file into a fresh workspace leaves its interviews unassigned. Restoring the same file over an otherwise identical interview preserves the assignment already in the workspace.

Select a local backup and choose **Preview restore**. The server checks the format, graph, word matches and snapshot against the file and compares stable record IDs with the target. The preview lists new records, identical records, conflicts, saved drafts and the number of assignments, handoff notes and rubric scores in the file. If a recorded assignment, handoff note or rubric scorecard entry differs from the target, the entire restore stops. A handoff note ID already attached to another interview also blocks the restore. On explicit **Restore new records**, the server checks the same file and database again inside one write transaction. A fresh Trash operation version is issued for each restored trashed interview.

If the connection drops while restoring, the server may already have saved the records. The selected file stays in the form. Choose **Preview restore** again to see which records are present. An identical record is skipped if you restore again.

For up to 20 conflicting records, the preview lists the parts that differ, such as the assignment or saved scorecard. A scorecard difference can include reviewer attribution or its update time. Clients can request these categories with `include_conflict_reasons=true` on the preview endpoint.

JSON restore has a 20 MiB file limit. Export smaller sets as individual interviews where appropriate. For a complete large deployment, use SQLite's consistent backup procedure and retain any separate account database under the operator's storage policy. The service does not automatically delete backup files when an interview is purged.


## Offline review worksheet

Open **Offline review worksheet** on one saved exchange and choose **Preview worksheet**. The default text contains the exchange number, record identifiers, revision and verification receipts. Select the question or the first 240 characters of the answer to include either field. Inspect the exact contents before copying or downloading.

Edit the text below the proposed note marker in a UTF-8 text editor. The file can be edited offline. Return to the same exchange in the original workspace, select the file, and compare the proposed note with the saved note. **Stage proposed note** places it in the current tab. **Save review** saves the note and keeps the existing outcome and reviewer votes. The app checks eligibility and current evidence at each transfer, staging and save. A change while the comparison is open requires another comparison. An unavailable server cannot validate or apply a worksheet. If a save reply is lost or incomplete, **Check saved review** reads the current state. It reports when the submitted note is already present and keeps later local edits. If another reviewer changed the note, compare the versions before deciding to keep your edits. A confirmed loss of access clears staged text from the tab. Preview reserves space in the file for a full 12,000 character UTF-8 note.

Each saved exchange has a private binding key. Purging the exchange and restoring its JSON creates a new identity even in the same workspace. A full SQLite restore preserves the original identities and conditional actions still check the saved material and review. Downloaded files, clipboard copies and text in an external editor remain under the recipient's control after an interview is trashed, anonymized or removed. Staged worksheet text is held in memory until saved or discarded.
