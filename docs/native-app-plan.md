# Native Mac app plan (loop, Nov 7 20:05 → about Nov 8 04:05)

Goal: InterviewCheck behaves like a proper Mac app, not a Cluely-style overlay.
Rules: commit after each verified step; run tests only through the crash watchdog
(`scratchpad/run-some-tests.sh` / `run-tests-guarded.sh`); never hide windows from
screen sharing; no global shortcut may steal common keys (Cmd+D, Cmd+E, Cmd+/ ...).

Status key: [ ] todo · [~] in progress · [x] done (commit)

## A. Native app shell
- [ ] A1 SwiftUI `WindowGroup` main window: title bar with close/minimize/zoom,
      movable, resizable (min 900x600), remembers size; `NavigationSplitView`
      sidebar: Interview, Roles, Reports. Overlay panel and startup badge no
      longer created. Closing the window keeps the app running; Dock click reopens.
- [ ] A2 Global shortcuts cut to the interview actions only (Question asked,
      Answer done), off until the interviewer turns them on; no Accessibility
      prompt at launch. Old candidate hotkeys (Cmd+D, Cmd+E quit, Cmd+/ ...) gone.
- [ ] A3 Menu bar: File > New Interview (Cmd+N), New Role; Interview > Start, Question
      Asked (Cmd+Return), Answer Done (Cmd+Shift+Return... in-app), End; Report export.
- [ ] A4 Native views (system look): Interview setup/live/ended, Roles list +
      detail (job description, Draft, questions, prompts), Reports table + detail.
- [ ] A5 Native Settings scene (Cmd+,): Keys, Detector, Shortcuts, License/Account, About.
- [ ] A6 Live Companion: optional small always-on-top window (normal title bar,
      closable) showing the current question and score while the call is in front.
- [ ] A7 App icon + accent colour; install to ~/Applications/InterviewCheck.app.
- [ ] A8 Permissions asked when starting an interview (mic, screen audio), with
      an explanation screen; nothing at launch.

## B. Scalable structure
- [ ] B1 Rename target/module memanager → InterviewCheck (folders, imports, scripts).
- [ ] B2 `Packages/InterviewCheckKit`: detector core (models, timing, scoring) as a
      Swift package with `swift test` (fast, no app host, no crash dialogs).
- [ ] B3 Remove candidate-only code: Quick Assist/Solve/Design/ML guide, Practice,
      Knowledge, Modes, teleprompter, coach nudges, voice signature + Eagle SDK,
      overlay window + glass/Metal shaders (drops the Metal toolchain need).
- [ ] B4 README + ARCHITECTURE docs; one `scripts/ci.sh`.

## C. Verify every step
- build; guarded tests; render native screens light/dark; launch the installed app,
  confirm it stays up, no new crash report, window screenshot.

## Log
- 20:05 plan written.
