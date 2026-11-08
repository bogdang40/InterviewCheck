# Native Mac app plan (loop, Nov 7 20:05 → about Nov 8 04:05)

Goal: InterviewCheck behaves like a proper Mac app, not a Cluely-style overlay.
Rules: commit after each verified step; run tests only through the crash watchdog
(`scratchpad/run-some-tests.sh` / `run-tests-guarded.sh`); never hide windows from
screen sharing; no global shortcut may steal common keys (Cmd+D, Cmd+E, Cmd+/ ...).

Status key: [ ] todo · [~] in progress · [x] done (commit)

## A. Native app shell
- [x] A1 SwiftUI `WindowGroup` main window: title bar with close/minimize/zoom,
      movable, resizable (min 900x600), remembers size; `NavigationSplitView`
      sidebar: Interview, Roles, Reports. Overlay panel and startup badge no
      longer created. Closing the window keeps the app running; Dock click reopens.
- [x] A2 Global shortcuts cut to the interview actions only (Question asked,
      Answer done), off until the interviewer turns them on; no Accessibility
      prompt at launch. Old candidate hotkeys (Cmd+D, Cmd+E quit, Cmd+/ ...) gone.
- [x] A3 Menu bar: File > New Interview (Cmd+N), New Role; Interview > Start, Question
      Asked (Cmd+Return), Answer Done (Cmd+Shift+Return... in-app), End; Report export.
- [x] A4 Native views (system look): Interview setup/live/ended, Roles list +
      detail (job description, Draft, questions, prompts), Reports table + detail.
- [x] A5 Native Settings scene (Cmd+,): Keys, Detector, Shortcuts, License/Account, About.
- [x] A6 Live Companion: optional small always-on-top window (normal title bar,
      closable) showing the current question and score while the call is in front.
- [x] A7 App icon + accent colour; install to ~/Applications/InterviewCheck.app.
- [x] A8 Permissions asked when starting an interview (mic, screen audio), with
      an explanation screen; nothing at launch.

## B. Scalable structure
- [x] B1 Rename target/module InterviewCheck → InterviewCheck (folders, imports, scripts).
- [x] B2 `Packages/InterviewCheckKit`: detector core (models, timing, scoring) as a
      Swift package with `swift test` (fast, no app host, no crash dialogs).
- [x] B3 Remove candidate-only code: Quick Assist/Solve/Design/ML guide, Practice,
      Knowledge, Modes, teleprompter, coach nudges, voice signature + Eagle SDK,
      overlay window + glass/Metal shaders (drops the Metal toolchain need).
- [x] B4 README + ARCHITECTURE docs; one `scripts/ci.sh`.

## D. Polish and product (added during the loop)
- [x] D1 Live audio status strip (mic / call audio / clock), also in the companion.
- [x] D2 Paginated PDF reports built from formatted text.
- [x] D3 Menu bar item while an interview is live.
- [x] D4 First-launch welcome (Help › Welcome).
- [x] D5 Release install, hardened runtime, `package-dmg.sh`.
- [x] D6 Analyze Recording (File › Analyze Recording, ⌘O).
- [x] D7 Privacy: keep interviews N days, delete all data, what is stored where.
- [x] D8 Audio settings: choose the microphone, test both sides before an interview.
- [~] D9 Remove dead audio code (legacy unified stream, voice-ID leftovers). DEFERRED: 142 references
      through the capture state machine; needs a live-call test after the change.
- [x] D10 Report feedback: "this score was wrong" to calibrate weights locally.
- [x] D11 Demo Interview (Help › Demo Interview, `-InterviewCheckOpenDemo YES`): a scripted
      three-question interview through the real live screen and scorer; no keys, mic or network.
- [x] D12 Your notes per answer (live and in reports, saved as you type, schema v19), the timing
      strip rebuilt in reports from saved word timings, verdict + notes in Markdown/PDF, and
      Export › All Interviews as CSV (formula cells defused).
- [x] D13 Crash recovery: an interview left open is finished and scored at the next launch,
      marked "ended unexpectedly" in the report and exports.
- [x] D14 Mac conventions: one main window (re-opening brings it forward, no copies), View ›
      Interview/Roles/Reports ⌘1–⌘3, Show/Hide Sidebar, File › Print Report ⌘P, "Live" Dock badge.
- [x] D15 Documents in: job description and résumé from PDF, Word (.docx/.doc), RTF, ODT or text.
      Roles: Duplicate, Export… and File › Import Role… (JSON, always imported as a new role).

## C. Verify every step
- build; guarded tests; render native screens light/dark; launch the installed app,
  confirm it stays up, no new crash report, window screenshot.

## Log (times from commits)
- 20:05 plan written.
- 20:16 6da0258 A1–A6: native window + sidebar, menus, Settings, companion, Carbon shortcuts
  only while live, native screens. Launched from ~/Applications: real window, no crash.
- 20:20 65814e8 A7: app icon, accent colour, `-InterviewCheckStartSection`.
- 20:22 d855c55 A8: permissions asked at Start (Deepgram key, mic, call audio).
- 20:30 4727ff8 B3 round 1: overlay UI, candidate services/DAOs/providers removed;
  ~1,260 -> ~200 Swift files; 310 tests pass in 5 s.
- 20:34 5ff2b7f B3 round 2: Eagle voice ID + dylib + model + library-validation
  exception, welcome frames, Mermaid removed. App 49 MB -> 10 MB.
- 20:36 f77cb14 B1: memanager -> InterviewCheck everywhere.
- 20:42 B2: Packages/InterviewCheckKit (core, 34 tests via `swift test` in 0.03 s);
  app 247 tests pass. B4: README, ARCHITECTURE, scripts/ci.sh.
- 20:46–21:00 D1–D6 (commits 2b?..07d691e): status strip, paginated PDF, menu bar item,
  welcome, Release + DMG + hardened runtime, Analyze Recording. 263 app + 38 package tests.
- 21:01–21:13 D7 privacy (810551e), D8 audio settings (c337c94), D10 calibration (verdicts + tuner,
  schema v18). D9 deferred. 268 app + 41 package tests.
- 21:16 D11 demo interview (honest answer low, read-from-AI answer high). 270 app tests.
- 21:22 D12 notes, report timing strip, CSV export. 272 app + 42 package tests.
- 21:28 demo: one card per prompt style (Copilot / Talking points / STAR), bullets keep line breaks, demo + companion windows not restored at launch, Welcome › Watch a Demo Interview. 273 app tests.
- 21:31 D13 crash recovery: interviews left open by a quit/crash are closed, scored offline (low confidence) and marked interrupted at next launch (schema v20).
- 21:37 D14: fixed File/View commands opening a second main window (WindowGroup → Window); ⌘1–3, ⌘P, Dock badge, sidebar commands. Checked in the installed app via System Events.
- 21:43 D15 documents in (DocumentText replaces the candidate-app extractor), role duplicate/export/import. 278 app tests.
