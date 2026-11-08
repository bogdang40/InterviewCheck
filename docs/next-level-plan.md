# Next level (8 November 2026, 12:40–14:40)

The owner's verdict on the overnight build: "still mid". These notes come from screenshots of
every screen of the installed app and the demo.

## What makes it feel mid today

1. **The evidence is only words.** A score says "Closely follows the GPT 5.2 answer", but nothing
   on screen shows it. The candidate's answer and the AI answers sit apart as plain text.
2. **One question at a time.** The live screen shows only the current question. Which answers were
   flagged is a small list at the bottom, and the timing strip disappears once the answer ends.
3. **The demo is the one thing a buyer can watch without keys or a call, and it ends in silence.**
   It shows no summary and no report. Its AI answers appear at once ("first line after 0.1 s"),
   which hides the pause a real tool causes.
4. **First run lands on a form topped by two orange warnings.** The demo is hidden in the Help
   menu.
5. **Detection leans on keys.** Without a Claude or OpenAI key there is nothing to compare against.
   Nothing compares an answer with the same candidate's other answers.

## Items, in order

| # | Item | Status |
|---|---|---|
| N1 | **Shared words highlighted.** Words the answer shares, in the same order, with an AI answer are highlighted in both texts, like a plagiarism checker, with "41 of 63 words appear word for word in an AI answer". Live screen, report and PDF. | Done |
| N2 | **The interview at a glance.** A rail of question chips (Q1 12% · Q2 86% …) at the top of the live screen; click one to look back; the timing strip stays after the answer ends. | Done |
| N3 | **A demo that tells the story.** AI answers take as long as real ones; the demo ends on its report. | Done (check below) |
| N4 | **First run.** "Watch a 2-minute demo" on the welcome sheet and on the setup screen while keys are missing. | Done |
| N5 | **AI phrasing.** A signal that works without keys: read-aloud LLM wording ("furthermore", "it's worth noting", spoken "Situation: … Task: …", announced lists). | Done |
| N6 | **Their own baseline.** An answer that starts much later and runs much cleaner than the same candidate's other answers is called out. | Done |
| N7 | **Follow-ups without keys.** "Ask next" questions made from the answer's own terms (those an AI answer also used first) when there is no AI review. | Done |
| N8 | **The report leads with its payoff.** Question chips that jump to each answer, and "What stood out": every answer at 70%+ with its strongest evidence, in the app, PDF and Markdown. | Done |
| N9 | **Fixes from an independent design review** (screenshots of every screen). | Done |
| N10 | **The moment the call ends.** The summary leads with "1 of 3 answers flagged", the chips and what stood out; "1 of 1 answer" everywhere. | Done |

## Log

