# Portable edition acceptance

## Reviewer data and recovery

The Windows, Ubuntu and container upgrade checks passed for the reviewer workflow release. The deployed merge `4f38133` has the same Git tree as the tested PR head. Local verification on that head passed 728 backend tests, 371 production browser tests, six development checks and three static browser checks. The normal npm launchers and a fresh ZIP extraction also passed their startup and shutdown checks. The separate Windows build after merge passed the static browser assertions but failed while stopping its test server. [PR checks](https://github.com/bogdang40/InterviewCheck/actions/runs/45232233822) · [Postmerge Windows job](https://github.com/bogdang40/InterviewCheck/actions/runs/45236954386/job/137911081853) · [Production rollout](https://github.com/bogdang40/InterviewCheck/actions/runs/45240578974)

Two synthetic reviewers exercised scorecard changes for 130 minutes on `ba1c157`. The test observed 101 save requests, 32 stale writes and two overlapping edits that needed an explicit choice. It checked the saved ratings, rationales and attribution after writes and after two ten minute idle periods.

The archive recovery check used files created by the actual version 1, 3, 4 and 5 writers. A separate version 2 reader fixture was derived from version 1. Version 5 recovered a 70.0% active scorecard and a 73.3% scorecard in Trash with their original rationale text, authors and update times. Replaying an older archive over an otherwise identical interview preserved a newer local grade. Replaying a conflicting version 5 file returned HTTP 409.

## Interview workbench

The release candidate at Git tree `73bae5dc9ba93aeed437c2ed3f0883d0d6c9b9f3` passed all **232 backend and production browser tests** in a clean Debian 13 ARM64 guest, in 72.05 seconds. The run used Linux 6.12.117, Python 3.13.5, Node 22.16.0 and Chromium 159.0.8154.6. Both root npm entry points passed HTTP, WebSocket and shutdown checks. The static export, production build, TypeScript and all synthetic evaluation expectations passed. Five additional development checks and three static browser checks passed. A fresh extracted ZIP started without Node on the executable path, completed embedded trial signup and durably saved an interview.

That run used a Git archive of the source tree and synthetic records in empty databases. It found and retested two release issues: the single and batch transcript controls required distinct locators, and the header needed a narrower mobile layout to fit inside a 320 pixel viewport. The only warning in the combined test run was a FastAPI TestClient dependency deprecation. Windows x64 CI remains a separate check for this revision; Linux performance and browser results do not establish Windows behavior.

Independent acceptance used fictional interviews in temporary databases. For the UI comparison, eight interviews contained 13 exchanges and three pending passage matches. Both affected interviews were absent from the five most recent rows in the original workspace. The new queue linked directly to each pending exchange, including one in a finished interview. At a 390 pixel viewport width, the first pending question in the six exchange record moved from 2,789 pixels below the top to 546 pixels below the top.

| Workflow | Independent check |
| --- | --- |
| Review | Archive filters survived browser Back. Refresh retained the selected exchange. Mobile navigation stayed disabled during unsaved changes. A match following a Unicode emoji highlighted the correct text in the correct one of two sources with identical names. |
| Updates from two tabs | A stale save preserved the local note, kept the current selection and left the stored version intact. The reviewer could compare versions, reconcile the note and advance. A separate check covered competing saved drafts. |
| Transcript import | A three speaker WebVTT file produced only the selected interviewer and candidate exchanges. A new host selection or display ordinal could not duplicate an existing cue. Concurrent repeated imports produced one set of answers. An error in the final row left earlier rows unwritten. |
| Policy and history | Revisions to a role left an existing interview's permitted sources intact. Selecting the second of two identical planned questions preserved its slot. An edited follow up retained its parent after saving and resuming a draft. |
| Drafts and backup | Two separate FastAPI processes reopened the same saved draft. It stayed out of evidence and exports until publication. A backup restored the draft, source snapshots and imported cue identities. The Next.js proxy accepted a valid file above 2 MiB and rejected one byte above 20 MiB. |
| Local media | Synthetic WAV playback and input checks used browser media APIs. A short or unreadable recording produced an error. A different transcript required a fresh file selection. Stopping a check before permission resolved released late tracks, and leaving the page closed the active audio context. |
| Briefs and delivery | The default brief omitted private names, source labels, prompts, transcript and notes. Selecting a note enabled its export. A changed note invalidated the prior download approval. |
| Data lifecycle | Purge required the current Trash version and exact interview ID. A previous version could not remove a restored interview. A delayed synthetic ATS callback did not update the receipt after a move and restore. |
| Search and setup | A literal search containing percent and underscore matched one answer. Keyboard reopening, focus return, and answer navigation were checked. A partially configured ATS displayed a separate state for each operation. The catalog exposed no credential values and made no vendor calls. |
| Practice | The three fictional exchanges used only the local preview endpoint. Practice notes, outcomes and reset did not create real interview records. |
| Generated references | Delayed provider output was discarded when the originating role or exchange changed. A question changed and then reverted still invalidated the pending result. A partial two-provider failure retried only the failed provider after an explicit action. Existing operator sources were preserved. |
| Appearance | A local axe-core 4.14.1 sweep of 10 screens in light and dark settings found zero violations among the selected contrast, field-name, control-name and ARIA checks after repairs. Primary text contrast was 14.95:1 in light and 13.76:1 in dark. Muted text measured 5.57:1 and 8.46:1. Keyboard theme selection persisted across reloads and synchronized across tabs. Actual WebGL draw counts stopped when reduced motion was enabled. |

### Archive load

A local Chrome test compared the archive before and after pagination with 5,000 synthetic interviews, six exchanges per interview and 30 role names. Each frontend measurement used a fresh 1440 pixel browser page. API time is the median of five local reads.

| Metric at 5,000 sessions | Original full list | First page of 25 |
| --- | ---: | ---: |
| JSON returned | 1,697,607 bytes | 6,731 bytes |
| Median API time | 76 ms | 5 ms |
| DOM nodes | About 65,465 | About 513 |
| Time until the expected rows were present, two runs | 389 ms in both runs | 97 and 103 ms |

These figures describe this fixture, browser and workstation. They do not establish hosted throughput, physical capture compatibility or detection accuracy.


## Next.js server and FastAPI

On November 18, 2026, Chrome on macOS exercised the Next.js development server and production server against separate FastAPI processes or listeners. Each scenario used a temporary SQLite database. The production browser suite exercised interview capture, review, exports, migrations, account access, and the actual WebSocket proxy. The combined backend and production acceptance run passed 122 tests. Five dedicated development checks passed, including the same audio transfer, interview lifecycle, role selection, signed webhook path and account administration. A scripted provider accepted real encoded audio frames and returned final words. No test sent audio or notes to a vendor.

The browser selected the second of two roles with the same name. Its interview retained the correct planned questions after an edit to the role library. The reviewer could inspect a live comparison before saving, change a source permission, start the suggested follow up, finish the interview and reopen it. The API rejected new answers while the session was finished. Pending answer edits and review notes blocked report export. Declining a navigation prompt preserved the draft note. The original hash link and the canonical review URL opened the same record.

The Account screen created a synthetic local administrator, granted complimentary access to a second test account, displayed the audit entry and signed out. Browser Back after sign out did not display the protected record. The production and development proxies accepted a correctly signed synthetic webhook with Unicode text and rejected the same signature after one body byte changed. Subscription and checkout tests used a fixture Stripe transport.

The release test started an extracted package without Node on the executable path, created a local account in embedded mode and saved an interview. The source workflow also tests compatibility with the original Node account service.

## Previous portable release

A clean Debian 13 ARM64 guest built the static portable release at commit `b20bfd4` with Python 3.13.5 and Node 22.16.0. The test used an empty SQLite database and Chromium 159. The workstation launcher built the static export and TypeScript passed. A separate test extracted the release ZIP to a new directory with spaces, removed Node from the executable search path, started the packaged launcher, fetched the interface and saved an interview to disk. The combined backend and acceptance run passed 101 tests. The independent acceptance tests use the production FastAPI routes and a new database for each scenario.

| Check | Evidence |
| --- | --- |
| Start and review an interview | Chromium required candidate notice, imported a WebVTT exchange with an explicit speaker selection, compared both passages, saved the explanation and reopened the record. |
| Interpret shared words | Seven HTTP scenarios cover direct copying, a question echo, two sources sharing the same language, permitted text, a short answer, absent references and independent wording. Repeating the same create request produced one session. |
| Use captured audio | Chromium encoded bytes from a synthetic microphone. A second case supplied a stream with video and audio at the output of the display picker. Only the audio track entered MediaRecorder. The app retained the final transcript after clicking Stop and after ending the shared video and audio tracks together. A scripted socket supplied the words. Saving stayed disabled until the operator applied the excerpt. |
| Migrate records | The tests used the upstream schema and a native role file. They verified source preservation, original notes and scores, retry behavior and rollback. The browser previewed a role, imported it and detected a duplicate. An archived interview with no notice offered no capture controls. |
| Export | Chromium downloaded Markdown and archive CSV, opened the print view, and rendered a PDF. The exported evidence and note matched the saved record. |
| Prepare from an ATS file | Chromium read a quoted CSV candidate name into setup. The notice box stayed clear. |
| Author roles and export a private note | The browser requested a synthetic question draft, then saved it in the role library. It previewed a private note and required fresh confirmation after editing the text. The local provider stub received the expected recipient and text exactly once. |
| Use account access | The portable service ran against the original Node account service with a second temporary database. Signup, trial entitlement, checkout refusal with billing unconfigured, logout, access denial and login passed. |
| Display the workspace | Desktop and mobile screenshots at widths of 1440 and 390 pixels showed all navigation and evidence controls within the viewport. |

The native comparison used upstream commit `3c03f17`. A synthetic answer about measuring delays on a conveyor started ten seconds after the question. Each word lasted 0.30 seconds, with 0.08 seconds between words. The native scorer assigned 94 percent with low confidence when both the reference and model review were absent. The portable comparison returns limited evidence for an answer without a reference.

## Run acceptance

Use Python 3.13 and Node 22.13 or newer. The two commands in the server directory prepare the original Node service for its compatibility test. Install the Python test dependencies in a separate environment.

~~~sh
npm ci --prefix server --ignore-scripts
npm run build --prefix server
cd portable
python run.py --build-only
python -m pip install -r qa/requirements.txt
python -m playwright install chromium
python qa/smoke_next.py
python -m pytest tests -q
python -m pytest qa -q --frontend=start
python -m pytest qa/test_session_lifecycle.py qa/test_capture.py qa/test_webhook_transport.py qa/test_connected_ui.py::test_admin_grants_access_through_account_page -q --frontend=dev
python -m pytest qa/test_browser.py -q --frontend=static
python package_release.py ../build/InterviewCheck-portable.zip
python qa/smoke_archive.py ../build/InterviewCheck-portable.zip
~~~

On a minimal Linux installation use `python -m playwright install --with-deps chromium`. In Windows PowerShell, `py -3.13` can select Python. The workflow in `.github/workflows/portable.yml` performs these checks on Ubuntu and Windows x64 and attaches the tested ZIP to each successful job. No Windows runner was available in this local session. Its first CI run is pending.

The Linux tests cover browser media APIs with synthetic tracks. The operating system source picker, real call audio and live vendor credentials still require platform acceptance. The provider tests use fixtures. The account test stops before Stripe checkout. Detection accuracy requires independently labeled interviews and a representative sample. The synthetic cases establish behavior under their stated inputs.
