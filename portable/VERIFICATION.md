# Portable edition acceptance

On November 18, 2026, a clean Debian 13 ARM64 guest built the product with Python 3.13.5 and Node 22.16.0. The test used an empty SQLite database and Chromium 159. The workstation launcher built the static export and TypeScript passed. A separate test extracted the release ZIP to a new directory with spaces, removed Node from the executable search path, started the packaged launcher, fetched the interface and saved an interview to disk. The combined backend and acceptance run passed 101 tests. The independent acceptance tests use the production FastAPI routes and a new database for each scenario.

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

Use Python 3.13 and Node 22.13 or newer. From the repository root, build the account service and the browser app, then run the tests in a separate Python environment.

~~~sh
npm ci --prefix server --ignore-scripts
npm run build --prefix server
cd portable
python run.py --build-only
python -m pip install -r qa/requirements.txt
python -m playwright install chromium
python -m pytest tests qa -q
python package_release.py ../build/InterviewCheck-portable.zip
python qa/smoke_archive.py ../build/InterviewCheck-portable.zip
~~~

On a minimal Linux installation use `python -m playwright install --with-deps chromium`. In Windows PowerShell, `py -3.13` can select Python. The workflow in `.github/workflows/portable.yml` performs these checks on Ubuntu and Windows x64 and attaches the tested ZIP to each successful job. No Windows runner was available in this local session. Its first CI run is pending.

The Linux tests cover browser media APIs with synthetic tracks. The operating system source picker, real call audio and live vendor credentials still require platform acceptance. The provider tests use fixtures. The account test stops before Stripe checkout. Detection accuracy requires independently labeled interviews and a representative sample. The synthetic cases establish behavior under their stated inputs.
