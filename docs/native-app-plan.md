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
- 20:16 A1–A6: native WindowGroup + sidebar, menus, Settings scene, companion, Carbon
  shortcuts only while live, native screens. Launched from ~/Applications: real window
  with traffic lights, no crash. Commit 6da0258.
- 20:22 A7: generated app icon (shield + check), AccentColor, `-InterviewCheckStartSection`
  launch option for screenshots. Window screenshots of Interview / Roles / Reports OK.
- 20:30 A8: Start checks Deepgram key, asks microphone, checks Screen \& System Audio
  Recording with System Settings link; interview drives AudioCaptureService directly.
- 20:45 B3 round 1: deleted overlay UI (Views/, Rendering/), candidate services (session hub,
  Quick Assist, Solve/Design, practice, knowledge, workspaces, project tools, screenshots,
  hotkeys), candidate DB DAOs, provider classes; native access gate; slim SettingsManager.
  App 1,260 -> ~230 Swift files; 310 tests pass in 5 s; app launches.
- 21:00 B3 round 2: removed Picovoice Eagle voice ID (Swift code, dylib, model, build steps,
  disable-library-validation), old welcome frames (30 MB), Mermaid bundle. App 49 MB -> 10 MB;
  no network needed to build; 281 tests pass; launches.