- **N1 done.** `SharedWords` in the core package finds runs of 4+ words (two of them not small words, not the question said back) shared in order, using greedy string tiling. The live screen, report and PDF highlight them in the candidate's answer and in each AI answer, with "N of M words appear word for word in an AI answer" and an "N words match" tag on each AI card. 10 new core tests.
- **N2 done.** `QuestionRail` replaces the "Earlier questions" box: one chip per question with its score colour (an orange dot while it is being answered) and "63% overall · 1 of 2 flagged" from final scores. Clicking a chip looks back at that question, with "Back to Q3" (Esc); a new question returns to live. A finished answer keeps its timing strip, rebuilt from the timeline. New render `native-live-rail`.
- **N3.** The demo's AI answers now wait 1.0–2.3 s before their first words, like real models, so the pause and "first line after" mean something. When the last score is saved the demo switches to its report (Interview | Report switch, overall line in the header).
- **N4 done.** The welcome sheet already had "Watch a Demo Interview". The two orange warnings on New Interview are now a "Before your first interview" checklist (Deepgram key, Claude or OpenAI key, with check marks), "Add Keys in Settings…" and "Watch the Demo".
- **N5 done.** `PhrasingSignal` (core package) looks for model wording read aloud: strong tells ("furthermore", "it's worth noting", "plays a crucial role" …) count fully, common tech words ("leverage", "robust") a third; STAR labels said in order and announced or ordinal lists add a little. It is scored per 100 words, needs 25+ words, and only counts from 0.3 up: an answer without such words is not evidence of anything. It joins the blend at weight 0.10 (saved weights without it gain the default) with the reason "Sounds written, not spoken: …". It works without any AI key. 8 new core tests; full app suite green (345).
- **N6 done.** `BaselineSignal` (core package) compares an answer with the same candidate's other finished answers (20+ words, at least two of them). It is called out when the answer has a third or less of their usual hesitations (fillers and restarts per 100 words, when they usually have 3+), and more strongly when it also starts much later than usual (2.5× and 2.5 s more). It appears on the score card under "Compared with their other answers", in the report and in the PDF. It is evidence only and does not change the %, so the calibration stays as it is. 6 core tests and 1 app test.
- **N7 done.** `ProbeQuestions` (core package) tags the answer's noun phrases with Apple's on-device NaturalLanguage tagger. It skips the question's own terms, vague leads ("many", "great") and time words, and ranks terms an AI answer also used first, then longer terms. Technical questions get "You mentioned “token bucket algorithm”. Walk me through how that works, step by step." and "What would go wrong with “gateway node” here…". Questions about their past get "What exactly was your part in that?", and questions about motives get "What have you actually done with it so far?". These are used as "Ask next" whenever the AI review is off or fails. 5 core tests. The empty Reports list also offers the demo now.
- **N8 done.** The finished demo opened on Q1 (honest, 20%), and the caught answer was below the fold. Reports now have question chips under the header (click to scroll) and a "What stood out" box. `ReportStandout` is shared by the report view, PDF and Markdown. Markdown also gains the shared-word line and the baseline note.
- **N9 done.** An independent design review of every screen found these, now fixed:
  - In dark mode white button text on the green accent had 2.2:1 contrast; the accent is now #2B8552 (4.6:1).
  - AI answer cards were cut off mid-line inside a hidden inner scroll view. They now show 9 lines with "Show All", and every card says "N words match" or "No overlap".
  - The evidence read like debug output (lowercased quotes with punctuation stripped). It now reads "Matches the GPT 5.2 answer word for word: 99 of 104 words", and the word counts agree because shared words are counted as shown.
  - The "Copilot" prompt read as Microsoft Copilot; it is now "Full answer", and saved roles are migrated on load. "Cheater prompts" is now "AI-tool prompts" everywhere in the UI.
  - Colours had too many meanings. Green, orange and red are now only score bands. Matched words get a yellow marker with black text, like Find. Silence and stalling are two greys, the answer is blue, live activity is blue, and tags and chips are neutral.
  - "Overall" was an unexplained number with three wordings. Every screen now leads with "N of M answers flagged", with the overall % second and a tooltip explaining it.
  - Start Interview was greyed out at the bottom of a long form with no reason given. It now sits in a bottom bar that says what it is waiting for (the consent confirmation) or "Ready: name · role".
  - The notes field was capped at 640 pt and the timing strip had no label. Notes are now full width, the strip is captioned "Timing", and the report runs score, timing, answer, AI answers, then verdict and notes.
  - Settings: the model pickers are aligned. "When I forget the key" is now "when I forget to press Question Asked". The audio rows show their icon on the left and their fix on the right, and the Deepgram row has "Open Keys", which switches to the Keys tab.
- **N10 done.** The summary after End used to be one big overall %. It now leads with "N of M answers flagged" (red when any), with "63% overall · Some signs of AI help" below and a tooltip. The question chips open the report, and "What stood out" gives up to three flagged answers with their strongest evidence. "Open Report" is the default button. `InterviewSummary.flaggedLine` gives every place the same wording with the right plural ("1 of 1 answer flagged"): rail, report, summary, demo, PDF, Markdown, the "Report ready" notification and the note sent to the ATS. The chips' own count is hidden where the screen already says it. Full suite green (346).
- **N11 done.**
  - The live screen keeps the score above the growing answer, in the report's order: score, timing, answer, AI answers.
  - The match reason reads "Matches the GPT 5.2 · Full answer word for word: 99 of 104 words".
  - Connections rows no longer repeat "Upcoming interviews" on every row; they say what else each system adds.
  - The README describes the new evidence, and LIVE-TEST-CHECKLIST lists what to confirm about it on the first real call.
- **N12 done.**
  - The welcome sheet makes "Watch a 90-Second Demo" the default button while keys are missing.
  - The Live Companion window above the call shows "N of M words match an AI answer" with the marker swatch.
  - Probe terms drop a verb tagged as a noun before an adverb ("teams ship safely"), and generic nouns (team, company, version …) are skipped.
  - Seen in the real demo run: Q1 20%, Q2 95%, Q3 47%, "1 of 3 answers flagged · 55% overall".
- **N13 done.** The timing strip marks with a tick where the fastest AI answer had its first line, with an "AI's first line" legend and a tooltip. When the real answer began 2.5 s or more after the question and within 5 s of that line, the line under the strip adds "…, 4.0 s after the fastest AI's first line", the same window `TimingSignal.pacedToAI` scores. It appears in the live screen, report and companion. 3 core tests.
