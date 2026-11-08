# Architecture

```
Packages/InterviewCheckKit/   pure detector core (Swift package, `swift test`)
Packages/InterviewCheckConnectors/
                              ATS, unified HR APIs, calendars, mail (IMAP),
                              booking links, meeting tools, MCP: one set of
                              types (`swift test`, stub HTTP, scripted IMAP)
InterviewCheck/               the Mac app
  App/                        @main App scenes, AppDelegate, AppBrand
  AppShell/                   root view, sidebar, menus, shortcuts, permissions
  Features/                   SwiftUI screens: Interview, Roles, Reports,
                              Companion, Settings, Access (sign in / subscribe),
                              Demo, Recording
  Connectors/                 ConnectorManager (accounts, sync, Prepare,
                              recordings, notes), Connections screen,
                              reminders, automatic Prepare, auto-scoring,
                              Shortcuts/Dock/URL actions
  Detector/                   app-side detector: live controller, timeline,
                              roles, AI clients and prompts, reports
  Services/                   audio capture and transcription (Deepgram, Apple)
  Database/                   SQLite store, schema and migrations
  AI/                         HTTP streaming, wire models, and the original
                              candidate-copilot prompt used to imitate cheating tools
  Access/                     accounts, subscriptions, owner license
  Utilities/, Shared/         settings, Keychain, small shared types
InterviewCheckTests/          app tests (hosted XCTest)
server/                       access server: accounts, Stripe, admin (Node 22)
scripts/                      build, test, deploy, CI, asset generation
```

## How an answer gets its score

```
mic ─┐                       ┌─ interviewer words ─┐
     ├─ DualStreamDeepgram ──┤                      ├─ InterviewTimeline (one clock)
call ┘   (StreamClock maps   └─ candidate words ───┘          │
          offsets to host time)                    QuestionTracker (question / answer)
                                                              │
  ReferenceAnswerRunner ── AI answers (lineup × cheater prompts, in parallel)
                                                              │
  TimingSignal · FluencySignal · SimilaritySignal · JudgeSignal → CheatScorer
                                                              │
                         AnswerScore (0–95%, confidence, reasons, follow-ups)
```

- **InterviewCheckKit** holds everything that can be computed from words,
  times and texts: `TimedWord`, `StreamClock`, `QuestionTracker`, the four
  signals, `CheatScorer` and `CheatScoreWeights` (all tunable numbers in one
  place). It has no dependency on the app, UI or network.
- **InterviewController** (main actor) runs an interview: start and end,
  question marks, live scoring every few seconds, final scoring after the AI
  answers, embeddings and the AI review arrive, and saving.
- **InterviewTimeline** receives Deepgram's final words, already on the host
  clock, from `DualStreamDeepgramService.onFinalTimedWords`.
- **ReferenceAnswerRunner** pairs providers with cheater prompts (a Latin
  square so a capped list still covers every provider and prompt) and streams
  them concurrently.
- **Storage**: `interviews`, `interview_words`, `interview_questions`,
  `reference_answers`, `answer_scores`, `role_profiles` (v17), `answer_labels`
  (v18), `answer_notes` (v19), interrupted flag (v20), `external_interviews`,
  `external_recordings` and `interviews.external_ref` (v21), `scored_from` and
  `external_links` (v22).
  Older tables from the original app remain in the schema so existing
  databases migrate cleanly.

## Connectors

```
EventKit / .ics / Google / Microsoft       ─┐                  ┌─ Upcoming Interviews (Prepare, Join)
Mail (IMAP) / Calendly · Cal.com            ─┤                  ├─ AutoPrepare at reminder time
Zoom · Webex (recordings, transcripts)      ─┼─ ConnectorManager ┼─ reminders · Dock · Shortcuts
ATS (12 direct) / Merge · Kombo · Unified.to ─┤  (sync every 15m,  ├─ Analyze Recording / AutoScorer
MCP (Greenhouse · Ashby · Workable · any)   ─┘  cache in SQLite) └─ Send Summary (NoteDestination)
```

- Every connector maps its API onto the same types (`ExternalInterview`,
  `ExternalCandidate`, `ExternalJob`, `ExternalRecording`) through small
  protocols: `InterviewSource`, `JobSource`, `CandidateSource`,
  `RecordingSource`, `NoteDestination`, `CandidateLookup`. Adding a system is
  one file plus a catalog entry and a factory line.
- `APIClient` handles auth headers, Retry-After, errors and Link paging;
  `JSONValue` reads vendors' JSON without a struct per endpoint. Files are
  downloaded with the API's headers only when they need them (`needsAuth`).
- `SyncNotes` is a task-local collector: a connector that stops at a page
  limit says so, and the account shows it without counting as a failure.
- Mail is read over IMAP (`IMAPSession` on a Network.framework TLS stream):
  EXAMINE and BODY.PEEK only, calendar parts only.
- Sign-in: API keys and client-credentials tokens; OAuth 2.0 public clients
  with PKCE and a loopback redirect (`LoopbackReceiver`); MCP sign-in with
  discovery, dynamic client registration and the RFC 8707 resource.
  Credentials live in the Keychain (`KeychainCredentialStore`).
- Prepare fills the interview from the source; a calendar invite is matched
  to an ATS candidate by email (`CandidateLookup`) for the job description,
  résumé and the note target.
- Built from the vendors' published documentation (Nov 2026); not yet run
  against live accounts.

## Conventions

- Files stay under 400 lines (`scripts/check-source-size.py`).
- Windows are never hidden from screen sharing.
- System-wide shortcuts are Carbon hot keys, registered only while an
  interview is live.
- A score never claims certainty: shown scores stop at 95%.
