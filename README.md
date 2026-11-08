# InterviewCheck

A Mac app for interviewers that helps spot candidates who read their answers
from AI tools (Cluely, Interview Coder, ChatGPT on a second screen).

During a video interview the interviewer asks a question and presses
**Question Asked** (⇧⌘↩, works while Zoom, Meet or Teams is in front).
InterviewCheck then:

1. asks several AI models, with prompts that imitate real cheating tools, what
   they would tell a candidate to say;
2. times the candidate's answer word by word: the "Cluely pause" (silence or
   stalling, then a sudden fluent answer), fillers, restarts, pace;
3. compares the answer with the AI answers (shared phrasing, meaning);
4. shows a score from 0 to 95% with the reasons and two follow-up questions.

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
4. Press **Question Asked** after each question and **Answer Done** (⇧⌘E)
   when the candidate finishes. **Window › Live Companion** keeps a small
   window above the call.
5. **Reports**: every interview, each answer and its evidence, your verdict
   and notes; export Markdown or PDF, or every interview as one CSV.
6. **File › Analyze Recording** (⌘O): score a recorded interview (audio or
   video). Pick the candidate's voice; questions are found automatically.
7. **Help › Demo Interview**: watch a scripted three-question interview run
   through the real live screen and scorer. Needs no keys, microphone or
   network; nothing is saved to your interviews.

### Connections (⌘4)

Connect the systems interviews already live in, so the app does the setup:

- **Calendar on this Mac** (no keys) and **.ics invites**; **Google Workspace**
  (Calendar, Meet transcripts), **Microsoft 365** (Outlook, Teams transcripts),
  **Zoom** (meetings, cloud recordings). Browser sign-in, no client secret.
- **Applicant tracking**: Greenhouse (Harvest v3), Lever, Ashby, Workable,
  SmartRecruiters, Recruitee, Zoho Recruit, Teamtailor, BambooHR, JazzHR,
  Breezy HR, Personio; **Workday, iCIMS, SuccessFactors, Taleo, Jobvite** and
  the long tail through **Merge, Kombo, Unified.to** (or Apideck for jobs).
- **MCP**: sign in as yourself to Greenhouse's, Ashby's or Workable's official
  MCP servers, or any MCP server.

Then: **Interview › Upcoming Interviews** lists the next interviews with
**Join** and **Prepare** (candidate, role with the job description, résumé; a
calendar invite is matched to the ATS candidate by email); a reminder arrives
before each one; **File › Analyze Recording** offers recent Zoom, Teams and
Meet recordings; a report prepared from an ATS has **Send to <ATS>** (an
editable private note, sent only when you press Send). Shortcuts has **Prepare Next Interview**, **Sync Interview Connections** and **Open Latest
Interview Report**; the Dock icon's menu lists the next interviews; links
`interviewcheck://prepare-next`, `interviewcheck://sync` and `interviewcheck://report/latest`
work from anywhere. Keys stay in the
Keychain; synced data stays on this Mac. Connector code and tests live in
`Packages/InterviewCheckConnectors` (`swift test`). Setup steps for every system: [docs/CONNECTORS.md](docs/CONNECTORS.md).

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
