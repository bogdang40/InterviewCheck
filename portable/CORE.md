# Review service

The FastAPI service keeps interviews and roles in a local SQLite file. Start it from the portable directory with the command below. Build the browser application before starting the service so it can mount the exported pages. The API documentation is available at /docs on the same port.

```sh
python -m uvicorn api.main:app --host 127.0.0.1 --port 8000
```

The default database is `portable/data/review.sqlite3`. Set `INTERVIEWCHECK_DB` to select another file. Set up the existing access service and operator email as described in the portable setup guide to require account entitlement on the workstation. Local mode uses the workstation account as its trust boundary. Multiple people who share the same OS account also share the workspace.

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
| POST /api/roles/import/preview | Check a native role name, question count and duplicate ID before importing |
| POST /api/roles/import | Read the JSON object exported by the native role editor |

For create operations a client can supply an optional UUID as `id`. Replaying the same ID with identical content returns the existing object. Reusing the ID for different input returns HTTP 409. Use an answer's PUT route for intentional edits. Writes use SQLite transactions.

## Native migration

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
