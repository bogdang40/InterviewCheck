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
      Nov 7 23:05 finding: `.deepgramLegacy` is unreachable (resolveTranscriptionMode returns
      `.deepgramSourceBased` whenever a Deepgram key exists, and InterviewPermissions blocks Start
      without one). Dead: UnifiedAudioMixer(+3), DeepgramService(+Responses), DeepgramSpeakerMapper
      (~1,600 lines), initializeLegacyDeepgram, the legacy branch of shutdownDeepgram, the
      `.deepgramLegacy` cases in DeviceRouting/Diagnostics/BufferStats, legacy* state vars, and tests
      DeepgramServiceLifecycleTests + the legacy rows of TranscriptionModeResolutionTests. Apple
      Speech/Analyzer modes are likewise unreachable for interviews. Remove in one commit, then run a
      real two-party call (mic + call audio) before shipping.
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
- [x] D16 Reports list: sort (newest, oldest, highest score, candidate), role filter, flagged-only,
      "No Matches" with Clear Filters; interrupted interviews marked in the list.

## E. Connectors (added Nov 7 ~22:00 at the owner's request)
Goal: automate the interviewer's day. Pull upcoming interviews, candidates, résumés and job
descriptions from ATS / HR systems (direct and through unified APIs), calendars, mail and meeting
tools; pull finished meeting recordings for scoring; optionally post a private note back.
- [x] E1 Packages/InterviewCheckConnectors: shared types, API client, Keychain credentials, OAuth +
      PKCE + loopback receiver, meeting links, HTML job posts, .ics parser, interview classifier.
- [x] E2 App: Connections sidebar section (⌘4), ConnectorManager (connect, browser sign-in, sync
      every 15 min, cache in schema v21), Upcoming Interviews with Prepare (candidate, role + JD,
      résumé) and Join, Calendar on this Mac, .ics invites.
- [x] E3 ATS direct: Greenhouse (Harvest v3), Lever, Ashby, Workable, Recruitee, Zoho Recruit,
      SmartRecruiters (interviews); Teamtailor, BambooHR, JazzHR, Breezy, Personio (no interview API:
      calendar invites are matched to the candidate by email); Workday and iCIMS through unified APIs.
- [x] E4 Unified: Merge, Kombo, Unified.to (interviews + notes), Apideck (jobs + applicants only).
- [x] E5 Google (Calendar + Meet transcripts; Gmail/Drive skipped: restricted scopes), Microsoft 365 (Outlook, Teams
      recordings/transcripts), Zoom (meetings, cloud recordings).
- [x] E6 Meeting recordings in File › Analyze Recording (Zoom audio, Teams/Meet transcripts scored by
      speaker name, low confidence, schema v22 scored_from); reminders with Prepare; Send Summary to the
      ATS as a private note (explicit, editable; link kept in external_links).
- [x] E7 MCP: Swift streamable-HTTP client (JSON or SSE), MCP OAuth (resource metadata, AS metadata,
      dynamic client registration, PKCE, RFC 8707 resource); presets for the official Greenhouse, Ashby
      and Workable MCP servers plus any server; tolerant interview mapper; tools list in Connections.

- [x] E8 Optional automatic scoring of new meeting recordings matched to scheduled interviews
      (off by default, consent confirmation, each recording tried once, "Report ready" notification).

- [x] E9 Automation entry points: Shortcuts actions (Prepare Next Interview, Sync, Latest Report), Dock
      menu with the next interviews, interviewcheck://prepare-next | sync | report/latest, Welcome step.

- [x] E11 Mail (IMAP): interview invites from any mailbox (Gmail, iCloud, Yahoo, Fastmail, Zoho,
      company servers) with an app password; read-only (EXAMINE + BODY.PEEK), calendar parts only,
      latest revision wins, cancellations remove the interview. TLS checked against imap.gmail.com.

- [x] E12 Booking links: Calendly (personal access token) and Cal.com (API key, self-hosted too):
      bookings → upcoming interviews with the invitee as candidate; never follows paging links off-host.

- [x] E13 Webex: hosted meetings + invitees, transcripts (WebVTT speakers) and recording audio, OAuth with
      PKCE on a fixed loopback port (Webex matches redirect ports exactly). Downloads now send API keys
      only to files that need them (pre-signed links never get them).

- [x] E14 Get Next Interview Ready: automatic Prepare at reminder time (on by default; never starts,
      never ticks consent, never over typed setup, no window switch, waits while editing Roles).

- [x] E15 Other calendars for Google (calendar IDs) and Microsoft 365 (calendar names; Calendars.Read.Shared only
      when named): team "Interviews" calendars, deduplicated, unreadable ones noted on the account.

- [x] E16 Staffing ATSs: Bullhorn (Interview appointments, data-center lookup, one REST login per sync, résumé
      attachments, email lookup) and JobAdder (/interviews + /events merged). Read-only: neither has private notes.
      Shared ConnectorOAuth picks each vendor's endpoints and the fixed redirect port.

- [x] E17 Opt-in automation: open the prepared interview's meeting a minute before it starts; save a PDF of
      every finished report to a chosen folder (Settings › Privacy). "Ready" tag on the prepared interview.

