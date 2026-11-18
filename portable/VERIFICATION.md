# Portable edition acceptance

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
