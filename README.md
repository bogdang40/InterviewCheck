# InterviewCheck

InterviewCheck is a Next.js and FastAPI web application for reviewing interview answers. Capture an exchange, compare its wording with named sources, ask a follow up and record the candidate's explanation. The browser uses shadcn/ui and Tailwind CSS v4 with zero heavy 3D or animation runtime dependencies. FastAPI owns the review service, SQLite storage, provider integrations and optional accounts and billing.

## Run the web app

Install Node.js 22.13 or later, npm, and Python 3.11 or later. From the repository root run:

```sh
npm run dev
```

Open [InterviewCheck](http://localhost:3000). FastAPI serves the [API documentation](http://127.0.0.1:8000/docs). The launcher installs the project dependencies on first use. To run the production build:

```sh
npm run build
npm start
```

The sample review and the manual interview workflow run without provider keys. Start an interview with a saved role or your own role title, record the agreed resources, and add answers. Finish capture when the interview ends. Review notes and report exports remain available after capture ends.

See the [web runtime guide](portable/WEB.md), [connection guide](portable/CONNECTIONS.md), and [review and migration guide](portable/CORE.md). An optional [downloadable edition](portable/README.md) serves the built browser interface from FastAPI. The [implementation plan](PLAN.md) records the original detector findings.

## Interview workbench

Open the review queue to go directly to an exchange with a pending passage match. During capture, a saved draft survives a restart. Import a WebVTT conversation in one transaction, or play a corresponding local recording at its source interval. The role policy and permitted materials are frozen when the interview starts.

Open **Compare candidates** at `/interviews/compare/` to select two to six interviews from the archive. The comparison shows the saved questions for each interview. You can include saved ratings and choose whether to include reviewer rationales before printing or downloading the comparison. Interviews in Trash are excluded.

Open `/admin/` and select **Models** to connect providers and configure prices and spend thresholds. **Usage** shows the cost log and controls the monthly attempt allowance. **Playground** includes a scripted rehearsal of the saved review rules. The console also manages accounts, audit records, diagnostics, alerts, prompts, access controls and retention policies.

Use the review brief to preview exactly what a reader will receive. Its default omits identifying fields, transcript excerpts and notes. Full reports remain available. Workspace data supports a versioned JSON backup, restore previews and a separate Trash view. The account screen contains the browser appearance preference.

Run the production readiness aggregator from the repository root (`--with-bundle` after `npm run export` validates the `< 600 KiB` static bundle budget and secret/dependency hygiene):

```sh
PYTHONPATH=portable portable/.venv/bin/python scripts/run_production_audit.py --with-dr --json
```

[Reviewed release plan](portable/WORKSPACE-ROADMAP.md) · [Workflow verification](portable/VERIFICATION.md)

## Original macOS application

A Mac app for interviewers that helps spot candidates who read their answers
from AI tools (Cluely, Interview Coder, ChatGPT on a second screen).

During a video interview the interviewer asks a question and presses
**Question Asked** (⇧⌘↩, works while Zoom, Meet or Teams is in front).
InterviewCheck then:

1. asks several AI models, with prompts that imitate real cheating tools, what
   they would tell a candidate to say;
2. times the candidate's answer word by word: the "Cluely pause" (silence or
   stalling, then a sudden fluent answer), fillers, restarts, pace;
