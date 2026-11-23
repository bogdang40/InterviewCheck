> **Historical document.** This was the working plan for the portable edition and is no longer kept up to date.
> [README.md](README.md) supersedes it; read that for how InterviewCheck works today.

# InterviewCheck portable edition

## Working prompt

Trace the native interview from question capture to report. Build a Windows and Linux edition that lets an interviewer test a specific claim of outside assistance. Show the candidate's passage, its comparison source, permitted resources, and the outcome of a follow up. Record uncertainty when the available evidence cannot distinguish an independent answer from an assisted one. Use a Next.js interface with shadcn/ui, Three.js and Framer Motion. Put the interview API in FastAPI. Include audio, migration, calendar, ATS and account workflows.

## Source findings and coverage

The native AnswerEvaluator combines timing, fluency, reference similarity, wording and an optional model review. CheatScorer redistributes weights over the signals present. An even answer after a pause can therefore cross its flag threshold without a matching reference. SharedWords already excludes prompt echoes and finds overlapping sequences. ProbeQuestions asks candidates to explain claims. The portable edition keeps the comparison and the follow up as the units of review.

| Scenario | Observable evidence | Interviewer action |
| --- | --- | --- |
| Verbatim assistance from a known reference | A passage appears in both texts | Compare both passages and ask for a change to the solution |
| Common wording, question restatement or permitted material | The same words also occur in a supplied common source | Exclude those words from a finding |
| Coaching, a second device, or a paraphrase | The spoken answer can be identical to an independent answer | Ask a constraint change and record the explanation |
| No comparison source, short answer or incomplete capture | The available text cannot support comparison | Record limited evidence and obtain context |
| Fluent speech, silence or transcription errors | Delivery and capture quality have multiple explanations | Inspect the transcript before review |

## Interfaces and sequence

~~~mermaid
flowchart LR
  Capture[Typed answer or call audio] --> Review[Next.js review]
  Import[Transcript or native data] --> Review
  Review --> API[FastAPI]
  API --> Compare[Passage comparison]
  API --> Store[SQLite]
  API --> Providers[Configured services]
  Compare --> Review
  Review --> Report[Evidence and interviewer notes]
~~~

1. Implement bounded text comparison, exclusions, attributable excerpts and follow up prompts in portable/api. Test independent, shared, permitted, ambiguous and missing evidence.
2. Add SQLite sessions, roles, reviewed answers and reports. Read native records without modifying the source. Reuse the existing access server contract for accounts and billing.
3. Build the local browser workspace in portable/web. Support explicit notice, editable transcripts, shared audio where the browser supports it, and file import. Keep provider credentials on the server.
4. Exercise the app through its FastAPI routes and browser controls. Build a static Next.js export served by FastAPI so both operating systems use one local process. Supply platform setup and test instructions.
5. Package the built UI and FastAPI service together. Smoke test the extracted archive independently of the source checkout.
6. Track native feature coverage, external account checks and platform verification in portable/README.md.

The primary failure mode is treating shared technical language as proof of a policy violation. A passage can establish shared wording. Only the interviewer can interpret it against the agreed rules. Before claiming detection performance, collect consented sessions with known conditions and independent labels. Split by person and question, evaluate recall, false referrals and abstentions separately, and publish counts with uncertainty.


## Team execution prompt

The orchestrator owns the browser workflow, product contract and final acceptance. One implementer owns the evidence service, native migration and exports. One owns capture, connectors and billing. The reviewer traces real user paths, records reproducible failures, and returns each finding to its owner. Repeat the build and affected tests after each correction. Mark vendor checks, physical capture and each target operating system separately.


## Findings from the implemented system

The upstream path is `InterviewTimeline` to `QuestionTracker` to `AnswerEvaluator` to `CheatScorer`. `ReferenceAnswerRunner` varies comparison prompts and providers. `SharedWords` returns the displayed word ranges. `InterviewReportComposer` combines those outputs with the interviewer's notes. In a synthetic replay, a ten second pause and a uniform pace produced a score of 94 with low confidence without any reference answer or model opinion. See [the verification record](portable/VERIFICATION.md).

The portable API stores named sources per exchange. The operator marks permitted sources, and the matcher excludes prompt and common wording before quoting the two passages. It offers a changed constraint or asks about a claim from the candidate's answer, even when no passage can be attributed. The interviewer can record an explanation, an unresolved question or a disclosure of assistance. These are separate from machine observations.

The fixed evaluation includes a coached and an independent case with identical observations. No detector receiving those inputs can distinguish them. In a pilot, record the tool actually used and which materials were permitted before analysis. Count valid reviews of known incidents, missed incidents, reviews raised on independent answers, and cases with insufficient data. Stratify by interview task and capture quality. A proxy candidate, a human coach, or unobserved work on another device can leave no attributable text at all. Test these with a supervised work sample and an explanation of the candidate's own changes.


## Web application acceptance

The primary application runs Next.js and FastAPI as separate processes with one browser origin. The repository root provides development, production build and start commands. The static bundle is an optional delivery format.

The browser routes cover setup, capture, follow up, review, finish, reopen and export. Each interview takes a snapshot of its selected role template. The reviewer checks those paths in both server modes, including saved records, live audio transport and access control. Optional FastAPI accounts and billing replace the external Node account service for new deployments.
