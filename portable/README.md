# InterviewCheck portable edition

This directory contains the web frontend, Python API and an optional distribution for a single workstation. To start the Next.js and FastAPI development servers from the repository root, run `npm run dev` and open [InterviewCheck](http://localhost:3000). See the [web runtime guide](WEB.md). In the packaged edition, the browser loads a local production build of Next.js. FastAPI stores the interview in SQLite. The sample review and manual interview workflow work without vendor accounts.

## Start from the distribution

Extract the entire InterviewCheck folder to a writable location. Install Python 3.11 or newer. The first start installs Python dependencies and requires internet access. The packaged interface is already built.

| System | Start in the extracted folder |
| --- | --- |
| Windows | Open `Start InterviewCheck.cmd` or run `py -3 run.py` in PowerShell |
| Linux | Run `python3 run.py`. Install the Python venv package if the distribution packages it separately. |

Open [the workspace](http://127.0.0.1:8765). Leave the terminal open while using it. Ctrl+C stops the service. To use another local port, pass `--port 8766`. Start in the same extracted folder to reopen your interviews.

## Build the optional distribution from source

Install Node.js 22.13 or later with npm and Python 3.11 or later. Run the Windows or Linux command above from the repository's `portable` directory. The launcher builds the Next.js export, checks changes to its inputs at each start and serves it from FastAPI. Use `--build-only` for a build without a server. The API and interface share one origin.

## Review an interview

1. Open **Open sample** to compare a fictional answer. Mark the reference as permitted and inspect the change. The sample does not enter the session log.
2. Select **New interview**. Enter a candidate name or alias, a role and the agreed assistance policy. Confirm the notice. Add a question and answer by typing, selecting a speaker and exchange from WebVTT, or using a configured transcription provider.
3. Add named sources. Mark permitted sources explicitly. The comparison uses these designations. A free text description of the policy cannot classify a source automatically.
4. Open **Live comparison** to preview the current exchange. Select **Save and compare** to keep it. For a passage match, inspect the candidate and source text. Ask the suggested follow up and save the candidate's explanation under the review outcome. If the candidate discloses assistance, select that outcome and record what they said. **Limited evidence** means a comparison could not establish overlap. **No passage match** refers only to the supplied sources.
5. Use **Ask this follow up** to start another exchange. Select **Finish interview** when capture is complete. You can still review evidence and save notes. Select **Reopen interview** to resume capture. Export a Markdown report, print to PDF or export the archive as CSV. The role library accepts native role exports. The migration command imports a snapshot of the native Mac database and retains original scores and notes.

## Data and services

This is a single operator workstation. Its default address is loopback. The local SQLite database lives in `portable/data/review.sqlite3` in the checkout or `data/review.sqlite3` inside the distribution. Set `INTERVIEWCHECK_DB` to choose another path. Use a SQLite backup or stop the service before copying the entire data directory. Local data is plaintext under the operating system account. The web interface does not display or store provider keys.

Optional generation uses the selected provider's configured model. Set one group of environment variables before starting the server. Generation sends the role and question, or the role and job description for drafting. The resulting reference and questions remain editable. The operator controls each request.

| Provider | Environment variables |
| --- | --- |
| OpenAI | `OPENAI_API_KEY`, `INTERVIEWCHECK_REFERENCE_MODEL` |
| Anthropic | `ANTHROPIC_API_KEY`, `INTERVIEWCHECK_ANTHROPIC_MODEL` |
| Azure OpenAI | `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_DEPLOYMENT`, `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_API_VERSION` |

See [connection setup and limits](CONNECTIONS.md) for live audio, calendars, ATS and account services. FastAPI can serve accounts and Stripe billing directly. The original access service is also supported for existing deployments.

## Native migration coverage

| Area | Portable implementation |
| --- | --- |
| Capture and review | Shared call audio when the browser offers it, microphone, recording import, named WebVTT speakers, typed answers, source excerpts, manual review and reports |
| Roles and past reports | Role library, question planning and optional provider drafting, native role file import, SQLite snapshot migration, historical native scores and notes |
| Integrations and access | Calendar and ATS preparation, recording providers, account sign in and billing paths. The connection guide lists the operation supported by each adapter. |
| Desktop specific facilities | Native menu bar, global shortcuts, EventKit, Keychain, hardware bound owner licenses and background OS automation remain features of the Mac application. Use the browser controls and configured service credentials in this edition. |
| Scoring | The portable detector compares observable passages. It does not assign a probability of cheating to timing, fluency or a model opinion. The native percentage is retained as historical data on import. |

See [evidence and migration details](CORE.md) and the [verification record](VERIFICATION.md). External services require appropriate credentials and consent. Tests with provider fixtures do not establish live account compatibility. No real interview corpus has established an accuracy rate.

## Developer checks

From this directory, install `requirements-dev.txt` in the virtual environment. Run `python -m pytest tests` and `python evaluate.py` using that environment. From `web`, run `npm ci`, `npm run build` and `npm run typecheck`. The browser tests, including the Linux and Windows matrix, are in `qa` and `.github/workflows/portable.yml`.

To package the application, build the frontend and run `python package_release.py ../build/InterviewCheck-portable.zip` from this directory. The archive contains the exported UI, FastAPI code and setup instructions. Interview records, credentials and virtual environments are excluded.
