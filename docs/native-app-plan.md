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
- [ ] D9 Remove dead audio code (legacy unified stream, voice-ID leftovers).
- [ ] D10 Report feedback: "this score was wrong" to calibrate weights locally.

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
