# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

- Interviewers and hiring teams at companies who run live or recorded technical interviews and need to know when a candidate's answer was read from somewhere else (an AI assistant, a search result, notes) rather than given in their own words.
- The operator of a hosted deployment: one assigned account per deployment signs in and runs the interview workspace (record, compare, review, report).
- Visitors to the hosted site who are not signed in: prospective customers, colleagues the owner sends the link to, and the operator before signing in.

## Product Purpose

An interviewer-side workspace. The interviewer records the assistance policy agreed with the candidate, captures each question and answer (typed, imported from a WebVTT meeting transcript, or live audio when a provider is configured), and adds named sources: AI answers to the same question, references, notes. The workspace shows every passage the candidate's answer shares word for word with a source, marks which sources were permitted, suggests a follow-up question about the matching passage, and records the interviewer's review outcome (explained, unresolved, candidate disclosed assistance). Reports: printable PDF, Markdown, review brief, side-by-side candidate comparison.

Success: the interviewer asks the right follow-up in the moment and leaves with a fair, documented record.

## Positioning

Evidence, not a verdict. The web edition does not assign a probability of cheating from timing, fluency or a model opinion; it shows the exact shared passages and leaves the judgement, and the follow-up question, to the interviewer. Permitted sources are excluded explicitly, and the candidate notice is recorded before capture.

## Operating Context

Live video interviews and their recordings or transcripts; role plans with planned questions, rubric criteria and permitted sources; ATS and calendar preparation; panels that hand interviews between reviewers (assignments, handoff notes, scorecards).

## Capabilities and Constraints

- Hosted deployment: one operator account per deployment; sign-up requires an invite. No public sign-up, no pricing, Stripe billing not configured.
- A fictional sample review works without an account (`/sample/`).
- Optional AI providers (OpenAI, Anthropic, Azure OpenAI, OpenAI-compatible) can generate reference answers and question plans when the operator configures them; none are configured on the hosted site today.
- No real interview corpus has established an accuracy rate (README). Never claim detection accuracy, "catches cheaters", or percentages.
- A native Mac edition exists separately and does show a timing/fluency-based percentage; the web edition does not.

## Brand Commitments

- Name: currently **InterviewCheck**; the owner is choosing a new name (candidates: Honest Interviews, In Their Own Words, Candor Check, and others; Nov 20 2026). Keep the name in one place in code.
- Existing app identity: dark studio look, peach accent, DM Sans + Instrument Serif italic + IBM Plex Mono, waveform mark, studio microphone image (`public/studio-microphone.webp`).
- Home page actions (owner, Nov 20 2026): Sign in, and try the sample review. Signed-in users go straight to the workspace.

## Evidence on Hand

- The sample review's fictional exchanges (`lib/sample.ts`), usable as labelled demonstration content.
- No customers, testimonials, press, benchmarks or prices exist. Do not invent them.

## Product Principles

1. Show the passage, not a score.
2. The interviewer decides; the tool prepares the follow-up.
3. Fairness to the candidate: agreed policy, recorded notice, permitted sources honoured.
4. Every claim on a public page must be true of the web edition today.
