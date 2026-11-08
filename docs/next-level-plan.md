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
| N6 | **Their own baseline.** An answer that starts much later and runs much cleaner than the same candidate's other answers is called out. | |

## Log

- **N1 done.** `SharedWords` in the core package finds runs of 4+ words (two of them not small words, not the question said back) shared in order, using greedy string tiling. The live screen, report and PDF highlight them in the candidate's answer and in each AI answer, with "N of M words appear word for word in an AI answer" and an "N words match" tag on each AI card. 10 new core tests.
- **N2 done.** `QuestionRail` replaces the "Earlier questions" box: one chip per question with its score colour (an orange dot while it is being answered) and "63% overall · 1 of 2 flagged" from final scores. Clicking a chip looks back at that question, with "Back to Q3" (Esc); a new question returns to live. A finished answer keeps its timing strip, rebuilt from the timeline. New render `native-live-rail`.
- **N3.** The demo's AI answers now wait 1.0–2.3 s before their first words, like real models, so the pause and "first line after" mean something. When the last score is saved the demo switches to its report (Interview | Report switch, overall line in the header).
- **N4 done.** The welcome sheet already had "Watch a Demo Interview". The two orange warnings on New Interview are now a "Before your first interview" checklist (Deepgram key, Claude or OpenAI key, with check marks), "Add Keys in Settings…" and "Watch the Demo".
- **N5 done.** `PhrasingSignal` (core package) looks for model wording read aloud: strong tells ("furthermore", "it's worth noting", "plays a crucial role" …) count fully, common tech words ("leverage", "robust") a third; STAR labels said in order and announced or ordinal lists add a little. It is scored per 100 words, needs 25+ words, and only counts from 0.3 up: an answer without such words is not evidence of anything. It joins the blend at weight 0.10 (saved weights without it gain the default) with the reason "Sounds written, not spoken: …". It works without any AI key. 8 new core tests; full app suite green (345).