3. compares the answer with the AI answers and **highlights every run of four
   or more words said in the same order**, like a plagiarism checker ("99 of
   104 words appear word for word in an AI answer");
4. notices **model wording read aloud** ("furthermore", "it's worth noting",
   spoken STAR labels) and **a change from the candidate's own other answers**
   (much later start, far fewer hesitations), both without any AI key;
5. shows a score from 0 to 95% with the reasons and follow-up questions; without
   the AI review, follow-ups are made from the candidate's own words ("You
   mentioned “token bucket algorithm”. Walk me through how that works.").

After the call the summary leads with how many answers were flagged and what
stood out; the report and PDF open with the same summary.

A score is a signal to follow up on, never proof. The candidate is told the
interview is transcribed and checked before it starts (the app requires the
interviewer to confirm this).

## Using it

1. **Settings › Keys**: add a Deepgram key (transcription with word timings)
   and a Claude and/or OpenAI key (AI answers, review, drafting).
2. **Roles**: create a role, paste the job description (or import a PDF or
   Word file), press **Draft Questions and Prompts**. Share a role with other
   interviewers with **Export…** and **File › Import Role…**.
3. **Interview**: choose the role, type the candidate's name, optionally add
   their resume, confirm the notice, **Start Interview**.
4. Press **Question Asked** after each question (or turn on Settings › Detector ›
   *Mark questions automatically* (beta) for the ones you forget) and **Answer Done** (⇧⌘E)
   when the candidate finishes. **Window › Live Companion** keeps a small
   window above the call.
5. **Reports**: every interview, each answer and its evidence, your verdict
   and notes; export Markdown or PDF, or every interview as one CSV.
6. **File › Analyze Recording** (⌘O): score a recorded interview (audio or
   video). Pick the candidate's voice; questions are found automatically.
7. **Help › Demo Interview** (also on the welcome sheet and the New Interview
   screen): watch a scripted 90-second, three-question interview run through
   the real live screen and scorer, ending on its report. Needs no keys,
   microphone or network; nothing is saved to your interviews.

### Connections (⌘4)

Connect the systems interviews already live in, so the app does the setup:

- **Calendars**: Calendar on this Mac (no keys), .ics invites, **Google Workspace**
  (Calendar and team calendars, Meet transcripts), **Microsoft 365** (Outlook and
  team calendars, Teams transcripts and recordings).
- **Mail**: any mailbox over IMAP with an app password (Gmail, iCloud, Yahoo,
  Fastmail, Zoho, company servers); read-only, follows updates and cancellations.
- **Booking links**: **Calendly** and **Cal.com** (screens booked through a link).
- **Meeting recordings**: **Zoom** and **Webex** (meetings, recordings,
  transcripts), plus Teams and Meet transcripts above.
- **Applicant tracking**: Greenhouse (Harvest v3), Lever, Ashby, Workable,
  SmartRecruiters, Recruitee, Zoho Recruit, Teamtailor, BambooHR, JazzHR,
  Breezy HR, Personio, and for staffing agencies **Bullhorn** and **JobAdder**;
  **Workday, iCIMS, SuccessFactors, Taleo, Jobvite** and the long tail through
  **Merge, Kombo, Unified.to** (or Apideck for jobs).
- **MCP**: sign in as yourself to Greenhouse's, Ashby's or Workable's official
  MCP servers, or any MCP server.

Then: **Interview › Upcoming Interviews** lists the next interviews with
**Join** and **Prepare** (candidate, role with the job description, résumé; a
calendar, mail or booking interview is matched to the ATS candidate by email).
**Connections › Automation**: the next interview is made ready by itself at
reminder time (never started, consent never ticked, typed setup never
replaced), the meeting can open when it starts (off by default), and new
recordings of scheduled interviews can be scored in the background (off by
default). **Settings › Privacy** can save a PDF of every finished report to a
folder. **File › Analyze Recording** offers recent Zoom, Webex, Teams and Meet
recordings; a report prepared from an ATS that keeps private notes has
**Send to <ATS>** (an editable note, sent only when you press Send). Shortcuts
has **Prepare Next Interview**, **Join Next Interview**, **Sync Interview Connections**
and **Open Latest Interview Report**; the Dock icon's menu lists the next interviews; links
`interviewcheck://prepare-next`, `interviewcheck://join-next`, `interviewcheck://sync` and `interviewcheck://report/latest`
work from anywhere. Keys stay in the Keychain; synced data stays on this Mac.
Connector code and tests live in `Packages/InterviewCheckConnectors`
(`swift test`). Setup steps for every system: [docs/CONNECTORS.md](docs/CONNECTORS.md).

Keyboard: ⌘1 Interview, ⌘2 Roles, ⌘3 Reports, ⌘4 Connections, ⌘N new interview, ⇧⌘N new
role, ⌘O analyze a recording, ⌘R start, ⇧⌘↩ question asked, ⇧⌘E answer done,
⌘P print the open report, ⌥⌘L Live Companion, ⌘, Settings.

The first interview asks for the microphone (your questions) and for Screen
& System Audio Recording (the candidate's side of the call).

## Building

Requirements: macOS 14+, Xcode 16+ (tested with Xcode 27), `xcodegen`
(`brew install xcodegen`).

```sh
./scripts/build-debug.sh      # builds and installs ~/Applications/InterviewCheck.app
./scripts/build-release.sh    # optimised build, same install location
./scripts/ci.sh               # everything: size rule, package tests, app tests, server
```

Without `INTERVIEWCHECK_DEVELOPMENT_TEAM` the app is signed ad hoc; macOS then
asks for permissions again after each rebuild. Set it to your Apple team ID to
keep permissions between builds.

## Packaging for other Macs

```sh
./scripts/build-release.sh && ./scripts/package-dmg.sh   # build/InterviewCheck-<version>.dmg
```

Release builds use the hardened runtime. To install on Macs other than the
build machine without Gatekeeper warnings, sign with a Developer ID
Application certificate (`INTERVIEWCHECK_DEVELOPMENT_TEAM` plus a Developer ID
identity) and notarize the disk image:

```sh
xcrun notarytool submit build/InterviewCheck-1.0.0.dmg --keychain-profile <profile> --wait
xcrun stapler staple build/InterviewCheck-1.0.0.dmg
```

Companies deploying through MDM can pre-approve the microphone with
`InterviewCheck-permissions.mobileconfig`.

## Licensing and accounts

The app unlocks with an account on the access server (`server/`, Node 22,
Stripe subscriptions) or with an owner license file tied to one Mac:

```sh
cd server && npm ci --ignore-scripts
npm run owner-license -- keygen                       # once; key in ~/.interviewcheck
npm run owner-license -- issue --email you@example.com --device auto
```

Paste the printed public key into
`InterviewCheck/Access/Services/OwnerLicensePublicKey.swift` after `keygen`.

## Layout

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
