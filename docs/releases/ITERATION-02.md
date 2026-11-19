# Interview delivery round

## Execution prompt

Operate as a coordinated product team. The orchestrator owns the release plan and integration branch. An independent reviewer first challenges the proposed behavior and acceptance tests. The assigned implementer reads the owning code, callers, existing tests and history, then implements one bounded workflow. The reviewer exercises that workflow through its normal entry points and returns reproducible defects. Repeat repair and verification until the round meets its criteria. Publish a reviewable branch and PR, monitor the checks, and use the next verified gap to plan the next round.

## Current base

All prior feature PRs are merged. This round starts from f9dbdec on main. The shared release checkout is InterviewCheck-delivery-round. Existing checkout edits belong to their owners and require no cleanup to start this round.

## Proposed round

| Lane | User need | Proposed scope | Acceptance |
| --- | --- | --- | --- |
| Review history | Know what changed after another review or answer correction | Persist revision snapshots for explicit answer edits and disposition/note changes; expose a read-only history with actor attribution limited to the available operator context | Stable revision, transaction with current write, no duplicate history on retries, legacy rows have an honest baseline, history cannot revive Trash or leak into a redacted brief |
| History UI | Read earlier evidence without losing the current draft | A focused revision timeline in the exchange review, accessible keyboard selection and clear earlier/current labels | Stale saves retain local text, historic text never becomes the current assessment without an explicit normal edit, mobile and dark UI supported |
| Role portability | Reuse role kits between workspaces | Export a versioned role file and duplicate a role from the library using existing validated import/create paths | Names, questions, policy and permitted materials preserved; no accounts or candidate records; duplicate import conflict handling explicit; cloned role gets a new ID |
| Release assurance | Safely extend the deployed application | Review configuration and deployment changes on main, execute full integration and clean-checkout checks | Upgrade/restoration evidence; Windows and Linux CI; no deployment or payment action without the applicable authority |

## Interfaces

History implementation owns its schema and API. The history UI consumes that API. Role portability owns only role export/clone paths and role library controls. The orchestrator handles shared registration/import seams and verifies backups, privacy limits and reviewer findings across features. Review history must define backup semantics before implementation.

~~~mermaid
flowchart LR
  Plan[Plan and contract] --> Review[Independent review]
  Review --> Implement[Assigned feature lane]
  Implement --> Test[Normal entry point verification]
  Test --> Fix[Repair findings]
  Fix --> Test
  Test --> Release[Commit and PR]
  Release --> Checks[CI and review]
  Checks --> Plan
~~~

## Release ledger

Plan review and ownership assignment are in progress. Remote actions are limited to source branches, PRs and CI for this release. Deployment, live interview data and paid provider operations are separate actions.

## Integrated verification

The orchestrator ran all 205 portable service tests and 68 production browser tests on the combined code. The Node service passed 80 tests and built successfully. Next.js type checking, production build, static export and the packaged app startup checks passed. The independent reviewer verified history privacy and recovery, role kit transfer, phone controls and a 1,000 revision fixture. The ordinary interview response retained its original fields; only its revision number changed.

The release also repairs two source-confirmed hosting gaps. A failed predeployment backup stops before replacing an existing application. The readiness route reads the required review database and, in embedded account mode, the account database, returning 503 if either is unavailable. The backup test uses the deployed Python script against temporary WAL databases and simulated deployment commands. No cloud resource was changed.

The next gate is Windows and Linux CI on the published revision. A merge to main may trigger production rollout and requires the operator's release decision.
