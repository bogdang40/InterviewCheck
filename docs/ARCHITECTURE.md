# Architecture

```
Packages/InterviewCheckKit/   pure detector core (Swift package, `swift test`)
InterviewCheck/               the Mac app
  App/                        @main App scenes, AppDelegate, AppBrand
  AppShell/                   root view, sidebar, menus, shortcuts, permissions
  Features/                   SwiftUI screens: Interview, Roles, Reports,
                              Companion, Settings, Access (sign in / subscribe)
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
  `reference_answers`, `answer_scores`, `role_profiles` (migration v17).
  Older tables from the original app remain in the schema so existing
  databases migrate cleanly.

## Conventions

- Files stay under 400 lines (`scripts/check-source-size.py`).
- Windows are never hidden from screen sharing.
- System-wide shortcuts are Carbon hot keys, registered only while an
  interview is live.
- A score never claims certainty: shown scores stop at 95%.