- [x] E18 Calendar feed (secret iCal link, webcal/https only, several feeds), Join Next Interview (Shortcuts,
      interviewcheck://join-next, Dock menu).

- [x] E19 Résumés from mail: Prepare searches the connected mailbox (server-side TEXT search, 90 days) for an
      attachment that names the candidate, or a CV in a message whose subject names them; says which file and sender.

- [x] E10 Beta: mark questions automatically when the interviewer forgets the key (Settings ›
      Detector, off by default; question end + 12-word answer, tagged "Marked automatically").

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
- 21:46 D16 reports sort/filter; fixed list centring (frame applied before the inset). 280 app tests.
- 22:04 E1–E2 connectors core + app wiring. 282 app + 12 connector tests.
- 22:09 E3a Greenhouse v3 / Lever / Ashby / Workable connectors from the vendors' docs (research in session scratchpad). 21 connector tests.
- 22:11 E4 unified APIs (Merge, Kombo, Unified.to, Apideck). 25 connector tests.
- 22:17 E5 Google / Microsoft Graph / Zoom connectors + WebVTT; public-client OAuth (no secret). 31 connector tests.
- 22:23 E6 recordings → analysis, transcript scoring, reminders, Send Summary. 286 app + 31 connector tests.
- 22:31 E3b remaining ATSs + CandidateLookup enrichment in Prepare. 37 connector tests.
- 22:36 E7 MCP connectors. 42 connector tests.
- 22:46 E8 auto-scoring of meeting recordings. 288 app tests.
- 22:47 accessibility pass: score card one spoken summary, headings, labelled Join/Prepare, list rows combined.
- 22:50 E9 Shortcuts / Dock menu / URL actions. 290 app tests; Metadata.appintents in the bundle.
- 23:17 review fixes (independent review of the connectors, 15 findings): 2120ff2, 619ff83, fd988b0. Not done: forced refresh + retry on 401, surfacing truncated syncs as warnings (done 00:34, SyncNotes), MCP protocol-version negotiation, data-protection keychain (needs a signed team ID). 298 app + 48 connector tests.
- 23:28 native polish: last section remembered, Delete key in lists, Share PDF; Open in <ATS>; Import roles from ATS jobs; docs/CONNECTORS.md. 299 app + 49 connector tests.
- 23:58 core review (14 findings) fixed: early/late keypress, short answers capped (pause alone never flags), transcripts leave fluency out, New Interview waits for pending scores, answer settle delay, stale finals after regenerate dropped, words saved once, double keypress = one question, recording lifecycle/cleanup/endedAt, whole-name voice match (+ AutoScorer skips ambiguous), recovery respects Answer Done, recording interjections. Late-mark overlap fixed after (closes the previous answer at the next question's start). Reconnect gaps fixed after (connection epoch + count drops; gaps checked from 5 s before the question end). Still to check on a live call: diarized speaker numbers after a reconnect. 305 app + 47 kit tests.
- 00:10 Release reinstalled in ~/Applications: window after 2.0 s, 107 MB, 0% CPU at idle.
- 00:20 18e9083 E11 Mail (IMAP) connector; ICS cancellations and SEQUENCE. 59 connector tests (+ an opt-in live TLS greeting check).
- 00:25 798ff92 E12 Calendly + Cal.com connectors ("Booking links" section). 66 connector tests.
- 00:28–00:31 6dde412 download header fix; 5c7292f E13 Webex. 71 connector tests.
- 00:34 1be7a1f Sync notes: a list cut at a page limit (any connector) shows "Stopped after N …; some may be missing." on the account, without counting as a failure. 73 connector + 312 app tests.
- 00:36 528bdbd E14 automatic Prepare before each interview. 318 app tests.
- 00:44 85c5593 E15 other calendars (Google, Outlook). 75 connector tests.
- 00:54 621e491 E16 Bullhorn + JobAdder. 81 connector tests.
- 01:01 review of tonight's connectors (11 findings) fixed: 380ff72 automatic Prepare (kept until the interview ends, no half-writes, manual Prepare respected), 11dfef0 mail (replies ignored, timeless cancels, IMAP literal crash, closed failed connections, VALARM text), 7ecc565 Webex fresh links at download, Cal.com past bookings, Outlook iCalUId dedupe + listing failure as a note. 85 connector + 321 app tests.
- 01:10 c0d5da9 E17 auto-join + report PDFs to a folder + Ready tag.
- 01:14 3042e2a mail cache across syncs (UIDVALIDITY). 86 connector + 325 app tests.
- 01:23 d11752c E18 calendar feeds + Join Next. 89 connector tests.
- 01:36 second review (10 findings) fixed: c21a953 Prepare (stop clears preparedFrom, first-run role, manual parts written at once, keep until 5 min before the next), 10e55fa report PDFs (rewrite on score change, retry, recovered), 5f6152f Bullhorn invitees, transcript fallback, JobAdder paging. 89 connector + 331 app tests.
- 01:42 bcc2407 E19 résumés from mail. 93 connector tests.
- 01:44 9892978 E19b Outlook résumés via Graph (opt-in Mail.Read); matching shared in ResumeMatching. 94 connector tests.
- third review (12 findings) fixed: 30c05ea IMAP search injection via names (control chars refused), full-name-only résumé matching, forwarded parts, feed failure keeps the last list, Bullhorn stable paging; app fixes (manual Prepare keeps edits, mail résumés manual-only, refusal shown, stop() by generation, PDF after New Interview, keep window). 96 connector tests.
